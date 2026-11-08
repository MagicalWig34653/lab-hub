import XCTest
import Foundation
@testable import HubKit

// WP-D8: reine Tests (ohne Datenbank) der artspezifischen Detektoren und Parser gegen den Entwicklungs- und den Holdout-Korpus.
// Entwicklungskorpus: Regeln wurden daran geschärft, die Zahlen sind optimistisch. Holdout: nach dem Einfrieren der Regeln geschrieben, nur zur Messung.

struct KindMetrics {
    var n = 0, kindOK = 0, tp = 0, fp = 0, fn = 0, fieldOK = 0, fieldTotal = 0
    var failures: [String] = []
    var precision: Double { Double(tp) / Double(max(1, tp + fp)) }
    var recall: Double { Double(tp) / Double(max(1, tp + fn)) }
    var kindAccuracy: Double { Double(kindOK) / Double(max(1, n)) }
    var fieldAccuracy: Double { Double(fieldOK) / Double(max(1, fieldTotal)) }
}

enum KindMeasure {
    static func run(_ c: KindCase) -> ExtractionResult {
        DocumentExtractor.extract(ExtractionInput(text: c.text, subject: c.subject, sender: c.sender))
    }

    static func best(_ r: ExtractionResult, _ type: String) -> ExtractedFact? {
        r.facts.filter { $0.type == type }.sorted { ($0.confidence, -($0.source?.offset ?? 0)) > ($1.confidence, -($1.source?.offset ?? 0)) }.first
    }

    /// Messung für eine Gruppe über `pool` (Fälle aller Gruppen zählen für die Precision mit: ein Kassenbon, der als Vertrag erkannt wird, ist ein Falsch-Positiv des Vertrags).
    static func measure(_ pool: [KindCase], group: DocumentKind, label: String) -> KindMetrics {
        var m = KindMetrics()
        for c in pool {
            let r = run(c)
            let predicted = ExtractionKindCorpus.group(r.kind) == group && r.kindCertain
            let actual = ExtractionKindCorpus.group(c.kind) == group && c.certain
            if predicted && actual { m.tp += 1 } else if predicted { m.fp += 1; m.failures.append("FALSCH-POSITIV \(c.name): \(r.kind) \(r.kindScore)") } else if actual { m.fn += 1; m.failures.append("FALSCH-NEGATIV \(c.name): \(r.kind) \(r.kindScore) \(r.scores.prefix(3).map { "\($0.kind.rawValue)=\($0.score)" })") }
            guard c.group == group else { continue }
            m.n += 1
            if r.kind == c.kind && r.kindCertain == c.certain { m.kindOK += 1 } else { m.failures.append("ART \(c.name): erwartet \(c.kind) war \(r.kind) \(r.kindScore) \(r.scores.prefix(3).map { "\($0.kind.rawValue)=\($0.score)" }) \(r.scores.first { $0.kind == c.kind }?.reasons ?? [])") }
            for (type, expected) in c.facts.sorted(by: { $0.key < $1.key }) {
                m.fieldTotal += 1
                let actualValue = best(r, type)?.value
                if actualValue == expected { m.fieldOK += 1 } else { m.failures.append("FELD \(c.name).\(type): erwartet \(expected) war \(actualValue ?? "nil")") }
            }
            if let cur = c.currency {
                for (type, _) in c.facts where ["amount", "premium", "recurring_amount", "settlement_amount", "balance_opening", "balance_closing"].contains(type) {
                    m.fieldTotal += 1
                    if best(r, type)?.currency == cur { m.fieldOK += 1 } else { m.failures.append("WÄHRUNG \(c.name).\(type): erwartet \(cur) war \(best(r, type)?.currency ?? "nil")") }
                }
            }
            for type in c.absent {
                m.fieldTotal += 1
                if r.facts.contains(where: { $0.type == type }) { m.failures.append("UNERWARTET \(c.name).\(type)") } else { m.fieldOK += 1 }
            }
            let s = DMSExtraction.summary(r)
            if let a = c.summary.amount { m.fieldTotal += 1; if s.amount == a { m.fieldOK += 1 } else { m.failures.append("ÜBERSICHT \(c.name).amount: erwartet \(a) war \(s.amount ?? "nil")") } }
            if let d = c.summary.due { m.fieldTotal += 1; if s.due == d { m.fieldOK += 1 } else { m.failures.append("ÜBERSICHT \(c.name).due: erwartet \(d) war \(s.due ?? "nil")") } }
            if let x = c.summary.reference { m.fieldTotal += 1; if s.reference == x { m.fieldOK += 1 } else { m.failures.append("ÜBERSICHT \(c.name).reference: erwartet \(x) war \(s.reference ?? "nil")") } }
        }
        print("D8 \(label) \(group.rawValue): n=\(m.n) precision=\(m.precision) recall=\(m.recall) kindAccuracy=\(m.kindAccuracy) fields=\(m.fieldOK)/\(m.fieldTotal) tp=\(m.tp) fp=\(m.fp) fn=\(m.fn)")
        for f in m.failures { print("D8 \(label) \(f)") }
        return m
    }

    static let groups: [DocumentKind] = [.contract, .insurance, .taxNotice, .bankStatement, .receipt]

    /// D7-Korpus als Fälle, damit die Precision der neuen Arten auch dort gilt (kein Rechnungs-/Mahn-/Newsletter-Fall darf zu einer neuen Art werden).
    static var d7Pool: [KindCase] {
        ExtractionCorpus.all.map { KindCase(name: "d7-" + $0.name, group: ExtractionKindCorpus.group($0.kind), text: $0.text, subject: $0.subject, sender: $0.sender, kind: $0.kind) }
    }
}

final class ExtractionKindsTests: XCTestCase {
    // MARK: AK-D8-1…5 Qualität je Art (Entwicklungskorpus)

    func testAKD8_dev_corpusSizes() {
        for g in KindMeasure.groups {
            let pos = ExtractionKindCorpus.all.filter { $0.group == g && ExtractionKindCorpus.group($0.kind) == g }
            let neg = ExtractionKindCorpus.all.filter { $0.group == g && ExtractionKindCorpus.group($0.kind) != g }
            XCTAssertGreaterThanOrEqual(pos.count, 6, "\(g)")
            XCTAssertGreaterThanOrEqual(neg.count, 4, "\(g)")
        }
    }

    func testAKD8_dev_qualityPerKind() {
        let pool = ExtractionKindCorpus.all + KindMeasure.d7Pool
        for g in KindMeasure.groups {
            let m = KindMeasure.measure(pool, group: g, label: "dev")
            XCTAssertEqual(m.fp, 0, "\(g): keine Falsch-Positive \(m.failures)")
            XCTAssertEqual(m.precision, 1.0, "\(g)")
            XCTAssertGreaterThanOrEqual(m.recall, 0.95, "\(g): \(m.failures)")
            XCTAssertGreaterThanOrEqual(m.kindAccuracy, 0.95, "\(g): \(m.failures)")
            XCTAssertGreaterThanOrEqual(m.fieldAccuracy, 0.95, "\(g): \(m.failures)")
        }
    }

    /// Rechnung bleibt unberührt: Precision 1,0 und Recall >= 0,95 im D7-Korpus plus allen D8-Fällen.
    func testAKD8_invoiceStillPerfectAcrossBothCorpora() {
        var tp = 0, fp = 0, fn = 0
        for c in ExtractionCorpus.all.map({ KindCase(name: $0.name, group: .other, text: $0.text, subject: $0.subject, sender: $0.sender, kind: $0.kind) }) + ExtractionKindCorpus.all {
            let r = KindMeasure.run(c)
            let predicted = r.kind == .invoice && r.kindCertain
            if predicted && c.kind == .invoice { tp += 1 } else if predicted { fp += 1; print("D8 Rechnung FALSCH-POSITIV \(c.name)") } else if c.kind == .invoice { fn += 1; print("D8 Rechnung FALSCH-NEGATIV \(c.name)") }
        }
        XCTAssertEqual(fp, 0)
        XCTAssertEqual(fn, 0)
        XCTAssertGreaterThan(tp, 25)
    }

    // MARK: AK-D8-7 Determinismus, Erklärbarkeit

    func testAKD8_deterministicAndExplainableForEveryCase() {
        for c in ExtractionKindCorpus.all {
            let first = KindMeasure.run(c)
            for _ in 0..<5 { XCTAssertEqual(KindMeasure.run(c), first, c.name) }
            XCTAssertFalse(first.reasons.isEmpty, c.name)
            let ns = c.text as NSString
            for f in first.facts {
                XCTAssertFalse(f.reason.isEmpty, "\(c.name).\(f.type)")
                XCTAssertGreaterThan(f.confidence, 0, "\(c.name).\(f.type)")
                XCTAssertLessThanOrEqual(f.confidence, 1, "\(c.name).\(f.type)")
                if let s = f.source {
                    XCTAssertGreaterThanOrEqual(s.offset, 0, "\(c.name).\(f.type)")
                    XCTAssertLessThanOrEqual(s.offset + s.length, ns.length, "\(c.name).\(f.type)")
                    XCTAssertFalse(s.excerpt.isEmpty, "\(c.name).\(f.type)")
                }
            }
            // Beträge sind Dezimalzeichenketten mit zwei Nachkommastellen (nie Gleitkomma)
            for f in first.facts where ["amount", "premium", "recurring_amount", "settlement_amount", "balance_opening", "balance_closing", "amount_tax_7", "amount_tax_19"].contains(f.type) {
                XCTAssertNotNil(f.value.range(of: "^-?[0-9]+\\.[0-9]{2}$", options: .regularExpression), "\(c.name).\(f.type)=\(f.value)")
            }
        }
    }

    func testAKD8_explainableWithFundstelleOnLabeledFacts() {
        let c = ExtractionKindCorpus.contracts[0]
        let r = KindMeasure.run(c)
        let notice = KindMeasure.best(r, "notice_period")!
        let src = notice.source!
        XCTAssertTrue((c.text as NSString).substring(with: NSRange(location: src.offset, length: src.length)).contains("3 Monate"))
        XCTAssertTrue(notice.reason.contains("P3M"))
        XCTAssertTrue(r.reasons.contains { $0.contains("Vertrag") })
    }

    // MARK: AK-D8-6 Konflikte

    func testAKD8_conflictsDoNotOverrideEachOther() {
        for c in ExtractionKindCorpus.conflicts {
            let r = KindMeasure.run(c)
            XCTAssertEqual(r.kind, c.kind, "\(c.name): \(r.scores.prefix(3).map { "\($0.kind.rawValue)=\($0.score)" })")
            XCTAssertTrue(r.kindCertain, c.name)
            for (t, v) in c.facts { XCTAssertEqual(KindMeasure.best(r, t)?.value, v, "\(c.name).\(t)") }
        }
        // Reihenfolge der Eingabe ist egal: Detektoren sind unabhängig, nur die Konfliktregeln wirken
        let reminderText = "Mahnung\nVertragsnummer: V-1\nLaufzeit 24 Monate, Kündigungsfrist 3 Monate\nRechnungsnummer: R-9\nMahngebühr 5,00 €\nGesamtbetrag 100,00 €"
        let r = DocumentExtractor.extract(ExtractionInput(text: reminderText))
        XCTAssertEqual(r.kind, .reminder)
        XCTAssertLessThanOrEqual(r.scores.first { $0.kind == .invoice }!.score, 0.3)
    }

    func testAKD8_authorityReminderStaysAuthorityAndPlainReminderStaysReminder() {
        let fa = ExtractionKindCorpus.authorities.first { $0.name == "tax-mahnung-finanzamt" }!
        XCTAssertEqual(KindMeasure.run(fa).kind, .taxNotice)
        XCTAssertLessThanOrEqual(KindMeasure.run(fa).scores.first { $0.kind == .reminder }!.score, 0.5)
        let plain = ExtractionKindCorpus.contracts.first { $0.name == "contract-neg-mahnung-mit-vertragsnummer" }!
        XCTAssertEqual(KindMeasure.run(plain).kind, .reminder)
    }

    // MARK: Parser und Validierung

    func testAKD8_durationsAndDateMath() {
        func d(_ s: String) -> [String] { ExtractionParsers.durations(s as NSString).map(\.iso) }
        XCTAssertEqual(d("Kündigungsfrist 3 Monate"), ["P3M"])
        XCTAssertEqual(d("drei Monaten zum Quartalsende"), ["P3M"])
        XCTAssertEqual(d("eines Monats"), ["P1M"])
        XCTAssertEqual(d("innerhalb von 4 Wochen"), ["P4W"])
        XCTAssertEqual(d("14 Tage"), ["P14D"])
        XCTAssertEqual(d("zwei Jahre"), ["P2Y"])
        XCTAssertEqual(d("30 days"), ["P30D"])
        XCTAssertEqual(d("12 months"), ["P12M"])
        XCTAssertEqual(d("0 Monate"), [])
        XCTAssertEqual(d("Tagesauszug und Monatsende"), [])
        XCTAssertEqual(ExtractionParsers.addDuration("2026-11-30", "P3M"), "2027-02-28")
        XCTAssertEqual(ExtractionParsers.addDuration("2026-11-08", "P1M"), "2026-12-08")
        XCTAssertEqual(ExtractionParsers.addDuration("2026-11-08", "P2W"), "2026-11-22")
        XCTAssertEqual(ExtractionParsers.addDuration("2026-11-08", "P1Y"), "2027-11-08")
        XCTAssertNil(ExtractionParsers.addDuration("2026-11-08", "3M"))
    }

    func testAKD8_intervals() {
        func i(_ s: String) -> String? { ExtractionParsers.interval(in: s)?.value }
        XCTAssertEqual(i("monatlich 10,00"), "monthly")
        XCTAssertEqual(i("pro Monat"), "monthly")
        XCTAssertEqual(i("per month"), "monthly")
        XCTAssertEqual(i("vierteljährlich"), "quarterly")
        XCTAssertEqual(i("halbjährlich"), "semiannual")
        XCTAssertEqual(i("jährlich"), "yearly")
        XCTAssertEqual(i("Jahresbeitrag"), "yearly")
        XCTAssertEqual(i("annual premium"), "yearly")
        XCTAssertNil(i("einmalig 10,00"))
        XCTAssertNil(i("pro Stunde"))
    }

    func testAKD8_taxIDAndTaxNumberValidation() {
        XCTAssertTrue(ExtractionParsers.isValidTaxID(ExtractionKindCorpus.taxIDValid))
        XCTAssertTrue(ExtractionParsers.isValidTaxID("945 8073 0215".replacingOccurrences(of: " ", with: "")))
        XCTAssertFalse(ExtractionParsers.isValidTaxID(ExtractionKindCorpus.taxIDInvalid), "falsche Prüfziffer")
        XCTAssertFalse(ExtractionParsers.isValidTaxID("04580730215"), "beginnt mit 0")
        XCTAssertFalse(ExtractionParsers.isValidTaxID("1234567890"), "zu kurz")
        XCTAssertFalse(ExtractionParsers.isValidTaxID("12345678901"), "alle Ziffern verschieden")
        XCTAssertEqual(ExtractionParsers.normalizedTaxNumber("123/456/78901"), "123/456/78901")
        XCTAssertEqual(ExtractionParsers.normalizedTaxNumber("12/345/67890"), "12/345/67890")
        XCTAssertEqual(ExtractionParsers.normalizedTaxNumber("2893081508152"), "2893081508152")
        XCTAssertNil(ExtractionParsers.normalizedTaxNumber("12/34"))
        XCTAssertNil(ExtractionParsers.normalizedTaxNumber("abc"))
        // ungültige Steuer-ID im Text: kein Fakt
        let bad = DocumentExtractor.extract(ExtractionInput(text: "Finanzamt Musterstadt\nEinkommensteuerbescheid 2025\nSteuer-ID: \(ExtractionKindCorpus.taxIDInvalid)\nAktenzeichen: 99/123/456"))
        XCTAssertNil(KindMeasure.best(bad, "tax_id"))
        let ok = DocumentExtractor.extract(ExtractionInput(text: "Finanzamt Musterstadt\nEinkommensteuerbescheid 2025\nSteuer-ID: 945 8073 0215\nAktenzeichen: 99/123/456"))
        XCTAssertEqual(KindMeasure.best(ok, "tax_id")?.value, ExtractionKindCorpus.taxIDValid)
    }

    func testAKD8_signedAmountsAndIBANInStatements() {
        func s(_ text: String) -> (String, Bool) {
            let ns = text as NSString
            let hit = ExtractionParsers.amounts(ns, range: NSRange(location: 0, length: ns.length)).first { $0.explicitDecimals }!
            return ExtractionParsers.signed(hit, in: ns)
        }
        XCTAssertEqual(s("Saldo -120,00 €").0, "-120.00")
        XCTAssertEqual(s("Saldo 120,00 EUR S").0, "-120.00")
        XCTAssertEqual(s("Saldo 120,00 EUR H").0, "120.00")
        XCTAssertEqual(s("Saldo 120,00-").0, "-120.00")
        XCTAssertEqual(s("Saldo 0,00 S").0, "0.00")
        XCTAssertEqual(s("Haben 120,00 €").0, "120.00")
        XCTAssertEqual(s("Rechnung 4711-119,00").0, "119.00", "Bindestrich zwischen Wörtern/Ziffern ist kein Vorzeichen")
        // ungültige IBAN im Kontoauszug zählt nicht
        let r = DocumentExtractor.extract(ExtractionInput(text: "Kontoauszug\nIBAN DE89 3704 0044 0532 0130 01\nAlter Kontostand 10,00 €\nNeuer Kontostand 20,00 €"))
        XCTAssertNil(KindMeasure.best(r, "iban"))
    }

    func testAKD8_receiptTaxSharesAndPayment() {
        let t = ReceiptDetector.taxShares("A 19,00% 0,80   B 7,00% 0,18" as NSString)
        XCTAssertEqual(t.map(\.rate).sorted(), [7, 19])
        XCTAssertEqual(t.first { $0.rate == 19 }?.value, "0.80")
        XCTAssertEqual(t.first { $0.rate == 7 }?.value, "0.18")
        let n = ReceiptDetector.taxShares("MwSt 7 %: Netto 3,00 MwSt 0,21 Brutto 3,21" as NSString)
        XCTAssertEqual(n.first?.value, "0.21", "Steueranteil, nicht Netto")
        XCTAssertTrue(ReceiptDetector.taxShares("MwSt 7 %" as NSString).isEmpty, "ohne Betrag kein Fakt")
        XCTAssertEqual(ReceiptDetector.paymentMethod("Zahlart: Mastercard" as NSString)?.value, "credit_card")
        XCTAssertEqual(ReceiptDetector.paymentMethod("Bezahlt mit PayPal" as NSString)?.value, "paypal")
        XCTAssertNil(ReceiptDetector.paymentMethod("Café Bar Muster" as NSString), "„Bar“ im Namen ist keine Barzahlung")
    }

    func testAKD8_kindsAreExtensibleWithoutSchemaChange() {
        // neue Faktentypen sind reine Zeichenketten: jeder Typ ist in der erweiterbaren Liste und im Vertrag eingetragen
        let types = Set(FactType.allCases.map(\.rawValue))
        for t in ["counterparty", "contract_number", "period_start", "period_end", "term", "notice_period", "auto_renewal", "recurring_amount", "payment_interval", "policy_number", "premium",
                  "notice_type", "tax_number", "tax_id", "objection_deadline", "settlement_amount", "balance_opening", "balance_closing", "amount_tax_7", "amount_tax_19", "payment_method", "insurer", "authority"] {
            XCTAssertTrue(types.contains(t), t)
        }
        XCTAssertEqual(ExtractionResult.version, 2)
        XCTAssertEqual(Facts.order("authority"), FactType.allCases.firstIndex(of: .authority))
    }

    func testAKD8_hugeAndHostileInputsStayBounded() {
        let start = Date()
        let big = String(repeating: "Vertragsnummer: A1234 Laufzeit 24 Monate Kündigungsfrist 3 Monate Beitrag 10,00 € monatlich Aktenzeichen: Z99 Saldo 1,00 € ", count: 6_000)
        let r = DocumentExtractor.extract(ExtractionInput(text: big))
        XCTAssertNotNil(r.kind)
        let deep = String(repeating: "a ", count: 5_000) + " Vertrag " + String(repeating: "1.", count: 5_000)
        _ = DocumentExtractor.extract(ExtractionInput(text: deep))
        _ = DocumentExtractor.extract(ExtractionInput(text: String(repeating: "\n", count: 100_000)))
        XCTAssertLessThan(Date().timeIntervalSince(start), 60)
    }
}
