import XCTVapor
import Fluent
import SQLKit
import Crypto
@testable import HubKit

// WP-O2: Tests mit der echten Engine (ocrmypdf, Tesseract deu+eng, Ghostscript, poppler). Laufen im Worker-Image (`scripts/ocr-container-test.sh`);
// ohne Werkzeuge werden sie mit Meldung übersprungen. Alle Eingaben werden hier selbst erzeugt (Text aus dem Test, gezeichnet mit DejaVu Sans, bzw. PostScript).

enum OCRTestTools {
    static func which(_ name: String) -> Bool {
        (ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin").split(separator: ":").contains { FileManager.default.isExecutableFile(atPath: "\($0)/\(name)") }
    }
    /// Wirft XCTSkip mit Begründung, wenn ein Werkzeug fehlt.
    static func require() throws {
        for tool in ["ocrmypdf", "tesseract", "gs", "pdftotext", "pdfinfo", "python3"] where !which(tool) {
            throw XCTSkip("OCR-Test übersprungen: \(tool) nicht installiert (läuft im Worker-Image, siehe scripts/ocr-container-test.sh)")
        }
        guard FileManager.default.fileExists(atPath: Synth.font) else { throw XCTSkip("OCR-Test übersprungen: Schrift \(Synth.font) fehlt") }
    }

    static let referenceLines = [
        "Rechnung Nummer 2026-0815 vom 7. November 2026",
        "Sehr geehrte Damen und Herren, für die Lieferung der Büromöbel",
        "berechnen wir Ihnen den Gesamtbetrag von 1.234,50 Euro.",
        "Bitte überweisen Sie den Betrag innerhalb von 14 Tagen.",
        "Mit freundlichen Grüßen, Musterfirma Beispielstadt GmbH"]
    /// Schwelle der Wortfehlerrate für saubere, synthetische 300-dpi-Seiten (Annahme: echte Scans sind schlechter; Messwert im Handoff).
    static let maxWordErrorRate = 0.10

    static func words(_ s: String) -> [String] {
        s.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
    }

    /// Wortfehlerrate = Levenshtein-Distanz über Wörter / Anzahl Referenzwörter.
    static func wordErrorRate(reference: String, hypothesis: String) -> Double {
        let r = words(reference), h = words(hypothesis)
        guard !r.isEmpty else { return h.isEmpty ? 0 : 1 }
        var prev = Array(0...h.count)
        for i in 1...r.count {
            var cur = [i] + Array(repeating: 0, count: h.count)
            if h.count > 0 {
                for j in 1...h.count { cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (r[i - 1] == h[j - 1] ? 0 : 1)) }
            }
            prev = cur
        }
        return Double(prev[h.count]) / Double(r.count)
    }
}

/// Erzeugt synthetische Dokumente mit Python/Pillow (Bild), PostScript/Ghostscript (Textschicht) und zlib (Dekompressionsbombe).
enum Synth {
    static let font = "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf"

    static func run(_ exe: String, _ args: [String], dir: URL, timeout: TimeInterval = 120) async throws -> OCRProcessResult {
        try await OCRProcess.run(exe, args, workDir: dir, timeout: timeout, environment: ["LC_ALL": "C.UTF-8"])
    }

    /// Eine Seite je Eintrag in `pages` (Zeilen durch \n). A4 bei 300 dpi, schwarzer Text auf weiß. Ausgabe PNG (eine Seite) oder PDF (mehrere Seiten möglich).
    static func scan(_ out: URL, pages: [String], dir: URL) async throws {
        let script = """
        import sys
        from PIL import Image, ImageDraw, ImageFont
        out, font = sys.argv[1], sys.argv[2]
        f = ImageFont.truetype(font, 44)
        imgs = []
        for page in sys.argv[3:]:
            im = Image.new("L", (2480, 3508), 255)
            d = ImageDraw.Draw(im)
            y = 300
            for line in page.split("\\n"):
                d.text((250, y), line, font=f, fill=0)
                y += 120
            imgs.append(im)
        if out.endswith(".pdf"):
            imgs[0].save(out, "PDF", resolution=300.0, save_all=True, append_images=imgs[1:])
        else:
            imgs[0].save(out, dpi=(300, 300))
        """
        let r = try await run("python3", ["-I", "-c", script, out.path, font] + pages, dir: dir)
        guard r.exitCode == 0 else { throw XCTSkip("Pillow-Erzeugung fehlgeschlagen: \(r.stderr.prefix(200))") }
    }

    /// PDF mit echter Textschicht (Ghostscript aus PostScript, nur ASCII), `pages` Seiten.
    static func textPDF(_ out: URL, pages: Int, dir: URL) async throws {
        var ps = "%!PS\n/Helvetica findfont 16 scalefont setfont\n"
        for p in 1...pages {
            for (i, line) in ["Rechnung Nummer 4711 fuer Beispielfirma", "Seite \(p) Gesamtbetrag 99 Euro netto", "Bitte ueberweisen Sie innerhalb von 14 Tagen"].enumerated() {
                ps += "72 \(750 - i * 30) moveto (\(line)) show\n"
            }
            ps += "showpage\n"
        }
        let src = dir.appendingPathComponent("text-\(UUID().uuidString).ps")
        try Data(ps.utf8).write(to: src)
        let r = try await run("gs", ["-q", "-dBATCH", "-dNOPAUSE", "-sDEVICE=pdfwrite", "-sOutputFile=\(out.path)", src.path], dir: dir)
        guard r.exitCode == 0 else { throw XCTSkip("Ghostscript-Erzeugung fehlgeschlagen: \(r.stderr.prefix(200))") }
    }

    /// Dekompressionsbombe: PNG, deklariert w×h Graustufen (Nullbytes), auf der Platte wenige MB.
    static func pngBomb(_ out: URL, side: Int, dir: URL) async throws {
        let script = """
        import struct, sys, zlib
        out, w = sys.argv[1], int(sys.argv[2])
        def chunk(t, d):
            return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xffffffff)
        comp = zlib.compressobj(9)
        row = b"\\x00" * (w + 1)
        data = b"".join(comp.compress(row) for _ in range(w)) + comp.flush()
        open(out, "wb").write(b"\\x89PNG\\r\\n\\x1a\\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, w, 8, 0, 0, 0, 0)) + chunk(b"IDAT", data) + chunk(b"IEND", b""))
        """
        let r = try await run("python3", ["-I", "-c", script, out.path, String(side)], dir: dir)
        guard r.exitCode == 0 else { throw XCTSkip("Bombe konnte nicht erzeugt werden: \(r.stderr.prefix(200))") }
    }
}

class OCRToolTestCase: XCTestCase {
    var dir: URL!
    override func setUp() async throws {
        try OCRTestTools.require()
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("lh-o2-tools-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDown() async throws { if let dir { try? FileManager.default.removeItem(at: dir) } }

    func work() throws -> URL {
        let u = dir.appendingPathComponent("w-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }
}

final class DMSOCRToolTests: OCRToolTestCase {

    /// AK-O2-1: Synthetisches Scan-PDF (nur Bild, deutscher Text mit Umlauten) -> OCR liefert die Soll-Wörter; Wortfehlerrate unter der Schwelle; Archivversion ist PDF/A.
    func testAKO2_1_scanPdfYieldsExpectedWordsWithinWordErrorRate() async throws {
        let input = dir.appendingPathComponent("scan.pdf")
        try await Synth.scan(input, pages: [OCRTestTools.referenceLines.joined(separator: "\n")], dir: dir)
        let engine = OCRToolEngine(config: OCRConfig())
        let w = try work()
        let result = try await engine.extract(input: input, mime: "application/pdf", workDir: w)
        XCTAssertTrue(result.usedOCR); XCTAssertEqual(result.engine, "ocrmypdf"); XCTAssertEqual(result.lang, "de"); XCTAssertEqual(result.pages, 1)
        let wer = OCRTestTools.wordErrorRate(reference: OCRTestTools.referenceLines.joined(separator: "\n"), hypothesis: result.text)
        print("AK-O2-1 Wortfehlerrate (PDF-Scan): \(wer)")
        XCTAssertLessThanOrEqual(wer, OCRTestTools.maxWordErrorRate, "Text: \(result.text)")
        let low = result.text.lowercased()
        for expected in ["rechnung", "büromöbel", "grüßen", "überweisen", "november"] { XCTAssertTrue(low.contains(expected), "fehlt: \(expected)") }
        // Archivversion: durchsuchbares PDF/A-2b, liegt im Arbeitsverzeichnis
        let archive = try XCTUnwrap(result.archive)
        XCTAssertTrue(archive.path.hasPrefix(w.path))
        let bytes = try Data(contentsOf: archive)
        XCTAssertTrue(bytes.starts(with: Array("%PDF-".utf8)))
        XCTAssertTrue(result.pdfa)
        XCTAssertNotNil(bytes.range(of: Data("pdfaid:part".utf8)), "XMP-Kennung PDF/A fehlt")
        XCTAssertNotNil(bytes.range(of: Data("<pdfaid:part>2</pdfaid:part>".utf8)) ?? bytes.range(of: Data("pdfaid:part=\"2\"".utf8)), "PDF/A-2 erwartet")
    }

    /// AK-O2-1 mit Bilddatei (PNG, ohne eigene DPI-Angabe im Dokument-Container).
    func testAKO2_1_pngImageYieldsExpectedWords() async throws {
        let input = dir.appendingPathComponent("scan.png")
        try await Synth.scan(input, pages: [OCRTestTools.referenceLines.joined(separator: "\n")], dir: dir)
        let result = try await OCRToolEngine().extract(input: input, mime: "image/png", workDir: try work())
        let wer = OCRTestTools.wordErrorRate(reference: OCRTestTools.referenceLines.joined(separator: "\n"), hypothesis: result.text)
        print("AK-O2-1 Wortfehlerrate (PNG): \(wer)")
        XCTAssertLessThanOrEqual(wer, OCRTestTools.maxWordErrorRate, "Text: \(result.text)")
        XCTAssertNotNil(result.archive)
    }

    /// AK-O2-1: Englische Seite wird als `en` erkannt.
    func testAKO2_1_englishPageDetected() async throws {
        let input = dir.appendingPathComponent("en.pdf")
        try await Synth.scan(input, pages: ["Please find the invoice for the order that we are sending to you.\nThe amount is due within fourteen days of the date of this letter."], dir: dir)
        let result = try await OCRToolEngine().extract(input: input, mime: "application/pdf", workDir: try work())
        XCTAssertEqual(result.lang, "en"); XCTAssertTrue(result.text.lowercased().contains("invoice"))
    }

    /// AK-O2-2: PDF mit Textschicht wird ohne OCR ausgelesen (Engine `pdftotext`, kein Archiv, keine Rasterung) und ist schnell.
    func testAKO2_2_textLayerPdfExtractedWithoutOcr() async throws {
        let input = dir.appendingPathComponent("text.pdf")
        try await Synth.textPDF(input, pages: 3, dir: dir)
        let w = try work()
        let start = Date()
        let result = try await OCRToolEngine().extract(input: input, mime: "application/pdf", workDir: w)
        XCTAssertFalse(result.usedOCR); XCTAssertEqual(result.engine, "pdftotext"); XCTAssertNil(result.archive); XCTAssertEqual(result.pages, 3)
        for expected in ["rechnung nummer 4711", "seite 1", "seite 3", "gesamtbetrag 99 euro", "innerhalb von 14 tagen"] {
            XCTAssertTrue(result.text.lowercased().replacingOccurrences(of: "  ", with: " ").contains(expected), "fehlt: \(expected) in \(result.text)")
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 20, "ohne OCR in Sekunden")
        XCTAssertEqual((try FileManager.default.contentsOfDirectory(atPath: w.path)).filter { !$0.hasPrefix(".") }.count, 0, "ohne OCR entsteht keine Datei")
    }

    /// Gemischtes PDF (Seite 1 Textschicht, Seite 2 Scan): OCR nur mit `--skip-text`, Text beider Seiten, Archiv vorhanden.
    func testMixedPdfGetsOcrOnlyWhereNeeded() async throws {
        let a = dir.appendingPathComponent("a.pdf"), b = dir.appendingPathComponent("b.pdf"), mixed = dir.appendingPathComponent("mixed.pdf")
        try await Synth.textPDF(a, pages: 1, dir: dir)
        try await Synth.scan(b, pages: ["Büromöbel Lieferschein Nummer 77 vom Montag"], dir: dir)
        let r = try await Synth.run("gs", ["-q", "-dBATCH", "-dNOPAUSE", "-sDEVICE=pdfwrite", "-sOutputFile=\(mixed.path)", a.path, b.path], dir: dir)
        XCTAssertEqual(r.exitCode, 0, r.stderr)
        let result = try await OCRToolEngine().extract(input: mixed, mime: "application/pdf", workDir: try work())
        XCTAssertTrue(result.usedOCR); XCTAssertEqual(result.pages, 2)
        let low = result.text.lowercased()
        XCTAssertTrue(low.contains("beispielfirma")); XCTAssertTrue(low.contains("lieferschein"), result.text)
    }

    /// AK-O2-3 (Engine): Das Original wird nicht verändert (Hash vor/nach, Datei bleibt schreibgeschützt lesbar); Ausgaben nur im Arbeitsverzeichnis.
    func testAKO2_3_engineLeavesInputByteIdenticalAndWritesOnlyInWorkDir() async throws {
        let inDir = dir.appendingPathComponent("in-ro")
        try FileManager.default.createDirectory(at: inDir, withIntermediateDirectories: true)
        let input = inDir.appendingPathComponent("scan.pdf")
        try await Synth.scan(input, pages: [OCRTestTools.referenceLines.joined(separator: "\n")], dir: dir)
        let before = Data(SHA256.hash(data: try Data(contentsOf: input)))
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: input.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: inDir.path)   // keine neuen Dateien neben dem Original
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: inDir.path) }
        let result = try await OCRToolEngine().extract(input: input, mime: "application/pdf", workDir: try work())
        XCTAssertTrue(result.usedOCR)
        XCTAssertEqual(Data(SHA256.hash(data: try Data(contentsOf: input))), before)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: inDir.path), ["scan.pdf"])
        XCTAssertNotEqual(Data(SHA256.hash(data: try Data(contentsOf: try XCTUnwrap(result.archive)))), before, "Archivversion ist eine eigene Datei")
    }

    /// AK-O2-4: Zeitlimit greift bei echter OCR (1 s Gesamtbudget für ein mehrseitiges Scan-PDF) -> wiederholbarer Fehler `ocr_timeout`, kein hängender Prozess.
    func testAKO2_4_ocrTimeoutIsEnforcedAndRetryable() async throws {
        let input = dir.appendingPathComponent("many.pdf")
        try await Synth.scan(input, pages: Array(repeating: OCRTestTools.referenceLines.joined(separator: "\n"), count: 6), dir: dir)
        var config = OCRConfig(); config.timeoutSeconds = 1
        let start = Date()
        do {
            _ = try await OCRToolEngine(config: config).extract(input: input, mime: "application/pdf", workDir: try work())
            XCTFail("Zeitlimit muss greifen")
        } catch let f as OCRFailure {
            XCTAssertEqual(f, OCRFailure(code: "ocr_timeout", permanent: false))
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 60)
    }

    /// AK-O2-4: Seitenlimit (Seitenbombe) -> `too_many_pages`, dauerhaft, ohne OCR zu starten.
    func testAKO2_4_pageLimitRejectsPageBomb() async throws {
        let input = dir.appendingPathComponent("pages.pdf")
        try await Synth.textPDF(input, pages: 6, dir: dir)
        var config = OCRConfig(); config.maxPages = 5
        do {
            _ = try await OCRToolEngine(config: config).extract(input: input, mime: "application/pdf", workDir: try work())
            XCTFail("Seitenlimit muss greifen")
        } catch let f as OCRFailure { XCTAssertEqual(f, OCRFailure(code: "too_many_pages", permanent: true)) }
    }

    /// AK-O2-4: Dekompressionsbombe (PNG, 25 000 × 25 000 px = 625 Mpx, wenige MB auf der Platte) wird abgelehnt, ohne den Rechner zu fluten:
    /// Fehler (kein Erfolg), begrenzte Zeit, Speicherlimit im Prozess.
    func testAKO2_4_decompressionBombIsRejected() async throws {
        let bomb = dir.appendingPathComponent("bomb.png")
        try await Synth.pngBomb(bomb, side: 25_000, dir: dir)
        XCTAssertLessThan(try XCTUnwrap(FileManager.default.attributesOfItem(atPath: bomb.path)[.size] as? Int), 60_000_000)
        var config = OCRConfig(); config.memoryMB = 3072; config.timeoutSeconds = 120
        let start = Date()
        do {
            _ = try await OCRToolEngine(config: config).extract(input: bomb, mime: "image/png", workDir: try work())
            XCTFail("Bombe darf nicht verarbeitet werden")
        } catch let f as OCRFailure {
            XCTAssertTrue(["input_invalid", "ocr_failed", "ocr_timeout"].contains(f.code), f.code)
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 150)
    }

    /// Verschlüsseltes/kaputtes PDF -> dauerhafter Fehler (kein Wiederholen).
    func testGarbagePdfIsPermanentFailure() async throws {
        let input = dir.appendingPathComponent("broken.pdf")
        try Data("%PDF-1.4\nkein gueltiges Dokument\n".utf8).write(to: input)
        do {
            _ = try await OCRToolEngine().extract(input: input, mime: "application/pdf", workDir: try work())
            XCTFail("kaputtes PDF darf nicht gelingen")
        } catch let f as OCRFailure { XCTAssertTrue(f.permanent, f.code) }
    }

    /// AK-O2-5: Im Container mit read-only Root (`LH_READONLY_ROOT=1`, gesetzt von scripts/ocr-container-test.sh) gelingt die OCR vollständig,
    /// obwohl außerhalb von /tmp (tmpfs) nirgends geschrieben werden kann. Beweis: Root ist wirklich schreibgeschützt, und die OCR läuft trotzdem durch.
    func testAKO2_5_ocrWorksWithReadOnlyRootAndTmpfsOnly() async throws {
        guard ProcessInfo.processInfo.environment["LH_READONLY_ROOT"] == "1" else {
            throw XCTSkip("AK-O2-5 braucht den Container mit read-only Root (LH_READONLY_ROOT=1), siehe scripts/ocr-container-test.sh")
        }
        for path in ["/usr/local/lh-probe", "/etc/lh-probe", "/var/lh-probe", "/root/lh-probe", "/lh-probe"] {
            XCTAssertFalse(FileManager.default.createFile(atPath: path, contents: Data("x".utf8)), "Root muss schreibgeschützt sein: \(path)")
        }
        XCTAssertTrue(FileManager.default.createFile(atPath: "/tmp/lh-probe-\(UUID().uuidString)", contents: Data("x".utf8)), "tmpfs /tmp muss beschreibbar sein")
        let input = dir.appendingPathComponent("scan.pdf")
        try await Synth.scan(input, pages: [OCRTestTools.referenceLines.joined(separator: "\n")], dir: dir)
        var config = OCRConfig(); config.tempRoot = "/tmp"
        let w = URL(fileURLWithPath: "/tmp", isDirectory: true).appendingPathComponent("lh-ro-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: w, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: w) }
        let result = try await OCRToolEngine(config: config).extract(input: input, mime: "application/pdf", workDir: w)
        XCTAssertTrue(result.usedOCR)
        XCTAssertLessThanOrEqual(OCRTestTools.wordErrorRate(reference: OCRTestTools.referenceLines.joined(separator: "\n"), hypothesis: result.text), OCRTestTools.maxWordErrorRate)
    }
}

/// Ganzer Weg mit echter Engine: Upload -> Job -> Worker (Handler mit OCRToolEngine) -> Text in der Suche, Archivversion, Original byte-identisch (AK-O2-3).
final class DMSOCREndToEndTests: DMSOCRTestBase {
    func testAKO2_3_endToEndOriginalByteIdenticalAndTextSearchable() async throws {
        try OCRTestTools.require()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lh-o2-e2e-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let scan = dir.appendingPathComponent("scan.pdf")
        try await Synth.scan(scan, pages: [OCRTestTools.referenceLines.joined(separator: "\n")], dir: dir)
        let original = try Data(contentsOf: scan)

        let w = try await world()
        let up = try await upload(w.alice, w.tenantA, original, query: "filename=scan.pdf")
        XCTAssertEqual(up.status, .created, "\(up.json)")
        let docID = up.json["id"] as! String
        let originalSha = try await scalar("SELECT sha256 AS v FROM dms_document_files WHERE document_id = '\(docID)' AND role = 'original'", as: String.self)
        XCTAssertEqual(originalSha, hex(original))
        let fileRow = try await scalar("SELECT concat_ws('|', f.sha256, f.size_bytes, f.storage_key) AS v FROM files f JOIN dms_document_files d ON d.file_id = f.id WHERE d.document_id = '\(docID)' AND d.role = 'original'", as: String.self)

        let worker = makeWorker(OCRToolEngine())
        let run = Task { await worker.run() }
        try await waitFor("OCR fertig", timeout: 180) {
            let st = try await itemState(docID)
            return st == "done" || st.hasPrefix("failed")
        }
        worker.requestShutdown(); await run.value
        try await aEq(try await itemState(docID), "done")

        // Original: Bytes im Speicher und Metadaten unverändert
        let orig = try await raw(app2, .GET, base(w.tenantA) + "/documents/\(docID)/file", token: w.alice.token)
        XCTAssertEqual(hex(orig.body), hex(original)); XCTAssertEqual(orig.body, original)
        try await aEq(try await scalar("SELECT concat_ws('|', f.sha256, f.size_bytes, f.storage_key) AS v FROM files f JOIN dms_document_files d ON d.file_id = f.id WHERE d.document_id = '\(docID)' AND d.role = 'original'", as: String.self), fileRow)
        // Archivversion: eigene Datei (PDF), nicht identisch zum Original
        let arch = try await raw(app1, .GET, base(w.tenantA) + "/documents/\(docID)/file?role=archive", token: w.alice.token)
        XCTAssertEqual(arch.status, .ok); XCTAssertTrue(arch.body.starts(with: Array("%PDF-".utf8))); XCTAssertNotEqual(hex(arch.body), hex(original))
        // Text im Suchindex: Volltextsuche mit Wortstamm findet das Dokument über den OCR-Text (Titel „scan“ enthält das Wort nicht)
        let hit = try await raw(app2, .GET, base(w.tenantA) + "/search?q=B%C3%BCrom%C3%B6bel&fuzzy=false", token: w.alice.token)
        XCTAssertEqual((hit.json["items"] as? [[String: Any]])?.compactMap { $0["id"] as? String }.map { $0.uppercased() }, [docID.uppercased()], "\(hit.json)")
        let st = try await processing(w, docID)
        XCTAssertEqual(st.json["phase"] as? String, "done"); XCTAssertEqual((st.json["text"] as? [String: Any])?["engine"] as? String, "ocrmypdf")
    }
}
