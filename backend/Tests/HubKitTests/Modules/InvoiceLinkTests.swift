import XCTVapor
import Fluent
import SQLKit
@testable import HubKit

/// WP-R3: Gutschrift, Umwandlung, Verknüpfungen Beleg↔Beleg, Rechte und Mandanten, durchgehender Weg über echtes HTTP. Nur synthetische Daten.
final class InvoiceLinkTests: InvoicePaymentTestBase, @unchecked Sendable {

    // MARK: AK-R3-7 Gutschrift

    /// AK-R3-7: Gutschrift aus finaler Rechnung als Entwurf mit negierten Positionen, verknüpft; wirkt erst nach dem Finalisieren; nie mehr als die Rechnung.
    func testAKR3_7_CreditNote() async throws {
        let s = try await setup()
        let body: [String: Any] = [
            "price_mode": "gross", "discount_amount": "5", "skonto_percent": "2", "skonto_days": 10,
            "lines": [["kind": "item", "description": "A", "quantity": "2", "unit_price": "59.5", "tax_rate": "19", "discount_kind": "amount", "discount_value": "9"],
                      ["kind": "text", "description": "Hinweis"],
                      ["kind": "item", "description": "B", "quantity": "1", "unit_price": "10.70", "tax_rate": "7", "discount_kind": "percent", "discount_value": "10"]],
            "charges": [["description": "Versand", "tax_rate": "19", "amount": "5.95"]]]
        let inv = try await invoice(s, extra: body)
        let original = try await call(app1, .GET, s.docs + "/\(inv)", token: s.token)
        let gross = try XCTUnwrap(num(original.json["gross_total"]))
        let r = try await creditNote(s, inv)
        XCTAssertEqual(r.status, .created, "\(r.json)")
        let cid = r.json["id"] as? String ?? ""
        XCTAssertEqual(r.json["status"] as? String, "draft"); XCTAssertEqual(r.json["kind"] as? String, "credit_note")
        XCTAssertEqual(r.json["contact_id"] as? String, original.json["contact_id"] as? String)
        XCTAssertTrue(r.json["skonto_percent"] == nil || r.json["skonto_percent"] is NSNull)
        for key in ["net_total", "tax_total", "gross_total", "discount_total"] { XCTAssertEqual(num(r.json[key]), num(original.json[key]).map { -$0 }, key) }
        XCTAssertEqual((r.json["lines"] as? [[String: Any]])?.count, 3)
        // Entwurf wirkt nicht
        try await aEq(num((try await balance(s, inv))["total_balance"]), gross)
        let l = try await links(s, inv)
        XCTAssertEqual(l.first?["kind"] as? String, "credit_note"); XCTAssertEqual(l.first?["direction"] as? String, "outgoing")
        XCTAssertEqual((l.first?["document"] as? [String: Any])?["id"] as? String, cid)
        // Belegart der Gutschrift ist gesperrt
        assertField(try await call(app1, .PATCH, s.docs + "/\(cid)", json: ["document_type_id": s.types["invoice"]!], token: s.token), "document_type_id", "kind_locked")
        // positive Summe, anderer Kontakt, andere Währung: nicht finalisierbar
        let negated = r.json["lines"] as? [[String: Any]] ?? []
        let positive = try await call(app1, .PATCH, s.docs + "/\(cid)", json: ["lines": [["kind": "item", "description": "x", "quantity": "1", "unit_price": "1", "tax_rate": "0"]], "charges": [Any](), "discount_amount": NSNull()], token: s.token)
        XCTAssertEqual(positive.status, .ok, "\(positive.json)")
        assertField(try await finalize(s, cid), "lines", "credit_must_be_negative")
        _ = try await call(app1, .PATCH, s.docs + "/\(cid)", json: ["lines": [["kind": "item", "description": "x", "quantity": "-1", "unit_price": "10", "tax_rate": "0"]]], token: s.token)
        _ = try await call(app1, .PATCH, s.docs + "/\(cid)", json: ["currency": "USD"], token: s.token)
        assertField(try await finalize(s, cid), "currency", "differs_from_invoice")
        let stranger = (try await call(app1, .POST, "api/v1/tenants/\(s.w.tenantA)/contacts", json: ["kind": "person", "display_name": "Anders"], token: s.token)).json["id"] as? String ?? ""
        _ = try await call(app1, .PATCH, s.docs + "/\(cid)", json: ["currency": "EUR", "contact_id": stranger], token: s.token)
        assertField(try await finalize(s, cid), "contact_id", "differs_from_invoice")
        // mehr als die Rechnung
        _ = try await call(app1, .PATCH, s.docs + "/\(cid)", json: ["contact_id": s.contact, "lines": [["kind": "item", "description": "x", "quantity": "-1", "unit_price": "1000", "tax_rate": "0"]]], token: s.token)
        assertField(try await finalize(s, cid), "lines", "credit_exceeds_invoice")
        try await aEq(try await count("counters", where: "tenant_id = '\(s.w.tenantA)' AND key LIKE 'invoice:%'"), 1, "Fehlversuche verbrauchen keine Nummer")
        // Original-Positionen zurück: volle Gutschrift
        let restore = negated.map { line in line.filter { !($0.value is NSNull) && !["id", "position"].contains($0.key) } }
        let back = try await call(app1, .PATCH, s.docs + "/\(cid)", json: ["lines": restore, "charges": [["description": "Versand", "tax_rate": "19", "amount": "-5.95"]], "discount_amount": "-5"], token: s.token)
        XCTAssertEqual(num(back.json["gross_total"]), -gross, "\(back.json)")
        let f = try await finalize(s, cid)
        XCTAssertEqual(f.status, .ok, "\(f.json)"); XCTAssertEqual(f.json["number"] as? String, "GS-0001")
        let b = try await balance(s, inv)
        XCTAssertEqual(num(b["open_balance"]), gross); XCTAssertEqual(num(b["credited"]), gross); XCTAssertEqual(num(b["total_balance"]), 0)
        XCTAssertEqual(b["payment_status"] as? String, "settled")
        XCTAssertEqual((b["credit_notes"] as? [[String: Any]])?.first?["number"] as? String, "GS-0001")
        // nach voller Gutschrift ist nichts mehr offen
        let pid = try await payment(s, "5")
        assertField(try await allocate(s, pid, inv, "5"), "amount", "exceeds_open_amount")
        assertField(try await allocate(s, pid, cid, "5"), "document_id", "not_an_invoice")
        // Original unverändert (Hash)
        try await aEq((try await call(app2, .GET, s.docs + "/\(inv)", token: s.token)).json["content_hash"] as? String, original.json["content_hash"] as? String)
        // nur aus finalen Rechnungen, nur mit Gutschrift-Belegtyp
        assertConflict(try await creditNote(s, try await draft(s)), "document_not_final")
        let q = try await draft(s, kind: "quote"); try await finalize(s, q)
        assertField(try await creditNote(s, q), "id", "not_an_invoice")
        assertField(try await call(app1, .POST, s.docs + "/\(inv)/credit-note", json: ["document_type_id": s.types["invoice"]!], token: s.token), "document_type_id", "not_a_credit_note_type")
        assertField(try await call(app1, .POST, s.docs + "/\(inv)/credit-note", json: [String: Any](), token: s.token), "document_type_id", "required")
        // Idempotency-Key: eine Gutschrift
        let before = try await count("invoice_documents")
        let k1 = try await creditNote(s, inv, headers: ["Idempotency-Key": "cn-1"]), k2 = try await creditNote(s, inv, via: app2, headers: ["Idempotency-Key": "cn-1"])
        XCTAssertEqual(k1.status, .created); XCTAssertEqual(k2.json["id"] as? String, k1.json["id"] as? String)
        try await aEq(try await count("invoice_documents"), before + 1)
    }

    // MARK: AK-R3-8 Umwandlung und Verknüpfungen

    /// AK-R3-8: Umwandlung kopiert den finalen Beleg in einen Entwurf der Zielart und verknüpft beide; nur erlaubte Wege; Referenzen von Hand,
    /// Systemverknüpfungen nicht entfernbar.
    func testAKR3_8_ConvertAndLinks() async throws {
        let s = try await setup()
        let quote = try await draft(s, "250", kind: "quote", extra: ["header_text": "Ihr Angebot", "delivery_date": "2026-12-01"])
        assertConflict(try await convert(s, quote, to: "invoice"), "document_not_final")
        try await finalize(s, quote)
        let source = try await call(app1, .GET, s.docs + "/\(quote)", token: s.token)
        let r = try await convert(s, quote, to: "order_confirmation")
        XCTAssertEqual(r.status, .created, "\(r.json)")
        let ab = r.json["id"] as? String ?? ""
        XCTAssertEqual(r.json["status"] as? String, "draft"); XCTAssertEqual(r.json["kind"] as? String, "order_confirmation")
        XCTAssertEqual(r.json["gross_total"] as? String, "250.00"); XCTAssertEqual(r.json["header_text"] as? String, "Ihr Angebot")
        XCTAssertEqual(r.json["delivery_date"] as? String, "2026-12-01"); XCTAssertEqual(r.json["issue_date"] as? String, "2026-11-24")
        XCTAssertTrue(r.json["number"] == nil || r.json["number"] is NSNull)
        XCTAssertEqual((r.json["lines"] as? [[String: Any]])?.first?["description"] as? String, "Leistung")
        try await finalize(s, ab)
        let inv = (try await convert(s, ab, to: "invoice")).json["id"] as? String ?? ""
        // Verknüpfungen beidseitig
        let middle = try await links(s, ab)
        XCTAssertEqual(Set(middle.map { "\($0["kind"] ?? "") \($0["direction"] ?? "") \(($0["document"] as? [String: Any])?["id"] ?? "")" }),
                       ["conversion incoming \(quote)", "conversion outgoing \(inv)"])
        // Quelle unverändert
        try await aEq((try await call(app2, .GET, s.docs + "/\(quote)", token: s.token)).json["rev"] as? Int, source.json["rev"] as? Int)
        // verbotene Wege
        try await finalize(s, inv)
        assertField(try await convert(s, inv, to: "quote"), "document_type_id", "conversion_not_allowed")
        assertField(try await convert(s, quote, to: "credit_note"), "document_type_id", "conversion_not_allowed")
        assertField(try await convert(s, quote, to: "quote"), "document_type_id", "conversion_not_allowed")
        // Idempotency-Key
        let before = try await count("invoice_documents")
        let k1 = try await convert(s, quote, to: "invoice", headers: ["Idempotency-Key": "conv-1"])
        let k2 = try await convert(s, quote, to: "invoice", via: app2, headers: ["Idempotency-Key": "conv-1"])
        XCTAssertEqual(k1.status, .created); XCTAssertEqual(k2.json["id"] as? String, k1.json["id"] as? String)
        try await aEq(try await count("invoice_documents"), before + 1)
        // Zielart des Umwandlungsentwurfs ist gesperrt, Löschen des Entwurfs entfernt die Verknüpfung
        let copy = k1.json["id"] as? String ?? ""
        assertField(try await call(app1, .PATCH, s.docs + "/\(copy)", json: ["document_type_id": s.types["quote"]!], token: s.token), "document_type_id", "kind_locked")
        try await aEq((try await links(s, quote)).count, 2)
        try await aEq((try await call(app1, .DELETE, s.docs + "/\(copy)", token: s.token)).status, .noContent)
        try await aEq((try await links(s, quote)).count, 1)
        // Referenz von Hand
        let path = s.docs + "/\(quote)/links"
        let ref = try await call(app1, .POST, path, json: ["target_id": inv], token: s.token)
        XCTAssertEqual(ref.status, .created, "\(ref.json)"); XCTAssertEqual(ref.json["kind"] as? String, "reference")
        assertConflict(try await call(app2, .POST, path, json: ["target_id": inv], token: s.token), "conflict")
        assertConflict(try await call(app2, .POST, s.docs + "/\(inv)/links", json: ["target_id": quote], token: s.token), "conflict")
        assertField(try await call(app1, .POST, path, json: ["target_id": quote], token: s.token), "target_id", "invalid")
        assertField(try await call(app1, .POST, path, json: ["target_id": UUID().uuidString], token: s.token), "target_id", "not_found")
        assertField(try await call(app1, .POST, path, json: ["target_id": inv, "kind": "credit_note"], token: s.token), "kind", "unknown_field")
        let all = try await links(s, quote)
        let system = all.first { $0["kind"] as? String == "conversion" }?["id"] as? String ?? ""
        assertConflict(try await call(app1, .DELETE, path + "/\(system)", token: s.token), "document_link_locked")
        let rid = ref.json["id"] as? String ?? ""
        try await aEq((try await call(app1, .DELETE, s.docs + "/\(ab)/links/\(rid)", token: s.token)).status, .notFound, "Verknüpfung gehört nicht zu diesem Beleg")
        try await aEq((try await call(app2, .DELETE, path + "/\(rid)", token: s.token)).status, .noContent)
        try await aEq((try await links(s, quote)).count, 1)
        // SQL: Systemverknüpfung zwischen finalen Belegen ist weder änder- noch löschbar
        await expectSQLFailure("DELETE FROM invoice_document_links WHERE kind = 'conversion' AND to_document_id = '\(inv)'")
        await expectSQLFailure("UPDATE invoice_document_links SET kind = 'reference' WHERE to_document_id = '\(inv)'")
        try await aEq(try await count("audit_log", where: "action IN ('invoice.document.converted', 'invoice.link.created', 'invoice.link.deleted')"), 5)
    }

    // MARK: AK-R3-9 Rechte und Mandanten

    /// AK-R3-9: Zahlungen lesen owner/accountant/member/tax_advisor, schreiben und zuordnen nur owner/accountant; Umwandeln/Gutschrift wie Anlegen, Verknüpfen wie Ändern.
    /// Fremder Mandant: 404 auf allen Routen, fremde IDs im eigenen Mandanten 422/404.
    func testAKR3_9_PermissionsAndTenantIsolation() async throws {
        let s = try await setup()
        let declared = InvoiceModule().permissions
        func allowed(_ role: Role, _ p: String) -> Bool { declared.contains { $0.name == p && (role == .owner || $0.roles.contains(role)) } }
        for role in Role.allCases {
            XCTAssertEqual(allowed(role, "invoice.payment.read"), [.owner, .accountant, .member, .taxAdvisor].contains(role), role.rawValue)
            XCTAssertEqual(allowed(role, "invoice.payment.write"), [.owner, .accountant].contains(role), role.rawValue)
        }
        let inv = try await invoice(s, "100"), pid = try await payment(s, "100")
        for role in Role.allCases where role != .owner {
            let u = try await addUser(role.rawValue, handle: "p_" + role.rawValue, tenant: s.w.tenantA, by: s.w.alice)
            func expect(_ method: HTTPMethod, _ path: String, _ permission: String, json: [String: Any]? = nil) async throws {
                let r = try await call(app2, method, path, json: json, token: u.token)
                if allowed(role, permission) { XCTAssertNotEqual(r.status, .forbidden, "\(role.rawValue) \(method) \(path)") }
                else { XCTAssertEqual(r.status, .forbidden, "\(role.rawValue) \(method) \(path)") }
            }
            try await expect(.GET, s.payments, "invoice.payment.read")
            try await expect(.GET, s.payments + "/\(pid)", "invoice.payment.read")
            try await expect(.GET, s.payments + "/\(pid)/suggestions", "invoice.payment.read")
            try await expect(.GET, s.docs + "/\(inv)/balance", "invoice.payment.read")
            try await expect(.GET, s.docs + "/\(inv)/links", "invoice.document.read")
            if !allowed(role, "invoice.payment.write") {
                try await expect(.POST, s.payments, "invoice.payment.write", json: ["amount": "1", "paid_on": "2026-11-25"])
                try await expect(.POST, s.payments + "/\(pid)/allocations", "invoice.payment.write", json: ["document_id": inv, "amount": "1", "confirmed": true])
                try await expect(.DELETE, s.payments + "/\(pid)/allocations/\(UUID())", "invoice.payment.write")
                try await expect(.POST, s.payments + "/\(pid)/void", "invoice.payment.write", json: ["reason": "x"])
            }
            if !allowed(role, "invoice.document.create") {
                try await expect(.POST, s.docs + "/\(inv)/credit-note", "invoice.document.create", json: ["document_type_id": s.types["credit_note"]!])
                try await expect(.POST, s.docs + "/\(inv)/convert", "invoice.document.create", json: ["document_type_id": s.types["delivery_note"]!])
            }
            if !allowed(role, "invoice.document.update") {
                try await expect(.POST, s.docs + "/\(inv)/links", "invoice.document.update", json: ["target_id": inv])
                try await expect(.DELETE, s.docs + "/\(inv)/links/\(UUID())", "invoice.document.update")
            }
        }
        try await aEq(try await count("invoice_payments"), 1); try await aEq(try await activeAllocations(), 0)
        try await aEq(try await count("invoice_document_links"), 0)
        // fremder Mandant
        let tenantB = (try await call(app1, .POST, "api/v1/tenants", json: ["name": "Zweiter Mandant"], token: s.token)).json["id"] as? String ?? ""
        let carol = try await addUser("owner", handle: "carol", tenant: tenantB, by: s.w.alice)
        try await setModule(tenantB, true, by: carol)
        let routes = app1.moduleRoutes.filter { $0.module == "invoice" && ($0.path.contains("/payments") || $0.path.contains("/documents/{id}/")) }
        XCTAssertGreaterThanOrEqual(routes.count, 13)
        for route in routes {
            for tenant in [s.w.tenantA, tenantB] {
                // Mandant A: Carol ist kein Mitglied; Mandant B: Carols Mandant, IDs aus A.
                if tenant == tenantB, !route.path.contains("{id}") { continue }
                let id = route.path.contains("/payments") ? pid : inv
                let path = String(route.path.dropFirst()).replacingOccurrences(of: "{tenant}", with: tenant).replacingOccurrences(of: "{id}", with: id)
                    .replacingOccurrences(of: "{allocation}", with: UUID().uuidString).replacingOccurrences(of: "{link}", with: UUID().uuidString)
                let body: [String: Any]? = route.method == "GET" || route.method == "DELETE" ? nil
                    : ["document_type_id": s.types["credit_note"]!, "target_id": inv, "document_id": inv, "amount": "1", "confirmed": true, "reason": "x", "paid_on": "2026-11-25"]
                let r = try await call(app1, HTTPMethod(rawValue: route.method), path, json: body, token: carol.token)
                if tenant == s.w.tenantA { XCTAssertEqual(r.status, .notFound, "\(route.method) \(route.path)") }
                else { XCTAssertTrue([.notFound, .unprocessableEntity].contains(r.status), "\(route.method) \(route.path): \(r.status.code) \(r.json)") }
            }
        }
        try await aEq(items(try await call(app1, .GET, "api/v1/tenants/\(tenantB)/invoice/payments", token: carol.token)).count, 0)
        // fremde IDs im eigenen Mandanten
        let foreignPayment = (try await call(app1, .POST, "api/v1/tenants/\(tenantB)/invoice/payments", json: ["amount": "100", "paid_on": "2026-11-25"], token: carol.token)).json["id"] as? String ?? ""
        assertField(try await call(app1, .POST, "api/v1/tenants/\(tenantB)/invoice/payments/\(foreignPayment)/allocations", json: ["document_id": inv, "amount": "1", "confirmed": true], token: carol.token), "document_id", "not_found")
        try await aEq((try await allocate(s, foreignPayment, inv, "1")).status, .notFound)
        let foreignContact = (try await call(app1, .POST, "api/v1/tenants/\(tenantB)/contacts", json: ["kind": "person", "display_name": "Fremd"], token: carol.token)).json["id"] as? String ?? ""
        assertField(try await call(app1, .POST, s.payments, json: ["amount": "1", "paid_on": "2026-11-25", "contact_id": foreignContact], token: s.token), "contact_id", "not_found")
        await expectSQLFailure("INSERT INTO invoice_payment_allocations (tenant_id, payment_id, document_id, amount, confirmed_by) VALUES ('\(tenantB)', '\(foreignPayment)', '\(inv)', 1, '\(carol.userID)')")
        await expectSQLFailure("INSERT INTO invoice_document_links (tenant_id, from_document_id, to_document_id, kind) VALUES ('\(tenantB)', '\(inv)', '\(inv)', 'reference')")
        try await aEq(try await activeAllocations(), 0)
    }

    // MARK: AK-R3-11 Durchgehender Weg über echtes HTTP

    /// Anfrage über einen echten TCP-Server (kein In-Memory-Aufruf).
    private func live(_ app: Application, _ method: HTTPMethod, _ path: String, _ json: [String: Any]? = nil, token: String) async throws -> Resp {
        var headers = HTTPHeaders()
        headers.bearerAuthorization = BearerAuthorization(token: token)
        var body: ByteBuffer?
        if let json { body = ByteBuffer(data: try JSONSerialization.data(withJSONObject: json)); headers.contentType = .json }
        var out: Resp?
        try await app.testable(method: .running(port: 0)).test(method, path, headers: headers, body: body) { res async throws in
            out = Resp(status: res.status, json: (try? JSONSerialization.jsonObject(with: Data(buffer: res.body))) as? [String: Any] ?? [:], headers: res.headers)
        }
        return out!
    }

    /// AK-R3-11: Angebot → Rechnung (Umwandlung) → finalisieren → Zahlung → Vorschlag → bestätigte Zuordnung mit Skonto → Teilgutschrift → Saldo,
    /// abwechselnd über zwei Instanzen mit echtem HTTP gegen Postgres.
    func testAKR3_11_EndToEndOverHTTP() async throws {
        let s = try await setup()
        let t = s.token
        let q = try await live(app1, .POST, s.docs, ["document_type_id": s.types["quote"]!, "contact_id": s.contact, "issue_date": "2026-11-20", "skonto_percent": "3", "skonto_days": 14,
            "lines": [["kind": "item", "description": "Einrichtung", "quantity": "1", "unit_price": "1000", "tax_rate": "19"]]], token: t)
        XCTAssertEqual(q.status, .created, "\(q.json)")
        let quote = q.json["id"] as? String ?? ""
        try await aEq((try await live(app2, .POST, s.docs + "/\(quote)/finalize", [:], token: t)).status, .ok)
        let conv = try await live(app1, .POST, s.docs + "/\(quote)/convert", ["document_type_id": s.types["invoice"]!, "issue_date": "2026-11-23"], token: t)
        XCTAssertEqual(conv.status, .created, "\(conv.json)"); XCTAssertEqual(conv.json["skonto_days"] as? Int, 14)
        let inv = conv.json["id"] as? String ?? ""
        let fin = try await live(app2, .POST, s.docs + "/\(inv)/finalize", [:], token: t)
        XCTAssertEqual(fin.json["number"] as? String, "RE-0001", "\(fin.json)"); XCTAssertEqual(fin.json["gross_total"] as? String, "1190.00")
        let pay = try await live(app1, .POST, s.payments, ["amount": "1154.30", "paid_on": "2026-11-30", "reference": "RE-0001", "method": "bank_transfer"], token: t)
        let pid = pay.json["id"] as? String ?? ""
        let sug = try await live(app2, .GET, s.payments + "/\(pid)/suggestions", token: t)
        let proposal = try XCTUnwrap(items(sug).first)
        XCTAssertEqual(proposal["document_id"] as? String, inv); XCTAssertEqual(num(proposal["skonto_amount"]), dec("35.70"))
        try await aEq(num((try await live(app2, .GET, s.docs + "/\(inv)/balance", token: t)).json["open_balance"]), 1190)
        let a = try await live(app1, .POST, s.payments + "/\(pid)/allocations",
                               ["document_id": inv, "amount": proposal["amount"] ?? "", "skonto_amount": proposal["skonto_amount"] ?? "", "confirmed": true], token: t)
        XCTAssertEqual(a.status, .created, "\(a.json)")
        let cn = try await live(app2, .POST, s.docs + "/\(inv)/credit-note", ["document_type_id": s.types["credit_note"]!], token: t)
        let cid = cn.json["id"] as? String ?? ""
        _ = try await live(app1, .PATCH, s.docs + "/\(cid)", ["lines": [["kind": "item", "description": "Nachlass", "quantity": "-1", "unit_price": "100", "tax_rate": "19"]]], token: t)
        let cfin = try await live(app2, .POST, s.docs + "/\(cid)/finalize", [:], token: t)
        XCTAssertEqual(cfin.json["number"] as? String, "GS-0001", "\(cfin.json)")
        let b = (try await live(app1, .GET, s.docs + "/\(inv)/balance", token: t)).json
        XCTAssertEqual(num(b["paid"]), dec("1154.30")); XCTAssertEqual(num(b["skonto"]), dec("35.70")); XCTAssertEqual(num(b["open_balance"]), 0)
        XCTAssertEqual(num(b["credited"]), 119); XCTAssertEqual(num(b["total_balance"]), -119); XCTAssertEqual(b["payment_status"] as? String, "overpaid")
        let chain = items(try await live(app2, .GET, s.docs + "/\(inv)/links", token: t))
        XCTAssertEqual(Set(chain.map { "\($0["kind"] ?? "") \($0["direction"] ?? "")" }), ["conversion incoming", "credit_note outgoing"])
    }
}
