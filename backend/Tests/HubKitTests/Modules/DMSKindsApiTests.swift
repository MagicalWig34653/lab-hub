import XCTVapor
import Fluent
import SQLKit
@testable import HubKit

// WP-D8: Neu-Lauf-Route und Dokumentliste für alle neuen Arten (mit Datenbank, zwei Instanzen). Alles synthetisch.
// AK-D8-8  Neu-Lauf (Route) funktioniert für alle Arten, idempotent, mit den Fakten der Art
// AK-D8-10 Fristen erscheinen in der Fälligkeitsspalte und lassen sich über due_from/due_to filtern und sortieren (Behörde: früheste Frist, Vertrag: Ende)
// Mandantentrennung und Rechte der Route sind in D7 getestet (DMSExtractionTests.testAKD7_8/9) und unverändert.
final class DMSKindsApiTests: DMSRulesTestBase {
    func testAKD8_8_10_rerunAllKindsAndDueFilters() async throws {
        let w = try await world()
        let engine = ScriptedOCREngine()
        let cases: [(key: String, name: String, kind: String)] = [
            ("contract", "contract-wartung-de", "contract"), ("insurance", "insurance-hausrat-de", "insurance"), ("tax", "tax-est-erstattung", "tax_notice"),
            ("letter", "letter-verwarnung", "letter"), ("statement", "statement-standard-de", "bank_statement"), ("receipt", "receipt-markt-bar", "receipt"),
            ("other", "letter-neg-info-muellabfuhr", "other")]
        var ids: [String: String] = [:]
        for c in cases {
            let text = ExtractionKindCorpus.all.first { $0.name == c.name }!.text
            ids[c.key] = try await uploadText(w, engine, seed: "d8-\(c.key)", text: text)
        }
        try await drain(engine)
        let outbox = try await count("dms_event_outbox")
        for c in cases {
            let doc = ids[c.key]!
            let first = try await call(app1, .GET, base(w.tenantA) + "/documents/\(doc)/extraction", token: w.alice.token)
            XCTAssertEqual(first.status, .ok, "\(first.json)")
            XCTAssertEqual(first.json["kind"] as? String, c.kind, c.key)
            XCTAssertEqual(first.json["extractor_version"] as? Int, ExtractionResult.version)
            for _ in 0..<2 {
                let r = try await call(app2, .POST, base(w.tenantA) + "/documents/\(doc)/extraction/run", token: w.alice.token)
                XCTAssertEqual(r.status, .ok, "\(c.key) \(r.json)")
                XCTAssertEqual(NSDictionary(dictionary: r.json.filter { $0.key != "updated_at" }), NSDictionary(dictionary: first.json.filter { $0.key != "updated_at" }), "\(c.key): gleicher Text = gleiches Ergebnis")
            }
            try await aEq(try await count("dms_extractions", where: "document_id = '\(doc)' AND runs = 3"), 1, c.key)
        }
        try await aEq(try await count("dms_event_outbox"), outbox, "Neu-Läufe erzeugen keine zweiten Ereignisse")

        // Faktentypen der Arten über die API
        func types(_ key: String) async throws -> Set<String> {
            let r = try await call(app1, .GET, base(w.tenantA) + "/documents/\(ids[key]!)/extraction", token: w.alice.token)
            return Set((r.json["facts"] as? [[String: Any]] ?? []).compactMap { $0["type"] as? String })
        }
        let contract = try await types("contract"), tax = try await types("tax"), statement = try await types("statement"), receipt = try await types("receipt")
        XCTAssertTrue(contract.isSuperset(of: ["contract_number", "term", "notice_period", "auto_renewal", "recurring_amount", "payment_interval", "period_start", "counterparty"]), "\(contract)")
        XCTAssertTrue(tax.isSuperset(of: ["authority", "tax_number", "tax_id", "objection_deadline", "settlement_amount", "notice_type"]), "\(tax)")
        XCTAssertTrue(statement.isSuperset(of: ["balance_opening", "balance_closing", "iban", "period_start", "period_end"]), "\(statement)")
        XCTAssertTrue(receipt.isSuperset(of: ["amount_tax_7", "amount_tax_19", "payment_method", "seller", "amount"]), "\(receipt)")

        // Übersicht: Betrag (vorzeichenbehaftet), Fälligkeit/Frist, Referenz je Art
        func summary(_ key: String) async throws -> [String: Any] {
            let r = try await call(app1, .GET, base(w.tenantA) + "/documents/\(ids[key]!)", token: w.alice.token)
            return r.json["extraction"] as? [String: Any] ?? [:]
        }
        let taxS = try await summary("tax"), contractS = try await summary("contract"), stmtS = try await summary("statement")
        XCTAssertEqual(taxS["amount"] as? String, "-520.00"); XCTAssertEqual(taxS["due_date"] as? String, "2026-12-08"); XCTAssertEqual(taxS["currency"] as? String, "EUR")
        XCTAssertEqual(contractS["amount"] as? String, "450.00"); XCTAssertEqual(contractS["reference"] as? String, "WV-2026-017")
        XCTAssertEqual(stmtS["amount"] as? String, "2821.00"); XCTAssertEqual(stmtS["reference"] as? String, ExtractionKindCorpus.ibanDE)

        // Fristen in Spalte, Filter und Sortierung
        let key = Dictionary(uniqueKeysWithValues: ids.map { ($1, $0) })
        func order(_ q: String) async throws -> [String] {
            items(try await call(app1, .GET, base(w.tenantA) + "/documents?limit=50" + q, token: w.alice.token)).compactMap { key[$0["id"] as? String ?? ""] }
        }
        let beforeDec = try await order("&due_to=2026-11-30&sort=due_date")
        let december = try await order("&due_from=2026-12-01&due_to=2026-12-31&sort=due_date")
        let letters = try await order("&kind=letter&sort=due_date")
        let late = try await order("&due_from=2027-01-01&sort=due_date")
        let all = try await order("&due_from=2000-01-01&sort=due_date")
        XCTAssertEqual(beforeDec, ["letter"], "nur die Verwarnung hat eine Frist bis 30.11.")
        XCTAssertEqual(december, ["tax"], "Einspruchsfrist des Steuerbescheids")
        XCTAssertEqual(letters, ["letter"])
        XCTAssertTrue(late.contains("insurance"), "Versicherung fällig 01.01.2027")
        XCTAssertEqual(Array(all.prefix(2)), ["letter", "tax"], "früheste Frist zuerst")
    }
}
