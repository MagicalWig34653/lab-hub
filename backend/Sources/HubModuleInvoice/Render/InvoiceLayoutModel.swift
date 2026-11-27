import Foundation
import HubCore

// WP-R6d: Layoutmodell V1 (FRONTEND.md Abschnitt 13 Stufe 1). Ein Layout ist eine Mandantenzeile mit unveränderlichen, fortlaufend nummerierten Versionen;
// jede Version hält ihre Parameter als JSON-Dokument mit `schema`. Schema 1 = Standardlayout (`base: standard`) plus Parameter: Schrift aus der freigegebenen
// Liste, Akzent- und Textfarbe, Logo (Verweis auf ein geprüftes Bild des Mandanten), Kopf- und Fußtext mit Platzhaltern. Der Designer (WP-F7b) teilt das Modell:
// er führt ein neues `schema` (Elemente, Ebenen, Seiten) im selben Versionsdokument ein; Schema 1 bleibt renderbar, weil finale Belege ihre Version behalten.
// Die Prüfung ist streng (unbekannte Felder werden abgelehnt), gespeichert wird die kanonische Form (sortierte Schlüssel): Speichern → Laden liefert dasselbe.

/// JSON-Wert für die strenge Prüfung: Wahrheitswerte, ganze Zahlen und andere Zahlen bleiben unterscheidbar (anders als bei `JSONSerialization`).
indirect enum LayoutJSON: Decodable, Equatable, Sendable {
    case null, bool(Bool), int(Int), number, string(String), array([LayoutJSON]), object([String: LayoutJSON])
    init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Int.self) { self = .int(v) }
        else if (try? c.decode(Double.self)) != nil { self = .number }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([LayoutJSON].self) { self = .array(v) }
        else { self = .object(try c.decode([String: LayoutJSON].self)) }
    }
}

struct InvoiceLayoutParams: Equatable, Sendable {
    struct Logo: Equatable, Sendable { let sha256: String; let widthMM: Int; let align: String }

    static let schema = 1
    /// Schriften im Worker-Image: Inter (gepinnt, `Dockerfile.worker`), Libertinus Serif und New Computer Modern (im Typst-Binary eingebettet, `docs/LIZENZEN.md`).
    static let fonts = ["Inter", "Libertinus Serif", "New Computer Modern"]
    static let placeholders = ["number", "issue_date", "due_date", "sender", "recipient"]
    static let maxText = 2000
    static let logoWidthMM = 10...80

    var font = "Inter"
    var accent = "#000000"
    var text = "#000000"
    var logo: Logo?
    var headerText: String?
    var footerText: String?

    /// Prüft ein Parameterdokument (JSON-Bytes); Fehler als `validation_failed` mit Feldpfad `params.…`.
    static func parse(json: Data) throws -> InvoiceLayoutParams {
        guard let value = try? JSONDecoder().decode(LayoutJSON.self, from: json) else { throw InvoiceError.invalid("params", "invalid") }
        return try parse(value)
    }

    /// Bequemlichkeit für Tests und Aufrufer mit `JSONSerialization`-Werten.
    static func parse(_ value: Any) throws -> InvoiceLayoutParams {
        guard JSONSerialization.isValidJSONObject(value), let data = try? JSONSerialization.data(withJSONObject: value) else { throw InvoiceError.invalid("params", "invalid") }
        return try parse(json: data)
    }

    static func parse(_ value: LayoutJSON) throws -> InvoiceLayoutParams {
        var errors: [FieldError] = []
        func fail(_ field: String, _ code: String) { errors.append(FieldError(field: "params." + field, code: code)) }
        guard case .object(let o) = value else { throw InvoiceError.invalid("params", "invalid") }
        for key in o.keys.sorted() where !["schema", "base", "font", "colors", "logo", "texts"].contains(key) { fail(key, "unknown") }
        if o["schema"] != .int(schema) { fail("schema", o["schema"] == nil ? "required" : "unsupported") }
        if o["base"] != .string("standard") { fail("base", o["base"] == nil ? "required" : "unsupported") }
        var p = InvoiceLayoutParams()
        if case .string(let font)? = o["font"], fonts.contains(font) { p.font = font } else { fail("font", o["font"] == nil ? "required" : "not_allowed") }

        if case .object(let colors)? = o["colors"] {
            for key in colors.keys.sorted() where !["accent", "text"].contains(key) { fail("colors." + key, "unknown") }
            for key in ["accent", "text"] {
                guard case .string(let c)? = colors[key], c.range(of: "^#[0-9A-Fa-f]{6}$", options: .regularExpression) != nil else { fail("colors." + key, colors[key] == nil ? "required" : "invalid"); continue }
                if key == "accent" { p.accent = c } else { p.text = c }
            }
        } else { fail("colors", o["colors"] == nil ? "required" : "invalid") }

        if let raw = o["logo"], raw != .null {
            if case .object(let logo) = raw {
                for key in logo.keys.sorted() where !["sha256", "width_mm", "align"].contains(key) { fail("logo." + key, "unknown") }
                var sha = "", width = 0, align = ""
                if case .string(let v)? = logo["sha256"], v.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil { sha = v } else { fail("logo.sha256", "invalid") }
                if case .int(let v)? = logo["width_mm"], logoWidthMM.contains(v) { width = v } else { fail("logo.width_mm", "invalid") }
                if case .string(let v)? = logo["align"], ["left", "right"].contains(v) { align = v } else { fail("logo.align", "invalid") }
                p.logo = Logo(sha256: sha, widthMM: width, align: align)
            } else { fail("logo", "invalid") }
        }

        if let raw = o["texts"], raw != .null {
            if case .object(let texts) = raw {
                for key in texts.keys.sorted() where !["header", "footer"].contains(key) { fail("texts." + key, "unknown") }
                for key in ["header", "footer"] {
                    guard let rawText = texts[key], rawText != .null else { continue }
                    guard case .string(let t) = rawText else { fail("texts." + key, "invalid"); continue }
                    if t.count > maxText { fail("texts." + key, "too_long"); continue }
                    if !unknownPlaceholders(t).isEmpty { fail("texts." + key, "unknown_placeholder"); continue }
                    if key == "header" { p.headerText = t } else { p.footerText = t }
                }
            } else { fail("texts", "invalid") }
        }
        guard errors.isEmpty else { throw HubError(.unprocessableEntity, "validation_failed", errors: errors) }
        return p
    }

    /// Namen in `{{…}}`, die keine bekannten Platzhalter sind.
    static func unknownPlaceholders(_ text: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: "\\{\\{\\s*([^}]*?)\\s*\\}\\}") else { return [] }
        return re.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { m in
            Range(m.range(at: 1), in: text).map { String(text[$0]) }
        }.filter { !placeholders.contains($0) }
    }

    /// Ersetzt `{{name}}` durch die Werte (in Swift, nie in Typst); unbekannte Namen gibt es nach `parse` nicht.
    static func fill(_ text: String, _ values: [String: String]) -> String {
        guard let re = try? NSRegularExpression(pattern: "\\{\\{\\s*([a-z_]+)\\s*\\}\\}") else { return text }
        var out = "", last = text.startIndex
        for m in re.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let whole = Range(m.range, in: text), let name = Range(m.range(at: 1), in: text) else { continue }
            out += text[last..<whole.lowerBound]
            out += values[String(text[name])] ?? ""
            last = whole.upperBound
        }
        return out + text[last...]
    }

    /// Dokument in kanonischer Form (wie gespeichert und ausgeliefert).
    var document: [String: Any] {
        var o: [String: Any] = ["schema": Self.schema, "base": "standard", "font": font, "colors": ["accent": accent, "text": text]]
        if let logo { o["logo"] = ["sha256": logo.sha256, "width_mm": logo.widthMM, "align": logo.align] }
        var texts: [String: Any] = [:]
        if let headerText { texts["header"] = headerText }
        if let footerText { texts["footer"] = footerText }
        if !texts.isEmpty { o["texts"] = texts }
        return o
    }

    var canonicalJSON: String {
        String(decoding: (try? JSONSerialization.data(withJSONObject: document, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data("{}".utf8), as: UTF8.self)
    }

    static func fromStored(_ json: String) throws -> InvoiceLayoutParams { try parse(json: Data(json.utf8)) }
}

/// Layout, mit dem ein Beleg gerendert wird: Schlüssel und Version (für die Zustandszeile), Parameter und Logo-Bytes. `standard` = Standardlayout ohne Parameter.
struct InvoiceRenderLayout: Sendable {
    let key: String
    let version: Int
    let params: InvoiceLayoutParams?
    let logo: Data?
    let logoType: String?

    init(key: String, version: Int, params: InvoiceLayoutParams?, logo: Data? = nil, logoType: String? = nil) {
        self.key = key; self.version = version; self.params = params; self.logo = logo; self.logoType = logoType
    }

    static let standard = InvoiceRenderLayout(key: InvoiceStandardLayout.key, version: InvoiceStandardLayout.version, params: nil)

    var logoFileName: String? {
        guard logo != nil, let logoType else { return nil }
        return logoType == "image/jpeg" ? "logo.jpg" : "logo.png"
    }
}

/// Prüfung hochgeladener Logos: nur PNG und JPEG, Bytes passend zum angegebenen Typ, Größe und Pixelmaße begrenzt. Das Bild wird hier nicht dekodiert;
/// das tut Typst im Worker in einem eigenen Prozess mit Speicher- und Zeitlimit (die Maßgrenze begrenzt den Speicher beim Dekodieren).
enum InvoiceLogo {
    static let maxBytes = 512 * 1024
    static let maxPixels = 2000
    static let types = ["image/png", "image/jpeg"]

    struct Info: Equatable { let contentType: String; let width: Int; let height: Int }

    static func detect(_ d: [UInt8]) -> String? {
        if d.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) { return "image/png" }
        if d.starts(with: [0xFF, 0xD8, 0xFF]) { return "image/jpeg" }
        return nil
    }

    /// `contentType` ist der angegebene Typ (schon auf `types` geprüft). Fehler: 422 Feld `logo` mit `type_mismatch`, `invalid` oder `dimensions`.
    static func inspect(_ data: Data, contentType: String) throws -> Info {
        let d = [UInt8](data)
        guard !d.isEmpty else { throw InvoiceError.invalid("logo", "invalid") }
        guard detect(d) == contentType else { throw InvoiceError.invalid("logo", "type_mismatch") }
        guard let (w, h) = contentType == "image/png" ? png(d) : jpeg(d) else { throw InvoiceError.invalid("logo", "invalid") }
        guard (1...maxPixels).contains(w), (1...maxPixels).contains(h) else { throw InvoiceError.invalid("logo", "dimensions") }
        return Info(contentType: contentType, width: w, height: h)
    }

    private static func be32(_ d: [UInt8], _ i: Int) -> Int { Int(d[i]) << 24 | Int(d[i + 1]) << 16 | Int(d[i + 2]) << 8 | Int(d[i + 3]) }

    /// PNG: Signatur, Chunks mit gültiger CRC bis `IEND` am Ende, `IHDR` zuerst, mindestens ein `IDAT`. Rückgabe: Breite, Höhe.
    static func png(_ d: [UInt8]) -> (Int, Int)? {
        var i = 8, size: (Int, Int)?, sawData = false
        while i + 12 <= d.count {
            let length = be32(d, i)
            guard length >= 0, length <= d.count, i + 12 + length <= d.count else { return nil }
            let type = String(decoding: d[(i + 4)..<(i + 8)], as: UTF8.self)
            let body = Array(d[(i + 4)..<(i + 8 + length)])
            guard UInt32(be32(d, i + 8 + length)) == crc32(body) else { return nil }
            if size == nil {
                guard type == "IHDR", length == 13 else { return nil }
                size = (be32(d, i + 8), be32(d, i + 12))
            }
            if type == "IDAT" { sawData = true }
            i += 12 + length
            if type == "IEND" { return i == d.count && sawData ? size : nil }
        }
        return nil
    }

    /// JPEG: Segmente ab SOI bis zum ersten SOF (Maße); Datei muss mit EOI enden.
    static func jpeg(_ d: [UInt8]) -> (Int, Int)? {
        guard d.count >= 4, d[d.count - 2] == 0xFF, d[d.count - 1] == 0xD9 else { return nil }
        var i = 2
        while i + 4 <= d.count {
            guard d[i] == 0xFF else { return nil }
            let marker = d[i + 1]
            if marker == 0xFF { i += 1; continue }
            let length = Int(d[i + 2]) << 8 | Int(d[i + 3])
            guard length >= 2, i + 2 + length <= d.count else { return nil }
            if [0xC0, 0xC1, 0xC2, 0xC3, 0xC5, 0xC6, 0xC7, 0xC9, 0xCA, 0xCB, 0xCD, 0xCE, 0xCF].contains(marker) {
                guard length >= 7 else { return nil }
                return (Int(d[i + 7]) << 8 | Int(d[i + 8]), Int(d[i + 5]) << 8 | Int(d[i + 6]))
            }
            if marker == 0xDA || marker == 0xD9 { return nil }
            i += 2 + length
        }
        return nil
    }

    private static let crcTable: [UInt32] = (0..<256).map { n -> UInt32 in
        var c = UInt32(n)
        for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1 }
        return c
    }

    static func crc32(_ bytes: [UInt8]) -> UInt32 {
        var c: UInt32 = 0xFFFFFFFF
        for b in bytes { c = crcTable[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
        return c ^ 0xFFFFFFFF
    }
}
