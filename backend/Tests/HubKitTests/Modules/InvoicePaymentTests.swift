import XCTVapor
import Fluent
import SQLKit
@testable import HubKit

/// WP-R3: Zahlungen mit Skonto, ausdrückliche Zuordnung („nie still“), Gutschrift, Umwandlung, Verknüpfungen Beleg↔Beleg. Nur synthetische Daten.
class InvoicePaymentTestBase: InvoiceTestBase, @unchecked Sendable {

    struct Setup {
        let w: World
        let contact: String
        /// Belegtyp-ID je Art (jede mit eigener Serie).
        let types: [String: String]
        var base: String { "api/v1/tenants/\(w.tenantA)/invoice" }
        var docs: String { base + "/documents" }
        var payments: String { base + "/payments" }
        var token: String { w.alice.token }
    }

    static let prefixes = ["quote": "AN", "order_confirmation": "AB", "delivery_note": "LS", "invoice": "RE", "credit_note": "GS"]

    func setup() async throws -> Setup {
        let w = try await world()
        let put = try await call(app1, .PUT, base(w.tenantA) + "/settings", json: ["sender_name": "Muster GmbH", "city": "Musterstadt", "currency": "EUR"], token: w.alice.token)
        XCTAssertEqual(put.status, .ok, "\(put.json)")
        var types: [String: String] = [:]
        for (kind, prefix) in Self.prefixes {
            let s = try await series(w, code: prefix.lowercased(), format: "\(prefix)-{N:4}")
            XCTAssertEqual(s.status, .created, "\(s.json)")
            let t = try await call(app1, .POST, base(w.tenantA) + "/document-types", json: ["code": kind, "name": kind, "kind": kind, "default_series_id": s.json["id"] as? String ?? ""], token: w.alice.token)
            XCTAssertEqual(t.status, .created, "\(t.json)")
            types[kind] = t.json["id"] as? String
        }
        let c = try await call(app1, .POST, "api/v1/tenants/\(w.tenantA)/contacts", json: ["kind": "organization", "display_name": "Kunde AG"], token: w.alice.token)
        XCTAssertEqual(c.status, .created, "\(c.json)")
        return Setup(w: w, contact: c.json["id"] as? String ?? "", types: types)
    }

    /// Entwurf mit einer Position `gross` ohne Steuer (Bruttosumme = `gross`).
    func draft(_ s: Setup, _ gross: String = "119", kind: String = "invoice", extra: [String: Any] = [:]) async throws -> String {
        var body: [String: Any] = ["document_type_id": s.types[kind]!, "contact_id": s.contact, "issue_date": "2026-11-23", "currency": "EUR",
                                   "lines": [["kind": "item", "description": "Leistung", "quantity": "1", "unit_price": gross, "tax_rate": "0"]]]
        for (k, v) in extra { body[k] = v }
        let r = try await call(app1, .POST, s.docs, json: body, token: s.token)
        XCTAssertEqual(r.status, .created, "\(r.json)")
        return r.json["id"] as? String ?? ""
    }

    @discardableResult
    func finalize(_ s: Setup, _ id: String, via: Application? = nil) async throws -> Resp {
        try await call(via ?? app1, .POST, s.docs + "/\(id)/finalize", json: [String: Any](), token: s.token)
    }

    /// Finalisierte Rechnung.
    func invoice(_ s: Setup, _ gross: String = "119", extra: [String: Any] = [:]) async throws -> String {
        let id = try await draft(s, gross, extra: extra)
        let f = try await finalize(s, id)
        XCTAssertEqual(f.status, .ok, "\(f.json)")
        return id
    }

    func payment(_ s: Setup, _ amount: String, on date: String = "2026-11-25", extra: [String: Any] = [:]) async throws -> String {
        var body: [String: Any] = ["amount": amount, "paid_on": date]
        for (k, v) in extra { body[k] = v }
        let r = try await call(app1, .POST, s.payments, json: body, token: s.token)
        XCTAssertEqual(r.status, .created, "\(r.json)")
        return r.json["id"] as? String ?? ""
    }

    func allocate(_ s: Setup, _ payment: String, _ document: String, _ amount: String, extra: [String: Any] = [:], via: Application? = nil, token: String? = nil) async throws -> Resp {
        var body: [String: Any] = ["document_id": document, "amount": amount, "confirmed": true]
        for (k, v) in extra { body[k] = v }
        return try await call(via ?? app1, .POST, s.payments + "/\(payment)/allocations", json: body, token: token ?? s.token)
    }

    func balance(_ s: Setup, _ id: String, via: Application? = nil) async throws -> [String: Any] {
        let r = try await call(via ?? app2, .GET, s.docs + "/\(id)/balance", token: s.token)
        XCTAssertEqual(r.status, .ok, "\(r.json)")
        return r.json
    }

    func creditNote(_ s: Setup, _ invoice: String, via: Application? = nil, headers: [String: String] = [:]) async throws -> Resp {
        try await call(via ?? app1, .POST, s.docs + "/\(invoice)/credit-note", json: ["document_type_id": s.types["credit_note"]!, "issue_date": "2026-11-24"], token: s.token, headers: headers)
    }

    func convert(_ s: Setup, _ source: String, to kind: String, via: Application? = nil, headers: [String: String] = [:]) async throws -> Resp {
        try await call(via ?? app1, .POST, s.docs + "/\(source)/convert", json: ["document_type_id": s.types[kind]!, "issue_date": "2026-11-24"], token: s.token, headers: headers)
    }

    func links(_ s: Setup, _ id: String) async throws -> [[String: Any]] {
        let r = try await call(app2, .GET, s.docs + "/\(id)/links", token: s.token)
        XCTAssertEqual(r.status, .ok, "\(r.json)")
        return items(r)
    }

    func num(_ any: Any?, file: StaticString = #filePath, line: UInt = #line) -> Decimal? { (any as? String).flatMap { Decimal(string: $0, locale: Locale(identifier: "en_US_POSIX")) } }
    func dec(_ s: String) -> Decimal { Decimal(string: s, locale: Locale(identifier: "en_US_POSIX"))! }

    /// 422 mit genau diesem Feldfehler.
    func assertField(_ r: Resp, _ field: String, _ code: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(r.status, .unprocessableEntity, "\(r.json)", file: file, line: line)
        let errors = (r.json["errors"] as? [[String: Any]] ?? []).map { "\($0["field"] ?? "") \($0["code"] ?? "")" }
        XCTAssertEqual(errors, ["\(field) \(code)"], file: file, line: line)
    }

    func assertConflict(_ r: Resp, _ code: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(r.status, .conflict, "\(r.json)", file: file, line: line)
        XCTAssertEqual(r.problemCode, code, "\(r.json)", file: file, line: line)
    }

    func activeAllocations() async throws -> Int64 { try await count("invoice_payment_allocations", where: "revoked_at IS NULL") }

    func expectSQLFailure(_ statement: String, file: StaticString = #filePath, line: UInt = #line) async {
        do { try await db.raw("\(unsafeRaw: statement)").run(); XCTFail("muss scheitern: \(statement)", file: file, line: line) } catch {}
    }
}

final class InvoicePaymentTests: InvoicePaymentTestBase, @unchecked Sendable {

    // MARK: AK-R3-1 Salden

    private struct Vectors: Decodable {
        struct Payment: Decodable { let amount: String; let allocations: [String: String] }
        struct Linked: Decodable { let gross: String }
        struct Input: Decodable { let gross: String; let payments: [Payment]; let linkedDocuments: [Linked] }
        struct Expected: Decodable { let paid: String; let openBalance: String; let totalBalance: String }
        struct Vector: Decodable { let id: String; let input: Input; let expected: Expected }
        let vectors: [Vector]
    }

    /// AK-R3-1: Alle fünf Salden-Vektoren (`balances.json`) Ende-zu-Ende: Rechnung, Zahlungen, Zuordnungen, Gutschrift, Saldo über die API.
    func testAKR3_1_BalanceVectors() async throws {
        let s = try await setup()
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../Fixtures/taxlab-vectors/balances.json").standardized
        let vectors = try JSONDecoder().decode(Vectors.self, from: Data(contentsOf: url)).vectors
        XCTAssertEqual(vectors.count, 5)
        for v in vectors {
            let doc = try await invoice(s, v.input.gross)
            var other: String?
            for p in v.input.payments {
                let pid = try await payment(s, p.amount)
                for (key, amount) in p.allocations.sorted(by: { $0.key < $1.key }) {
                    var target = doc
                    if key != "doc" { if other == nil { other = try await invoice(s, amount) }; target = other! }
                    let over: [String: Any] = dec(amount) > dec(v.input.gross) ? ["overpayment": true] : [:]
                    let r = try await allocate(s, pid, target, amount, extra: over)
                    XCTAssertEqual(r.status, .created, "\(v.id): \(r.json)")
                }
            }
            for linked in v.input.linkedDocuments {
                let cn = try await creditNote(s, doc)
                XCTAssertEqual(cn.status, .created, "\(v.id): \(cn.json)")
                let cid = cn.json["id"] as? String ?? ""
                // Teilgutschrift: Position auf den Betrag des Vektors ändern
                let patch = try await call(app1, .PATCH, s.docs + "/\(cid)", json: ["lines": [["kind": "item", "description": "Nachlass", "quantity": "-1",
                    "unit_price": String(linked.gross.dropFirst()), "tax_rate": "0"]]], token: s.token)
                XCTAssertEqual(patch.status, .ok, "\(v.id): \(patch.json)")
                try await aEq((try await finalize(s, cid)).status, .ok, v.id)
            }
            let b = try await balance(s, doc)
            XCTAssertEqual(num(b["paid"]), dec(v.expected.paid), "\(v.id) paid")
            XCTAssertEqual(num(b["open_balance"]), dec(v.expected.openBalance), "\(v.id) open")
            XCTAssertEqual(num(b["total_balance"]), dec(v.expected.totalBalance), "\(v.id) total")
        }
    }

    // MARK: AK-R3-2 Zuordnung nie still

    /// AK-R3-2: Eine Zahlung mit passender Nummer und passendem Betrag wird nie automatisch zugeordnet; Vorschläge ändern nichts; erst die bestätigte
    /// Zuordnung (`confirmed: true`) bucht, mit Nutzer und Audit.
    func testAKR3_2_AllocationOnlyAfterConfirmation() async throws {
        let s = try await setup()
        let doc = try await invoice(s)
        let noise = try await invoice(s, "55")
        let r = try await call(app1, .POST, s.payments, json: ["amount": "119", "paid_on": "2026-11-25", "reference": "Zahlung RE-0001 danke", "contact_id": s.contact], token: s.token)
        XCTAssertEqual(r.status, .created, "\(r.json)")
        let pid = r.json["id"] as? String ?? ""
        XCTAssertEqual((r.json["allocations"] as? [Any])?.count, 0)
        XCTAssertEqual(num(r.json["unallocated"]), 119)
        try await aEq(try await activeAllocations(), 0)
        // Vorschläge: nur lesen, mit Begründung, beste zuerst
        let sug = try await call(app2, .GET, s.payments + "/\(pid)/suggestions", token: s.token)
        XCTAssertEqual(sug.status, .ok, "\(sug.json)")
        let first = items(sug).first
        XCTAssertEqual(first?["document_id"] as? String, doc)
        XCTAssertEqual(Set(first?["reasons"] as? [String] ?? []), ["number_in_reference", "amount_matches_open", "same_contact"])
        XCTAssertEqual(num(first?["amount"]), 119)
        XCTAssertEqual(items(sug).map { $0["document_id"] as? String }, [doc, noise])
        try await aEq(try await activeAllocations(), 0, "Vorschläge ordnen nichts zu")
        try await aEq(num((try await balance(s, doc))["open_balance"]), 119)
        try await aEq(try await count("audit_log", where: "action = 'invoice.payment.allocated'"), 0)
        // Ohne Bestätigung keine Zuordnung
        let path = s.payments + "/\(pid)/allocations"
        assertField(try await call(app1, .POST, path, json: ["document_id": doc, "amount": "119"], token: s.token), "confirmed", "required")
        assertField(try await call(app1, .POST, path, json: ["document_id": doc, "amount": "119", "confirmed": false], token: s.token), "confirmed", "required")
        assertField(try await call(app1, .POST, path, json: ["document_id": doc, "amount": "119", "confirmed": "true"], token: s.token), "confirmed", "required")
        assertField(try await call(app1, .POST, path, json: ["document_id": doc, "confirmed": true], token: s.token), "amount", "required")
        assertField(try await call(app1, .POST, path, json: ["amount": "119", "confirmed": true], token: s.token), "document_id", "required")
        try await aEq(try await activeAllocations(), 0)
        // Bestätigt
        let a = try await allocate(s, pid, doc, "119")
        XCTAssertEqual(a.status, .created, "\(a.json)")
        XCTAssertEqual(num(a.json["unallocated"]), 0)
        let alloc = (a.json["allocations"] as? [[String: Any]])?.first
        XCTAssertEqual(alloc?["document_id"] as? String, doc)
        XCTAssertEqual(alloc?["confirmed_by"] as? String, s.w.alice.userID.uppercased())
        XCTAssertNotNil(alloc?["confirmed_at"] as? String)
        let b = try await balance(s, doc)
        XCTAssertEqual(b["payment_status"] as? String, "settled"); XCTAssertEqual(num(b["open_balance"]), 0)
        try await aEq(try await count("audit_log", where: "action = 'invoice.payment.allocated'"), 1)
        // Zugeordnete Zahlung fehlt im Filter `unassigned`, die offene steht darin
        let open = try await payment(s, "5")
        let list = try await call(app1, .GET, s.payments + "?unassigned=true", token: s.token)
        XCTAssertEqual(items(list).map { $0["id"] as? String }, [open])
        try await aEq(items(try await call(app1, .GET, s.payments, token: s.token)).count, 2)
    }

    // MARK: AK-R3-3 Skonto

    /// AK-R3-3: Skonto nur laut Belegbedingung, innerhalb der Frist (Zahldatum), höchstens der vereinbarte Satz, nur wenn es den Rest ausgleicht, nie automatisch.
    func testAKR3_3_Skonto() async throws {
        let s = try await setup()
        let terms: [String: Any] = ["skonto_percent": "2", "skonto_days": 10]
        let doc = try await invoice(s, "119", extra: terms)
        var b = try await balance(s, doc)
        let sk = b["skonto_terms"] as? [String: Any]
        XCTAssertEqual(sk?["deadline"] as? String, "2026-12-03"); XCTAssertEqual(num(sk?["amount"]), dec("2.38")); XCTAssertEqual(sk?["days"] as? Int, 10)
        // Frist verpasst (Tag 11)
        let late = try await payment(s, "116.62", on: "2026-12-04")
        assertField(try await allocate(s, late, doc, "116.62", extra: ["skonto_amount": "2.38"]), "skonto_amount", "skonto_period_expired")
        // letzter Fristtag
        let pid = try await payment(s, "116.62", on: "2026-12-03", extra: ["reference": "RE-0001"])
        let sug = try await call(app1, .GET, s.payments + "/\(pid)/suggestions", token: s.token)
        XCTAssertEqual(Set(items(sug).first?["reasons"] as? [String] ?? []), ["number_in_reference", "amount_matches_skonto"])
        XCTAssertEqual(num(items(sug).first?["skonto_amount"]), dec("2.38"))
        assertField(try await allocate(s, pid, doc, "116.61", extra: ["skonto_amount": "2.39"]), "skonto_amount", "skonto_exceeds_terms")
        assertField(try await allocate(s, pid, doc, "100", extra: ["skonto_amount": "2.38"]), "skonto_amount", "skonto_must_settle")
        assertField(try await allocate(s, pid, doc, "116.62", extra: ["skonto_amount": "-1"]), "skonto_amount", "invalid")
        // ohne skonto_amount wird nichts nachgelassen
        let plain = try await allocate(s, pid, doc, "116.62")
        XCTAssertEqual(plain.status, .created, "\(plain.json)")
        b = try await balance(s, doc)
        XCTAssertEqual(num(b["open_balance"]), dec("2.38")); XCTAssertEqual(b["payment_status"] as? String, "partial"); XCTAssertEqual(num(b["skonto"]), 0)
        let aid = (plain.json["allocations"] as? [[String: Any]])?.first?["id"] as? String ?? ""
        let revoked = try await call(app2, .DELETE, s.payments + "/\(pid)/allocations/\(aid)", token: s.token)
        XCTAssertEqual(revoked.status, .ok, "\(revoked.json)"); XCTAssertEqual(num(revoked.json["unallocated"]), dec("116.62"))
        // mit bestätigtem Skonto ausgeglichen
        let ok = try await allocate(s, pid, doc, "116.62", extra: ["skonto_amount": "2.38"])
        XCTAssertEqual(ok.status, .created, "\(ok.json)")
        b = try await balance(s, doc)
        XCTAssertEqual(num(b["paid"]), dec("116.62")); XCTAssertEqual(num(b["skonto"]), dec("2.38")); XCTAssertEqual(num(b["open_balance"]), 0)
        XCTAssertEqual(b["payment_status"] as? String, "settled")
        // ohne Bedingung kein Skonto
        let bare = try await invoice(s, "100")
        let p2 = try await payment(s, "98")
        assertField(try await allocate(s, p2, bare, "98", extra: ["skonto_amount": "2"]), "skonto_amount", "skonto_not_allowed")
        // Bedingungen: nur gemeinsam, Grenzen, am finalen Beleg unveränderlich, an Angeboten ok
        for (bad, field) in [(["skonto_percent": "2"] as [String: Any], "skonto_days"), (["skonto_days": 7], "skonto_percent")] {
            var body: [String: Any] = ["document_type_id": s.types["invoice"]!, "issue_date": "2026-11-23"]
            for (k, v) in bad { body[k] = v }
            assertField(try await call(app1, .POST, s.docs, json: body, token: s.token), field, "required_together")
        }
        for bad in [["skonto_percent": "100", "skonto_days": 7] as [String: Any], ["skonto_percent": "0", "skonto_days": 7], ["skonto_percent": "2", "skonto_days": 366]] {
            var body: [String: Any] = ["document_type_id": s.types["invoice"]!, "issue_date": "2026-11-23"]
            for (k, v) in bad { body[k] = v }
            try await aEq((try await call(app1, .POST, s.docs, json: body, token: s.token)).status, .unprocessableEntity, "\(bad)")
        }
        let d = try await draft(s, "10", extra: terms)
        assertField(try await call(app1, .PATCH, s.docs + "/\(d)", json: ["skonto_days": NSNull()], token: s.token), "skonto_days", "required_together")
        assertConflict(try await call(app1, .PATCH, s.docs + "/\(doc)", json: ["skonto_percent": "3"], token: s.token), "document_final_immutable")
    }

    // MARK: AK-R3-4 Grenzen

    /// AK-R3-4: Zuordnung nie über den Zahlbetrag; über den offenen Betrag nur ausdrücklich als Überzahlung; nur finale Rechnungen gleicher Währung;
    /// Storno einer Zahlung erst nach Rücknahme der Zuordnungen.
    func testAKR3_4_AllocationLimitsAndVoid() async throws {
        let s = try await setup()
        let doc = try await invoice(s, "100"), second = try await invoice(s, "100")
        let pid = try await payment(s, "150")
        assertField(try await allocate(s, pid, doc, "150.01", extra: ["overpayment": true]), "amount", "exceeds_payment")
        assertField(try await allocate(s, pid, doc, "120"), "amount", "exceeds_open_amount")
        assertField(try await allocate(s, pid, doc, "0"), "amount", "invalid")
        assertField(try await allocate(s, pid, doc, "1.005"), "amount", "invalid")
        let over = try await allocate(s, pid, doc, "120", extra: ["overpayment": true])
        XCTAssertEqual(over.status, .created, "\(over.json)")
        XCTAssertEqual((over.json["allocations"] as? [[String: Any]])?.first?["overpayment"] as? Bool, true)
        let b = try await balance(s, doc)
        XCTAssertEqual(b["payment_status"] as? String, "overpaid"); XCTAssertEqual(num(b["total_balance"]), -20)
        assertConflict(try await allocate(s, pid, doc, "1"), "conflict")  // dieselbe Zahlung ist diesem Beleg schon zugeordnet
        assertField(try await allocate(s, pid, second, "31"), "amount", "exceeds_payment")
        // nur finale Rechnungen gleicher Währung
        let d = try await draft(s)
        assertConflict(try await allocate(s, pid, d, "1"), "document_not_final")
        assertConflict(try await call(app1, .GET, s.docs + "/\(d)/balance", token: s.token), "document_not_final")
        let quote = try await draft(s, kind: "quote")
        try await finalize(s, quote)
        assertField(try await allocate(s, pid, quote, "1"), "document_id", "not_an_invoice")
        let usd = try await invoice(s, "100", extra: ["currency": "USD"])
        assertField(try await allocate(s, pid, usd, "1"), "document_id", "currency_mismatch")
        assertField(try await allocate(s, pid, UUID().uuidString, "1"), "document_id", "not_found")
        // Storno
        assertConflict(try await call(app1, .POST, s.payments + "/\(pid)/void", json: ["reason": "Fehlbuchung"], token: s.token), "payment_allocated")
        let aid = (over.json["allocations"] as? [[String: Any]])?.first?["id"] as? String ?? ""
        try await aEq((try await call(app1, .DELETE, s.payments + "/\(pid)/allocations/\(aid)", token: s.token)).status, .ok)
        try await aEq((try await call(app1, .DELETE, s.payments + "/\(pid)/allocations/\(aid)", token: s.token)).status, .notFound)
        assertField(try await call(app1, .POST, s.payments + "/\(pid)/void", json: [String: Any](), token: s.token), "reason", "required")
        let v = try await call(app1, .POST, s.payments + "/\(pid)/void", json: ["reason": "Fehlbuchung"], token: s.token)
        XCTAssertEqual(v.status, .ok, "\(v.json)"); XCTAssertEqual(v.json["void_reason"] as? String, "Fehlbuchung"); XCTAssertEqual(num(v.json["unallocated"]), 0)
        assertConflict(try await call(app2, .POST, s.payments + "/\(pid)/void", json: ["reason": "x"], token: s.token), "payment_voided")
        assertConflict(try await allocate(s, pid, second, "1"), "payment_voided")
        // Historie bleibt: die zurückgenommene Zuordnung ist sichtbar
        let got = try await call(app2, .GET, s.payments + "/\(pid)", token: s.token)
        XCTAssertNotNil((got.json["allocations"] as? [[String: Any]])?.first?["revoked_at"] as? String)
        // Eingaben beim Anlegen
        for (body, field) in [(["paid_on": "2026-11-25"], "amount"), (["amount": "5"], "paid_on")] {
            assertField(try await call(app1, .POST, s.payments, json: body, token: s.token), field, "required")
        }
        for body in [["amount": "-5", "paid_on": "2026-11-25"] as [String: Any], ["amount": 5.5, "paid_on": "2026-11-25"], ["amount": "0", "paid_on": "2026-11-25"],
                     ["amount": "5", "paid_on": "2026-02-30"], ["amount": "5", "paid_on": "2026-11-25", "method": "bitcoin"],
                     ["amount": "5", "paid_on": "2026-11-25", "document_id": doc]] {
            try await aEq((try await call(app1, .POST, s.payments, json: body, token: s.token)).status, .unprocessableEntity, "\(body)")
        }
        // Idempotency-Key: keine doppelte Zahlung
        let before = try await count("invoice_payments")
        let k1 = try await call(app1, .POST, s.payments, json: ["amount": "7", "paid_on": "2026-11-25"], token: s.token, headers: ["Idempotency-Key": "pay-1"])
        let k2 = try await call(app2, .POST, s.payments, json: ["amount": "7", "paid_on": "2026-11-25"], token: s.token, headers: ["Idempotency-Key": "pay-1"])
        XCTAssertEqual(k1.status, .created); XCTAssertEqual(k2.json["id"] as? String, k1.json["id"] as? String)
        try await aEq(try await count("invoice_payments"), before + 1)
    }

    // MARK: AK-R3-5 zwei Instanzen

    /// AK-R3-5: Parallele Zuordnungen über zwei Instanzen überschreiten weder den Zahlbetrag noch den Rechnungsbetrag.
    func testAKR3_5_ParallelAllocationsAcrossInstances() async throws {
        let s = try await setup()
        var docs: [String] = []
        for _ in 0..<8 { docs.append(try await invoice(s, "60")) }
        let pid = try await payment(s, "100")
        let targets = docs
        let a = try await parallel(8) { i in try await self.allocate(s, pid, targets[i], "60", via: i % 2 == 0 ? self.app1 : self.app2) }
        XCTAssertEqual(a.filter { $0.status == .created }.count, 1, a.map { "\($0.status.code) \($0.json)" }.joined(separator: "\n"))
        XCTAssertEqual(a.filter { $0.status == .unprocessableEntity }.count, 7)
        try await aEq(try await activeAllocations(), 1)
        let one = try await invoice(s, "100")
        var pays: [String] = []
        for _ in 0..<8 { pays.append(try await payment(s, "100")) }
        let sources = pays
        let b = try await parallel(8) { i in try await self.allocate(s, sources[i], one, "100", via: i % 2 == 0 ? self.app1 : self.app2) }
        XCTAssertEqual(b.filter { $0.status == .created }.count, 1, b.map { "\($0.status.code) \($0.json)" }.joined(separator: "\n"))
        try await aEq(num((try await balance(s, one))["total_balance"]), 0)
        // zwei volle Gutschriften derselben Rechnung parallel finalisieren: genau eine gewinnt, die andere verbraucht keine Nummer
        let target = try await invoice(s, "80")
        let c1 = (try await creditNote(s, target)).json["id"] as? String ?? "", c2 = (try await creditNote(s, target)).json["id"] as? String ?? ""
        let c = try await parallel(2) { i in try await self.finalize(s, i == 0 ? c1 : c2, via: i == 0 ? self.app1 : self.app2) }
        XCTAssertEqual(c.map { $0.status.code }.sorted(), [200, 422], c.map { "\($0.json)" }.joined(separator: "\n"))
        try await aEq(num((try await balance(s, target))["total_balance"]), 0)
        try await aEq(try await count("invoice_documents", where: "kind = 'credit_note' AND status = 'final'"), 1)
        try await aEq(try await scalar("SELECT max(value) AS v FROM counters WHERE tenant_id = '\(s.w.tenantA)' AND key LIKE 'invoice:%' AND key ILIKE '%' || (SELECT id::text FROM invoice_series WHERE code = 'gs') || '%'", as: Int64.self), 1)
    }

    // MARK: AK-R3-6 Datenbank

    /// AK-R3-6: Die Datenbank selbst erzwingt die Grenzen: keine Überzuordnung, keine Zuordnung auf Entwürfe, Zahlungen und Zuordnungen nicht änder- oder löschbar.
    func testAKR3_6_DatabaseInvariants() async throws {
        let s = try await setup()
        let doc = try await invoice(s, "100"), d = try await draft(s), other = try await invoice(s, "100")
        let pid = try await payment(s, "150")
        try await aEq((try await allocate(s, pid, doc, "100")).status, .created)
        let t = s.w.tenantA, u = s.w.alice.userID
        func insert(_ target: String, _ amount: String, skonto: String = "0", over: Bool = false) -> String {
            "INSERT INTO invoice_payment_allocations (tenant_id, payment_id, document_id, amount, skonto_amount, overpayment, confirmed_by) VALUES ('\(t)', '\(pid)', '\(target)', \(amount), \(skonto), \(over), '\(u)')"
        }
        await expectSQLFailure(insert(other, "50.01"))                 // mehr als die Zahlung
        await expectSQLFailure(insert(d, "1"))                          // Entwurf
        await expectSQLFailure(insert(other, "50", skonto: "60"))       // mehr als der Rechnungsbetrag ohne Kennzeichen
        await expectSQLFailure("UPDATE invoice_payment_allocations SET amount = 1 WHERE payment_id = '\(pid)'")
        await expectSQLFailure("DELETE FROM invoice_payment_allocations WHERE payment_id = '\(pid)'")
        await expectSQLFailure("UPDATE invoice_payments SET amount = 500 WHERE id = '\(pid)'")
        await expectSQLFailure("DELETE FROM invoice_payments WHERE id = '\(pid)'")
        await expectSQLFailure("UPDATE invoice_payments SET voided_at = now(), voided_by = '\(u)', void_reason = 'x' WHERE id = '\(pid)'")  // noch zugeordnet
        try await db.raw(SQLQueryString(insert(other, "50"))).run()    // Rest ist erlaubt
        try await db.raw(SQLQueryString("UPDATE invoice_payment_allocations SET revoked_at = now(), revoked_by = '\(u)' WHERE document_id = '\(other)'")).run()
        await expectSQLFailure("UPDATE invoice_payment_allocations SET revoked_at = NULL, revoked_by = NULL WHERE document_id = '\(other)'")
        try await aEq(try await activeAllocations(), 1)
    }

    // MARK: AK-R3-10 Migration

    /// AK-R3-10: Migration `invoice_029_payments` ist rückbaubar und wieder anwendbar.
    func testAKR3_10_MigrationRevertAndReapply() async throws {
        _ = try await world(enable: false)
        let tables = ["invoice_payments", "invoice_payment_allocations", "invoice_document_links"]
        for tbl in tables { try await aEq(try await count("information_schema.tables", where: "table_name = '\(tbl)'"), 1, tbl) }
        try await aEq(try await count("_fluent_migrations", where: "name = 'invoice_029_payments'"), 1)
        let m = try XCTUnwrap(InvoiceModule().migrations.first { $0.name == "invoice_029_payments" } as? any AsyncMigration), database = app1.db(.psql)
        try await m.revert(on: database)
        for tbl in tables { try await aEq(try await count("information_schema.tables", where: "table_name = '\(tbl)'"), 0, tbl) }
        try await aEq(try await count("information_schema.columns", where: "table_name = 'invoice_documents' AND column_name LIKE 'skonto%'"), 0)
        try await m.prepare(on: database)
        for tbl in tables { try await aEq(try await count("information_schema.tables", where: "table_name = '\(tbl)'"), 1, tbl) }
    }
}
