import Foundation

// WP-D7: Allgemeine Fakten für alle Dokumente (Datum, Fälligkeit, Beträge mit Währung, IBAN, USt-ID, Referenzen, Aussteller, Titelvorschlag).
// Jeder Fakt trägt Fundstelle (UTF-16-Offset), Konfidenz und Begründung. Die Konfidenzen sind feste Konstanten.

enum Facts {
    static func order(_ type: String) -> Int { FactType.allCases.firstIndex { $0.rawValue == type } ?? 99 }

    static func source(_ ns: NSString, _ range: NSRange) -> FactSource {
        FactSource(offset: range.location, length: range.length, excerpt: DMSRuleEngine.excerpt(ns.substring(with: range), max: 80))
    }

    // MARK: Muster

    private static let dueLabel = Rx("(fällig(?:keit(?:sdatum)?)?(?:\\s+(?:am|bis))?|zahlungsziel|zahlbar\\s+bis|zu\\s+zahlen\\s+bis|zahlungsfrist|due\\s+date|payment\\s+due|due\\s+on|due\\s+by|pay\\s+by)[\\s:.|-]*$")
    private static let issueLabel = Rx("(rechnungsdatum|rechnungs-datum|belegdatum|ausstellungsdatum|invoice\\s+date|date\\s+of\\s+issue|issue\\s+date|ausgestellt\\s+am)[\\s:.|-]*$")
    private static let plainDateLabel = Rx("(datum|date|vom|dated)[\\s:.|-]*$")
    private static let deadlineLabel = Rx("(frist|bis\\s+zum|spätestens(?:\\s+bis)?|deadline|until|no\\s+later\\s+than)[\\s:.|-]*$")
    private static let relativeDue = Rx("(?:innerhalb\\s+von|binnen|within|zahlungsziel:?|zahlbar\\s+in|net|zahlbar\\s+innerhalb\\s+von)\\s*(\\d{1,3})\\s*(?:tage|tagen|tag|days|day)")
    private static let invoiceNumber = Rx("(?:rechnungs-?\\s?(?:nummer|nr|no)\\.?|invoice\\s?(?:number|no|nr|#)\\.?|rechnung\\s+(?:nr|no)\\.?|re-?nr\\.?|beleg-?\\s?(?:nummer|nr)\\.?)\\s*[:#|]?\\s*[:#|]?\\s*([A-Z0-9][A-Z0-9\\-/._]{2,30})")
    private static let reference = Rx("(aktenzeichen|geschäftszeichen|vertragsnummer|kundennummer|kunden-nr|versicherungsnummer|policennummer|police(?:n)?-?nr|steuernummer|bestellnummer|referenznummer|referenz|customer\\s+(?:no|number|id)|contract\\s+(?:no|number)|policy\\s+(?:no|number)|order\\s+(?:no|number)|reference|az)\\.?\\s*[:#|]\\s*([A-Z0-9][A-Z0-9\\-/._]{2,28})")
    private static let legalForm = Rx("(?<![A-Za-zäöü])(GmbH(?:\\s*&\\s*Co\\.?\\s*KG)?|AG|UG(?:\\s*\\(haftungsbeschränkt\\))?|KG|OHG|GbR|e\\.\\s?K\\.|eG|SE|Ltd\\.?|Inc\\.?|LLC|S\\.A\\.|B\\.V\\.|Corp\\.?)(?![A-Za-zäöü])", caseInsensitive: false)

    private static let grossTier1 = Rx("(?<![a-zäöü-])(gesamtbetrag|rechnungsbetrag|bruttobetrag|endbetrag|gesamtsumme|rechnungssumme|zahlbetrag|total\\s+amount|amount\\s+due|grand\\s+total|total\\s+due|balance\\s+due|invoice\\s+total|zu\\s+zahlender\\s+betrag|zu\\s+zahlen|gesamt\\s+brutto|summe\\s+brutto|brutto(?:summe|betrag)?)(?![a-zäöü])")
    private static let grossTier2 = Rx("(?<![a-zäöü-])(summe|gesamt|total|betrag|amount|beitrag|prämie|saldo|zahlung)(?![a-zäöü])")
    private static let netLabel = Rx("(?<![a-zäöü])(nettobetrag|netto(?:summe)?|summe\\s+netto|zwischensumme|subtotal|net\\s+(?:amount|total)|gesamt\\s+netto)(?![a-zäöü])")
    private static let taxLabel = Rx("(?<![a-zäöü])(mwst|mehrwertsteuer|umsatzsteuer|ust|vat|tax)(?![a-zäöü])(?!\\.?-?\\s?ident)(?!\\.?-?\\s?id\\b)(?!-?\\s?nr)(?!\\.?\\s?-?\\s?voranmeldung)")
    private static let netWordAfter = Rx("^\\s{0,3}(netto|net)(?![a-zäöü])")

    // MARK: Entry

    static func general(_ ns: NSString, input: ExtractionInput, subject: String?) -> [ExtractedFact] {
        var out: [ExtractedFact] = []
        out += dateFacts(ns)
        out += amountFacts(ns)
        out += idFacts(ns)
        out += referenceFacts(ns)
        out += sellerFacts(ns, input: input)
        if let subject, !subject.isEmpty {
            out.append(ExtractedFact(.title, value: String(subject.prefix(300)), confidence: 0.7, reason: "Betreff der Mail",
                                     source: ns.range(of: subject).location != NSNotFound ? source(ns, ns.range(of: subject)) : nil))
        }
        return out
    }

    /// Für Nicht-Rechnungen: Rechnungsnummer wird zum Bezug (`reference`), Brutto zum allgemeinen Betrag, Netto/Steuer entfallen.
    static func finalize(_ facts: [ExtractedFact], kind: DocumentKind) -> [ExtractedFact] {
        if kind == .invoice { return facts }
        return facts.compactMap { f in
            switch f.type {
            case FactType.invoiceNumber.rawValue:
                return ExtractedFact(.reference, value: f.value, confidence: f.confidence * 0.9, reason: "Bezug: " + f.reason, source: f.source)
            case FactType.amountGross.rawValue:
                return ExtractedFact(.amount, value: f.value, currency: f.currency, confidence: f.confidence, reason: f.reason, source: f.source)
            case FactType.amountNet.rawValue, FactType.amountTax.rawValue:
                return nil
            default: return f
            }
        }
    }

    // MARK: Daten

    private static func labelContext(_ ns: NSString, before location: Int) -> String {
        let start = max(0, location - 60)
        var prefix = ns.substring(with: NSRange(location: start, length: location - start))
        if let nl = prefix.lastIndex(of: "\n") {
            let tail = prefix[prefix.index(after: nl)...]
            if tail.trimmingCharacters(in: .whitespaces).isEmpty {   // Spaltenlayout: Beschriftung steht in der Zeile davor
                let head = String(prefix[..<nl]).trimmingCharacters(in: .whitespaces)
                return head
            }
            prefix = String(tail)
        }
        return prefix
    }

    private static func dateFacts(_ ns: NSString) -> [ExtractedFact] {
        var out: [ExtractedFact] = []
        var unlabeled = 0
        for hit in ExtractionParsers.dates(ns) {
            let ctx = labelContext(ns, before: hit.range.location) as NSString
            let src = source(ns, hit.range)
            if let m = dueLabel.first(ctx) {
                out.append(ExtractedFact(.dueDate, value: hit.value, confidence: 0.9, reason: "Fälligkeit: Beschriftung „\(DMSRuleEngine.excerpt(ctx.substring(with: m.range(at: 1)), max: 40))“", source: src))
            } else if let m = issueLabel.first(ctx) {
                out.append(ExtractedFact(.date, value: hit.value, confidence: 0.9, reason: "Rechnungsdatum: Beschriftung „\(DMSRuleEngine.excerpt(ctx.substring(with: m.range(at: 1)), max: 40))“", source: src))
            } else if let m = plainDateLabel.first(ctx) {
                out.append(ExtractedFact(.date, value: hit.value, confidence: 0.7, reason: "Datum: Beschriftung „\(DMSRuleEngine.excerpt(ctx.substring(with: m.range(at: 1)), max: 40))“", source: src))
            } else if let m = deadlineLabel.first(ctx) {
                out.append(ExtractedFact(.deadline, value: hit.value, confidence: 0.6, reason: "Frist: Beschriftung „\(DMSRuleEngine.excerpt(ctx.substring(with: m.range(at: 1)), max: 40))“", source: src))
            } else if unlabeled < 6 {
                unlabeled += 1
                out.append(ExtractedFact(.date, value: hit.value, confidence: 0.4, reason: "Datum ohne Beschriftung", source: src))
            }
        }
        // relativ: „zahlbar innerhalb von 14 Tagen“ + beschriftetes Datum (höchste Konfidenz, dann frühester Fundort)
        if !out.contains(where: { $0.type == FactType.dueDate.rawValue }),
           let base = out.filter({ $0.type == FactType.date.rawValue }).sorted(by: { ($0.confidence, -($0.source?.offset ?? 0)) > ($1.confidence, -($1.source?.offset ?? 0)) }).first,
           let m = relativeDue.first(ns), let days = Int(ns.substring(with: m.range(at: 1))), let due = ExtractionParsers.addDays(base.value, days) {
            out.append(ExtractedFact(.dueDate, value: due, confidence: 0.55, reason: "abgeleitet: \(days) Tage Zahlungsziel ab \(base.value)", source: source(ns, m.range)))
        }
        return out
    }

    // MARK: Beträge

    private struct Labeled { let hit: AmountHit; let label: String; let range: NSRange }

    private static func accept(_ h: AmountHit) -> Bool { h.currency != nil || h.explicitDecimals }

    /// Betrag hinter einer Beschriftung: Rest der Zeile, sonst (Spaltenlayout) die nächste Zeile.
    private static func amount(after m: NSTextCheckingResult, in ns: NSString, labelGroup: Int = 1) -> Labeled? {
        let end = m.range.location + m.range.length
        let lineEnd = ns.range(of: "\n", options: [], range: NSRange(location: end, length: ns.length - end))
        let stop = min(lineEnd.location == NSNotFound ? ns.length : lineEnd.location, end + 120)
        var window = NSRange(location: end, length: stop - end)
        if let w = amountWindowResult(ns, window) { return Labeled(hit: w, label: ns.substring(with: m.range(at: labelGroup)), range: NSRange(location: m.range.location, length: w.range.location + w.range.length - m.range.location)) }
        if lineEnd.location != NSNotFound, ns.substring(with: window).trimmingCharacters(in: CharacterSet(charactersIn: " :|-.\t")).isEmpty {
            let next = lineEnd.location + 1
            let next2 = ns.range(of: "\n", options: [], range: NSRange(location: next, length: ns.length - next))
            window = NSRange(location: next, length: min(next2.location == NSNotFound ? ns.length : next2.location, next + 80) - next)
            if let w = amountWindowResult(ns, window) { return Labeled(hit: w, label: ns.substring(with: m.range(at: labelGroup)), range: NSRange(location: m.range.location, length: w.range.location + w.range.length - m.range.location)) }
        }
        return nil
    }

    private static func amountWindowResult(_ ns: NSString, _ window: NSRange) -> AmountHit? {
        guard window.length > 0 else { return nil }
        return ExtractionParsers.amounts(ns, range: window).first(where: accept)
    }

    private static func best(_ rx: Rx, _ ns: NSString, skipNetFollow: Bool, preferMax: Bool) -> Labeled? {
        var found: [Labeled] = []
        for m in rx.all(ns) {
            if skipNetFollow, netWordAfter.first(ns, range: NSRange(location: m.range.location + m.range.length, length: min(12, ns.length - m.range.location - m.range.length))) != nil { continue }
            if let l = amount(after: m, in: ns) { found.append(l) }
        }
        guard !found.isEmpty else { return nil }
        if preferMax { return found.max { (ExtractionParsers.decimal($0.hit.value) ?? 0) < (ExtractionParsers.decimal($1.hit.value) ?? 0) } }
        return found.first
    }

    private static func amountFacts(_ ns: NSString) -> [ExtractedFact] {
        var out: [ExtractedFact] = []
        var gross = best(grossTier1, ns, skipNetFollow: true, preferMax: true)
        var tier = "Gesamtbetrag"
        if gross == nil { gross = best(grossTier2, ns, skipNetFollow: true, preferMax: true); tier = "Summe/Betrag" }
        let net = best(netLabel, ns, skipNetFollow: false, preferMax: false)
        let tax = best(taxLabel, ns, skipNetFollow: false, preferMax: false)

        var grossValue = gross?.hit.value, grossCurrency = gross?.hit.currency
        var grossConfidence = gross.map { tier == "Gesamtbetrag" ? ($0.hit.currency != nil ? 0.9 : 0.8) : 0.55 }
        var grossReason = gross.map { "\(tier): Beschriftung „\(DMSRuleEngine.excerpt($0.label, max: 40))“" }
        var grossSource = gross.map { source(ns, $0.range) }

        // Plausibilität: Netto + Steuer = Brutto
        if let g = gross, let n = net, let t = tax, let gd = ExtractionParsers.decimal(g.hit.value), let nd = ExtractionParsers.decimal(n.hit.value), let td = ExtractionParsers.decimal(t.hit.value) {
            if nd + td == gd { grossConfidence = min(0.97, (grossConfidence ?? 0.8) + 0.07); grossReason = (grossReason ?? "") + "; Netto + Steuer = Brutto stimmt" }
            else { grossConfidence = (grossConfidence ?? 0.8) * 0.8; grossReason = (grossReason ?? "") + "; Netto + Steuer weicht ab" }
        } else if gross == nil, let n = net, let t = tax, let nd = ExtractionParsers.decimal(n.hit.value), let td = ExtractionParsers.decimal(t.hit.value) {
            grossValue = ExtractionParsers.parseAmount(NSDecimalNumber(decimal: nd + td).stringValue)
            grossCurrency = n.hit.currency ?? t.hit.currency
            grossConfidence = 0.6; grossReason = "abgeleitet: Netto + Steuer"; grossSource = source(ns, n.range)
        }
        if let v = grossValue, let c = grossConfidence, let r = grossReason {
            out.append(ExtractedFact(.amountGross, value: v, currency: grossCurrency, confidence: c, reason: r, source: grossSource))
        }
        if let n = net { out.append(ExtractedFact(.amountNet, value: n.hit.value, currency: n.hit.currency ?? grossCurrency, confidence: 0.8, reason: "Netto: Beschriftung „\(DMSRuleEngine.excerpt(n.label, max: 40))“", source: source(ns, n.range))) }
        if let t = tax { out.append(ExtractedFact(.amountTax, value: t.hit.value, currency: t.hit.currency ?? grossCurrency, confidence: 0.8, reason: "Steuer: Beschriftung „\(DMSRuleEngine.excerpt(t.label, max: 40))“", source: source(ns, t.range))) }
        // fehlende Währung: aus den übrigen Beträgen übernehmen (gleiches Dokument, gleiche Währung)
        return out
    }

    // MARK: IBAN / USt-ID

    private static func idFacts(_ ns: NSString) -> [ExtractedFact] {
        var out: [ExtractedFact] = []
        for (iban, range) in ExtractionParsers.ibans(ns).prefix(5) {
            out.append(ExtractedFact(.iban, value: iban, confidence: 0.95, reason: "IBAN, Prüfsumme (mod 97) gültig", source: source(ns, range)))
        }
        for (id, range, labeled) in ExtractionParsers.vatIDs(ns).prefix(3) {
            out.append(ExtractedFact(.vatID, value: id, confidence: labeled ? 0.92 : 0.6, reason: labeled ? "USt-ID mit Beschriftung, Format gültig" : "USt-ID-Format ohne Beschriftung", source: source(ns, range)))
        }
        return out
    }

    // MARK: Referenzen

    private static func referenceFacts(_ ns: NSString) -> [ExtractedFact] {
        var out: [ExtractedFact] = []
        if let m = invoiceNumber.all(ns).first(where: { ns.substring(with: $0.range(at: 1)).contains(where: \.isNumber) }) {
            var value = ns.substring(with: m.range(at: 1))
            while let last = value.last, "-/._".contains(last) { value.removeLast() }
            let full = NSRange(location: m.range.location, length: m.range.location + m.range.length - m.range.location - (ns.substring(with: m.range(at: 1)).count - value.count))
            out.append(ExtractedFact(.invoiceNumber, value: value, confidence: 0.9, reason: "Rechnungsnummer mit Beschriftung", source: source(ns, full)))
        }
        var seen = Set(out.map(\.value))
        for m in reference.all(ns) {
            var value = ns.substring(with: m.range(at: 2))
            while let last = value.last, "-/._".contains(last) { value.removeLast() }
            guard value.contains(where: \.isNumber), seen.insert(value).inserted else { continue }
            out.append(ExtractedFact(.reference, value: value, confidence: 0.8, reason: "Beschriftung „\(DMSRuleEngine.excerpt(ns.substring(with: m.range(at: 1)), max: 40))“", source: source(ns, m.range)))
            if out.count >= 6 { break }
        }
        return out
    }

    // MARK: Aussteller

    private static func sellerFacts(_ ns: NSString, input: ExtractionInput) -> [ExtractedFact] {
        var lineStart = 0
        var index = 0
        var candidates: [(line: String, range: NSRange, index: Int)] = []
        while lineStart < ns.length && index < 400 {
            let r = ns.range(of: "\n", options: [], range: NSRange(location: lineStart, length: ns.length - lineStart))
            let end = r.location == NSNotFound ? ns.length : r.location
            let range = NSRange(location: lineStart, length: end - lineStart)
            let line = ns.substring(with: range)
            if line.count <= 100, let m = legalForm.first(line as NSString) {
                // nur bis zum Ende der Rechtsform (Adresse, Telefon dahinter entfallen)
                var name = (line as NSString).substring(to: m.range.location + m.range.length).trimmingCharacters(in: CharacterSet(charactersIn: " \t|-–,:"))
                if let r = name.range(of: " (?:bei|von|from|at) (?=[A-ZÄÖÜ])", options: [.regularExpression, .backwards]) { name = String(name[r.upperBound...]) }
                for prefix in ["Von:", "From:", "Absender:", "Rechnungssteller:", "Seller:"] where name.hasPrefix(prefix) { name = String(name.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces) }
                if name.count >= 4 { candidates.append((name, range, index)) }
            }
            lineStart = end + 1; index += 1
        }
        guard let pick = candidates.first(where: { $0.index < 15 }) ?? candidates.first else { return [] }
        return [ExtractedFact(.seller, value: String(pick.line.prefix(120)), confidence: pick.index < 15 ? 0.6 : 0.45, reason: pick.index < 15 ? "Zeile mit Rechtsform im Briefkopf" : "Zeile mit Rechtsform im Dokument", source: source(ns, pick.range))]
    }
}
