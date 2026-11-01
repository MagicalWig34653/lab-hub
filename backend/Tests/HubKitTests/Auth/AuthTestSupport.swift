import XCTVapor
import Fluent
import SQLKit
import Crypto
@testable import HubKit

/// Alle Hub-Tabellen in abhängigkeitssicherer Reihenfolge (für saubere Testzustände). Nur synthetische Daten.
enum HubTestDB {
    static let tables = ["audit_log", "rate_limit_events", "auth_challenges", "recovery_codes", "invitations", "sessions",
                         "passkey_credentials", "users", "object_chunks", "files", "jobs", "idempotency_keys", "counters",
                         "schema_version", "_fluent_migrations"]
    static func dropAll(_ db: any SQLDatabase) async throws {
        for t in tables { try await db.raw("DROP TABLE IF EXISTS \(unsafeRaw: t) CASCADE").run() }
    }
    static var env: [String: String] {
        let e = ProcessInfo.processInfo.environment
        return ["DB_HOST": e["TEST_DB_HOST"] ?? "127.0.0.1", "DB_PORT": e["TEST_DB_PORT"] ?? "15432",
                "DB_NAME": e["TEST_DB_NAME"] ?? "labhub", "DB_USER": e["TEST_DB_USER"] ?? "labhub",
                "DB_PASSWORD": e["TEST_DB_PASSWORD"] ?? "devtest-pw", "DB_TLS": "disable"]
    }
}

/// Software-Authenticator (ES256) als Testhilfe: erzeugt Registrierungs- und Anmeldedaten im Wire-Format der Browser-API.
/// Eigene Umsetzung nach dem Vorbild von timetrack-backend `SoftwareAuthenticator.swift` (nur gelesen).
struct VirtualAuthenticator: @unchecked Sendable {
    var rpID = "localhost"
    var origin = "http://localhost:18080"
    let privateKey = P256.Signing.PrivateKey()
    let credentialID = Data((0..<32).map { _ in UInt8.random(in: 0...255) })

    func clientData(challenge: String, type: String) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["type": type, "challenge": challenge, "origin": origin, "crossOrigin": false], options: [.sortedKeys])
    }

    /// `publicKey`: das Objekt `public_key` aus der Optionsantwort. Rückgabe: Wert für `credential`.
    func registration(_ publicKey: [String: Any], flags: UInt8 = 0x45) throws -> [String: Any] {
        let challenge = publicKey["challenge"] as! String
        let xy = Array(privateKey.publicKey.x963Representation.dropFirst())
        let cose: [UInt8] = [0xa5, 0x01, 0x02, 0x03, 0x26, 0x20, 0x01, 0x21] + bytes(Array(xy.prefix(32))) + [0x22] + bytes(Array(xy.suffix(32)))
        let auth = Array(SHA256.hash(data: Data(rpID.utf8))) + [flags, 0, 0, 0, 0] + Array(repeating: UInt8(0), count: 16) + [0, 32] + Array(credentialID) + cose
        let attestation = [UInt8(0xa3)] + text("fmt") + text("none") + text("attStmt") + [0xa0] + text("authData") + bytes(auth)
        let client = try clientData(challenge: challenge, type: "webauthn.create")
        return ["id": credentialID.base64URL, "rawId": credentialID.base64URL, "type": "public-key",
                "response": ["clientDataJSON": client.base64URL, "attestationObject": Data(attestation).base64URL, "transports": ["internal"]]]
    }

    func assertion(_ publicKey: [String: Any], userID: String, count: UInt32, signWith key: P256.Signing.PrivateKey? = nil) throws -> [String: Any] {
        let challenge = publicKey["challenge"] as! String
        let client = try clientData(challenge: challenge, type: "webauthn.get")
        let counter = [UInt8(count >> 24), UInt8(truncatingIfNeeded: count >> 16), UInt8(truncatingIfNeeded: count >> 8), UInt8(truncatingIfNeeded: count)]
        let auth = Data(Array(SHA256.hash(data: Data(rpID.utf8))) + [5] + counter)  // UP | UV
        let signature = try (key ?? privateKey).signature(for: auth + Data(SHA256.hash(data: client))).derRepresentation
        return ["id": credentialID.base64URL, "rawId": credentialID.base64URL, "type": "public-key",
                "response": ["clientDataJSON": client.base64URL, "authenticatorData": auth.base64URL, "signature": signature.base64URL,
                             "userHandle": Data(userID.utf8).base64URL]]
    }

    private func text(_ s: String) -> [UInt8] { [0x60 + UInt8(s.utf8.count)] + Array(s.utf8) }
    private func bytes(_ v: [UInt8]) -> [UInt8] {
        (v.count < 24 ? [0x40 + UInt8(v.count)] : v.count < 256 ? [0x58, UInt8(v.count)] : [0x59, UInt8(v.count >> 8), UInt8(truncatingIfNeeded: v.count)]) + v
    }
}

struct Resp: @unchecked Sendable {
    let status: HTTPStatus
    let json: [String: Any]
    let headers: HTTPHeaders
    var problemCode: String? { json["code"] as? String }
}

final class RespBox: @unchecked Sendable { var value: Resp? }

struct TestSession: @unchecked Sendable {
    let token: String
    let userID: String
    let csrf: String
    let handle: String
}

let setupToken = "synthetic-setup-token-for-tests"

/// Zwei Instanzen (gleiche Datenbank) für Zustandstests; Hilfsfunktionen für HTTP und Passkey-Abläufe.
class AuthTestCase: XCTestCase, @unchecked Sendable {
    var app1: Application!
    var app2: Application!
    var db: (any SQLDatabase)!

    static func makeEnv() -> [String: String] {
        var env = HubTestDB.env
        env["PUBLIC_URL"] = "http://localhost:18080"; env["WEBAUTHN_RP_ID"] = "localhost"; env["SETUP_TOKEN"] = setupToken
        return env
    }

    func makeApp() async throws -> Application {
        let app = try await Application.make(.testing)
        try configure(app, environment: Self.makeEnv())
        app.authSettings?.rateLimitMax = 10_000  // einzelne Tests setzen niedrige Werte
        return app
    }

    override func setUp() async throws {
        app1 = try await makeApp()
        do { _ = try await (app1.db(.psql) as! any SQLDatabase).raw("SELECT 1").all() } catch {
            try await app1.asyncShutdown(); app1 = nil
            throw XCTSkip("Keine Postgres-Datenbank erreichbar")
        }
        db = (app1.db(.psql) as! any SQLDatabase)
        try await HubTestDB.dropAll(db)
        try await migrateWithLock(app1)
        app2 = try await makeApp()
    }

    override func tearDown() async throws {
        if let app2 { try await app2.asyncShutdown() }
        if let app1 { try await app1.asyncShutdown() }
    }

    func call(_ app: Application, _ method: HTTPMethod, _ path: String, json: Any? = nil, token: String? = nil,
              headers extra: [String: String] = [:]) async throws -> Resp {
        var headers = HTTPHeaders()
        if let token { headers.bearerAuthorization = BearerAuthorization(token: token) }
        for (k, v) in extra { headers.replaceOrAdd(name: k, value: v) }
        var body: ByteBuffer?
        if let json {
            body = ByteBuffer(data: try JSONSerialization.data(withJSONObject: json))
            headers.contentType = .json
        }
        let box = RespBox()
        try await app.test(method, path, headers: headers, body: body) { res async throws in
            let obj = (try? JSONSerialization.jsonObject(with: Data(buffer: res.body))) as? [String: Any] ?? [:]
            box.value = Resp(status: res.status, json: obj, headers: res.headers)
        }
        return box.value!
    }

    /// Erster Nutzer über das Setup-Token (AK-K1-1).
    @discardableResult
    func bootstrap(_ app: Application, _ auth: VirtualAuthenticator, handle: String = "alice") async throws -> TestSession {
        let o = try await call(app, .POST, "api/v1/auth/bootstrap/options", json: ["setup_token": setupToken, "handle": handle, "display_name": "Alice Synthetic"])
        XCTAssertEqual(o.status, .ok)
        let credential = try auth.registration(o.json["public_key"] as! [String: Any])
        let v = try await call(app, .POST, "api/v1/auth/bootstrap/verify", json: ["challenge_id": o.json["challenge_id"]!, "credential": credential],
                               headers: ["X-Auth-Transport": "bearer"])
        XCTAssertEqual(v.status, .created, "\(v.json)")
        return session(v, handle: handle)
    }

    func session(_ r: Resp, handle: String) -> TestSession {
        let user = r.json["user"] as? [String: Any] ?? [:]
        return TestSession(token: r.json["token"] as? String ?? "", userID: user["id"] as? String ?? "", csrf: r.json["csrf_token"] as? String ?? "", handle: handle)
    }

    /// Anmeldung per Passkey; `count` ist der Signaturzähler des Authenticators.
    func login(_ app: Application, _ auth: VirtualAuthenticator, userID: String, handle: String, count: UInt32) async throws -> Resp {
        let o = try await call(app, .POST, "api/v1/auth/login/options")
        XCTAssertEqual(o.status, .ok)
        let credential = try auth.assertion(o.json["public_key"] as! [String: Any], userID: userID, count: count)
        return try await call(app, .POST, "api/v1/auth/login/verify", json: ["challenge_id": o.json["challenge_id"]!, "credential": credential],
                              headers: ["X-Auth-Transport": "bearer"])
    }

    func invite(_ app: Application, by s: TestSession) async throws -> String {
        let r = try await call(app, .POST, "api/v1/invitations", json: [:], token: s.token)
        XCTAssertEqual(r.status, .created, "\(r.json)")
        return r.json["token"] as! String
    }

    /// Registrierung per Einladung; Rückgabe: Antwort des Verify-Schritts.
    func register(_ app: Application, _ auth: VirtualAuthenticator, invite: String, handle: String) async throws -> Resp {
        let o = try await call(app, .POST, "api/v1/auth/register/options", json: ["invite_token": invite, "handle": handle, "display_name": "Bob Synthetic"])
        guard o.status == .ok else { return o }
        let credential = try auth.registration(o.json["public_key"] as! [String: Any])
        return try await call(app, .POST, "api/v1/auth/register/verify", json: ["challenge_id": o.json["challenge_id"]!, "credential": credential],
                              headers: ["X-Auth-Transport": "bearer"])
    }

    func scalar<T: Decodable>(_ sqlText: String, as: T.Type) async throws -> T {
        try await db.raw(SQLQueryString(sqlText)).first()!.decode(column: "v", as: T.self)
    }
}
