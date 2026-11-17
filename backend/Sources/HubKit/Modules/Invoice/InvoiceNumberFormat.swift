import Foundation
import SQLKit

// WP-R1: Nummernformat der Serien (Syntax wie im Rechenkern der App, F-27: Neuimplementierung gegen die gemeinsamen Testvektoren
// `Tests/Fixtures/taxlab-vectors/number-format.json`). Reine Funktionen ohne Zustand; Vergabe der Nummer selbst (Kernzähler) kommt mit WP-R2.
//
// Syntax: Literaltext mit Platzhaltern `{YYYY}`, `{YY}`, `{MM}`, `{N}`/`{N:<Stellen>}` (genau einmal), `{ABBR}`, `{CLIENT}`, `{PROJECT}`; `{{` und `}}` sind Klammern.

struct InvoiceNumberFormat: Sendable, Equatable {
    enum Scope: String, Sendable, Equatable { case continuous, perYear = "per_year", perMonth = "per_month" }

    /// Fehler wie in der Referenz; `vectorName` entspricht der Schreibweise der Testvektoren.
    enum Failure: Error, Equatable {
        case unknownToken(String), unbalancedBrace, counterCount(Int), invalidDigits(String), missingValue(String), invalidCounter

        var vectorName: String {
            switch self {
            case .unknownToken(let t): "unknownToken(\"\(t)\")"
            case .unbalancedBrace: "unbalancedBrace"
            case .counterCount(let n): "counterCount(\(n))"
            case .invalidDigits(let d): "invalidDigits(\"\(d)\")"
            case .missingValue(let v): "missingValue(\"\(v)\")"
            case .invalidCounter: "invalidCounter"
            }
        }
        /// Fehlercode für `errors[].code` der API (Feld `number_format`).
        var fieldCode: String {
            switch self {
            case .unknownToken: "unknown_token"
            case .unbalancedBrace: "unbalanced_brace"
            case .counterCount: "counter_count"
            case .invalidDigits: "invalid_digits"
            case .missingValue: "missing_value"
            case .invalidCounter: "invalid_counter"
            }
        }
    }

    enum Part: Sendable, Equatable {
        case literal(String), year4, year2, month, counter(digits: Int), abbreviation, client, project
    }

    static let maxDigits = 12   // Annahme (Taxlab-Grenze nicht dokumentiert): Zähler ist bigint, 12 Stellen reichen für jede Serie

    let parts: [Part]

    var scope: Scope {
        if parts.contains(.month) { return .perMonth }
        if parts.contains(.year4) || parts.contains(.year2) { return .perYear }
        return .continuous
    }

    /// Ob zum Formatieren Werte aus Kontakt/Projekt nötig sind (Vorschau ohne Kunde nicht möglich).
    var needsClientOrProject: Bool { parts.contains(.client) || parts.contains(.project) }

    static func parse(_ template: String) throws -> InvoiceNumberFormat {
        var parts: [Part] = []
        var literal = ""
        var counters = 0
        let chars = Array(template)
        var i = 0
        func flush() { if !literal.isEmpty { parts.append(.literal(literal)); literal = "" } }
        while i < chars.count {
            let c = chars[i]
            if c == "{" {
                if i + 1 < chars.count, chars[i + 1] == "{" { literal.append("{"); i += 2; continue }
                guard let close = chars[(i + 1)...].firstIndex(of: "}") else { throw Failure.unbalancedBrace }
                let token = String(chars[(i + 1)..<close])
                if token.contains("{") { throw Failure.unbalancedBrace }
                flush()
                switch token {
                case "YYYY": parts.append(.year4)
                case "YY": parts.append(.year2)
                case "MM": parts.append(.month)
                case "ABBR": parts.append(.abbreviation)
                case "CLIENT": parts.append(.client)
                case "PROJECT": parts.append(.project)
                case "N": parts.append(.counter(digits: 1)); counters += 1
                default:
                    if token.hasPrefix("N:") {
                        let d = String(token.dropFirst(2))
                        guard d.allSatisfy(\.isASCII), let n = Int(d), (1...maxDigits).contains(n) else { throw Failure.invalidDigits(d) }
                        parts.append(.counter(digits: n)); counters += 1
                    } else { throw Failure.unknownToken(token) }
                }
                i = close + 1
            } else if c == "}" {
                guard i + 1 < chars.count, chars[i + 1] == "}" else { throw Failure.unbalancedBrace }
                literal.append("}"); i += 2
            } else { literal.append(c); i += 1 }
        }
        flush()
        guard counters == 1 else { throw Failure.counterCount(counters) }
        return InvoiceNumberFormat(parts: parts)
    }

    func format(counter: Int64, year: Int, month: Int, abbreviation: String?, clientNumber: String?, projectCode: String?) throws -> String {
        guard counter >= 1 else { throw Failure.invalidCounter }
        var out = ""
        for part in parts {
            switch part {
            case .literal(let s): out += s
            case .year4: out += String(format: "%04d", year)
            case .year2: out += String(format: "%02d", year % 100)
            case .month: out += String(format: "%02d", month)
            case .counter(let digits):
                let s = String(counter)
                out += String(repeating: "0", count: max(0, digits - s.count)) + s
            case .abbreviation:
                guard let v = abbreviation, !v.isEmpty else { throw Failure.missingValue("ABBR") }
                out += v
            case .client:
                guard let v = clientNumber, !v.isEmpty else { throw Failure.missingValue("CLIENT") }
                out += v
            case .project:
                guard let v = projectCode, !v.isEmpty else { throw Failure.missingValue("PROJECT") }
                out += v
            }
        }
        return out
    }
}

/// Zählerschlüssel der Serien im Kern-Zähler (`CounterService`). Je Serie und Zeitraum ein eigener Schlüssel: fortlaufend `<serie>`, je Jahr `<serie>-<jjjj>`,
/// je Monat `<serie>-<jjjj>-<mm>`; `<serie>` ist die UUID in Kleinbuchstaben. WP-R2 vergibt Nummern über genau diese Schlüssel (Finalisieren in einer Transaktion).
enum InvoiceNumbering {
    static let space = "invoice"

    static func counterKey(series: UUID, scope: InvoiceNumberFormat.Scope, year: Int, month: Int) -> CounterKey {
        let id = series.uuidString.lowercased()
        switch scope {
        case .continuous: return CounterKey(space: space, name: id)
        case .perYear: return CounterKey(space: space, name: id + "-" + String(format: "%04d", year))
        case .perMonth: return CounterKey(space: space, name: id + "-" + String(format: "%04d-%02d", year, month))
        }
    }

    /// Aktueller Zeitraum nach Datenbankuhr (UTC; nie die Instanzuhr, ADR 0003). Annahme: Mandanten-Zeitzone gibt es noch nicht.
    static func currentPeriod(on db: any SQLDatabase) async throws -> (year: Int, month: Int) {
        guard let row = try await db.raw("SELECT extract(year FROM (now() AT TIME ZONE 'UTC'))::int AS y, extract(month FROM (now() AT TIME ZONE 'UTC'))::int AS m").first()
        else { throw HubError(.internalServerError, "internal_error") }
        return (try row.decode(column: "y", as: Int.self), try row.decode(column: "m", as: Int.self))
    }
}
