import XCTVapor
@testable import HubKit

/// WP-ST7 (PWA-Redesign): Akzentfarbe je Benutzer, gespeichert im Konto, gleich auf jeder Instanz.
final class PreferencesTests: AuthTestCase {
    /// AK-ST7-1: Jeder Nutzer hat seine eigene Akzentfarbe; zwei Instanzen sehen denselben Stand; `null` setzt zurück.
    func testAKST7_1_AccentIsStoredPerUser() async throws {
        let alice = try await bootstrap(app1, VirtualAuthenticator())
        let bob = session(try await register(app1, VirtualAuthenticator(), invite: try await invite(app1, by: alice), handle: "bobby"), handle: "bobby")

        let initial = try await call(app1, .GET, "api/v1/me/preferences", token: alice.token)
        XCTAssertEqual(initial.status, .ok)
        XCTAssertTrue(initial.json["accent"] is NSNull, "\(initial.json)")

        let set = try await call(app1, .PUT, "api/v1/me/preferences", json: ["accent": "#0D9488"], token: alice.token)
        XCTAssertEqual(set.status, .ok, "\(set.json)")
        XCTAssertEqual(set.json["accent"] as? String, "#0d9488")

        let bobSet = try await call(app2, .PUT, "api/v1/me/preferences", json: ["accent": "#7c3aed"], token: bob.token)
        XCTAssertEqual(bobSet.status, .ok)

        // andere Instanz, anderer Nutzer: jeder sieht nur seine Farbe
        let aliceOther = try await call(app2, .GET, "api/v1/me/preferences", token: alice.token)
        XCTAssertEqual(aliceOther.json["accent"] as? String, "#0d9488")
        let bobOther = try await call(app1, .GET, "api/v1/me/preferences", token: bob.token)
        XCTAssertEqual(bobOther.json["accent"] as? String, "#7c3aed")

        let reset = try await call(app2, .PUT, "api/v1/me/preferences", json: ["accent": NSNull()], token: alice.token)
        XCTAssertEqual(reset.status, .ok)
        let aliceReset = try await call(app1, .GET, "api/v1/me/preferences", token: alice.token)
        XCTAssertTrue(aliceReset.json["accent"] is NSNull, "\(aliceReset.json)")
        let bobKept = try await call(app1, .GET, "api/v1/me/preferences", token: bob.token)
        XCTAssertEqual(bobKept.json["accent"] as? String, "#7c3aed")
    }

    /// AK-ST7-2: Nur `#rgb`/`#rrggbb` ist erlaubt; sonst 400 `validation_failed`, der alte Wert bleibt.
    func testAKST7_2_InvalidAccentIsRejected() async throws {
        let alice = try await bootstrap(app1, VirtualAuthenticator())
        _ = try await call(app1, .PUT, "api/v1/me/preferences", json: ["accent": "#2563eb"], token: alice.token)
        for bad: Any in ["red", "#12345", "#gggggg", "2563eb", "#2563eb00", 42, "#2563eb; color: red"] {
            let r = try await call(app1, .PUT, "api/v1/me/preferences", json: ["accent": bad], token: alice.token)
            XCTAssertEqual(r.status, .badRequest, "\(bad)")
            XCTAssertEqual(r.problemCode, "validation_failed", "\(bad)")
        }
        let short = try await call(app1, .PUT, "api/v1/me/preferences", json: ["accent": "#AbC"], token: alice.token)
        XCTAssertEqual(short.json["accent"] as? String, "#aabbcc")
    }
}
