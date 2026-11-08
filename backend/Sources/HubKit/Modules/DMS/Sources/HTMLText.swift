import Foundation

// WP-D7: HTML -> Klartext für Mailtexte (Suchindex, Extraktion). Eigener, schlanker Einmal-Durchlauf ohne Baum und ohne Rekursion (keine Parser-Abhängigkeit,
// keine Lizenzfrage). Unvertrauenswürdige Eingabe: Eingabe auf `maxInput` Zeichen, Ausgabe auf `maxOutput` begrenzt, Tag-Länge begrenzt, nichts wird geladen oder ausgeführt
// (Bilder, Tracking-Pixel, Stylesheets, Skripte und Links werden nie aufgerufen; `<img>`, `<link>`, `<script>`, `<style>`, `<head>`, Kommentare entfallen).
// Tabellen werden zu Zeilen (Zellen mit „ | “), <br>/<p>/<div>/<li>/<h1…> zu Zeilenumbrüchen, Entitäten dekodiert.

enum HTMLText {
    static let maxInput = 2 * 1024 * 1024
    static let maxOutput = 500_000
    static let maxTagLength = 4096

    private static let blockTags: Set<String> = ["p", "div", "br", "tr", "table", "ul", "ol", "li", "h1", "h2", "h3", "h4", "h5", "h6", "section", "article", "header", "footer", "blockquote", "pre", "hr", "address", "dl", "dt", "dd", "form", "center", "body", "html"]
    private static let skipTags: Set<String> = ["script", "style", "head", "noscript", "template", "object", "embed", "iframe", "svg", "math", "title"]

    private static let entities: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ", "euro": "€", "pound": "£", "yen": "¥", "cent": "¢", "copy": "©", "reg": "®",
        "auml": "ä", "ouml": "ö", "uuml": "ü", "Auml": "Ä", "Ouml": "Ö", "Uuml": "Ü", "szlig": "ß", "eacute": "é", "egrave": "è", "agrave": "à", "aacute": "á",
        "ndash": "–", "mdash": "—", "hellip": "…", "bull": "•", "middot": "·", "laquo": "«", "raquo": "»", "lsquo": "‘", "rsquo": "’", "ldquo": "“", "rdquo": "”",
        "sect": "§", "deg": "°", "times": "×", "shy": "", "zwnj": "", "zwj": "", "ensp": " ", "emsp": " ", "thinsp": " ", "para": "¶", "plusmn": "±", "micro": "µ"]

    static func extract(_ html: String) -> String {
        var scalars = Array(html.unicodeScalars.prefix(maxInput))
        scalars = scalars.map { $0 == "\u{0}" ? " " : $0 }
        var out = String.UnicodeScalarView()
        var i = 0
        var cellOpen = false     // in der aktuellen Zeile steht schon eine Zelle
        var capped = false
        var count = 0

        var atLineStart = true
        func emit(_ s: Unicode.Scalar) { if count < maxOutput { out.append(s); count += 1; atLineStart = s == "\n" } else { capped = true } }
        func emitString(_ s: String) { for u in s.unicodeScalars { emit(u) } }
        func newline() { if !atLineStart { emit("\n") }; cellOpen = false }

        while i < scalars.count, !capped {
            let c = scalars[i]
            if c == "<" {
                // Kommentar
                if starts(scalars, i, "<!--") {
                    if let end = find(scalars, "-->", from: i + 4) { i = end + 3 } else { i = scalars.count }
                    continue
                }
                // ein Tag beginnt unmittelbar mit Buchstabe, `/`, `!` oder `?`; „a < b“ ist Text
                guard i + 1 < scalars.count, scalars[i + 1].properties.isAlphabetic || scalars[i + 1] == "/" || scalars[i + 1] == "!" || scalars[i + 1] == "?",
                      let close = findTagEnd(scalars, from: i + 1), close - i <= maxTagLength else { emit(c); i += 1; continue }   // kein Tag: als Text
                let inner = String(String.UnicodeScalarView(scalars[(i + 1)..<close]))
                i = close + 1
                var name = ""
                var closing = false
                var idx = inner.startIndex
                if inner.hasPrefix("/") { closing = true; idx = inner.index(after: idx) }
                if inner.hasPrefix("!") || inner.hasPrefix("?") { continue }   // Doctype, Verarbeitungsanweisung
                while idx < inner.endIndex, inner[idx].isLetter || inner[idx].isNumber { name.append(inner[idx]); idx = inner.index(after: idx) }
                name = name.lowercased()
                guard !name.isEmpty else { emit("<"); continue }
                if !closing, skipTags.contains(name), !inner.hasSuffix("/") {
                    // Inhalt bis zum passenden Endtag verwerfen (nicht verschachtelt auswerten); fehlt er, entfällt der Rest
                    if let end = findCI(scalars, "</" + name, from: i), let gt = findTagEnd(scalars, from: end + 2) { i = gt + 1 } else { i = scalars.count }
                    continue
                }
                if name == "td" || name == "th" {
                    if !closing { if cellOpen { emitString(" | ") }; cellOpen = true }
                } else if name == "li", !closing { newline(); emitString("- ") }
                else if blockTags.contains(name) { newline() }
                continue
            }
            if c == "&" {
                var j = i + 1
                while j < scalars.count, j - i <= 12, scalars[j] != ";", scalars[j] != "&", scalars[j] != "<", scalars[j] != " " { j += 1 }
                if j < scalars.count, scalars[j] == ";", let decoded = decode(String(String.UnicodeScalarView(scalars[(i + 1)..<j]))) { emitString(decoded); i = j + 1; continue }
            }
            emit(c); i += 1
        }
        return normalize(String(out))
    }

    // MARK: Hilfen

    private static func starts(_ s: [Unicode.Scalar], _ i: Int, _ p: String) -> Bool {
        let u = Array(p.unicodeScalars)
        guard i + u.count <= s.count else { return false }
        return zip(s[i..<(i + u.count)], u).allSatisfy { $0 == $1 }
    }

    private static func find(_ s: [Unicode.Scalar], _ p: String, from: Int) -> Int? {
        let u = Array(p.unicodeScalars)
        guard !u.isEmpty, s.count >= u.count, from <= s.count - u.count else { return nil }
        var i = from
        while i <= s.count - u.count { if s[i] == u[0], starts(s, i, p) { return i }; i += 1 }
        return nil
    }

    private static func findCI(_ s: [Unicode.Scalar], _ p: String, from: Int) -> Int? {
        let u = Array(p.lowercased().unicodeScalars)
        guard s.count >= u.count, from <= s.count - u.count else { return nil }
        var i = from
        while i <= s.count - u.count {
            var ok = true
            for k in 0..<u.count where Character(s[i + k]).lowercased().unicodeScalars.first != u[k] { ok = false; break }
            if ok { return i }
            i += 1
        }
        return nil
    }

    /// Ende eines Tags (`>` außerhalb von Anführungszeichen), höchstens `maxTagLength` weit.
    private static func findTagEnd(_ s: [Unicode.Scalar], from: Int) -> Int? {
        var quote: Unicode.Scalar?
        var i = from
        while i < s.count, i - from <= maxTagLength {
            let c = s[i]
            if let q = quote { if c == q { quote = nil } } else if c == "\"" || c == "'" { quote = c } else if c == ">" { return i } else if c == "<" { return nil }
            i += 1
        }
        return nil
    }

    private static func decode(_ name: String) -> String? {
        if name.hasPrefix("#") {
            let digits = name.dropFirst()
            let value = digits.hasPrefix("x") || digits.hasPrefix("X") ? UInt32(digits.dropFirst(), radix: 16) : UInt32(digits)
            guard let v = value, v > 0, let u = Unicode.Scalar(v), v != 0xFEFF else { return nil }
            return String(Character(u))
        }
        return entities[name]
    }

    /// Leerraum zusammenfassen, Zeilen trimmen, höchstens eine Leerzeile in Folge.
    private static func normalize(_ s: String) -> String {
        var lines: [String] = []
        var blank = 0
        for raw in s.split(separator: "\n", omittingEmptySubsequences: false) {
            var line = ""
            var lastSpace = true
            for ch in raw.unicodeScalars {
                let isSpace = ch == " " || ch == "\t" || ch == "\r" || ch == "\u{00A0}" || ch == "\u{200B}" || ch == "\u{2009}" || ch.properties.generalCategory == .control
                if isSpace { if !lastSpace { line.append(" "); lastSpace = true } } else { line.unicodeScalars.append(ch); lastSpace = false }
            }
            line = line.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line == "|" { blank += 1; if blank <= 1, !lines.isEmpty { lines.append("") } } else { blank = 0; lines.append(line) }
        }
        while lines.last == "" { lines.removeLast() }
        return lines.joined(separator: "\n")
    }
}

// WP-H10 Befund 4: Das gespeicherte HTML-Derivat einer Mail wird beim Speichern entschärft. Entfernt werden `<meta>` (u. a. `http-equiv=refresh`), `<base>` und `<link>`;
// `<form>` wird zu `<div>`, `action`/`formaction` entfallen, damit nichts navigiert oder absendet. Mehrfach angewandt bis zum Fixpunkt (verschachtelte Tarnung wie `<me<meta>ta …>`).
// Zusätzlich liefert `DMSUpload.response` jedes Dokument mit `default-src 'none'; sandbox; frame-src 'none'; base-uri 'none'; form-action 'none'`.
enum HTMLSafety {
    private static let removeTags = try! NSRegularExpression(pattern: "<(?:meta|base|link)(?![A-Za-z0-9])[^>]*>?", options: [.caseInsensitive])
    private static let formOpen = try! NSRegularExpression(pattern: "<form(?![A-Za-z0-9])", options: [.caseInsensitive])
    private static let formClose = try! NSRegularExpression(pattern: "</form(?![A-Za-z0-9])", options: [.caseInsensitive])
    private static let actionAttr = try! NSRegularExpression(pattern: "(?<![A-Za-z0-9_-])(?:form)?action\\s{0,5}=\\s{0,5}(?:\"[^\"]*\"|'[^']*'|[^\\s>]*)", options: [.caseInsensitive])

    static func neutralize(_ html: String) -> String {
        var s = html
        for _ in 0..<8 {
            let before = s
            s = replace(removeTags, in: s, with: "")
            s = replace(formOpen, in: s, with: "<div")
            s = replace(formClose, in: s, with: "</div")
            s = replace(actionAttr, in: s, with: "")
            if s == before { break }
        }
        return s
    }

    private static func replace(_ re: NSRegularExpression, in s: String, with template: String) -> String {
        re.stringByReplacingMatches(in: s, options: [], range: NSRange(location: 0, length: (s as NSString).length), withTemplate: template)
    }
}
