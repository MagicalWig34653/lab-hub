import Foundation

// WP-R2: Rechenkern des Rechnungsmoduls (MODUL-RECHNUNG.md Abschnitt 3, F-27: Neuimplementierung gegen die gemeinsamen Testvektoren
// `Tests/Fixtures/taxlab-vectors/`, kein Eingriff ins taxlab-Repo). Rein und deterministisch: keine Datenbank, keine Uhr, kein Gleitkomma.
// Gerundet wird nur auf Belegebene je Steuersatz (nie je Position); Summen netto/Steuer/brutto sind die Summen der gerundeten Steuersatz-Summen.

/// Rundungsregel eines Belegs (Modus und Nachkommastellen). Standard: kaufmännisch auf Cent.
struct InvoiceRounding: Sendable, Equatable {
    enum Mode: String, Sendable, Equatable, CaseIterable { case halfAwayFromZero, halfEven, towardZero }

    var mode: Mode
    var scale: Int

    static let `default` = InvoiceRounding(mode: .halfAwayFromZero, scale: 2)

    func apply(_ value: Decimal) -> Decimal {
        var input = value, result = Decimal()
        let foundationMode: NSDecimalNumber.RoundingMode
        switch mode {
        case .halfAwayFromZero: foundationMode = .plain
        case .halfEven: foundationMode = .bankers
        case .towardZero: foundationMode = value < 0 ? .up : .down
        }
        NSDecimalRound(&result, &input, scale, foundationMode)
        return result
    }
}

enum InvoiceDecimal {
    /// Strenger Dezimal-String: optionales Minus, Ziffern, optional Punkt und Nachkommastellen. Kein Exponent, kein Komma, keine Leerzeichen, kein `NaN`.
    static func parse(_ s: String) -> Decimal? {
        guard s.range(of: "^-?[0-9]+(\\.[0-9]+)?$", options: .regularExpression) != nil else { return nil }
        return Decimal(string: s, locale: Locale(identifier: "en_US_POSIX"))
    }

    /// Kanonische Ausgabe mit genau `scale` Nachkommastellen (ohne Gruppierung, Punkt als Trenner). Der Wert wird dafür vorher auf `scale` Stellen gerundet.
    static func string(_ value: Decimal, scale: Int) -> String {
        var input = value, rounded = Decimal()
        NSDecimalRound(&rounded, &input, scale, .plain)
        let plain = NSDecimalNumber(decimal: rounded).stringValue
        guard scale > 0 else { return plain }
        let parts = plain.split(separator: ".", omittingEmptySubsequences: false)
        let fraction = parts.count > 1 ? String(parts[1]) : ""
        return String(parts[0]) + "." + fraction + String(repeating: "0", count: max(0, scale - fraction.count))
    }
}

enum InvoiceCalculator {
    enum PriceMode: String, Sendable, Equatable { case net, gross }

    enum Discount: Sendable, Equatable {
        case percent(Decimal)
        case amount(Decimal)
    }

    /// Position: Preis und Werte stehen im Eingabemodus des Belegs (netto oder brutto), ungerundet.
    struct Line: Sendable, Equatable {
        var taxRate: Decimal
        var unitPrice: Decimal
        var quantity: Decimal
        var secondQuantity: Decimal?
        var discount: Discount?

        var valueBeforeDiscount: Decimal { unitPrice * quantity * (secondQuantity ?? 1) }
        var discountValue: Decimal {
            switch discount {
            case nil: 0
            case .percent(let p)?: valueBeforeDiscount * p / 100
            case .amount(let a)?: a
            }
        }
        /// Positionswert nach Positionsrabatt, ungerundet.
        var value: Decimal { valueBeforeDiscount - discountValue }
    }

    /// Zusatzkosten (Versand): im Eingabemodus, werden nicht rabattiert.
    struct Charge: Sendable, Equatable {
        var taxRate: Decimal
        var amount: Decimal
    }

    struct Input: Sendable, Equatable {
        var priceMode: PriceMode
        var lines: [Line]
        var charges: [Charge] = []
        var documentDiscountPercent: Decimal = 0
        /// Fester Belegrabatt im Eingabemodus; hat Vorrang vor dem Prozentwert.
        var documentDiscountAmount: Decimal?
        var rounding: InvoiceRounding = .default
    }

    struct RateTotal: Sendable, Equatable {
        let rate: Decimal
        let net: Decimal
        let tax: Decimal
        let gross: Decimal
    }

    struct Result: Sendable, Equatable {
        let byRate: [RateTotal]
        let documentDiscount: Decimal
        var net: Decimal { byRate.reduce(0) { $0 + $1.net } }
        var tax: Decimal { byRate.reduce(0) { $0 + $1.tax } }
        var gross: Decimal { byRate.reduce(0) { $0 + $1.gross } }
    }

    static func calculate(_ input: Input) -> Result {
        let rule = input.rounding
        let base = input.lines.reduce(Decimal(0)) { $0 + $1.value }
        let discount = input.documentDiscountAmount ?? (base * input.documentDiscountPercent / 100)
        let factor: Decimal = base == 0 ? 1 : 1 - discount / base
        var lineSums: [Decimal: Decimal] = [:], chargeSums: [Decimal: Decimal] = [:]
        for line in input.lines { lineSums[line.taxRate, default: 0] += line.value }
        for charge in input.charges { chargeSums[charge.taxRate, default: 0] += charge.amount }
        let rates = Set(lineSums.keys).union(chargeSums.keys).sorted()
        let byRate = rates.map { rate -> RateTotal in
            let entered = (lineSums[rate] ?? 0) * factor + (chargeSums[rate] ?? 0)
            switch input.priceMode {
            case .net:
                let net = rule.apply(entered)
                let tax = rule.apply(net * rate / 100)
                return RateTotal(rate: rate, net: net, tax: tax, gross: net + tax)
            case .gross:
                let gross = rule.apply(entered)
                let net = rule.apply(gross / (1 + rate / 100))
                return RateTotal(rate: rate, net: net, tax: gross - net, gross: gross)
            }
        }
        return Result(byRate: byRate, documentDiscount: rule.apply(discount))
    }
}
