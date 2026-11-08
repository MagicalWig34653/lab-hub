import Vapor
import Fluent
import SQLKit

// WP-D9: Quelle des Dokuments (`dms_documents.source`), Zähler für das Dashboard (`GET dms/stats`) und passende Indizes.
// - Migration `dms_025_document_source` (Modul, expand-only, `schema_version` unverändert): Spalte `source` (NOT NULL, Standard `unknown`), Backfill aus dem frühesten Eingangsvorgang
//   (`dms_ingest_items`) bzw. aus `mail_attachment`-Verknüpfungen, sonst `unknown`; Indizes für Quelle, offene Vorschläge, Fehlerzustände.
// - Neue Dokumente setzen die Quelle beim Anlegen (Upload, Mail, Konsumordner, Share-/Scan-API, Import, API).

enum DMSDocumentSource: String, Sendable, CaseIterable {
    case upload, mail, folder, share, `import`, api, unknown

    /// Standardableitung aus dem Eingangsvorgang (der Import überschreibt mit `.import`, er läuft technisch als `api`).
    init(ingest: DMSIngest.Source) {
        switch ingest {
        case .upload: self = .upload
        case .folder: self = .folder
        case .mail: self = .mail
        case .shareExt: self = .share
        case .api: self = .api
        }
    }
}

struct CreateDMSDocumentSource: AsyncMigration {
    let name = "dms_025_document_source"
    func prepare(on db: any Database) async throws {
        try await run(db, [
            "ALTER TABLE dms_documents ADD COLUMN source text NOT NULL DEFAULT 'unknown' CHECK (source IN ('upload', 'mail', 'folder', 'share', 'import', 'api', 'unknown'))",
            // Backfill: frühester Eingangsvorgang; `api` mit Herkunft `paperless:` war der Import (D6)
            """
            UPDATE dms_documents d SET source = i.s FROM (
              SELECT DISTINCT ON (document_id) tenant_id, document_id,
                CASE source WHEN 'upload' THEN 'upload' WHEN 'folder' THEN 'folder' WHEN 'mail' THEN 'mail' WHEN 'share_ext' THEN 'share'
                            ELSE CASE WHEN origin_ref LIKE 'paperless:%' THEN 'import' ELSE 'api' END END AS s
              FROM dms_ingest_items WHERE document_id IS NOT NULL ORDER BY document_id, created_at, id) i
            WHERE d.id = i.document_id AND d.tenant_id = i.tenant_id
            """,
            // ohne Eingangsvorgang: Mail-Anhang bzw. Mail selbst (Verknüpfung) -> mail
            """
            UPDATE dms_documents d SET source = 'mail' WHERE d.source = 'unknown' AND EXISTS (
              SELECT 1 FROM links l WHERE l.tenant_id = d.tenant_id AND l.kind = 'mail_attachment' AND l.removed_at IS NULL
                AND ((l.from_type = 'dms.document' AND l.from_id = d.id) OR (l.to_type = 'dms.document' AND l.to_id = d.id)))
            """,
            "CREATE INDEX dms_documents_source ON dms_documents (tenant_id, source, created_at, id) WHERE trashed_at IS NULL",
            "CREATE INDEX dms_suggestions_open_document ON dms_suggestions (tenant_id, document_id) WHERE state = 'open'",
            "CREATE INDEX dms_ingest_items_failed ON dms_ingest_items (tenant_id, document_id) WHERE state = 'failed_permanent'"])
    }
    func revert(on db: any Database) async throws {
        try await run(db, ["DROP INDEX dms_ingest_items_failed", "DROP INDEX dms_suggestions_open_document", "DROP INDEX dms_documents_source",
                           "ALTER TABLE dms_documents DROP COLUMN source"])
    }
}

/// Zähler für das Dashboard (Recht `dms.document.read`); Papierkorb zählt nie mit, alles mandantengefiltert.
struct DMSStatsOut: Content, Sendable, Equatable {
    /// Dokumente mit Eingangsvorgang in Verarbeitung (nicht `done`, nicht `failed_permanent`; `failed_retryable` läuft noch).
    let queued: Int
    /// Dokumente mit Eingangsvorgang in `failed_permanent` (Quarantäne).
    let failed: Int
    /// Dokumente mit mindestens einem offenen Vorschlag.
    let open_suggestions: Int
    /// Dokumente mit Fälligkeit/Frist vor `today` (Standard: Datenbankdatum); Verträge zählen nicht (ihr Vertragsende ist keine Zahlungsfrist).
    let overdue: Int
    /// Dokumente, die in den letzten 7 Tagen eingegangen sind (Datenbankzeit).
    let new_last_7_days: Int
}

enum DMSStats {
    static func load(tenant: UUID, today: String?, on s: any SQLDatabase) async throws -> DMSStatsOut {
        let row = try await s.raw("""
            SELECT
              (SELECT count(DISTINCT i.document_id) FROM dms_ingest_items i JOIN dms_documents d ON d.id = i.document_id AND d.tenant_id = i.tenant_id
                 WHERE i.tenant_id = \(bind: tenant) AND d.trashed_at IS NULL AND i.state NOT IN ('done', 'failed_permanent'))::bigint AS queued,
              (SELECT count(DISTINCT i.document_id) FROM dms_ingest_items i JOIN dms_documents d ON d.id = i.document_id AND d.tenant_id = i.tenant_id
                 WHERE i.tenant_id = \(bind: tenant) AND d.trashed_at IS NULL AND i.state = 'failed_permanent')::bigint AS failed,
              (SELECT count(*) FROM dms_documents d WHERE d.tenant_id = \(bind: tenant) AND d.trashed_at IS NULL
                 AND EXISTS (SELECT 1 FROM dms_suggestions g WHERE g.tenant_id = d.tenant_id AND g.document_id = d.id AND g.state = 'open'))::bigint AS open_suggestions,
              (SELECT count(*) FROM dms_documents d JOIN dms_extractions x ON x.document_id = d.id AND x.tenant_id = d.tenant_id
                 WHERE d.tenant_id = \(bind: tenant) AND d.trashed_at IS NULL AND x.kind <> 'contract' AND x.due_date < COALESCE(\(bind: today)::text::date, current_date))::bigint AS overdue,
              (SELECT count(*) FROM dms_documents d WHERE d.tenant_id = \(bind: tenant) AND d.trashed_at IS NULL AND d.created_at >= now() - interval '7 days')::bigint AS new_last_7_days
            """).first()!
        func n(_ c: String) throws -> Int { Int(try row.decode(column: c, as: Int64.self)) }
        return DMSStatsOut(queued: try n("queued"), failed: try n("failed"), open_suggestions: try n("open_suggestions"), overdue: try n("overdue"), new_last_7_days: try n("new_last_7_days"))
    }
}
