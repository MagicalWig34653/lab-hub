import Foundation

// WP-D7: Parser für Beträge (deutsch und englisch), Daten, IBAN (Prüfsumme) und USt-ID (Format). Alles reine Funktionen, keine Gleitkommazahlen:
// Beträge sind Zeichenketten mit genau zwei Nachkommastellen (`1234.56`), Vergleiche und Summen laufen über `Decimal`.

struct Rx: @unchecked Sendable {
    let re: NSRegularExpression
    init(_ pattern: String, caseInsensitive: Bool = true, multiline: Bool = false) {
        var o: NSRegularExpression.Options = []
        if caseInsensitive { o.insert(.caseInsensitive) }
        if multiline { o.insert(.anchorsMatchLines) }
        // feste, im Code stehende Muster: ein Fehler wäre ein Programmierfehler und fällt in jedem Test auf
        re = try! NSRegularExpression(pattern: pattern, options: o)
    }
    func all(_ ns: NSString, range: NSRange? = nil) -> [NSTextCheckingResult] {
        let r = range ?? NSRange(location: 0, length: ns.length)
        guard let state = ExtractionDeadline.current else { return re.matches(in: ns as String, options: [], range: r) }
        if state.isExpired { return [] }
        var out: [NSTextCheckingResult] = []
        re.enumerateMatches(in: ns as String, options: [.reportProgress], range: r) { result, flags, stop in
            if let result { out.append(result) } else if flags.contains(.progress), state.isExpired { stop.pointee = true }
        }
        return state.isExpired ? [] : out
    }
    func first(_ ns: NSString, range: NSRange? = nil) -> NSTextCheckingResult? {
        let r = range ?? NSRange(location: 0, length: ns.length)
        guard let state = ExtractionDeadline.current else { return re.firstMatch(in: ns as String, options: [], range: r) }
        if state.isExpired { return nil }
        var found: NSTextCheckingResult?
        re.enumerateMatches(in: ns as String, options: [.reportProgress], range: r) { result, flags, stop in
            if let result { found = result; stop.pointee = true } else if flags.contains(.progress), state.isExpired { stop.pointee = true }
        }
        return state.isExpired ? nil : found
    }
}

/// Harte Frist für die (synchrone) Extraktion, je Thread (Thread-Dictionary). Die ICU-Engine meldet in langen Läufen Fortschritt (`reportProgress`);
/// nach Fristablauf liefern `Rx.first`/`Rx.all` sofort leer und brechen laufende Läufe ab. Wanduhr, nur zur Begrenzung (das Ergebnis bei Ablauf ist fest).
final class ExtractionDeadline: @unchecked Sendable {
    private static let key = "labhub.extraction.deadline"
    private let end: Date
    private var expired = false
    private init(timeout: TimeInterval) { end = Date().addingTimeInterval(timeout) }

    static var current: ExtractionDeadline? { Thread.current.threadDictionary[key] as? ExtractionDeadline }

    var isExpired: Bool {
        if !expired, Date() >= end { expired = true }
        return expired
    }

    static func run<T>(timeout: TimeInterval, _ body: () -> T) -> (T, expired: Bool) {
        let state = ExtractionDeadline(timeout: timeout)
        let previous = Thread.current.threadDictionary[key]
        Thread.current.threadDictionary[key] = state
        defer { if let previous { Thread.current.threadDictionary[key] = previous } else { Thread.current.threadDictionary.removeObject(forKey: key) } }
        let value = body()
        return (value, state.isExpired)
    }
}

struct AmountHit: Sendable, Equatable {
    let value: String
    let currency: String?
    let range: NSRange
    /// Das Token hatte 1–2 Nachkommastellen (`119,00`); reine Ganzzahlen ohne Währung sind kein verlässlicher Betrag.
    let explicitDecimals: Bool
}

enum ExtractionParsers {
    // MARK: Beträge

    private static let tokenRx = Rx("(?<![\\d.,'])\\d+(?:[.,']\\d+)*(?![\\d])", caseInsensitive: false)
    private static let currencyAfter = Rx("^\\s{0,2}(EUR|€|Euro|USD|\\$|CHF|GBP|£)(?![A-Za-z])")
    private static let currencyBefore = Rx("(EUR|€|USD|\\$|CHF|GBP|£)\\s{0,2}$")
    private static let percentAfter = Rx("^\\s{0,2}(%|Prozent|percent)")

    static func canonicalCurrency(_ raw: String) -> String {
        switch raw.lowercased() {
        case "€", "eur", "euro": "EUR"
        case "$", "usd": "USD"
        case "£", "gbp": "GBP"
        default: raw.uppercased()
        }
    }

    /// `1.234,56`, `1,234.56`, `1234.56`, `1'234.56`, `119`, `1.234` (Tausender) -> `1234.56`; sonst nil. Mehr als zwei Nachkommastellen sind kein Geldbetrag.
    static func parseAmount(_ token: String) -> String? {
        let t = token.replacingOccurrences(of: "'", with: "")
        guard !t.isEmpty, t.first!.isNumber, t.last!.isNumber else { return nil }
        let seps = t.enumerated().filter { $0.element == "." || $0.element == "," }
        func clean(_ int: String, _ frac: String) -> String? {
            guard int.allSatisfy({ $0.isASCII && $0.isNumber }), frac.allSatisfy({ $0.isASCII && $0.isNumber }), int.count <= 13 else { return nil }
            var i = String(int.drop(while: { $0 == "0" })); if i.isEmpty { i = "0" }
            return i + "." + (frac + "00").prefix(2)
        }
        func groupsOK(_ s: String) -> Bool {
            let parts = s.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "." || $0 == "," })
            guard let head = parts.first, (1...3).contains(head.count), head.first != "0" || parts.count == 1 else { return false }
            return parts.dropFirst().allSatisfy { $0.count == 3 }
        }
        if seps.isEmpty { return clean(t, "") }
        let last = seps.last!
        let after = t.count - last.offset - 1
        let kinds = Set(seps.map(\.element))
        let head = String(t.prefix(last.offset))
        if kinds.count == 2 {
            guard (1...2).contains(after), groupsOK(head) else { return nil }
            return clean(head.filter { $0 != "." && $0 != "," }, String(t.suffix(after)))
        }
        if seps.count > 1 {
            guard after == 3, groupsOK(t) else { return nil }
            return clean(t.filter { $0 != "." && $0 != "," }, "")
        }
        if (1...2).contains(after) { return clean(head, String(t.suffix(after))) }
        if after == 3, (1...3).contains(head.count), head.first != "0" { return clean(head + t.suffix(3), "") }
        return nil
    }

    /// Alle Geldbetrags-Kandidaten im Bereich (Prozentangaben ausgenommen). Währung nur, wenn sie unmittelbar vor oder hinter der Zahl steht.
    static func amounts(_ ns: NSString, range: NSRange) -> [AmountHit] {
        var out: [AmountHit] = []
        for m in tokenRx.all(ns, range: range) {
            let token = ns.substring(with: m.range)
            guard let value = parseAmount(token) else { continue }
            let afterStart = m.range.location + m.range.length
            let lineEndAfter = min(ns.length, afterStart + 12)
            let after = ns.substring(with: NSRange(location: afterStart, length: lineEndAfter - afterStart)).split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
            let afterNS = after as NSString
            if percentAfter.first(afterNS) != nil { continue }
            let beforeStart = max(0, m.range.location - 6)
            let before = ns.substring(with: NSRange(location: beforeStart, length: m.range.location - beforeStart)).split(separator: "\n", omittingEmptySubsequences: false).last.map(String.init) ?? ""
            var currency: String?
            var end = m.range.location + m.range.length, start = m.range.location
            if let c = currencyAfter.first(afterNS) { currency = canonicalCurrency(afterNS.substring(with: c.range(at: 1))); end = afterStart + c.range.location + c.range.length }
            else if let c = currencyBefore.first(before as NSString) {
                currency = canonicalCurrency((before as NSString).substring(with: c.range(at: 1)))
                start = m.range.location - ((before as NSString).length - c.range.location)
            }
            out.append(AmountHit(value: value, currency: currency, range: NSRange(location: start, length: end - start),
                                 explicitDecimals: token.range(of: "[.,][0-9]{1,2}$", options: .regularExpression) != nil))
        }
        return out
    }

    static func decimal(_ s: String) -> Decimal? { Decimal(string: s, locale: Locale(identifier: "en_US_POSIX")) }

    // MARK: Daten

    static let monthNames: [String: Int] = [
        "januar": 1, "jan": 1, "january": 1, "februar": 2, "feb": 2, "february": 2, "märz": 3, "maerz": 3, "mär": 3, "mar": 3, "march": 3,
        "april": 4, "apr": 4, "mai": 5, "may": 5, "juni": 6, "jun": 6, "june": 6, "juli": 7, "jul": 7, "july": 7, "august": 8, "aug": 8,
        "september": 9, "sep": 9, "sept": 9, "oktober": 10, "okt": 10, "oct": 10, "october": 10, "november": 11, "nov": 11,
        "dezember": 12, "dez": 12, "dec": 12, "december": 12]
    static let monthAlt = "januar|january|februar|february|märz|maerz|march|april|mai|may|juni|june|juli|july|august|september|sept|oktober|october|november|dezember|december|jan|feb|mär|mar|apr|jun|jul|aug|sep|okt|oct|nov|dez|dec"
    private static let dmy = Rx("(?<![\\d.])(\\d{1,2})\\.\\s?(\\d{1,2})\\.\\s?(\\d{4}|\\d{2})(?![\\d])")
    private static let iso = Rx("(?<![\\d-])(\\d{4})-(\\d{2})-(\\d{2})(?![\\d-])")
    private static let dMonthY = Rx("(?<![\\d])(\\d{1,2})\\.?\\s{1,3}(\(monthAlt))\\.?,?\\s{1,3}(\\d{4})(?![\\d])")
    private static let monthDY = Rx("(?<![A-Za-zäöü])(\(monthAlt))\\.?\\s{1,3}(\\d{1,2})(?:st|nd|rd|th)?,?\\s{1,3}(\\d{4})(?![\\d])")
    private static let slash = Rx("(?<![\\d/])(\\d{1,2})/(\\d{1,2})/(\\d{4})(?![\\d/])")

    struct DateHit: Sendable, Equatable { let value: String; let range: NSRange }

    static func isValidDate(_ y: Int, _ m: Int, _ d: Int) -> Bool {
        guard (1990...2100).contains(y), (1...12).contains(m), d >= 1 else { return false }
        let days = [31, (y % 4 == 0 && (y % 100 != 0 || y % 400 == 0)) ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
        return d <= days[m - 1]
    }

    static func format(_ y: Int, _ m: Int, _ d: Int) -> String { String(format: "%04d-%02d-%02d", y, m, d) }

    /// Alle gültigen Kalendertage im Bereich, nach Fundstelle sortiert (überlappende Treffer nur einmal).
    static func dates(_ ns: NSString, range: NSRange? = nil) -> [DateHit] {
        var hits: [DateHit] = []
        func int(_ m: NSTextCheckingResult, _ i: Int) -> Int { Int(ns.substring(with: m.range(at: i))) ?? 0 }
        func word(_ m: NSTextCheckingResult, _ i: Int) -> Int? { monthNames[ns.substring(with: m.range(at: i)).lowercased()] }
        for m in dmy.all(ns, range: range) {
            var y = int(m, 3); if y < 100 { y += 2000 }
            if isValidDate(y, int(m, 2), int(m, 1)) { hits.append(DateHit(value: format(y, int(m, 2), int(m, 1)), range: m.range)) }
        }
        for m in iso.all(ns, range: range) where isValidDate(int(m, 1), int(m, 2), int(m, 3)) { hits.append(DateHit(value: format(int(m, 1), int(m, 2), int(m, 3)), range: m.range)) }
        for m in dMonthY.all(ns, range: range) { if let mo = word(m, 2), isValidDate(int(m, 3), mo, int(m, 1)) { hits.append(DateHit(value: format(int(m, 3), mo, int(m, 1)), range: m.range)) } }
        for m in monthDY.all(ns, range: range) { if let mo = word(m, 1), isValidDate(int(m, 3), mo, int(m, 2)) { hits.append(DateHit(value: format(int(m, 3), mo, int(m, 2)), range: m.range)) } }
        for m in slash.all(ns, range: range) {
            let a = int(m, 1), b = int(m, 2), y = int(m, 3)
            if a > 12, isValidDate(y, b, a) { hits.append(DateHit(value: format(y, b, a), range: m.range)) }            // dd/MM/yyyy
            else if b > 12, a <= 12, isValidDate(y, a, b) { hits.append(DateHit(value: format(y, a, b), range: m.range)) }  // MM/dd/yyyy
        }
        hits.sort { ($0.range.location, $0.range.length) < ($1.range.location, $1.range.length) }
        var out: [DateHit] = []
        for h in hits where !(out.last.map { NSIntersectionRange($0.range, h.range).length > 0 } ?? false) { out.append(h) }
        return out
    }

    /// `yyyy-MM-dd` plus `days` Tage (Gregorianisch, UTC).
    static func addDays(_ date: String, _ days: Int) -> String? {
        let p = date.split(separator: "-").compactMap { Int($0) }
        guard p.count == 3 else { return nil }
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        guard let d = cal.date(from: DateComponents(year: p[0], month: p[1], day: p[2])), let n = cal.date(byAdding: .day, value: days, to: d) else { return nil }
        let c = cal.dateComponents([.year, .month, .day], from: n)
        return format(c.year!, c.month!, c.day!)
    }

    // MARK: IBAN

    static func compact(_ s: String) -> String { String(s.uppercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) }) }

    /// ISO 7064 mod 97-10 und Länge 15…34.
    static func isValidIBAN(_ raw: String) -> Bool {
        let n = compact(raw)
        guard (15...34).contains(n.count), n.range(of: "^[A-Z]{2}[0-9]{2}[A-Z0-9]+$", options: .regularExpression) != nil else { return false }
        var remainder = 0
        for ch in String(n.dropFirst(4)) + String(n.prefix(4)) {
            guard let v = ch.isNumber ? ch.wholeNumberValue : (ch.asciiValue.map { Int($0) - 55 }) else { return false }
            for digit in String(v) { remainder = (remainder * 10 + Int(String(digit))!) % 97 }
        }
        return remainder == 1
    }

    private static let ibanRx = Rx("(?<![A-Za-z0-9])[A-Z]{2}\\d{2}(?:[ \u{00A0}]?[A-Z0-9]{2,4}){3,8}(?![A-Za-z0-9])", caseInsensitive: false)

    /// IBANs mit gültiger Prüfsumme. Anhängende Großbuchstabenwörter (BIC …) werden Gruppe für Gruppe abgeschnitten, bis die Prüfsumme stimmt.
    static func ibans(_ ns: NSString) -> [(value: String, range: NSRange)] {
        var out: [(String, NSRange)] = []
        for m in ibanRx.all(ns) {
            let raw = ns.substring(with: m.range)
            let groups = raw.split(whereSeparator: { $0 == " " || $0 == "\u{00A0}" }).map(String.init)
            var n = groups.count
            while n >= 1 {
                let candidate = groups.prefix(n).joined()
                if isValidIBAN(candidate) {
                    let consumed = groups.prefix(n).joined(separator: " ")
                    out.append((compact(candidate), NSRange(location: m.range.location, length: (consumed as NSString).length)))
                    break
                }
                n -= 1
            }
        }
        var seen = Set<String>()
        return out.filter { seen.insert($0.0).inserted }
    }

    // MARK: USt-ID

    private static let vatLabeled = Rx("(?:ust\\.?-?\\s?id(?:\\.?-?nr)?\\.?|umsatzsteuer-?\\s?(?:id|identifikationsnummer)(?:-?nr)?\\.?|vat\\s?(?:id|reg(?:istration)?)?\\s?(?:no\\.?|number|nr\\.?)?|tax\\s?id|uid(?:-?nr)?\\.?)[\\s:.#|-]{0,6}([A-Z]{2}[A-Z0-9 ]{8,16})")
    private static let vatPrefix = Rx("^(DE\\d{9}|ATU\\d{8}|FR[A-Z0-9]{2}\\d{9}|NL\\d{9}B\\d{2}|IT\\d{11}|ES[A-Z0-9]\\d{7}[A-Z0-9]|BE0\\d{9}|[A-Z]{2}[A-Z0-9]{8,12})", caseInsensitive: false)
    private static let vatBare = Rx("(?<![A-Za-z0-9])(DE\\s?\\d{9})(?![A-Za-z0-9])", caseInsensitive: false)

    static func isValidVATFormat(_ compactID: String) -> Bool {
        guard let m = vatPrefix.first(compactID as NSString), m.range.length == (compactID as NSString).length else { return false }
        return true
    }

    static func vatIDs(_ ns: NSString) -> [(value: String, range: NSRange, labeled: Bool)] {
        var out: [(String, NSRange, Bool)] = []
        for m in vatLabeled.all(ns) {
            let capture = m.range(at: 1)
            let c = compact(ns.substring(with: capture))
            guard let p = vatPrefix.first(c as NSString), p.range.location == 0 else { continue }
            let id = (c as NSString).substring(with: p.range)
            // Länge im Text: bis zum letzten Zeichen der ID (Leerzeichen innerhalb mitzählen)
            var consumed = 0, taken = 0
            let captureText = ns.substring(with: capture)
            for ch in captureText { if taken == id.count { break }; consumed += ch.utf16.count; if ch.isASCII, ch.isLetter || ch.isNumber { taken += 1 } }
            out.append((id, NSRange(location: m.range.location, length: capture.location - m.range.location + consumed), true))
        }
        for m in vatBare.all(ns) {
            let id = compact(ns.substring(with: m.range(at: 1)))
            if !out.contains(where: { $0.0 == id }) { out.append((id, m.range, false)) }
        }
        var seen = Set<String>()
        return out.filter { seen.insert($0.0).inserted }
    }
}
