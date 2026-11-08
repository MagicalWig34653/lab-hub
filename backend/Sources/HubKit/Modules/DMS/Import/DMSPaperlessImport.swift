import Vapor
import Fluent
import SQLKit

// WP-D6: Paperless-Import (MODUL-DMS 10). Läufe verwalten (anlegen, lesen, abbrechen) und der Worker-Job `dms.import.paperless` (Lease, genau ein Worker je Lauf).
// Ein Lauf hat eine Quelle (`export`: Verzeichnis eines document_exporter-Exports im Worker, `api`: REST-API, Token verschlüsselt) und einen Modus
// (`dry_run`: nichts im DMS schreiben, nur Bericht; `import`). Wiederholung und Fortsetzung beruhen auf `dms_import_items` (Quelle + Art + Paperless-ID):
// ein neuer Lauf gegen dieselbe Quelle ergänzt nur Fehlendes, ein vom Worker-Absturz unterbrochener Lauf wird nach Lease-Ablauf von einem anderen Worker fortgesetzt.
// Rechte und Besitzer der Quelle werden nie übernommen (F-23), Regeln nur als Vorschläge im Bericht. Dokumente laufen über `DMSDocuments.create` (Quota, Hash, Magic Bytes).

struct DMSImportOut: Content, Sendable {
    let id: UUID
    let source_kind: String
    let mode: String
    let state: String
    let cancel_requested: Bool
    let config: [String: String]
    let has_secret: Bool
    let progress: [String: Int]
    let error_code: String?
    let requested_by: UUID
    let created_at: String
    let started_at: String?
    let finished_at: String?
}

enum DMSImport {
    static let kind = "dms.import.paperless"
    static let maxAttempts = 3
    struct Payload: Codable, Sendable { let import_id: UUID; let tenant_id: UUID }

    // MARK: Anlegen

    private static func str(_ v: Any?, _ field: String, max: Int) throws -> String {
        guard let s = v as? String, !s.isEmpty, s.count <= max, !s.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw DMSError.invalid(field, v == nil ? "required" : "invalid")
        }
        return s
    }

    /// Prüft den Body streng (unbekannte Schlüssel = 422 mit Feldname) und legt Lauf und Job in einer Transaktion an. Das Token wird sofort verschlüsselt.
    static func enqueue(_ body: [String: Any], tenant: UUID, actor: UUID, requestID: String, box: SecretBox?, policy: PaperlessEndpoint.Policy, on db: any Database) async throws -> DMSImportOut {
        if let k = Set(body.keys).subtracting(["source", "mode", "options"]).sorted().first { throw DMSError.invalid(k, "unknown_field") }
        guard let mode = body["mode"] as? String, ["dry_run", "import"].contains(mode) else { throw DMSError.invalid("mode", body["mode"] == nil ? "required" : "invalid") }
        guard let source = body["source"] as? [String: Any] else { throw DMSError.invalid("source", "required") }
        var options: [String: Any] = ["ocr": true]
        if let o = body["options"] {
            guard let od = o as? [String: Any] else { throw DMSError.invalid("options") }
            if let k = Set(od.keys).subtracting(["ocr"]).sorted().first { throw DMSError.invalid("options.\(k)", "unknown_field") }
            if let ocr = od["ocr"] { guard let b = ocr as? Bool else { throw DMSError.invalid("options.ocr") }; options["ocr"] = b }
        }
        let id = UUID()
        var sourceKind: String, sourceKey: String, config: [String: String], sealed: String?
        switch source["kind"] as? String {
        case "export":
            if let k = Set(source.keys).subtracting(["kind", "path"]).sorted().first { throw DMSError.invalid("source.\(k)", "unknown_field") }
            let path = try str(source["path"], "source.path", max: 200)
            guard PaperlessExportSource.validPath(path) else { throw DMSError.invalid("source.path") }
            (sourceKind, sourceKey, config, sealed) = ("export", "export:" + path.lowercased(), ["path": path], nil)
        case "api":
            if let k = Set(source.keys).subtracting(["kind", "base_url", "token"]).sorted().first { throw DMSError.invalid("source.\(k)", "unknown_field") }
            let endpoint: PaperlessEndpoint
            do { endpoint = try PaperlessEndpoint.parse(try str(source["base_url"], "source.base_url", max: 300), policy: policy) }
            catch let e as ImportError { throw DMSError.invalid("source.base_url", e.code) }
            let token = try str(source["token"], "source.token", max: 500)
            guard let box else { throw DMSError.invalid("source.token", "secret_key_missing") }
            sealed = try box.seal(token, tenant: tenant, source: id)
            (sourceKind, sourceKey, config) = ("api", endpoint.key, ["base_url": endpoint.base])
        default: throw DMSError.invalid("source.kind", source["kind"] == nil ? "required" : "invalid")
        }
        let configJSON = String(decoding: try JSONSerialization.data(withJSONObject: config, options: [.sortedKeys]), as: UTF8.self)
        let optionsJSON = String(decoding: try JSONSerialization.data(withJSONObject: options, options: [.sortedKeys]), as: UTF8.self)
        let (kind0, key0, sealed0) = (sourceKind, sourceKey, sealed)
        return try await dmsTransaction(db) { _, s in
            try await s.raw("SELECT pg_advisory_xact_lock(hashtextextended(\(bind: "dms.import:\(tenant.uuidString):\(key0)"), 0))").run()
            if try await s.raw("SELECT 1 AS x FROM dms_imports WHERE tenant_id = \(bind: tenant) AND source_key = \(bind: key0) AND state IN ('queued', 'running')").first() != nil {
                throw HubError(.conflict, "conflict", detail: "import_already_open")
            }
            try await s.raw("""
                INSERT INTO dms_imports (id, tenant_id, source_kind, source_key, config, secret_enc, mode, options, requested_by)
                VALUES (\(bind: id), \(bind: tenant), \(bind: kind0), \(bind: key0), \(bind: configJSON)::text::jsonb, \(bind: sealed0), \(bind: mode), \(bind: optionsJSON)::text::jsonb, \(bind: actor))
                """).run()
            let payload = String(decoding: try JSONEncoder().encode(Payload(import_id: id, tenant_id: tenant)), as: UTF8.self)
            let job = try await JobService(s).enqueue(kind: kind, payload: payload, priority: DMSOCR.priorityBulk)
            try await s.raw("UPDATE dms_imports SET job_id = \(bind: job) WHERE tenant_id = \(bind: tenant) AND id = \(bind: id)").run()
            try await AuditLog.record(AuditEvent(action: "dms.import.requested", actor: actor, tenant: tenant, subjectType: "dms.import", subjectID: id.uuidString,
                                                 meta: ["mode": .safe(mode), "source": .safe(kind0)], requestID: requestID), on: s)
            guard let out = try await load(id, tenant: tenant, on: s) else { throw Abort(.internalServerError) }
            return out
        }
    }

    // MARK: Lesen

    private static let columns = "id, source_kind, mode, state, cancel_requested, config::text AS config, secret_enc IS NOT NULL AS has_secret, progress::text AS progress, error_code, requested_by, created_at, started_at, finished_at"

    private static func out(_ r: any SQLRow) throws -> DMSImportOut {
        func json<T: Decodable>(_ col: String, _ type: T.Type, default d: T) throws -> T {
            (try? JSONDecoder().decode(T.self, from: Data(try r.decode(column: col, as: String.self).utf8))) ?? d
        }
        return DMSImportOut(id: try r.decode(column: "id", as: UUID.self), source_kind: try r.decode(column: "source_kind", as: String.self), mode: try r.decode(column: "mode", as: String.self),
                            state: try r.decode(column: "state", as: String.self), cancel_requested: try r.decode(column: "cancel_requested", as: Bool.self),
                            config: try json("config", [String: String].self, default: [:]), has_secret: try r.decode(column: "has_secret", as: Bool.self),
                            progress: try json("progress", [String: Int].self, default: [:]), error_code: try r.decode(column: "error_code", as: String?.self),
                            requested_by: try r.decode(column: "requested_by", as: UUID.self), created_at: iso(try r.decode(column: "created_at", as: Date.self)),
                            started_at: try r.decode(column: "started_at", as: Date?.self).map(iso), finished_at: try r.decode(column: "finished_at", as: Date?.self).map(iso))
    }

    static func load(_ id: UUID, tenant: UUID, on s: any SQLDatabase) async throws -> DMSImportOut? {
        try await s.raw("SELECT \(unsafeRaw: columns) FROM dms_imports WHERE tenant_id = \(bind: tenant) AND id = \(bind: id)").first().map(out)
    }

    static func list(tenant: UUID, on s: any SQLDatabase) async throws -> [DMSImportOut] {
        try await s.raw("SELECT \(unsafeRaw: columns) FROM dms_imports WHERE tenant_id = \(bind: tenant) ORDER BY created_at DESC, id DESC LIMIT 50").all().map(out)
    }

    /// Der Bericht als JSON-Text; `nil`, solange der Lauf keinen hat (nicht beendet) oder die ID fremd/unbekannt ist.
    static func report(_ id: UUID, tenant: UUID, on s: any SQLDatabase) async throws -> String? {
        try await s.raw("SELECT report::text AS r FROM dms_imports WHERE tenant_id = \(bind: tenant) AND id = \(bind: id) AND report IS NOT NULL").first()?.decode(column: "r", as: String.self)
    }

    // MARK: Abbrechen

    /// `queued` -> sofort `cancelled`; `running` -> der Lauf endet vor dem nächsten Dokument (bereits importierte bleiben, ein neuer Lauf setzt fort); sonst 409.
    static func cancel(_ id: UUID, tenant: UUID, actor: UUID, requestID: String, on db: any Database) async throws -> DMSImportOut {
        try await dmsTransaction(db) { _, s in
            guard let row = try await s.raw("SELECT state FROM dms_imports WHERE tenant_id = \(bind: tenant) AND id = \(bind: id) FOR UPDATE").first() else { throw DMSError.notFound }
            switch try row.decode(column: "state", as: String.self) {
            case "queued":
                try await s.raw("UPDATE dms_imports SET state = 'cancelled', cancel_requested = true, finished_at = now() WHERE tenant_id = \(bind: tenant) AND id = \(bind: id)").run()
                try await AuditLog.record(AuditEvent(action: "dms.import.cancelled", actor: actor, tenant: tenant, subjectType: "dms.import", subjectID: id.uuidString, requestID: requestID), on: s)
            case "running":
                try await s.raw("UPDATE dms_imports SET cancel_requested = true WHERE tenant_id = \(bind: tenant) AND id = \(bind: id)").run()
                try await AuditLog.record(AuditEvent(action: "dms.import.cancel_requested", actor: actor, tenant: tenant, subjectType: "dms.import", subjectID: id.uuidString, requestID: requestID), on: s)
            default: throw HubError(.conflict, "conflict", detail: "import_not_cancellable")
            }
            guard let out = try await load(id, tenant: tenant, on: s) else { throw DMSError.notFound }
            return out
        }
    }

    // MARK: Worker

    static func handler(storeConfig: @escaping @Sendable () throws -> ObjectStoreConfig, box: SecretBox?, root: String?, tempRoot: String, policy: PaperlessEndpoint.Policy,
                        limits: DMSSourceLimits, afterDocument: (@Sendable (_ processed: Int) async throws -> Void)? = nil) -> JobHandler {
        return { job, s in
            guard let payload = try? JSONDecoder().decode(Payload.self, from: Data(job.payload.utf8)) else { throw PermanentJobError(code: "payload_invalid") }
            guard let db = s as? any Database else { throw PermanentJobError(code: "database_unavailable") }
            try await process(job: job, payload: payload, storeConfig: storeConfig, box: box, root: root, tempRoot: tempRoot, policy: policy, limits: limits, afterDocument: afterDocument, db: db, s: s)
        }
    }

    struct RunRow: Sendable {
        let id: UUID, tenant: UUID, sourceKind: String, sourceKey: String, config: [String: String], secretEnc: String?, mode: String, ocr: Bool, requestedBy: UUID
    }

    private static func process(job: ClaimedJob, payload: Payload, storeConfig: () throws -> ObjectStoreConfig, box: SecretBox?, root: String?, tempRoot: String,
                                policy: PaperlessEndpoint.Policy, limits: DMSSourceLimits, afterDocument: (@Sendable (Int) async throws -> Void)?, db: any Database, s: any SQLDatabase) async throws {
        let tenant = payload.tenant_id
        // Übernehmen: nur ein Lauf in `queued`/`running` (abgebrochene, fertige oder fremde Läufe: nichts tun). Ein zweiter Worker kommt nur nach Lease-Ablauf hierher.
        guard let row = try await s.raw("""
            UPDATE dms_imports SET state = 'running', started_at = COALESCE(started_at, now()) WHERE tenant_id = \(bind: tenant) AND id = \(bind: payload.import_id) AND state IN ('queued', 'running')
            RETURNING source_kind, source_key, config::text AS config, secret_enc, mode, (options->>'ocr')::boolean AS ocr, requested_by
            """).first() else { return }
        let run = RunRow(id: payload.import_id, tenant: tenant, sourceKind: try row.decode(column: "source_kind", as: String.self), sourceKey: try row.decode(column: "source_key", as: String.self),
                         config: (try? JSONDecoder().decode([String: String].self, from: Data(try row.decode(column: "config", as: String.self).utf8))) ?? [:],
                         secretEnc: try row.decode(column: "secret_enc", as: String?.self), mode: try row.decode(column: "mode", as: String.self),
                         ocr: try row.decode(column: "ocr", as: Bool?.self) ?? true, requestedBy: try row.decode(column: "requested_by", as: UUID.self))
        guard try await DMSSources.dmsActive(tenant: tenant, on: s) else { try await DMSImportRunner.finish(run, state: "failed", code: "module_disabled", runner: nil, db: db, s: s); return }

        var client: HTTPClient?
        func shutdown() async { if let c = client { try? await c.shutdown(); client = nil } }
        do {
            let source: any PaperlessSource
            switch run.sourceKind {
            case "export":
                guard let root, root.hasPrefix("/") else { throw ImportError("import_root_missing") }
                guard let path = run.config["path"], PaperlessExportSource.validPath(path), let dir = PaperlessExportSource.resolve(root: root, tenant: tenant, path: path) else { throw ImportError("source_not_found") }
                source = try PaperlessExportSource(dir: dir, key: run.sourceKey)
            default:
                guard let box else { throw ImportError("secret_key_missing") }
                guard let sealed = run.secretEnc else { throw ImportError("secret_missing") }
                let token: String
                do { token = try box.open(sealed, tenant: tenant, source: run.id) } catch { throw ImportError("secret_unreadable") }
                let endpoint = try PaperlessEndpoint.parse(run.config["base_url"] ?? "", policy: policy)   // Allowlist gilt auch im Worker (Konfiguration kann sich geändert haben)
                let c = PaperlessAPISource.makeClient()
                client = c
                source = PaperlessAPISource(endpoint: endpoint, token: token, tempRoot: URL(fileURLWithPath: tempRoot, isDirectory: true), client: c)
            }
            let runner = DMSImportRunner(run: run, source: source, config: try storeConfig(), limits: limits, db: db, s: s, requestID: "import-\(job.id.uuidString.prefix(8).lowercased())", afterDocument: afterDocument)
            do {
                try await runner.execute()
                await shutdown()
                try await DMSImportRunner.finish(run, state: "done", code: nil, runner: runner, db: db, s: s)
            } catch is DMSImportRunner.Cancelled {
                await shutdown()
                try await DMSImportRunner.finish(run, state: "cancelled", code: nil, runner: runner, db: db, s: s)
            }
        } catch is CancellationError {
            await shutdown()
            throw CancellationError()   // Worker-Ende oder Lease-Verlust: der Lauf bleibt `running`, ein anderer Worker setzt fort
        } catch let e as ImportError {
            await shutdown()
            try await DMSImportRunner.finish(run, state: "failed", code: e.code, runner: nil, db: db, s: s)
        } catch let e as HubError {
            await shutdown()
            try await DMSImportRunner.finish(run, state: "failed", code: e.code == "storage_quota_exceeded" ? e.code : "import_failed", runner: nil, db: db, s: s)
        } catch {
            await shutdown()
            if Task.isCancelled { throw CancellationError() }
            if job.attempts >= maxAttempts {
                try await DMSImportRunner.finish(run, state: "failed", code: "import_failed", runner: nil, db: db, s: s)
                throw PermanentJobError(code: "import_failed")
            }
            throw error
        }
    }
}
