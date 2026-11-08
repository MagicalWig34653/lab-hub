import Foundation

// WP-D7: Extraktor. Ablauf: allgemeine Fakten (alle Dokumente) -> Detektoren je Dokumentart bewerten -> Art wählen -> artspezifische Fakten.
// Voll ausgebaut ist `invoice`; `reminder` (damit Mahnungen nie als Rechnung zählen) und einfache Stichwort-Detektoren für weitere Arten sind enthalten.
// Weitere Arten: einen `DocumentDetector` in `DocumentExtractor.detectors` ergänzen, keine Schemaänderung.
// Regeln der Wahl: höchster Score gewinnt (Gleichstand: feste Detektor-Reihenfolge); ist `reminder` sicher, wird `invoice` auf 0,3 gedeckelt;
// unter `uncertainThreshold` gilt `other`. Alle Zahlen sind Konstanten im Code, keine Uhr, kein Zufall.

enum DocumentExtractor {
    static let maxChars = 200_000
    static let detectors: [any DocumentDetector] = [
        InvoiceDetector(), ReminderDetector(),
        KeywordDetector(kind: .receipt, strong: ["Kassenbon", "Kassenbeleg", "Quittung", "Kassenzettel", "Receipt", "Bon-?Nr"],
                        weak: ["Rückgeld", "Kartenzahlung", "EC-Karte", "Bar", "Zahlart", "Vielen Dank für Ihren Einkauf", "TSE", "Contactless"]),
        KeywordDetector(kind: .contract, strong: ["Vertrag", "Vereinbarung", "Contract", "Agreement", "Kündigungsfrist", "Vertragsbeginn", "Vertragspartner", "Laufzeit"],
                        weak: ["§", "Unterschrift", "Signature", "Parteien", "Kündigung", "Vertragsgegenstand", "Auftraggeber", "Auftragnehmer"]),
        KeywordDetector(kind: .insurance, strong: ["Versicherungsschein", "Versicherungsnummer", "Versicherung", "Police", "Policy", "Insurance", "Prämie", "Schadenmeldung"],
                        weak: ["Versicherungsnehmer", "Deckung", "Selbstbeteiligung", "Versicherungsschutz", "Beitrag", "Versicherungssumme"]),
        KeywordDetector(kind: .bankStatement, strong: ["Kontoauszug", "Bank statement", "Account statement", "Alter Kontostand", "Neuer Kontostand", "Opening balance", "Closing balance", "Buchungstag"],
                        weak: ["Valuta", "Umsatz", "Saldo", "BIC", "Buchungstext", "Haben", "Soll"]),
        KeywordDetector(kind: .taxNotice, strong: ["Finanzamt", "Steuerbescheid", "Einkommensteuerbescheid", "Steuernummer", "Steuererklärung", "Umsatzsteuer-Voranmeldung", "Tax notice"],
                        weak: ["Einspruch", "Veranlagung", "Festsetzung", "Nachzahlung", "Erstattung", "Steuerpflichtige"]),
        KeywordDetector(kind: .letter, strong: ["Rechtsbehelfsbelehrung", "Bußgeldbescheid", "Ordnungsamt", "Stadtverwaltung", "Gemeindeverwaltung", "Behörde", "Anhörung", "Widerspruch"],
                        weak: ["Bescheid", "Aktenzeichen", "Geschäftszeichen", "Verwarnung", "Verfahren"])
    ]

    static func extract(_ input: ExtractionInput) -> ExtractionResult {
        let text = input.text.count > maxChars ? String(input.text.prefix(maxChars)) : input.text
        let ns = text as NSString
        let subject = (input.subject ?? derivedSubject(ns))
        let general = Facts.general(ns, input: input, subject: subject)
        let ctx = ExtractionContext(input: input, ns: ns, subjectNS: (subject ?? "") as NSString, general: general)

        var scores = detectors.map { $0.score(ctx) }
        if let r = scores.first(where: { $0.kind == .reminder }), r.score >= ExtractionResult.certainThreshold,
           let i = scores.firstIndex(where: { $0.kind == .invoice }), scores[i].score > 0.3 {
            scores[i] = KindScore(kind: .invoice, score: 0.3, reasons: scores[i].reasons + ["gedeckelt auf 0,3: Mahnung erkannt (Mahnung ist keine Rechnung)"])
        }
        // stabile Sortierung: Score absteigend, Detektor-Reihenfolge bei Gleichstand
        let ordered = scores.enumerated().sorted { ($0.element.score, -$0.offset) > ($1.element.score, -$1.offset) }.map(\.element)
        let best = ordered[0]
        let kind: DocumentKind, score: Double, certain: Bool, reasons: [String]
        if best.score >= ExtractionResult.uncertainThreshold {
            kind = best.kind; score = best.score; certain = best.score >= ExtractionResult.certainThreshold; reasons = best.reasons
        } else {
            kind = .other; score = ((1 - best.score) * 1000).rounded() / 1000; certain = true
            reasons = ["Keine Dokumentart erreicht die Schwelle \(fmt(ExtractionResult.uncertainThreshold)) (beste: \(best.kind.rawValue) \(fmt(best.score)))"]
        }
        var facts = Facts.finalize(general, kind: kind)
        if let detector = detectors.first(where: { $0.kind == kind }) { facts += detector.facts(ctx) }
        facts.sort { (Facts.order($0.type), $0.source?.offset ?? -1, $0.value) < (Facts.order($1.type), $1.source?.offset ?? -1, $1.value) }
        return ExtractionResult(kind: kind, kindScore: score, kindCertain: certain, reasons: reasons, scores: ordered, facts: facts)
    }

    static func fmt(_ d: Double) -> String { String(format: "%.2f", d).replacingOccurrences(of: ".", with: ",") }

    private static let subjectRx = Rx("^(?:betreff|subject|betr\\.?)\\s*:\\s*(.{1,300})$", multiline: true)
    /// Mailtext beginnt mit „Betreff: …“ (so legt D7 ihn ab); sonst kein Betreff.
    static func derivedSubject(_ ns: NSString) -> String? {
        let head = ns.substring(to: min(ns.length, 600)) as NSString
        guard let m = subjectRx.first(head) else { return nil }
        return head.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespaces)
    }
}

// MARK: Detektoren

func scoreBuilder() -> (add: (Double, String) -> Void, result: (DocumentKind) -> KindScore) {
    final class Box: @unchecked Sendable { var total = 0.0; var reasons: [String] = [] }
    let box = Box()
    return ({ points, reason in box.total += points; box.reasons.append((points >= 0 ? "+" : "") + DocumentExtractor.fmt(points) + " " + reason) },
            { kind in KindScore(kind: kind, score: (max(0, min(1, box.total)) * 1000).rounded() / 1000, reasons: box.reasons) })
}

struct InvoiceDetector: DocumentDetector {
    let kind = DocumentKind.invoice
    private static let subjectWord = Rx("(?<![a-zäöü])(rechnung|invoice|faktura|rechnungs\\w*)(?![a-zäöü]{3})")
    private static let titleLine = Rx("^\\s*(rechnung|invoice|tax invoice|ausgangsrechnung|eingangsrechnung|rechnung\\s+(?:nr|nummer)[^\\n]{0,30})\\s*$", multiline: true)
    private static let strongLabel = Rx("rechnungs-?\\s?(?:nummer|nr|datum)|invoice\\s?(?:number|no|nr|date|#)|rechnung\\s+nr|re-?nr")
    private static let dueWords = Rx("fällig|zahlungsziel|zahlbar|due date|payment terms|zahlungsbedingungen|payment due")
    private static let taxWords = Rx("(?<![a-zäöü])(mwst|ust|umsatzsteuer|mehrwertsteuer|vat)(?![a-zäöü])")
    private static let payWords = Rx("bitte überweisen|überweisen sie|please pay|please remit|bankverbindung|bank details|zahlung an")
    private static let newsletter = Rx("newsletter|abmelden|unsubscribe|abbestellen|im browser ansehen|view in browser")
    private static let promo = Rx("gutschein|rabatt auf|% rabatt|% off|jetzt sichern|nur heute")
    private static let shipping = Rx("versandbestätigung|wurde versendet|ist unterwegs|sendungsnummer|sendungsverfolgung|tracking|shipping confirmation|has shipped|bestellbestätigung|order confirmation|lieferschein")
    private static let phishing = Rx("klicken sie hier|click here|konto (?:wurde )?gesperrt|account (?:has been )?(?:suspended|locked)|passwort|password|verify your|bestätigen sie ihre|öffnen sie den anhang|open the attachment|\\.zip|\\.exe")
    private static let senderHint = Rx("^(?:invoice|invoices|billing|rechnung|rechnungen|buchhaltung|accounting|faktura|ar)[@+.]")

    func score(_ ctx: ExtractionContext) -> KindScore {
        let (add, result) = scoreBuilder()
        let ns = ctx.ns
        if InvoiceDetector.subjectWord.first(ctx.subjectNS) != nil { add(0.2, "Betreff nennt Rechnung/Invoice") }
        if let s = ctx.input.sender, InvoiceDetector.senderHint.first(s as NSString) != nil { add(0.1, "Absenderadresse deutet auf Rechnungsversand") }
        if InvoiceDetector.titleLine.first(ns) != nil { add(0.2, "Zeile „Rechnung“/„Invoice“ als Überschrift") }
        let hasNumber = ctx.has(.invoiceNumber)
        if hasNumber { add(0.3, "Rechnungsnummer mit Wert gefunden") } else if InvoiceDetector.strongLabel.first(ns) != nil { add(0.12, "Rechnungs-Beschriftung ohne auswertbare Nummer") }
        if ctx.general.contains(where: { $0.type == FactType.amountGross.rawValue }) { add(0.15, "Gesamt-/Bruttobetrag mit Beschriftung") }
        if ctx.has(.amountNet), ctx.has(.amountTax) { add(0.1, "Netto und Steuer ausgewiesen") }
        if ctx.general.contains(where: { $0.type == FactType.date.rawValue && $0.reason.hasPrefix("Rechnungsdatum") }) { add(0.1, "Rechnungsdatum beschriftet") }
        if ctx.has(.dueDate) { add(0.1, "Fälligkeit/Zahlungsziel gefunden") } else if InvoiceDetector.dueWords.first(ns) != nil { add(0.05, "Zahlungsbedingungen erwähnt") }
        if ctx.has(.iban) { add(0.1, "IBAN mit gültiger Prüfsumme") }
        if ctx.has(.vatID) { add(0.05, "USt-ID im Format gültig") }
        if InvoiceDetector.taxWords.first(ns) != nil { add(0.05, "Steuerbegriff (MwSt/USt/VAT)") }
        if InvoiceDetector.payWords.first(ns) != nil { add(0.05, "Zahlungsaufforderung/Bankverbindung") }
        // Gegenindizien
        if InvoiceDetector.newsletter.first(ns) != nil || InvoiceDetector.newsletter.first(ctx.subjectNS) != nil { add(-0.3, "Newsletter-/Werbehinweis") }
        if InvoiceDetector.promo.first(ns) != nil || InvoiceDetector.promo.first(ctx.subjectNS) != nil { add(-0.15, "Werbehinweis (Gutschein/Rabatt)") }
        if InvoiceDetector.shipping.first(ns) != nil || InvoiceDetector.shipping.first(ctx.subjectNS) != nil { add(hasNumber ? -0.1 : -0.25, "Versand-/Bestellbestätigung") }
        if InvoiceDetector.phishing.first(ns) != nil { add(-0.3, "Phishing-/Spam-Muster (Link-Aufforderung, Passwort, Archivanhang)") }
        return result(.invoice)
    }

    func facts(_ ctx: ExtractionContext) -> [ExtractedFact] { [] }
}

struct ReminderDetector: DocumentDetector {
    let kind = DocumentKind.reminder
    private static let words: [(String, Rx)] = [
        ("Mahnung", Rx("mahnung|dunning")), ("Zahlungserinnerung", Rx("zahlungserinnerung|payment reminder|reminder of payment")),
        ("Zahlungsaufforderung", Rx("zahlungsaufforderung")), ("überfällig", Rx("überfällig|overdue|past due")),
        ("Mahngebühr", Rx("mahngebühr|mahnkosten|late fee|verzugszinsen|default interest")), ("Inkasso/Letzte Frist", Rx("inkasso|final notice|letzte mahnung|letzte aufforderung|collection agency"))]

    func score(_ ctx: ExtractionContext) -> KindScore {
        let (add, result) = scoreBuilder()
        var hits = 0
        for (label, rx) in ReminderDetector.words where rx.first(ctx.ns) != nil || rx.first(ctx.subjectNS) != nil { hits += 1; if hits <= 3 { add(0.35, "Stichwort „\(label)“") } }
        if hits > 0, ReminderDetector.words[0].1.first(ctx.subjectNS) != nil { add(0.15, "Betreff nennt Mahnung") }
        if hits > 0, ctx.has(.invoiceNumber) || ctx.has(.amountGross) { add(0.1, "Bezug auf Rechnungsnummer/Betrag") }
        return result(.reminder)
    }
}

struct KeywordDetector: DocumentDetector {
    let kind: DocumentKind
    private let strong: [(String, Rx)]
    private let weak: [(String, Rx)]

    init(kind: DocumentKind, strong: [String], weak: [String]) {
        func rx(_ w: String) -> Rx { Rx(w == "§" ? "§" : "(?<![a-zäöüß])" + w + "(?![a-zäöüß])") }
        self.kind = kind
        self.strong = strong.map { ($0, rx($0)) }
        self.weak = weak.map { ($0, rx($0)) }
    }

    func score(_ ctx: ExtractionContext) -> KindScore {
        let (add, result) = scoreBuilder()
        var s = 0, w = 0
        for (label, rx) in strong where rx.first(ctx.ns) != nil || rx.first(ctx.subjectNS) != nil { s += 1; if s <= 3 { add(0.35, "Stichwort „\(label)“") } }
        for (label, rx) in weak where rx.first(ctx.ns) != nil { w += 1; if w <= 4 { add(0.12, "Hinweis „\(label)“") } }
        return result(kind)
    }
}
