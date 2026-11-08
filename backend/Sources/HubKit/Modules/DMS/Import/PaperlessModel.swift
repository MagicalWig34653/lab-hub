import Foundation
import Crypto

// WP-D6: neutrales Zwischenformat für den Paperless-Import. Beide Quellen (Export-Verzeichnis, REST-API) liefern dieselben Strukturen; der Import kennt nur sie.
// Paperless-ngx steht unter GPL-3.0: hier steht kein Code und kein Text daraus, nur die Abbildung von Funktionen (Korrespondent, Dokumenttyp, Tag, Speicherpfad,
// benutzerdefiniertes Feld, Archivnummer, Notiz). Das Feldformat der Quellen ist aus der öffentlichen Beschreibung der Funktionen abgeleitet (zu verifizieren
// gegen eine echte Instanz, siehe docs/handoff/WP-D6.md).

struct ImportError: Error, Equatable { let code: String; init(_ c: String) { code = c } }

/// Skalarwert (benutzerdefiniertes Feld, JSON der Quelle).
enum PLValue: Sendable, Equatable {
    case null, bool(Bool), int(Int64), double(Double), string(String), list([PLValue])

    init(native: Any?) {
        switch native {
        case nil, is NSNull: self = .null
        case let b as Bool: self = .bool(b)
        case let i as Int: self = .int(Int64(i))
        case let i as Int64: self = .int(i)
        case let d as Double: self = d == d.rounded() && abs(d) < 1e15 ? .int(Int64(d)) : .double(d)
        case let s as String: self = .string(s)
        case let a as [Any]: self = .list(a.map { PLValue(native: $0) })
        default: self = .null
        }
    }
    var text: String? {
        switch self {
        case .string(let s): s
        case .int(let i): String(i)
        case .double(let d): String(d)
        case .bool(let b): b ? "true" : "false"
        default: nil
        }
    }
}

struct PLOption: Sendable, Equatable { let id: String?; let label: String }

/// Korrespondent, Dokumenttyp, Tag, Speicherpfad oder benutzerdefiniertes Feld.
struct PLEntity: Sendable {
    let id: Int64
    let name: String
    var match: String = ""
    var algorithm: Int = 0
    var insensitive: Bool = true
    var color: String?
    var template: String?
    var dataType: String?
    var options: [PLOption] = []
}

struct PLReferences: Sendable {
    var correspondents: [PLEntity] = [], types: [PLEntity] = [], tags: [PLEntity] = [], paths: [PLEntity] = [], fields: [PLEntity] = []
    /// Nur Zähler: Benutzer und Gruppen der Quelle werden weder gelesen noch übernommen (F-23).
    var userCount = 0, groupCount = 0
}

struct PLNote: Sendable { let id: Int64?; let text: String; let created: String? }
struct PLFieldValue: Sendable { let field: Int64; let value: PLValue }

struct PLDoc: Sendable {
    let id: Int64
    var title: String = ""
    var content: String = ""
    var created: String?
    var added: String?
    var asn: Int64?
    var correspondent: Int64?
    var type: Int64?
    var path: Int64?
    var tags: [Int64] = []
    var owner: Int64?
    var notes: [PLNote] = []
    var fields: [PLFieldValue] = []
    var checksum: String?, archiveChecksum: String?
    var originalName: String?
    /// Export: relative Pfade der Dateien im Verzeichnis. API: `archiveAvailable` aus der Antwort.
    var originalRef: String?, archiveRef: String?
    var archiveAvailable = false
}

enum PLFileRole: String, Sendable { case original, archive }

/// Eine auf die Platte gelegte Datei (Export: die Originaldatei im Verzeichnis, API: temporäre Datei auf tmpfs) mit beiden Prüfsummen.
struct LocalFile: Sendable {
    let url: URL
    let size: Int64
    let sha256: String
    let md5: String
    let temporary: Bool
    func discard() { if temporary { try? FileManager.default.removeItem(at: url) } }

    /// Bytes der ersten Seite zur Typerkennung (Magic Bytes).
    func head(_ n: Int = DMSFileKind.sniffLength) -> [UInt8] {
        guard let h = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? h.close() }
        return Array((try? h.read(upToCount: n)) ?? Data())
    }

    static func measure(_ url: URL, temporary: Bool, maxBytes: Int64) throws -> LocalFile {
        let h = try FileHandle(forReadingFrom: url)
        defer { try? h.close() }
        var sha = SHA256(), md5 = Insecure.MD5()
        var size: Int64 = 0
        while let chunk = try h.read(upToCount: 1 << 20), !chunk.isEmpty {
            size += Int64(chunk.count)
            if size > maxBytes { throw ImportError("file_too_large") }
            sha.update(data: chunk); md5.update(data: chunk)
        }
        return LocalFile(url: url, size: size, sha256: sha.finalize().map { String(format: "%02x", $0) }.joined(),
                         md5: md5.finalize().map { String(format: "%02x", $0) }.joined(), temporary: temporary)
    }
}

protocol PaperlessSource: Sendable {
    /// Idempotenzschlüssel der Quelle (gleicher Schlüssel = gleiche Paperless-Instanz bzw. gleiches Exportverzeichnis).
    var key: String { get }
    func references() async throws -> PLReferences
    /// Dokumente in aufsteigender Paperless-ID, seitenweise.
    func pages(size: Int, _ body: ([PLDoc], Int?) async throws -> Void) async throws
    /// Legt die Datei bereit; `nil`, wenn sie in der Quelle fehlt.
    func materialize(_ doc: PLDoc, _ role: PLFileRole, maxBytes: Int64) async throws -> LocalFile?
}

// MARK: Abbildungshilfen (rein, ohne Datenbank)

enum PL {
    static func int(_ v: Any?) -> Int64? {
        switch v {
        case let i as Int: return Int64(i)
        case let i as Int64: return i
        case let d as Double where d == d.rounded(): return Int64(d)
        case let s as String: return Int64(s.trimmingCharacters(in: .whitespaces))
        default: return nil
        }
    }
    static func str(_ v: Any?) -> String? { (v as? String).flatMap { $0.isEmpty ? nil : $0 } }

    /// `yyyy-MM-dd` aus Datum oder Zeitstempel der Quelle (der Kalendertag der Quelle, nicht umgerechnet).
    static func date(_ s: String?) -> String? {
        guard let s, s.count >= 10, let d = try? DMSError.date(String(s.prefix(10)), "created") else { return nil }
        return d
    }

    static func timestamp(_ s: String?) -> Date? {
        guard let s, !s.isEmpty else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        if let d = f.date(from: s) { return d }
        if let day = date(s) {
            var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
            let p = day.split(separator: "-").compactMap { Int($0) }
            return cal.date(from: DateComponents(year: p[0], month: p[1], day: p[2]))
        }
        return nil
    }

    /// Paperless-Vorlage -> Hub-Vorlage (`{doc_date:yyyy}`, `{type}` …); `nil`, wenn ein Platzhalter oder Filter nicht übersetzbar ist.
    static func template(_ raw: String) -> String? {
        let known = ["created_year": "{doc_date:yyyy}", "created_month": "{doc_date:MM}", "correspondent": "{correspondent}", "document_type": "{type}",
                     "title": "{title}", "asn": "{asn}"]
        var out = ""
        var rest = Substring(raw.trimmingCharacters(in: .whitespacesAndNewlines))
        while let open = rest.firstIndex(of: "{") {
            let literal = rest[..<open]
            guard !literal.contains("}") else { return nil }
            out += literal
            var after = rest[open...]
            let double = after.hasPrefix("{{")
            after = after.dropFirst(double ? 2 : 1)
            guard let close = after.range(of: double ? "}}" : "}") else { return nil }
            let token = after[..<close.lowerBound].trimmingCharacters(in: .whitespaces)
            guard let mapped = known[token] else { return nil }
            out += mapped
            rest = after[close.upperBound...]
        }
        guard !rest.contains("}") else { return nil }
        out += rest
        guard !out.isEmpty, out.count <= 300 else { return nil }
        return out
    }

    /// Dreiergruppen-Ähnlichkeit wie bei `pg_trgm` (Wörter mit zwei Leerzeichen davor und einem danach, Jaccard-Maß).
    static func trigrams(_ s: String) -> Set<String> {
        var set = Set<String>()
        for word in s.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }) {
            let chars = Array("  " + word + " ")
            guard chars.count >= 3 else { continue }
            for i in 0...(chars.count - 3) { set.insert(String(chars[i..<(i + 3)])) }
        }
        return set
    }
    static func similarity(_ a: Set<String>, _ b: Set<String>) -> Double {
        let u = a.union(b).count
        return u == 0 ? 0 : Double(a.intersection(b).count) / Double(u)
    }

    /// Feldcode aus dem Namen (`^[a-z][a-z0-9_]{0,39}$`).
    static func code(from name: String) -> String {
        var s = name.lowercased()
        for (a, b) in [("ä", "ae"), ("ö", "oe"), ("ü", "ue"), ("ß", "ss")] { s = s.replacingOccurrences(of: a, with: b) }
        s = s.folding(options: .diacriticInsensitive, locale: nil)
        let mapped = String(s.unicodeScalars.map { ($0.value >= 97 && $0.value <= 122) || ($0.value >= 48 && $0.value <= 57) ? Character($0) : "_" })
        var c = mapped.split(separator: "_", omittingEmptySubsequences: true).joined(separator: "_")
        if c.isEmpty { c = "feld" }
        if let f = c.first, f.isNumber { c = "f_" + c }
        return String(c.prefix(36))
    }

    static func algorithmName(_ n: Int) -> String {
        ["none", "any", "all", "literal", "regex", "fuzzy", "auto"].indices.contains(n) ? ["none", "any", "all", "literal", "regex", "fuzzy", "auto"][n] : "unknown"
    }

    static func hexLength(_ s: String) -> Int? { s.range(of: "^[0-9a-fA-F]+$", options: .regularExpression) != nil ? s.count : nil }

    /// Prüfsumme der Quelle gegen die gemessene Datei: 32 Hexzeichen = MD5, 64 = SHA-256. `nil` = nicht prüfbar (leer oder unbekanntes Format).
    static func checksumMatches(_ expected: String?, _ file: LocalFile) -> Bool? {
        guard let e = expected?.lowercased(), let n = hexLength(e) else { return nil }
        switch n { case 32: return e == file.md5; case 64: return e == file.sha256; default: return nil }
    }
}
