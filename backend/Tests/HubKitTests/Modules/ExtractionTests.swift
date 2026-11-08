import XCTest
import Foundation
@testable import HubKit

// WP-D7: reine Tests des Extraktors (ohne Datenbank) gegen den synthetischen Korpus.
// Schwellen (im Handoff dokumentiert): Precision der Rechnungserkennung = 1,0 (keine Falsch-Positive bei den Negativfällen), Recall >= 0,95,
// Art-Genauigkeit über alle Fälle >= 0,95, Feld-Genauigkeit (Betrag, Datum, Fälligkeit, Nummer, IBAN, USt-ID) >= 0,95 über alle gesetzten Soll-Werte.

final class ExtractionTests: XCTestCase {
    func run(_ c: CorpusCase) -> ExtractionResult {
        DocumentExtractor.extract(ExtractionInput(text: c.text, subject: c.subject, sender: c.sender))
    }

    func value(_ r: ExtractionResult, _ t: FactType) -> String? {
        r.facts(t).sorted { ($0.confidence, -($0.source?.offset ?? 0)) > ($1.confidence, -($1.source?.offset ?? 0)) }.first?.value
    }

    func testCorpusSize() {
        XCTAssertGreaterThanOrEqual(ExtractionCorpus.all.count, 40)
        XCTAssertGreaterThanOrEqual(ExtractionCorpus.invoices.count, 20)
    }

    /// AK-D7-4 / AK-D7-11: Precision und Recall der Rechnungserkennung, Art-Genauigkeit.
    func testAKD7_11_invoiceDetectionPrecisionRecallAndKindAccuracy() {
        var tp = 0, fp = 0, fn = 0, kindOK = 0
        var failures: [String] = []
        for c in ExtractionCorpus.all {
            let r = run(c)
            let predicted = r.kind == .invoice && r.kindCertain
            if predicted && c.isInvoice { tp += 1 } else if predicted { fp += 1; failures.append("FALSCH-POSITIV \(c.name): \(r.kind) \(r.kindScore)") }
            else if c.isInvoice { fn += 1; failures.append("FALSCH-NEGATIV \(c.name): \(r.kind) \(r.kindScore) \(r.reasons)") }
            if r.kind == c.kind { kindOK += 1 } else { failures.append("ART \(c.name): erwartet \(c.kind) war \(r.kind) \(r.kindScore) \(r.scores.prefix(3).map { "\($0.kind.rawValue)=\($0.score)" })") }
        }
        let precision = Double(tp) / Double(max(1, tp + fp)), recall = Double(tp) / Double(max(1, tp + fn))
        let accuracy = Double(kindOK) / Double(ExtractionCorpus.all.count)
        print("D7 corpus: n=\(ExtractionCorpus.all.count) precision=\(precision) recall=\(recall) kindAccuracy=\(accuracy) tp=\(tp) fp=\(fp) fn=\(fn)")
        for f in failures { print("D7 \(f)") }
        XCTAssertEqual(fp, 0, "keine Falsch-Positive: \(failures)")
        XCTAssertEqual(precision, 1.0)
        XCTAssertGreaterThanOrEqual(recall, 0.95, "\(failures)")
        XCTAssertGreaterThanOrEqual(accuracy, 0.95, "\(failures)")
    }

    /// AK-D7-5: Felder exakt (Beträge als Dezimalzeichenkette).
    func testAKD7_5_fieldAccuracyAndExactDecimals() {
        var total = 0, ok = 0
        var failures: [String] = []
        func check(_ name: String, _ label: String, _ expected: String?, _ actual: String?) {
            guard let expected else { return }
            total += 1
            if expected == actual { ok += 1 } else { failures.append("\(name).\(label): erwartet \(expected) war \(actual ?? "nil")") }
        }
        for c in ExtractionCorpus.all {
            let r = run(c)
            let isInv = r.kind == .invoice
            check(c.name, "number", c.number, value(r, .invoiceNumber))
            check(c.name, "gross", c.gross, value(r, isInv ? .amountGross : .amount))
            check(c.name, "net", c.net, value(r, .amountNet))
            check(c.name, "tax", c.tax, value(r, .amountTax))
            check(c.name, "date", c.date, value(r, .date))
            check(c.name, "due", c.due, value(r, .dueDate))
            check(c.name, "iban", c.iban, value(r, .iban))
            check(c.name, "vat", c.vat, value(r, .vatID))
            check(c.name, "seller", c.seller, value(r, .seller))
            if let currency = c.currency, let gross = r.first(isInv ? .amountGross : .amount) { check(c.name, "currency", currency, gross.currency) }
            else if c.currency != nil { total += 1; failures.append("\(c.name).currency: kein Betrag") }
        }
        let accuracy = Double(ok) / Double(total)
        print("D7 fields: \(ok)/\(total) = \(accuracy)")
        for f in failures { print("D7 \(f)") }
        XCTAssertGreaterThanOrEqual(accuracy, 0.95, "\(failures)")
        XCTAssertGreaterThan(total, 100)
    }

    /// AK-D7-5: Zahlenformate.
    func testAKD7_5_amountFormats() {
        let p = ExtractionParsers.parseAmount
        XCTAssertEqual(p("1.234,56"), "1234.56")
        XCTAssertEqual(p("1,234.56"), "1234.56")
        XCTAssertEqual(p("1234.56"), "1234.56")
        XCTAssertEqual(p("1234,5"), "1234.50")
        XCTAssertEqual(p("1'234.50"), "1234.50")
        XCTAssertEqual(p("1.234.567,89"), "1234567.89")
        XCTAssertEqual(p("0,99"), "0.99")
        XCTAssertEqual(p("119"), "119.00")
        XCTAssertEqual(p("1.234"), "1234.00")
        XCTAssertNil(p("08.11.2026"))
        XCTAssertNil(p("1.2345"))
        XCTAssertNil(p("12,3456"))
        // keine Gleitkommafehler: 0,1 + 0,2 bleibt 0.30 als Dezimalrechnung
        XCTAssertEqual(ExtractionParsers.decimal("0.10")! + ExtractionParsers.decimal("0.20")!, ExtractionParsers.decimal("0.30")!)
        let ns = "Gesamt 1.234,56 € und EUR 1,234.56 sowie 19 %" as NSString
        let hits = ExtractionParsers.amounts(ns, range: NSRange(location: 0, length: ns.length))
        XCTAssertEqual(hits.map(\.value), ["1234.56", "1234.56"])
        XCTAssertEqual(hits.map(\.currency), ["EUR", "EUR"])
    }

    func testIBANChecksumAndVATFormat() {
        for iban in [ExtractionCorpus.ibanDE, ExtractionCorpus.ibanAT, ExtractionCorpus.ibanNL, ExtractionCorpus.ibanGB, ExtractionCorpus.ibanFR, ExtractionCorpus.ibanCH] {
            XCTAssertTrue(ExtractionParsers.isValidIBAN(iban), iban)
        }
        XCTAssertFalse(ExtractionParsers.isValidIBAN("DE89370400440532013001"))
        XCTAssertFalse(ExtractionParsers.isValidIBAN("DE00 1234"))
        let ns = "Konto DE89 3704 0044 0532 0130 01 und DE89 3704 0044 0532 0130 00 BIC COBADEFF" as NSString
        XCTAssertEqual(ExtractionParsers.ibans(ns).map(\.value), ["DE89370400440532013000"], "nur die Nummer mit gültiger Prüfsumme; angehängtes BIC wird abgeschnitten")
        XCTAssertTrue(ExtractionParsers.isValidVATFormat("DE123456789"))
        XCTAssertTrue(ExtractionParsers.isValidVATFormat("ATU12345678"))
        XCTAssertFalse(ExtractionParsers.isValidVATFormat("DE12345"))
    }

    func testDates() {
        func d(_ s: String) -> [String] { ExtractionParsers.dates(s as NSString).map(\.value) }
        XCTAssertEqual(d("08.11.2026"), ["2026-11-08"])
        XCTAssertEqual(d("8.11.26"), ["2026-11-08"])
        XCTAssertEqual(d("2026-11-08"), ["2026-11-08"])
        XCTAssertEqual(d("8. November 2026"), ["2026-11-08"])
        XCTAssertEqual(d("November 8, 2026"), ["2026-11-08"])
        XCTAssertEqual(d("8 Nov 2026"), ["2026-11-08"])
        XCTAssertEqual(d("20/11/2026"), ["2026-11-20"])
        XCTAssertEqual(d("11/20/2026"), ["2026-11-20"])
        XCTAssertEqual(d("05/06/2026"), [], "mehrdeutig: nichts raten")
        XCTAssertEqual(d("31.02.2026"), [])
        XCTAssertEqual(ExtractionParsers.addDays("2026-11-01", 14), "2026-11-15")
        XCTAssertEqual(ExtractionParsers.addDays("2026-12-25", 10), "2027-01-04")
    }

    /// AK-D7-12: gleicher Text = gleiches Ergebnis (100 Wiederholungen), Fundstellen und Begründungen vorhanden.
    func testAKD7_12_deterministicAndExplainable() {
        let c = ExtractionCorpus.invoices[0]
        let first = run(c)
        for _ in 0..<100 { XCTAssertEqual(run(c), first) }
        XCTAssertTrue(first.kindCertain)
        XCTAssertFalse(first.reasons.isEmpty)
        for f in first.facts {
            XCTAssertFalse(f.reason.isEmpty, f.type)
            XCTAssertGreaterThan(f.confidence, 0)
            if let s = f.source {   // Fundstelle zeigt wirklich auf die Stelle im Text
                let ns = c.text as NSString
                XCTAssertLessThanOrEqual(s.offset + s.length, ns.length)
                XCTAssertFalse(s.excerpt.isEmpty)
            }
        }
        let gross = first.first(.amountGross)!
        XCTAssertEqual(gross.value, "178.50")
        XCTAssertTrue((c.text as NSString).substring(with: NSRange(location: gross.source!.offset, length: gross.source!.length)).contains("178,50"))
    }

    /// Neue Dokumentart nur durch Detektor: Reihenfolge, Mahnung deckelt Rechnung.
    func testReminderBeatsInvoiceAndOtherFallback() {
        let r = DocumentExtractor.extract(ExtractionInput(text: "Mahnung\nRechnungsnummer: R-1\nRechnungsdatum: 01.11.2026\nMahngebühr 5,00 €\nGesamtbetrag 100,00 €"))
        XCTAssertEqual(r.kind, .reminder)
        XCTAssertLessThanOrEqual(r.scores.first { $0.kind == .invoice }!.score, 0.3)
        let o = DocumentExtractor.extract(ExtractionInput(text: "Hallo Welt"))
        XCTAssertEqual(o.kind, .other)
        XCTAssertTrue(o.facts.isEmpty)
        XCTAssertEqual(DocumentExtractor.extract(ExtractionInput(text: "")).kind, .other)
    }

    func testHugeInputIsBounded() {
        let big = String(repeating: "Rechnungsnummer: A1234 Gesamtbetrag 10,00 € ", count: 20_000)
        let start = Date()
        let r = DocumentExtractor.extract(ExtractionInput(text: big))
        XCTAssertLessThan(Date().timeIntervalSince(start), 20)
        XCTAssertEqual(r.kind, .invoice)
    }
}
