import Foundation

// WP-D8: Detektoren für Verträge und Versicherungen. Deterministisch, ohne KI. Jeder Punkt des Scores hat eine Begründung; jeder Fakt trägt Fundstelle und Begründung.
// Konfidenzen sind feste Konstanten (beschriftet und validiert: 0,85 bis 0,95; abgeleitet: 0,5 bis 0,6).

/// Gemeinsame Fakten für Zeiträume (Vertrag, Versicherung, Kontoauszug).
enum PeriodFacts {
    static func facts(_ ns: NSString, start: Rx, end: Rx, range: Rx, what: String) -> [ExtractedFact] {
        var out: [ExtractedFact] = []
        for r in KS.labeledDates(range, ns) where r.all.count >= 2 {
            let a = r.all[0], b = r.all[1]
            guard b.value >= a.value else { continue }
            out.append(KS.make(.periodStart, a.value, 0.85, "\(what): Beschriftung „\(DMSRuleEngine.excerpt(r.label, max: 30))“, erstes Datum", ns, a.range))
            out.append(KS.make(.periodEnd, b.value, 0.85, "\(what): Beschriftung „\(DMSRuleEngine.excerpt(r.label, max: 30))“, zweites Datum", ns, b.range))
            break
        }
        if let s = KS.dateAfter(start, ns, gap: 80).first {
            out.append(KS.make(.periodStart, s.date.value, 0.88, "\(what) Beginn: Beschriftung „\(DMSRuleEngine.excerpt(s.label, max: 30))“", ns, s.range))
        }
        if let e = KS.dateAfter(end, ns, gap: 80).first {
            out.append(KS.make(.periodEnd, e.date.value, 0.88, "\(what) Ende: Beschriftung „\(DMSRuleEngine.excerpt(e.label, max: 30))“", ns, e.range))
        }
        return out
    }
}

struct ContractDetector: DocumentDetector {
    let kind = DocumentKind.contract
    var replaces: Set<FactType> { [] }

    private static let title = Rx("^\\W*(?:[\\p{L}\\-&]{1,30}\\s{1,3}){0,3}(?:[\\p{L}\\-]{0,30}vertrag|[\\p{L}\\-]{0,30}vereinbarung|agreement|contract)(?![\\p{L}])")
    private static let partyLabel = Rx("(?<![\\p{L}])(?:vertragspartner(?:in)?|auftraggeber(?:in)?|auftragnehmer(?:in)?|vermieter(?:in)?|mieter(?:in)?|lizenzgeber(?:in)?|lizenznehmer(?:in)?|arbeitgeber(?:in)?|arbeitnehmer(?:in)?|anbieter(?:in)?|provider|supplier|landlord|tenant|licensor|licensee|contractor|counterparty)\\s{0,3}[:|]")
    private static let partyKeywords = Rx("(?<![\\p{L}])(vertragspartner\\w{0,30}|auftraggeber\\w{0,30}|auftragnehmer\\w{0,30}|vermieter\\w{0,30}|mieter\\w{0,30}|lizenzgeber\\w{0,30}|arbeitgeber\\w{0,30}|arbeitnehmer\\w{0,30}|parteien|contracting part\\w{1,30}|the parties|licensor|licensee|landlord|tenant)(?![\\p{L}])")
    private static let between = Rx("(?i:zwischen|between)\\s{1,3}(?:der\\s{1,3}|dem\\s{1,3}|the\\s{1,3}|herrn\\s{1,3}|frau\\s{1,3})?([^\\n]{3,80}?)\\s{0,3}(?:,|\\n|\\(|\\s)(?i:und|and)\\s{1,3}(?:der\\s{1,3}|dem\\s{1,3}|the\\s{1,3}|herrn\\s{1,3}|frau\\s{1,3})?([^\\n,(]{3,80})")
    private static let legal = Rx("(?<![\\p{L}])(?:GmbH(?:\\s{0,3}&\\s{0,3}Co\\.?\\s{0,3}KG)?|AG|UG|KG|OHG|GbR|SE|Ltd\\.?|Inc\\.?|LLC|B\\.V\\.|S\\.A\\.|e\\.\\s?K\\.)(?![\\p{L}])", caseInsensitive: false)
    private static let numberLabel = Rx("(?:vertrags-?\\s?(?:nummer|nr)|vertrag\\s{1,3}nr|kontrakt-?\\s?(?:nummer|nr)|contract\\s{1,3}(?:no|number|nr|id|#)|agreement\\s{1,3}(?:no|number|nr|#))\\.?\\s{0,3}[:#|]?")
    private static let startLabel = Rx("(?:vertragsbeginn|vertragsstart|mietbeginn|beginn\\s{1,3}(?:des\\s{1,3})?(?:vertrag(?:s|es)?|mietverhältnis(?:ses)?|laufzeit)|laufzeitbeginn|beginn\\s{1,3}der\\s{1,3}laufzeit|laufzeit\\s{1,3}ab|beginnt\\s{1,3}am|beginn|start\\s{1,3}date|effective\\s{1,3}date|commencement\\s{1,3}date|starts?\\s{1,3}on|starting\\s{1,3}(?:on|from)|valid\\s{1,3}from)(?![\\p{L}])")
    private static let endLabel = Rx("(?:vertragsende|laufzeitende|ende\\s{1,3}der\\s{1,3}laufzeit|mietende|ablaufdatum|ablauf\\s{1,3}(?:des\\s{1,3})?(?:vertrag(?:s|es)?)|befristet\\s{1,3}bis|läuft\\s{1,3}bis|endet\\s{1,3}am|gültig\\s{1,3}bis|end\\s{1,3}date|expiry\\s{1,3}date|expiration\\s{1,3}date|expires\\s{1,3}on|valid\\s{1,3}until|ends?\\s{1,3}on|ending\\s{1,3}on)(?![\\p{L}])")
    private static let rangeLabel = Rx("(?:vertragslaufzeit|laufzeit|vertragszeitraum|mietzeit|term|contract\\s{1,3}period)\\s{0,3}[:|]?")
    private static let termLabel = Rx("(?:mindest-?)?(?:vertrags-?)?laufzeit|vertragsdauer|mietdauer|contract\\s{1,3}term|initial\\s{1,3}term|minimum\\s{1,3}term|term\\s{1,3}of\\s{1,3}(?:the\\s{1,3})?(?:contract|agreement)")
    private static let indefinite = Rx("unbefristet|auf\\s{1,3}unbestimmte\\s{1,3}zeit|indefinite|open-ended|until\\s{1,3}terminated")
    private static let noticeLabel = Rx("kündigungs-?\\s?frist|notice\\s{1,3}period|period\\s{1,3}of\\s{1,3}notice")
    private static let noticeSentence = Rx("(?:mit\\s{1,3}einer\\s{1,3})?frist\\s{1,3}von|(?:with|upon|by|giving)\\s{1,3}(?:a\\s{1,3})?(?:written\\s{1,3})?notice\\s{1,3}of|vorlauf\\s{1,3}von|im\\s{1,3}voraus\\s{1,3}von")
    private static let noticeEnglish = Rx("(\\d{1,3})\\s{0,3}(days|weeks|months)['’]?\\s{1,3}(?:written\\s{1,3})?notice")
    private static let renewTrue = Rx("verlängert\\s{1,3}sich\\s{1,3}(?:jeweils\\s{1,3}|automatisch\\s{1,3}|stillschweigend\\s{1,3})?(?:\\S+\\s{1,3}){0,4}?um|verlängert\\s{1,3}sich\\s{1,3}(?:automatisch|stillschweigend|jeweils)|automatische\\s{1,3}verlängerung|stillschweigende\\s{1,3}verlängerung|verlängerung\\s{1,3}um\\s{1,3}jeweils|auto(?:matically)?[\\s-]+renew\\w{0,30}|renews\\s{1,3}automatically|automatic\\s{1,3}renewal|renewed\\s{1,3}automatically")
    private static let renewFalse = Rx("keine\\s{1,3}automatische\\s{1,3}verlängerung|verlängert\\s{1,3}sich\\s{1,3}nicht|endet\\s{1,3}(?:automatisch|ohne\\s{1,3}kündigung)|ohne\\s{1,3}dass\\s{1,3}es\\s{1,3}einer\\s{1,3}kündigung\\s{1,3}bedarf|does\\s{1,3}not\\s{1,3}(?:automatically\\s{1,3})?renew|will\\s{1,3}not\\s{1,3}(?:automatically\\s{1,3})?renew|no\\s{1,3}automatic\\s{1,3}renewal|not\\s{1,3}automatically\\s{1,3}renew|ohne\\s{1,3}automatische\\s{1,3}verlängerung")
    private static let recurringLabel = Rx("(?<![\\p{L}])(?:(?:monatliche[rnms]?|jährliche[rnms]?|vierteljährliche[rnms]?|halbjährliche[rnms]?|monthly|annual|yearly|quarterly)\\s{1,3})?(?:(?:monats|jahres|quartals|halbjahres)?(?:vergütung|entgelt|miete|mietzins|pauschale|beitrag|preis|gebühr|rate|honorar)|grundgebühr|grundpreis|nutzungsentgelt|kaltmiete|warmmiete|miete|vergütung|entgelt|zahlung|kosten|betrag|fees?|rent|price|payment|charge|subscription|license\\s{1,3}fees?)(?![\\p{L}])")
    private static let signature = Rx("unterschrift|unterschriften|unterzeichnet|signature|signed\\s{1,3}by|ort,?\\s{1,3}datum|place,?\\s{1,3}date")
    private static let offer = Rx("^\\W*(?:[\\p{L}\\-]{1,30}\\s{1,3}){0,2}(?:angebot|vertragsangebot|offer|quote|quotation|kostenvoranschlag|proposal)(?![\\p{L}])")
    private static let cancelConfirm = Rx("kündigungsbestätigung|bestätigung\\s{1,3}(?:ihrer|der)\\s{1,3}kündigung|kündigung\\s{1,3}bestätigt|cancellation\\s{1,3}confirmation|termination\\s{1,3}confirmation")
    private static let dateLabel = Rx("(?:vertragsdatum|abgeschlossen\\s{1,3}am|unterzeichnet\\s{1,3}am|date\\s{1,3}of\\s{1,3}(?:the\\s{1,3})?agreement|signed\\s{1,3}on|agreement\\s{1,3}date)\\s{0,3}[:|]?")

    func score(_ ctx: ExtractionContext) -> KindScore {
        let (add, result) = scoreBuilder()
        let ns = ctx.ns
        let titleHit = KS.headline(ContractDetector.title, ctx)
        if let t = titleHit { add(0.25, "Überschrift nennt Vertrag/Vereinbarung/Agreement: „\(DMSRuleEngine.excerpt(t, max: 40))“") }
        let paragraphs = KS.count(Rx("§\\s?\\d"), ns)
        let parties = ContractDetector.between.first(ns) != nil
        if parties { add(0.1, "„zwischen … und …“ (Parteien)") }
        if ContractDetector.partyKeywords.first(ns) != nil { add(0.1, "Parteibezeichnung (Vertragspartner/Auftraggeber/Vermieter …)") }
        if paragraphs >= 2 { add(0.1, "Paragrafen (§) gegliedert") }
        let number = !KS.labeledTokens(ContractDetector.numberLabel, ns).isEmpty
        if number { add(0.2, "Vertragsnummer mit Wert") }
        let termF = ContractDetector.termLabel.first(ns) != nil && !ExtractionParsers.durations(ns).isEmpty
        let noticeF = !ContractDetector.noticeFacts(ns).isEmpty
        if termF { add(0.12, "Laufzeit mit Dauer") }
        if noticeF { add(0.15, "Kündigungsfrist mit Dauer") }
        if !KS.dateAfter(ContractDetector.startLabel, ns, gap: 80).isEmpty { add(0.1, "Vertragsbeginn mit Datum") }
        if ContractDetector.signature.first(ns) != nil { add(0.1, "Unterschriftszeile") }
        if ContractDetector.renewTrue.first(ns) != nil || ContractDetector.renewFalse.first(ns) != nil { add(0.05, "Regelung zur Verlängerung") }
        // Gegenindizien
        if newsletterRx.first(ns) != nil || newsletterRx.first(ctx.subjectNS) != nil { add(-0.35, "Newsletter-/Werbehinweis") }
        if promoRx.first(ns) != nil || promoRx.first(ctx.subjectNS) != nil { add(-0.25, "Werbehinweis (Rabatt/Aktion/Gutschein)") }
        if phishingRx.first(ns) != nil { add(-0.3, "Phishing-/Spam-Muster") }
        if KS.headline(ContractDetector.offer, ctx) != nil { add(-0.25, "Überschrift ist ein Angebot (kein geschlossener Vertrag)") }
        if ContractDetector.cancelConfirm.first(ns) != nil || ContractDetector.cancelConfirm.first(ctx.subjectNS) != nil { add(-0.3, "Kündigungsbestätigung") }
        var s = result(.contract)
        s.primary = titleHit != nil || (parties && paragraphs >= 2) || number && (termF || noticeF) && ContractDetector.signature.first(ns) != nil
        return s.primary ? s : capped(s, at: 0.45, reason: "keine Vertragsüberschrift und keine Parteien-/Paragrafenstruktur")
    }

    static func noticeFacts(_ ns: NSString) -> [ExtractedFact] {
        var out: [ExtractedFact] = []
        for m in noticeLabel.all(ns) {
            guard let r = KS.region(after: m, in: ns, maxLen: 80), let d = ExtractionParsers.durations(ns, range: r).first else { continue }
            out.append(noticeFact(d, ns, labelStart: m.range.location, label: ns.substring(with: m.range), conf: 0.9))
            break
        }
        if out.isEmpty {
            for m in noticeSentence.all(ns) {
                let end = m.range.location + m.range.length
                let r = NSRange(location: end, length: min(40, ns.length - end))
                guard let d = ExtractionParsers.durations(ns, range: r).first, d.range.location - end <= 6 else { continue }
                let ctxStart = max(0, m.range.location - 140)
                let before = ns.substring(with: NSRange(location: ctxStart, length: m.range.location - ctxStart))
                guard before.range(of: "kündig|terminat|cancel|beend", options: [.regularExpression, .caseInsensitive]) != nil else { continue }
                out.append(noticeFact(d, ns, labelStart: m.range.location, label: ns.substring(with: m.range), conf: 0.8))
                break
            }
        }
        if out.isEmpty, let m = noticeEnglish.first(ns) {
            let n = Int(ns.substring(with: m.range(at: 1))) ?? 0
            let u = ns.substring(with: m.range(at: 2)).lowercased()
            if n >= 1 { out.append(KS.make(.noticePeriod, "P\(n)\(u.hasPrefix("day") ? "D" : u.hasPrefix("week") ? "W" : "M")", 0.8, "Kündigungsfrist: \(n) \(u) Kündigung schriftlich (englisch)", ns, m.range)) }
        }
        return out
    }

    private static func noticeFact(_ d: ExtractionParsers.DurationHit, _ ns: NSString, labelStart: Int, label: String, conf: Double) -> ExtractedFact {
        KS.make(.noticePeriod, d.iso, conf, "Kündigungsfrist: \(d.count) \(unitName(d)) nach „\(DMSRuleEngine.excerpt(label, max: 30))“ (ISO 8601: \(d.iso))", ns,
                NSRange(location: labelStart, length: d.range.location + d.range.length - labelStart))
    }

    static func unitName(_ d: ExtractionParsers.DurationHit) -> String {
        switch d.unit { case "D": d.count == 1 ? "Tag" : "Tage"; case "W": d.count == 1 ? "Woche" : "Wochen"; case "M": d.count == 1 ? "Monat" : "Monate"; default: d.count == 1 ? "Jahr" : "Jahre" }
    }

    func facts(_ ctx: ExtractionContext) -> [ExtractedFact] {
        let ns = ctx.ns
        var out: [ExtractedFact] = []
        // Vertragspartner: beschriftet, sonst „zwischen A und B“
        var parties = 0
        for lv in KS.labeledValues(ContractDetector.partyLabel, ns, maxLen: 120) where parties < 3 {
            let name = KS.cutName(lv.value)
            guard name.count >= 3, name.count <= 100 else { continue }
            out.append(KS.make(.counterparty, name, 0.75, "Vertragspartner: Beschriftung „\(DMSRuleEngine.excerpt(lv.label, max: 30))“", ns, lv.range)); parties += 1
        }
        if parties == 0, let m = ContractDetector.between.first(ns) {
            for i in 1...2 {
                var name = KS.cutName(ns.substring(with: m.range(at: i)))
                if let r = ContractDetector.legal.all(name as NSString).last { name = (name as NSString).substring(to: r.range.location + r.range.length) }
                name = name.trimmingCharacters(in: CharacterSet(charactersIn: " ,;:"))
                guard name.count >= 3 else { continue }
                out.append(KS.make(.counterparty, name, 0.6, "Partei \(i) laut „zwischen … und …“", ns, m.range(at: i)))
            }
        }
        if let n = KS.labeledTokens(ContractDetector.numberLabel, ns).first {
            out.append(KS.make(.contractNumber, n.token, 0.9, "Vertragsnummer: Beschriftung „\(DMSRuleEngine.excerpt(n.label, max: 30))“", ns, n.range))
        }
        if let d = KS.dateAfter(ContractDetector.dateLabel, ns, gap: 6).first {
            out.append(KS.make(.date, d.date.value, 0.88, "Vertragsdatum: Beschriftung „\(DMSRuleEngine.excerpt(d.label, max: 30))“", ns, d.range))
        }
        out += PeriodFacts.facts(ns, start: ContractDetector.startLabel, end: ContractDetector.endLabel, range: ContractDetector.rangeLabel, what: "Vertrag")
        // Laufzeit
        var termDone = false
        for m in ContractDetector.termLabel.all(ns) {
            guard let r = KS.region(after: m, in: ns, maxLen: 80) else { continue }
            if let d = ExtractionParsers.durations(ns, range: r).first {
                out.append(KS.make(.term, d.iso, 0.85, "Laufzeit: \(d.count) \(ContractDetector.unitName(d)) nach „\(DMSRuleEngine.excerpt(ns.substring(with: m.range), max: 30))“ (ISO 8601: \(d.iso))", ns,
                                   NSRange(location: m.range.location, length: d.range.location + d.range.length - m.range.location)))
                termDone = true; break
            }
        }
        if !termDone, let m = ContractDetector.indefinite.first(ns) {
            out.append(KS.make(.term, "indefinite", 0.8, "Laufzeit unbefristet („\(ns.substring(with: m.range))“)", ns, m.range))
        }
        out += ContractDetector.noticeFacts(ns)
        if let m = ContractDetector.renewFalse.first(ns) {
            out.append(KS.make(.autoRenewal, "false", 0.8, "keine automatische Verlängerung: „\(DMSRuleEngine.excerpt(ns.substring(with: m.range), max: 50))“", ns, m.range))
        } else if let m = ContractDetector.renewTrue.first(ns) {
            out.append(KS.make(.autoRenewal, "true", 0.8, "automatische Verlängerung: „\(DMSRuleEngine.excerpt(ns.substring(with: m.range), max: 50))“", ns, m.range))
        }
        out += ContractDetector.recurring(ns)
        return out
    }

    /// Wiederkehrender Betrag mit Intervall: Betrag hinter einer Entgelt-Beschriftung, Intervall im Beschriftungswort oder im selben Satzteil.
    static func recurring(_ ns: NSString) -> [ExtractedFact] {
        for m in recurringLabel.all(ns) {
            guard let r = KS.region(after: m, in: ns, maxLen: 100),
                  let hit = ExtractionParsers.amounts(ns, range: r).first(where: { $0.currency != nil || $0.explicitDecimals }) else { continue }
            let lineStart = ns.lineRange(for: NSRange(location: m.range.location, length: 0)).location
            let tail = NSRange(location: lineStart, length: min(ns.length - lineStart, hit.range.location + hit.range.length - lineStart + 40))
            let text = ns.substring(with: tail).components(separatedBy: "\n")[0]
            guard let iv = ExtractionParsers.interval(in: text) else { continue }
            let cur = hit.currency ?? KS.documentCurrency(ns)
            let src = NSRange(location: m.range.location, length: hit.range.location + hit.range.length - m.range.location)
            var out = [KS.make(.recurringAmount, hit.value, currency: cur, 0.82, "wiederkehrender Betrag: Beschriftung „\(DMSRuleEngine.excerpt(ns.substring(with: m.range), max: 30))“, Intervall „\(iv.match)“", ns, src)]
            if let ir = (text as NSString).range(of: iv.match, options: .caseInsensitive) as NSRange?, ir.location != NSNotFound {
                out.append(KS.make(.paymentInterval, iv.value, 0.82, "Zahlungsintervall „\(iv.match)“ beim wiederkehrenden Betrag", ns, NSRange(location: tail.location + ir.location, length: ir.length)))
            }
            return out
        }
        return []
    }
}

struct InsuranceDetector: DocumentDetector {
    let kind = DocumentKind.insurance
    var replaces: Set<FactType> { [] }

    private static let title = Rx("(?<![\\p{L}])(versicherungsschein|versicherungspolice|policenbrief|versicherungsbestätigung|versicherungsnachweis|versicherungsvertrag|police|beitragsrechnung|beitragsanpassung|beitragsübersicht|nachtrag\\s{1,3}zum\\s{1,3}versicherungsschein|insurance\\s{1,3}(?:policy|certificate|schedule)|policy\\s{1,3}(?:schedule|document|certificate)|certificate\\s{1,3}of\\s{1,3}insurance|schadenmeldung)(?![\\p{L}])")
    private static let numberLabel = Rx("(?:versicherungsschein-?\\s?(?:nummer|nr)|versicherungs-?\\s?(?:nummer|nr)|polic(?:en|e)-?\\s?(?:nummer|nr)|polizzen-?\\s?(?:nummer|nr)|vers\\.?-?\\s?nr|policy\\s{1,3}(?:no|number|nr|#)|policy\\s{1,3}id)\\.?\\s{0,3}[:#|]?")
    private static let holder = Rx("(?<![\\p{L}])(versicherungsnehmer(?:in)?|policyholder|policy\\s{1,3}holder|versicherte\\s{1,3}person|versicherungsschutz|versicherungssumme|selbstbeteiligung|deckung(?:ssumme)?|coverage|deductible|sum\\s{1,3}insured)(?![\\p{L}])")
    private static let insurerLine = Rx("(?<![\\p{L}])(?i:[\\p{L}\\-]{0,30}versicherung[\\p{L}\\-]{0,30})(?:\\s{1,3}[\\p{L}\\-&.]{1,30}){0,3}\\s{1,3}(?:AG|SE|VVaG|a\\.G\\.|GmbH|Ltd\\.?|Inc\\.?|plc)(?![\\p{L}])|(?<![\\p{L}])[\\p{L}\\-]{1,30}\\s{1,3}(?i:insurance|assurance)\\s{1,3}(?i:co(?:mpany|\\.)?|ltd\\.?|inc\\.?|plc|ag|se)(?![\\p{L}])", caseInsensitive: false)
    private static let insurerLabel = Rx("(?<![\\p{L}])(?:versicherer|versicherungsgesellschaft|risikoträger|insurer|underwriter|insurance\\s{1,3}company)\\s{0,3}[:|]")
    private static let premiumLabel = Rx("(?<![\\p{L}])(zahlbeitrag|gesamtbeitrag|jahresbeitrag|monatsbeitrag|quartalsbeitrag|halbjahresbeitrag|jahresprämie|monatsprämie|beitrag|prämie|premium)(?![\\p{L}])")
    private static let intervalLabel = Rx("(?:zahlweise|zahlungsweise|zahlungsintervall|zahlungsmodus|payment\\s{1,3}(?:frequency|interval)|billing\\s{1,3}frequency)\\s{0,3}[:|]?")
    private static let startLabel = Rx("(?:versicherungsbeginn|vertragsbeginn|beginn\\s{1,3}des\\s{1,3}versicherungsschutzes|beginn\\s{1,3}der\\s{1,3}versicherung|beginn|gültig\\s{1,3}ab|policy\\s{1,3}start|start\\s{1,3}date|effective\\s{1,3}date|valid\\s{1,3}from|inception\\s{1,3}date)(?![\\p{L}])")
    private static let endLabel = Rx("(?:versicherungsablauf|versicherungsende|ablauf\\s{1,3}der\\s{1,3}versicherung|vertragsablauf|vertragsende|ablauf|ablaufdatum|gültig\\s{1,3}bis|policy\\s{1,3}end|end\\s{1,3}date|expiry\\s{1,3}date|expiration\\s{1,3}date|valid\\s{1,3}until|expires\\s{1,3}on)(?![\\p{L}])")
    private static let rangeLabel = Rx("(?:versicherungszeitraum|versicherungsperiode|versicherungsjahr|vertragslaufzeit|laufzeit|policy\\s{1,3}period|period\\s{1,3}of\\s{1,3}insurance|coverage\\s{1,3}period)\\s{0,3}[:|]?")
    private static let dueLabel = Rx("(?:hauptfälligkeit|nächste\\s{1,3}fälligkeit|fälligkeit(?:\\s{1,3}(?:der\\s{1,3})?(?:erst\\w{1,30}\\s{1,3})?(?:beitrag\\w{0,30}|zahlung))?|beitrag\\s{1,3}fällig(?:\\s{1,3}(?:am|zum))?|fällig(?:\\s{1,3}(?:am|zum|bis))?|next\\s{1,3}payment\\s{1,3}due|payment\\s{1,3}due(?:\\s{1,3}date)?|due\\s{1,3}date)\\s{0,3}[:|]?")
    private static let dateLabel = Rx("(?:ausstellungsdatum|ausgestellt\\s{1,3}am|datum|date\\s{1,3}of\\s{1,3}issue|issue\\s{1,3}date|date)\\s{0,3}[:|]")
    private static let ad = Rx("jetzt\\s{1,3}(?:wechseln|vergleichen|abschließen|berechnen|beitrag\\s{1,3}berechnen)|tarifrechner|vergleichsrechner|günstig\\w{0,30}\\s{1,3}(?:versicherung|tarif)|sparen\\s{1,3}sie|bis\\s{1,3}zu\\s{1,3}\\d+\\s?%\\s{1,3}(?:sparen|günstiger)|unverbindlich\\w{0,30}\\s{1,3}(?:angebot|vergleich)|get\\s{1,3}a\\s{1,3}quote|compare\\s{1,3}and\\s{1,3}save|switch\\s{1,3}and\\s{1,3}save")

    func score(_ ctx: ExtractionContext) -> KindScore {
        let (add, result) = scoreBuilder()
        let ns = ctx.ns
        let titleHit = KS.headline(InsuranceDetector.title, ctx)
        if let t = titleHit { add(0.3, "Überschrift Versicherungsschein/Police/Beitragsrechnung: „\(DMSRuleEngine.excerpt(t, max: 40))“") }
        let number = !KS.labeledTokens(InsuranceDetector.numberLabel, ns).isEmpty
        if number { add(0.25, "Policen-/Versicherungsscheinnummer mit Wert") }
        var holders = 0
        for m in InsuranceDetector.holder.all(ns) { holders += 1; if holders <= 2 { add(0.1, "Versicherungsbegriff „\(DMSRuleEngine.excerpt(ns.substring(with: m.range(at: 1)), max: 30))“") } }
        let insurer = InsuranceDetector.insurerLine.first(ns) != nil || !KS.labeledValues(InsuranceDetector.insurerLabel, ns).isEmpty
        if insurer { add(0.15, "Versicherer genannt") }
        let premium = InsuranceDetector.premium(ns)
        if premium != nil { add(0.15, "Beitrag mit Betrag") }
        if premium?.interval != nil { add(0.05, "Zahlweise genannt") }
        if !KS.dateAfter(InsuranceDetector.startLabel, ns, gap: 80).isEmpty { add(0.05, "Versicherungsbeginn mit Datum") }
        if !KS.dateAfter(InsuranceDetector.endLabel, ns, gap: 80).isEmpty || !KS.labeledDates(InsuranceDetector.rangeLabel, ns).filter({ $0.all.count >= 2 }).isEmpty { add(0.05, "Ablauf/Zeitraum mit Datum") }
        if newsletterRx.first(ns) != nil || newsletterRx.first(ctx.subjectNS) != nil { add(-0.35, "Newsletter-/Werbehinweis") }
        if promoRx.first(ns) != nil || promoRx.first(ctx.subjectNS) != nil || InsuranceDetector.ad.first(ns) != nil || InsuranceDetector.ad.first(ctx.subjectNS) != nil { add(-0.35, "Werbung/Vergleich/Tarifrechner (Versicherungswerbung)") }
        if phishingRx.first(ns) != nil { add(-0.3, "Phishing-/Spam-Muster") }
        var s = result(.insurance)
        s.primary = titleHit != nil || number
        return s.primary ? s : capped(s, at: 0.45, reason: "weder Versicherungsschein-Überschrift noch Policennummer")
    }

    /// Beitrag: spezifischste Beschriftung zuerst (Zahlbeitrag/Gesamtbeitrag vor Jahres-/Monatsbeitrag vor Beitrag/Prämie); Zahlweise aus Beschriftung, Zeile oder „Zahlweise:“-Zeile.
    static func premium(_ ns: NSString) -> (value: String, currency: String?, range: NSRange, label: String, interval: (value: String, match: String, range: NSRange?)?)? {
        var best: (rank: Int, hit: AmountHit, m: NSTextCheckingResult, region: NSRange)?
        for m in premiumLabel.all(ns) {
            let label = ns.substring(with: m.range(at: 1)).lowercased()
            // „Beitragsanpassung“ usw. sind keine Beiträge: der Wortrand im Muster verhindert sie
            guard let r = KS.region(after: m, in: ns, maxLen: 100),
                  let hit = ExtractionParsers.amounts(ns, range: r).first(where: { $0.currency != nil || $0.explicitDecimals }) else { continue }
            let rank = (label == "zahlbeitrag" || label == "gesamtbeitrag") ? 3 : label.hasSuffix("beitrag") && label != "beitrag" || label.hasSuffix("prämie") && label != "prämie" ? 2 : 1
            if best == nil || rank > best!.rank { best = (rank, hit, m, r) }
        }
        guard let b = best else { return nil }
        let label = ns.substring(with: b.m.range(at: 1))
        let premiumLineStart = ns.lineRange(for: NSRange(location: b.m.range.location, length: 0)).location
        let lineText = ns.substring(with: NSRange(location: premiumLineStart, length: min(ns.length - premiumLineStart, b.hit.range.location + b.hit.range.length - premiumLineStart + 40))).components(separatedBy: "\n")[0]
        var iv: (value: String, match: String, range: NSRange?)?
        if let f = ExtractionParsers.interval(in: lineText) {
            let r = (lineText as NSString).range(of: f.match, options: .caseInsensitive)
            iv = (f.value, f.match, r.location == NSNotFound ? nil : NSRange(location: premiumLineStart + r.location, length: r.length))
        } else if let m = intervalLabel.first(ns), let r = KS.region(after: m, in: ns, maxLen: 60), let f = ExtractionParsers.interval(in: ns.substring(with: r)) {
            let rr = (ns.substring(with: r) as NSString).range(of: f.match, options: .caseInsensitive)
            iv = (f.value, f.match, NSRange(location: r.location + rr.location, length: rr.length))
        }
        return (b.hit.value, b.hit.currency ?? KS.documentCurrency(ns), NSRange(location: b.m.range.location, length: b.hit.range.location + b.hit.range.length - b.m.range.location), label, iv)
    }

    func facts(_ ctx: ExtractionContext) -> [ExtractedFact] {
        let ns = ctx.ns
        var out: [ExtractedFact] = []
        if let v = KS.labeledValues(InsuranceDetector.insurerLabel, ns, maxLen: 100).first {
            out.append(KS.make(.insurer, KS.cutName(v.value), 0.85, "Versicherer: Beschriftung „\(DMSRuleEngine.excerpt(v.label, max: 30))“", ns, v.range))
        } else if let m = InsuranceDetector.insurerLine.first(ns) {
            let line = ns.lineRange(for: m.range)
            let full = ns.substring(with: line).trimmingCharacters(in: .whitespacesAndNewlines)
            let name = KS.cutName(full.count <= 80 ? full : ns.substring(with: m.range))
            out.append(KS.make(.insurer, name, 0.7, "Zeile mit Versicherungsunternehmen (Rechtsform)", ns, NSRange(location: line.location, length: min(line.length, (full as NSString).length))))
        }
        if let n = KS.labeledTokens(InsuranceDetector.numberLabel, ns).first {
            out.append(KS.make(.policyNumber, n.token, 0.9, "Policennummer: Beschriftung „\(DMSRuleEngine.excerpt(n.label, max: 30))“", ns, n.range))
        }
        if let p = InsuranceDetector.premium(ns) {
            out.append(KS.make(.premium, p.value, currency: p.currency, 0.85, "Beitrag: Beschriftung „\(DMSRuleEngine.excerpt(p.label, max: 30))“", ns, p.range))
            if let iv = p.interval { out.append(KS.make(.paymentInterval, iv.value, 0.8, "Zahlweise „\(iv.match)“ zum Beitrag", ns, iv.range)) }
        }
        out += PeriodFacts.facts(ns, start: InsuranceDetector.startLabel, end: InsuranceDetector.endLabel, range: InsuranceDetector.rangeLabel, what: "Versicherung")
        if let d = KS.dateAfter(InsuranceDetector.dueLabel, ns, gap: 10).first {
            out.append(KS.make(.dueDate, d.date.value, 0.88, "Fälligkeit: Beschriftung „\(DMSRuleEngine.excerpt(d.label, max: 40))“", ns, d.range))
        }
        if let d = KS.dateAfter(InsuranceDetector.dateLabel, ns, gap: 6).first {
            out.append(KS.make(.date, d.date.value, 0.85, "Ausstellungsdatum: Beschriftung „\(DMSRuleEngine.excerpt(d.label, max: 30))“", ns, d.range))
        }
        return out
    }
}
