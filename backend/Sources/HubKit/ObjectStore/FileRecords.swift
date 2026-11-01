import Foundation
import SQLKit

/// Metadaten zu gespeicherten Objekten (Tabelle `files`); je Mandant und Hash genau eine Zeile (Dedup).
public struct FileRecordService: Sendable {
    let db: any SQLDatabase
    public init(_ db: any SQLDatabase) { self.db = db }

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
