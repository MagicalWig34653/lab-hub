import XCTVapor
import Fluent
import SQLKit
@testable import HubKit

/// WP-R1: Stammdaten des Rechnungsmoduls (Einstellungen, Steuerzeiträume, Belegtypen, Nummernserien, Artikel). Nur synthetische Daten.
class InvoiceTestBase: AuthTestCase {
    override var testModules: [any HubModule] { [InvoiceModule()] }

    struct World {
        let alice: TestSession   // Owner Mandant A
        let tenantA: String
    }

    func world(enable: Bool = true) async throws -> World {
        let alice = try await bootstrap(app1, VirtualAuthenticator())
        let tenant = try await scalar("SELECT tenant_id::text AS v FROM memberships WHERE user_id = '\(alice.userID)'", as: String.self)
        if enable { try await setModule(tenant, true, by: alice) }
        return World(alice: alice, tenantA: tenant)
    }

    func setModule(_ tenant: String, _ enabled: Bool, by s: TestSession) async throws {
        let r = try await call(app1, .PUT, "api/v1/tenants/\(tenant)/modules/invoice", json: ["enabled": enabled], token: s.token)
        XCTAssertEqual(r.status, .ok, "\(r.json)")
    }

    func addUser(_ role: String, handle: String, tenant: String, by: TestSession) async throws -> TestSession {
        let token = try await invite(app1, by: by, tenant: tenant, role: role)
        let r = try await register(app1, VirtualAuthenticator(), invite: token, handle: handle)
        XCTAssertEqual(r.status, .created, "\(r.json)")
        return session(r, handle: handle)
    }

    func base(_ tenant: String) -> String { "api/v1/tenants/\(tenant)/invoice" }
    func items(_ r: Resp) -> [[String: Any]] { r.json["items"] as? [[String: Any]] ?? [] }

    func count(_ table: String, where clause: String = "TRUE") async throws -> Int64 {
        try await scalar("SELECT count(*)::bigint AS v FROM \(table) WHERE \(clause)", as: Int64.self)
    }

    func aEq<T: Equatable>(_ a: @autoclosure () async throws -> T, _ b: @autoclosure () throws -> T, _ m: @autoclosure () -> String = "",
                           file: StaticString = #filePath, line: UInt = #line) async throws {
        let v = try await a(); let e = try b(); XCTAssertEqual(v, e, m(), file: file, line: line)
    }

    func parallel(_ n: Int, _ body: @escaping @Sendable (Int) async throws -> Resp) async throws -> [Resp] {
        try await withThrowingTaskGroup(of: Resp.self) { group in
            for i in 0..<n { group.addTask { try await body(i) } }
            var out: [Resp] = []
            for try await r in group { out.append(r) }
            return out
        }
    }

    func series(_ w: World, code: String = "re", format: String = "RE-{N:4}", extra: [String: Any] = [:], via: Application? = nil) async throws -> Resp {
        var body: [String: Any] = ["code": code, "name": "Rechnungen", "number_format": format]
        for (k, v) in extra { body[k] = v }
        return try await call(via ?? app1, .POST, base(w.tenantA) + "/series", json: body, token: w.alice.token)
    }
}

final class InvoiceMasterTests: InvoiceTestBase {

    // MARK: AK-R1-1 Modul aus

    /// AK-R1-1: Ohne Aktivierung liefert jede Invoice-Route 404 `module_disabled` (abwechselnd auf beiden Instanzen), anonym 401; nach Aktivierung geht es.
    func testAKR1_1_DisabledModuleReturns404OnAllRoutes() async throws {
        let w = try await world(enable: false)
        let routes = app1.moduleRoutes.filter { $0.module == "invoice" }
        XCTAssertGreaterThanOrEqual(routes.count, 20)
        let moduleOps = OpenAPIContract.serverOperations(app1).filter { $0.contains("/api/v1/tenants/{tenant}/invoice") }
        XCTAssertEqual(moduleOps, Set(routes.map { "\($0.method) \($0.path)" }))
        var n = 0
        for route in routes {
            let app = n % 2 == 0 ? app1! : app2!; n += 1
            let path = String(route.path.dropFirst()).replacingOccurrences(of: "{tenant}", with: w.tenantA).replacingOccurrences(of: "{id}", with: UUID().uuidString)
            let r = try await call(app, HTTPMethod(rawValue: route.method), path, json: route.method == "GET" ? nil : ["name": "x"], token: w.alice.token)
            XCTAssertEqual(r.status, .notFound, "\(route.method) \(route.path)")
            XCTAssertEqual(r.problemCode, "module_disabled", "\(route.method) \(route.path)")
            let anon = try await call(app, HTTPMethod(rawValue: route.method), path, json: route.method == "GET" ? nil : ["name": "x"])
            XCTAssertEqual(anon.status, .unauthorized, "\(route.method) \(route.path)")
        }
        try await setModule(w.tenantA, true, by: w.alice)
        let r = try await call(app2, .GET, base(w.tenantA) + "/items", token: w.alice.token)
        XCTAssertEqual(r.status, .ok)
        // Navigation nur bei wirksamem Modul, mit Leserecht
        let nav = try await call(app1, .GET, "api/v1/tenants/\(w.tenantA)/modules", token: w.alice.token)
        XCTAssertTrue((nav.json["navigation"] as? [[String: Any]] ?? []).contains { $0["module"] as? String == "invoice" })
    }

    // MARK: AK-R1-2 Berechtigungen

    /// AK-R1-2: owner/accountant schreiben, member und tax_advisor nur lesen, customer_viewer nichts; Verbot = 403 ohne Nebenwirkung.
    func testAKR1_2_PermissionMatrix() async throws {
        let w = try await world()
        var sessions: [Role: TestSession] = [.owner: w.alice]
        for role in Role.allCases where role != .owner {
            sessions[role] = try await addUser(role.rawValue, handle: "u_" + role.rawValue, tenant: w.tenantA, by: w.alice)
        }
        let probe = (try await series(w)).json["id"] as! String
        let writers: Set<Role> = [.owner, .accountant], readers: Set<Role> = [.owner, .accountant, .member, .taxAdvisor]
        let declared = InvoiceModule().permissions
        for role in Role.allCases {
            let actual = Set(declared.filter { role == .owner || $0.roles.contains(role) }.map(\.name))
            XCTAssertEqual(actual.contains("invoice.master.manage"), writers.contains(role), role.rawValue)
            XCTAssertEqual(actual.contains("invoice.master.read"), readers.contains(role), role.rawValue)
        }
        func fingerprint() async throws -> String {
            try await scalar("""
                SELECT concat_ws('|', (SELECT count(*) FROM invoice_series), (SELECT count(*) FROM invoice_items), (SELECT count(*) FROM invoice_tax_periods),
                  (SELECT count(*) FROM invoice_document_types), (SELECT count(*) FROM invoice_settings), (SELECT count(*) FROM audit_log WHERE action LIKE 'invoice.%')) AS v
                """, as: String.self)
        }
        let before = try await fingerprint()
        let routes = app1.moduleRoutes.filter { $0.module == "invoice" && $0.permission.hasPrefix("invoice.master.") }   // Belege: InvoiceDocumentTests
        for route in routes {
            let isRead = route.permission == "invoice.master.read"
            XCTAssertTrue(isRead || route.permission == "invoice.master.manage", route.path)
            for (role, s) in sessions {
                let allowed = isRead ? readers.contains(role) : writers.contains(role)
                guard !allowed else { continue }   // erlaubte Schreibwege prüfen die Fachtests; hier zählt das Verbot
                let path = String(route.path.dropFirst()).replacingOccurrences(of: "{tenant}", with: w.tenantA).replacingOccurrences(of: "{id}", with: probe)
                let r = try await call(app2, HTTPMethod(rawValue: route.method), path, json: route.method == "GET" ? nil : ["name": "Hack"], token: s.token)
                XCTAssertEqual(r.status, .forbidden, "\(role.rawValue) \(route.method) \(route.path)")
                XCTAssertEqual(r.problemCode, "forbidden")
            }
        }
        let afterDenied = try await fingerprint()
        XCTAssertEqual(afterDenied, before, "Verbote ohne Nebenwirkung")
        // erlaubt: Lesen für alle vier Rollen, Schreiben für owner und accountant
        for role in readers {
            let r = try await call(app1, .GET, base(w.tenantA) + "/series", token: sessions[role]!.token)
            XCTAssertEqual(r.status, .ok, role.rawValue)
            XCTAssertEqual(items(r).count, 1)
            try await aEq((try await call(app1, .GET, base(w.tenantA) + "/settings", token: sessions[role]!.token)).status, .ok)
        }
        for role in writers {
            let r = try await call(app2, .POST, base(w.tenantA) + "/items", json: ["name": "Artikel \(role.rawValue)", "unit_price": "1.00", "tax_rate": "19"], token: sessions[role]!.token)
            XCTAssertEqual(r.status, .created, "\(role.rawValue) \(r.json)")
            let p = try await call(app1, .PUT, base(w.tenantA) + "/settings", json: ["sender_name": "Muster GmbH \(role.rawValue)"], token: sessions[role]!.token)
            XCTAssertEqual(p.status, .ok, "\(role.rawValue) \(p.json)")
        }
    }

    // MARK: AK-R1-3 Mandantentrennung

    /// AK-R1-3: Fremder Mandant = 404 auf allen Routen, fremde IDs im eigenen Mandanten = 404, Listen getrennt, Verweise über Mandantengrenzen scheitern (auch per SQL).
    func testAKR1_3_TenantIsolation() async throws {
        let w = try await world()
        let tenantB = (try await call(app1, .POST, "api/v1/tenants", json: ["name": "Zweiter Mandant"], token: w.alice.token)).json["id"] as! String
        let carol = try await addUser("owner", handle: "carol", tenant: tenantB, by: w.alice)
        try await setModule(tenantB, true, by: carol)
        let a = base(w.tenantA), b = base(tenantB)

        let seriesA = (try await series(w)).json["id"] as! String
        let itemA = (try await call(app1, .POST, a + "/items", json: ["name": "Nur A", "unit_price": "5", "tax_rate": "19"], token: w.alice.token)).json["id"] as! String
        let periodA = (try await call(app1, .POST, a + "/tax-periods", json: ["regime": "standard", "valid_from": "2026-01-01"], token: w.alice.token)).json["id"] as! String
        let typeA = (try await call(app1, .POST, a + "/document-types", json: ["code": "invoice", "name": "Rechnung", "kind": "invoice"], token: w.alice.token)).json["id"] as! String
        _ = try await call(app1, .PUT, a + "/settings", json: ["sender_name": "Absender A"], token: w.alice.token)

        let probes: [(HTTPMethod, String, [String: Any]?)] = [
            (.GET, "/series/\(seriesA)", nil), (.PATCH, "/series/\(seriesA)", ["name": "Hack"]), (.DELETE, "/series/\(seriesA)", nil),
            (.GET, "/items/\(itemA)", nil), (.PATCH, "/items/\(itemA)", ["name": "Hack"]), (.DELETE, "/items/\(itemA)", nil),
            (.GET, "/tax-periods/\(periodA)", nil), (.PATCH, "/tax-periods/\(periodA)", ["note": "Hack"]), (.DELETE, "/tax-periods/\(periodA)", nil),
            (.GET, "/document-types/\(typeA)", nil), (.PATCH, "/document-types/\(typeA)", ["name": "Hack"]), (.DELETE, "/document-types/\(typeA)", nil)]
        for (m, p, body) in probes {
            let r = try await call(app2, m, b + p, json: body, token: carol.token)
            XCTAssertEqual(r.status, .notFound, "\(m) \(p)")
        }
        // Carol auf dem Pfad von Mandant A: kein Mitglied = 404 auf allen Routen
        for route in app1.moduleRoutes where route.module == "invoice" {
            let path = String(route.path.dropFirst()).replacingOccurrences(of: "{tenant}", with: w.tenantA).replacingOccurrences(of: "{id}", with: seriesA)
            let r = try await call(app1, HTTPMethod(rawValue: route.method), path, json: route.method == "GET" ? nil : ["name": "x"], token: carol.token)
            XCTAssertEqual(r.status, .notFound, "\(route.method) \(route.path)")
            XCTAssertEqual(r.problemCode, "not_found")
        }
        // Daten unverändert, Listen getrennt
        try await aEq(try await scalar("SELECT name AS v FROM invoice_series WHERE id = '\(seriesA)'", as: String.self), "Rechnungen")
        try await aEq(try await scalar("SELECT name AS v FROM invoice_items WHERE id = '\(itemA)'", as: String.self), "Nur A")
        for seg in ["series", "items", "tax-periods", "document-types"] { try await aEq(items(try await call(app1, .GET, "\(b)/\(seg)", token: carol.token)).count, 0, seg) }
        let settingsB = try await call(app1, .GET, b + "/settings", token: carol.token)
        XCTAssertEqual(settingsB.json["configured"] as? Bool, false)
        XCTAssertNil(settingsB.json["sender_name"] as? String)
        // Verweis auf fremde Serie: 422 (API) und Fremdschlüssel (SQL)
        let r = try await call(app1, .POST, b + "/document-types", json: ["code": "invoice", "name": "Rechnung", "kind": "invoice", "default_series_id": seriesA], token: carol.token)
        XCTAssertEqual(r.status, .unprocessableEntity); XCTAssertEqual(r.problemCode, "validation_failed")
        do {
            try await db.raw(SQLQueryString("INSERT INTO invoice_document_types (tenant_id, code, name, kind, default_series_id) VALUES ('\(tenantB)', 'x', 'X', 'invoice', '\(seriesA)')")).run()
            XCTFail("Fremdschlüssel über Mandantengrenzen muss scheitern")
        } catch {}
        // gleiche Codes in verschiedenen Mandanten sind erlaubt
        let sameCode = try await call(app1, .POST, b + "/series", json: ["code": "re", "name": "B", "number_format": "RE-{N}"], token: carol.token)
        XCTAssertEqual(sameCode.status, .created)
    }

    // MARK: AK-R1-4 Einstellungen

    /// AK-R1-4: Absender/Einstellungen: Standardwerte ohne Zeile, Ersetzen (PUT), Prüfung von IBAN, Land, Währung; zweite Instanz sieht den Stand; Audit.
    func testAKR1_4_Settings() async throws {
        let w = try await world()
        let s = base(w.tenantA) + "/settings"
        let empty = try await call(app1, .GET, s, token: w.alice.token)
        XCTAssertEqual(empty.status, .ok)
        XCTAssertEqual(empty.json["configured"] as? Bool, false)
        XCTAssertEqual(empty.json["currency"] as? String, "EUR")
        XCTAssertEqual(empty.json["payment_term_days"] as? Int, 14)
        try await aEq(try await count("invoice_settings"), 0, "Lesen legt nichts an")

        let bad: [[String: Any]] = [
            ["sender_name": ""], [:], ["sender_name": "X", "iban": "DE89370400440532013001"], ["sender_name": "X", "iban": "nope"],
            ["sender_name": "X", "country": "Deutschland"], ["sender_name": "X", "currency": "eur"], ["sender_name": "X", "payment_term_days": -1],
            ["sender_name": "X", "unknown": 1], ["sender_name": "X", "email": "kein-mail"]]
        for body in bad {
            let r = try await call(app1, .PUT, s, json: body, token: w.alice.token)
            XCTAssertEqual(r.status, .unprocessableEntity, "\(body)")
            XCTAssertEqual(r.problemCode, "validation_failed")
        }
        let ok = try await call(app1, .PUT, s, json: ["sender_name": "Muster GmbH", "street": "Musterweg 1", "postal_code": "12345", "city": "Musterstadt", "country": "DE",
                                                       "iban": "DE89 3704 0044 0532 0130 00", "bic": "COBADEFFXXX", "email": "rechnung@example.org", "currency": "EUR",
                                                       "payment_term_days": 30, "abbreviation": "MU"], token: w.alice.token)
        XCTAssertEqual(ok.status, .ok, "\(ok.json)")
        XCTAssertEqual(ok.json["iban"] as? String, "DE89370400440532013000", "IBAN ohne Leerzeichen gespeichert")
        XCTAssertEqual(ok.json["configured"] as? Bool, true)
        XCTAssertEqual(ok.json["rev"] as? Int, 1)
        let again = try await call(app2, .PUT, s, json: ["sender_name": "Muster GmbH 2"], token: w.alice.token)
        XCTAssertEqual(again.status, .ok)
        XCTAssertEqual(again.json["rev"] as? Int, 2)
        XCTAssertNil(again.json["street"] as? String, "PUT ersetzt: nicht genannte Felder werden leer")
        XCTAssertEqual(again.json["payment_term_days"] as? Int, 14)
        try await aEq(try await count("invoice_settings"), 1)
        let read = try await call(app1, .GET, s, token: w.alice.token)
        XCTAssertEqual(read.json["sender_name"] as? String, "Muster GmbH 2")
        // zwei Instanzen gleichzeitig: genau eine Zeile, Revision lückenlos
        let rs = try await parallel(8) { i in try await self.call(i % 2 == 0 ? self.app1 : self.app2, .PUT, s, json: ["sender_name": "P\(i)"], token: w.alice.token) }
        XCTAssertTrue(rs.allSatisfy { $0.status == .ok })
        try await aEq(try await count("invoice_settings"), 1)
        try await aEq(try await scalar("SELECT rev::int AS v FROM invoice_settings", as: Int.self), 10)
        try await aEq(try await count("audit_log", where: "action = 'invoice.settings.updated' AND tenant_id = '\(w.tenantA)' AND actor_user_id = '\(w.alice.userID)'"), 10)
        try await aEq(try await count("audit_log", where: "meta::text ILIKE '%Muster%' OR meta::text ILIKE '%DE89%'"), 0, "Audit ohne Nutzdaten")
    }

    // MARK: AK-R1-5 Steuerzeiträume

    /// AK-R1-5: Steuerzeiträume überlappen nicht (API und Datenbank), angrenzende sind erlaubt, offenes Ende nur zuletzt; parallele Anlage über zwei Instanzen: genau eine gewinnt.
    func testAKR1_5_TaxPeriods() async throws {
        let w = try await world()
        let t = base(w.tenantA) + "/tax-periods"
        let p1 = try await call(app1, .POST, t, json: ["regime": "small_business", "valid_from": "2025-01-01", "valid_to": "2025-12-31", "note": "Kleinunternehmer"], token: w.alice.token)
        XCTAssertEqual(p1.status, .created, "\(p1.json)")
        XCTAssertEqual(p1.json["valid_from"] as? String, "2025-01-01")
        XCTAssertEqual(p1.json["regime"] as? String, "small_business")
        let p2 = try await call(app2, .POST, t, json: ["regime": "standard", "valid_from": "2026-01-01"], token: w.alice.token)
        XCTAssertEqual(p2.status, .created, "\(p2.json)")
        XCTAssertTrue(p2.json["valid_to"] is NSNull || p2.json["valid_to"] == nil)
        let overlapping: [[String: Any]] = [["regime": "standard", "valid_from": "2025-12-31", "valid_to": "2026-02-01"], ["regime": "standard", "valid_from": "2030-01-01"],
                                           ["regime": "standard", "valid_from": "2024-01-01", "valid_to": "2025-01-01"]]
        for body in overlapping {
            let r = try await call(app1, .POST, t, json: body, token: w.alice.token)
            XCTAssertEqual(r.status, .conflict, "\(body)")
            XCTAssertEqual(r.problemCode, "tax_period_overlap")
        }
        let invalid: [[String: Any]] = [["regime": "x", "valid_from": "2020-01-01"], ["regime": "standard"], ["regime": "standard", "valid_from": "2020-13-01"],
                                       ["regime": "standard", "valid_from": "2020-05-01", "valid_to": "2020-04-30"], ["regime": "standard", "valid_from": "2020-01-01", "nope": 1]]
        for body in invalid {
            let r = try await call(app1, .POST, t, json: body, token: w.alice.token)
            XCTAssertEqual(r.status, .unprocessableEntity, "\(body)")
        }
        // Ändern: Überlappung beim Verlängern abgelehnt, Notiz ändern geht, Sich-selbst-Überlappen ist kein Konflikt
        let id1 = p1.json["id"] as! String
        try await aEq((try await call(app1, .PATCH, "\(t)/\(id1)", json: ["valid_to": "2026-03-31"], token: w.alice.token)).problemCode, "tax_period_overlap")
        try await aEq((try await call(app1, .PATCH, "\(t)/\(id1)", json: ["note": "geändert"], token: w.alice.token)).status, .ok)
        let id2 = p2.json["id"] as! String
        try await aEq((try await call(app2, .PATCH, "\(t)/\(id2)", json: ["valid_from": "2026-01-02"], token: w.alice.token)).status, .ok)
        try await aEq(items(try await call(app1, .GET, t, token: w.alice.token)).map { $0["valid_from"] as? String }, ["2025-01-01", "2026-01-02"], "Liste nach Beginn sortiert")
        // Datenbank als Rückfall: direkte Überlappung scheitert
        do {
            try await db.raw(SQLQueryString("INSERT INTO invoice_tax_periods (tenant_id, regime, valid_from, valid_to) VALUES ('\(w.tenantA)', 'standard', '2025-06-01', '2025-06-30')")).run()
            XCTFail("Überlappung muss in der Datenbank scheitern")
        } catch {}
        // parallel über zwei Instanzen
        try await aEq((try await call(app1, .DELETE, "\(t)/\(id2)", token: w.alice.token)).status, .noContent)
        let rs = try await parallel(8) { i in
            try await self.call(i % 2 == 0 ? self.app1 : self.app2, .POST, t, json: ["regime": "standard", "valid_from": "2026-0\(1 + i % 3)-01", "valid_to": "2026-12-31"], token: w.alice.token)
        }
        XCTAssertEqual(rs.filter { $0.status == .created }.count, 1, "\(rs.map { $0.status.code })")
        XCTAssertEqual(rs.filter { $0.problemCode == "tax_period_overlap" }.count, 7)
        try await aEq(try await count("invoice_tax_periods"), 2)
        try await aEq((try await call(app2, .DELETE, "\(t)/\(UUID().uuidString)", token: w.alice.token)).status, .notFound)
    }

    // MARK: AK-R1-6 Nummernserien

    /// AK-R1-6: Nummernformat wird geprüft (Platzhalter-Syntax), Gültigkeitsbereich folgt aus dem Format, Anfangsnummer über den Kernzähler (Audit), nach Nummernvergabe weder Format noch Löschen.
    func testAKR1_6_Series() async throws {
        let w = try await world()
        let sBase = base(w.tenantA) + "/series"
        for (fmt, code) in [("{FOO}{N}", "unknown_token"), ("{N", "unbalanced_brace"), ("{YYYY}", "counter_count"), ("{N}{N}", "counter_count"), ("{N:0}", "invalid_digits"), ("", "required")] {
            let r = try await series(w, code: "x", format: fmt)
            XCTAssertEqual(r.status, .unprocessableEntity, fmt)
            XCTAssertEqual((r.json["errors"] as? [[String: Any]])?.first?["field"] as? String, "number_format", fmt)
            XCTAssertEqual((r.json["errors"] as? [[String: Any]])?.first?["code"] as? String, code, fmt)
        }
        _ = try await call(app1, .PUT, base(w.tenantA) + "/settings", json: ["sender_name": "M", "abbreviation": "MU"], token: w.alice.token)
        let cont = try await series(w, code: "re", format: "RE-{N:4}", extra: ["start_number": 100])
        XCTAssertEqual(cont.status, .created, "\(cont.json)")
        XCTAssertEqual(cont.json["counter_scope"] as? String, "continuous")
        XCTAssertEqual(cont.json["next_number"] as? Int, 100)
        XCTAssertEqual(cont.json["next_number_preview"] as? String, "RE-0100")
        XCTAssertEqual(cont.json["in_use"] as? Bool, true, "Anfangsnummer > 1 hebt den Kernzähler an")
        let year = try await scalar("SELECT extract(year FROM (now() AT TIME ZONE 'UTC'))::int AS v", as: Int.self)
        let yearly = try await series(w, code: "yr", format: "{ABBR}-{YYYY}-{N:3}", extra: ["start_number": 7])
        XCTAssertEqual(yearly.json["counter_scope"] as? String, "per_year")
        XCTAssertEqual(yearly.json["next_number_preview"] as? String, "MU-\(year)-007")
        let monthly = try await series(w, code: "mo", format: "{YYYY}{MM}-{N}")
        XCTAssertEqual(monthly.json["counter_scope"] as? String, "per_month")
        XCTAssertEqual(monthly.json["next_number"] as? Int, 1)
        XCTAssertEqual(monthly.json["in_use"] as? Bool, false)
        let needsClient = try await series(w, code: "cl", format: "{CLIENT}-{N}")
        XCTAssertEqual(needsClient.status, .created)
        XCTAssertTrue(needsClient.json["next_number_preview"] is NSNull || needsClient.json["next_number_preview"] == nil, "Vorschau ohne Kundennummer nicht möglich")

        // Kernzähler: nächste Nummer stimmt mit der Anzeige überein (auch über die zweite Instanz), Audit der Anhebung
        let contID = UUID(uuidString: cont.json["id"] as! String)!
        let key = InvoiceNumbering.counterKey(series: contID, scope: .continuous, year: year, month: 1)
        let sqlDB = app2.db(.psql) as! any SQLDatabase
        let issued = try await CounterService(sqlDB).next(tenant: UUID(uuidString: w.tenantA)!, key: key)
        XCTAssertEqual(issued, 100)
        try await aEq(try await count("audit_log", where: "action = 'counter.raised' AND tenant_id = '\(w.tenantA)'"), 2)
        let shown = try await call(app1, .GET, "\(sBase)/\(contID.uuidString)", token: w.alice.token)
        XCTAssertEqual(shown.json["next_number"] as? Int, 101)

        // benutzt: Format und Löschen gesperrt, Name änderbar
        let id = contID.uuidString
        try await aEq((try await call(app1, .PATCH, "\(sBase)/\(id)", json: ["number_format": "R{N}"], token: w.alice.token)).problemCode, "series_in_use")
        try await aEq((try await call(app1, .DELETE, "\(sBase)/\(id)", token: w.alice.token)).problemCode, "series_in_use")
        try await aEq((try await call(app1, .PATCH, "\(sBase)/\(id)", json: ["name": "Neu", "number_format": "RE-{N:4}"], token: w.alice.token)).status, .ok, "gleiches Format ist keine Änderung")
        // unbenutzt: Format änderbar, Gültigkeitsbereich folgt, Löschen geht
        let mid = monthly.json["id"] as! String
        let changed = try await call(app2, .PATCH, "\(sBase)/\(mid)", json: ["number_format": "{YYYY}-{N}"], token: w.alice.token)
        XCTAssertEqual(changed.status, .ok, "\(changed.json)")
        XCTAssertEqual(changed.json["counter_scope"] as? String, "per_year")
        try await aEq((try await call(app1, .PATCH, "\(sBase)/\(mid)", json: ["number_format": "{N"], token: w.alice.token)).status, .unprocessableEntity)
        // Standardserie eines Belegtyps verhindert das Löschen
        let dt = try await call(app1, .POST, base(w.tenantA) + "/document-types", json: ["code": "invoice", "name": "Rechnung", "kind": "invoice", "default_series_id": mid], token: w.alice.token)
        XCTAssertEqual(dt.status, .created, "\(dt.json)")
        try await aEq((try await call(app1, .DELETE, "\(sBase)/\(mid)", token: w.alice.token)).status, .conflict)
        try await aEq((try await call(app1, .DELETE, "\(base(w.tenantA))/document-types/\(dt.json["id"] as! String)", token: w.alice.token)).status, .noContent)
        try await aEq((try await call(app1, .DELETE, "\(sBase)/\(mid)", token: w.alice.token)).status, .noContent)
        try await aEq((try await call(app1, .GET, "\(sBase)/\(mid)", token: w.alice.token)).status, .notFound)
        // doppelter Code: genau einer gewinnt, auch parallel über zwei Instanzen
        try await aEq((try await series(w, code: "re")).status, .conflict)
        let rs = try await parallel(8) { i in try await self.series(w, code: "par", extra: [:], via: i % 2 == 0 ? self.app1 : self.app2) }
        XCTAssertEqual(rs.filter { $0.status == .created }.count, 1)
        XCTAssertEqual(rs.filter { $0.status == .conflict }.count, 7)
        let invalid: [[String: Any]] = [["code": "Re X", "name": "n", "number_format": "{N}"], ["code": "x1", "name": "", "number_format": "{N}"],
                                       ["code": "x2", "name": "n", "number_format": "{N}", "start_number": 0], ["code": "x3", "name": "n", "number_format": "{N}", "start_number": "5"],
                                       ["code": "x4", "name": "n", "number_format": "{N}", "nope": true]]
        for bad in invalid {
            let r = try await call(app1, .POST, sBase, json: bad, token: w.alice.token)
            XCTAssertEqual(r.status, .unprocessableEntity, "\(bad)")
        }
    }

    // MARK: AK-R1-7 Belegtypen

    /// AK-R1-7: Belegtypen: feste Arten, eindeutiger Code/Name, Standardserie aus demselben Mandanten.
    func testAKR1_7_DocumentTypes() async throws {
        let w = try await world()
        let t = base(w.tenantA) + "/document-types"
        let ser = (try await series(w)).json["id"] as! String
        let kinds = ["quote", "order_confirmation", "delivery_note", "invoice", "credit_note"]
        for (i, kind) in kinds.enumerated() {
            let r = try await call(app1, .POST, t, json: ["code": "t\(i)", "name": "Typ \(i)", "kind": kind], token: w.alice.token)
            XCTAssertEqual(r.status, .created, "\(kind) \(r.json)")
            XCTAssertEqual(r.json["kind"] as? String, kind)
            XCTAssertEqual(r.json["active"] as? Bool, true)
        }
        let invalid: [[String: Any]] = [["code": "t9", "name": "X", "kind": "bogus"], ["code": "T 9", "name": "X", "kind": "invoice"], ["name": "X", "kind": "invoice"],
                                       ["code": "t9", "name": "X", "kind": "invoice", "default_series_id": UUID().uuidString], ["code": "t9", "name": "X", "kind": "invoice", "default_series_id": "kaputt"]]
        for bad in invalid {
            let r = try await call(app1, .POST, t, json: bad, token: w.alice.token)
            XCTAssertEqual(r.status, .unprocessableEntity, "\(bad)")
        }
        try await aEq((try await call(app1, .POST, t, json: ["code": "t0", "name": "Anders", "kind": "invoice"], token: w.alice.token)).status, .conflict)
        try await aEq((try await call(app1, .POST, t, json: ["code": "neu", "name": "TYP 0", "kind": "invoice"], token: w.alice.token)).status, .conflict, "Name ohne Beachtung der Groß-/Kleinschreibung eindeutig")
        let withSeries = try await call(app2, .POST, t, json: ["code": "rg", "name": "Rechnung", "kind": "invoice", "default_series_id": ser], token: w.alice.token)
        XCTAssertEqual(withSeries.status, .created)
        XCTAssertEqual((withSeries.json["default_series_id"] as? String)?.lowercased(), ser.lowercased())
        let id = withSeries.json["id"] as! String
        try await aEq((try await call(app1, .PATCH, "\(t)/\(id)", json: ["active": false, "default_series_id": NSNull()], token: w.alice.token)).json["active"] as? Bool, false)
        let listed = items(try await call(app1, .GET, t, token: w.alice.token))
        XCTAssertEqual(listed.count, 6)
    }

    // MARK: AK-R1-8 Artikel und Geldbeträge

    /// AK-R1-8: Artikel: Beträge nur als Dezimal-Strings (numeric), verlustfrei, kein Gleitkomma in Eingabe, Ausgabe und Schema.
    func testAKR1_8_ItemsAndMoney() async throws {
        let w = try await world()
        let t = base(w.tenantA) + "/items"
        let r = try await call(app1, .POST, t, json: ["sku": "A-1", "name": "Beratung", "description": "Stunde", "unit": "h", "unit_price": "1234567890.1234", "tax_rate": "19",
                                                       "price_includes_tax": false, "track_stock": true, "stock_quantity": "12.5"], token: w.alice.token)
        XCTAssertEqual(r.status, .created, "\(r.json)")
        XCTAssertEqual(r.json["unit_price"] as? String, "1234567890.1234")
        XCTAssertEqual(r.json["tax_rate"] as? String, "19.0000")
        XCTAssertEqual(r.json["stock_quantity"] as? String, "12.5000")
        XCTAssertEqual(r.json["active"] as? Bool, true)
        let id = r.json["id"] as! String
        let small = try await call(app2, .POST, t, json: ["name": "Kleinbetrag", "unit_price": "0.1", "tax_rate": "7"], token: w.alice.token)
        XCTAssertEqual(small.json["unit_price"] as? String, "0.1000", "0,1 bleibt exakt, keine 0.1000000000000000055")
        try await aEq(try await scalar("SELECT (unit_price = 0.1)::text AS v FROM invoice_items WHERE id = '\(small.json["id"] as! String)'", as: String.self), "true")
        let neg = try await call(app1, .POST, t, json: ["name": "Rabatt", "unit_price": "-5.5", "tax_rate": "0"], token: w.alice.token)
        XCTAssertEqual(neg.status, .created); XCTAssertEqual(neg.json["unit_price"] as? String, "-5.5000")

        let bad: [[String: Any]] = [
            ["name": "X", "unit_price": 19.99, "tax_rate": "19"],                      // JSON-Zahl (Gleitkomma) abgelehnt
            ["name": "X", "unit_price": 20, "tax_rate": "19"],                         // auch ganze JSON-Zahlen
            ["name": "X", "unit_price": "1.12345", "tax_rate": "19"],                  // mehr als 4 Nachkommastellen: nie still runden
            ["name": "X", "unit_price": "1,5", "tax_rate": "19"], ["name": "X", "unit_price": "1e3", "tax_rate": "19"], ["name": "X", "unit_price": "abc", "tax_rate": "19"],
            ["name": "X", "unit_price": "100000000000000.0000", "tax_rate": "19"],     // über numeric(18,4)
            ["name": "X", "unit_price": "1", "tax_rate": "100.0001"], ["name": "X", "unit_price": "1", "tax_rate": "-1"], ["name": "X", "unit_price": "1"],
            ["name": "X", "unit_price": "1", "tax_rate": "19", "stock_quantity": "3"],   // Bestand ohne Bestandsführung
            ["name": "", "unit_price": "1", "tax_rate": "19"], ["unit_price": "1", "tax_rate": "19"]]
        for body in bad {
            let e = try await call(app1, .POST, t, json: body, token: w.alice.token)
            XCTAssertEqual(e.status, .unprocessableEntity, "\(body)")
        }
        try await aEq((try await call(app1, .POST, t, json: ["sku": "A-1", "name": "Doppelt", "unit_price": "1", "tax_rate": "19"], token: w.alice.token)).status, .conflict)
        let upd = try await call(app2, .PATCH, "\(t)/\(id)", json: ["unit_price": "99.99", "track_stock": false, "stock_quantity": NSNull(), "active": false], token: w.alice.token)
        XCTAssertEqual(upd.status, .ok, "\(upd.json)")
        XCTAssertEqual(upd.json["unit_price"] as? String, "99.9900")
        try await aEq((try await call(app1, .PATCH, "\(t)/\(id)", json: ["unit_price": 5.5], token: w.alice.token)).status, .unprocessableEntity)
        let list = try await call(app1, .GET, t, token: w.alice.token)
        XCTAssertEqual(items(list).count, 3)
        try await aEq(items(try await call(app1, .GET, t + "?active=true", token: w.alice.token)).count, 2)
        try await aEq(items(try await call(app1, .GET, t + "?q=berat", token: w.alice.token)).map { $0["name"] as? String }, ["Beratung"])

        // Schema: kein Gleitkomma, Beträge numeric mit festem Maßstab
        try await aEq(try await count("information_schema.columns", where: "table_name LIKE 'invoice\\_%' AND data_type IN ('double precision', 'real', 'money')"), 0)
        try await aEq(try await scalar("SELECT concat(numeric_precision, ',', numeric_scale) AS v FROM information_schema.columns WHERE table_name = 'invoice_items' AND column_name = 'unit_price'", as: String.self), "18,4")
        try await aEq((try await call(app1, .DELETE, "\(t)/\(id)", token: w.alice.token)).status, .noContent)
        try await aEq((try await call(app1, .GET, "\(t)/\(id)", token: w.alice.token)).status, .notFound)
    }

    // MARK: AK-R1-9 Idempotenz

    /// AK-R1-9: Anlegen mit `Idempotency-Key`: Wiederholung (auch über die andere Instanz und parallel) liefert dieselbe Antwort ohne zweite Zeile; anderer Inhalt unter demselben Key = 422.
    func testAKR1_9_IdempotentCreate() async throws {
        let w = try await world()
        let t = base(w.tenantA) + "/items"
        let body: [String: Any] = ["name": "Einmalig", "unit_price": "10", "tax_rate": "19"]
        let first = try await call(app1, .POST, t, json: body, token: w.alice.token, headers: ["Idempotency-Key": "k-1"])
        XCTAssertEqual(first.status, .created)
        let second = try await call(app2, .POST, t, json: body, token: w.alice.token, headers: ["Idempotency-Key": "k-1"])
        XCTAssertEqual(second.status, .created)
        XCTAssertEqual(second.json["id"] as? String, first.json["id"] as? String)
        try await aEq(try await count("invoice_items"), 1)
        let other = try await call(app1, .POST, t, json: ["name": "Anders", "unit_price": "10", "tax_rate": "19"], token: w.alice.token, headers: ["Idempotency-Key": "k-1"])
        XCTAssertEqual(other.status, .unprocessableEntity); XCTAssertEqual(other.problemCode, "idempotency_key_reused")
        // Fehler gibt den Key frei und hinterlässt nichts
        let fail = try await call(app1, .POST, t, json: ["name": "", "unit_price": "10", "tax_rate": "19"], token: w.alice.token, headers: ["Idempotency-Key": "k-2"])
        XCTAssertEqual(fail.status, .unprocessableEntity)
        try await aEq(try await count("idempotency_keys", where: "key = 'k-2'"), 0)
        // parallel, gleicher Key
        nonisolated(unsafe) let same: [String: Any] = ["name": "Parallel", "unit_price": "1", "tax_rate": "19"]   // eine Instanz des Wörterbuchs: identische Serialisierung, damit der Request-Hash gleich ist
        let rs = try await parallel(8) { i in
            try await self.call(i % 2 == 0 ? self.app1 : self.app2, .POST, "\(t)", json: same, token: w.alice.token, headers: ["Idempotency-Key": "k-3"])
        }
        XCTAssertTrue(rs.allSatisfy { $0.status == .created }, "\(rs.map { $0.status.code })")
        XCTAssertEqual(Set(rs.compactMap { $0.json["id"] as? String }).count, 1)
        try await aEq(try await count("invoice_items", where: "name = 'Parallel'"), 1)
        // ohne Key weiter möglich (optional); zu langer Key abgelehnt
        try await aEq((try await call(app1, .POST, t, json: ["name": "Ohne Key", "unit_price": "1", "tax_rate": "19"], token: w.alice.token)).status, .created)
        let tooLong = try await call(app1, .POST, t, json: body, token: w.alice.token, headers: ["Idempotency-Key": String(repeating: "x", count: 256)])
        XCTAssertEqual(tooLong.status, .badRequest)
    }

    // MARK: AK-R1-10 Audit

    /// AK-R1-10: Jede schreibende Stammdatenaktion steht mit Akteur im Audit-Log; das Audit enthält keine Nutzdaten.
    func testAKR1_10_Audit() async throws {
        let w = try await world()
        let sid = (try await series(w)).json["id"] as! String
        let iid = (try await call(app1, .POST, base(w.tenantA) + "/items", json: ["name": "Geheimname", "unit_price": "10", "tax_rate": "19"], token: w.alice.token)).json["id"] as! String
        _ = try await call(app1, .PATCH, "\(base(w.tenantA))/items/\(iid)", json: ["name": "Anderer Geheimname"], token: w.alice.token)
        _ = try await call(app1, .DELETE, "\(base(w.tenantA))/items/\(iid)", token: w.alice.token)
        _ = try await call(app1, .PATCH, "\(base(w.tenantA))/series/\(sid)", json: ["name": "N"], token: w.alice.token)
        let pid = (try await call(app1, .POST, base(w.tenantA) + "/tax-periods", json: ["regime": "standard", "valid_from": "2026-01-01"], token: w.alice.token)).json["id"] as! String
        _ = try await call(app1, .DELETE, "\(base(w.tenantA))/tax-periods/\(pid)", token: w.alice.token)
        for action in ["invoice.series.created", "invoice.series.updated", "invoice.item.created", "invoice.item.updated", "invoice.item.deleted", "invoice.tax_period.created", "invoice.tax_period.deleted"] {
            try await aEq(try await count("audit_log", where: "action = '\(action)' AND tenant_id = '\(w.tenantA)' AND actor_user_id = '\(w.alice.userID)'"), 1, action)
        }
        try await aEq(try await count("audit_log", where: "action LIKE 'invoice.%' AND subject_id IS NULL"), 0)
        try await aEq(try await count("audit_log", where: "meta::text ILIKE '%Geheim%' OR meta::text ILIKE '%Rechnungen%'"), 0)
        // fehlgeschlagene Anfragen schreiben kein Audit
        let before = try await count("audit_log", where: "action LIKE 'invoice.%'")
        _ = try await call(app1, .POST, base(w.tenantA) + "/items", json: ["name": ""], token: w.alice.token)
        try await aEq(try await count("audit_log", where: "action LIKE 'invoice.%'"), before)
    }

    // MARK: AK-R1-11 Zwei Instanzen

    /// AK-R1-11: Zustand liegt nur in der Datenbank: Anlegen auf Instanz 1, Lesen/Ändern/Löschen auf Instanz 2; Modulschalter wirkt sofort auf beiden.
    func testAKR1_11_TwoInstances() async throws {
        let w = try await world()
        let created = try await call(app1, .POST, base(w.tenantA) + "/items", json: ["name": "Zweiinstanz", "unit_price": "3", "tax_rate": "19"], token: w.alice.token)
        let id = created.json["id"] as! String
        try await aEq((try await call(app2, .GET, "\(base(w.tenantA))/items/\(id)", token: w.alice.token)).json["name"] as? String, "Zweiinstanz")
        try await aEq((try await call(app2, .PATCH, "\(base(w.tenantA))/items/\(id)", json: ["name": "Geändert"], token: w.alice.token)).status, .ok)
        try await aEq((try await call(app1, .GET, "\(base(w.tenantA))/items/\(id)", token: w.alice.token)).json["name"] as? String, "Geändert")
        try await setModule(w.tenantA, false, by: w.alice)
        try await aEq((try await call(app2, .GET, "\(base(w.tenantA))/items/\(id)", token: w.alice.token)).problemCode, "module_disabled")
        try await aEq(try await count("invoice_items"), 1, "Daten bleiben bei abgeschaltetem Modul")
        try await setModule(w.tenantA, true, by: w.alice)
        try await aEq((try await call(app2, .GET, "\(base(w.tenantA))/items/\(id)", token: w.alice.token)).status, .ok)
        // gleichzeitiges Anlegen gleicher SKU: genau eine Zeile
        let rs = try await parallel(8) { i in
            try await self.call(i % 2 == 0 ? self.app1 : self.app2, .POST, "\(self.base(w.tenantA))/items", json: ["sku": "PAR", "name": "P\(i)", "unit_price": "1", "tax_rate": "19"], token: w.alice.token)
        }
        XCTAssertEqual(rs.filter { $0.status == .created }.count, 1)
        XCTAssertEqual(rs.filter { $0.status == .conflict }.count, 7)
    }

    // MARK: AK-R1-12 Migration

    /// AK-R1-12: Modul-Migration ist Expand-only (neue Tabellen, `schema_version` unverändert) und rückbaubar; Tabellen existieren auch bei deaktiviertem Modul.
    func testAKR1_12_MigrationRevertAndReapply() async throws {
        let w = try await world(enable: false)
        let tables = ["invoice_settings", "invoice_tax_periods", "invoice_series", "invoice_document_types", "invoice_items"]
        let versionBefore = try await scalar("SELECT max(version)::int AS v FROM schema_version", as: Int.self)
        for tbl in tables { try await aEq(try await count("information_schema.tables", where: "table_name = '\(tbl)'"), 1, tbl) }
        try await aEq(try await count("_fluent_migrations", where: "name = 'invoice_027_master'"), 1)
        try await aEq((try await call(app1, .GET, "ready")).status, .ok)
        let migration = CreateInvoiceMaster()
        let database = app1.db(.psql)
        try await CreateInvoicePayments().revert(on: database)    // WP-R3 vor WP-R2 zurückbauen
        try await CreateInvoiceDocuments().revert(on: database)   // WP-R2: Belegtabellen verweisen auf die Stammdaten
        try await migration.revert(on: database)
        for tbl in tables { try await aEq(try await count("information_schema.tables", where: "table_name = '\(tbl)'"), 0, tbl) }
        try await aEq(try await count("pg_proc", where: "proname LIKE 'invoice\\_%'"), 0, "Funktionen/Trigger mit zurückgebaut")
        try await migration.prepare(on: database)
        try await CreateInvoiceDocuments().prepare(on: database)
        try await CreateInvoicePayments().prepare(on: database)
        for tbl in tables { try await aEq(try await count("information_schema.tables", where: "table_name = '\(tbl)'"), 1, tbl) }
        try await aEq(try await scalar("SELECT max(version)::int AS v FROM schema_version", as: Int.self), versionBefore)
        XCTAssertFalse(w.tenantA.isEmpty)
    }

    // MARK: AK-R1-13 Nummernformat gegen Testvektoren

    /// AK-R1-13: Nummernformat entspricht den gemeinsamen Testvektoren (`Tests/Fixtures/invoice-vectors/number-format.json`, F-27: Neuimplementierung gegen Vektoren).
    func testAKR1_13_NumberFormatMatchesVectors() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/invoice-vectors/number-format.json")
        let root = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        let vectors = root["vectors"] as! [[String: Any]]
        XCTAssertEqual(vectors.count, 15)
        for v in vectors {
            let id = v["id"] as! String, input = v["input"] as! [String: Any], expected = v["expected"] as! [String: Any]
            let template = input["template"] as! String
            let counter = Int64(input["counter"] as! Int)
            func run() throws -> (String, InvoiceNumberFormat.Scope) {
                let parsed = try InvoiceNumberFormat.parse(template)
                let text = try parsed.format(counter: counter, year: input["year"] as! Int, month: input["month"] as! Int,
                                             abbreviation: input["abbreviation"] as? String, clientNumber: input["clientNumber"] as? String, projectCode: input["projectCode"] as? String)
                return (text, parsed.scope)
            }
            if let error = expected["error"] as? String {
                XCTAssertThrowsError(try run(), id) { e in XCTAssertEqual((e as? InvoiceNumberFormat.Failure)?.vectorName, error, id) }
            } else {
                let (text, scope) = try run()
                XCTAssertEqual(text, expected["formatted"] as? String, id)
                let map: [String: InvoiceNumberFormat.Scope] = ["continuous": .continuous, "perYear": .perYear, "perMonth": .perMonth]
                XCTAssertEqual(scope, map[expected["counterScope"] as! String], id)
            }
        }
        // Zählerschlüssel: je Serie und Zeitraum getrennt, stabil, mit Kleinbuchstaben-UUID
        let sid = UUID()
        XCTAssertEqual(InvoiceNumbering.counterKey(series: sid, scope: .continuous, year: 2026, month: 3).rawValue, "invoice:\(sid.uuidString.lowercased())")
        XCTAssertEqual(InvoiceNumbering.counterKey(series: sid, scope: .perYear, year: 2026, month: 3).rawValue, "invoice:\(sid.uuidString.lowercased())-2026")
        XCTAssertEqual(InvoiceNumbering.counterKey(series: sid, scope: .perMonth, year: 2026, month: 3).rawValue, "invoice:\(sid.uuidString.lowercased())-2026-03")
    }
}
