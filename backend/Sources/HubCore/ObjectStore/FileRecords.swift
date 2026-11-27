import Foundation
import SQLKit

/// Metadaten zu gespeicherten Objekten (Tabelle `files`); je Mandant und Hash genau eine Zeile (Dedup).
public struct FileRecordService: Sendable {
    package let db: any SQLDatabase
    public init(_ db: any SQLDatabase) { self.db = db }

    /// WP-R6c: Sperre je (Mandant, Hash) bis zum Ende der Transaktion. Wer Bytes verwirft, weil keine `files`-Zeile auf sie zeigt, und wer eine `files`-Zeile für sie anlegt,
    /// nimmt dieselbe Sperre (jedes Modul, das Dateien anlegt oder aufräumt): Zeile und Bytes werden nie gegeneinander gelöscht und angelegt.
    public static func lockBlob(tenant: UUID, sha256: String, on s: any SQLDatabase) async throws {
        try await s.raw("SELECT pg_advisory_xact_lock(hashtextextended(\(bind: "file-blob:\(tenant.uuidString):\(sha256)"), 0))").run()
    }

    /// Idempotent: gleiche Bytes im selben Mandanten liefern dieselbe `files.id`.
    public func register(_ object: StoredObject, backend: ObjectStoreKind, contentType: String = "application/octet-stream") async throws -> UUID {
        let row = try await db.raw("""
            INSERT INTO files (tenant_id, sha256, size_bytes, content_type, backend, storage_key)
            VALUES (\(bind: object.key.tenantID), \(bind: object.key.sha256), \(bind: object.size), \(bind: contentType), \(bind: backend.rawValue), \(bind: object.key.path))
            ON CONFLICT (tenant_id, sha256) DO UPDATE SET sha256 = files.sha256 RETURNING id
            """).first()
        guard let row else { throw ObjectStoreError.io("files insert") }
        return try row.decode(column: "id", as: UUID.self)
    }
}
