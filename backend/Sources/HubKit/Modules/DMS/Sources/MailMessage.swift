import Foundation

// WP-D4: schlanker MIME-Parser (RFC 5322/2045/2047/2231) für den Mail-Ingest und ein Minimal-PDF-Schreiber für den optionalen Mailtext.
// Bewusst klein: Multipart (rekursiv, begrenzt), base64/quoted-printable, Kopfzeilen mit Encoded-Words, Dateinamen (auch RFC 2231). Kein HTML-Rendering.
// Die Eingabe ist unvertrauenswürdig: Tiefe, Teileanzahl und Gesamtgröße sind begrenzt, es wird nichts ausgeführt oder nachgeladen.

struct MailAttachment: Sendable, Equatable {
    var filename: String?
    var contentType: String
    var isInline: Bool
    var hasContentID: Bool
    var data: Data
}

struct ParsedMail: Sendable {
    var messageID: String?
    var from: String?          // nur die Adresse (addr-spec, kleingeschrieben)
    var subject: String?
    var date: String?
    var textBody: String?
    /// WP-D7: HTML-Teil (decodiert, höchstens `maxHTMLBytes`) und daraus abgeleiteter Klartext. Der HTML-Teil wird nur gespeichert, nie ausgewertet oder nachgeladen.
    var htmlBody: String?
    var htmlText: String?
    var attachments: [MailAttachment]

    /// Text für Suchindex und Extraktion: Kopfzeilen (Betreff, Von, Datum) und der aussagekräftigere Mailtext (der längere aus Klartext- und HTML-Teil).
    var indexText: String {
        let plain = (textBodyIsPlain ? textBody : nil)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let html = htmlText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let body = html.count > plain.count ? html : plain
        var head = ""
        if let subject, !subject.isEmpty { head += "Betreff: \(subject)\n" }
        if let from, !from.isEmpty { head += "Von: \(from)\n" }
        if let date, !date.isEmpty { head += "Datum: \(date)\n" }
        return head + (head.isEmpty ? "" : "\n") + body
    }
    fileprivate var textBodyIsPlain = false
}

enum MailParser {
    static let maxDepth = 8
    static let maxParts = 200
    static let maxHTMLBytes = 2 * 1024 * 1024

    struct Headers {
        var fields: [(name: String, value: String)] = []
        func first(_ name: String) -> String? { fields.first { $0.name == name.lowercased() }?.value }
    }

    static func parse(_ raw: Data) -> ParsedMail {
        let (headers, body) = split(raw)
        var mail = ParsedMail(messageID: nil, from: nil, subject: nil, date: nil, textBody: nil, htmlBody: nil, htmlText: nil, attachments: [])
        mail.messageID = headers.first("message-id").map { $0.trimmingCharacters(in: .whitespaces) }.flatMap { $0.isEmpty ? nil : String($0.prefix(998)) }
        mail.from = headers.first("from").flatMap(address)
        mail.subject = headers.first("subject").map { decodeWords($0) }.map { String($0.prefix(300)) }
        mail.date = headers.first("date").map { String($0.prefix(100)) }
        var parts = 0
        walk(headers: headers, body: body, depth: 0, parts: &parts, mail: &mail)
        if let html = mail.htmlBody {
            mail.htmlText = HTMLText.extract(html)
            if mail.textBody == nil { mail.textBody = mail.htmlText }
        }
        return mail
    }

    // MARK: Aufbau

    /// Trennt Kopf und Rumpf an der ersten Leerzeile (CRLF oder LF), entfaltet Kopfzeilen.
    static func split(_ raw: Data) -> (Headers, Data) {
        let bytes = [UInt8](raw)
        var i = 0, headEnd = bytes.count, bodyStart = bytes.count
        while i < bytes.count {
            if bytes[i] == 0x0A {
                if i + 1 < bytes.count, bytes[i + 1] == 0x0A { headEnd = i; bodyStart = i + 2; break }
                if i + 2 < bytes.count, bytes[i + 1] == 0x0D, bytes[i + 2] == 0x0A { headEnd = i; bodyStart = i + 3; break }
            }
            i += 1
        }
        let head = String(decoding: bytes[0..<min(headEnd, bytes.count)], as: UTF8.self).replacingOccurrences(of: "\r\n", with: "\n")
        var headers = Headers()
        var current: (String, String)?
        for line in head.split(separator: "\n", omittingEmptySubsequences: false).map({ $0.hasSuffix("\r") ? $0.dropLast() : $0 }) {
            if let first = line.first, first == " " || first == "\t" {
                if current != nil { current!.1 += " " + line.trimmingCharacters(in: .whitespaces) }
            } else {
                if let c = current { headers.fields.append(c) }
                if let colon = line.firstIndex(of: ":") {
                    current = (line[..<colon].trimmingCharacters(in: .whitespaces).lowercased(), line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces))
                } else { current = nil }
            }
        }
        if let c = current { headers.fields.append(c) }
        return (headers, Data(bytes[min(bodyStart, bytes.count)...]))
    }

    private static func walk(headers: Headers, body: Data, depth: Int, parts: inout Int, mail: inout ParsedMail) {
        parts += 1
        guard depth <= maxDepth, parts <= maxParts else { return }
        let (type, params) = parameters(headers.first("content-type") ?? "text/plain")
        if type.hasPrefix("multipart/"), let boundary = params["boundary"], !boundary.isEmpty {
            for part in multipartParts(body, boundary: boundary) {
                let (h, b) = split(part)
                walk(headers: h, body: b, depth: depth + 1, parts: &parts, mail: &mail)
                if parts > maxParts { return }
            }
            return
        }
        let (disposition, dparams) = parameters(headers.first("content-disposition") ?? "")
        let decoded = decodeTransfer(body, encoding: headers.first("content-transfer-encoding")?.lowercased() ?? "7bit")
        var filename = dparams["filename"] ?? params["name"]
        filename = filename.map { decodeWords($0) }
        if type.hasPrefix("text/"), filename == nil, disposition != "attachment" {
            let text = decodeText(decoded, charset: params["charset"])
            if type == "text/plain" { mail.textBody = (mail.textBodyIsPlain ? mail.textBody.map { $0 + "\n\n" } ?? "" : "") + text; mail.textBodyIsPlain = true }
            else if type == "text/html", mail.htmlBody == nil { mail.htmlBody = String(text.prefix(maxHTMLBytes)) }
            return
        }
        if type.hasPrefix("message/") { return }   // eingebettete Mails werden nicht ausgepackt
        mail.attachments.append(MailAttachment(filename: filename, contentType: type, isInline: disposition == "inline",
                                               hasContentID: headers.first("content-id") != nil, data: decoded))
    }

    static func multipartParts(_ body: Data, boundary: String) -> [Data] {
        let bytes = [UInt8](body)
        let delimiter = [UInt8]("--\(boundary)".utf8)
        var positions: [Int] = []
        var i = 0
        while i + delimiter.count <= bytes.count {
            if (i == 0 || bytes[i - 1] == 0x0A), bytes[i..<(i + delimiter.count)].elementsEqual(delimiter) { positions.append(i); i += delimiter.count } else { i += 1 }
        }
        var result: [Data] = []
        for (n, start) in positions.enumerated() {
            let after = start + delimiter.count
            if after + 1 < bytes.count, bytes[after] == 0x2D, bytes[after + 1] == 0x2D { break }   // Schlussgrenze
            var lineEnd = after
            while lineEnd < bytes.count, bytes[lineEnd] != 0x0A { lineEnd += 1 }
            let contentStart = min(lineEnd + 1, bytes.count)
            var contentEnd = n + 1 < positions.count ? positions[n + 1] : bytes.count
            if contentEnd > contentStart, bytes[contentEnd - 1] == 0x0A { contentEnd -= 1 }
            if contentEnd > contentStart, bytes[contentEnd - 1] == 0x0D { contentEnd -= 1 }
            if contentEnd >= contentStart { result.append(Data(bytes[contentStart..<contentEnd])) }
        }
        return result
    }

    // MARK: Felder

    /// `type/subtype; a=b; c="d"` -> (kleingeschriebener Typ, Parameter). Unterstützt RFC 2231 (`filename*=UTF-8''...` und `filename*0=`).
    static func parameters(_ value: String) -> (String, [String: String]) {
        var pieces: [String] = [], current = "", quoted = false
        for ch in value {
            if ch == "\"" { quoted.toggle(); current.append(ch) } else if ch == ";", !quoted { pieces.append(current); current = "" } else { current.append(ch) }
        }
        pieces.append(current)
        let type = pieces.first?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
        var params: [String: String] = [:]
        var continuations: [String: [Int: String]] = [:]
        for piece in pieces.dropFirst() {
            guard let eq = piece.firstIndex(of: "=") else { continue }
            var name = piece[..<eq].trimmingCharacters(in: .whitespaces).lowercased()
            var val = piece[piece.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if val.hasPrefix("\""), val.hasSuffix("\""), val.count >= 2 { val = String(val.dropFirst().dropLast()).replacingOccurrences(of: "\\\"", with: "\"") }
            if let star = name.firstIndex(of: "*") {
                let base = String(name[..<star]), rest = name[name.index(after: star)...]
                let extended = rest.hasSuffix("*") || rest.isEmpty
                let index = Int(rest.replacingOccurrences(of: "*", with: "")) ?? 0
                continuations[base, default: [:]][index] = extended ? "*" + val : val
                continue
            }
            name = String(name)
            params[name] = val
        }
        for (base, pieces) in continuations {
            var joined = ""
            var charset = "utf-8"
            for index in pieces.keys.sorted() {
                var p = pieces[index]!
                if p.hasPrefix("*") {
                    p.removeFirst()
                    if index == 0, let q1 = p.firstIndex(of: "'"), let q2 = p[p.index(after: q1)...].firstIndex(of: "'") {
                        charset = String(p[..<q1]).lowercased(); p = String(p[p.index(after: q2)...])
                    }
                    joined += percentDecode(p, charset: charset)
                } else { joined += p }
            }
            params[base] = joined
        }
        return (type, params)
    }

    private static func percentDecode(_ s: String, charset: String) -> String {
        var bytes: [UInt8] = []
        let u = Array(s.utf8)
        var i = 0
        while i < u.count {
            if u[i] == 0x25, i + 2 < u.count, let v = UInt8(String(decoding: u[(i + 1)...(i + 2)], as: UTF8.self), radix: 16) { bytes.append(v); i += 3 } else { bytes.append(u[i]); i += 1 }
        }
        return decodeText(Data(bytes), charset: charset)
    }

    /// Adresse aus `Name <a@b>` oder `a@b`; kleingeschrieben, höchstens 320 Zeichen. Ohne `@` nil.
    static func address(_ field: String) -> String? {
        let decoded = decodeWords(field)
        var candidate = decoded
        if let lt = decoded.lastIndex(of: "<"), let gt = decoded[lt...].firstIndex(of: ">") { candidate = String(decoded[decoded.index(after: lt)..<gt]) }
        candidate = candidate.trimmingCharacters(in: CharacterSet(charactersIn: " \t\"'<>")).lowercased()
        guard candidate.contains("@"), candidate.count <= 320, !candidate.contains(where: { $0.isWhitespace || $0.isNewline }) else { return nil }
        return candidate
    }

    /// RFC 2047 Encoded-Words (`=?charset?B|Q?...?=`).
    static func decodeWords(_ s: String) -> String {
        guard s.contains("=?") else { return s }
        var result = "", rest = Substring(s), previousEncoded = false
        while let start = rest.range(of: "=?") {
            let before = rest[..<start.lowerBound]
            guard let word = encodedWord(rest[start.lowerBound...]) else { result += rest[..<start.upperBound]; rest = rest[start.upperBound...]; previousEncoded = false; continue }
            if !(previousEncoded && before.allSatisfy { $0 == " " || $0 == "\t" }) { result += before }
            result += word.text
            rest = rest[word.end...]
            previousEncoded = true
        }
        return result + rest
    }

    private static func encodedWord(_ s: Substring) -> (text: String, end: Substring.Index)? {
        let parts = s.dropFirst(2).split(separator: "?", maxSplits: 3, omittingEmptySubsequences: false)
        guard parts.count == 4, parts[3].hasPrefix("=") else { return nil }
        let charset = String(parts[0]), enc = parts[1].lowercased()
        let payload = parts[2]
        let end = payload.endIndex
        guard let close = s.range(of: "?=", range: payload.startIndex..<s.endIndex) else { return nil }
        let data: Data
        if enc == "b" { guard let d = Data(base64Encoded: String(payload)) else { return nil }; data = d }
        else if enc == "q" { data = decodeQuotedPrintable(Data(String(payload).replacingOccurrences(of: "_", with: " ").utf8), header: true) }
        else { return nil }
        _ = end
        return (decodeText(data, charset: charset), close.upperBound)
    }

    // MARK: Inhalte

    static func decodeTransfer(_ data: Data, encoding: String) -> Data {
        switch encoding {
        case "base64": return Data(base64Encoded: String(decoding: data.filter { $0 != 0x0A && $0 != 0x0D && $0 != 0x20 && $0 != 0x09 }, as: UTF8.self), options: [.ignoreUnknownCharacters]) ?? Data()
        case "quoted-printable": return decodeQuotedPrintable(data, header: false)
        default: return data
        }
    }

    static func decodeQuotedPrintable(_ data: Data, header: Bool) -> Data {
        let u = [UInt8](data)
        var out: [UInt8] = []
        var i = 0
        while i < u.count {
            if u[i] == 0x3D {
                if i + 1 < u.count, u[i + 1] == 0x0A { i += 2; continue }                          // weicher Umbruch
                if i + 2 < u.count, u[i + 1] == 0x0D, u[i + 2] == 0x0A { i += 3; continue }
                if i + 2 < u.count, let v = UInt8(String(decoding: u[(i + 1)...(i + 2)], as: UTF8.self), radix: 16) { out.append(v); i += 3; continue }
            }
            out.append(u[i]); i += 1
        }
        return Data(out)
    }

    static func decodeText(_ data: Data, charset: String?) -> String {
        switch charset?.lowercased() {
        case "iso-8859-1", "latin1", "iso8859-1", "us-ascii", "ascii": return String(data: data, encoding: .isoLatin1) ?? ""
        case "windows-1252", "cp1252": return String(data: data, encoding: .windowsCP1252) ?? String(data: data, encoding: .isoLatin1) ?? ""
        case "iso-8859-15": return String(data: data, encoding: .isoLatin1) ?? ""
        default: return String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
        }
    }

    /// Grobes Entfernen von Tags (nur als Rückfall, wenn es keinen Text-Teil gibt).
    static func stripHTML(_ html: String) -> String {
        var s = html
        for tag in ["style", "script"] {
            while let a = s.range(of: "<\(tag)", options: .caseInsensitive), let b = s.range(of: "</\(tag)>", options: .caseInsensitive, range: a.upperBound..<s.endIndex) { s.removeSubrange(a.lowerBound..<b.upperBound) }
        }
        s = s.replacingOccurrences(of: "<br", with: "\n<br", options: .caseInsensitive).replacingOccurrences(of: "</p>", with: "\n\n", options: .caseInsensitive)
        var out = "", inTag = false
        for ch in s { if ch == "<" { inTag = true } else if ch == ">" { inTag = false } else if !inTag { out.append(ch) } }
        return out.replacingOccurrences(of: "&nbsp;", with: " ").replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
    }
}

/// Minimaler PDF-Schreiber für den Mailtext (Helvetica, WinAnsi/Latin-1, A4). Zeichen außerhalb von Latin-1 werden zu `?`.
enum MailBodyPDF {
    static let linesPerPage = 58, columns = 92, maxLines = 2000

    static func render(subject: String?, from: String?, date: String?, body: String) -> Data {
        var lines: [String] = []
        for (label, value) in [("Von", from), ("Datum", date), ("Betreff", subject)] { if let value, !value.isEmpty { lines += wrap("\(label): \(value)") } }
        lines.append("")
        for raw in body.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false) { lines += wrap(String(raw)) }
        if lines.count > maxLines { lines = Array(lines.prefix(maxLines)) }
        let pages = stride(from: 0, to: max(lines.count, 1), by: linesPerPage).map { Array(lines[$0..<min($0 + linesPerPage, lines.count)]) }

        var objects: [Data] = []   // Objekt n steht an Index n-1
        let pageCount = pages.count
        objects.append(Data("<< /Type /Catalog /Pages 2 0 R >>".utf8))
        objects.append(Data("<< /Type /Pages /Kids [\((0..<pageCount).map { "\(4 + $0 * 2) 0 R" }.joined(separator: " "))] /Count \(pageCount) >>".utf8))
        objects.append(Data("<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>".utf8))
        for (n, pageLines) in pages.enumerated() {
            let contentID = 5 + n * 2
            objects.append(Data("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 595 842] /Resources << /Font << /F1 3 0 R >> >> /Contents \(contentID) 0 R >>".utf8))
            var stream = Data("BT /F1 10 Tf 12 TL 50 790 Td\n".utf8)
            for line in pageLines { stream.append(Data("(".utf8)); stream.append(escape(line)); stream.append(Data(") Tj T*\n".utf8)) }
            stream.append(Data("ET".utf8))
            var obj = Data("<< /Length \(stream.count) >>\nstream\n".utf8)
            obj.append(stream); obj.append(Data("\nendstream".utf8))
            objects.append(obj)
        }
        var pdf = Data("%PDF-1.4\n".utf8)
        var offsets: [Int] = []
        for (i, o) in objects.enumerated() {
            offsets.append(pdf.count)
            pdf.append(Data("\(i + 1) 0 obj\n".utf8)); pdf.append(o); pdf.append(Data("\nendobj\n".utf8))
        }
        let xref = pdf.count
        pdf.append(Data("xref\n0 \(objects.count + 1)\n0000000000 65535 f \n".utf8))
        for o in offsets { pdf.append(Data((String(format: "%010d", o) + " 00000 n \n").utf8)) }
        pdf.append(Data("trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n".utf8))
        return pdf
    }

    private static func wrap(_ line: String) -> [String] {
        let scalars = Array(line.unicodeScalars.map { $0.value == 9 ? " " : $0 }.filter { $0.value >= 32 })
        if scalars.isEmpty { return [""] }
        return stride(from: 0, to: scalars.count, by: columns).map { String(String.UnicodeScalarView(scalars[$0..<min($0 + columns, scalars.count)])) }
    }

    private static func escape(_ s: String) -> Data {
        var out = Data()
        for scalar in s.unicodeScalars {
            let v = scalar.value
            if v == 0x28 || v == 0x29 || v == 0x5C { out.append(0x5C); out.append(UInt8(v)) }
            else if v >= 32, v < 127 { out.append(UInt8(v)) }
            else if v >= 160, v <= 255 { out.append(Data(String(format: "\\%03o", v).utf8)) }
            else { out.append(0x3F) }
        }
        return out
    }
}
