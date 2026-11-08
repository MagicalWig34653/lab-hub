import Foundation

// WP-D7: Extraktor. Ablauf: allgemeine Fakten (alle Dokumente) -> Detektoren je Dokumentart bewerten -> Art wählen -> artspezifische Fakten.
// Voll ausgebaut ist `invoice`; `reminder` (damit Mahnungen nie als Rechnung zählen) und einfache Stichwort-Detektoren für weitere Arten sind enthalten.
// Weitere Arten: einen `DocumentDetector` in `DocumentExtractor.detectors` ergänzen, keine Schemaänderung.
// Regeln der Wahl: höchster Score gewinnt (Gleichstand: feste Detektor-Reihenfolge); ist `reminder` sicher, wird `invoice` auf 0,3 gedeckelt;
// unter `uncertainThreshold` gilt `other`. Alle Zahlen sind Konstanten im Code, keine Uhr, kein Zufall.

// WP-H10 (ReDoS-Härtung): (1) Whitespace-Läufe werden vor der Extraktion auf höchstens 3 Zeichen gekappt (`normalize`), (2) alle Etikett-Muster nutzen begrenzte
// Quantoren (`\\s{0,3}`, `[ \\t]{0,3}`, keine verschachtelten offenen Quantoren), (3) der Text wird auf `maxChars` (50 000) begrenzt, (4) die ganze Extraktion läuft unter einer
// harten Frist (`ExtractionDeadline`, Standard 5 s, `DMS_EXTRACT_TIMEOUT_MS` 50…30000): jeder Regex-Lauf meldet Fortschritt und bricht nach Fristablauf ab.
// Ablauf der Frist: Ergebnis `other`, unsicher, Grund `extraction_timeout`, keine Fakten; der Aufrufer (Ingest, Mail-Poll) läuft normal weiter.
// Fundstellen-Offsets (`FactSource`) beziehen sich auf den normalisierten Text.

enum DocumentExtractor {
    /// Obergrenze des ausgewerteten Textes nach der Normalisierung (50 000 Zeichen reichen für Briefe/Rechnungen; mehr Text ist fast immer Anhang/Rauschen).
    static let maxChars = 50_000
    /// Der Rohtext wird vor der Normalisierung auf diese Zahl Unicode-Zeichen begrenzt (Speicher/Zeit der Normalisierung selbst).
    static let maxRawScalars = 600_000
    static let defaultTimeout: TimeInterval = 5.0
    static let timeoutReason = "extraction_timeout"

    static var timeout: TimeInterval {
        if let raw = ProcessInfo.processInfo.environment["DMS_EXTRACT_TIMEOUT_MS"], let ms = Int(raw), (50...30_000).contains(ms) { return Double(ms) / 1000 }
        return defaultTimeout
    }

    /// Kappt jeden zusammenhängenden Whitespace-Lauf auf höchstens 3 Zeichen. Läufe bis 3 Zeichen bleiben unverändert; längere Läufe mit Zeilenumbruch werden zu
    /// höchstens zwei Umbrüchen plus höchstens drei Leerzeichen Einrückung (Absatz und Einrückung der nächsten Zeile bleiben erhalten), ohne Umbruch zu höchstens drei Leerzeichen.
    static func normalize(_ text: String) -> String {
        var out = String.UnicodeScalarView()
        var run: [Unicode.Scalar] = []
        func flush() {
            defer { run.removeAll(keepingCapacity: true) }
            if run.count <= 3 { out.append(contentsOf: run); return }
            var newlines = 0, indent = 0, previous: Unicode.Scalar = " "
            for c in run {
                switch c {
                case "\n": if previous != "\r" { newlines += 1 }; indent = 0
                case "\r", "\u{2028}", "\u{2029}", "\u{85}", "\u{0B}", "\u{0C}": newlines += 1; indent = 0
                default: indent += 1
                }
                previous = c
            }
            if newlines == 0 { out.append(contentsOf: [Unicode.Scalar](repeating: " ", count: 3)); return }
            out.append(contentsOf: [Unicode.Scalar](repeating: "\n", count: min(newlines, 2)))
            out.append(contentsOf: [Unicode.Scalar](repeating: " ", count: min(indent, 3)))
        }
        for c in text.unicodeScalars.prefix(maxRawScalars) {
            if c.properties.isWhitespace { run.append(c) } else { flush(); out.append(c) }
        }
        flush()
        return String(out)
    }

    /// Reihenfolge = Rangfolge bei Gleichstand (WP-D8: Mahnung vor den übrigen Arten, Rechnung zuerst).
    static let detectors: [any DocumentDetector] = [
        InvoiceDetector(), ReminderDetector(), ReceiptDetector(), ContractDetector(), InsuranceDetector(), BankStatementDetector(),
        AuthorityDetector(kind: .taxNotice), AuthorityDetector(kind: .letter)
    ]

    private static let invoiceBlockers: Set<DocumentKind> = [.receipt, .bankStatement, .taxNotice, .letter]

    /// Läuft unter einer harten Frist (`timeout`); bei Ablauf siehe `timeoutResult`.
    static func extract(_ input: ExtractionInput, timeout: TimeInterval = DocumentExtractor.timeout) -> ExtractionResult {
        let (result, expired) = ExtractionDeadline.run(timeout: timeout) { compute(input) }
        return expired ? timeoutResult : result
    }

    static var timeoutResult: ExtractionResult {
        ExtractionResult(kind: .other, kindScore: 0, kindCertain: false, reasons: [timeoutReason], scores: [KindScore(kind: .other, score: 0, reasons: [timeoutReason])], facts: [], timedOut: true)
    }

    private static func compute(_ input: ExtractionInput) -> ExtractionResult {
        let normalized = normalize(input.text)
        let text = normalized.count > maxChars ? String(normalized.prefix(maxChars)) : normalized
        let ns = text as NSString
        let subject = (input.subject ?? derivedSubject(ns))
        let general = Facts.general(ns, input: input, subject: subject)
        let ctx = ExtractionContext(input: input, ns: ns, subjectNS: (subject ?? "") as NSString, general: general)

        let scores = resolve(detectors.map { $0.score(ctx) }, ctx: ctx)
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
        if let detector = ownDetector(kind, best: best) {
            let own = detector.facts(ctx)
            let replaced = Set(detector.replaces.map(\.rawValue)).intersection(own.map(\.type))
            facts = facts.filter { !replaced.contains($0.type) } + own
        }
        facts = dedupe(facts)
        facts.sort { (Facts.order($0.type), $0.source?.offset ?? -1, $0.value) < (Facts.order($1.type), $1.source?.offset ?? -1, $1.value) }
        return ExtractionResult(kind: kind, kindScore: score, kindCertain: certain, reasons: reasons, scores: ordered, facts: facts)
    }

    private static func ownDetector(_ kind: DocumentKind, best: KindScore) -> (any DocumentDetector)? {
        detectors.first { $0.kind == kind }
    }

    /// Gleicher Typ + gleicher Wert nur einmal (höchste Konfidenz bleibt, die Begründungen der anderen Fundstellen entfallen).
    static func dedupe(_ facts: [ExtractedFact]) -> [ExtractedFact] {
        var best: [String: ExtractedFact] = [:]
        var orderKeys: [String] = []
        for f in facts {
            let key = f.type + "\u{1}" + f.value
            if let old = best[key] { if f.confidence > old.confidence { best[key] = f } } else { best[key] = f; orderKeys.append(key) }
        }
        return orderKeys.map { best[$0]! }
    }

    /// Konfliktregeln zwischen den Arten (alle Zahlen sind Konstanten, jede Deckelung steht in der Begründung):
    /// 1. Mahnung (sicher) deckelt Rechnung auf 0,3. 2. Behörde mit Bescheid-Kennzeichen (sicher) deckelt Mahnung auf 0,5 und Rechnung auf 0,3 („Mahnung der Behörde“ bleibt Behördenschreiben).
    /// 3. Kassenbon/Kontoauszug (sicher, eigene Überschrift) deckelt Rechnung auf 0,3, sofern keine Rechnungsnummer im Text steht. 4. Ist Rechnung oder Mahnung sicher, werden Arten ohne eigene Struktur
    /// (`primary == false`) auf 0,3 gedeckelt. 5. Versicherung (sicher, eigene Überschrift/Policennummer) deckelt Vertrag auf 0,5 (Versicherungsvertrag ist eine Versicherung).
    static func resolve(_ input: [KindScore], ctx: ExtractionContext) -> [KindScore] {
        var s = input
        func idx(_ k: DocumentKind) -> Int? { s.firstIndex { $0.kind == k } }
        func cap(_ k: DocumentKind, _ limit: Double, _ why: String) {
            if let i = idx(k) { s[i] = capped(s[i], at: limit, reason: why) }
        }
        let certain = ExtractionResult.certainThreshold
        if let r = idx(.reminder), s[r].score >= certain { cap(.invoice, 0.3, "Mahnung erkannt (Mahnung ist keine Rechnung)") }
        let authority = s.filter { ($0.kind == .taxNotice || $0.kind == .letter) && $0.primary && $0.score >= certain }
        if !authority.isEmpty {
            cap(.reminder, 0.5, "Behördenschreiben mit Bescheid-/Aktenzeichen-Kennzeichen (Mahnung der Behörde bleibt Behördenschreiben)")
            cap(.invoice, 0.3, "Behördenschreiben erkannt")
        }
        if !ctx.has(.invoiceNumber) {
            for k in [DocumentKind.receipt, .bankStatement] { if let i = idx(k), s[i].primary, s[i].score >= certain { cap(.invoice, 0.3, "\(k.rawValue) mit eigener Überschrift erkannt, keine Rechnungsnummer") } }
        }
        let invoiceOrReminderCertain = [DocumentKind.invoice, .reminder].contains { k in idx(k).map { s[$0].score >= certain } ?? false }
        if invoiceOrReminderCertain {
            for k in [DocumentKind.contract, .insurance, .bankStatement, .receipt, .taxNotice, .letter] {
                if let i = idx(k), !s[i].primary { s[i] = capped(s[i], at: 0.3, reason: "Rechnung/Mahnung erkannt, die Art hat keine eigene Struktur (Überschrift/Kennung)") }
            }
        }
        if let i = idx(.insurance), s[i].primary, s[i].score >= certain { cap(.contract, 0.5, "Versicherungsschein/Police erkannt (Versicherungsvertrag ist eine Versicherung)") }
        return s
    }

    static func fmt(_ d: Double) -> String { String(format: "%.2f", d).replacingOccurrences(of: ".", with: ",") }

    private static let subjectRx = Rx("^(?:betreff|subject|betr\\.?)\\s{0,3}:\\s{0,3}(.{1,300})$", multiline: true)
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
    private static let subjectWord = Rx("(?<![a-zäöü])(rechnung|invoice|faktura|rechnungs\\w{0,30})(?![a-zäöü]{3})")
    private static let titleLine = Rx("^[ \\t]{0,3}(rechnung|invoice|tax invoice|ausgangsrechnung|eingangsrechnung|rechnung[ \\t]{1,3}(?:nr|nummer)[^\\n]{0,30})[ \\t]{0,3}$", multiline: true)
    private static let strongLabel = Rx("rechnungs-?\\s?(?:nummer|nr|datum)|invoice\\s?(?:number|no|nr|date|#)|rechnung\\s{1,3}nr|re-?nr")
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
