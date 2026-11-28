import Vapor
import Fluent
import SQLKit
import HubCore

// WP-PA7 Teil 3 (AK-PA7-3): Pflege ohne Hand und ohne eigenen Zeitgeber. Beide Schritte sind Aufräumschritte der Worker (`jobSweeps`): jeder Worker mit der
// Job-Art ruft sie zwischen zwei Jobs auf (also nur im Leerlauf). Zustandslos (ADR 0003): ob etwas fällig ist, steht allein in der Datenbank, Zeiten kommen von
// `now()` der Datenbank, und die Entscheidung fällt je Eintrag unter einer Datenbanksperre. Beliebig viele Worker dürfen gleichzeitig laufen.

/// Plant `dms.verify` je Mandant: spätestens alle `DMS_VERIFY_INTERVAL_HOURS` (Standard 168 = 7 Tage, 0 = aus) ein Lauf.
/// Fällig ist ein Mandant mit aktivem DMS und Bestand (Original oder Löschprotokoll), wenn weder ein Lauf im Abstand liegt (auch einer von Hand) noch einer offen ist.
/// Ein Lauf mit Zustand `error` zählt nur einen Tag, damit nach einer Speicherstörung nicht eine Woche lang ungeprüft bleibt.
enum DMSVerifySchedule {
    static let defaultIntervalHours = 168
    static let errorRetryHours = 24

    static func intervalHours(_ env: [String: String]) -> Int {
        env["DMS_VERIFY_INTERVAL_HOURS"].flatMap(Int.init).flatMap { (0...8760).contains($0) ? $0 : nil } ?? defaultIntervalHours
    }

    private static func due(intervalHours: Int, only: UUID?, on s: any SQLDatabase) async throws -> [UUID] {
        try await s.raw("""
            SELECT t.tenant_id FROM tenant_modules t
            WHERE t.module_key = 'dms' AND t.enabled AND (\(bind: only)::uuid IS NULL OR t.tenant_id = \(bind: only)::uuid)
              AND NOT EXISTS (SELECT 1 FROM installation_modules WHERE module_key = 'dms' AND NOT enabled)
              AND (EXISTS (SELECT 1 FROM dms_document_files f WHERE f.tenant_id = t.tenant_id AND f.role = 'original')
                   OR EXISTS (SELECT 1 FROM dms_deletion_log l WHERE l.tenant_id = t.tenant_id))
              AND NOT EXISTS (SELECT 1 FROM dms_integrity_runs r WHERE r.tenant_id = t.tenant_id AND (
                    (r.state <> 'error' AND r.created_at > now() - make_interval(hours => \(bind: intervalHours)::int))
                 OR r.created_at > now() - make_interval(hours => \(bind: min(errorRetryHours, intervalHours))::int)
                 OR (r.state IN ('queued', 'running') AND EXISTS (SELECT 1 FROM jobs j WHERE j.id = r.job_id AND j.state IN ('queued', 'running')))))
            ORDER BY t.tenant_id
            """).all().map { try $0.decode(column: "tenant_id", as: UUID.self) }
    }

    /// Die erste Abfrage (ohne Sperre) findet Kandidaten; verbindlich ist die Wiederholung unter der Sperre je Mandant in der Transaktion, die den Lauf anlegt.
    static func run(intervalHours: Int, on s: any SQLDatabase) async throws {
        guard intervalHours > 0 else { return }
        let candidates = try await due(intervalHours: intervalHours, only: nil, on: s)
        if candidates.isEmpty { return }
        guard let database = s as? any Database else { throw ConfigError(description: "database_unavailable") }
        for tenant in candidates {
            try Task.checkCancellation()
            try await dmsTransaction(database) { _, tx in
                try await tx.raw("SELECT pg_advisory_xact_lock(hashtextextended(\(bind: "dms-verify-schedule:\(tenant.uuidString)"), 0))").run()
                guard try await !due(intervalHours: intervalHours, only: tenant, on: tx).isEmpty else { return }
                _ = try await DMSIntegrity.insertRun(tenant: tenant, actor: nil, action: "dms.integrity.scheduled", requestID: nil, on: tx)
            }
        }
    }
}

/// Entfernt fertige Export-ZIPs `DMS_EXPORT_RETENTION_DAYS` Tage nach der Fertigstellung (Standard 30, 0 = nie). Der Eintrag bleibt als `expired`
/// mit Prüfsummen erhalten; die Datei zählt danach nicht mehr zur Quota. Ein Export ist jederzeit neu erzeugbar.
enum DMSExportExpiry {
    static let defaultRetentionDays = 30
    static let batch = 100

    static func retentionDays(_ env: [String: String]) -> Int {
        env["DMS_EXPORT_RETENTION_DAYS"].flatMap(Int.init).flatMap { (0...3650).contains($0) ? $0 : nil } ?? defaultRetentionDays
    }

    static func run(retentionDays: Int, config: @Sendable () throws -> ObjectStoreConfig, on s: any SQLDatabase) async throws {
        guard retentionDays > 0 else { return }
        let expired = try await s.raw("""
            SELECT tenant_id, id FROM dms_exports WHERE state = 'done' AND finished_at < now() - make_interval(days => \(bind: retentionDays)::int)
            ORDER BY finished_at, id LIMIT \(bind: batch)
            """).all().map { (tenant: try $0.decode(column: "tenant_id", as: UUID.self), id: try $0.decode(column: "id", as: UUID.self)) }
        if expired.isEmpty { return }
        guard let database = s as? any Database else { throw ConfigError(description: "database_unavailable") }
        let storeConfig = try config()
        var firstError: (any Error)?
        for e in expired {   // ein gestörter Eintrag hält die übrigen nicht auf
            try Task.checkCancellation()
            do { try await expire(e.id, tenant: e.tenant, retentionDays: retentionDays, config: storeConfig, database: database) }
            catch { firstError = firstError ?? error }
        }
        if let firstError { throw firstError }
    }

    /// Erst die Datenbank in einer Transaktion (Zustand, Dateizeile, Audit), danach die Bytes. Fällt der zweite Schritt aus, bleibt ein Objekt ohne
    /// `files`-Zeile, das der Aufräumlauf von `dms.verify` nach seiner Schonfrist entfernt.
    private static func expire(_ id: UUID, tenant: UUID, retentionDays: Int, config: ObjectStoreConfig, database: any Database) async throws {
        let removable: String? = try await dmsTransaction(database) { _, tx -> String? in
            guard let row = try await tx.raw("""
                SELECT sha256, size_bytes, file_id FROM dms_exports WHERE tenant_id = \(bind: tenant) AND id = \(bind: id) AND state = 'done'
                  AND finished_at < now() - make_interval(days => \(bind: retentionDays)::int) FOR UPDATE SKIP LOCKED
                """).first() else { return nil }   // ein anderer Worker war schneller
            let sha = try row.decode(column: "sha256", as: String?.self), size = try row.decode(column: "size_bytes", as: Int64?.self)
            let fileID = try row.decode(column: "file_id", as: UUID?.self)
            // Blob-Sperre wie beim Anlegen einer `files`-Zeile: niemand hängt sich zwischen Prüfung und Löschen an dieselben Bytes
            if let sha { try await DMSUpload.lockBlob(tenant: tenant, sha256: sha, on: tx) }
            try await tx.raw("""
                UPDATE dms_exports SET state = 'expired', expired_at = now(), file_id = NULL WHERE tenant_id = \(bind: tenant) AND id = \(bind: id)
                """).run()
            var gone: String?
            // `dms_exports.file_id` hat keinen Fremdschlüssel: andere Exporte und Dokumentdateien ausdrücklich prüfen; Verweise anderer Module sichert ihr Fremdschlüssel
            if let fileID, try await tx.raw("""
                SELECT 1 AS x WHERE EXISTS (SELECT 1 FROM dms_document_files WHERE file_id = \(bind: fileID))
                   OR EXISTS (SELECT 1 FROM dms_exports WHERE tenant_id = \(bind: tenant) AND file_id = \(bind: fileID) AND state = 'done')
                """).first() == nil {
                gone = try await DMSPurge.deleteFileRowIfUnreferenced(fileID, tenant: tenant, on: tx)
            }
            try await AuditLog.record(AuditEvent(action: "dms.export.expired", tenant: tenant, subjectType: "dms.export", subjectID: id.uuidString,
                                                 meta: ["size": .number(size ?? 0), "file_removed": .number(gone == nil ? 0 : 1)]), on: tx)
            return gone
        }
        guard let removable else { return }
        _ = try await DMSPurge.removeBlobIfUnreferenced(try ObjectKey(tenantID: tenant, sha256: removable), config: config, db: database)
    }
}

/// Modul-Migration `dms_032_export_expiry` (Expand): Zustand `expired` und `dms_exports.expired_at`. `schema_version` bleibt unverändert.
/// Revert: abgelaufene Exporte werden `failed` mit Code `expired` (ihre Datei ist weg).
struct CreateDMSExportExpiry: AsyncMigration {
    let name = "dms_032_export_expiry"

    func prepare(on db: any Database) async throws {
        try await run(db, [
            "ALTER TABLE dms_exports ADD COLUMN expired_at timestamptz",
            "ALTER TABLE dms_exports DROP CONSTRAINT dms_exports_state_check",
            "ALTER TABLE dms_exports ADD CONSTRAINT dms_exports_state_check CHECK (state IN ('queued', 'running', 'done', 'failed', 'expired'))",
            "CREATE INDEX dms_exports_expiry ON dms_exports (finished_at) WHERE state = 'done'"])
    }

    func revert(on db: any Database) async throws {
        try await run(db, [
            "DROP INDEX dms_exports_expiry",
            "UPDATE dms_exports SET state = 'failed', error_code = 'expired' WHERE state = 'expired'",
            "ALTER TABLE dms_exports DROP CONSTRAINT dms_exports_state_check",
            "ALTER TABLE dms_exports ADD CONSTRAINT dms_exports_state_check CHECK (state IN ('queued', 'running', 'done', 'failed'))",
            "ALTER TABLE dms_exports DROP COLUMN expired_at"])
    }
}
