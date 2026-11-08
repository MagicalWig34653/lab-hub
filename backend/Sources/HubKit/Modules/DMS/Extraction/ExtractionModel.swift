import Foundation

// WP-D7 Extraktion: allgemeines Gerüst für ALLE Dokumente (MODUL-DMS 5.3). Ein Extraktor liefert (1) die Dokumentart mit Score und Begründung, gewählt aus austauschbaren
// Detektoren je `DocumentKind`, und (2) Fakten (Datum, Beträge mit Währung, IBAN, USt-ID, Referenz, Aussteller, Titelvorschlag, Frist) mit Fundstelle, Konfidenz und Begründung.
// Deterministisch und ohne Uhr/Zufall: gleicher Text + gleiche Extraktorversion = gleiches Ergebnis. Beträge sind Dezimalzeichenketten (nie Gleitkomma).
// Neue Dokumentarten brauchen nur einen weiteren `DocumentDetector`; Schema, API und Speicher bleiben unverändert (`kind` und `facts` sind generisch).

enum DocumentKind: String, Sendable, CaseIterable, Codable {
    case invoice, receipt, contract, letter, bankStatement = "bank_statement", insurance, taxNotice = "tax_notice", reminder, other
}

/// Fundstelle: UTF-16-Offset und Länge im Dokumenttext (wie die Regel-Treffer aus D3) plus gekürzter Ausschnitt.
struct FactSource: Codable, Sendable, Equatable {
    let offset: Int
    let length: Int
    let excerpt: String
}

enum FactType: String, Sendable, CaseIterable {
    case invoiceNumber = "invoice_number", reference, date, dueDate = "due_date", deadline
    case amount, amountGross = "amount_gross", amountNet = "amount_net", amountTax = "amount_tax"
    case iban, vatID = "vat_id", seller, title
}

struct ExtractedFact: Codable, Sendable, Equatable {
    let type: String
    /// Kanonisch: Beträge als Dezimalzeichenkette (`1234.56`), Daten `yyyy-MM-dd`, IBAN/USt-ID kompakt in Großschreibung.
    let value: String
    let currency: String?
    let confidence: Double
    let reason: String
    let source: FactSource?

    init(_ type: FactType, value: String, currency: String? = nil, confidence: Double, reason: String, source: FactSource?) {
        self.type = type.rawValue; self.value = value; self.currency = currency; self.confidence = (confidence * 1000).rounded() / 1000; self.reason = reason; self.source = source
    }
}

struct KindScore: Sendable, Equatable {
    let kind: DocumentKind
    let score: Double
    let reasons: [String]
}

/// Eingabe des Extraktors. Betreff und Absender stammen aus der Mail (oder fehlen); der Text ist der Dokumenttext (OCR, PDF-Textschicht, Mailtext).
struct ExtractionInput: Sendable {
    var text: String
    var subject: String?
    var sender: String?
    var filename: String?

    init(text: String, subject: String? = nil, sender: String? = nil, filename: String? = nil) {
        self.text = text; self.subject = subject; self.sender = sender; self.filename = filename
    }
}

struct ExtractionResult: Sendable, Equatable {
    static let version = 1
    /// Schwellen (im Handoff dokumentiert): ab `certainThreshold` gilt die Art als erkannt, zwischen `uncertainThreshold` und `certainThreshold` als unsicher.
    static let certainThreshold = 0.6
    static let uncertainThreshold = 0.35

    let kind: DocumentKind
    let kindScore: Double
    let kindCertain: Bool
    let reasons: [String]
    /// Scores aller Detektoren (zur Nachvollziehbarkeit), absteigend.
    let scores: [KindScore]
    let facts: [ExtractedFact]

    func facts(_ type: FactType) -> [ExtractedFact] { facts.filter { $0.type == type.rawValue } }
    func first(_ type: FactType) -> ExtractedFact? { facts(type).first }
}

/// Kontext für Detektoren: Text (alle Muster sind unabhängig von der Schreibweise, damit Offsets stimmen) und vorab extrahierte allgemeine Fakten.
struct ExtractionContext: @unchecked Sendable {
    let input: ExtractionInput
    let ns: NSString
    let subjectNS: NSString
    let general: [ExtractedFact]

    func has(_ type: FactType) -> Bool { general.contains { $0.type == type.rawValue } }
}

protocol DocumentDetector: Sendable {
    var kind: DocumentKind { get }
    func score(_ ctx: ExtractionContext) -> KindScore
    /// Zusätzliche Fakten, nur wenn diese Art gewählt wurde.
    func facts(_ ctx: ExtractionContext) -> [ExtractedFact]
}

extension DocumentDetector {
    func facts(_ ctx: ExtractionContext) -> [ExtractedFact] { [] }
}
