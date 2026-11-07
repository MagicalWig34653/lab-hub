import XCTVapor
import Fluent
import SQLKit
import Crypto
@testable import HubKit

/// WP-K1 Auth gegen echtes Postgres (ohne erreichbare DB übersprungen). Zwei Anwendungsinstanzen teilen eine Datenbank.
/// Alle Daten synthetisch.
final class AuthTests: AuthTestCase {

    // MARK: AK-K1-1 Setup-Token-Bootstrap

    func testAKK1_1_BootstrapNeedsSetupTokenAndClosesAfterFirstUser() async throws {
        let wrong = try await call(app1, .POST, "api/v1/auth/bootstrap/options", json: ["setup_token": "wrong", "handle": "alice", "display_name": "Alice"])
        XCTAssertEqual(wrong.status, .forbidden); XCTAssertEqual(wrong.problemCode, "setup_token_invalid")
        let usersBefore = try await scalar("SELECT count(*)::bigint AS v FROM users", as: Int64.self)
        XCTAssertEqual(usersBefore, 0)

        let auth = VirtualAuthenticator()
        let s = try await bootstrap(app1, auth)
        let me = try await call(app2, .GET, "api/v1/auth/session", token: s.token)
        XCTAssertEqual(me.status, .ok)
        XCTAssertEqual((me.json["user"] as? [String: Any])?["handle"] as? String, "alice")
        XCTAssertEqual((me.json["user"] as? [String: Any])?["is_operator"] as? Bool, true)  // WP-K2: ersetzt is_admin
        XCTAssertEqual((me.json["memberships"] as? [[String: Any]])?.first?["role"] as? String, "owner")

        // Kein offenes Fenster mehr: mit korrektem Token trotzdem 404, auch auf der zweiten Instanz.
        for app in [app1!, app2!] {
            let again = try await call(app, .POST, "api/v1/auth/bootstrap/options", json: ["setup_token": setupToken, "handle": "mallory", "display_name": "M"])
            XCTAssertEqual(again.status, .notFound)
        }
    }

    func testAKK1_1_NoSetupTokenConfiguredMeansNoBootstrap() async throws {
        app1.authSettings?.setupToken = nil
        let r = try await call(app1, .POST, "api/v1/auth/bootstrap/options", json: ["setup_token": setupToken, "handle": "alice", "display_name": "Alice"])
        XCTAssertEqual(r.status, .notFound)
    }

    func testAKK1_1_ConcurrentBootstrapCreatesExactlyOneUser() async throws {
        let a = VirtualAuthenticator(), b = VirtualAuthenticator()
        async let x = bootstrapResult(app1, a, handle: "alice")
        async let y = bootstrapResult(app2, b, handle: "bobby")
        let results = try await [x, y]
        XCTAssertEqual(results.filter { $0 == .created }.count, 1, "\(results)")
        let n = try await scalar("SELECT count(*)::bigint AS v FROM users", as: Int64.self)
        XCTAssertEqual(n, 1)
    }

    private func bootstrapResult(_ app: Application, _ auth: VirtualAuthenticator, handle: String) async throws -> HTTPStatus {
        let o = try await call(app, .POST, "api/v1/auth/bootstrap/options", json: ["setup_token": setupToken, "handle": handle, "display_name": "X"])
        guard o.status == .ok else { return o.status }
        let credential = try auth.registration(o.json["public_key"] as! [String: Any])
        return try await call(app, .POST, "api/v1/auth/bootstrap/verify", json: ["challenge_id": o.json["challenge_id"]!, "credential": credential]).status
    }

    // MARK: AK-K1-2 Passkey-Registrierung und -Login mit virtuellem Authenticator

    func testAKK1_2_LoginWithVirtualAuthenticator() async throws {
        let auth = VirtualAuthenticator()
        let first = try await bootstrap(app1, auth)
        let r = try await login(app1, auth, userID: first.userID, handle: "alice", count: 1)
        XCTAssertEqual(r.status, .ok, "\(r.json)")
        XCTAssertEqual(r.json["kind"] as? String, "normal")
        // Challenge von Instanz 1, Prüfung auf Instanz 2 (Challenges liegen in der DB)
        let o = try await call(app1, .POST, "api/v1/auth/login/options")
        let credential = try auth.assertion(o.json["public_key"] as! [String: Any], userID: first.userID, count: 2)
        let v = try await call(app2, .POST, "api/v1/auth/login/verify", json: ["challenge_id": o.json["challenge_id"]!, "credential": credential])
        XCTAssertEqual(v.status, .ok)
        let signCount = try await scalar("SELECT sign_count AS v FROM passkey_credentials", as: Int64.self)
        XCTAssertEqual(signCount, 2)
    }

    func testAKK1_2_ForeignKeyReplayAndCounterRegressionAreRejected() async throws {
        let auth = VirtualAuthenticator()
        let first = try await bootstrap(app1, auth)
        // Signatur mit fremdem Schlüssel
        let o = try await call(app1, .POST, "api/v1/auth/login/options")
        let forged = try auth.assertion(o.json["public_key"] as! [String: Any], userID: first.userID, count: 1, signWith: P256.Signing.PrivateKey())
        let bad = try await call(app1, .POST, "api/v1/auth/login/verify", json: ["challenge_id": o.json["challenge_id"]!, "credential": forged])
        XCTAssertEqual(bad.status, .unauthorized); XCTAssertEqual(bad.problemCode, "login_failed")
        // Challenge ist verbraucht, auch eine korrekte Antwort darauf scheitert (Replay)
        let valid = try auth.assertion(o.json["public_key"] as! [String: Any], userID: first.userID, count: 1)
        let replay = try await call(app1, .POST, "api/v1/auth/login/verify", json: ["challenge_id": o.json["challenge_id"]!, "credential": valid])
        XCTAssertEqual(replay.status, .unauthorized)
        // Zähler muss steigen
        let ok = try await login(app1, auth, userID: first.userID, handle: "alice", count: 5)
        XCTAssertEqual(ok.status, .ok)
        let stale = try await login(app1, auth, userID: first.userID, handle: "alice", count: 5)
        XCTAssertEqual(stale.status, .unauthorized)
        // Falscher userHandle
        let o2 = try await call(app1, .POST, "api/v1/auth/login/options")
        let wrongUser = try auth.assertion(o2.json["public_key"] as! [String: Any], userID: UUID().uuidString, count: 9)
        let wu = try await call(app1, .POST, "api/v1/auth/login/verify", json: ["challenge_id": o2.json["challenge_id"]!, "credential": wrongUser])
        XCTAssertEqual(wu.status, .unauthorized)
    }

    func testAKK1_2_ChallengeExpiresByDatabaseClock() async throws {
        let auth = VirtualAuthenticator()
        let first = try await bootstrap(app1, auth)
        let o = try await call(app1, .POST, "api/v1/auth/login/options")
        try await db.raw("UPDATE auth_challenges SET expires_at = now() - interval '1 second'").run()
        let credential = try auth.assertion(o.json["public_key"] as! [String: Any], userID: first.userID, count: 1)
        let r = try await call(app2, .POST, "api/v1/auth/login/verify", json: ["challenge_id": o.json["challenge_id"]!, "credential": credential])
        XCTAssertEqual(r.status, .unauthorized)
    }

    func testAKK1_2_AddAndRevokePasskeys() async throws {
        let auth = VirtualAuthenticator(), second = VirtualAuthenticator()
        let s = try await bootstrap(app1, auth)
        // Letzter Passkey bleibt erhalten
        let list = try await call(app1, .GET, "api/v1/me/passkeys", token: s.token)
        let firstID = ((list.json["items"] as! [[String: Any]])[0])["id"] as! String
        let last = try await call(app1, .DELETE, "api/v1/me/passkeys/\(firstID)", token: s.token)
        XCTAssertEqual(last.status, .conflict); XCTAssertEqual(last.problemCode, "last_passkey")
        // Zweiten hinzufügen (Challenge auf Instanz 1, Prüfung auf Instanz 2)
        let o = try await call(app1, .POST, "api/v1/me/passkeys/options", token: s.token)
        XCTAssertEqual(o.status, .ok)
        let excluded = ((o.json["public_key"] as! [String: Any])["excludeCredentials"] as! [[String: Any]]).count
        XCTAssertEqual(excluded, 1)
        let cred = try second.registration(o.json["public_key"] as! [String: Any])
        let v = try await call(app2, .POST, "api/v1/me/passkeys/verify", json: ["challenge_id": o.json["challenge_id"]!, "credential": cred, "name": "Zweitgerät"], token: s.token)
        XCTAssertEqual(v.status, .created, "\(v.json)")
        // Anmeldung mit dem zweiten Passkey
        let l = try await login(app1, second, userID: s.userID, handle: "alice", count: 1)
        XCTAssertEqual(l.status, .ok)
        // Jetzt darf der erste widerrufen werden; danach ist er unbrauchbar
        let rev = try await call(app1, .DELETE, "api/v1/me/passkeys/\(firstID)", token: s.token)
        XCTAssertEqual(rev.status, .noContent)
        let gone = try await login(app1, auth, userID: s.userID, handle: "alice", count: 10)
        XCTAssertEqual(gone.status, .unauthorized)
        // Doppelte Credential-ID wird abgelehnt
        let o2 = try await call(app1, .POST, "api/v1/me/passkeys/options", token: s.token)
        let dup = try await call(app1, .POST, "api/v1/me/passkeys/verify", json: ["challenge_id": o2.json["challenge_id"]!, "credential": try second.registration(o2.json["public_key"] as! [String: Any])], token: s.token)
        XCTAssertEqual(dup.status, .badRequest); XCTAssertEqual(dup.problemCode, "passkey_invalid")
    }

    // MARK: AK-K1-3 Einladung, Einmal-Link, Ablauf

    func testAKK1_3_InvitationIsSingleUseAndRegistersUser() async throws {
        let admin = try await bootstrap(app1, VirtualAuthenticator())
        let token = try await invite(app2, by: admin)
        let bobKey = VirtualAuthenticator()
        let reg = try await register(app1, bobKey, invite: token, handle: "bobby")
        XCTAssertEqual(reg.status, .created, "\(reg.json)")
        XCTAssertEqual((reg.json["user"] as? [String: Any])?["is_operator"] as? Bool, false)  // WP-K2: ersetzt is_admin
        XCTAssertEqual((reg.json["memberships"] as? [[String: Any]])?.first?["role"] as? String, "member")
        // zweite Verwendung scheitert
        let again = try await call(app2, .POST, "api/v1/auth/register/options", json: ["invite_token": token, "handle": "carol", "display_name": "C"])
        XCTAssertEqual(again.status, .gone); XCTAssertEqual(again.problemCode, "invitation_invalid")
        let usedBy = try await scalar("SELECT used_by IS NOT NULL AS v FROM invitations", as: Bool.self)
        XCTAssertTrue(usedBy)
        // Nur der Hash ist gespeichert
        let plaintext = try await scalar("SELECT count(*)::bigint AS v FROM invitations WHERE token_hash = '\(token)'", as: Int64.self)
        XCTAssertEqual(plaintext, 0)
        // Neuer Nutzer kann sich anmelden
        let bobID = (reg.json["user"] as! [String: Any])["id"] as! String
        let l = try await login(app2, bobKey, userID: bobID, handle: "bobby", count: 1)
        XCTAssertEqual(l.status, .ok)
    }

    func testAKK1_3_ExpiredAndUnknownInvitationsFail() async throws {
        let admin = try await bootstrap(app1, VirtualAuthenticator())
        let token = try await invite(app1, by: admin)
        try await db.raw("UPDATE invitations SET expires_at = now() - interval '1 second'").run()
        let expired = try await register(app2, VirtualAuthenticator(), invite: token, handle: "bobby")
        XCTAssertEqual(expired.status, .gone); XCTAssertEqual(expired.problemCode, "invitation_invalid")
        let unknown = try await register(app1, VirtualAuthenticator(), invite: AuthSecrets.token(), handle: "bobby")
        XCTAssertEqual(unknown.status, .gone)
        // Ablauf zwischen Optionen und Verify
        let t2 = try await invite(app1, by: admin)
        let o = try await call(app1, .POST, "api/v1/auth/register/options", json: ["invite_token": t2, "handle": "carol", "display_name": "C"])
        XCTAssertEqual(o.status, .ok)
        try await db.raw("UPDATE invitations SET expires_at = now() - interval '1 second' WHERE used_at IS NULL").run()
        let cred = try VirtualAuthenticator().registration(o.json["public_key"] as! [String: Any])
        let late = try await call(app2, .POST, "api/v1/auth/register/verify", json: ["challenge_id": o.json["challenge_id"]!, "credential": cred])
        XCTAssertEqual(late.status, .gone)
        let users = try await scalar("SELECT count(*)::bigint AS v FROM users", as: Int64.self)
        XCTAssertEqual(users, 1)
    }

    func testAKK1_3_TwoParallelRegistrationsOnOneInvitationYieldOneUser() async throws {
        let admin = try await bootstrap(app1, VirtualAuthenticator())
        let token = try await invite(app1, by: admin)
        let a = VirtualAuthenticator(), b = VirtualAuthenticator()
        let oa = try await call(app1, .POST, "api/v1/auth/register/options", json: ["invite_token": token, "handle": "carol", "display_name": "C"])
        let ob = try await call(app2, .POST, "api/v1/auth/register/options", json: ["invite_token": token, "handle": "dave", "display_name": "D"])
        let ca = try a.registration(oa.json["public_key"] as! [String: Any]), cb = try b.registration(ob.json["public_key"] as! [String: Any])
        async let ra = call(app1, .POST, "api/v1/auth/register/verify", json: ["challenge_id": oa.json["challenge_id"]!, "credential": ca])
        async let rb = call(app2, .POST, "api/v1/auth/register/verify", json: ["challenge_id": ob.json["challenge_id"]!, "credential": cb])
        let statuses = try await [ra.status, rb.status]
        XCTAssertEqual(statuses.filter { $0 == .created }.count, 1, "\(statuses)")
        let users = try await scalar("SELECT count(*)::bigint AS v FROM users", as: Int64.self)
        XCTAssertEqual(users, 2)  // Admin + genau einer
    }

    func testAKK1_3_HandleTakenAndValidation() async throws {
        let admin = try await bootstrap(app1, VirtualAuthenticator())
        let token = try await invite(app1, by: admin)
        let taken = try await call(app1, .POST, "api/v1/auth/register/options", json: ["invite_token": token, "handle": "alice", "display_name": "X"])
        XCTAssertEqual(taken.status, .conflict); XCTAssertEqual(taken.problemCode, "handle_taken")
        let invalid = try await call(app1, .POST, "api/v1/auth/register/options", json: ["invite_token": token, "handle": "A!", "display_name": ""])
        XCTAssertEqual(invalid.status, .unprocessableEntity); XCTAssertEqual(invalid.problemCode, "validation_failed")
        // Fehlgeschlagene Registrierung (Handle-Konflikt zwischen Optionen und Verify) verbraucht die Einladung nicht
        let o = try await call(app1, .POST, "api/v1/auth/register/options", json: ["invite_token": token, "handle": "erin", "display_name": "E"])
        try await db.raw("INSERT INTO users (handle, display_name) VALUES ('erin', 'Racer')").run()
        let cred = try VirtualAuthenticator().registration(o.json["public_key"] as! [String: Any])
        let r = try await call(app1, .POST, "api/v1/auth/register/verify", json: ["challenge_id": o.json["challenge_id"]!, "credential": cred])
        XCTAssertEqual(r.status, .conflict)
        let unused = try await scalar("SELECT (used_at IS NULL) AS v FROM invitations", as: Bool.self)
        XCTAssertTrue(unused)
    }

    // MARK: AK-K1-4 Recovery-Codes

    func testAKK1_4_RecoveryCodesAreSingleUseAndStoredHashed() async throws {
        let auth = VirtualAuthenticator()
        let s = try await bootstrap(app1, auth)
        let gen = try await call(app1, .POST, "api/v1/me/recovery-codes", token: s.token)
        XCTAssertEqual(gen.status, .created)
        let codes = gen.json["codes"] as! [String]
        XCTAssertEqual(Set(codes).count, 10)
        let remaining = try await call(app2, .GET, "api/v1/me/recovery-codes", token: s.token)
        XCTAssertEqual(remaining.json["remaining"] as? Int, 10)
        // Klartext steht nirgends in der DB
        for code in codes {
            let hits = try await scalar("SELECT count(*)::bigint AS v FROM recovery_codes WHERE code_hash = '\(code)'", as: Int64.self)
            XCTAssertEqual(hits, 0)
        }
        // Erste Verwendung (auf Instanz 2) klappt, zweite scheitert (auf Instanz 1); Schreibweise tolerant
        let use = try await call(app2, .POST, "api/v1/auth/recovery/login", json: ["handle": "alice", "code": codes[0].lowercased()], headers: ["X-Auth-Transport": "bearer"])
        XCTAssertEqual(use.status, .ok, "\(use.json)")
        XCTAssertEqual(use.json["kind"] as? String, "recovery")
        let reuse = try await call(app1, .POST, "api/v1/auth/recovery/login", json: ["handle": "alice", "code": codes[0]])
        XCTAssertEqual(reuse.status, .unauthorized); XCTAssertEqual(reuse.problemCode, "login_failed")
        let unknownUser = try await call(app1, .POST, "api/v1/auth/recovery/login", json: ["handle": "nobody", "code": codes[1]])
        XCTAssertEqual(unknownUser.status, .unauthorized)
        let left = try await call(app1, .GET, "api/v1/me/recovery-codes", token: s.token)
        XCTAssertEqual(left.json["remaining"] as? Int, 9)
        // Neue Codes ersetzen alle alten
        _ = try await call(app1, .POST, "api/v1/me/recovery-codes", token: s.token)
        let old = try await call(app1, .POST, "api/v1/auth/recovery/login", json: ["handle": "alice", "code": codes[2]])
        XCTAssertEqual(old.status, .unauthorized)
    }

    func testAKK1_4_RecoverySessionIsRestrictedAndUpgradesWithNewPasskey() async throws {
        let auth = VirtualAuthenticator(), fresh = VirtualAuthenticator()
        let s = try await bootstrap(app1, auth)
        let codes = (try await call(app1, .POST, "api/v1/me/recovery-codes", token: s.token)).json["codes"] as! [String]
        let rec = try await call(app1, .POST, "api/v1/auth/recovery/login", json: ["handle": "alice", "code": codes[0]], headers: ["X-Auth-Transport": "bearer"])
        let token = rec.json["token"] as! String
        let blocked = try await call(app1, .POST, "api/v1/me/recovery-codes", token: token)
        XCTAssertEqual(blocked.status, .forbidden); XCTAssertEqual(blocked.problemCode, "recovery_session_restricted")
        let o = try await call(app2, .POST, "api/v1/me/passkeys/options", token: token)
        XCTAssertEqual(o.status, .ok)
        let v = try await call(app2, .POST, "api/v1/me/passkeys/verify", json: ["challenge_id": o.json["challenge_id"]!, "credential": try fresh.registration(o.json["public_key"] as! [String: Any])], token: token)
        XCTAssertEqual(v.status, .created)
        let now = try await call(app1, .GET, "api/v1/auth/session", token: token)
        XCTAssertEqual(now.json["kind"] as? String, "normal")
        let allowed = try await call(app1, .GET, "api/v1/me/recovery-codes", token: token)
        XCTAssertEqual(allowed.status, .ok)
    }

    // MARK: AK-K1-5 Sitzung gilt auf zweiter Instanz

    func testAKK1_5_SessionWorksOnSecondInstanceAndLogoutIsGlobal() async throws {
        let auth = VirtualAuthenticator()
        let first = try await bootstrap(app1, auth)
        let l = try await login(app1, auth, userID: first.userID, handle: "alice", count: 1)
        let token = l.json["token"] as! String
        for app in [app1!, app2!] {
            let r = try await call(app, .GET, "api/v1/auth/session", token: token)
            XCTAssertEqual(r.status, .ok)
        }
        let out = try await call(app2, .POST, "api/v1/auth/logout", token: token)
        XCTAssertEqual(out.status, .noContent)
        let after = try await call(app1, .GET, "api/v1/auth/session", token: token)
        XCTAssertEqual(after.status, .unauthorized); XCTAssertEqual(after.problemCode, "unauthorized")
        // nur der Hash liegt in der DB
        let plain = try await scalar("SELECT count(*)::bigint AS v FROM sessions WHERE token_hash = '\(token)'", as: Int64.self)
        XCTAssertEqual(plain, 0)
    }

    func testAKK1_5_SessionExpiresByDatabaseClock() async throws {
        let s = try await bootstrap(app1, VirtualAuthenticator())
        try await db.raw("UPDATE sessions SET expires_at = now() - interval '1 second'").run()
        let r = try await call(app2, .GET, "api/v1/auth/session", token: s.token)
        XCTAssertEqual(r.status, .unauthorized)
    }

    func testAKK1_5_CookieSessionNeedsCsrfHeaderForWrites() async throws {
        let auth = VirtualAuthenticator()
        let first = try await bootstrap(app1, auth)
        let o = try await call(app1, .POST, "api/v1/auth/login/options")
        let credential = try auth.assertion(o.json["public_key"] as! [String: Any], userID: first.userID, count: 1)
        let v = try await call(app1, .POST, "api/v1/auth/login/verify", json: ["challenge_id": o.json["challenge_id"]!, "credential": credential])
        XCTAssertEqual(v.status, .ok)
        XCTAssertNil(v.json["token"], "Token gehört bei Cookie-Transport nicht in den Body")
        let cookie = v.headers.setCookie?[sessionCookieName]
        XCTAssertNotNil(cookie)
        XCTAssertTrue(cookie?.isHTTPOnly ?? false)
        XCTAssertEqual(cookie?.sameSite, HTTPCookies.SameSitePolicy.lax)
        let cookieHeader = "\(sessionCookieName)=\(cookie!.string)"
        let read = try await call(app2, .GET, "api/v1/auth/session", headers: ["Cookie": cookieHeader])
        XCTAssertEqual(read.status, .ok)
        let noCsrf = try await call(app2, .POST, "api/v1/me/recovery-codes", headers: ["Cookie": cookieHeader])
        XCTAssertEqual(noCsrf.status, .forbidden); XCTAssertEqual(noCsrf.problemCode, "csrf_invalid")
        let withCsrf = try await call(app2, .POST, "api/v1/me/recovery-codes", headers: ["Cookie": cookieHeader, "X-CSRF-Token": read.json["csrf_token"] as! String])
        XCTAssertEqual(withCsrf.status, .created)
    }

    // MARK: AK-K1-6 Rate-Limit instanzübergreifend

    func testAKK1_6_RateLimitSharedAcrossInstancesWithDatabaseClock() async throws {
        for app in [app1!, app2!] { app.authSettings?.rateLimitMax = 3; app.authSettings?.rateLimitWindow = 60 }
        let r1 = try await call(app1, .POST, "api/v1/auth/login/options")
        let r2 = try await call(app2, .POST, "api/v1/auth/login/options")
        let r3 = try await call(app1, .POST, "api/v1/auth/login/options")
        XCTAssertEqual([r1.status, r2.status, r3.status], [.ok, .ok, .ok])
        for app in [app2!, app1!] {
            let blocked = try await call(app, .POST, "api/v1/auth/login/options")
            XCTAssertEqual(blocked.status, .tooManyRequests); XCTAssertEqual(blocked.problemCode, "too_many_requests")
            XCTAssertEqual(blocked.headers.first(name: "Retry-After"), "60")
            XCTAssertEqual(blocked.headers.contentType?.serialize(), "application/problem+json")
        }
        // Das Fenster läuft nach DB-Zeit ab (Ereignisse künstlich in der DB gealtert, keine Instanzuhr beteiligt)
        try await db.raw("UPDATE rate_limit_events SET occurred_at = occurred_at - interval '61 seconds'").run()
        let again = try await call(app2, .POST, "api/v1/auth/login/options")
        XCTAssertEqual(again.status, .ok)
    }

    func testAKK1_6_ConcurrentRequestsNeverExceedLimit() async throws {
        for app in [app1!, app2!] { app.authSettings?.rateLimitMax = 5 }
        var ok = 0
        try await withThrowingTaskGroup(of: HTTPStatus.self) { g in
            for i in 0..<20 { g.addTask { [self] in try await call(i.isMultiple(of: 2) ? app1 : app2, .POST, "api/v1/auth/login/options").status } }
            for try await s in g where s == .ok { ok += 1 }
        }
        XCTAssertEqual(ok, 5)
    }

    func testAKK1_6_ProtectedRoutesAreNotRateLimitedByAuthBucket() async throws {
        let s = try await bootstrap(app1, VirtualAuthenticator())
        for app in [app1!, app2!] { app.authSettings?.rateLimitMax = 1 }
        for _ in 0..<3 { let r = try await call(app1, .GET, "api/v1/auth/session", token: s.token); XCTAssertEqual(r.status, .ok) }
    }

    // MARK: AK-K1-7 alle Geräte abmelden

    func testAKK1_7_LogoutAllRevokesEverySessionOfTheUserOnly() async throws {
        let aliceKey = VirtualAuthenticator(), bobKey = VirtualAuthenticator()
        let alice = try await bootstrap(app1, aliceKey)
        let bobReg = try await register(app1, bobKey, invite: try await invite(app1, by: alice), handle: "bobby")
        let bob = session(bobReg, handle: "bobby")
        let t2 = (try await login(app1, aliceKey, userID: alice.userID, handle: "alice", count: 1)).json["token"] as! String
        let t3 = (try await login(app2, aliceKey, userID: alice.userID, handle: "alice", count: 2)).json["token"] as! String
        let list = try await call(app1, .GET, "api/v1/auth/sessions", token: t2)
        XCTAssertEqual((list.json["items"] as! [[String: Any]]).count, 3)
        let out = try await call(app2, .POST, "api/v1/auth/logout-all", token: t3)
        XCTAssertEqual(out.status, .ok); XCTAssertEqual(out.json["revoked"] as? Int, 3)
        for t in [alice.token, t2, t3] {
            for app in [app1!, app2!] {
                let r = try await call(app, .GET, "api/v1/auth/session", token: t)
                XCTAssertEqual(r.status, .unauthorized)
            }
        }
        let bobStill = try await call(app1, .GET, "api/v1/auth/session", token: bob.token)
        XCTAssertEqual(bobStill.status, .ok)
        // Anmelden geht danach weiter
        let again = try await login(app1, aliceKey, userID: alice.userID, handle: "alice", count: 3)
        XCTAssertEqual(again.status, .ok)
    }

    func testAKK1_7_RevokeSingleSessionAndForeignSessionIs404() async throws {
        let aliceKey = VirtualAuthenticator(), bobKey = VirtualAuthenticator()
        let alice = try await bootstrap(app1, aliceKey)
        let bob = session(try await register(app1, bobKey, invite: try await invite(app1, by: alice), handle: "bobby"), handle: "bobby")
        let t2 = (try await login(app1, aliceKey, userID: alice.userID, handle: "alice", count: 1)).json["token"] as! String
        let list = try await call(app1, .GET, "api/v1/auth/sessions", token: alice.token)
        let items = list.json["items"] as! [[String: Any]]
        let other = items.first { ($0["current"] as? Bool) == false }!["id"] as! String
        let bobSessionID = (try await call(app1, .GET, "api/v1/auth/sessions", token: bob.token)).json["items"] as! [[String: Any]]
        let foreign = try await call(app1, .DELETE, "api/v1/auth/sessions/\(bobSessionID[0]["id"] as! String)", token: alice.token)
        XCTAssertEqual(foreign.status, .notFound)
        let mine = try await call(app2, .DELETE, "api/v1/auth/sessions/\(other)", token: alice.token)
        XCTAssertEqual(mine.status, .noContent)
        let r = try await call(app1, .GET, "api/v1/auth/session", token: t2)
        XCTAssertEqual(r.status, .unauthorized)
    }

    // MARK: AK-K1-8 Audit ohne Nutzdaten, append-only per DB

    func testAKK1_8_AuditHasNoUserDataAndIsAppendOnly() async throws {
        let auth = VirtualAuthenticator()
        let s = try await bootstrap(app1, auth, handle: "alice")
        let inv = try await invite(app1, by: s)
        let bobKey = VirtualAuthenticator()
        let bob = try await register(app1, bobKey, invite: inv, handle: "bobby-secret-handle")
        _ = try await login(app2, auth, userID: s.userID, handle: "alice", count: 1)
        let codes = (try await call(app1, .POST, "api/v1/me/recovery-codes", token: s.token)).json["codes"] as! [String]
        _ = try await call(app1, .POST, "api/v1/auth/recovery/login", json: ["handle": "alice", "code": codes[0]])
        _ = try await call(app1, .POST, "api/v1/auth/logout-all", token: s.token)
        XCTAssertEqual(bob.status, .created)

        let rows = try await db.raw("SELECT action, actor_user_id::text AS actor, subject_type, subject_id, meta::text AS meta, request_id FROM audit_log ORDER BY id").all()
        let actions = try rows.map { try $0.decode(column: "action", as: String.self) }
        for expected in ["auth.bootstrap", "auth.invitation_created", "auth.register", "auth.login", "auth.recovery_codes_generated", "auth.recovery_login", "auth.logout_all"] {
            XCTAssertTrue(actions.contains(expected), "Audit-Eintrag \(expected) fehlt: \(actions)")
        }
        let dump = try await scalar("SELECT coalesce(string_agg(audit_log::text, ' '), '') AS v FROM audit_log", as: String.self)
        for secret in ["alice", "Alice Synthetic", "bobby-secret-handle", "Bob Synthetic", inv, s.token, codes[0], "setup", "unknown", "127.0.0.1", "localhost"] {
            XCTAssertFalse(dump.contains(secret), "Audit enthält Nutzdaten: \(secret)")
        }
        XCTAssertTrue(rows.allSatisfy { (try? $0.decode(column: "request_id", as: String?.self)) != nil })

        await assertDBRejects("UPDATE audit_log SET action = 'x'")
        await assertDBRejects("DELETE FROM audit_log")
        await assertDBRejects("TRUNCATE audit_log")
        let count = try await scalar("SELECT count(*)::bigint AS v FROM audit_log", as: Int64.self)
        XCTAssertEqual(count, Int64(rows.count))
    }

    private func assertDBRejects(_ statement: String, file: StaticString = #filePath, line: UInt = #line) async {
        do { try await db.raw(SQLQueryString(statement)).run(); XCTFail("Statement hätte scheitern müssen: \(statement)", file: file, line: line) }
        catch { let text = String(reflecting: error).lowercased()
            XCTAssertTrue(text.contains("append-only"), text, file: file, line: line) }
    }

    func testAKK1_8_CounterAuditHookWritesAuditLogInSameTransaction() async throws {
        let counters = CounterService(db, auditHook: AuditLogCounterHook())
        let tenant = UUID()
        let key = CounterKey(space: "invoice", name: "2026")
        try await counters.ensureAtLeast(tenant: tenant, key: key, value: 100, reason: "import")
        try await counters.ensureAtLeast(tenant: tenant, key: key, value: 50, reason: "import")  // keine Änderung, kein Eintrag
        try await counters.ensureAtLeast(tenant: tenant, key: key, value: 120, reason: "Max Mustermann importiert")  // unsicherer Grund
        let rows = try await db.raw("SELECT subject_id, meta::text AS meta, tenant_id FROM audit_log WHERE action = 'counter.raised' ORDER BY id").all()
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(try rows[0].decode(column: "subject_id", as: String.self), "invoice:2026")
        XCTAssertEqual(try rows[0].decode(column: "tenant_id", as: UUID.self), tenant)
        let m0 = try rows[0].decode(column: "meta", as: String.self), m1 = try rows[1].decode(column: "meta", as: String.self)
        XCTAssertTrue(m0.contains("\"new\": 100") && m0.contains("import"), m0)
        XCTAssertTrue(m1.contains("\"previous\": 100") && m1.contains("\"reason\": \"invalid\""), m1)
        XCTAssertFalse(m1.contains("Mustermann"))
        // Rollback der Transaktion nimmt den Audit-Eintrag mit zurück
        struct Boom: Error {}
        do {
            try await app1.db.transaction { tx in
                _ = try await counters.ensureAtLeast(tenant: tenant, key: key, value: 999, reason: "import", on: try sql(tx))
                throw Boom()
            }
        } catch is Boom {}
        let after = try await scalar("SELECT count(*)::bigint AS v FROM audit_log WHERE action = 'counter.raised'", as: Int64.self)
        XCTAssertEqual(after, 2)
    }

    // MARK: Migrationen (Expand/Contract, schema_version, Revert)

    func testMigrationsSetSchemaVersionAndRevert() async throws {
        let v = try await scalar("SELECT max(version)::bigint AS v FROM schema_version", as: Int64.self)
        XCTAssertEqual(v, 17)  // WP-O1 (017)
        let authMigrations: [any Migration] = [CreateUsers(), CreatePasskeyCredentials(), CreateSessions(), CreateInvitations(), CreateRecoveryCodes(), CreateAuditLog(), CreateAuthSupport()]
        let database = app1.db(.psql)
        try await CreateJobsPriority().revert(on: database)  // WP-O1 (017) zuerst
        try await CreateContacts().revert(on: database)  // WP-K5 (015) zuerst
        try await CreateModules().revert(on: database)  // WP-K3 hängt an tenants/users
        try await CreateTenants().revert(on: database)  // WP-K2 hängt an users/invitations
        for m in authMigrations.reversed() { try await m.revert(on: database).get() }
        let reverted = try await scalar("SELECT max(version)::bigint AS v FROM schema_version", as: Int64.self)
        XCTAssertEqual(reverted, 5)
        let leftovers = try await scalar("""
            SELECT count(*)::bigint AS v FROM information_schema.tables WHERE table_schema = current_schema()
            AND table_name IN ('users','passkey_credentials','sessions','invitations','recovery_codes','audit_log','auth_challenges','rate_limit_events')
            """, as: Int64.self)
        XCTAssertEqual(leftovers, 0)
        for m in authMigrations { try await m.prepare(on: database).get() }
        try await CreateTenants().prepare(on: database)
        try await CreateModules().prepare(on: database)
        try await CreateContacts().prepare(on: database)
        let again = try await scalar("SELECT max(version)::bigint AS v FROM schema_version", as: Int64.self)
        XCTAssertEqual(again, 15)
        try await CreateJobsPriority().prepare(on: database)
    }
}
