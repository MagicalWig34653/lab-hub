import Foundation
import NIOCore
import SQLKit

/// Database backend for tiny installations (docs/OFFENE-FRAGEN.md F-06: not for large volumes, bloats backups/WAL).
/// Bytes live in `object_chunks` (1 MiB `bytea` rows, so neither writing nor reading buffers the whole object).
/// Uploads are staged under a random `tmp:` hash and promoted by a single `UPDATE` after verification.
/// `created_at` (DB time) is the last write or dedup hit; the orphan sweep (`OrphanSweep.swift`) uses it as grace period.
public struct PostgresObjectStore: ObjectStore {
    public let kind = ObjectStoreKind.db
    package let db: any SQLDatabase
    public init(_ db: any SQLDatabase) { self.db = db }

    public func put(tenant: UUID, stream: ByteStream, expectedSHA256: String?) async throws -> StoredObject {
        let expected = try normalizedExpectedHash(expectedSHA256)
        let staging = "tmp:" + UUID().uuidString.lowercased()
        var hasher = StreamHasher()
        var seq = 0
        var pending = ByteBuffer()
        func flush(_ buf: ByteBuffer) async throws {
            let bytes = Data(buf.readableBytesView)
            try await db.raw("INSERT INTO object_chunks (tenant_id, sha256, seq, data) VALUES (\(bind: tenant), \(bind: staging), \(bind: seq), \(bind: bytes))").run()
            seq += 1
        }
        do {
            for try await chunk in stream {
                hasher.update(chunk)
                var c = chunk
                pending.writeBuffer(&c)
                while pending.readableBytes >= objectStoreChunkSize {
                    try await flush(pending.readSlice(length: objectStoreChunkSize)!)
                }
                pending.discardReadBytes()
            }
            if pending.readableBytes > 0 || seq == 0 { try await flush(pending) }   // empty object keeps one empty chunk
            let hash = hasher.finish()
            if let expected, expected != hash { throw ObjectStoreError.hashMismatch }
            let key = try ObjectKey(tenantID: tenant, sha256: hash)
            // Karte 3: Dedup frischt die Zeit des vorhandenen Objekts auf (Schonfrist des Aufräumlaufs). Löscht der Aufräumlauf es gerade (Zeilensperre),
            // wartet das UPDATE, findet danach keine Zeile mehr, und dieser Upload legt die Bytes neu ab.
            if try await db.raw("UPDATE object_chunks SET created_at = now() WHERE tenant_id = \(bind: tenant) AND sha256 = \(bind: hash) AND seq = 0 RETURNING seq").first() != nil {
                try await discard(tenant, staging)
                return StoredObject(key: key, size: hasher.size, deduplicated: true)
            }
            do {
                // Karte 3: only promote a complete staging set. A `put` stalled beyond the grace period may have lost parts to the orphan sweep;
                // it must fail instead of publishing a truncated object under the hash.
                let promoted = try await db.raw("""
                    UPDATE object_chunks SET sha256 = \(bind: hash), created_at = now() WHERE tenant_id = \(bind: tenant) AND sha256 = \(bind: staging)
                      AND (SELECT count(*) FROM object_chunks WHERE tenant_id = \(bind: tenant) AND sha256 = \(bind: staging)) = \(bind: seq)
                    RETURNING seq
                    """).all()
                if promoted.isEmpty { throw ObjectStoreError.io("staging incomplete") }
            } catch {
                // concurrent identical upload won the primary-key race
                try await discard(tenant, staging)
                if try await exists(key) { return StoredObject(key: key, size: hasher.size, deduplicated: true) }
                throw error
            }
            return StoredObject(key: key, size: hasher.size, deduplicated: false)
        } catch {
            try? await discard(tenant, staging)
            throw error
        }
    }

    private func discard(_ tenant: UUID, _ staging: String) async throws {
        try await db.raw("DELETE FROM object_chunks WHERE tenant_id = \(bind: tenant) AND sha256 = \(bind: staging)").run()
    }

    public func get(_ key: ObjectKey) async throws -> ByteStream {
        guard try await exists(key) else { throw ObjectStoreError.notFound }
        let state = UnsafeSendableBox(0)
        let db = self.db
        return ByteStream(unfolding: {
            let seq = state.value
            guard let row = try await db.raw("SELECT data FROM object_chunks WHERE tenant_id = \(bind: key.tenantID) AND sha256 = \(bind: key.sha256) AND seq = \(bind: seq)").first() else { return nil }
            state.value += 1
            let bytes = try row.decode(column: "data", as: Data.self)
            // the single empty chunk of an empty object ends the stream without yielding
            if bytes.isEmpty { return nil }
            return ByteBuffer(data: bytes)
        })
    }

    public func exists(_ key: ObjectKey) async throws -> Bool {
        try await db.raw("SELECT 1 AS x FROM object_chunks WHERE tenant_id = \(bind: key.tenantID) AND sha256 = \(bind: key.sha256) AND seq = 0").first() != nil
    }

    public func delete(_ key: ObjectKey) async throws {
        try await db.raw("DELETE FROM object_chunks WHERE tenant_id = \(bind: key.tenantID) AND sha256 = \(bind: key.sha256)").run()
    }
}
