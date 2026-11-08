import Foundation

// WP-D8: Kontoauszug und Kassenbon. Salden sind vorzeichenbehaftet (Soll/Minus = negativ). Eine reine Benachrichtigung („Ihr Kontoauszug liegt bereit“) ohne Auszugsinhalt
// bleibt unter der Schwelle (kein Saldo, keine Buchungszeilen, keine IBAN).

struct BankStatementDetector: DocumentDetector {
    let kind = DocumentKind.bankStatement
    var replaces: Set<FactType> { [.amount] }

    private static let title = Rx("(?<![\\p{L}])(kontoauszug|tagesauszug|kontoumsätze|umsatzübersicht|account\\s+statement|bank\\s+statement|statement\\s+of\\s+account|kreditkartenabrechnung|credit\\s+card\\s+statement)(?![\\p{L}])")
    private static let opening = Rx("(?<![\\p{L}])(?:alter\\s+kontostand|kontostand\\s+alt|anfangssaldo|anfangsbestand|saldovortrag|saldo\\s+vortrag|saldo\\s+alt|alter\\s+saldo|saldo\\s+zum\\s+(?:beginn|vortag)|opening\\s+balance|balance\\s+brought\\s+forward|previous\\s+balance|starting\\s+balance|beginning\\s+balance)(?![\\p{L}])")
    private static let closing = Rx("(?<![\\p{L}])(?:neuer\\s+kontostand|kontostand\\s+neu|endsaldo|schlusssaldo|endbestand|saldo\\s+neu|neuer\\s+saldo|saldo\\s+zum\\s+ende|saldo\\s+am\\s+ende|closing\\s+balance|ending\\s+balance|new\\s+balance|final\\s+balance|end\\s+balance|aktueller\\s+kontostand)(?![\\p{L}])")
    private static let balanceGeneric = Rx("(?<![\\p{L}])(?:kontostand(?:\\s+am)?|saldo)(?![\\p{L}])")
    private static let periodRange = Rx("(?:abrechnungszeitraum|auszugszeitraum|buchungszeitraum|zeitraum|statement\\s+period|period|für\\s+den\\s+zeitraum|umsätze\\s+(?:vom|von))\\s*[:|]?")
    private static let statementDate = Rx("(?:auszugsdatum|kontoauszug\\s+vom|statement\\s+date|erstellt\\s+am|stand|datum|date)\\s*[:|]?")
    private static let posting = Rx("^[ \\t]*(?:\\d{1,2}\\.\\d{1,2}\\.(?:\\d{2,4})?|\\d{4}-\\d{2}-\\d{2})\\s+.{3,}?\\s[-+−–]?\\d[\\d.,']*\\s?(?:€|EUR|[-+SH])?[ \\t]*$", multiline: true)
    private static let postingHead = Rx("buchungstag|valuta|buchungstext|verwendungszweck|umsatz|booking\\s+date|value\\s+date|description|zahlungsempfänger|auftraggeber")
    private static let notification = Rx("liegt\\s+(?:für\\s+sie\\s+)?(?:zum\\s+abruf\\s+)?bereit|steht\\s+(?:für\\s+sie\\s+)?(?:zum\\s+(?:abruf|download)\\s+)?bereit|im\\s+(?:online-?banking|postfach|banking-?postfach)|jetzt\\s+(?:einsehen|abrufen|ansehen)|zum\\s+abruf|ready\\s+to\\s+(?:view|download)|available\\s+(?:in|on)\\s+your\\s+online|log\\s?in\\s+to\\s+(?:view|see)|melden\\s+sie\\s+sich\\s+an|neue\\s+nachricht")

    func score(_ ctx: ExtractionContext) -> KindScore {
        let (add, result) = scoreBuilder()
        let ns = ctx.ns
        let titleHit = KS.headline(BankStatementDetector.title, ctx)
        if let t = titleHit { add(0.3, "Überschrift „\(DMSRuleEngine.excerpt(t, max: 40))“") }
        let hasIBAN = ctx.has(.iban)
        if hasIBAN { add(0.12, "IBAN mit gültiger Prüfsumme") }
        let o = BankStatementDetector.balance(BankStatementDetector.opening, ns) != nil
        let c = BankStatementDetector.balance(BankStatementDetector.closing, ns) != nil || KS.labeledAmounts(BankStatementDetector.balanceGeneric, ns).first != nil
        if o && c { add(0.35, "Anfangs- und Endsaldo") } else if o || c { add(0.15, "Saldo (nur einer von beiden)") }
        let postings = BankStatementDetector.posting.all(ns).count
        if postings >= 4 { add(0.2, "\(postings) Buchungszeilen (Datum, Text, Betrag)") } else if postings >= 2 { add(0.1, "\(postings) Buchungszeilen") }
        if BankStatementDetector.postingHead.all(ns).count >= 2 { add(0.1, "Tabellenkopf (Buchungstag/Valuta/Verwendungszweck)") }
        if !KS.labeledDates(BankStatementDetector.periodRange, ns).filter({ $0.all.count >= 2 }).isEmpty { add(0.1, "Zeitraum mit zwei Daten") }
        if newsletterRx.first(ns) != nil || newsletterRx.first(ctx.subjectNS) != nil { add(-0.3, "Newsletter-/Werbehinweis") }
        if BankStatementDetector.notification.first(ns) != nil || BankStatementDetector.notification.first(ctx.subjectNS) != nil { add(-0.25, "Benachrichtigung (Abruf im Online-Banking), kein Auszugsinhalt") }
        if phishingRx.first(ns) != nil { add(-0.3, "Phishing-/Spam-Muster") }
        var s = result(.bankStatement)
        let structure = o || c || postings >= 2
        s.primary = titleHit != nil && structure
        return structure ? s : capped(s, at: 0.3, reason: "kein Saldo und keine Buchungszeilen (nur Benachrichtigung/Erwähnung)")
    }

    /// Betrag mit Vorzeichen hinter einer Saldo-Beschriftung (Soll/Minus = negativ).
    static func balance(_ rx: Rx, _ ns: NSString) -> KS.SignedAmount? {
        KS.labeledAmounts(rx, ns).first
    }

    func facts(_ ctx: ExtractionContext) -> [ExtractedFact] {
        let ns = ctx.ns
        var out: [ExtractedFact] = []
        func signed(_ a: KS.SignedAmount, _ type: FactType, _ conf: Double, _ what: String) -> ExtractedFact {
            KS.make(type, a.value, currency: a.currency ?? KS.documentCurrency(ns), conf, "\(what): Beschriftung „\(DMSRuleEngine.excerpt(a.label, max: 30))“\(a.negative ? ", Soll/Minus (negativ)" : "")", ns, a.range)
        }
        if let a = BankStatementDetector.balance(BankStatementDetector.opening, ns) { out.append(signed(a, .balanceOpening, 0.88, "Anfangssaldo")) }
        var closing = BankStatementDetector.balance(BankStatementDetector.closing, ns)
        var closingConf = 0.88
        if closing == nil {
            // „Kontostand“/„Saldo“ ohne alt/neu gilt als Endsaldo, wenn kein Anfangssaldo gleicher Fundstelle ist
            let opening = BankStatementDetector.balance(BankStatementDetector.opening, ns)
            closing = KS.labeledAmounts(BankStatementDetector.balanceGeneric, ns).first(where: { $0.range.location != opening?.range.location })
            closingConf = 0.6
        }
        if let a = closing { out.append(signed(a, .balanceClosing, closingConf, closingConf < 0.7 ? "Endsaldo (unbeschriftet als „Kontostand/Saldo“)" : "Endsaldo")) }
        out += PeriodFacts.facts(ns, start: Rx("(?:zeitraum\\s+von|umsätze\\s+vom|von)(?![\\p{L}])"), end: Rx("(?:\\bbis\\b)(?![\\p{L}])"), range: BankStatementDetector.periodRange, what: "Kontoauszug")
            .filter { $0.reason.contains("Beschriftung „Zeitraum") || $0.reason.contains("Beschriftung „Abrechnungszeitraum") || $0.reason.contains("Beschriftung „Auszugszeitraum") || $0.reason.contains("Beschriftung „Buchungszeitraum") || $0.reason.contains("Beschriftung „Statement period") || $0.reason.contains("Beschriftung „Period") || $0.reason.contains("Beschriftung „für den Zeitraum") || $0.reason.contains("Beschriftung „Umsätze") }
        if let d = KS.dateAfter(BankStatementDetector.statementDate, ns, gap: 6).first {
            out.append(KS.make(.date, d.date.value, 0.85, "Auszugsdatum: Beschriftung „\(DMSRuleEngine.excerpt(d.label.trimmingCharacters(in: .whitespaces), max: 30))“", ns, d.range))
        } else if let e = out.first(where: { $0.type == FactType.periodEnd.rawValue }) {
            out.append(ExtractedFact(.date, value: e.value, confidence: 0.6, reason: "abgeleitet: Ende des Auszugszeitraums", source: e.source))
        }
        return out
    }
}

struct ReceiptDetector: DocumentDetector {
    let kind = DocumentKind.receipt
    var replaces: Set<FactType> { [.amount] }

    private static let title = Rx("^\\W*(?:[\\p{L}\\-]+\\s+){0,2}(kassenbon|kassenbeleg|kassenzettel|bon|quittung|zahlungsbeleg|kundenbeleg|kundenquittung|receipt|sales\\s+receipt|till\\s+receipt|customer\\s+copy)(?![\\p{L}])")
    private static let bonNumber = Rx("(?:bon-?\\s?(?:nr|nummer)|quittung\\s+(?:nr|nummer)|bonnummer|beleg-?\\s?(?:nr|nummer)|kassenbeleg-?\\s?(?:nr|nummer)|receipt\\s+(?:no|number|nr|#)|trans(?:action)?\\s+(?:no|nr|id|#)|transaktions-?\\s?(?:nr|nummer))\\.?\\s*[:#|]?")
    private static let sumLabel = Rx("(?<![\\p{L}])(?:summe|gesamtsumme|gesamt|total|zu\\s+zahlen|zahlbetrag|gesamtbetrag|endbetrag|betrag|amount|sum|total\\s+due)(?![\\p{L}])")
    private static let subtotal = Rx("zwischensumme|subtotal|teilsumme")
    private static let taxLine = Rx("(?:(?:mwst|ust|steuer|vat|tax|mw\\.?st\\.?)\\s*)?(?:[A-D]\\s+)?(7|19)(?:[,.]0{1,2})?\\s?%")
    private static let change = Rx("(?<![\\p{L}])(?:rückgeld|wechselgeld|change(?:\\s+due)?|cash\\s+tendered|gegeben)(?![\\p{L}])")
    private static let payLabel = Rx("(?:zahlart|zahlungsart|bezahlt\\s+mit|payment(?:\\s+method)?|paid\\s+by|tender)\\s*[:|]?")
    private static let tse = Rx("(?<![\\p{L}])(?:tse|seriennummer\\s+kasse|kassen-?seriennummer|kassenid|kasse\\s+\\d|kassierer|bediener|filiale|terminal-?id|trace-?nr)(?![\\p{L}])")
    private static let thanks = Rx("vielen\\s+dank\\s+für\\s+ihren\\s+(?:einkauf|besuch)|danke\\s+für\\s+ihren\\s+einkauf|thank\\s+you\\s+for\\s+(?:shopping|your\\s+purchase|your\\s+visit)|bis\\s+bald")
    private static let itemLine = Rx("^[ \\t]*(?:\\d+\\s?x?\\s?)?[\\p{L}][^\\n]{1,40}?\\s+\\d{1,4}[,.]\\d{2}\\s?(?:€|EUR|[A-D])?[ \\t]*$", multiline: true)
    private static let invoiceMarks = Rx("rechnungs-?\\s?(?:nummer|nr)|invoice\\s+(?:number|no)|zahlungsziel|zahlbar\\s+(?:bis|innerhalb)|bitte\\s+überweisen|payment\\s+terms|due\\s+date")
    private static let orderMarks = Rx("bestellbestätigung|versandbestätigung|order\\s+confirmation|bestellnummer|wurde\\s+versendet|sendungsverfolgung|lieferung\\s+in|tracking")

    func score(_ ctx: ExtractionContext) -> KindScore {
        let (add, result) = scoreBuilder()
        let ns = ctx.ns
        let titleHit = KS.headline(ReceiptDetector.title, ctx)
        if let t = titleHit { add(0.3, "Überschrift/Betreff „\(DMSRuleEngine.excerpt(t, max: 40))“") }
        let bon = !KS.labeledTokens(ReceiptDetector.bonNumber, ns).isEmpty
        if bon { add(0.15, "Bon-/Belegnummer mit Wert") }
        let sum = ReceiptDetector.total(ns) != nil
        if sum { add(0.15, "Summe/Gesamt mit Betrag") }
        let taxes = ReceiptDetector.taxShares(ns)
        if ReceiptDetector.taxLine.first(ns) != nil { add(0.1, "Steuersatz 7 %/19 %") }
        let pay = ReceiptDetector.paymentMethod(ns)
        if pay != nil { add(0.15, "Zahlart erkennbar") }
        if ReceiptDetector.change.first(ns) != nil { add(0.1, "Rückgeld/Wechselgeld") }
        if ReceiptDetector.tse.first(ns) != nil { add(0.08, "Kassen-/TSE-/Filialangabe") }
        if ReceiptDetector.thanks.first(ns) != nil { add(0.05, "Dankesformel am Bonende") }
        let items = ReceiptDetector.itemLine.all(ns).count
        if items >= 3 { add(0.1, "\(items) Artikelzeilen (Text, Preis)") }
        _ = taxes
        if ReceiptDetector.invoiceMarks.first(ns) != nil { add(-0.3, "Rechnungsmerkmale (Rechnungsnummer/Zahlungsziel/Überweisung): eher Rechnung") }
        if ReceiptDetector.orderMarks.first(ns) != nil { add(-0.25, "Bestell-/Versandbestätigung") }
        if newsletterRx.first(ns) != nil || newsletterRx.first(ctx.subjectNS) != nil { add(-0.35, "Newsletter-/Werbehinweis") }
        if phishingRx.first(ns) != nil { add(-0.3, "Phishing-/Spam-Muster") }
        var s = result(.receipt)
        s.primary = titleHit != nil || bon
        return s.primary ? s : capped(s, at: 0.45, reason: "weder Kassenbon-Überschrift noch Bon-/Belegnummer")
    }

    /// Summe: Beschriftung mit Betrag; Zwischensummen zählen nicht. Bei mehreren Treffern der letzte (am Bonende), sonst der größte beschriftete.
    static func total(_ ns: NSString) -> (value: String, currency: String?, range: NSRange, label: String)? {
        let hits = KS.labeledAmounts(sumLabel, ns).filter { a in
            let pre = ns.substring(with: NSRange(location: max(0, a.range.location - 12), length: min(12, a.range.location)))
            return subtotal.first(pre as NSString) == nil && !a.line.lowercased().contains("zwischensumme") && !a.negative
        }
        guard !hits.isEmpty else { return nil }
        // „Summe“ und „zu zahlen“ vor „Gesamt“/„Betrag“; unter gleichen Rängen der letzte Treffer
        func rank(_ l: String) -> Int { let x = l.lowercased(); return x.contains("summe") || x.contains("zu zahlen") || x.contains("total") || x.contains("zahlbetrag") || x == "sum" ? 2 : 1 }
        let best = hits.enumerated().max { (rank($0.element.label), $0.offset) < (rank($1.element.label), $1.offset) }!.element
        return (best.value, best.currency ?? KS.documentCurrency(ns), best.range, best.label)
    }

    static func taxShares(_ ns: NSString) -> [(rate: Int, value: String, currency: String?, range: NSRange)] {
        var out: [(Int, String, String?, NSRange)] = []
        for m in taxLine.all(ns) {
            let rate = Int(ns.substring(with: m.range(at: 1))) ?? 0
            let end = m.range.location + m.range.length
            let probe = NSRange(location: end, length: min(120, ns.length - end))
            let nl = ns.range(of: "\n", options: [], range: probe)
            let rest = NSRange(location: end, length: nl.location == NSNotFound ? probe.length : nl.location - end)
            let hits = ExtractionParsers.amounts(ns, range: rest).filter { $0.explicitDecimals }
            guard !hits.isEmpty else { continue }
            // enthält die Zeile „netto“ vor dem ersten Betrag, ist der Steueranteil der Betrag hinter „MwSt/Steuer“
            let line = ns.substring(with: rest).lowercased()
            var pick = hits[0]
            if line.contains("netto") || line.contains("net "), let tr = line.range(of: "(?:mwst|ust|steuer|vat|tax)", options: .regularExpression) {
                let off = line.distance(from: line.startIndex, to: tr.upperBound)
                if let h = hits.first(where: { $0.range.location - rest.location >= off }) { pick = h }
            }
            if !out.contains(where: { $0.0 == rate }) { out.append((rate, pick.value, pick.currency, NSRange(location: m.range.location, length: pick.range.location + pick.range.length - m.range.location))) }
        }
        return out.filter { $0.0 == 7 || $0.0 == 19 }
    }

    static func paymentMethod(_ ns: NSString) -> (value: String, range: NSRange, why: String)? {
        let rules: [(String, Rx)] = [
            ("debit_card", Rx("girocard|ec-?karte|ec-?cash|maestro|debitkarte|debit\\s+card|v\\s?pay")),
            ("credit_card", Rx("(?<![\\p{L}])(?:visa|mastercard|master\\s+card|amex|american\\s+express|kreditkarte|credit\\s+card)(?![\\p{L}])")),
            ("paypal", Rx("paypal")),
            ("card", Rx("kartenzahlung|card\\s+payment|kontaktlos|contactless|(?<![\\p{L}])karte(?![\\p{L}])|(?<![\\p{L}])card(?![\\p{L}])")),
            ("cash", Rx("^[ \\t]*(?:bar(?:zahlung)?|bargeld|cash)\\s*[:]?\\s*(?:eur\\s*|€\\s*)?\\d|(?<![\\p{L}])(?:rückgeld|wechselgeld)(?![\\p{L}])|(?:zahlart|zahlungsart|bezahlt\\s+mit|payment(?:\\s+method)?|paid\\s+by)\\s*[:|]?\\s*(?:bar|cash)(?![\\p{L}])"))]
        for (value, rx) in rules {
            let multi = value == "cash" ? Rx(rx.re.pattern, multiline: true) : rx
            if let m = multi.first(ns) { return (value, m.range, "Zahlart „\(DMSRuleEngine.excerpt(ns.substring(with: m.range).trimmingCharacters(in: .whitespacesAndNewlines), max: 30))“") }
        }
        return nil
    }

    func facts(_ ctx: ExtractionContext) -> [ExtractedFact] {
        let ns = ctx.ns
        var out: [ExtractedFact] = []
        // Händler: Rechtsform-Zeile (allgemeiner Fakt bleibt), sonst erste Textzeile, die kein Titel/Datum/Betrag ist
        if !ctx.has(.seller) {
            for l in KS.lines(ns, limit: 8) {
                let t = l.text.trimmingCharacters(in: .whitespaces)
                if t.count < 3 || t.count > 60 || ReceiptDetector.title.first(t as NSString) != nil || ReceiptDetector.invoiceMarks.first(t as NSString) != nil { continue }
                if t.range(of: "^[\\p{L}][\\p{L}0-9 &.,'’\\-]+$", options: .regularExpression) == nil || ExtractionParsers.dates(t as NSString).count > 0 { continue }
                out.append(KS.make(.seller, KS.cutName(t), 0.5, "Händler: erste Textzeile des Bons (Zeile \(l.index + 1))", ns, l.range)); break
            }
        }
        if let d = ExtractionParsers.dates(ns).first, d.range.location < 600 || ReceiptDetector.thanks.first(ns) == nil {
            let lr = ns.lineRange(for: d.range)
            let line = ns.substring(with: lr)
            let time = line.range(of: "\\d{1,2}:\\d{2}", options: .regularExpression) != nil
            out.append(KS.make(.date, d.value, time ? 0.85 : 0.7, "Datum des Bons\(time ? " (mit Uhrzeit in derselben Zeile)" : "")", ns, d.range))
        }
        if let t = ReceiptDetector.total(ns) {
            out.append(KS.make(.amount, t.value, currency: t.currency, 0.88, "Summe: Beschriftung „\(DMSRuleEngine.excerpt(t.label, max: 30))“", ns, t.range))
        }
        for s in ReceiptDetector.taxShares(ns) {
            out.append(KS.make(s.rate == 7 ? .amountTax7 : .amountTax19, s.value, currency: s.currency ?? KS.documentCurrency(ns), 0.8, "Steueranteil \(s.rate) %", ns, s.range))
        }
        if let p = ReceiptDetector.paymentMethod(ns) {
            out.append(KS.make(.paymentMethod, p.value, 0.8, p.why, ns, p.range))
        }
        return out
    }
}
