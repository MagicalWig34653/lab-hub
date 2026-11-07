import Foundation

// WP-O2 (MODUL-DMS 5.2/5.3, ADR 0006, F-07/F-21): Textextraktion.
// - PDF mit Textschicht (jede Seite genug Buchstaben): Text per `pdftotext`, keine OCR, keine Archivversion (das Original ist bereits durchsuchbar).
// - Sonst (Scan, Bild, gemischtes PDF): `ocrmypdf` (Tesseract deu+eng, Seiten mit Text bleiben, Ausgabe PDF/A-2b), Text per `pdftotext` aus der Archivversion.
// Alle Dateien liegen im Arbeitsverzeichnis (tmpfs, ADR 0003). Werkzeuge laufen nur als eigene Prozesse mit Zeit- und Speicherlimit.

/// Fehler der Extraktion mit stabilem Code (kurzer Token, keine Nutzdaten). `permanent`: Wiederholen ist sinnlos.
struct OCRFailure: Error, Equatable, CustomStringConvertible {
    let code: String
    let permanent: Bool
    var description: String { code }
}

struct OCRExtraction: Sendable {
    let text: String
    let lang: String          // "de" | "en"
    let engine: String        // z. B. "pdftotext", "ocrmypdf"
    let archive: URL?         // PDF (bevorzugt PDF/A-2b) im Arbeitsverzeichnis
    let pages: Int?
    let usedOCR: Bool
    let pdfa: Bool
}

protocol OCRExtracting: Sendable {
    func extract(input: URL, mime: String, workDir: URL) async throws -> OCRExtraction
}

struct OCRConfig: Sendable, Equatable {
    var timeoutSeconds: Int = 600          // gesamte OCR eines Dokuments
    var toolTimeoutSeconds: Int = 60       // pdfinfo/pdftotext
    var memoryMB: Int = 4096               // Adressraumlimit je Werkzeugprozess (Linux)
    var maxPages: Int = 300
    var languages: String = "deu+eng"
    var minLettersPerPage: Int = 25        // darunter gilt eine Seite als „ohne Textschicht“
    var maxTextCharacters: Int = 500_000   // tsvector-Grenze (1 MB) schützen, S1-Handoff
    var dehyphenate: Bool = true
    var jobs: Int = 2
    var maxImageMegapixels: Int = 200      // Pillow bricht erst bei dem Doppelten ab, daher hier niedrig halten (A0 bei 300 dpi sind rund 140)
    var tempRoot: String = NSTemporaryDirectory()

    static func fromEnvironment(_ env: [String: String] = ProcessInfo.processInfo.environment) -> OCRConfig {
        var c = OCRConfig()
        func int(_ key: String, _ range: ClosedRange<Int>) -> Int? { env[key].flatMap(Int.init).flatMap { range.contains($0) ? $0 : nil } }
        if let v = int("OCR_TIMEOUT_SECONDS", 1...86_400) { c.timeoutSeconds = v }
        if let v = int("OCR_MEMORY_MB", 256...262_144) { c.memoryMB = v }
        if let v = int("OCR_MAX_PAGES", 1...100_000) { c.maxPages = v }
        if let v = int("OCR_JOBS", 1...32) { c.jobs = v }
        if let v = env["OCR_LANGUAGES"], v.range(of: "^[a-z_]{3,10}(\\+[a-z_]{3,10})*$", options: .regularExpression) != nil { c.languages = v }
        if env["OCR_DEHYPHENATE"] == "false" { c.dehyphenate = false }
        if let v = env["OCR_TMPDIR"], v.hasPrefix("/") { c.tempRoot = v }
        return c
    }
}

struct OCRToolEngine: OCRExtracting {
    let config: OCRConfig
    init(config: OCRConfig = .fromEnvironment()) { self.config = config }

    private var memoryBytes: Int64 { Int64(config.memoryMB) * 1024 * 1024 }

    /// Prüft beim Worker-Start, dass alle Werkzeuge und Sprachpakete vorhanden sind (sonst würden alle Aufträge in die Quarantäne laufen).
    static func preflight(config: OCRConfig, workDir: URL) async -> String? {
        for (tool, args) in [("pdftotext", ["-v"]), ("pdfinfo", ["-v"]), ("ocrmypdf", ["--version"]), ("tesseract", ["--version"]), ("gs", ["--version"])] {
            guard let r = try? await OCRProcess.run(tool, args, workDir: workDir, timeout: 30), r.exitCode == 0 || tool == "pdftotext" || tool == "pdfinfo" else {
                return "Werkzeug fehlt oder startet nicht: \(tool)"
            }
        }
        guard let langs = try? await OCRProcess.run("tesseract", ["--list-langs"], workDir: workDir, timeout: 30) else { return "tesseract --list-langs fehlgeschlagen" }
        let have = Set((langs.stdout + "\n" + langs.stderr).split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) })
        for l in config.languages.split(separator: "+") where !have.contains(String(l)) { return "Tesseract-Sprachpaket fehlt: \(l)" }
        return nil
    }

    func extract(input: URL, mime: String, workDir: URL) async throws -> OCRExtraction {
        let env = Self.environment(for: workDir)
        if mime == "application/pdf" {
            let pages = try await pageCount(input, workDir: workDir, env: env)
            if let pages, pages > config.maxPages { throw OCRFailure(code: "too_many_pages", permanent: true) }
            if let layer = try await textLayer(of: input, workDir: workDir, env: env, expectedPages: pages) {
                return OCRExtraction(text: normalize(layer), lang: Self.detectLanguage(layer), engine: "pdftotext", archive: nil, pages: pages, usedOCR: false, pdfa: false)
            }
        }
        return try await runOCR(input: input, mime: mime, workDir: workDir, env: env)
    }

    static func environment(for workDir: URL) -> [String: String] {
        ["HOME": workDir.path, "TMPDIR": workDir.path, "TEMP": workDir.path, "XDG_CACHE_HOME": workDir.appendingPathComponent(".cache").path,
         "XDG_CONFIG_HOME": workDir.appendingPathComponent(".config").path, "OMP_THREAD_LIMIT": "1", "LC_ALL": "C.UTF-8"]
    }

    private func pageCount(_ pdf: URL, workDir: URL, env: [String: String]) async throws -> Int? {
        let r = try await OCRProcess.run("pdfinfo", [pdf.path], workDir: workDir, timeout: TimeInterval(config.toolTimeoutSeconds), memoryBytes: memoryBytes, environment: env)
        if r.timedOut { throw OCRFailure(code: "ocr_timeout", permanent: false) }
        guard r.exitCode == 0 else {   // nicht lesbar: verschlüsselt oder defekt, beides ohne Wiederholungsaussicht
            throw OCRFailure(code: r.stderr.localizedCaseInsensitiveContains("password") ? "pdf_encrypted" : "input_invalid", permanent: true)
        }
        for line in r.stdout.split(whereSeparator: \.isNewline) where line.hasPrefix("Pages:") {
            return Int(line.dropFirst(6).trimmingCharacters(in: .whitespaces))
        }
        return nil
    }

    /// Text der vorhandenen Schicht, wenn **jede** Seite genug Buchstaben trägt; sonst nil (dann OCR mit `--skip-text`).
    private func textLayer(of pdf: URL, workDir: URL, env: [String: String], expectedPages: Int?) async throws -> String? {
        guard let text = try await pdfText(pdf, workDir: workDir, env: env, failQuietly: true) else { return nil }
        var pages = text.components(separatedBy: "\u{0C}")
        if pages.last?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true { pages.removeLast() }
        guard !pages.isEmpty else { return nil }
        if let expectedPages, pages.count != expectedPages { return nil }
        for p in pages where p.unicodeScalars.reduce(0, { $0 + (CharacterSet.letters.contains($1) ? 1 : 0) }) < config.minLettersPerPage { return nil }
        return pages.joined(separator: "\n\n")
    }

    private func pdfText(_ pdf: URL, workDir: URL, env: [String: String], failQuietly: Bool = false) async throws -> String? {
        let out = workDir.appendingPathComponent("text-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: out) }
        let r = try await OCRProcess.run("pdftotext", ["-enc", "UTF-8", "-layout", pdf.path, out.path], workDir: workDir,
                                         timeout: TimeInterval(config.toolTimeoutSeconds), memoryBytes: memoryBytes, environment: env)
        if r.timedOut { throw OCRFailure(code: "ocr_timeout", permanent: false) }
        guard r.exitCode == 0, let data = FileManager.default.contents(atPath: out.path) else {
            if failQuietly { return nil }
            throw OCRFailure(code: "text_extraction_failed", permanent: false)
        }
        return String(decoding: data, as: UTF8.self)
    }

    private func runOCR(input: URL, mime: String, workDir: URL, env: [String: String]) async throws -> OCRExtraction {
        let output = workDir.appendingPathComponent("archive.pdf")
        func args(_ type: String) -> [String] {
            var a = ["--language", config.languages, "--output-type", type, "--skip-text", "--rotate-pages", "--jobs", String(config.jobs),
                     "--tesseract-timeout", String(config.timeoutSeconds), "--max-image-mpixels", String(config.maxImageMegapixels), "--quiet"]
            if mime.hasPrefix("image/") { a += ["--image-dpi", "300"] }
            return a + [input.path, output.path]
        }
        var pdfa = true
        var r = try await OCRProcess.run("ocrmypdf", args("pdfa-2"), workDir: workDir, timeout: TimeInterval(config.timeoutSeconds), memoryBytes: memoryBytes, environment: env)
        if !r.timedOut, r.exitCode == 4 || r.exitCode == 10 {   // PDF/A-Erzeugung nicht möglich: durchsuchbares PDF ohne PDF/A-Anspruch
            try? FileManager.default.removeItem(at: output)
            pdfa = false
            r = try await OCRProcess.run("ocrmypdf", args("pdf"), workDir: workDir, timeout: TimeInterval(config.timeoutSeconds), memoryBytes: memoryBytes, environment: env)
        }
        if r.timedOut { throw OCRFailure(code: "ocr_timeout", permanent: false) }
        switch r.exitCode {
        case 0: break
        case 2: throw OCRFailure(code: "input_invalid", permanent: true)
        case 8: throw OCRFailure(code: "pdf_encrypted", permanent: true)
        case 3: throw OCRFailure(code: "ocr_tool_missing", permanent: false)
        default: throw OCRFailure(code: "ocr_failed", permanent: false)
        }
        guard FileManager.default.fileExists(atPath: output.path) else { throw OCRFailure(code: "ocr_failed", permanent: false) }
        let pages = try await pageCount(output, workDir: workDir, env: env)
        if let pages, pages > config.maxPages { throw OCRFailure(code: "too_many_pages", permanent: true) }
        let text = try await pdfText(output, workDir: workDir, env: env) ?? ""
        return OCRExtraction(text: normalize(text), lang: Self.detectLanguage(text), engine: "ocrmypdf", archive: output, pages: pages, usedOCR: true, pdfa: pdfa)
    }

    // MARK: Normalisierung (MODUL-DMS 5.3)

    func normalize(_ raw: String) -> String {
        var t = raw.replacingOccurrences(of: "\0", with: "").replacingOccurrences(of: "\u{0C}", with: "\n\n").replacingOccurrences(of: "\r\n", with: "\n")
        t = t.precomposedStringWithCanonicalMapping
        if config.dehyphenate { t = Self.dehyphenate(t) }
        t = t.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.count > config.maxTextCharacters { t = String(t.prefix(config.maxTextCharacters)) }
        return t
    }

    /// „Rech-\nnung“ -> „Rechnung“ (nur wenn die Folgezeile klein beginnt, damit „Ost-\nWest“ und Aufzählungen nicht zerstört werden).
    static func dehyphenate(_ s: String) -> String {
        s.replacingOccurrences(of: "(?<=\\p{L})-[ \\t]*\\n[ \\t]*(?=\\p{Ll})", with: "", options: .regularExpression)
    }

    /// Einfache Heuristik: Stoppwörter zählen; bei Gleichstand Deutsch (Standardsprache des Systems).
    static func detectLanguage(_ text: String) -> String {
        let de: Set<String> = ["der", "die", "das", "und", "ist", "nicht", "mit", "für", "von", "den", "dem", "ein", "eine", "auf", "zu", "im", "sie", "wir", "bitte", "rechnung"]
        let en: Set<String> = ["the", "and", "is", "not", "with", "for", "of", "to", "in", "you", "we", "please", "invoice", "that", "this", "are", "be", "on"]
        var d = 0, e = 0
        for w in text.lowercased().split(whereSeparator: { !$0.isLetter }).prefix(5000) {
            let s = String(w)
            if de.contains(s) { d += 1 }
            if en.contains(s) { e += 1 }
        }
        return e > d ? "en" : "de"
    }
}
