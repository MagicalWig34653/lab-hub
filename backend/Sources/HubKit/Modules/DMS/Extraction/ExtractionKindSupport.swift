import Foundation

// WP-D8: gemeinsame Bausteine der artspezifischen Detektoren (Vertrag, Versicherung, Behörde/Steuer, Kontoauszug, Kassenbon).
// Alles reine Funktionen auf dem Dokumenttext (UTF-16-Offsets wie in D7), keine Uhr, kein Zufall.

struct LabelValue {
    /// Beschriftung wie im Text.
    let label: String
    /// Wert hinter der Beschriftung (Rest der Zeile bzw. nächste Zeile bei Spaltenlayout).
    let value: String
    let valueRange: NSRange
    /// Beschriftung bis Wertende, für die Fundstelle.
    let range: NSRange
}

enum KS {
    static func src(_ ns: NSString, _ r: NSRange) -> FactSource { Facts.source(ns, r) }

    /// Wertbereich hinter einer Beschriftung: Rest der Zeile, bei leerem Rest (Spaltenlayout) die nächste nicht leere Zeile. Höchstens `maxLen` UTF-16-Einheiten.
    static func region(after m: NSTextCheckingResult, in ns: NSString, maxLen: Int = 120) -> NSRange? {
        let end = m.range.location + m.range.length
        guard end <= ns.length else { return nil }
        let window = min(ns.length - end, maxLen + 200)
        let nl = ns.range(of: "\n", options: [], range: NSRange(location: end, length: window))
        let lineEnd = nl.location == NSNotFound ? end + window : nl.location
        let rest = ns.substring(with: NSRange(location: end, length: lineEnd - end))
        if !rest.trimmingCharacters(in: CharacterSet(charactersIn: " :|-.\t\u{00A0}")).isEmpty {
            return NSRange(location: end, length: min(lineEnd - end, maxLen))
        }
        guard nl.location != NSNotFound else { return nil }
        var start = lineEnd + 1
        // höchstens eine Leerzeile überspringen
        for _ in 0..<2 where start < ns.length {
            let n2 = ns.range(of: "\n", options: [], range: NSRange(location: start, length: ns.length - start))
            let e2 = n2.location == NSNotFound ? ns.length : n2.location
            if !ns.substring(with: NSRange(location: start, length: e2 - start)).trimmingCharacters(in: .whitespaces).isEmpty {
                return NSRange(location: start, length: min(e2 - start, maxLen))
            }
            if n2.location == NSNotFound { return nil }
            start = e2 + 1
        }
        return nil
    }

    static func trimValue(_ s: String) -> String {
        s.trimmingCharacters(in: CharacterSet(charactersIn: " :|-–·,;\t\u{00A0}"))
    }

    /// Alle Treffer einer Beschriftung mit Wert (Text). `cut` kürzt den Wert an einem Trenner (z. B. zwei Leerzeichen, " | ").
    static func labeledValues(_ rx: Rx, _ ns: NSString, maxLen: Int = 100) -> [LabelValue] {
        var out: [LabelValue] = []
        for m in rx.all(ns) {
            guard let r = region(after: m, in: ns, maxLen: maxLen) else { continue }
            var v = ns.substring(with: r)
            if let cut = v.range(of: "\\s{3,}|\\s\\|\\s|\\t", options: .regularExpression) { v = String(v[..<cut.lowerBound]) }
            let t = trimValue(v)
            guard !t.isEmpty else { continue }
            let vr = NSRange(location: r.location + (ns.substring(with: r) as NSString).range(of: t).location, length: (t as NSString).length)
            out.append(LabelValue(label: ns.substring(with: m.range), value: t, valueRange: vr,
                                  range: NSRange(location: m.range.location, length: vr.location + vr.length - m.range.location)))
        }
        return out
    }

    /// Erstes Datum im Wertbereich hinter der Beschriftung.
    static func labeledDates(_ rx: Rx, _ ns: NSString) -> [(date: ExtractionParsers.DateHit, label: String, range: NSRange, all: [ExtractionParsers.DateHit])] {
        var out: [(ExtractionParsers.DateHit, String, NSRange, [ExtractionParsers.DateHit])] = []
        for m in rx.all(ns) {
            guard let r = region(after: m, in: ns, maxLen: 90) else { continue }
            let dates = ExtractionParsers.dates(ns, range: r)
            guard let d = dates.first else { continue }
            out.append((d, ns.substring(with: m.range), NSRange(location: m.range.location, length: d.range.location + d.range.length - m.range.location), dates))
        }
        return out
    }

    /// Betrag hinter einer Beschriftung (mit Vorzeichen, falls im Text erkennbar).
    struct SignedAmount { let value: String; let currency: String?; let range: NSRange; let label: String; let negative: Bool; let line: String }

    static func labeledAmounts(_ rx: Rx, _ ns: NSString, maxLen: Int = 100) -> [SignedAmount] {
        var out: [SignedAmount] = []
        for m in rx.all(ns) {
            guard let r = region(after: m, in: ns, maxLen: maxLen) else { continue }
            guard let hit = ExtractionParsers.amounts(ns, range: r).first(where: { $0.currency != nil || $0.explicitDecimals }) else { continue }
            let (v, neg) = ExtractionParsers.signed(hit, in: ns)
            let lineStart = max(0, m.range.location - 40)
            let line = ns.substring(with: NSRange(location: lineStart, length: min(ns.length - lineStart, 120))).components(separatedBy: "\n").last.map { String($0) } ?? ""
            out.append(SignedAmount(value: v, currency: hit.currency, range: NSRange(location: m.range.location, length: hit.range.location + hit.range.length - m.range.location),
                                    label: ns.substring(with: m.range), negative: neg, line: line))
        }
        return out
    }

    /// Überschriftszeile (Betreff oder eine der ersten Zeilen, höchstens 90 Zeichen), die das Muster trifft.
    static func headline(_ rx: Rx, _ ctx: ExtractionContext) -> String? {
        for l in (ctx.head as String).split(separator: "\n", omittingEmptySubsequences: true) where l.count <= 90 {
            if rx.first(String(l) as NSString) != nil { return String(l).trimmingCharacters(in: .whitespaces) }
        }
        return nil
    }

    /// Beschriftung + Kennung (Aktenzeichen, Vertragsnummer, Policennummer …).
    static func labeledTokens(_ rx: Rx, _ ns: NSString) -> [(token: String, label: String, range: NSRange)] {
        labeledValues(rx, ns, maxLen: 60).compactMap { lv in
            guard let t = idToken(lv.value) else { return nil }
            let off = (lv.value as NSString).range(of: t).location
            let start = lv.valueRange.location + (off == NSNotFound ? 0 : off)
            return (t, lv.label, NSRange(location: lv.range.location, length: start + (t as NSString).length - lv.range.location))
        }
    }

    /// Datum direkt hinter einer Beschriftung (höchstens `gap` Zeichen dazwischen; Spaltenlayout mit Datum in der nächsten Zeile zählt als direkt).
    static func dateAfter(_ rx: Rx, _ ns: NSString, gap: Int = 8) -> [(date: ExtractionParsers.DateHit, label: String, range: NSRange)] {
        labeledDates(rx, ns).compactMap { r in
            let labelEnd = r.range.location + (r.label as NSString).length
            let between = ns.substring(with: NSRange(location: labelEnd, length: max(0, r.date.range.location - labelEnd)))
            guard between.contains("\n") || between.count <= gap else { return nil }
            return (r.date, r.label, r.range)
        }
    }

    static func has(_ rx: Rx, _ ns: NSString) -> Bool { rx.first(ns) != nil }
    static func count(_ rx: Rx, _ ns: NSString) -> Int { rx.all(ns).count }

    /// Kennung (Vertrags-, Policen-, Aktenzeichen) am Anfang eines Werts: mindestens eine Ziffer, 3 bis 41 Zeichen.
    static func idToken(_ s: String) -> String? {
        var t = s.trimmingCharacters(in: CharacterSet(charactersIn: " :#|\t"))
        guard let r = t.range(of: "^[A-Za-z0-9][A-Za-z0-9\\-/._]{2,40}", options: .regularExpression) else { return nil }
        t = String(t[r])
        while let l = t.last, "-/._".contains(l) { t.removeLast() }
        return t.count >= 3 && t.contains(where: \.isNumber) ? t : nil
    }

    static func lines(_ ns: NSString, limit: Int = 400) -> [(text: String, range: NSRange, index: Int)] {
        var out: [(String, NSRange, Int)] = []
        var start = 0, i = 0
        while start <= ns.length, i < limit {
            let nl = ns.range(of: "\n", options: [], range: NSRange(location: start, length: ns.length - start))
            let end = nl.location == NSNotFound ? ns.length : nl.location
            out.append((ns.substring(with: NSRange(location: start, length: end - start)), NSRange(location: start, length: end - start), i))
            if nl.location == NSNotFound { break }
            start = end + 1; i += 1
        }
        return out
    }

    /// Dokumentweit häufigste/erste Währung (für Beträge ohne Währungsangabe).
    static func documentCurrency(_ ns: NSString) -> String? {
        ExtractionParsers.amounts(ns, range: NSRange(location: 0, length: min(ns.length, 60_000))).first(where: { $0.currency != nil })?.currency
    }

    static func make(_ type: FactType, _ value: String, currency: String? = nil, _ confidence: Double, _ reason: String, _ ns: NSString, _ range: NSRange?) -> ExtractedFact {
        ExtractedFact(type, value: value, currency: currency, confidence: confidence, reason: reason, source: range.map { src(ns, $0) })
    }

    /// Entfernt Adress-/Kontaktanhang hinter dem Namen (" · ", " | ", Komma + Ziffer).
    static func cutName(_ s: String) -> String {
        var name = s
        for sep in [" · ", " | ", "·", " • "] { if let r = name.range(of: sep) { name = String(name[..<r.lowerBound]) } }
        if let r = name.range(of: ",\\s*\\d", options: .regularExpression) { name = String(name[..<r.lowerBound]) }
        return trimValue(name)
    }

    /// Hat eine der ersten `n` nicht leeren Zeilen (Briefkopf/Titel) einen Treffer? Liefert die Zeile.
    static func headLine(_ rx: Rx, _ ns: NSString, first n: Int = 12) -> (text: String, range: NSRange, index: Int)? {
        var seen = 0
        for l in lines(ns, limit: 80) where !l.text.trimmingCharacters(in: .whitespaces).isEmpty {
            seen += 1
            if seen > n { break }
            if rx.first(l.text as NSString) != nil { return l }
        }
        return nil
    }
}

/// Lässt Detektoren je Art Obergrenzen setzen („Struktur fehlt“), mit Begründung.
func capped(_ s: KindScore, at cap: Double, reason: String) -> KindScore {
    s.score > cap ? KindScore(kind: s.kind, score: cap, reasons: s.reasons + ["gedeckelt auf \(DocumentExtractor.fmt(cap)): " + reason], primary: s.primary) : s
}

/// Phishing-/Spam-Muster (gemeinsam für alle Arten, die per Mail kommen können).
let phishingRx = Rx("klicken sie hier|click here|konto (?:wurde )?gesperrt|account (?:has been )?(?:suspended|locked)|passwort|password|verify your|bestätigen sie ihre|öffnen sie den anhang|open the attachment|\\.zip\\b|\\.exe\\b|kreditkarte(?![\\p{L}])|credit card(?! statement)|zugangsdaten|login details")
let newsletterRx = Rx("newsletter|abmelden|unsubscribe|abbestellen|im browser ansehen|view in browser")
let promoRx = Rx("gutschein|rabatt|% off|jetzt sichern|nur heute|jetzt (?:abschließen|berechnen|vergleichen|wechseln)|jetzt (?:informieren|bestellen|buchen)|sparen sie|save up to|special offer|sonderaktion|(?<![\\p{L}])aktion(?![\\p{L}])|testsieger|gratis|kostenlos(?:e[rn]?)? (?:beratung|angebot|vergleich)|unverbindliche[sn]? (?:angebot|vergleich|beratung)|free quote|get a quote")
