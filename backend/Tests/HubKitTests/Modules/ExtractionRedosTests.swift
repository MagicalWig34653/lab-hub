import XCTest
import Foundation
@testable import HubKit

// WP-H10 Befund 1: ReDoS im Extraktor. Hostile Eingaben (Etikett + sehr lange Whitespace-Läufe) dürfen den Worker nicht blockieren.
// Nur synthetische Texte. Jede Messung muss unter 2 Sekunden bleiben (vor der Behebung dauerte ein einzelnes Etikett Minuten).

final class ExtractionRedosTests: XCTestCase {
    /// Etiketten je Detektor (Rechnung, Mahnung-Bezug, Vertrag, Versicherung, Behörde/Steuer, Kontoauszug, Kassenbon).
    static let labels: [(String, String)] = [
        ("invoice", "Rechnungsnr"), ("invoice-en", "Invoice No"), ("invoice-due", "Fällig am"), ("invoice-gross", "Gesamtbetrag"),
        ("contract-number", "Vertragsnummer"), ("contract-between", "Zwischen"), ("contract-term", "Laufzeit"), ("contract-notice", "Kündigungsfrist"),
        ("insurance-number", "Versicherungsschein-Nr"), ("insurance-due", "Fälligkeit"), ("insurance-insurer", "Versicherer"),
        ("tax-number", "Steuernummer"), ("tax-id", "Steuer-ID"), ("authority-ref", "Aktenzeichen"), ("authority-due", "Zahlbar bis"),
        ("statement-period", "Zeitraum"), ("statement-balance", "Alter Kontostand"), ("receipt-number", "Bon-Nr"), ("receipt-pay", "Zahlart")
    ]
    static let fillers: [(String, String)] = [("spaces", " "), ("tabs", "\t"), ("newlines", "\n"), ("mixed", " \t\n"), ("crlf", "\r\n"), ("nbsp", "\u{00A0}")]

    private func timed(_ text: String, subject: String? = nil) -> (ExtractionResult, TimeInterval) {
        let t0 = Date()
        let r = DocumentExtractor.extract(ExtractionInput(text: text, subject: subject))
        return (r, Date().timeIntervalSince(t0))
    }

    /// AK-H10-1: je Etikett und Füllzeichen mit 190 000 Zeichen Whitespace hinter dem Etikett.
    func testAKH10_1_labelFollowedByHugeWhitespaceStaysFast() {
        for (name, label) in Self.labels {
            for (fname, filler) in Self.fillers {
                let text = "Kopf\n" + label + String(repeating: filler, count: 190_000) + "X1\nEnde"
                let (_, secs) = timed(text)
                XCTAssertLessThan(secs, 2.0, "\(name)/\(fname): \(secs)s")
            }
        }
    }

    /// Whitespace vor, zwischen und innerhalb mehrerer Etiketten (jede Lücke einzeln lang).
    func testAKH10_1_manyLabelsWithHugeGapsStaysFast() {
        let gap = String(repeating: " ", count: 100_000)
        var text = ""
        for (_, label) in Self.labels { text += label + ":" + gap + "\n" }
        let (_, secs) = timed(text)
        XCTAssertLessThan(secs, 2.0, "\(secs)s")
        let (_, s2) = timed(Self.labels.map(\.1).joined(separator: gap))
        XCTAssertLessThan(s2, 2.0, "\(s2)s")
    }

    /// Gleiches Etikett sehr oft wiederholt (viele Startpunkte) und große Texte ohne Whitespace.
    func testAKH10_1_repeatedLabelsAndLongTokensStayFast() {
        let (_, a) = timed(String(repeating: "Rechnungsnr  ", count: 20_000))
        XCTAssertLessThan(a, 2.0, "\(a)s")
        let (_, b) = timed(String(repeating: "x", count: 190_000) + "\nRechnungsnr: RE-2026-001")
        XCTAssertLessThan(b, 2.0, "\(b)s")
        let (_, c) = timed(String(repeating: "Steuernummer \n", count: 12_000), subject: "Rechnung")
        XCTAssertLessThan(c, 2.0, "\(c)s")
    }

    /// Normalisierung: lange Läufe werden gekürzt, Zeilenstruktur und kurze Läufe bleiben unverändert.
    func testAKH10_1_whitespaceNormalizationKeepsStructure() {
        XCTAssertEqual(DocumentExtractor.normalize("a   b\n\nc\t\td"), "a   b\n\nc\t\td")
        XCTAssertEqual(DocumentExtractor.normalize("a" + String(repeating: " ", count: 1000) + "b"), "a   b")
        XCTAssertEqual(DocumentExtractor.normalize("a   \n\n\n\n\n\n   b"), "a\n\n   b")
        XCTAssertEqual(DocumentExtractor.normalize("Rechnungsnr" + String(repeating: "\t", count: 500) + "RE-1"), "Rechnungsnr   RE-1")
        XCTAssertEqual(DocumentExtractor.normalize(String(repeating: "\n", count: 500)), "\n\n")
    }

    /// Lange Läufe ohne Whitespace (Buchstaben, Ziffern, Satzzeichen, Bindestriche): keine quadratischen Muster, kein Fristablauf.
    func testAKH10_1_longTokensWithoutWhitespaceNeitherSlowNorTimeout() {
        let runs = ["x", "1", "a-", ",", ".", "€", "ä", "-", "/", ":", "\\", "steu", "ver", "AG", "0,0"]
        for unit in runs {
            let text = "Rechnung\n" + String(repeating: unit, count: 30_000 / unit.count)
            let (r, secs) = timed(text)
            XCTAssertLessThan(secs, 2.0, "\(unit): \(secs)s")
            XCTAssertFalse(r.timedOut, "\(unit) darf die Frist nicht erreichen")
        }
    }

    /// Frist: bei Ablauf `other`, unsicher, Grund `extraction_timeout`, keine Fakten; eine normale Eingabe bleibt davon unberührt.
    func testAKH10_1_deadlineProducesTimeoutResult() {
        let text = "Rechnung\nRechnungsnr: RE-2026-0042\nGesamtbetrag: 119,00 EUR\n"
        let r = DocumentExtractor.extract(ExtractionInput(text: text), timeout: 0)
        XCTAssertTrue(r.timedOut)
        XCTAssertEqual(r.kind, .other)
        XCTAssertFalse(r.kindCertain)
        XCTAssertEqual(r.reasons, ["extraction_timeout"])
        XCTAssertTrue(r.facts.isEmpty)
        let ok = DocumentExtractor.extract(ExtractionInput(text: text))
        XCTAssertFalse(ok.timedOut)
        XCTAssertEqual(ok.kind, .invoice)
        // die Frist gilt je Aufruf und läuft nicht in den nächsten hinein
        XCTAssertNil(ExtractionDeadline.current)
    }

    /// Fachlich unverändert: ein Etikett mit Wert trotz langer Lücke wird noch gefunden (Lücke wird gekappt, nicht der Wert).
    func testAKH10_1_valueAfterLongGapStillExtracted() {
        let text = "Rechnung\nRechnungsnr:" + String(repeating: " ", count: 5000) + "RE-2026-0042\nGesamtbetrag: 119,00 EUR\n"
        let (r, secs) = timed(text)
        XCTAssertLessThan(secs, 2.0)
        XCTAssertEqual(r.first(.invoiceNumber)?.value, "RE-2026-0042")
    }
}
