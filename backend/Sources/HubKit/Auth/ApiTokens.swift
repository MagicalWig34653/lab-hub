import Vapor
import Fluent
import SQLKit
import Foundation

// WP-D4 (F-05, MINIMALSTAND): persönliche API-Tokens mit Scope. Nur das Nötige für Scanner, Skripte und Share-Sheet:
// Tabelle `api_tokens` (nur der SHA-256 des Tokens wird gespeichert), Scope, Pflicht-Ablauf, Widerruf, Audit, Erstellen/Listen/Widerrufen.
// Ein API-Token ersetzt NIE eine Sitzung: es wird nur von Routen akzeptiert, die ausdrücklich einen Scope verlangen (`ApiTokenModuleGuard`),
// nie von `SessionMiddleware`. Das Token hat eine feste Länge (47 Zeichen, Präfix `lhp_`), Sitzungstokens 43 Zeichen: keine Verwechslung.
// Nicht enthalten (spätere WPs): Scopes außer `dms.upload`, Mandantenbindung des Tokens, Nutzungsprotokoll je Aufruf, Rotation, OAuth.

struct CreateApiTokens: AsyncMigration {
    let name = "020_api_tokens"
    func prepare(on db: any Database) async throws {
        try await run(db, [
            """
            CREATE TABLE api_tokens (id uuid PRIMARY KEY DEFAULT gen_random_uuid(), user_id uuid NOT NULL REFERENCES users (id),
              name text NOT NULL CHECK (char_length(name) BETWEEN 1 AND 80),
              token_hash text NOT NULL UNIQUE CHECK (token_hash ~ '^[0-9a-f]{64}$'),
              scopes text[] NOT NULL CHECK (cardinality(scopes) >= 1),
              expires_at timestamptz NOT NULL, revoked_at timestamptz, last_used_at timestamptz,
              created_at timestamptz NOT NULL DEFAULT now())
            """,
            "CREATE INDEX api_tokens_user ON api_tokens (user_id, created_at)"])
    }
    func revert(on db: any Database) async throws { try await run(db, ["DROP TABLE api_tokens"]) }
}

/// JSON-Objekt mit nativen Swift-Werten (Bool, Int, Double, String, Array, Dictionary, NSNull). `JSONSerialization` liefert Zahlen als NSNumber, bei denen
/// `0 as? Bool` und `true as? Int` gelingen; Eingabeprüfungen müssen aber Typen unterscheiden.
enum StrictJSON: Decodable {
    case null, bool(Bool), int(Int), double(Double), string(String), array([StrictJSON]), object([String: StrictJSON])
    init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null } else if let b = try? c.decode(Bool.self) { self = .bool(b) } else if let i = try? c.decode(Int.self) { self = .int(i) }
        else if let d = try? c.decode(Double.self) { self = .double(d) } else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([StrictJSON].self) { self = .array(a) } else { self = .object(try c.decode([String: StrictJSON].self)) }
    }
    var native: Any {
        switch self {
        case .null: NSNull()
        case .bool(let b): b
        case .int(let i): i
        case .double(let d): d
        case .string(let s): s
        case .array(let a): a.map(\.native)
        case .object(let o): o.mapValues(\.native)
        }
    }
    /// Der Body als Objekt; `nil`, wenn er kein JSON-Objekt ist.
    static func object(_ data: Data) -> [String: Any]? {
        guard case .object(let o)? = try? JSONDecoder().decode(StrictJSON.self, from: data) else { return nil }
        return o.mapValues(\.native)
    }
}

struct ApiTokenIDKey: StorageKey { typealias Value = UUID }

enum ApiTokens {
    static let prefix = "lhp_"
    static let scopes: Set<String> = ["dms.upload"]
    static let defaultDays = 365, maxDays = 730

    static func newToken() -> String { prefix + AuthSecrets.token() }   // 4 + 43 Zeichen

    struct Out: Content {
        let id: UUID
        let name: String
        let scopes: [String]
        let expires_at: String
        let created_at: String
        let last_used_at: String?
        let revoked_at: String?
        var token: String?
    }

    private static func out(_ r: any SQLRow) throws -> Out {
        Out(id: try r.decode(column: "id", as: UUID.self), name: try r.decode(column: "name", as: String.self),
            scopes: try r.decode(column: "scopes", as: [String].self), expires_at: iso(try r.decode(column: "expires_at", as: Date.self)),
            created_at: iso(try r.decode(column: "created_at", as: Date.self)), last_used_at: try r.decode(column: "last_used_at", as: Date?.self).map(iso),
            revoked_at: try r.decode(column: "revoked_at", as: Date?.self).map(iso), token: nil)
    }

    static func list(user: UUID, on s: any SQLDatabase) async throws -> [Out] {
        try await s.raw("SELECT id, name, scopes, expires_at, created_at, last_used_at, revoked_at FROM api_tokens WHERE user_id = \(bind: user) ORDER BY created_at, id").all().map(out)
    }

    /// Erstellt ein Token; der Klartext steht nur in dieser Antwort.
    static func create(user: UUID, body: [String: Any], requestID: String, on db: any Database) async throws -> Out {
        for key in body.keys where !["name", "scopes", "expires_in_days"].contains(key) { throw DMSError.invalid(key, "unknown") }
        guard let name = (body["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), (1...80).contains(name.count),
              !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw DMSError.invalid("name") }
        guard let requested = body["scopes"] as? [String], !requested.isEmpty, requested.count <= 8 else { throw DMSError.invalid("scopes") }
        guard Set(requested).isSubset(of: scopes) else { throw DMSError.invalid("scopes", "unknown_scope") }
        let days: Int
        if let raw = body["expires_in_days"] {
            guard let d = raw as? Int, (1...maxDays).contains(d) else { throw DMSError.invalid("expires_in_days") }
            days = d
        } else { days = defaultDays }
        let token = newToken()
        let scopeList = Array(Set(requested)).sorted()
        return try await inTransaction(db) { s in
            guard let row = try await s.raw("""
                INSERT INTO api_tokens (user_id, name, token_hash, scopes, expires_at)
                VALUES (\(bind: user), \(bind: name), \(bind: AuthSecrets.hash(token)), \(bind: scopeList)::text[], now() + (\(bind: days)::bigint * interval '1 day'))
                RETURNING id, name, scopes, expires_at, created_at, last_used_at, revoked_at
                """).first() else { throw Abort(.internalServerError) }
            var result = try out(row)
            result.token = token
            try await AuditLog.record(AuditEvent(action: "auth.api_token.created", actor: user, subjectType: "api_token", subjectID: result.id.uuidString,
                                                 meta: ["scopes": .number(Int64(scopeList.count)), "days": .number(Int64(days))], requestID: requestID), on: s)
            return result
        }
    }

    /// Widerruf; idempotent. Fremdes oder unbekanntes Token: `false` (404).
    static func revoke(_ id: UUID, user: UUID, requestID: String, on db: any Database) async throws -> Bool {
        try await inTransaction(db) { s in
            guard let row = try await s.raw("SELECT revoked_at FROM api_tokens WHERE id = \(bind: id) AND user_id = \(bind: user) FOR UPDATE").first() else { return false }
            if try row.decode(column: "revoked_at", as: Date?.self) == nil {
                try await s.raw("UPDATE api_tokens SET revoked_at = now() WHERE id = \(bind: id)").run()
                try await AuditLog.record(AuditEvent(action: "auth.api_token.revoked", actor: user, subjectType: "api_token", subjectID: id.uuidString, requestID: requestID), on: s)
            }
            return true
        }
    }

    /// Prüft das Token gegen die Datenbank (jede Instanz, kein Cache: Widerruf wirkt sofort). `nil` bei unbekannt, widerrufen, abgelaufen,
    /// ohne den Scope oder deaktiviertem Nutzer.
    static func authenticate(_ bearer: String, scope: String, on db: any Database) async throws -> (AuthContext, UUID)? {
        guard bearer.hasPrefix(prefix), bearer.utf8.count == prefix.utf8.count + 43 else { return nil }
        let s = try sql(db)
        guard let row = try await s.raw("""
            SELECT t.id, t.expires_at, u.id AS user_id, u.handle, u.display_name, u.is_operator
            FROM api_tokens t JOIN users u ON u.id = t.user_id
            WHERE t.token_hash = \(bind: AuthSecrets.hash(bearer)) AND t.revoked_at IS NULL AND t.expires_at > now() AND u.disabled_at IS NULL
              AND \(bind: scope) = ANY (t.scopes)
            """).first() else { return nil }
        let id = try row.decode(column: "id", as: UUID.self)
        try await s.raw("UPDATE api_tokens SET last_used_at = now() WHERE id = \(bind: id) AND (last_used_at IS NULL OR last_used_at < now() - interval '60 seconds')").run()
        let user = AuthUser(id: try row.decode(column: "user_id", as: UUID.self), handle: try row.decode(column: "handle", as: String.self),
                            displayName: try row.decode(column: "display_name", as: String.self), isOperator: false)   // nie Betreiberrechte über ein Token
        return (AuthContext(sessionID: id, user: user, kind: .normal, expiresAt: try row.decode(column: "expires_at", as: Date.self), token: "", viaCookie: false), id)
    }
}

/// Guard für Modulrouten, die ein API-Token mit Scope akzeptieren. Reihenfolge wie `ModuleGuard`: ungültiges Token 401; kein Mitglied oder
/// unbekannter Mandant 404; Modul nicht wirksam 404 `module_disabled`; fehlende Modulberechtigung 403.
struct ApiTokenModuleGuard: AsyncMiddleware {
    let scope: String
    let module: ModuleKey
    let permission: String
    func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        guard let bearer = request.headers.bearerAuthorization?.token, let (context, tokenID) = try await ApiTokens.authenticate(bearer, scope: scope, on: request.db)
        else { throw HubError(.unauthorized, "unauthorized") }
        guard let tenant = request.parameters.get("tenant", as: UUID.self), let role = try await TenancyService.role(of: context.user.id, in: tenant, on: request.db)
        else { throw HubError(.notFound, "not_found") }
        let registry = request.application.hubModules
        guard try await ModuleService.statuses(registry, tenant: tenant, on: try sql(request.db)).first(where: { $0.key == module })?.effective == true
        else { throw HubError(.notFound, "module_disabled") }
        let modulePermissions = registry.permissions(of: role, module: module)
        guard modulePermissions.contains(permission) else { throw HubError(.forbidden, "forbidden") }
        request.storage[AuthContextKey.self] = context
        request.storage[ApiTokenIDKey.self] = tokenID
        request.storage[TenantContextKey.self] = TenantContext(tenantID: tenant, role: role, permissions: Permissions.of(role).union(modulePermissions))
        return try await next.respond(to: request)
    }
}

func registerApiTokenRoutes(_ app: Application) {
    // Nur Sitzungen (kein API-Token, keine Notfall-Sitzung): Tokens verwalten sich nicht selbst.
    let api = app.grouped("api", "v1").grouped(SessionMiddleware()).grouped(RequireSession()).grouped("auth", "api-tokens")
    api.get { req async throws -> Response in
        try jsonResponse(["items": try await ApiTokens.list(user: try req.requireAuth().user.id, on: try sql(req.db)).map { try JSONSerialization.jsonObject(with: JSONEncoder().encode($0)) }])
    }
    api.on(.POST) { req async throws -> Response in
        guard let buffer = req.body.data, let body = StrictJSON.object(Data(buffer: buffer)) else { throw DMSError.invalid("body") }
        let created = try await ApiTokens.create(user: try req.requireAuth().user.id, body: body, requestID: req.requestId, on: req.db)
        return try jsonResponse(try JSONSerialization.jsonObject(with: JSONEncoder().encode(created)), status: .created)
    }
    api.delete(":token") { req async throws -> Response in
        guard let id = req.parameters.get("token", as: UUID.self),
              try await ApiTokens.revoke(id, user: try req.requireAuth().user.id, requestID: req.requestId, on: req.db) else { throw HubError(.notFound, "not_found") }
        return Response(status: .noContent)
    }
}
