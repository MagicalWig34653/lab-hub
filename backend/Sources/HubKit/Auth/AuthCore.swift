import Vapor
import Fluent
import SQLKit
import Crypto
import Foundation

/// Einstellungen der Anmeldung (aus `HubConfig`; Zeiten in Sekunden). Tests dürfen Werte nach `configure` überschreiben.
public struct AuthSettings: Sendable {
    public var rpID: String
    public var rpName = "lab-hub"
    public var origin: String
    public var setupToken: String?
    public var sessionTTL = 30 * 24 * 3600
    public var recoverySessionTTL = 1800
    public var invitationTTL = 7 * 24 * 3600
    public var rateLimitMax = 20
    public var rateLimitWindow = 60
    public var secureCookies: Bool { origin.hasPrefix("https://") }

    /// `nil`, wenn weder `PUBLIC_URL` noch `WEBAUTHN_RP_ID` eine Herkunft ergeben (Auth-Routen antworten dann mit 503).
    public static func from(_ c: HubConfig) -> AuthSettings? {
        guard let publicURL = c.publicURL, let url = URL(string: publicURL), let scheme = url.scheme, let host = url.host else { return nil }
        let origin = "\(scheme)://\(host)" + (url.port.map { ":\($0)" } ?? "")
        var s = AuthSettings(rpID: c.webAuthnRPID ?? host, origin: origin)
        s.setupToken = c.setupToken
        return s
    }
}

enum SessionKind: String, Sendable { case normal, recovery }

struct AuthUser: Sendable {
    let id: UUID
    let handle: String
    let displayName: String
    let isAdmin: Bool
}

struct AuthContext: Sendable {
    let sessionID: UUID
    let user: AuthUser
    let kind: SessionKind
    let expiresAt: Date
    let token: String
    let viaCookie: Bool
}

enum AuthSecrets {
    static func token(bytes: Int = 32) -> String { Data((0..<bytes).map { _ in UInt8.random(in: 0...255) }).base64URL }
    static func hash(_ s: String) -> String { SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined() }
    /// Zeitkonstanter Vergleich.
    static func equal(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        return zip(x, y).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
    }
    static func csrf(_ token: String) -> String { hash("csrf:" + token) }

    static let recoveryAlphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
    /// `XXXXX-XXXXX-XXXXX` (75 Bit).
    static func recoveryCode() -> String {
        (0..<3).map { _ in String((0..<5).map { _ in recoveryAlphabet.randomElement()! }) }.joined(separator: "-")
    }
    static func recoveryHash(user: UUID, code: String) -> String {
        let normalized = code.uppercased().filter { recoveryAlphabet.contains($0) }
        return hash("recovery:\(user.uuidString):\(normalized)")
    }
}

extension Application {
    private struct SettingsKey: StorageKey { typealias Value = AuthSettings }
    private struct PasskeyKey: StorageKey { typealias Value = any PasskeyService }
    public var authSettings: AuthSettings? {
        get { storage[SettingsKey.self] }
        set { storage[SettingsKey.self] = newValue }
    }
    /// Austauschbar (Tests, Alternativbibliothek); Standard: `WebAuthnPasskeyService` aus den Einstellungen.
    public var passkeyService: (any PasskeyService)? {
        get { storage[PasskeyKey.self] }
        set { storage[PasskeyKey.self] = newValue }
    }

    func authService() throws -> AuthService {
        guard let s = authSettings else { throw HubError(.serviceUnavailable, "service_unavailable") }
        return AuthService(settings: s, passkeys: passkeyService ?? WebAuthnPasskeyService(rpID: s.rpID, rpName: s.rpName, origin: s.origin))
    }
}

/// Datenbank-Transaktion mit SQL-Zugriff.
func inTransaction<T: Sendable>(_ db: any Database, _ body: @escaping @Sendable (any SQLDatabase) async throws -> T) async throws -> T {
    try await db.transaction { tx in try await body(try sql(tx)) }
}

/// Rate-Limit in der Datenbank (instanzübergreifend, Zeit aus DB-`now()`). Ein Advisory-Lock je Schlüssel macht die Prüfung exakt.
struct RateLimiter: Sendable {
    let max: Int
    let windowSeconds: Int

    /// `true`, wenn der Aufruf zählt und erlaubt ist; `false`, wenn das Limit erreicht ist.
    func hit(_ key: String, on db: any Database) async throws -> Bool {
        let max = self.max, window = self.windowSeconds
        return try await inTransaction(db) { s in
            try await s.raw("SELECT pg_advisory_xact_lock(hashtextextended(\(bind: key), 0))").run()
            try await s.raw("DELETE FROM rate_limit_events WHERE key = \(bind: key) AND occurred_at < now() - (\(bind: window)::bigint * interval '1 second')").run()
            let row = try await s.raw("SELECT count(*)::bigint AS n FROM rate_limit_events WHERE key = \(bind: key)").first()
            let n = try row?.decode(column: "n", as: Int64.self) ?? 0
            guard n < Int64(max) else { return false }
            try await s.raw("INSERT INTO rate_limit_events (key) VALUES (\(bind: key))").run()
            return true
        }
    }
}

/// Zählt Anfragen an die Anmeldungs-Routen je Client-Adresse. Weitergeleitete Header werden nicht ausgewertet
/// (Vertrauensstellung zu Reverse Proxys ist eine offene Entscheidung, siehe Handoff WP-K1).
struct AuthRateLimitMiddleware: AsyncMiddleware {
    func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        let service = try request.application.authService()
        let client = request.remoteAddress?.ipAddress ?? "unknown"
        let limiter = RateLimiter(max: service.settings.rateLimitMax, windowSeconds: service.settings.rateLimitWindow)
        guard try await limiter.hit("auth:" + AuthSecrets.hash(client), on: request.db) else {
            throw HubError(.tooManyRequests, "too_many_requests", headers: ["Retry-After": String(service.settings.rateLimitWindow)])
        }
        return try await next.respond(to: request)
    }
}

struct AuthContextKey: StorageKey { typealias Value = AuthContext }

extension Request {
    var authContext: AuthContext? { storage[AuthContextKey.self] }
    func requireAuth() throws -> AuthContext {
        guard let c = authContext else { throw HubError(.unauthorized, "unauthorized") }
        return c
    }
}

let sessionCookieName = "lh_session"

/// Liest Sitzungstoken (Bearer oder Cookie) und prüft ihn gegen die Datenbank (jede Instanz, kein Cache: Widerruf wirkt sofort).
/// Cookie-Sitzungen brauchen bei schreibenden Methoden den Header `X-CSRF-Token`.
struct SessionMiddleware: AsyncMiddleware {
    func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        var token: String?, viaCookie = false
        if let bearer = request.headers.bearerAuthorization?.token { token = bearer }
        else if let cookie = request.cookies[sessionCookieName]?.string { token = cookie; viaCookie = true }
        if let token, token.utf8.count == 43 {
            let service = try request.application.authService()
            if let context = try await service.authenticate(token, viaCookie: viaCookie, on: request.db) {
                if viaCookie, ![.GET, .HEAD, .OPTIONS].contains(request.method) {
                    guard let header = request.headers.first(name: "X-CSRF-Token"), AuthSecrets.equal(header, AuthSecrets.csrf(token)) else {
                        throw HubError(.forbidden, "csrf_invalid")
                    }
                }
                request.storage[AuthContextKey.self] = context
            }
        }
        return try await next.respond(to: request)
    }
}

/// Verlangt eine gültige Sitzung. Notfall-Sitzungen (Recovery-Code) sind standardmäßig ausgeschlossen (Default-Deny).
struct RequireSession: AsyncMiddleware {
    var allowRecovery = false
    var admin = false
    func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        let c = try request.requireAuth()
        if c.kind == .recovery, !allowRecovery { throw HubError(.forbidden, "recovery_session_restricted") }
        if admin, !c.user.isAdmin { throw HubError(.forbidden, "forbidden") }
        return try await next.respond(to: request)
    }
}
