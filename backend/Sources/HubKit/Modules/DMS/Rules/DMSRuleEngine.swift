import Foundation

// WP-D3 Regelauswertung. Reine, deterministische Funktionen: gleiche Eingabe (Text, Dateiname, Quelle, Absender, Dokumentzustand) und gleiche Regelversion
// ergeben dieselben Vorschläge in derselben Reihenfolge. Keine Datenbank, keine Uhr (außer dem Regex-Zeitlimit, das nur pathologische Muster betrifft), kein Zufall.

/// Eingabe der Auswertung.
struct RuleContext: Sendable {
    var text: String
    var filename: String?
    var source: String
    var sender: String?
    /// Aktueller Zustand des Dokuments (für „Vorschlag ist schon erfüllt“).
    var current: DocumentState
}

struct DocumentState: Sendable, Equatable {
    var title: String = ""
    var docDate: String?
    var typeID: UUID?
    var pathID: UUID?
    var correspondentID: UUID?
    var tagIDs: Set<UUID> = []
}

/// Kandidat für einen Vorschlag, noch nicht gespeichert.
struct SuggestionCandidate: Sendable, Equatable {
    let kind: String            // correspondent, type, tag, date, title, path
    let value: [String: String]
    let valueKey: String
    let source: String          // rule, contact_match
    let ruleID: UUID?
    let ruleVersion: Int?
    let confidence: Double
    let reason: String
    let evidence: [String: String]
    let automatic: Bool         // Regel im Modus `auto`

    var valueJSON: String { DMSRuleJSON.encode(value) }
    var evidenceJSON: String { DMSRuleJSON.encode(evidence) }
}

enum DMSRuleJSON {
    /// Schlüssel sortiert: dieselbe Eingabe ergibt dieselbe Zeichenkette.
    static func encode(_ dict: [String: String]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys]) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }
}

struct ConditionHit: Sendable, Equatable {
    let index: Int
    let type: String
    /// Gefundener Text (gekürzt) oder, bei `source_is`, der Wert.
    let matched: String
    /// UTF-16-Offset und Länge im Text (nur Textbedingungen).
    let offset: Int?
    let length: Int?
}

enum RuleVerdict: Sendable, Equatable {
    case matched([ConditionHit])
    case noMatch
    /// Mindestens ein Regex hat das Zeitlimit überschritten und nichts anderes hat die Regel erfüllt.
    case timedOut
}

enum DMSRuleEngine {
    static let maxExcerpt = 60

    // MARK: Hilfen

    /// Einzeilig, ohne Steuerzeichen, gekürzt (für Begründungen und Treffer).
    static func excerpt(_ s: String, max: Int = maxExcerpt) -> String {
        let collapsed = clean(s)
        return collapsed.count > max ? String(collapsed.prefix(max)) + "…" : collapsed
    }

    /// Einzeilig, ohne Steuerzeichen und doppelte Leerzeichen.
    static func clean(_ s: String) -> String {
        let cleaned = String(String.UnicodeScalarView(s.unicodeScalars.map { $0.properties.generalCategory == .control || $0.properties.generalCategory == .format ? " " : $0 }))
        return cleaned.split(whereSeparator: { $0 == " " }).joined(separator: " ")
    }

    /// Dateiname ohne Endung.
    static func stem(_ filename: String?) -> String? {
        guard let f = filename?.trimmingCharacters(in: .whitespacesAndNewlines), !f.isEmpty else { return nil }
        let s = (f as NSString).deletingPathExtension
        return s.isEmpty ? f : s
    }

    // MARK: Datum

    /// Erstes gültiges Datum im Text (Reihenfolge im Text). Formen `dd.mm.yyyy` und `yyyy-mm-dd`; Jahre 1990…2100 (keine Uhr, damit deterministisch).
    static func firstDate(in text: String) -> (iso: String, offset: Int, length: Int)? {
        let head = text.count > 20_000 ? String(text.prefix(20_000)) : text
        guard let re = try? NSRegularExpression(pattern: "(?<![0-9])(?:([0-9]{1,2})\\.([0-9]{1,2})\\.([0-9]{4})|([0-9]{4})-([0-9]{2})-([0-9]{2}))(?![0-9])") else { return nil }
        let ns = head as NSString
        for m in re.matches(in: head, range: NSRange(location: 0, length: ns.length)) {
            func group(_ i: Int) -> Int? { m.range(at: i).location == NSNotFound ? nil : Int(ns.substring(with: m.range(at: i))) }
            let (d, mo, y) = m.range(at: 1).location != NSNotFound ? (group(1), group(2), group(3)) : (group(6), group(5), group(4))
            if let d, let mo, let y, isValid(y, mo, d) { return (String(format: "%04d-%02d-%02d", y, mo, d), m.range.location, m.range.length) }
        }
        return nil
    }

    static func isValid(_ y: Int, _ m: Int, _ d: Int) -> Bool {
        guard (1990...2100).contains(y), (1...12).contains(m), d >= 1 else { return false }
        let days = [31, (y % 4 == 0 && (y % 100 != 0 || y % 400 == 0)) ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
        return d <= days[m - 1]
    }

    // MARK: Bedingungen

    /// Wertet die Bedingungen einer Regel aus. `all`: alle müssen zutreffen (Abbruch bei der ersten verfehlten), `any`: mindestens eine.
    static func evaluate(_ rule: RuleDefinition, context: RuleContext, regexTimeout: TimeInterval = SafeRegex.timeout) -> RuleVerdict {
        var hits: [ConditionHit] = []
        var timedOut = false
        for (i, cond) in rule.conditions.conditions.enumerated() {
            switch evaluate(cond, index: i, context: context, regexTimeout: regexTimeout) {
            case .hit(let h):
                hits.append(h)
                if rule.conditions.isAny { return .matched(hits) }
            case .miss:
                if !rule.conditions.isAny { return .noMatch }
            case .timeout:
                timedOut = true
                if !rule.conditions.isAny { return .timedOut }
            }
        }
        if rule.conditions.isAny { return timedOut ? .timedOut : .noMatch }
        return .matched(hits)
    }

    private enum One { case hit(ConditionHit), miss, timeout }

    private static func evaluate(_ c: RuleCondition, index: Int, context: RuleContext, regexTimeout: TimeInterval) -> One {
        let sensitive = c.case_sensitive ?? false
        switch c.type {
        case "text_contains":
            return contains(context.text, c.value ?? "", sensitive: sensitive, index: index, type: c.type)
        case "filename_contains":
            guard let f = context.filename else { return .miss }
            return contains(f, c.value ?? "", sensitive: sensitive, index: index, type: c.type)
        case "sender_contains":
            guard let s = context.sender else { return .miss }
            return contains(s, c.value ?? "", sensitive: sensitive, index: index, type: c.type)
        case "text_regex", "filename_regex":
            let subject = c.type == "text_regex" ? context.text : context.filename
            guard let subject, let re = SafeRegex.compile(c.pattern ?? "", caseSensitive: sensitive) else { return .miss }
            switch SafeRegex.firstMatch(re, in: subject, timeout: regexTimeout) {
            case .match(let loc, let len):
                let s = (subject as NSString)
                let matched = loc >= 0 && loc + len <= s.length ? s.substring(with: NSRange(location: loc, length: len)) : ""
                return .hit(ConditionHit(index: index, type: c.type, matched: excerpt(matched), offset: loc, length: len))
            case .noMatch: return .miss
            case .timedOut: return .timeout
            }
        case "source_is":
            return context.source == c.value ? .hit(ConditionHit(index: index, type: c.type, matched: context.source, offset: nil, length: nil)) : .miss
        default:
            return .miss
        }
    }

    private static func contains(_ haystack: String, _ needle: String, sensitive: Bool, index: Int, type: String) -> One {
        let needle = needle.trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCanonicalMapping
        guard !needle.isEmpty else { return .miss }
        let ns = haystack as NSString
        let r = ns.range(of: needle, options: sensitive ? [] : [.caseInsensitive])
        guard r.location != NSNotFound else { return .miss }
        return .hit(ConditionHit(index: index, type: type, matched: excerpt(ns.substring(with: r)), offset: r.location, length: r.length))
    }

    // MARK: Vorschläge einer Regel

    /// Vorschlagskandidaten einer zutreffenden Regel, in fester Reihenfolge: Korrespondent, Typ, Tags (nach ID), Datum, Titel, Pfad.
    /// Was das Dokument schon hat, wird nicht vorgeschlagen.
    static func candidates(for rule: RuleDefinition, hits: [ConditionHit], context: RuleContext) -> [SuggestionCandidate] {
        let first = hits.first(where: { $0.type.hasPrefix("text_") }) ?? hits.first
        let matchText = first?.matched ?? ""
        let reason = "Regel „\(excerpt(rule.name, max: 100))“, Treffer „\(matchText)“"
        var evidence: [String: String] = ["condition": first.map { String($0.index) } ?? "", "type": first?.type ?? ""]
        if let o = first?.offset, let l = first?.length { evidence["offset"] = String(o); evidence["length"] = String(l) }
        let auto = rule.mode == "auto"
        func make(_ kind: String, _ value: [String: String], key: String, extra: [String: String] = [:]) -> SuggestionCandidate {
            SuggestionCandidate(kind: kind, value: value, valueKey: key, source: "rule", ruleID: rule.id, ruleVersion: rule.version, confidence: rule.confidence,
                                reason: reason, evidence: evidence.merging(extra) { a, _ in a }, automatic: auto)
        }
        let a = rule.actions
        var out: [SuggestionCandidate] = []
        if let id = a.correspondent_id, context.current.correspondentID != id {
            out.append(make("correspondent", ["contact_id": id.uuidString.lowercased()], key: id.uuidString.lowercased()))
        }
        if let id = a.document_type_id, context.current.typeID != id {
            out.append(make("type", ["document_type_id": id.uuidString.lowercased()], key: id.uuidString.lowercased()))
        }
        for id in Set(a.tag_ids ?? []).sorted(by: { $0.uuidString < $1.uuidString }) where !context.current.tagIDs.contains(id) {
            out.append(make("tag", ["tag_id": id.uuidString.lowercased()], key: id.uuidString.lowercased()))
        }
        var date: String?
        if let d = a.doc_date {
            if d == "extracted" {
                if let found = firstDate(in: context.text) {
                    date = found.iso
                    if context.current.docDate != found.iso {
                        out.append(make("date", ["doc_date": found.iso], key: found.iso, extra: ["date_offset": String(found.offset), "date_length": String(found.length)]))
                    }
                }
            } else {
                date = d
                if context.current.docDate != d { out.append(make("date", ["doc_date": d], key: d)) }
            }
        }
        if let t = a.title_template {
            let title = render(t, filename: stem(context.filename), match: matchText, date: date ?? context.current.docDate ?? firstDate(in: context.text)?.iso)
            if let title, title != context.current.title { out.append(make("title", ["title": title], key: title)) }
        }
        if let id = a.storage_path_id, context.current.pathID != id {
            out.append(make("path", ["storage_path_id": id.uuidString.lowercased()], key: id.uuidString.lowercased()))
        }
        return out
    }

    /// Titelvorlage; fehlt ein verwendeter Platzhalter-Wert, entsteht kein Titel (statt „-- -“). Ergebnis höchstens 300 Zeichen, ohne Steuerzeichen.
    static func render(_ template: String, filename: String?, match: String, date: String?) -> String? {
        var out = template
        for (token, value) in [("filename", filename), ("match", match.isEmpty ? nil : match), ("date", date)] where out.contains("{\(token)}") {
            guard let value else { return nil }
            out = out.replacingOccurrences(of: "{\(token)}", with: value)
        }
        let title = clean(out).precomposedStringWithCanonicalMapping.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? nil : String(title.prefix(300))
    }
}
