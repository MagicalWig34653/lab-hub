import Vapor
import Foundation

// WP-D3 Regelmodell (MODUL-DMS 5.4): Bedingungen und Aktionen als versioniertes JSON, strikte Prüfung (unbekannte Schlüssel = 422),
// Regex nur mit Längenlimit und Zeitlimit (`SafeRegex`). Reine Werttypen, keine Datenbank.

/// Ablehnung unbekannter Schlüssel: Eingabe mit Tippfehler soll nicht still ignoriert werden.
private struct AnyKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}

private func rejectUnknownKeys(_ decoder: any Decoder, allowed: Set<String>) throws {
    let c = try decoder.container(keyedBy: AnyKey.self)
    for key in c.allKeys where !allowed.contains(key.stringValue) {
        throw DecodingError.dataCorruptedError(forKey: key, in: c, debugDescription: "unknown key")
    }
}

struct RuleCondition: Codable, Sendable, Equatable {
    static let types: Set<String> = ["text_contains", "text_regex", "filename_contains", "filename_regex", "sender_contains", "source_is"]
    static let sources: Set<String> = ["upload", "folder", "mail", "share_ext", "api"]

    var type: String
    /// Für `*_contains` und `source_is`.
    var value: String?
    /// Für `*_regex`.
    var pattern: String?
    /// Standard: Groß-/Kleinschreibung wird ignoriert.
    var case_sensitive: Bool?

    init(type: String, value: String? = nil, pattern: String? = nil, case_sensitive: Bool? = nil) {
        self.type = type; self.value = value; self.pattern = pattern; self.case_sensitive = case_sensitive
    }
    init(from decoder: any Decoder) throws {
        try rejectUnknownKeys(decoder, allowed: ["type", "value", "pattern", "case_sensitive"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = try c.decode(String.self, forKey: .type)
        value = try c.decodeIfPresent(String.self, forKey: .value)
        pattern = try c.decodeIfPresent(String.self, forKey: .pattern)
        case_sensitive = try c.decodeIfPresent(Bool.self, forKey: .case_sensitive)
    }
}

struct RuleConditions: Codable, Sendable, Equatable {
    static let currentVersion = 1
    static let maxConditions = 20

    var version: Int?
    /// `all` (Standard) oder `any`.
    var match: String?
    var conditions: [RuleCondition]

    var isAny: Bool { match == "any" }

    init(version: Int? = nil, match: String? = nil, conditions: [RuleCondition]) { self.version = version; self.match = match; self.conditions = conditions }
    init(from decoder: any Decoder) throws {
        try rejectUnknownKeys(decoder, allowed: ["version", "match", "conditions"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version)
        match = try c.decodeIfPresent(String.self, forKey: .match)
        conditions = try c.decode([RuleCondition].self, forKey: .conditions)
    }
}

struct RuleActions: Codable, Sendable, Equatable {
    var correspondent_id: UUID?
    var document_type_id: UUID?
    var tag_ids: [UUID]?
    var storage_path_id: UUID?
    /// `extracted` (erstes gültiges Datum im Text) oder ein festes Datum `yyyy-MM-dd`.
    var doc_date: String?
    /// Platzhalter `{filename}` (Dateiname ohne Endung), `{match}` (erster Treffer einer Textbedingung), `{date}` (erkanntes Datum).
    var title_template: String?

    var isEmpty: Bool { correspondent_id == nil && document_type_id == nil && (tag_ids ?? []).isEmpty && storage_path_id == nil && doc_date == nil && title_template == nil }

    init(correspondent_id: UUID? = nil, document_type_id: UUID? = nil, tag_ids: [UUID]? = nil, storage_path_id: UUID? = nil, doc_date: String? = nil, title_template: String? = nil) {
        self.correspondent_id = correspondent_id; self.document_type_id = document_type_id; self.tag_ids = tag_ids
        self.storage_path_id = storage_path_id; self.doc_date = doc_date; self.title_template = title_template
    }
    init(from decoder: any Decoder) throws {
        try rejectUnknownKeys(decoder, allowed: ["correspondent_id", "document_type_id", "tag_ids", "storage_path_id", "doc_date", "title_template"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        correspondent_id = try c.decodeIfPresent(UUID.self, forKey: .correspondent_id)
        document_type_id = try c.decodeIfPresent(UUID.self, forKey: .document_type_id)
        tag_ids = try c.decodeIfPresent([UUID].self, forKey: .tag_ids)
        storage_path_id = try c.decodeIfPresent(UUID.self, forKey: .storage_path_id)
        doc_date = try c.decodeIfPresent(String.self, forKey: .doc_date)
        title_template = try c.decodeIfPresent(String.self, forKey: .title_template)
    }
}

/// Eine Regel, wie sie die Auswertung braucht.
struct RuleDefinition: Sendable {
    let id: UUID
    let name: String
    let priority: Int
    let mode: String
    let confidence: Double
    let version: Int
    let conditions: RuleConditions
    let actions: RuleActions
}

/// Eingabe für Anlegen (alle Pflichtfelder) und Ändern (nur gesetzte Felder).
struct RuleInput: Decodable, Sendable {
    var name: String?
    var priority: Int?
    var enabled: Bool?
    var mode: String?
    var confidence: Double?
    var conditions: RuleConditions?
    var actions: RuleActions?
    /// Nur für den Trockenlauf mit Entwurf: Anzahl der zu prüfenden Dokumente.
    var limit: Int?

    init(from decoder: any Decoder) throws {
        try rejectUnknownKeys(decoder, allowed: ["name", "priority", "enabled", "mode", "confidence", "conditions", "actions", "limit"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        priority = try c.decodeIfPresent(Int.self, forKey: .priority)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled)
        mode = try c.decodeIfPresent(String.self, forKey: .mode)
        confidence = try c.decodeIfPresent(Double.self, forKey: .confidence)
        conditions = try c.decodeIfPresent(RuleConditions.self, forKey: .conditions)
        actions = try c.decodeIfPresent(RuleActions.self, forKey: .actions)
        limit = try c.decodeIfPresent(Int.self, forKey: .limit)
    }
    private enum CodingKeys: String, CodingKey { case name, priority, enabled, mode, confidence, conditions, actions, limit }
}

// MARK: Regex mit Sicherheitslimit

/// Regulärer Ausdruck mit Längen- und Zeitlimit (MODUL-DMS 5.4: kein katastrophales Backtracking). Die ICU-Engine meldet während langer Läufe Fortschritt
/// (`reportProgress`); überschreitet die Wanduhr das Limit, wird der Lauf abgebrochen und als `timedOut` gemeldet (die Bedingung gilt dann als nicht erfüllt).
enum SafeRegex {
    static let maxPatternLength = 200
    /// Es wird höchstens dieser Textanfang geprüft (O2 begrenzt Texte ohnehin auf 500 000 Zeichen).
    static let maxInputLength = 300_000
    static let defaultTimeout: TimeInterval = 0.25

    /// Zeitlimit je Regex und Dokument; `DMS_REGEX_TIMEOUT_MS` (10…5000) überschreibt den Standard (Betrieb/Tests).
    static var timeout: TimeInterval {
        if let raw = ProcessInfo.processInfo.environment["DMS_REGEX_TIMEOUT_MS"], let ms = Int(raw), (10...5000).contains(ms) { return Double(ms) / 1000 }
        return defaultTimeout
    }

    enum Outcome: Equatable, Sendable {
        case match(location: Int, length: Int)   // UTF-16-Offsets im geprüften Text
        case noMatch
        case timedOut
    }

    /// `nil`, wenn das Muster zu lang ist oder nicht übersetzt werden kann.
    static func compile(_ pattern: String, caseSensitive: Bool) -> NSRegularExpression? {
        guard !pattern.isEmpty, pattern.count <= maxPatternLength else { return nil }
        return try? NSRegularExpression(pattern: pattern, options: caseSensitive ? [] : [.caseInsensitive])
    }

    static func firstMatch(_ re: NSRegularExpression, in text: String, timeout: TimeInterval) -> Outcome {
        let input = text.count > maxInputLength ? String(text.prefix(maxInputLength)) : text
        let length = (input as NSString).length
        let deadline = Date().addingTimeInterval(timeout)
        var outcome = Outcome.noMatch
        re.enumerateMatches(in: input, options: [.reportProgress], range: NSRange(location: 0, length: length)) { result, flags, stop in
            if let result {
                outcome = .match(location: result.range.location, length: result.range.length)
                stop.pointee = true
            } else if flags.contains(.progress), Date() > deadline {
                outcome = .timedOut
                stop.pointee = true
            }
        }
        return outcome
    }
}

// MARK: Prüfung der Eingabe

enum RuleValidation {
    static let namePattern = 100

    /// Prüft Bedingungen ohne Datenbank (Typen, Längen, Regex übersetzbar). Fehlerfelder wie `conditions[2].pattern`.
    static func validate(_ c: RuleConditions) throws {
        if let v = c.version, v != RuleConditions.currentVersion { throw DMSError.invalid("conditions.version", "unsupported") }
        if let m = c.match, m != "all", m != "any" { throw DMSError.invalid("conditions.match") }
        guard (1...RuleConditions.maxConditions).contains(c.conditions.count) else { throw DMSError.invalid("conditions.conditions", c.conditions.isEmpty ? "required" : "too_many") }
        for (i, cond) in c.conditions.enumerated() {
            let path = "conditions.conditions[\(i)]"
            guard RuleCondition.types.contains(cond.type) else { throw DMSError.invalid(path + ".type", "unknown") }
            switch cond.type {
            case "text_contains", "filename_contains", "sender_contains":
                guard let v = cond.value?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty else { throw DMSError.invalid(path + ".value", "required") }
                guard v.count <= 200 else { throw DMSError.invalid(path + ".value", "too_long") }
                guard cond.pattern == nil else { throw DMSError.invalid(path + ".pattern", "not_allowed") }
            case "text_regex", "filename_regex":
                guard let p = cond.pattern, !p.isEmpty else { throw DMSError.invalid(path + ".pattern", "required") }
                guard p.count <= SafeRegex.maxPatternLength else { throw DMSError.invalid(path + ".pattern", "too_long") }
                guard SafeRegex.compile(p, caseSensitive: cond.case_sensitive ?? false) != nil else { throw DMSError.invalid(path + ".pattern", "regex_invalid") }
                guard cond.value == nil else { throw DMSError.invalid(path + ".value", "not_allowed") }
            default:   // source_is
                guard let v = cond.value, RuleCondition.sources.contains(v) else { throw DMSError.invalid(path + ".value", "unknown") }
            }
        }
    }

    static func validate(name: String?) throws -> String {
        guard let n = name?.trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCanonicalMapping, !n.isEmpty else { throw DMSError.invalid("name", "required") }
        guard n.count <= namePattern else { throw DMSError.invalid("name", "too_long") }
        return n
    }

    static func validate(mode: String?) throws -> String {
        let m = mode ?? "suggest"
        guard m == "suggest" || m == "auto" else { throw DMSError.invalid("mode") }
        return m
    }

    static func validate(priority: Int?) throws -> Int {
        let p = priority ?? 0
        guard (-1000...1000).contains(p) else { throw DMSError.invalid("priority") }
        return p
    }

    /// Konfidenz als Dezimalzahl mit drei Nachkommastellen (Standard 0,8).
    static func validate(confidence: Double?) throws -> Double {
        let c = confidence ?? 0.8
        guard c >= 0, c <= 1, c.isFinite else { throw DMSError.invalid("confidence") }
        return (c * 1000).rounded() / 1000
    }

    static let titlePlaceholders: Set<String> = ["filename", "match", "date"]

    /// Prüft die Aktionen ohne Datenbank; Verweise (Typ, Tag, Pfad, Kontakt) prüft der Dienst gegen den Mandanten.
    static func validate(_ a: RuleActions) throws {
        guard !a.isEmpty else { throw DMSError.invalid("actions", "required") }
        if let tags = a.tag_ids { guard tags.count <= 20 else { throw DMSError.invalid("actions.tag_ids", "too_many") } }
        if let d = a.doc_date, d != "extracted" { _ = try DMSError.date(d, "actions.doc_date") }
        if let t = a.title_template {
            guard !t.isEmpty, t.count <= 300 else { throw DMSError.invalid("actions.title_template") }
            var rest = Substring(t)
            while let open = rest.firstIndex(of: "{") {
                guard let close = rest[open...].firstIndex(of: "}") else { throw DMSError.invalid("actions.title_template", "bad_placeholder") }
                guard titlePlaceholders.contains(String(rest[rest.index(after: open)..<close])) else { throw DMSError.invalid("actions.title_template", "bad_placeholder") }
                rest = rest[rest.index(after: close)...]
            }
            guard !rest.contains("}") else { throw DMSError.invalid("actions.title_template", "bad_placeholder") }
        }
    }
}
