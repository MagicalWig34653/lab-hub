import XCTVapor
import Fluent
import SQLKit
@testable import HubCore
@testable import HubKit
@testable import HubModuleDMS
@testable import HubModuleInvoice

/// WP-R2: Belege des Rechnungsmoduls (Entwurf, serverseitige Summen, Finalisieren mit Hub-Zähler, Unveränderlichkeit). Nur synthetische Daten.
final class InvoiceDocumentTests: InvoiceTestBase {

    struct Setup {
        let w: World
        let seriesID: String
        let typeID: String
        let contact: String
        var docs: String { "api/v1/tenants/\(w.tenantA)/invoice/documents" }
    }

    /// Absender, Serie `RE-{N:4}`, Belegtyp „Rechnung“ mit Standardserie, ein Kontakt.
    func setup(format: String = "RE-{N:4}") async throws -> Setup {
        let w = try await world()
        let put = try await call(app1, .PUT, base(w.tenantA) + "/settings", json: ["sender_name": "Muster GmbH", "city": "Musterstadt", "currency": "EUR"], token: w.alice.token)
        XCTAssertEqual(put.status, .ok, "\(put.json)")
        let s = try await series(w, format: format)
        XCTAssertEqual(s.status, .created, "\(s.json)")
        let seriesID = s.json["id"] as! String
        let t = try await call(app1, .POST, base(w.tenantA) + "/document-types", json: ["code": "invoice", "name": "Rechnung", "kind": "invoice", "default_series_id": seriesID], token: w.alice.token)
        XCTAssertEqual(t.status, .created, "\(t.json)")
        let c = try await call(app1, .POST, "api/v1/tenants/\(w.tenantA)/contacts", json: ["kind": "organization", "display_name": "Kunde AG"], token: w.alice.token)
        XCTAssertEqual(c.status, .created, "\(c.json)")
        return Setup(w: w, seriesID: seriesID, typeID: t.json["id"] as! String, contact: c.json["id"] as! String)
    }

    /// Entwurf aus dem Vektor `net-mixed-rates` (Summen 261.22 / 30.68 / 291.90).
    func draftBody(_ s: Setup, extra: [String: Any] = [:]) -> [String: Any] {
        var body: [String: Any] = [
            "document_type_id": s.typeID, "contact_id": s.contact, "issue_date": "2026-11-23", "currency": "EUR", "price_mode": "net",
            "lines": [
                ["kind": "item", "description": "Beratung", "quantity": "3", "unit_price": "49.99", "tax_rate": "19"],
                ["kind": "item", "description": "Material", "quantity": "2.5", "unit_price": "12.5", "tax_rate": "7"],
                ["kind": "item", "description": "Pauschale", "quantity": "1", "unit_price": "80", "tax_rate": "0"]]]
        for (k, v) in extra { body[k] = v }
        return body
    }

    func create(_ s: Setup, _ extra: [String: Any] = [:], via: Application? = nil, headers: [String: String] = [:]) async throws -> Resp {
        try await call(via ?? app1, .POST, s.docs, json: draftBody(s, extra: extra), token: s.w.alice.token, headers: headers)
    }

    func finalize(_ s: Setup, _ id: String, via: Application? = nil, token: String? = nil, headers: [String: String] = [:]) async throws -> Resp {
        try await call(via ?? app1, .POST, s.docs + "/\(id)/finalize", json: [String: Any](), token: token ?? s.w.alice.token, headers: headers)
    }

    func num(_ any: Any?) -> Decimal? { (any as? String).flatMap { Decimal(string: $0, locale: Locale(identifier: "en_US_POSIX")) } }

    // MARK: AK-R2-4 Entwurf und Summen

    /// AK-R2-4: Ein Entwurf entsteht ohne Nummer, der Server rechnet die Summen (Vektor `net-mixed-rates`), Steuersummen je Satz, Beträge als Strings.
    func testAKR2_4_DraftComputesTotalsOnServer() async throws {
        let s = try await setup()
        let r = try await create(s)
        XCTAssertEqual(r.status, .created, "\(r.json)")
        XCTAssertEqual(r.json["status"] as? String, "draft")
        XCTAssertTrue(r.json["number"] is NSNull || r.json["number"] == nil)
        XCTAssertEqual(num(r.json["net_total"]), Decimal(string: "261.22"))
        XCTAssertEqual(num(r.json["tax_total"]), Decimal(string: "30.68"))
        XCTAssertEqual(num(r.json["gross_total"]), Decimal(string: "291.90"))
        XCTAssertEqual(r.json["gross_total"] as? String, "291.90")
        let rates = (r.json["tax_totals"] as? [[String: Any]]) ?? []
        XCTAssertEqual(rates.compactMap { num($0["rate"]) }, [0, 7, 19].map { Decimal($0) })
        XCTAssertEqual(num(rates[2]["tax"]), Decimal(string: "28.49"))
        XCTAssertEqual((r.json["lines"] as? [[String: Any]])?.count, 3)
        // Client-Summen werden nicht angenommen
        let forged = try await create(s, ["net_total": "1.00"])
        XCTAssertEqual(forged.status, .unprocessableEntity); XCTAssertEqual(forged.problemCode, "validation_failed")
        // Gleitkomma statt String
        let float = try await create(s, ["lines": [["kind": "item", "description": "x", "quantity": 1.5, "unit_price": "1", "tax_rate": "19"]]])
        XCTAssertEqual(float.status, .unprocessableEntity)
        // Lesen und Liste
        let id = r.json["id"] as! String
        let got = try await call(app2, .GET, s.docs + "/\(id)", token: s.w.alice.token)
        XCTAssertEqual(got.status, .ok); XCTAssertEqual(got.json["gross_total"] as? String, "291.90")
        try await aEq(items(try await call(app1, .GET, s.docs + "?status=draft", token: s.w.alice.token)).count, 1)
        try await aEq(items(try await call(app1, .GET, s.docs + "?status=final", token: s.w.alice.token)).count, 0)
    }

    /// AK-R2-5: Ändern ersetzt Positionen und rechnet neu; Brutto-Modus, Belegrabatt und Zusatzkosten gehen durch denselben Kern.
    func testAKR2_5_UpdateRecalculates() async throws {
        let s = try await setup()
        let id = (try await create(s)).json["id"] as! String
        let p = try await call(app1, .PATCH, s.docs + "/\(id)", json: [
            "price_mode": "gross", "lines": [["kind": "item", "description": "A", "quantity": "1", "unit_price": "119", "tax_rate": "19"],
                                             ["kind": "item", "description": "B", "quantity": "3", "unit_price": "10.70", "tax_rate": "7"]]], token: s.w.alice.token)
        XCTAssertEqual(p.status, .ok, "\(p.json)")
        XCTAssertEqual(num(p.json["net_total"]), 130); XCTAssertEqual(num(p.json["tax_total"]), Decimal(string: "21.1")); XCTAssertEqual(num(p.json["gross_total"]), Decimal(string: "151.1"))
        XCTAssertEqual((p.json["lines"] as? [[String: Any]])?.count, 2)
        try await aEq(try await count("invoice_lines", where: "document_id = '\(id)'"), 2)
        // Kopf allein ändern lässt die Positionen
        let h = try await call(app1, .PATCH, s.docs + "/\(id)", json: ["header_text": "Danke"], token: s.w.alice.token)
        XCTAssertEqual(h.status, .ok); XCTAssertEqual(h.json["header_text"] as? String, "Danke"); XCTAssertEqual((h.json["lines"] as? [[String: Any]])?.count, 2)
        // Belegrabatt 10 % und Versand ohne Rabatt (Vektor net-charges-not-discounted: Summe bleibt im Kern)
        let d = try await call(app1, .PATCH, s.docs + "/\(id)", json: [
            "price_mode": "net", "discount_percent": "10",
            "lines": [["kind": "item", "description": "A", "quantity": "1", "unit_price": "100", "tax_rate": "19"]],
            "charges": [["description": "Versand", "tax_rate": "19", "amount": "10"]]], token: s.w.alice.token)
        XCTAssertEqual(d.status, .ok, "\(d.json)")
        XCTAssertEqual(num(d.json["net_total"]), 100); XCTAssertEqual(num(d.json["discount_total"]), 10)
        XCTAssertEqual((d.json["charges"] as? [[String: Any]])?.count, 1)
        // ungültig: unbekanntes Feld, falscher Status-Versuch, fremder Belegtyp
        let bad = try await call(app1, .PATCH, s.docs + "/\(id)", json: ["status": "final"], token: s.w.alice.token)
        XCTAssertEqual(bad.status, .unprocessableEntity)
        let delete = try await call(app1, .DELETE, s.docs + "/\(id)", token: s.w.alice.token)
        XCTAssertEqual(delete.status, .noContent)
        try await aEq(try await count("invoice_lines", where: "document_id = '\(id)'"), 0)
    }

    // MARK: AK-R2-6 Rechte und Mandanten

    /// AK-R2-6: Rollenmatrix: Lesen owner/accountant/member/tax_advisor, Anlegen und Ändern owner/accountant/member, Finalisieren nur owner/accountant; Verbot = 403 ohne Nebenwirkung.
    func testAKR2_6_PermissionMatrix() async throws {
        let s = try await setup()
        var sessions: [Role: TestSession] = [.owner: s.w.alice]
        for role in Role.allCases where role != .owner { sessions[role] = try await addUser(role.rawValue, handle: "u_" + role.rawValue, tenant: s.w.tenantA, by: s.w.alice) }
        let declared = InvoiceModule().permissions
        func allowed(_ role: Role, _ p: String) -> Bool { declared.contains { $0.name == p && (role == .owner || $0.roles.contains(role)) } }
        for role in Role.allCases {
            XCTAssertEqual(allowed(role, "invoice.document.read"), [.owner, .accountant, .member, .taxAdvisor].contains(role), role.rawValue)
            XCTAssertEqual(allowed(role, "invoice.document.create"), [.owner, .accountant, .member].contains(role), role.rawValue)
            XCTAssertEqual(allowed(role, "invoice.document.update"), [.owner, .accountant, .member].contains(role), role.rawValue)
            XCTAssertEqual(allowed(role, "invoice.document.finalize"), [.owner, .accountant].contains(role), role.rawValue)
        }
        let id = (try await create(s)).json["id"] as! String
        let before = try await count("invoice_documents")
        for role in Role.allCases {
            let t = sessions[role]!.token
            let read = try await call(app2, .GET, s.docs + "/\(id)", token: t)
            XCTAssertEqual(read.status, allowed(role, "invoice.document.read") ? .ok : .forbidden, "read \(role.rawValue)")
            if !allowed(role, "invoice.document.create") {
                let r = try await call(app2, .POST, s.docs, json: draftBody(s), token: t)
                XCTAssertEqual(r.status, .forbidden, "create \(role.rawValue)"); XCTAssertEqual(r.problemCode, "forbidden")
            }
            if !allowed(role, "invoice.document.update") {
                let r = try await call(app1, .PATCH, s.docs + "/\(id)", json: ["note": "x"], token: t)
                XCTAssertEqual(r.status, .forbidden, "update \(role.rawValue)")
                try await aEq((try await call(app1, .DELETE, s.docs + "/\(id)", token: t)).status, .forbidden, "delete \(role.rawValue)")
            }
            if !allowed(role, "invoice.document.finalize") {
                let r = try await finalize(s, id, via: app2, token: t)
                XCTAssertEqual(r.status, .forbidden, "finalize \(role.rawValue)")
            }
        }
        try await aEq(try await count("invoice_documents"), before)
        try await aEq(try await scalar("SELECT status AS v FROM invoice_documents WHERE id = '\(id)'", as: String.self), "draft")
        // Mitglied legt an, finalisiert aber nicht; Buchhaltung finalisiert
        let own = try await call(app1, .POST, s.docs, json: draftBody(s), token: sessions[.member]!.token)
        XCTAssertEqual(own.status, .created)
        try await aEq((try await finalize(s, own.json["id"] as! String, token: sessions[.accountant]!.token)).status, .ok)
    }

    /// AK-R2-7: Mandantentrennung: fremder Mandant 404 auf allen Beleg-Routen, fremde Kontakte/Serien/Typen im eigenen Mandanten 422, Kontakt per SQL über Mandantengrenze scheitert.
    func testAKR2_7_TenantIsolation() async throws {
        let s = try await setup()
        let id = (try await create(s)).json["id"] as! String
        let tenantB = (try await call(app1, .POST, "api/v1/tenants", json: ["name": "Zweiter Mandant"], token: s.w.alice.token)).json["id"] as! String
        let carol = try await addUser("owner", handle: "carol", tenant: tenantB, by: s.w.alice)
        try await setModule(tenantB, true, by: carol)
        let b = "api/v1/tenants/\(tenantB)/invoice/documents"
        for (m, p, body) in [(HTTPMethod.GET, "/\(id)", nil as [String: Any]?), (.PATCH, "/\(id)", ["note": "Hack"]), (.DELETE, "/\(id)", nil), (.POST, "/\(id)/finalize", [:])] {
            let r = try await call(app2, m, b + p, json: body, token: carol.token)
            XCTAssertEqual(r.status, .notFound, "\(m) \(p)")
        }
        try await aEq(items(try await call(app1, .GET, b, token: carol.token)).count, 0)
        for route in app1.moduleRoutes where route.module == "invoice" && route.path.contains("/documents") {
            let path = String(route.path.dropFirst()).replacingOccurrences(of: "{tenant}", with: s.w.tenantA).replacingOccurrences(of: "{id}", with: id)
            let r = try await call(app1, HTTPMethod(rawValue: route.method), path, json: route.method == "GET" ? nil : [String: Any](), token: carol.token)
            XCTAssertEqual(r.status, .notFound, "\(route.method) \(route.path)")
        }
        // Verweise über die Mandantengrenze
        let foreignContact = (try await call(app1, .POST, "api/v1/tenants/\(tenantB)/contacts", json: ["kind": "person", "display_name": "Fremd"], token: carol.token)).json["id"] as! String
        let r = try await create(s, ["contact_id": foreignContact])
        XCTAssertEqual(r.status, .unprocessableEntity); XCTAssertEqual(r.problemCode, "validation_failed")
        let fseries = try await call(app1, .POST, "api/v1/tenants/\(tenantB)/invoice/series", json: ["code": "re", "name": "B", "number_format": "B-{N}"], token: carol.token)
        let r2 = try await create(s, ["series_id": fseries.json["id"] as! String])
        XCTAssertEqual(r2.status, .unprocessableEntity)
        let r3 = try await create(s, ["document_type_id": UUID().uuidString])
        XCTAssertEqual(r3.status, .unprocessableEntity)
        do {
            try await db.raw(SQLQueryString("""
                INSERT INTO invoice_documents (tenant_id, document_type_id, kind, contact_id, issue_date, currency)
                VALUES ('\(s.w.tenantA)', '\(s.typeID)', 'invoice', '\(foreignContact)', '2026-11-23', 'EUR')
                """)).run()
            XCTFail("Kontakt eines fremden Mandanten muss scheitern")
        } catch {}
    }

    // MARK: AK-R2-8 Finalisieren

    /// AK-R2-8: Finalisieren vergibt die Nummer aus dem Hub-Zähler (Format der Serie), friert Absender und Empfänger ein, setzt Hash und Zeitpunkt; 409 beim zweiten Mal.
    func testAKR2_8_FinalizeAssignsNumberAndFreezes() async throws {
        let s = try await setup()
        let id = (try await create(s)).json["id"] as! String
        let f = try await finalize(s, id)
        XCTAssertEqual(f.status, .ok, "\(f.json)")
        XCTAssertEqual(f.json["status"] as? String, "final")
        XCTAssertEqual(f.json["number"] as? String, "RE-0001")
        XCTAssertEqual(f.json["counter_value"] as? Int, 1)
        XCTAssertEqual((f.json["sender"] as? [String: Any])?["sender_name"] as? String, "Muster GmbH")
        XCTAssertEqual((f.json["recipient"] as? [String: Any])?["display_name"] as? String, "Kunde AG")
        XCTAssertEqual((f.json["content_hash"] as? String)?.count, 64)
        XCTAssertNotNil(f.json["finalized_at"] as? String)
        XCTAssertEqual(f.json["tax_regime"] as? String, "standard")
        XCTAssertEqual(f.json["gross_total"] as? String, "291.90")
        // zweites Finalisieren und Ändern: 409
        let again = try await finalize(s, id, via: app2)
        XCTAssertEqual(again.status, .conflict); XCTAssertEqual(again.problemCode, "document_final_immutable")
        let patch = try await call(app2, .PATCH, s.docs + "/\(id)", json: ["note": "x"], token: s.w.alice.token)
        XCTAssertEqual(patch.status, .conflict); XCTAssertEqual(patch.problemCode, "document_final_immutable")
        let del = try await call(app1, .DELETE, s.docs + "/\(id)", token: s.w.alice.token)
        XCTAssertEqual(del.status, .conflict); XCTAssertEqual(del.problemCode, "document_final_immutable")
        // Nächste Nummer folgt lückenlos; Serie ist jetzt in Benutzung
        let id2 = (try await create(s)).json["id"] as! String
        try await aEq((try await finalize(s, id2)).json["number"] as? String, "RE-0002")
        let ser = try await call(app1, .DELETE, base(s.w.tenantA) + "/series/\(s.seriesID)", token: s.w.alice.token)
        XCTAssertEqual(ser.status, .conflict); XCTAssertEqual(ser.problemCode, "series_in_use")
        // Audit
        try await aEq(try await count("audit_log", where: "action = 'invoice.document.finalized'"), 2)
    }

    /// AK-R2-9: Finalisieren mit `Idempotency-Key`: Wiederholung (auch über die andere Instanz) liefert dieselbe Antwort und vergibt keine zweite Nummer.
    func testAKR2_9_FinalizeIsIdempotentWithKey() async throws {
        let s = try await setup()
        let id = (try await create(s)).json["id"] as! String
        let first = try await finalize(s, id, headers: ["Idempotency-Key": "fin-1"])
        XCTAssertEqual(first.status, .ok, "\(first.json)")
        let second = try await finalize(s, id, via: app2, headers: ["Idempotency-Key": "fin-1"])
        XCTAssertEqual(second.status, .ok)
        XCTAssertEqual(second.json["number"] as? String, first.json["number"] as? String)
        XCTAssertEqual(second.json["content_hash"] as? String, first.json["content_hash"] as? String)
        try await aEq(try await scalar("SELECT value AS v FROM counters WHERE tenant_id = '\(s.w.tenantA)' AND key LIKE 'invoice:%'", as: Int64.self), 1)
        // parallel mit gleichem Key: genau eine Nummer
        let id2 = (try await create(s)).json["id"] as! String
        let rs = try await parallel(8) { i in try await self.finalize(s, id2, via: i % 2 == 0 ? self.app1 : self.app2, headers: ["Idempotency-Key": "fin-2"]) }
        XCTAssertEqual(Set(rs.compactMap { $0.json["number"] as? String }), ["RE-0002"], rs.map { "\($0.status.code) \($0.json)" }.joined(separator: "\n"))
        try await aEq(try await scalar("SELECT value AS v FROM counters WHERE tenant_id = '\(s.w.tenantA)' AND key LIKE 'invoice:%'", as: Int64.self), 2)
    }

    /// AK-R2-10: Unvollständige Belege lassen sich nicht finalisieren (Kontakt, Serie, Positionen, Absender); der Fehlversuch verbraucht keine Nummer.
    func testAKR2_10_IncompleteDocumentsDoNotConsumeNumbers() async throws {
        let s = try await setup()
        let noContact = (try await create(s, ["contact_id": NSNull()])).json["id"] as! String
        let r = try await finalize(s, noContact)
        XCTAssertEqual(r.status, .unprocessableEntity); XCTAssertEqual(r.problemCode, "validation_failed")
        let noLines = (try await create(s, ["lines": [Any]()])).json["id"] as! String
        try await aEq((try await finalize(s, noLines)).status, .unprocessableEntity)
        // Typ ohne Standardserie und Beleg ohne Serie
        let bare = try await call(app1, .POST, base(s.w.tenantA) + "/document-types", json: ["code": "offer", "name": "Angebot", "kind": "quote"], token: s.w.alice.token)
        let noSeries = (try await create(s, ["document_type_id": bare.json["id"] as! String])).json["id"] as! String
        try await aEq((try await finalize(s, noSeries)).status, .unprocessableEntity)
        // Format braucht ein Kürzel, das nicht gesetzt ist: 422, keine Nummer verbraucht
        let abbr = try await series(s.w, code: "ab", format: "{ABBR}-{N:3}")
        let withAbbr = (try await create(s, ["series_id": abbr.json["id"] as! String])).json["id"] as! String
        try await aEq((try await finalize(s, withAbbr)).status, .unprocessableEntity)
        try await aEq(try await count("counters", where: "tenant_id = '\(s.w.tenantA)' AND key LIKE 'invoice:%'"), 0, "Fehlversuche verbrauchen keine Nummer")
        try await aEq(try await count("invoice_documents", where: "status = 'draft'"), 4)
        // danach klappt es und beginnt bei 1
        let ok = (try await create(s)).json["id"] as! String
        try await aEq((try await finalize(s, ok)).json["number"] as? String, "RE-0001")
    }

    /// AK-R2-11: Nummer im Konflikt (bereits vergebene Nummer der Serie) = 409 `number_conflict`, der Zähler rollt mit zurück (keine Lücke).
    func testAKR2_11_NumberConflictRollsBackCounter() async throws {
        let s = try await setup()
        let a = (try await create(s)).json["id"] as! String
        try await aEq((try await finalize(s, a)).json["number"] as? String, "RE-0001")
        // Fremdbelegte Nummer RE-0002 per SQL erzwingen (Altbestand), Zähler steht bei 1
        let other = (try await create(s)).json["id"] as! String
        try await db.raw(SQLQueryString("""
            INSERT INTO invoice_documents (tenant_id, document_type_id, kind, series_id, contact_id, status, number, counter_value, issue_date, currency, content_hash, sender, recipient, finalized_at)
            VALUES ('\(s.w.tenantA)', '\(s.typeID)', 'invoice', '\(s.seriesID)', '\(s.contact)', 'final', 'RE-0002', 2, '2026-11-01', 'EUR', '\(String(repeating: "a", count: 64))', '{}', '{}', now())
            """)).run()
        let r = try await finalize(s, other)
        XCTAssertEqual(r.status, .conflict, "\(r.json)"); XCTAssertEqual(r.problemCode, "number_conflict")
        try await aEq(try await scalar("SELECT value AS v FROM counters WHERE tenant_id = '\(s.w.tenantA)' AND key LIKE 'invoice:%'", as: Int64.self), 1)
        try await aEq(try await scalar("SELECT status AS v FROM invoice_documents WHERE id = '\(other)'", as: String.self), "draft")
    }

    /// AK-R2-12: Nummernkreise je Jahr: Zähler läuft je Belegjahr (Ausstellungsdatum), neues Jahr beginnt wieder bei 1.
    func testAKR2_12_PerYearSeriesUsesIssueYear() async throws {
        let s = try await setup(format: "RE-{YYYY}-{N:3}")
        let a = (try await create(s, ["issue_date": "2026-12-30"])).json["id"] as! String
        let b = (try await create(s, ["issue_date": "2027-01-02"])).json["id"] as! String
        let c = (try await create(s, ["issue_date": "2026-12-31"])).json["id"] as! String
        try await aEq((try await finalize(s, a)).json["number"] as? String, "RE-2026-001")
        try await aEq((try await finalize(s, b)).json["number"] as? String, "RE-2027-001")
        try await aEq((try await finalize(s, c)).json["number"] as? String, "RE-2026-002")
    }

    // MARK: AK-R2-13 Unveränderlichkeit in der Datenbank

    /// AK-R2-13: Nach dem Finalisieren scheitern UPDATE und DELETE an Beleg, Positionen, Zusatzkosten und Steuersummen auch direkt per SQL; Entwürfe bleiben änderbar.
    func testAKR2_13_FinalDocumentIsImmutableInSQL() async throws {
        let s = try await setup()
        let id = (try await create(s, ["charges": [["description": "Versand", "tax_rate": "19", "amount": "5"]]])).json["id"] as! String
        // Entwurf per SQL änderbar
        try await db.raw(SQLQueryString("UPDATE invoice_documents SET note = 'Entwurf' WHERE id = '\(id)'")).run()
        let finalized = try await finalize(s, id)
        XCTAssertEqual(finalized.status, .ok, "\(finalized.json)")
        let statements = [
            "UPDATE invoice_documents SET note = 'Hack' WHERE id = '\(id)'",
            "UPDATE invoice_documents SET status = 'draft', number = NULL, counter_value = NULL, finalized_at = NULL WHERE id = '\(id)'",
            "UPDATE invoice_documents SET gross_total = 1 WHERE id = '\(id)'",
            "DELETE FROM invoice_documents WHERE id = '\(id)'",
            "UPDATE invoice_lines SET description = 'Hack' WHERE document_id = '\(id)'",
            "DELETE FROM invoice_lines WHERE document_id = '\(id)'",
            "INSERT INTO invoice_lines (tenant_id, document_id, position, kind, description, quantity, unit_price, tax_rate) VALUES ('\(s.w.tenantA)', '\(id)', 99, 'item', 'x', 1, 1, 19)",
            "UPDATE invoice_charges SET amount = 1 WHERE document_id = '\(id)'",
            "DELETE FROM invoice_charges WHERE document_id = '\(id)'",
            "UPDATE invoice_tax_totals SET tax = 0 WHERE document_id = '\(id)'",
            "DELETE FROM invoice_tax_totals WHERE document_id = '\(id)'",
            "INSERT INTO invoice_tax_totals (tenant_id, document_id, rate, net, tax, gross) VALUES ('\(s.w.tenantA)', '\(id)', 5, 1, 1, 2)"]
        for sqlText in statements {
            do { try await db.raw(SQLQueryString(sqlText)).run(); XCTFail("muss scheitern: \(sqlText)") } catch {}
        }
        let doc = try await call(app1, .GET, s.docs + "/\(id)", token: s.w.alice.token)
        XCTAssertEqual(doc.json["gross_total"] as? String, finalized.json["gross_total"] as? String)
        XCTAssertEqual(doc.json["content_hash"] as? String, finalized.json["content_hash"] as? String)
        try await aEq(try await count("invoice_lines", where: "document_id = '\(id)'"), 3)
        try await aEq(try await count("invoice_charges", where: "document_id = '\(id)'"), 1)
        // Pflichtfelder: final ohne Nummer/Hash nicht anlegbar, Entwurf mit Nummer nicht anlegbar
        let head = "INSERT INTO invoice_documents (tenant_id, document_type_id, kind, issue_date, currency, "
        let common = "'\(s.w.tenantA)', '\(s.typeID)', 'invoice', '2026-11-23', 'EUR'"
        for bad in ["\(head)status, finalized_at) VALUES (\(common), 'final', now())", "\(head)status, number, counter_value) VALUES (\(common), 'draft', 'X-1', 1)"] {
            do { try await db.raw(SQLQueryString(bad)).run(); XCTFail("CHECK muss greifen: \(bad)") } catch {}
        }
    }

    // MARK: AK-R4 parallele Vergabe

    /// AK-R4: 50 parallele Finalisierungen über zwei Instanzen vergeben lückenlos eindeutige Nummern 1…50; jede Nummer genau einmal, Zähler = 50.
    func testAKR4_FiftyParallelFinalizationsAreGaplessAndUnique() async throws {
        let s = try await setup()
        var ids: [String] = []
        for _ in 0..<50 { ids.append((try await create(s)).json["id"] as! String) }
        let batch = ids
        let rs = try await parallel(50) { i in try await self.finalize(s, batch[i], via: i % 2 == 0 ? self.app1 : self.app2) }
        XCTAssertEqual(rs.filter { $0.status == .ok }.count, 50, rs.filter { $0.status != .ok }.map { "\($0.status.code) \($0.json)" }.joined(separator: "\n"))
        let numbers = Set(rs.compactMap { $0.json["number"] as? String })
        XCTAssertEqual(numbers, Set((1...50).map { String(format: "RE-%04d", $0) }))
        try await aEq(try await scalar("SELECT value AS v FROM counters WHERE tenant_id = '\(s.w.tenantA)' AND key LIKE 'invoice:%'", as: Int64.self), 50)
        try await aEq(try await count("invoice_documents", where: "status = 'final'"), 50)
        try await aEq(try await scalar("SELECT count(DISTINCT number)::bigint AS v FROM invoice_documents WHERE status = 'final'", as: Int64.self), 50)
        // zwei Belege parallel mit gleichem Beleg (ohne Key): genau einer gewinnt, der andere 409, keine zweite Nummer
        let extra = (try await create(s)).json["id"] as! String
        let race = try await parallel(6) { i in try await self.finalize(s, extra, via: i % 2 == 0 ? self.app1 : self.app2) }
        XCTAssertEqual(race.filter { $0.status == .ok }.count, 1, race.map { "\($0.status.code)" }.joined(separator: ","))
        XCTAssertEqual(Set(race.filter { $0.status != .ok }.map { $0.problemCode }), ["document_final_immutable"])
        try await aEq(try await scalar("SELECT value AS v FROM counters WHERE tenant_id = '\(s.w.tenantA)' AND key LIKE 'invoice:%'", as: Int64.self), 51)
    }

    // MARK: AK-R2-14 Modul aus, Migration

    /// AK-R2-14: Migration `invoice_028_documents` ist rückbaubar und wieder anwendbar, die Tabellen existieren auch bei deaktiviertem Modul.
    func testAKR2_14_MigrationRevertAndReapply() async throws {
        _ = try await world(enable: false)
        let tables = ["invoice_documents", "invoice_lines", "invoice_charges", "invoice_tax_totals"]
        for tbl in tables { try await aEq(try await count("information_schema.tables", where: "table_name = '\(tbl)'"), 1, tbl) }
        try await aEq(try await count("_fluent_migrations", where: "name = 'invoice_028_documents'"), 1)
        let m = CreateInvoiceDocuments(), database = app1.db(.psql)
        try await CreateInvoiceLayouts().revert(on: database)   // WP-R6d baut darauf auf
        try await CreateInvoiceRender().revert(on: database)    // WP-R6c baut darauf auf: Rückbau in umgekehrter Reihenfolge
        try await CreateInvoicePayments().revert(on: database)  // WP-R3 baut darauf auf
        try await m.revert(on: database)
        for tbl in tables { try await aEq(try await count("information_schema.tables", where: "table_name = '\(tbl)'"), 0, tbl) }
        try await aEq(try await count("pg_proc", where: "proname IN ('invoice_documents_guard', 'invoice_children_guard')"), 0)
        try await m.prepare(on: database)
        try await CreateInvoicePayments().prepare(on: database)
        try await CreateInvoiceRender().prepare(on: database)
        try await CreateInvoiceLayouts().prepare(on: database)
        for tbl in tables { try await aEq(try await count("information_schema.tables", where: "table_name = '\(tbl)'"), 1, tbl) }
    }
}
