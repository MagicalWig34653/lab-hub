import XCTVapor
import SQLKit
@testable import HubKit

/// Berechtigungstest für jede Auth-Route (Definition of Done): erlaubt/verboten je Sitzungsart.
/// Die Matrix muss alle `/api/v1`-Routen des Servers abdecken; eine neue Route ohne Eintrag lässt den Test scheitern.
final class AuthPermissionTests: AuthTestCase {
    enum Access { case open, anySession, normalSession, `operator`, tenant }

    static let matrix: [(String, String, Access)] = [
        ("POST", "/api/v1/auth/bootstrap/options", .open), ("POST", "/api/v1/auth/bootstrap/verify", .open),
        ("POST", "/api/v1/auth/register/options", .open), ("POST", "/api/v1/auth/register/verify", .open),
        ("POST", "/api/v1/auth/login/options", .open), ("POST", "/api/v1/auth/login/verify", .open),
        ("POST", "/api/v1/auth/recovery/login", .open),
        ("GET", "/api/v1/auth/session", .anySession), ("POST", "/api/v1/auth/logout", .anySession), ("POST", "/api/v1/auth/logout-all", .anySession),
        ("POST", "/api/v1/me/passkeys/options", .anySession), ("POST", "/api/v1/me/passkeys/verify", .anySession),
        ("GET", "/api/v1/auth/sessions", .normalSession), ("DELETE", "/api/v1/auth/sessions/{id}", .normalSession),
        ("GET", "/api/v1/me/passkeys", .normalSession), ("DELETE", "/api/v1/me/passkeys/{id}", .normalSession),
        ("GET", "/api/v1/me/recovery-codes", .normalSession), ("POST", "/api/v1/me/recovery-codes", .normalSession),
        // WP-K2: Betreiber legt Mandanten an; Mandantenrouten prüfen Mitgliedschaft und Berechtigung (Matrix in TenantTests)
        ("GET", "/api/v1/tenants", .normalSession), ("POST", "/api/v1/tenants", .operator),
        ("GET", "/api/v1/tenants/{tenant}", .tenant), ("GET", "/api/v1/tenants/{tenant}/members", .tenant),
        ("PATCH", "/api/v1/tenants/{tenant}/members/{user}", .tenant), ("DELETE", "/api/v1/tenants/{tenant}/members/{user}", .tenant),
        ("POST", "/api/v1/tenants/{tenant}/invitations", .tenant),
        // WP-K3: Modul-Katalog (jede normale Sitzung), Betreiberschalter, Mandantenschalter (Matrix in ModuleTests/TenantTests)
        ("GET", "/api/v1/modules", .normalSession), ("PUT", "/api/v1/modules/{module}", .operator),
        ("GET", "/api/v1/tenants/{tenant}/modules", .tenant), ("PUT", "/api/v1/tenants/{tenant}/modules/{module}", .tenant)
    ]

    /// AK-K1-*: Die Matrix deckt genau die Routen des Servers unter /api/v1 ab.
    func testMatrixCoversAllApiRoutes() {
        let actual = OpenAPIContract.serverOperations(app1).filter { $0.contains(" /api/v1/") }
        let declared = Set(Self.matrix.map { "\($0.0) \($0.1)" })
        XCTAssertEqual(actual, declared)
    }

    private func path(_ template: String) -> String {
        String(template.dropFirst()).replacingOccurrences(of: "{id}", with: UUID().uuidString)
            .replacingOccurrences(of: "{tenant}", with: UUID().uuidString).replacingOccurrences(of: "{user}", with: UUID().uuidString)
            .replacingOccurrences(of: "{module}", with: "ping")
    }

    private func method(_ m: String) -> HTTPMethod { HTTPMethod(rawValue: m) }

    /// Ohne Sitzung: geschützte Routen liefern 401 (Problem Details), offene Routen niemals 401/403 für fehlende Sitzung.
    func testAnonymousIsRejectedOnProtectedRoutes() async throws {
        for (m, p, access) in Self.matrix {
            let r = try await call(app1, method(m), path(p), json: [:])
            if access == .open {
                XCTAssertNotEqual(r.problemCode, "unauthorized", "\(m) \(p)")  // offen: keine Sitzung nötig
            } else {
                XCTAssertEqual(r.status, .unauthorized, "\(m) \(p)")
                XCTAssertEqual(r.problemCode, "unauthorized", "\(m) \(p)")
                XCTAssertEqual(r.headers.contentType?.serialize(), "application/problem+json", "\(m) \(p)")
            }
        }
    }

    func testInvalidAndForgedTokensAreRejected() async throws {
        for token in ["", "x", String(repeating: "A", count: 43), "Bearer"] {
            let r = try await call(app1, .GET, "api/v1/auth/session", token: token.isEmpty ? nil : token)
            XCTAssertEqual(r.status, .unauthorized, token)
        }
    }

    /// Normale Nutzer ohne Adminrecht: Administrationsroute 403, alle anderen Routen nicht 401/403.
    func testNormalUserMayUseOwnRoutesButNotAdminRoute() async throws {
        let admin = try await bootstrap(app1, VirtualAuthenticator())
        let bob = session(try await register(app1, VirtualAuthenticator(), invite: try await invite(app1, by: admin), handle: "bobby"), handle: "bobby")
        for (m, p, access) in Self.matrix where access != .open {
            if p.hasSuffix("/logout") || p.hasSuffix("/logout-all") { continue }  // beenden die Sitzung; eigener Test unten
            let r = try await call(app1, method(m), path(p), json: [:], token: bob.token)
            if access == .operator {
                XCTAssertEqual(r.status, .forbidden, "\(m) \(p)"); XCTAssertEqual(r.problemCode, "forbidden", "\(m) \(p)")
            } else if access == .tenant {
                XCTAssertEqual(r.status, .notFound, "\(m) \(p)")  // fremder/unbekannter Mandant: 404
            } else {
                XCTAssertNotEqual(r.status, .unauthorized, "\(m) \(p)")
                XCTAssertNotEqual(r.status, .forbidden, "\(m) \(p)")
            }
        }
        let tenant = try await scalar("SELECT tenant_id::text AS v FROM memberships WHERE user_id = '\(admin.userID)'", as: String.self)
        let adminOK = try await call(app2, .POST, "api/v1/tenants/\(tenant)/invitations", json: [:], token: admin.token)
        XCTAssertEqual(adminOK.status, .created)
        let tooLong = try await call(app2, .POST, "api/v1/tenants/\(tenant)/invitations", json: ["expires_in_hours": 100_000], token: admin.token)
        XCTAssertEqual(tooLong.status, .unprocessableEntity)
        let out = try await call(app1, .POST, "api/v1/auth/logout", token: bob.token)
        XCTAssertEqual(out.status, .noContent)
        let all = try await call(app1, .POST, "api/v1/auth/logout-all", token: bob.token)
        XCTAssertEqual(all.status, .unauthorized)  // Sitzung ist bereits beendet
    }

    /// Notfall-Sitzung: nur Session lesen, Abmelden und neuen Passkey anlegen; alles andere 403 (Default-Deny).
    func testRecoverySessionIsDeniedEverywhereExceptAllowList() async throws {
        let admin = try await bootstrap(app1, VirtualAuthenticator())
        let codes = (try await call(app1, .POST, "api/v1/me/recovery-codes", token: admin.token)).json["codes"] as! [String]
        let rec = try await call(app1, .POST, "api/v1/auth/recovery/login", json: ["handle": "alice", "code": codes[0]], headers: ["X-Auth-Transport": "bearer"])
        let token = rec.json["token"] as! String
        for (m, p, access) in Self.matrix where access != .open {
            if p.hasSuffix("/logout") || p.hasSuffix("/logout-all") { continue }
            let r = try await call(app1, method(m), path(p), json: [:], token: token)
            if access == .anySession {
                XCTAssertNotEqual(r.status, .forbidden, "\(m) \(p)"); XCTAssertNotEqual(r.status, .unauthorized, "\(m) \(p)")
            } else {
                XCTAssertEqual(r.status, .forbidden, "\(m) \(p)")
                XCTAssertEqual(r.problemCode, "recovery_session_restricted", "\(m) \(p)")
            }
        }
        let out = try await call(app1, .POST, "api/v1/auth/logout", token: token)
        XCTAssertEqual(out.status, .noContent)
    }

    /// Fremde Objekt-IDs liefern 404 (keine Existenzauskunft): Sitzungen und Passkeys anderer Nutzer.
    func testForeignObjectsAreNotFound() async throws {
        let admin = try await bootstrap(app1, VirtualAuthenticator())
        let bob = session(try await register(app1, VirtualAuthenticator(), invite: try await invite(app1, by: admin), handle: "bobby"), handle: "bobby")
        let adminSession = try await scalar("SELECT id::text AS v FROM sessions WHERE user_id = '\(admin.userID)'", as: String.self)
        let adminPasskey = try await scalar("SELECT id::text AS v FROM passkey_credentials WHERE user_id = '\(admin.userID)'", as: String.self)
        let bobExtra = try await call(app1, .DELETE, "api/v1/auth/sessions/\(adminSession)", token: bob.token)
        XCTAssertEqual(bobExtra.status, .notFound); XCTAssertEqual(bobExtra.problemCode, "not_found")
        let pk = try await call(app1, .DELETE, "api/v1/me/passkeys/\(adminPasskey)", token: bob.token)
        XCTAssertEqual(pk.status, .notFound)
        let stillThere = try await call(app2, .GET, "api/v1/auth/session", token: admin.token)
        XCTAssertEqual(stillThere.status, .ok)
        let unknown = try await call(app1, .DELETE, "api/v1/auth/sessions/not-a-uuid", token: bob.token)
        XCTAssertEqual(unknown.status, .notFound)
    }

    /// Ohne Auth-Konfiguration (kein PUBLIC_URL) antworten die Routen mit 503 statt mit unsicherem Verhalten.
    func testUnconfiguredAuthAnswers503() async throws {
        let app = try await Application.make(.testing)
        defer { Task { try? await app.asyncShutdown() } }
        var env = HubTestDB.env
        env["PUBLIC_URL"] = nil
        try configure(app, environment: env)
        let r = try await call(app, .POST, "api/v1/auth/login/options")
        XCTAssertEqual(r.status, .serviceUnavailable); XCTAssertEqual(r.problemCode, "service_unavailable")
    }
}
