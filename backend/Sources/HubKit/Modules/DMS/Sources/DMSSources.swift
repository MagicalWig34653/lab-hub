import Vapor
import Fluent
import SQLKit

// WP-D4: Quellen (MODUL-DMS 4): Mail (IMAP-Polling) und Konsumordner als Worker-Jobs, Verwaltung je Mandant.
// Jede Quelle hat genau eine Job-Kette: `dms.mail.poll` bzw. `dms.folder.scan` reiht nach jedem Lauf den nächsten Lauf ein (kein Zeitplaner nötig,
// kein Dauerprozess). `dms_sources.scheduled_job_id` unter Zeilensperre macht „höchstens ein offener Job je Quelle“ wahr; die Lease des Jobs
// (ADR 0006) macht „genau ein Worker je Lauf“ wahr. Ein Lauf, der abstürzt, wird nach Lease-Ablauf wiederholt; Idempotenz steht in `dms_source_items`.

struct CreateDMSSources: AsyncMigration {
    let name = "dms_022_sources"
    func prepare(on db: any Database) async throws {
        try await run(db, [
            """
            CREATE TABLE dms_sources (id uuid PRIMARY KEY DEFAULT gen_random_uuid(), tenant_id uuid NOT NULL,
              kind text NOT NULL CHECK (kind IN ('mail', 'folder')),
              name text NOT NULL CHECK (char_length(name) BETWEEN 1 AND 100),
              config jsonb NOT NULL,
              secret_enc text CHECK (secret_enc IS NULL OR char_length(secret_enc) <= 2000),
              enabled boolean NOT NULL DEFAULT true,
              created_by uuid NOT NULL REFERENCES users (id),
              scheduled_job_id uuid,
              runs bigint NOT NULL DEFAULT 0, last_run_at timestamptz,
              last_status text CHECK (last_status IS NULL OR last_status IN ('ok', 'error')),
              last_error text CHECK (last_error IS NULL OR last_error ~ '^[a-z0-9_.]{1,64}$'),
              last_stats jsonb,
              created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now(),
              UNIQUE (tenant_id, id), CHECK ((last_status = 'error') = (last_error IS NOT NULL)))
            """,
            "CREATE UNIQUE INDEX dms_sources_name ON dms_sources (tenant_id, lower(name))",
            // Idempotenz: ein Eingangselement (Mail+Anhang, Datei) wird je Quelle höchstens einmal zum Dokument. Ohne Fremdschlüssel auf Dokumente
            // (die Löschung eines Dokuments nach Fristablauf darf nicht an der Quelle hängen).
            """
            CREATE TABLE dms_source_items (tenant_id uuid NOT NULL, source_id uuid NOT NULL, item_key text NOT NULL CHECK (item_key ~ '^[0-9a-f]{64}$'),
              document_id uuid, created_at timestamptz NOT NULL DEFAULT now(), PRIMARY KEY (source_id, item_key),
              FOREIGN KEY (tenant_id, source_id) REFERENCES dms_sources (tenant_id, id) ON DELETE CASCADE)
            """,
            // Messungen des Konsumordners (Stabilitätsprüfung über zwei Läufe): Größe und mtime (µs), Zeit der ersten gleichen Messung aus DB-`now()`.
            """
            CREATE TABLE dms_folder_observations (tenant_id uuid NOT NULL, source_id uuid NOT NULL, rel_name text NOT NULL CHECK (char_length(rel_name) <= 255),
              size_bytes bigint NOT NULL, mtime_us bigint NOT NULL, first_seen_at timestamptz NOT NULL DEFAULT now(), PRIMARY KEY (source_id, rel_name),
              FOREIGN KEY (tenant_id, source_id) REFERENCES dms_sources (tenant_id, id) ON DELETE CASCADE)
            """])
    }
    func revert(on db: any Database) async throws {
        try await run(db, ["DROP TABLE dms_folder_observations", "DROP TABLE dms_source_items", "DROP TABLE dms_sources"])
    }
}

// MARK: Konfiguration

struct MailSourceConfig: Codable, Sendable, Equatable {
    var host: String
    var port: Int
    var username: String
    var mailbox: String
    var processed_mailbox: String?
    var interval_seconds: Int
    var include_body: Bool
    var sender_contains: String?
    var subject_contains: String?
    var max_per_run: Int
    /// WP-D7: `relevant` (Standard: die Mail wird als Original (.eml) abgelegt, wenn der Mailtext als Dokumentart erkannt wird), `always`, `never`.
    var keep_mail: String?
}

struct FolderSourceConfig: Codable, Sendable, Equatable {
    var path: String
    var interval_seconds: Int
    var stable_seconds: Int
}

enum DMSSourceKind: String, Sendable { case mail, folder
    var jobKind: String { self == .mail ? DMSMailPoll.kind : DMSFolderScan.kind }
}

struct DMSSourceOut: Content, Sendable {
    let id: UUID
    let kind: String
    let name: String
    let config: [String: DMSFieldValue]
    let has_secret: Bool
    let enabled: Bool
    let runs: Int64
    let last_run_at: String?
    let last_status: String?
    let last_error: String?
    let last_stats: [String: Int]?
    let created_at: String
    let updated_at: String
}

/// Kennung, die der Handler braucht (aus der Datenbank gelesen).
struct DMSSourceRow: Sendable {
    let id: UUID
    let tenant: UUID
    let kind: DMSSourceKind
    let name: String
    let configJSON: String
    let secretEnc: String?
    let enabled: Bool
    let createdBy: UUID

    func decode<T: Decodable>(_ type: T.Type) throws -> T { try JSONDecoder().decode(T.self, from: Data(configJSON.utf8)) }
}

enum DMSSources {
    static let maxPerTenant = 50
    static let columns = "id, kind, name, config::text AS config, secret_enc IS NOT NULL AS has_secret, enabled, runs, last_run_at, last_status, last_error, last_stats::text AS last_stats, created_at, updated_at"

    // MARK: Validierung

    private static func str(_ v: Any?, _ field: String, max: Int, required: Bool = true) throws -> String? {
        guard let v, !(v is NSNull) else { if required { throw DMSError.invalid(field, "required") }; return nil }
        guard let s = v as? String, !s.isEmpty, s.count <= max, !s.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw DMSError.invalid(field) }
        return s
    }
    private static func int(_ v: Any?, _ field: String, range: ClosedRange<Int>, default d: Int) throws -> Int {
        guard let v, !(v is NSNull) else { return d }
        guard let n = v as? Int, !(v is Bool), range.contains(n) else { throw DMSError.invalid(field) }
        return n
    }
    private static func ascii(_ s: String?, _ field: String) throws -> String? {
        guard let s else { return nil }
        guard s.unicodeScalars.allSatisfy({ $0.value >= 32 && $0.value < 127 }) else { throw DMSError.invalid(field, "ascii_only") }
        return s
    }
    static func hostAllowed(_ host: String, env: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        guard let list = env["DMS_MAIL_HOST_ALLOWLIST"], !list.isEmpty else { return true }
        return list.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.contains(host.lowercased())
    }

    /// Prüft und normalisiert die Konfiguration (unbekannte Schlüssel = 422, Feld im Fehler). Geheimnisse gehören nie hierher (`password` steht außerhalb).
    static func validate(kind: DMSSourceKind, config raw: [String: Any], env: [String: String] = ProcessInfo.processInfo.environment) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        switch kind {
        case .mail:
            for k in raw.keys where !["host", "port", "username", "mailbox", "processed_mailbox", "interval_seconds", "include_body", "sender_contains", "subject_contains", "max_per_run", "keep_mail"].contains(k) {
                throw DMSError.invalid("config.\(k)", "unknown")
            }
            let host = try str(raw["host"], "config.host", max: 253)!.lowercased()
            guard host.range(of: "^[a-z0-9]([a-z0-9.:-]*[a-z0-9])?$", options: .regularExpression) != nil, hostAllowed(host, env: env) else { throw DMSError.invalid("config.host") }
            // WP-H10 (Befund 2): nur DNS-Namen. Bei IP-Literalen entfällt die Hostprüfung des Zertifikats (kein SNI, kein Namensabgleich); Zertifikate mit IP-SAN sind bei IMAP-Anbietern unüblich,
            // und der Connect läuft ohnehin über eine vorab geprüfte IP mit dem DNS-Namen als TLS-Servernamen (Befund 3). Entscheidung: ablehnen statt SAN-IP prüfen.
            guard NetworkTarget.parseLiteral(host) == nil else { throw DMSError.invalid("config.host", "ip_literal_not_allowed") }
            // WP-H10 (Befund 3): interne Namen sind ohne `DMS_ALLOW_INTERNAL_TARGETS=true` gesperrt (die maßgebliche Prüfung folgt per Auflösung vor jedem Connect).
            guard NetworkTargetPolicy.fromEnvironment(env).allowInternal || !NetworkTarget.isInternalName(host) else { throw DMSError.invalid("config.host", "target_not_allowed") }
            if let flag = raw["include_body"], !(flag is Bool) { throw DMSError.invalid("config.include_body") }
            let port = try int(raw["port"], "config.port", range: 1...65535, default: 993)
            guard IMAPOptions.allowedPorts(env).contains(port) else { throw DMSError.invalid("config.port", "port_not_allowed") }   // WP-H10: nur 993 oder `DMS_MAIL_PORT_ALLOWLIST`
            let config = MailSourceConfig(
                host: host, port: port,
                username: try str(raw["username"], "config.username", max: 256)!,
                mailbox: try ascii(try str(raw["mailbox"], "config.mailbox", max: 200, required: false), "config.mailbox") ?? "INBOX",
                processed_mailbox: try ascii(try str(raw["processed_mailbox"], "config.processed_mailbox", max: 200, required: false), "config.processed_mailbox"),
                interval_seconds: try int(raw["interval_seconds"], "config.interval_seconds", range: 30...86400, default: 120),
                include_body: raw["include_body"] as? Bool ?? false,
                sender_contains: try ascii(try str(raw["sender_contains"], "config.sender_contains", max: 100, required: false), "config.sender_contains"),
                subject_contains: try ascii(try str(raw["subject_contains"], "config.subject_contains", max: 100, required: false), "config.subject_contains"),
                max_per_run: try int(raw["max_per_run"], "config.max_per_run", range: 1...200, default: 50),
                keep_mail: try keepMail(raw["keep_mail"]))
            return try encoder.encode(config)
        case .folder:
            for k in raw.keys where !["path", "interval_seconds", "stable_seconds"].contains(k) { throw DMSError.invalid("config.\(k)", "unknown") }
            let path = try str(raw["path"], "config.path", max: 200)!
            // nur relativ zum konfigurierten Mount (`DMS_FOLDER_ROOT` im Worker): keine absoluten Pfade, kein `..`, keine versteckten Namen
            guard path.range(of: "^[A-Za-z0-9_][A-Za-z0-9_. -]*(/[A-Za-z0-9_][A-Za-z0-9_. -]*)*$", options: .regularExpression) != nil,
                  !path.split(separator: "/").contains(where: { $0 == ".." || $0 == "." }) else { throw DMSError.invalid("config.path") }
            let config = FolderSourceConfig(path: path, interval_seconds: try int(raw["interval_seconds"], "config.interval_seconds", range: 10...86400, default: 60),
                                            stable_seconds: try int(raw["stable_seconds"], "config.stable_seconds", range: 0...3600, default: 10))
            return try encoder.encode(config)
        }
    }

    private static func keepMail(_ raw: Any?) throws -> String {
        guard let raw else { return "relevant" }
        guard let v = raw as? String, ["relevant", "always", "never"].contains(v) else { throw DMSError.invalid("config.keep_mail") }
        return v
    }

    static func out(_ r: any SQLRow) throws -> DMSSourceOut {
        let config = (try? JSONDecoder().decode([String: DMSFieldValue].self, from: Data(try r.decode(column: "config", as: String.self).utf8))) ?? [:]
        let stats = try r.decode(column: "last_stats", as: String?.self).flatMap { try? JSONDecoder().decode([String: Int].self, from: Data($0.utf8)) }
        return DMSSourceOut(id: try r.decode(column: "id", as: UUID.self), kind: try r.decode(column: "kind", as: String.self), name: try r.decode(column: "name", as: String.self),
                            config: config, has_secret: try r.decode(column: "has_secret", as: Bool.self), enabled: try r.decode(column: "enabled", as: Bool.self),
                            runs: try r.decode(column: "runs", as: Int64.self), last_run_at: try r.decode(column: "last_run_at", as: Date?.self).map(iso),
                            last_status: try r.decode(column: "last_status", as: String?.self), last_error: try r.decode(column: "last_error", as: String?.self), last_stats: stats,
                            created_at: iso(try r.decode(column: "created_at", as: Date.self)), updated_at: iso(try r.decode(column: "updated_at", as: Date.self)))
    }

    // MARK: CRUD

    static func list(tenant: UUID, on s: any SQLDatabase) async throws -> [DMSSourceOut] {
        try await s.raw("SELECT \(unsafeRaw: columns) FROM dms_sources WHERE tenant_id = \(bind: tenant) ORDER BY created_at, id").all().map(out)
    }

    static func load(_ id: UUID, tenant: UUID, on s: any SQLDatabase) async throws -> DMSSourceOut? {
        try await s.raw("SELECT \(unsafeRaw: columns) FROM dms_sources WHERE tenant_id = \(bind: tenant) AND id = \(bind: id)").first().map(out)
    }

    static func row(_ id: UUID, tenant: UUID, on s: any SQLDatabase) async throws -> DMSSourceRow? {
        guard let r = try await s.raw("SELECT id, kind, name, config::text AS config, secret_enc, enabled, created_by FROM dms_sources WHERE tenant_id = \(bind: tenant) AND id = \(bind: id)").first(),
              let kind = DMSSourceKind(rawValue: try r.decode(column: "kind", as: String.self)) else { return nil }
        return DMSSourceRow(id: id, tenant: tenant, kind: kind, name: try r.decode(column: "name", as: String.self), configJSON: try r.decode(column: "config", as: String.self),
                            secretEnc: try r.decode(column: "secret_enc", as: String?.self), enabled: try r.decode(column: "enabled", as: Bool.self), createdBy: try r.decode(column: "created_by", as: UUID.self))
    }

    private static func name(_ v: Any?) throws -> String {
        guard let n = try str(v, "name", max: 100) else { throw DMSError.invalid("name", "required") }
        let t = n.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { throw DMSError.invalid("name") }
        return t
    }

    private static func conflictOnName(_ error: any Error) -> any Error {
        if let e = error as? any DatabaseError, e.isConstraintFailure { return HubError(.conflict, "conflict", detail: "name_taken") }
        return error
    }

    static func create(_ body: [String: Any], tenant: UUID, actor: UUID, requestID: String, box: SecretBox?, on db: any Database) async throws -> DMSSourceOut {
        for k in body.keys where !["kind", "name", "config", "password", "enabled"].contains(k) { throw DMSError.invalid(k, "unknown") }
        guard let kindRaw = body["kind"] as? String, let kind = DMSSourceKind(rawValue: kindRaw) else { throw DMSError.invalid("kind") }
        let name = try name(body["name"])
        guard let rawConfig = body["config"] as? [String: Any] else { throw DMSError.invalid("config", "required") }
        let config = try validate(kind: kind, config: rawConfig)
        let enabled: Bool
        if let e = body["enabled"] { guard let b = e as? Bool else { throw DMSError.invalid("enabled") }; enabled = b } else { enabled = true }
        let password: String?
        if kind == .mail {
            guard let p = body["password"] as? String, !p.isEmpty, p.utf8.count <= 512 else { throw DMSError.invalid("password", "required") }
            password = p
            guard box != nil else { throw DMSError.invalid("password", "secret_key_missing") }
        } else if body["password"] != nil { throw DMSError.invalid("password", "not_applicable") } else { password = nil }
        let id = UUID()
        do {
            return try await dmsTransaction(db) { _, s in
                let count = try await s.raw("SELECT count(*)::bigint AS n FROM dms_sources WHERE tenant_id = \(bind: tenant)").first()?.decode(column: "n", as: Int64.self) ?? 0
                guard count < Int64(maxPerTenant) else { throw HubError(.conflict, "conflict", detail: "source_limit") }
                let secret = try password.map { try box!.seal($0, tenant: tenant, source: id) }
                try await s.raw("""
                    INSERT INTO dms_sources (id, tenant_id, kind, name, config, secret_enc, enabled, created_by)
                    VALUES (\(bind: id), \(bind: tenant), \(bind: kind.rawValue), \(bind: name), \(bind: String(decoding: config, as: UTF8.self))::text::jsonb, \(bind: secret), \(bind: enabled), \(bind: actor))
                    """).run()
                try await AuditLog.record(AuditEvent(action: "dms.source.created", actor: actor, tenant: tenant, subjectType: "dms.source", subjectID: id.uuidString,
                                                     meta: ["kind": .safe(kind.rawValue), "enabled": .number(enabled ? 1 : 0)], requestID: requestID), on: s)
                if enabled { try await schedule(source: id, tenant: tenant, delaySeconds: 0, expedite: true, on: s) }
                guard let out = try await load(id, tenant: tenant, on: s) else { throw Abort(.internalServerError) }
                return out
            }
        } catch { throw conflictOnName(error) }
    }

    static func update(_ id: UUID, body: [String: Any], tenant: UUID, actor: UUID, requestID: String, box: SecretBox?, on db: any Database) async throws -> DMSSourceOut {
        for k in body.keys where !["name", "config", "password", "enabled"].contains(k) { throw DMSError.invalid(k, "unknown") }
        nonisolated(unsafe) let body = body   // nur lesend, innerhalb einer Anfrage
        do {
            return try await dmsTransaction(db) { _, s in
                guard let current = try await s.raw("SELECT kind, enabled FROM dms_sources WHERE tenant_id = \(bind: tenant) AND id = \(bind: id) FOR UPDATE").first(),
                      let kind = DMSSourceKind(rawValue: try current.decode(column: "kind", as: String.self)) else { throw DMSError.notFound }
                let wasEnabled = try current.decode(column: "enabled", as: Bool.self)
                var changed: [String] = []
                if body["name"] != nil {
                    try await s.raw("UPDATE dms_sources SET name = \(bind: try name(body["name"])) WHERE tenant_id = \(bind: tenant) AND id = \(bind: id)").run(); changed.append("name")
                }
                if let raw = body["config"] {
                    guard let dict = raw as? [String: Any] else { throw DMSError.invalid("config") }
                    let config = try validate(kind: kind, config: dict)
                    try await s.raw("UPDATE dms_sources SET config = \(bind: String(decoding: config, as: UTF8.self))::text::jsonb WHERE tenant_id = \(bind: tenant) AND id = \(bind: id)").run(); changed.append("config")
                }
                if let p = body["password"] {
                    guard kind == .mail else { throw DMSError.invalid("password", "not_applicable") }
                    guard let pw = p as? String, !pw.isEmpty, pw.utf8.count <= 512 else { throw DMSError.invalid("password") }
                    guard let box else { throw DMSError.invalid("password", "secret_key_missing") }
                    try await s.raw("UPDATE dms_sources SET secret_enc = \(bind: try box.seal(pw, tenant: tenant, source: id)) WHERE tenant_id = \(bind: tenant) AND id = \(bind: id)").run(); changed.append("password")
                }
                var enabled = wasEnabled
                if let e = body["enabled"] {
                    guard let b = e as? Bool else { throw DMSError.invalid("enabled") }
                    enabled = b
                    try await s.raw("UPDATE dms_sources SET enabled = \(bind: b) WHERE tenant_id = \(bind: tenant) AND id = \(bind: id)").run(); changed.append("enabled")
                }
                try await s.raw("UPDATE dms_sources SET updated_at = now() WHERE tenant_id = \(bind: tenant) AND id = \(bind: id)").run()
                try await AuditLog.record(AuditEvent(action: "dms.source.updated", actor: actor, tenant: tenant, subjectType: "dms.source", subjectID: id.uuidString,
                                                     meta: ["changed": .number(Int64(changed.count)), "enabled": .number(enabled ? 1 : 0)], requestID: requestID), on: s)
                if enabled { try await schedule(source: id, tenant: tenant, delaySeconds: 0, expedite: !wasEnabled || changed.contains("config") || changed.contains("password"), on: s) }
                guard let out = try await load(id, tenant: tenant, on: s) else { throw DMSError.notFound }
                return out
            }
        } catch { throw conflictOnName(error) }
    }

    static func delete(_ id: UUID, tenant: UUID, actor: UUID, requestID: String, on db: any Database) async throws {
        try await dmsTransaction(db) { _, s in
            guard let row = try await s.raw("SELECT kind FROM dms_sources WHERE tenant_id = \(bind: tenant) AND id = \(bind: id) FOR UPDATE").first() else { throw DMSError.notFound }
            try await s.raw("DELETE FROM dms_sources WHERE tenant_id = \(bind: tenant) AND id = \(bind: id)").run()   // Idempotenz- und Messdaten per CASCADE
            try await AuditLog.record(AuditEvent(action: "dms.source.deleted", actor: actor, tenant: tenant, subjectType: "dms.source", subjectID: id.uuidString,
                                                 meta: ["kind": .safe(try row.decode(column: "kind", as: String.self))], requestID: requestID), on: s)
        }
    }

    // MARK: Zeitplan (Job-Kette)

    /// Legt höchstens einen offenen Job je Quelle an. Unter Zeilensperre der Quelle; `expedite` zieht einen schon wartenden Job auf „jetzt“.
    @discardableResult
    static func schedule(source id: UUID, tenant: UUID, delaySeconds: Int, expedite: Bool, afterJob current: UUID? = nil, on s: any SQLDatabase) async throws -> UUID? {
        guard let row = try await s.raw("SELECT kind, enabled, scheduled_job_id FROM dms_sources WHERE tenant_id = \(bind: tenant) AND id = \(bind: id) FOR UPDATE").first(),
              try row.decode(column: "enabled", as: Bool.self), let kind = DMSSourceKind(rawValue: try row.decode(column: "kind", as: String.self)) else { return nil }
        if let scheduled = try row.decode(column: "scheduled_job_id", as: UUID?.self), scheduled != current,
           try await s.raw("SELECT 1 AS x FROM jobs WHERE id = \(bind: scheduled) AND state IN ('queued', 'running')").first() != nil {
            if expedite { try await s.raw("UPDATE jobs SET run_at = now() WHERE id = \(bind: scheduled) AND state = 'queued' AND run_at > now()").run() }
            return nil
        }
        let payload = String(decoding: try JSONEncoder().encode(SourcePayload(source_id: id, tenant_id: tenant)), as: UTF8.self)
        let job = try await JobService(s).enqueue(kind: kind.jobKind, payload: payload, priority: 0)
        try await s.raw("UPDATE jobs SET run_at = now() + make_interval(secs => \(bind: delaySeconds)) WHERE id = \(bind: job)").run()
        try await s.raw("UPDATE dms_sources SET scheduled_job_id = \(bind: job) WHERE tenant_id = \(bind: tenant) AND id = \(bind: id)").run()
        return job
    }

    /// „Jetzt ausführen“ (Recht `dms.source.manage`): zieht den wartenden Job vor oder legt einen an.
    static func runNow(_ id: UUID, tenant: UUID, actor: UUID, requestID: String, on db: any Database) async throws -> DMSSourceOut {
        try await dmsTransaction(db) { _, s in
            guard let row = try await s.raw("SELECT enabled FROM dms_sources WHERE tenant_id = \(bind: tenant) AND id = \(bind: id)").first() else { throw DMSError.notFound }
            guard try row.decode(column: "enabled", as: Bool.self) else { throw HubError(.conflict, "conflict", detail: "source_disabled") }
            try await schedule(source: id, tenant: tenant, delaySeconds: 0, expedite: true, on: s)
            try await AuditLog.record(AuditEvent(action: "dms.source.run_requested", actor: actor, tenant: tenant, subjectType: "dms.source", subjectID: id.uuidString, requestID: requestID), on: s)
            guard let out = try await load(id, tenant: tenant, on: s) else { throw DMSError.notFound }
            return out
        }
    }

    // MARK: Laufprotokoll

    struct SourcePayload: Codable, Sendable { let source_id: UUID; let tenant_id: UUID }

    /// Hält das Ergebnis des Laufs fest (`last_*`, `runs`) und erzeugt bei Eingang oder Fehlern einen Audit-Eintrag ohne Nutzdaten.
    static func record(_ id: UUID, tenant: UUID, stats: [String: Int], error: String?, on s: any SQLDatabase) async throws {
        let json = String(decoding: try JSONEncoder().encode(stats), as: UTF8.self)
        let code = error.flatMap { $0.range(of: "^[a-z0-9_.]{1,64}$", options: .regularExpression) != nil ? $0 : "error" }
        try await s.raw("""
            UPDATE dms_sources SET runs = runs + 1, last_run_at = now(), last_status = \(bind: code == nil ? "ok" : "error"), last_error = \(bind: code),
              last_stats = \(bind: json)::text::jsonb WHERE tenant_id = \(bind: tenant) AND id = \(bind: id)
            """).run()
        if error != nil || (stats["ingested"] ?? 0) > 0 || (stats["failed"] ?? 0) > 0 {
            var meta: [String: AuditValue] = ["ok": .number(error == nil ? 1 : 0)]
            for (k, v) in stats { meta[k] = .number(Int64(v)) }
            if let code { meta["error"] = .safe(code) }
            try await AuditLog.record(AuditEvent(action: "dms.source.run", tenant: tenant, subjectType: "dms.source", subjectID: id.uuidString, meta: meta), on: s)
        }
    }

    /// Wirksamkeit des DMS-Moduls für den Mandanten (Betreiber an, Mandant an) direkt aus der Datenbank; der Worker kennt die Modulliste nicht.
    static func dmsActive(tenant: UUID, on s: any SQLDatabase) async throws -> Bool {
        try await s.raw("""
            SELECT EXISTS (SELECT 1 FROM tenant_modules WHERE tenant_id = \(bind: tenant) AND module_key = 'dms' AND enabled)
               AND NOT EXISTS (SELECT 1 FROM installation_modules WHERE module_key = 'dms' AND NOT enabled) AS active
            """).first()?.decode(column: "active", as: Bool.self) ?? false
    }
}
