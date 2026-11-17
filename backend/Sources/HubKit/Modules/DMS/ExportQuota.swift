import Vapor
import Fluent
import SQLKit

// WP-H11: Quota-Prüfung für Worker-Jobs, die selbst Dateien des Mandanten erzeugen (Export-ZIP, OCR-Archivdatei).
extension DMSUpload {
    /// Variante von `discardIfUnreferenced` für Aufrufer mit Objektspeicher-Instanz statt Konfiguration.
    static func discardIfUnreferenced(_ key: ObjectKey, store: any ObjectStore, db: any Database, logger: Logger) async {
        do {
            try await db.transaction { tx in
                let s = try sql(tx)
                try await lockBlob(tenant: key.tenantID, sha256: key.sha256, on: s)
                if try await s.raw("SELECT 1 AS x FROM files WHERE tenant_id = \(bind: key.tenantID) AND sha256 = \(bind: key.sha256)").first() == nil {
                    try await store.delete(key)
                }
            }
        } catch {
            logger.warning("quota cleanup failed", metadata: ["error": .string(String(describing: type(of: error)))])
        }
    }

    /// Registriert die Datei des Mandanten unter Blob- und Quota-Sperre (Reihenfolge wie `DMSDocuments.create`); gibt es die Bytes schon als `files`-Zeile, zählt nichts zusätzlich.
    /// Überschreitung: 413 `storage_quota_exceeded` (die Transaktion des Aufrufers wird zurückgerollt).
    static func registerWithinQuota(_ stored: StoredObject, backend: ObjectStoreKind, contentType: String, quotaBytes: Int64, on s: any SQLDatabase) async throws -> UUID {
        try await lockBlob(tenant: stored.key.tenantID, sha256: stored.key.sha256, on: s)
        if try await s.raw("SELECT 1 AS x FROM files WHERE tenant_id = \(bind: stored.key.tenantID) AND sha256 = \(bind: stored.key.sha256)").first() == nil {
            try await enforceQuota(tenant: stored.key.tenantID, adding: stored.size, limit: quotaBytes, on: s)
        }
        return try await FileRecordService(s).register(stored, backend: backend, contentType: contentType)
    }
}
