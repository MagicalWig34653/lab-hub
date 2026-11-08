import Foundation

// WP-D8: Behörden- und Steuerschreiben. Zwei Arten teilen sich diesen Detektor: `tax_notice` (Finanzverwaltung, Steuerbegriffe) und `letter` (sonstige Behörde:
// Ordnungsamt, Gericht, Stadt, Zoll …). Ohne Behördenkennzeichen im Briefkopf/Absender bleibt die Art unter der Schwelle (lieber `other`/unsicher).
// Vorzeichen von `settlement_amount`: positiv = Zahlung an die Behörde (Nachzahlung, Bußgeld, Gebühr), negativ = Erstattung/Guthaben.

struct AuthorityDetector: DocumentDetector {
    let kind: DocumentKind
    var replaces: Set<FactType> { [] }

    private static let authority = Rx("(?<![\\p{L}])(finanzamt|finanzverwaltung|finanzbehörde|steuerverwaltung|bundeszentralamt|hauptzollamt|zollamt|zollverwaltung|bundesamt|landesamt|landratsamt|kreisverwaltung|stadtverwaltung|gemeindeverwaltung|kreisfinanz\\w*|stadtkasse|gemeindekasse|kämmerei|ordnungsamt|bußgeldstelle|bußgeldbehörde|polizeipräsidium|polizei|staatsanwaltschaft|amtsgericht|landgericht|verwaltungsgericht|finanzgericht|sozialgericht|arbeitsgericht|jobcenter|agentur\\s+für\\s+arbeit|bürgeramt|bezirksamt|straßenverkehrsamt|zulassungsstelle|regierungspräsidium|senatsverwaltung|rathaus|ministerium|landesbehörde|bundesbehörde|behörde|rundfunkbeitrag|beitragsservice|tax\\s+office|revenue\\s+(?:service|agency)|hmrc|inland\\s+revenue|city\\s+council|county\\s+council|municipality|local\\s+authority|court)(?![\\p{L}])")
    private static let taxVocab = Rx("(?<![\\p{L}])(finanzamt|steuerbescheid|einkommensteuer\\w*|umsatzsteuer\\w*|gewerbesteuer\\w*|körperschaftsteuer\\w*|grundsteuer\\w*|kraftfahrzeugsteuer|kfz-steuer|steuernummer|steuer-?id|steuererklärung|veranlagung\\w*|vorauszahlung\\w*|steuerfestsetzung|festgesetzte\\s+steuer|säumniszuschlag|abgabenordnung|steuerschuld|steuerliche\\w*|tax\\s+(?:assessment|notice|return|reference)|notice\\s+of\\s+assessment|self\\s+assessment)(?![\\p{L}])")
    private static let notice = Rx("(?<![\\p{L}])([\\p{L}\\-]*bescheid|festsetzung|anhörung|vorladung|ladung|verwarnung\\w*|bußgeld\\w*|mahnung|zahlungserinnerung|zahlungsaufforderung|vollstreckung\\w*|aufforderung|erinnerung|beitragsbescheid|gebührenbescheid|verfügung|beschluss|urteil|penalty\\s+notice|notice\\s+of\\s+\\w+|tax\\s+assessment|summons|hearing)(?![\\p{L}])")
    private static let referenceLabel = Rx("(?:aktenzeichen|geschäftszeichen|kassenzeichen|bescheid-?\\s?(?:nummer|nr)|ihr\\s+zeichen|unser\\s+zeichen|buchungskennzeichen|beitragsnummer|(?<![\\p{L}])gz|(?<![\\p{L}])az|file\\s+(?:no|number|ref(?:erence)?)|case\\s+(?:no|number|ref(?:erence)?)|reference\\s+(?:no|number))\\.?\\s*[:#|]?")
    private static let taxNumberLabel = Rx("(?:steuernummer|steuer-?nr|st\\.?-?nr|tax\\s+reference|utr|unique\\s+taxpayer\\s+reference)\\.?\\s*[:#|]?\\s*")
    private static let taxIDLabel = Rx("(?:steuer-?\\s?id(?:-?nr)?|steuerliche\\s+identifikationsnummer|identifikationsnummer|idnr|tin|tax\\s+id(?:entification)?(?:\\s+number)?)\\.?\\s*[:#|]?\\s*")
    private static let remedy = Rx("rechtsbehelfsbelehrung|rechtsmittelbelehrung|einspruch|widerspruch|rechtsbehelf|appeal|objection|right\\s+to\\s+object")
    private static let infoOnly = Rx("zur\\s+information|informationsschreiben|information\\s+zur|hinweis\\s+zur|öffentliche\\s+bekanntmachung|newsletter|rundschreiben|bürgerinformation|information\\s+for\\s+residents|public\\s+notice")

    // Fristen
    private static let dueLabel = Rx("(?:zahlungsfrist|zahlbar\\s+bis|zu\\s+zahlen\\s+bis|zahlen\\s+sie(?:\\s+(?:den|die)\\s+\\S+)?(?:\\s+bitte)?\\s+(?:bis|spätestens)(?:\\s+(?:zum|spätestens|zum\\s+spätestens))?|bitte\\s+zahlen\\s+sie\\s+(?:bis|spätestens)(?:\\s+zum)?|überweisen\\s+sie\\s+(?:den\\s+betrag\\s+)?(?:bis|spätestens)(?:\\s+zum)?|fällig(?:keit(?:sdatum)?|keitstermin)?(?:\\s+(?:am|bis|zum))?|zahlungstermin|zahlung\\s+bis|payment\\s+due|due\\s+(?:date|by|on)|pay\\s+(?:by|before)|please\\s+pay\\s+(?:by|before))\\s*[:|]?")
    private static let deadlineLabel = Rx("(?:frist(?:ende)?|abgabefrist|stellungnahme\\s+(?:bis|innerhalb)|stellungnahme\\s+bis\\s+zum|äußerung\\s+bis|rückmeldung\\s+bis|einzureichen\\s+bis|vorzulegen\\s+bis|reply\\s+by|respond\\s+by|deadline)\\s*[:|]?")
    private static let objectionLabel = Rx("(?:einspruchs?-?frist|widerspruchs?-?frist|rechtsbehelfsfrist|einspruch|widerspruch|objection|appeal)")
    private static let dateLabel = Rx("(?:bescheid\\s+vom|bescheiddatum|datum\\s+des\\s+bescheids?|schreiben\\s+vom|ausstellungsdatum|ausgestellt\\s+am|date\\s+of\\s+(?:issue|notice|letter)|bescheid\\s+date|datum|date|, den)\\s*[:|]?")

    // Beträge: (Beschriftung, Richtung, Rang). Richtung +1 = Zahlung an die Behörde, -1 = Erstattung, 0 = Vorzeichen des Betrags entscheidet.
    private static let amountLabels: [(Rx, Int, Int)] = [
        (Rx("(?<![\\p{L}])(?:erstattungsbetrag|steuererstattung|rückerstattung|rückzahlung|erstattung|guthaben|überzahlung|zu\\s+erstatten\\w*|refund|credit)(?![\\p{L}])"), -1, 3),
        (Rx("(?<![\\p{L}])(?:nachzahlung|nachzuzahlen\\w*|zahlbetrag|zu\\s+zahlende[rn]?\\s+betrag|zu\\s+zahlen|gesamtbetrag|forderung|zahlungsbetrag|amount\\s+(?:payable|due)|balance\\s+due|total\\s+due|to\\s+pay)(?![\\p{L}])"), 1, 3),
        (Rx("(?<![\\p{L}])(?:abschlusszahlung|abschlussbetrag|ergebnis|saldo)(?![\\p{L}])"), 0, 3),
        (Rx("(?<![\\p{L}])(?:verwarnungsgeld|bußgeld|geldbuße|geldstrafe|säumniszuschlag|verspätungszuschlag|zwangsgeld|gebühr(?:en)?|kosten|festgesetzte\\s+(?:steuer|summe|betrag)|steuerschuld|vorauszahlung|beitrag|fine|penalty|fee)(?![\\p{L}])"), 1, 1)]

    private static let typeRules: [(String, String, Rx)] = [
        ("reminder", "Mahnung/Zahlungserinnerung", Rx("mahnung|zahlungserinnerung|vollstreckungsankündigung|zahlungsaufforderung|final\\s+notice|payment\\s+reminder")),
        ("hearing", "Anhörung", Rx("anhörung|hearing|stellungnahme")),
        ("summons", "Vorladung/Ladung", Rx("vorladung|ladung\\s+zu|summons")),
        ("fine", "Bußgeld/Verwarnung", Rx("bußgeld|verwarnung|geldbuße|ordnungswidrigkeit|penalty\\s+notice|fixed\\s+penalty")),
        ("tax_prepayment", "Vorauszahlungsbescheid", Rx("vorauszahlung\\w*bescheid|bescheid\\s+über\\s+(?:die\\s+)?vorauszahlung\\w*|bescheid\\s+für\\s+\\d{4}\\s+und\\s+vorauszahlung")),
        ("tax_assessment", "Steuerbescheid", Rx("steuerbescheid|einkommensteuerbescheid|umsatzsteuerbescheid|gewerbesteuerbescheid|grundsteuerbescheid|körperschaftsteuerbescheid|\\w*steuer\\w*bescheid|festsetzung\\s+der\\s+\\w*steuer|tax\\s+assessment|notice\\s+of\\s+assessment")),
        ("fee_notice", "Gebühren-/Beitragsbescheid", Rx("gebührenbescheid|beitragsbescheid|abgabenbescheid|rundfunkbeitrag|festsetzung\\s+der\\s+gebühr")),
        ("request", "Aufforderung/Erinnerung", Rx("aufforderung|erinnerung|reminder\\s+to\\s+file")),
        ("notice", "Bescheid", Rx("bescheid|verfügung|beschluss|notice"))]

    func isTax() -> Bool { kind == .taxNotice }

    func score(_ ctx: ExtractionContext) -> KindScore {
        let (add, result) = scoreBuilder()
        let ns = ctx.ns
        let senderName = ctx.input.sender ?? ""
        let head = ctx.head
        let authHead = AuthorityDetector.authority.first(head) != nil || AuthorityDetector.authority.first(senderName as NSString) != nil
        let taxCount = AuthorityDetector.taxVocab.all(ns).count
        let taxHead = AuthorityDetector.taxVocab.first(head) != nil
        let titleHit = KS.headline(AuthorityDetector.notice, ctx)
        let hasRef = !KS.labeledTokens(AuthorityDetector.referenceLabel, ns).isEmpty
        let taxNo = !AuthorityDetector.taxNumbers(ns).isEmpty
        let remedy = AuthorityDetector.remedy.first(ns) != nil
        let deadline = !AuthorityDetector.deadlineFacts(ns).isEmpty
        let settlement = AuthorityDetector.settlement(ns) != nil
        let tax = isTax()
        if tax {
            if authHead, AuthorityDetector.taxVocab.first(head) != nil || AuthorityDetector.taxVocab.first(senderName as NSString) != nil { add(0.3, "Finanzverwaltung im Briefkopf/Absender") }
            else if authHead { add(0.1, "Behörde im Briefkopf (nicht Finanzverwaltung)") }
            let t = min(2, taxCount)
            if t > 0 { add(0.12 * Double(t), "Steuerbegriffe im Text (\(taxCount))") }
            if taxHead { add(0.08, "Steuerbegriff in der Überschrift") }
        } else {
            if authHead { add(0.3, "Behörde im Briefkopf/Absender") }
            if taxCount >= 2 { add(-0.35, "Steuerbegriffe: gehört zur Art Steuerbescheid") }
        }
        if let t = titleHit { add(0.25, "Überschrift/Betreff nennt Bescheid/Verfahrensart: „\(DMSRuleEngine.excerpt(t, max: 40))“") }
        if hasRef { add(0.15, "Aktenzeichen/Geschäftszeichen mit Wert") }
        if taxNo { add(0.15, "Steuernummer im gültigen Format") }
        if remedy { add(0.12, "Rechtsbehelfsbelehrung/Einspruch/Widerspruch") }
        if deadline { add(0.08, "Frist mit Datum") }
        if settlement { add(0.08, "Zahlbetrag/Erstattung beschriftet") }
        if newsletterRx.first(ns) != nil || newsletterRx.first(ctx.subjectNS) != nil { add(-0.35, "Newsletter-/Werbehinweis") }
        if promoRx.first(ns) != nil { add(-0.25, "Werbehinweis") }
        if phishingRx.first(ns) != nil { add(-0.35, "Phishing-/Spam-Muster (Zugangsdaten, Link-Aufforderung)") }
        if AuthorityDetector.infoOnly.first(ns) != nil || AuthorityDetector.infoOnly.first(ctx.subjectNS) != nil { add(-0.15, "reines Informationsschreiben") }
        var s = result(kind)
        s.primary = authHead && (titleHit != nil || hasRef || taxNo)
        if !authHead { return capped(s, at: 0.3, reason: "keine Behörde im Briefkopf/Absender").withPrimary(false) }
        if titleHit == nil && !hasRef && !taxNo { return capped(s, at: 0.45, reason: "Behörde, aber weder Bescheid-Überschrift noch Aktenzeichen/Steuernummer").withPrimary(false) }
        return s
    }

    // MARK: Fakten

    /// Steuernummern mit Beschriftung im gültigen Format.
    static func taxNumbers(_ ns: NSString) -> [(value: String, label: String, range: NSRange)] {
        var out: [(String, String, NSRange)] = []
        for m in taxNumberLabel.all(ns) {
            let end = m.range.location + m.range.length
            let rest = ns.substring(with: NSRange(location: end, length: min(30, ns.length - end)))
            guard let r = rest.range(of: "^[0-9][0-9 /]{8,22}[0-9]", options: .regularExpression) else { continue }
            let raw = String(rest[r])
            for cut in stride(from: raw.count, through: 10, by: -1) {
                let cand = String(raw.prefix(cut))
                if let v = ExtractionParsers.normalizedTaxNumber(cand) {
                    out.append((v, ns.substring(with: m.range).trimmingCharacters(in: .whitespaces), NSRange(location: m.range.location, length: m.range.length + (cand as NSString).length)))
                    break
                }
            }
        }
        return out
    }

    static func taxIDs(_ ns: NSString) -> [(value: String, label: String, range: NSRange)] {
        var out: [(String, String, NSRange)] = []
        for m in taxIDLabel.all(ns) {
            let end = m.range.location + m.range.length
            let rest = ns.substring(with: NSRange(location: end, length: min(20, ns.length - end)))
            guard let r = rest.range(of: "^[0-9][0-9 ]{9,14}[0-9]", options: .regularExpression) else { continue }
            let raw = String(rest[r])
            for cut in stride(from: raw.count, through: 11, by: -1) {
                let cand = String(raw.prefix(cut))
                if ExtractionParsers.isValidTaxID(cand) {
                    out.append((cand.filter(\.isNumber), ns.substring(with: m.range).trimmingCharacters(in: .whitespaces), NSRange(location: m.range.location, length: m.range.length + (cand as NSString).length)))
                    break
                }
            }
        }
        return out
    }

    private static func accepts(_ between: String) -> Bool {
        let t = between.trimmingCharacters(in: CharacterSet(charactersIn: " :|,.\n\t")).lowercased()
        if t.isEmpty { return true }
        return ["bis", "bis zum", "bis spätestens", "spätestens", "spätestens bis", "spätestens zum", "bis spätestens zum", "zum", "am", "until", "by", "before", "bis zu", "endet am", "ist am", "ist bis", "ist bis zum", "läuft am", "läuft bis", "läuft bis zum"].contains(t)
    }

    /// Fristen: Zahlungsfrist -> due_date, sonstige Frist -> deadline, Einspruch/Widerspruch -> objection_deadline (Datum oder abgeleitet aus Bescheiddatum + Dauer).
    static func deadlineFacts(_ ns: NSString) -> [ExtractedFact] {
        var out: [ExtractedFact] = []
        func scan(_ rx: Rx, _ type: FactType, _ conf: Double, _ what: String, window: Int = 100) {
            for m in rx.all(ns) {
                let end = m.range.location + m.range.length
                guard end < ns.length else { continue }
                let r = NSRange(location: end, length: min(window, ns.length - end))
                guard let d = ExtractionParsers.dates(ns, range: r).first else { continue }
                let between = ns.substring(with: NSRange(location: end, length: d.range.location - end))
                guard accepts(between) || between.contains("\n") && accepts(between.components(separatedBy: "\n").last ?? "") else { continue }
                out.append(KS.make(type, d.value, conf, "\(what): Beschriftung „\(DMSRuleEngine.excerpt(ns.substring(with: m.range), max: 40))“",
                                   ns, NSRange(location: m.range.location, length: d.range.location + d.range.length - m.range.location)))
            }
        }
        scan(objectionLabel, .objectionDeadline, 0.88, "Einspruchs-/Widerspruchsfrist", window: 120)
        scan(dueLabel, .dueDate, 0.88, "Zahlungsfrist/Fälligkeit")
        scan(deadlineLabel, .deadline, 0.78, "Frist")
        // Einspruch relativ: „binnen eines Monats nach Bekanntgabe“ + Bescheiddatum
        if !out.contains(where: { $0.type == FactType.objectionDeadline.rawValue }), let base = dateFacts(ns).first(where: { $0.confidence >= 0.85 }) {
            for m in objectionLabel.all(ns) {
                let end = m.range.location + m.range.length
                let r = NSRange(location: end, length: min(80, ns.length - end))
                if let d = ExtractionParsers.durations(ns, range: r).first, let date = ExtractionParsers.addDuration(base.value, d.iso) {
                    out.append(KS.make(.objectionDeadline, date, 0.5, "abgeleitet: Bescheiddatum \(base.value) + \(d.count) \(ContractDetector.unitName(d)) (ohne Bekanntgabefiktion; Frist prüfen)", ns,
                                       NSRange(location: m.range.location, length: d.range.location + d.range.length - m.range.location)))
                    break
                }
            }
        }
        // jede Datums-/Typ-Kombination nur einmal
        var seen = Set<String>()
        return out.filter { seen.insert($0.type + $0.value).inserted }
    }

    static func dateFacts(_ ns: NSString) -> [ExtractedFact] {
        var out: [ExtractedFact] = []
        for d in KS.dateAfter(dateLabel, ns, gap: 6) {
            let strong = d.label.lowercased().contains("bescheid") || d.label.lowercased().contains("schreiben") || d.label.lowercased().contains("ausgestellt") || d.label.lowercased().contains("issue") || d.label.lowercased().contains("notice")
            out.append(KS.make(.date, d.date.value, strong ? 0.9 : 0.8, "Bescheid-/Schreibendatum: Beschriftung „\(DMSRuleEngine.excerpt(d.label.trimmingCharacters(in: .whitespaces), max: 30))“", ns, d.range))
        }
        if out.isEmpty {
            // erstes Datum im Briefkopf (erste zwölf Zeilen) als Schreibendatum
            for l in KS.lines(ns, limit: 14) {
                if let d = ExtractionParsers.dates(ns, range: l.range).first {
                    out.append(KS.make(.date, d.value, 0.6, "Datum im Briefkopf (Zeile \(l.index + 1)), ohne Beschriftung", ns, d.range)); break
                }
            }
        }
        return out
    }

    /// Zahlbetrag/Erstattung mit Vorzeichen: höchster Rang zuerst, dann erste Fundstelle. Positiv = an die Behörde zu zahlen.
    static func settlement(_ ns: NSString) -> (value: String, currency: String?, range: NSRange, label: String, direction: Int)? {
        var best: (rank: Int, value: String, currency: String?, range: NSRange, label: String, direction: Int)?
        for (rx, dir, rank) in amountLabels {
            for a in KS.labeledAmounts(rx, ns) {
                var sign = dir
                if dir == 0 { sign = a.negative ? -1 : 1 }
                guard let dec = ExtractionParsers.decimal(a.value.replacingOccurrences(of: "-", with: "")) else { continue }
                let magnitude = NSDecimalNumber(decimal: dec).stringValue
                let v = ExtractionParsers.parseAmount(magnitude) ?? a.value
                let signed = (sign < 0 && dec != 0) ? "-" + v : v
                if best == nil || rank > best!.rank { best = (rank, signed, a.currency, a.range, a.label, sign) }
            }
        }
        return best.map { ($0.value, $0.currency ?? KS.documentCurrency(ns), $0.range, $0.label, $0.direction) }
    }

    func facts(_ ctx: ExtractionContext) -> [ExtractedFact] {
        let ns = ctx.ns
        var out: [ExtractedFact] = []
        // Behörde: Briefkopfzeile mit Behördenwort, sonst Absender
        if let l = KS.lines(ns, limit: 14).first(where: { $0.text.count <= 100 && AuthorityDetector.authority.first($0.text as NSString) != nil && !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }) {
            let name = KS.trimValue(l.text)
            out.append(KS.make(.authority, name, 0.8, "Behörde: Zeile \(l.index + 1) im Briefkopf nennt eine Behörde", ns, NSRange(location: l.range.location + (l.text as NSString).range(of: name).location, length: (name as NSString).length)))
        } else if let sender = ctx.input.sender, AuthorityDetector.authority.first(sender as NSString) != nil {
            let name = KS.trimValue(sender.components(separatedBy: "<").first ?? sender)
            if !name.isEmpty { out.append(ExtractedFact(.authority, value: name, confidence: 0.65, reason: "Behörde: Absender der Mail", source: nil)) }
        }
        for t in KS.labeledTokens(AuthorityDetector.referenceLabel, ns).prefix(3) {
            out.append(KS.make(.reference, t.token, 0.88, "Aktenzeichen/Geschäftszeichen: Beschriftung „\(DMSRuleEngine.excerpt(t.label, max: 30))“", ns, t.range))
        }
        for n in AuthorityDetector.taxNumbers(ns).prefix(2) {
            out.append(KS.make(.taxNumber, n.value, 0.9, "Steuernummer: Beschriftung „\(DMSRuleEngine.excerpt(n.label, max: 20))“, Format gültig", ns, n.range))
            out.append(KS.make(.reference, n.value, 0.8, "Bezug: Steuernummer", ns, n.range))
        }
        for n in AuthorityDetector.taxIDs(ns).prefix(1) {
            out.append(KS.make(.taxID, n.value, 0.95, "Steuer-ID: Beschriftung „\(DMSRuleEngine.excerpt(n.label, max: 30))“, Prüfziffer (ISO 7064) gültig", ns, n.range))
        }
        out += AuthorityDetector.dateFacts(ns)
        out += AuthorityDetector.deadlineFacts(ns)
        if let s = AuthorityDetector.settlement(ns) {
            let why = s.direction < 0 ? "Erstattung/Guthaben (negativ)" : "Zahlung an die Behörde (positiv)"
            out.append(KS.make(.settlementAmount, s.value, currency: s.currency, 0.85, "\(why): Beschriftung „\(DMSRuleEngine.excerpt(s.label, max: 30))“", ns, s.range))
        }
        // Art des Schreibens: nur aus Überschrift/Betreff/Briefkopf, in fester Reihenfolge
        let headText = ctx.head as String
        for (code, label, rx) in AuthorityDetector.typeRules {
            if let line = headText.split(separator: "\n").first(where: { rx.first(String($0) as NSString) != nil }) {
                let r = ns.range(of: String(line))
                out.append(KS.make(.noticeType, code, 0.8, "Art: \(label) (Überschrift „\(DMSRuleEngine.excerpt(String(line), max: 40))“)", ns, r.location == NSNotFound ? nil : r))
                break
            }
        }
        return out
    }
}

private extension KindScore {
    func withPrimary(_ p: Bool) -> KindScore { var c = self; c.primary = p; return c }
}
