import Foundation

// WP-D8: weitere Parser: Zeitspannen (ISO 8601: P3M, P6W, P30D, P1Y), Zahlweise, Steuer-ID (Prüfziffer), Steuernummer (Format), Vorzeichen bei Beträgen, Datumsrechnung.

extension ExtractionParsers {
    // MARK: Zeitspannen

    private static let numberWords: [String: Int] = [
        "ein": 1, "eines": 1, "eine": 1, "einen": 1, "einem": 1, "einer": 1, "one": 1, "zwei": 2, "two": 2, "drei": 3, "three": 3, "vier": 4, "four": 4, "fünf": 5, "five": 5,
        "sechs": 6, "six": 6, "sieben": 7, "seven": 7, "acht": 8, "eight": 8, "neun": 9, "nine": 9, "zehn": 10, "ten": 10, "elf": 11, "zwölf": 12, "twelve": 12]
    private static let durationRx = Rx("(?<![\\p{L}\\d])(\\d{1,3}|einen|einem|einer|eines|eine|ein|one|zwei|two|drei|three|vier|four|fünf|five|sechs|six|sieben|seven|acht|eight|neun|nine|zehn|ten|elf|zwölf|twelve)(?:\\s?\\(\\d+\\))?[\\s-]{0,2}(tagen|tage|tag|wochen|woche|monaten|monate|monats|monat|jahren|jahre|jahres|jahr|days|day|weeks|week|months|month|years|year)(?![\\p{L}])")

    struct DurationHit: Sendable, Equatable { let iso: String; let count: Int; let unit: Character; let range: NSRange }

    /// Erste Zeitspanne im Bereich: `P<n>D|W|M|Y` (Tage, Wochen, Monate, Jahre). Null oder über 999 ergibt nil.
    static func durations(_ ns: NSString, range: NSRange? = nil) -> [DurationHit] {
        durationRx.all(ns, range: range).compactMap { m in
            let raw = ns.substring(with: m.range(at: 1)).lowercased()
            guard let n = Int(raw) ?? numberWords[raw], n >= 1 else { return nil }
            let u = ns.substring(with: m.range(at: 2)).lowercased()
            let unit: Character = u.hasPrefix("tag") || u.hasPrefix("day") ? "D" : u.hasPrefix("woche") || u.hasPrefix("week") ? "W" : u.hasPrefix("monat") || u.hasPrefix("month") ? "M" : "Y"
            return DurationHit(iso: "P\(n)\(unit)", count: n, unit: unit, range: m.range)
        }
    }

    /// `yyyy-MM-dd` plus ISO-Dauer (`P3M` usw.), Gregorianisch UTC; Monatsende wird geklammert.
    static func addDuration(_ date: String, _ iso: String) -> String? {
        guard iso.hasPrefix("P"), let unit = iso.last, let n = Int(iso.dropFirst().dropLast()) else { return nil }
        switch unit {
        case "D": return addDays(date, n)
        case "W": return addDays(date, n * 7)
        case "M", "Y":
            let p = date.split(separator: "-").compactMap { Int($0) }
            guard p.count == 3 else { return nil }
            var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
            guard let d = cal.date(from: DateComponents(year: p[0], month: p[1], day: p[2])),
                  let r = cal.date(byAdding: unit == "M" ? .month : .year, value: n, to: d) else { return nil }
            let c = cal.dateComponents([.year, .month, .day], from: r)
            return format(c.year!, c.month!, c.day!)
        default: return nil
        }
    }

    /// Letzter Tag des Monats (`yyyy-MM-dd`).
    static func endOfMonth(_ y: Int, _ m: Int) -> String {
        let days = [31, (y % 4 == 0 && (y % 100 != 0 || y % 400 == 0)) ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
        return format(y, m, days[m - 1])
    }

    // MARK: Zahlweise

    private static let intervalRules: [(String, Rx)] = [
        ("quarterly", Rx("vierteljährlich|vierteljährl\\.|vierteljahres\\w{0,30}|quartalsweise|quartals\\w{1,30}|(?:pro|je|im) quartal|quarterly|per quarter|a quarter|every three months|alle (?:drei|3) monate")),
        ("semiannual", Rx("halbjährlich|halbjährl\\.|halbjahres\\w{0,30}|semi-?annual\\w{0,30}|bi-?annual\\w{0,30}|every six months|alle (?:sechs|6) monate")),
        ("monthly", Rx("monatlich|monatl\\.|mtl\\.|monats(?:beitrag|prämie|miete|rate|preis|gebühr|entgelt)\\w{0,30}|(?:pro|je|im|/|per|a) ?monat|(?:per|a|/) ?month|monthly|/mo\\b")),
        ("yearly", Rx("(?<![\\p{L}])jährlich|(?<![\\p{L}])jährl\\.|jahres(?:beitrag|prämie|miete|gebühr|preis|entgelt|abo)\\w{0,30}|(?:pro|je|im|/) ?jahr|p\\.\\s?a\\.|(?:per|a|/) ?year|annual(?:ly)?|yearly"))]

    /// Zahlweise im Text (erster Treffer nach fester Reihenfolge der Regeln): quarterly, semiannual, monthly, yearly.
    static func interval(in text: String) -> (value: String, match: String)? {
        let ns = text as NSString
        for (value, rx) in intervalRules { if let m = rx.first(ns) { return (value, ns.substring(with: m.range)) } }
        return nil
    }

    // MARK: Steuer-ID und Steuernummer

    /// Persönliche Steuer-Identifikationsnummer: 11 Ziffern, erste nicht 0, in den ersten zehn Stellen genau eine Ziffer zwei- oder dreimal (nie dreimal hintereinander), Prüfziffer nach ISO 7064 (MOD 11,10).
    static func isValidTaxID(_ raw: String) -> Bool {
        let digits = raw.filter { $0.isASCII && $0.isNumber }
        guard digits.count == 11, raw.allSatisfy({ ($0.isASCII && $0.isNumber) || $0 == " " }), digits.first != "0" else { return false }
        let d = digits.map { $0.wholeNumberValue! }
        let first = Array(d.prefix(10))
        var counts = [Int](repeating: 0, count: 10)
        for x in first { counts[x] += 1 }
        guard counts.filter({ $0 >= 2 }).count == 1, counts.max()! <= 3 else { return false }
        for i in 0..<8 where first[i] == first[i + 1] && first[i + 1] == first[i + 2] { return false }
        var product = 10
        for x in first {
            var sum = (x + product) % 10
            if sum == 0 { sum = 10 }
            product = (2 * sum) % 11
        }
        let check = (11 - product) == 10 ? 0 : 11 - product
        return check == d[10]
    }

    /// Steuernummer (Landesformat `123/456/78901`, `12/345/67890`, 10- bis 13-stellig bundeseinheitlich): nur das Format, keine Prüfziffer (je Land verschieden).
    static func normalizedTaxNumber(_ raw: String) -> String? {
        let t = raw.trimmingCharacters(in: .whitespaces)
        let ns = t as NSString
        if let m = taxNumberSlash.first(ns), m.range.length == ns.length {
            return t.replacingOccurrences(of: " ", with: "")
        }
        let digits = t.replacingOccurrences(of: " ", with: "")
        if (10...13).contains(digits.count), digits.allSatisfy({ $0.isASCII && $0.isNumber }), t.allSatisfy({ $0.isNumber || $0 == " " }) { return digits }
        return nil
    }
    private static let taxNumberSlash = Rx("\\d{2,3} ?/ ?\\d{3,4} ?/ ?\\d{4,5}", caseInsensitive: false)

    // MARK: Vorzeichen

    /// Betrag mit Vorzeichen aus dem Umfeld: `-`/`−`/`–` davor oder dahinter, `S`/`Soll`/`DR` dahinter = negativ, `H`/`Haben`/`CR`/`+` = positiv.
    static func signed(_ hit: AmountHit, in ns: NSString) -> (value: String, negative: Bool) {
        var negative = false
        let i = hit.range.location - 1
        if i >= 0 {
            let c = ns.character(at: i).asScalar
            if "-−–".contains(c) {
                // Bindestrich zwischen Wörtern/Ziffern ist kein Vorzeichen: davor Leerraum, Zeilenanfang oder Beschriftungsende
                let before: Unicode.Scalar? = i > 0 ? ns.character(at: i - 1).asScalar : nil
                if before == nil || " \n\t:|(".contains(before!) { negative = true }
            }
        }
        let end = hit.range.location + hit.range.length
        let tail = ns.substring(with: NSRange(location: end, length: min(8, ns.length - end))).split(separator: "\n", omittingEmptySubsequences: false).first.map(String.init) ?? ""
        let t = tail.trimmingCharacters(in: .whitespaces)
        if t.range(of: "^[-−–](?![0-9])", options: .regularExpression) != nil { negative = true }
        else if t.range(of: "^(?:S|Soll|DR|D)(?![\\p{L}])", options: [.regularExpression]) != nil { negative = true }
        else if t.range(of: "^(?:H|Haben|CR|C)(?![\\p{L}])", options: [.regularExpression]) != nil { negative = false }
        return ((negative && hit.value != "0.00" ? "-" : "") + hit.value, negative)
    }
}

private extension UInt16 {
    var asScalar: Unicode.Scalar { Unicode.Scalar(self) ?? " " }
}

private extension String {
    func contains(_ s: Unicode.Scalar) -> Bool { unicodeScalars.contains(s) }
}
