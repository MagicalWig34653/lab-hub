import Vapor
import Fluent
import SQLKit

// WP-O1 Ingest-Zustandsautomat (MODUL-DMS 4). Jeder Übergang ist idempotent: Schlüssel (ingest_item, state) in `dms_ingest_transitions`,
// Zeilensperre auf dem Item serialisiert parallele Aufrufe (mehrere Instanzen/Worker). Mandantenfilter in jeder Abfrage.

struct CreateDMSIngest: AsyncMigration {
    let name = "dms_017_ingest"
    func prepare(on db: any Database) async throws {
        try await run(db, [
            """
            CREATE TABLE dms_ingest_items (id uuid PRIMARY KEY DEFAULT gen_random_uuid(), tenant_id uuid NOT NULL, document_id uuid,
              source text NOT NULL CHECK (source IN ('upload', 'folder', 'mail', 'share_ext', 'api')),
              origin_ref text CHECK (origin_ref IS NULL OR char_length(origin_ref) <= 500),
              state text NOT NULL CHECK (state IN ('received', 'stored', 'hashed', 'ocr_queued', 'ocr_done', 'classified', 'done', 'failed_retryable', 'failed_permanent')),
              resume_state text CHECK (resume_state IS NULL OR resume_state IN ('received', 'stored', 'hashed', 'ocr_queued', 'ocr_done', 'classified', 'done')),
              error_code text CHECK (error_code IS NULL OR error_code ~ '^[a-z0-9_.]{1,64}$'),
              created_by uuid, created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now(),
              UNIQUE (tenant_id, id), FOREIGN KEY (tenant_id, document_id) REFERENCES dms_documents (tenant_id, id),
              CHECK ((state IN ('failed_retryable', 'failed_permanent')) = (error_code IS NOT NULL)),
              CHECK ((state IN ('failed_retryable', 'failed_permanent')) = (resume_state IS NOT NULL)))
            """,
            "CREATE INDEX dms_ingest_items_document ON dms_ingest_items (tenant_id, document_id)",
            "CREATE INDEX dms_ingest_items_open ON dms_ingest_items (tenant_id, state) WHERE state <> 'done'",
            """
            CREATE TABLE dms_ingest_transitions (tenant_id uuid NOT NULL, ingest_item_id uuid NOT NULL,
              state text NOT NULL CHECK (state IN ('received', 'stored', 'hashed', 'ocr_queued', 'ocr_done', 'classified', 'done')),
              at timestamptz NOT NULL DEFAULT now(), PRIMARY KEY (ingest_item_id, state),
              FOREIGN KEY (tenant_id, ingest_item_id) REFERENCES dms_ingest_items (tenant_id, id))
            """])
    }
    func revert(on db: any Database) async throws {
        try await run(db, ["DROP TABLE dms_ingest_transitions", "DROP TABLE dms_ingest_items"])
    }
}

enum DMSIngest {
    /// Regulärer Ablauf in dieser Reihenfolge; `failed_*` sind Fehlerzustände (`retry` kehrt zum letzten guten Zustand zurück).
    enum State: String, CaseIterable, Sendable {
        case received, stored, hashed
        case ocrQueued = "ocr_queued", ocrDone = "ocr_done", classified, done
        var index: Int { Self.allCases.firstIndex(of: self)! }
    }
    enum Source: String, Sendable { case upload, folder, mail, shareExt = "share_ext", api }

    static let invalidTransition = HubError(.conflict, "conflict", detail: "invalid_ingest_transition")

    /// Legt ein Item an und führt es bis `upTo` (jeder Schritt protokolliert). Muss in der Transaktion des Aufrufers laufen.
    @discardableResult
    static func create(tenant: UUID, document: UUID?, source: Source, originRef: String? = nil, sender: String? = nil, actor: UUID?, upTo: State, on s: any SQLDatabase) async throws -> UUID {
        guard let row = try await s.raw("""
            INSERT INTO dms_ingest_items (tenant_id, document_id, source, origin_ref, sender, state, created_by)
            VALUES (\(bind: tenant), \(bind: document), \(bind: source.rawValue), \(bind: originRef), \(bind: sender), 'received', \(bind: actor)) RETURNING id
            """).first() else { throw Abort(.internalServerError) }
        let id = try row.decode(column: "id", as: UUID.self)
        try await s.raw("INSERT INTO dms_ingest_transitions (tenant_id, ingest_item_id, state) VALUES (\(bind: tenant), \(bind: id), 'received')").run()
        for next in State.allCases.dropFirst().prefix(upTo.index) { try await advance(id, tenant: tenant, to: next, on: s) }
        return id
    }

    private struct Locked { let state: String; let resume: String? }

    private static func lock(_ id: UUID, tenant: UUID, on s: any SQLDatabase) async throws -> Locked {
        guard let row = try await s.raw("SELECT state, resume_state FROM dms_ingest_items WHERE tenant_id = \(bind: tenant) AND id = \(bind: id) FOR UPDATE").first()
        else { throw DMSError.notFound }
        return Locked(state: try row.decode(column: "state", as: String.self), resume: try row.decode(column: "resume_state", as: String?.self))
    }

    /// Schritt auf den nächsten Zustand. `true` = geändert; `false` = Zustand schon erreicht oder überschritten (Wiederholung ohne Effekt).
    /// Überspringen oder Fortschritt aus einem Fehlerzustand: 409. Unbekanntes oder fremdes Item: 404.
    @discardableResult
    static func advance(_ id: UUID, tenant: UUID, to target: State, on s: any SQLDatabase) async throws -> Bool {
        let cur = try await lock(id, tenant: tenant, on: s)
        guard let current = State(rawValue: cur.state) else { throw invalidTransition }  // failed_*
        if target.index <= current.index { return false }
        guard target.index == current.index + 1 else { throw invalidTransition }
        try await s.raw("UPDATE dms_ingest_items SET state = \(bind: target.rawValue), updated_at = now() WHERE tenant_id = \(bind: tenant) AND id = \(bind: id)").run()
        try await s.raw("""
            INSERT INTO dms_ingest_transitions (tenant_id, ingest_item_id, state) VALUES (\(bind: tenant), \(bind: id), \(bind: target.rawValue))
            ON CONFLICT (ingest_item_id, state) DO NOTHING
            """).run()
        return true
    }

    static func advance(_ id: UUID, tenant: UUID, to target: State, on db: any Database) async throws -> Bool {
        try await dmsTransaction(db) { _, s in try await advance(id, tenant: tenant, to: target, on: s) }
    }

    /// Fehler melden. `retryable` = `failed_retryable` (Job-Wiederholung läuft), sonst `failed_permanent` (Quarantäne). `code` ist ein kurzer Token, keine Nutzdaten.
    /// Aus `done` oder bei gleichem Fehlerzustand: ohne Effekt (`false`). `failed_retryable` -> `failed_permanent` ist erlaubt (Eskalation).
    @discardableResult
    static func fail(_ id: UUID, tenant: UUID, code: String, retryable: Bool, on s: any SQLDatabase) async throws -> Bool {
        let cur = try await lock(id, tenant: tenant, on: s)
        let target = retryable ? "failed_retryable" : "failed_permanent"
        if cur.state == "done" || cur.state == target || cur.state == "failed_permanent" { return false }
        let token = AuditValue.isSafeToken(code) && code.range(of: "^[a-z0-9_.]{1,64}$", options: .regularExpression) != nil ? code : "error"
        try await s.raw("""
            UPDATE dms_ingest_items SET state = \(bind: target), error_code = \(bind: token), resume_state = COALESCE(resume_state, \(bind: cur.state)), updated_at = now()
            WHERE tenant_id = \(bind: tenant) AND id = \(bind: id)
            """).run()
        return true
    }

    static func fail(_ id: UUID, tenant: UUID, code: String, retryable: Bool, on db: any Database) async throws -> Bool {
        try await dmsTransaction(db) { _, s in try await fail(id, tenant: tenant, code: code, retryable: retryable, on: s) }
    }

    /// Manuelles Wiederholen: aus einem Fehlerzustand zurück auf den letzten guten Zustand; sonst ohne Effekt (`false`).
    @discardableResult
    static func retry(_ id: UUID, tenant: UUID, on s: any SQLDatabase) async throws -> Bool {
        let cur = try await lock(id, tenant: tenant, on: s)
        guard cur.state.hasPrefix("failed"), let resume = cur.resume else { return false }
        try await s.raw("""
            UPDATE dms_ingest_items SET state = \(bind: resume), error_code = NULL, resume_state = NULL, updated_at = now()
            WHERE tenant_id = \(bind: tenant) AND id = \(bind: id)
            """).run()
        return true
    }

    static func retry(_ id: UUID, tenant: UUID, on db: any Database) async throws -> Bool {
        try await dmsTransaction(db) { _, s in try await retry(id, tenant: tenant, on: s) }
    }
}
