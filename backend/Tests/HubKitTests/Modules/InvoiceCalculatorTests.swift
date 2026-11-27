import XCTest
import Foundation
@testable import HubCore
@testable import HubKit
@testable import HubModuleDMS
@testable import HubModuleInvoice

/// WP-R2: Rechenkern des Rechnungsmoduls gegen die gemeinsamen Testvektoren (`Tests/Fixtures/invoice-vectors/`, F-27: Neuimplementierung).
/// Vergleich numerisch (die Referenz lässt Nachkomma-Nullen weg, `"291.9"`). Nur synthetische Daten.
final class InvoiceCalculatorTests: XCTestCase {

    private func vectors(_ file: String) throws -> [[String: Any]] {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/invoice-vectors/\(file)")
        let root = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        return root["vectors"] as! [[String: Any]]
    }

    private func dec(_ s: String) -> Decimal { Decimal(string: s, locale: Locale(identifier: "en_US_POSIX"))! }
    private func dec(_ v: Any?) -> Decimal? { (v as? String).map { dec($0) } }

    private func mode(_ s: String) -> InvoiceRounding.Mode {
        switch s {
        case "halfAwayFromZero": .halfAwayFromZero
        case "halfEven": .halfEven
        case "towardZero": .towardZero
        default: fatalError("unbekannter Modus \(s)")
        }
    }

    /// AK-R2-1: Rundung entspricht den 14 Vektoren (`rounding.json`), alle drei Modi, positive und negative Werte.
    func testAKR2_1_RoundingMatchesVectors() throws {
        let all = try vectors("rounding.json")
        XCTAssertEqual(all.count, 14)
        for v in all {
            let id = v["id"] as! String
            let rule = InvoiceRounding(mode: mode(v["mode"] as! String), scale: v["scale"] as! Int)
            XCTAssertEqual(rule.apply(dec(v["input"] as! String)), dec(v["expected"] as! String), id)
        }
    }

    /// AK-R2-2: Belegsummen entsprechen den 16 Vektoren (`document-totals.json`): Netto-/Brutto-Modus, Positions-/Belegrabatt, Zusatzkosten, Gutschrift, Rundungsmodi, leerer Beleg.
    func testAKR2_2_DocumentTotalsMatchVectors() throws {
        let all = try vectors("document-totals.json")
        XCTAssertEqual(all.count, 16)
        for v in all {
            let id = v["id"] as! String, input = v["input"] as! [String: Any], expected = v["expected"] as! [String: Any]
            let rounding = input["rounding"] as! [String: Any]
            let lines = (input["lines"] as! [[String: Any]]).map { l -> InvoiceCalculator.Line in
                var discount: InvoiceCalculator.Discount?
                if let d = l["discount"] as? [String: Any] {
                    discount = (d["kind"] as! String) == "percent" ? .percent(dec(d["value"] as! String)) : .amount(dec(d["value"] as! String))
                }
                return InvoiceCalculator.Line(taxRate: dec(l["taxRate"] as! String), unitPrice: dec(l["unitPrice"] as! String), quantity: dec(l["quantity"] as! String),
                                              secondQuantity: dec(l["secondQuantity"]), discount: discount)
            }
            let charges = (input["charges"] as! [[String: Any]]).map { InvoiceCalculator.Charge(taxRate: dec($0["taxRate"] as! String), amount: dec($0["amount"] as! String)) }
            let result = InvoiceCalculator.calculate(.init(
                priceMode: (input["priceMode"] as! String) == "net" ? .net : .gross, lines: lines, charges: charges,
                documentDiscountPercent: dec(input["documentDiscountPercent"] as! String), documentDiscountAmount: dec(input["documentDiscountAmount"]),
                rounding: InvoiceRounding(mode: mode(rounding["mode"] as! String), scale: rounding["scale"] as! Int)))
            let byRate = expected["byRate"] as! [[String: Any]]
            XCTAssertEqual(result.byRate.count, byRate.count, id)
            for (got, want) in zip(result.byRate, byRate) {
                XCTAssertEqual(got.rate, dec(want["rate"] as! String), "\(id) rate")
                XCTAssertEqual(got.net, dec(want["net"] as! String), "\(id) net \(got.rate)")
                XCTAssertEqual(got.tax, dec(want["tax"] as! String), "\(id) tax \(got.rate)")
                XCTAssertEqual(got.gross, dec(want["gross"] as! String), "\(id) gross \(got.rate)")
            }
            XCTAssertEqual(result.net, dec(expected["net"] as! String), "\(id) net")
            XCTAssertEqual(result.tax, dec(expected["tax"] as! String), "\(id) tax")
            XCTAssertEqual(result.gross, dec(expected["gross"] as! String), "\(id) gross")
            XCTAssertEqual(result.documentDiscount, dec(expected["documentDiscount"] as! String), "\(id) documentDiscount")
        }
    }

    /// AK-R2-3: Dezimal-Strings werden streng gelesen (kein Exponent, keine Gleitkommaschreibweise, nie gerundet) und Dezimalwerte als kanonische Strings ausgegeben.
    func testAKR2_3_DecimalParsingIsStrict() {
        XCTAssertEqual(InvoiceDecimal.parse("19"), Decimal(19))
        XCTAssertEqual(InvoiceDecimal.parse("-0.5"), Decimal(string: "-0.5"))
        XCTAssertNil(InvoiceDecimal.parse("1e3"))
        XCTAssertNil(InvoiceDecimal.parse("1,5"))
        XCTAssertNil(InvoiceDecimal.parse(" 1"))
        XCTAssertNil(InvoiceDecimal.parse(""))
        XCTAssertNil(InvoiceDecimal.parse("NaN"))
        XCTAssertEqual(InvoiceDecimal.string(Decimal(string: "291.9")!, scale: 2), "291.90")
        XCTAssertEqual(InvoiceDecimal.string(Decimal(80), scale: 2), "80.00")
        XCTAssertEqual(InvoiceDecimal.string(Decimal(string: "-2.68")!, scale: 2), "-2.68")
    }
}
