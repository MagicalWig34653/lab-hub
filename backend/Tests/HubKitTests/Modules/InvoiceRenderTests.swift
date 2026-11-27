import XCTVapor
import SQLKit
import Crypto
@testable import HubCore
@testable import HubKit
@testable import HubModuleInvoice

// WP-R6b: Render-Werkzeugkette (Typst, qpdf) und Standardlayout 1. Nur synthetische Belege (`Tests/Fixtures/invoice-render/`).
// Zwei Gruppen:
//  - Ohne Werkzeuge lauffähig: Aufbereitung der Belegdaten, Factur-X-XMP, Zeitlimit, Prozessumgebung, Image-Definition.
//  - Mit Typst/pdftotext/qpdf (Worker-Test-Image, `scripts/render-test.sh`): Referenzfälle, Bytegleichheit, Anhang. Fehlen die Werkzeuge,
//    werden diese Tests mit Meldung übersprungen. Lokal außerhalb des Images: `LH_TEST_TYPST`, `LH_TEST_FONT_DIR`, `LH_TEST_QPDF`, `LH_TEST_RENDER_TMP`.
//  `LH_RENDER_OUT` schreibt die erzeugten PDFs für veraPDF (`scripts/verapdf-check.sh`), `LH_RENDER_UPDATE=1` schreibt die Referenzen neu.

enum RenderFixtures {
    static let cases = ["invoice", "quote", "order_confirmation", "delivery_note", "credit_note"]
    /// Fälle, die zusätzlich mit eingebettetem XML erzeugt werden.
    static let attachmentCases = ["invoice", "credit_note"]
    static var repo: URL {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { url.deleteLastPathComponent() }
        return url
    }
    static var directory: URL { repo.appendingPathComponent("backend/Tests/Fixtures/invoice-render") }
    static func data(_ name: String) throws -> Data { try Data(contentsOf: directory.appendingPathComponent(name)) }
    static func document(_ name: String, _ change: (inout [String: Any]) -> Void = { _ in }) throws -> Data {
        var object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data(name + ".json")) as? [String: Any])
        change(&object)
        return try JSONSerialization.data(withJSONObject: object)
    }

    static var environment: [String: String] { ProcessInfo.processInfo.environment }
    static var tools: InvoiceRenderTools {
        var tools = InvoiceRenderTools()
        if let v = environment["LH_TEST_TYPST"] { tools.typst = v }
        if let v = environment["LH_TEST_FONT_DIR"] { tools.fontDirectory = v }
        if let v = environment["LH_TEST_QPDF"] { tools.qpdf = v }
        tools.tempRoot = environment["LH_TEST_RENDER_TMP"] ?? NSTemporaryDirectory()
        return tools
    }

    static func scratch() throws -> URL {
        let dir = URL(fileURLWithPath: tools.tempRoot).appendingPathComponent("lh-render-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func available(_ tool: String, _ arguments: [String]) async -> Bool {
        guard let dir = try? scratch() else { return false }
        defer { try? FileManager.default.removeItem(at: dir) }
        return (try? await ToolProcess.run(tool, arguments, workDir: dir, timeout: 60))?.exitCode == 0
    }

    static func requireTools(qpdf: Bool = false) async throws {
        var missing: [String] = []
        if await !available(tools.typst, ["--version"]) { missing.append("typst") }
        if !FileManager.default.fileExists(atPath: tools.fontDirectory + "/Inter-Regular.ttf") { missing.append("Schriften") }
        if await !available("pdftotext", ["-v"]) { missing.append("pdftotext") }
        if qpdf, await !available(tools.qpdf, ["--version"]) { missing.append("qpdf") }
        if !missing.isEmpty { throw XCTSkip("Render-Werkzeuge fehlen (\(missing.joined(separator: ", "))); sie laufen im Worker-Test-Image (scripts/render-test.sh)") }
    }

    /// Seitenzahl und Text in Inhaltsreihenfolge, Leerraum je Zeile vereinheitlicht (unabhängig von der poppler-Version).
    static func extract(_ pdf: Data) async throws -> String {
        let dir = try scratch(); defer { try? FileManager.default.removeItem(at: dir) }
        try pdf.write(to: dir.appendingPathComponent("in.pdf"))
        let result = try await ToolProcess.run("pdftotext", ["-raw", "-enc", "UTF-8", "in.pdf", "out.txt"], workDir: dir, timeout: 60)
        XCTAssertEqual(result.exitCode, 0, result.stderr)
        let text = String(decoding: try Data(contentsOf: dir.appendingPathComponent("out.txt")), as: UTF8.self)
        let pages = text.filter { $0 == "\u{0C}" }.count
        let lines = text.replacingOccurrences(of: "\u{0C}", with: "\n=== Seitenende ===\n").split(separator: "\n")
            .map { $0.split(whereSeparator: \.isWhitespace).joined(separator: " ") }.filter { !$0.isEmpty }
        return "Seiten: \(pages)\n" + lines.joined(separator: "\n") + "\n"
    }

    static func sha256(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    static func keep(_ pdf: Data, as name: String) throws {
        guard let out = environment["LH_RENDER_OUT"] else { return }
        try FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
        try pdf.write(to: URL(fileURLWithPath: out).appendingPathComponent(name + ".pdf"))
    }

    static var attachment: InvoiceRenderAttachment {
        get throws { InvoiceRenderAttachment(xml: try data("factur-x.xml")) }
    }
}

// MARK: Ohne Werkzeuge

final class InvoiceRenderDataTests: XCTestCase {

    private func prepared(_ name: String, _ change: (inout [String: Any]) -> Void = { _ in }) throws -> InvoiceRenderData.Prepared {
        try InvoiceRenderData.prepare(RenderFixtures.document(name, change), attach: false)
    }

    private func allText(_ data: InvoiceRenderData) throws -> String { String(decoding: try JSONEncoder().encode(data), as: UTF8.self) }

    /// AK-R6b-1: Beträge, Mengen und Daten deutsch formatiert, aus Dezimal-Strings ohne Gleitkomma.
    func testAKR6b_1_formatsDecimalStrings() {
        XCTAssertEqual(InvoiceRenderFormat.money("1234567.5", currency: "EUR"), "1.234.567,50 €")
        XCTAssertEqual(InvoiceRenderFormat.money("-1234.50", currency: "EUR"), "-1.234,50 €")
        XCTAssertEqual(InvoiceRenderFormat.money("0.1250", currency: "CHF"), "0,125 CHF")
        XCTAssertEqual(InvoiceRenderFormat.money("-0.00", currency: "EUR"), "0,00 €")
        // größer als jede Double-Genauigkeit
        XCTAssertEqual(InvoiceRenderFormat.money("99999999999999.9999", currency: "EUR"), "99.999.999.999.999,9999 €")
        XCTAssertEqual(InvoiceRenderFormat.number("2.5000"), "2,5")
        XCTAssertEqual(InvoiceRenderFormat.number("1000.0000"), "1.000")
        XCTAssertEqual(InvoiceRenderFormat.number("19.0000"), "19")
        XCTAssertEqual(InvoiceRenderFormat.date("2026-11-03"), "03.11.2026")
    }

    /// AK-R6b-1: Positionswerte rechnet der Server (Menge × zweite Menge × Preis − Rabatt, Rundungsregel des Belegs), nie die Vorlage.
    func testAKR6b_1_computesLineValuesWithDecimal() throws {
        let data = try prepared("invoice").data
        XCTAssertEqual(data.rows.map { $0.cells.last ?? "" }, ["149,97 €", "125,00 €", "", "1.062,00 €"])
        XCTAssertEqual(data.rows[1].cells[2], "2,5 × 4 m")
        XCTAssertEqual(data.rows[3].detail, "Rabatt 10 %")
        XCTAssertEqual(data.totals.map(\.label), ["Zwischensumme", "Rabatt 5 %", "Versand (USt 19 %)", "Nettobetrag", "USt 7 % auf 118,75 €", "USt 19 % auf 1.176,37 €", "Gesamtbetrag"])
        XCTAssertEqual(data.totals.map(\.value), ["1.336,97 €", "-66,85 €", "25,00 €", "1.295,12 €", "8,31 €", "223,51 €", "1.526,94 €"])
        XCTAssertEqual(data.notes, ["Bei Zahlung innerhalb von 7 Tagen ab Rechnungsdatum gewähren wir 2 % Skonto."])
    }

    func testAKR6b_1_grossPriceModeShowsIncludedTax() throws {
        let data = try prepared("quote").data
        XCTAssertEqual(data.title, "Angebot")
        XCTAssertEqual(data.totals.map(\.label), ["Gesamtbetrag", "Nettobetrag", "enthaltene USt 19 % auf 2.000,00 €"])
        XCTAssertEqual(data.columns.last?.label, "Gesamt brutto")
        XCTAssertTrue(data.recipientLines.contains("AT"), "\(data.recipientLines)")
    }

    /// Standardlayout: Lieferschein ohne Preise, auch ohne Zusatzkosten, Skonto und Steuerhinweis.
    func testAKR6b_1_deliveryNoteHasNoPrices() throws {
        let data = try prepared("delivery_note") { $0["tax_regime"] = "small_business" }.data
        XCTAssertEqual(data.title, "Lieferschein")
        XCTAssertEqual(data.columns.map(\.key), ["position", "description", "quantity"])
        XCTAssertTrue(data.totals.isEmpty)
        XCTAssertTrue(data.notes.isEmpty)
        let text = try allText(data)
        for price in ["€", "17,77", "8,88", "284,14", "9,99", "Anlieferung", "Skonto", "Rabatt"] { XCTAssertFalse(text.contains(price), price) }
    }

    /// Hinweiszeile je Steuerregime; sie steht nie neben ausgewiesener Steuer.
    func testAKR6b_1_taxRegimeNote() throws {
        let small = try prepared("credit_note").data
        XCTAssertEqual(small.notes, [InvoiceRenderData.smallBusinessNote])
        XCTAssertEqual(small.totals.map(\.label), ["Gesamtbetrag"])
        let standard = try prepared("credit_note") { $0["tax_regime"] = "standard" }.data
        XCTAssertTrue(standard.notes.isEmpty)
        XCTAssertEqual(standard.totals.map(\.label), ["Nettobetrag", "USt 0 % auf -1.234,50 €", "Gesamtbetrag"])
        let contradicting = try prepared("invoice") { $0["tax_regime"] = "small_business" }.data
        XCTAssertFalse(contradicting.notes.contains(InvoiceRenderData.smallBusinessNote))
        XCTAssertTrue(contradicting.totals.contains { $0.label.hasPrefix("USt 19 %") })
    }

    /// Interne Notiz bleibt intern; der Zeitstempel des PDF ist der Finalisierungszeitpunkt.
    func testAKR6b_3_creationTimestampIsFinalizedAt() throws {
        let p = try prepared("invoice")
        XCTAssertEqual(p.createdAt, 1_795_428_930)
        XCTAssertEqual(try prepared("invoice") { $0["finalized_at"] = "2026-11-23T11:15:30+01:00" }.createdAt, 1_795_428_930)
        XCTAssertFalse(try allText(p.data).contains("interne Notiz"))
    }

    func testRejectsDraftsAndBrokenInput() throws {
        for change: (inout [String: Any]) -> Void in [{ $0["status"] = "draft" }, { $0["finalized_at"] = NSNull() }, { $0["number"] = NSNull() }, { $0["sender"] = NSNull() }] {
            XCTAssertThrowsError(try prepared("invoice", change)) { XCTAssertEqual($0 as? InvoiceRenderError, .notFinal) }
        }
        XCTAssertThrowsError(try prepared("invoice") { $0["gross_total"] = "1e5" }) { XCTAssertEqual($0 as? InvoiceRenderError, .invalidDocument("amount")) }
        XCTAssertThrowsError(try InvoiceRenderData.prepare(Data("{}".utf8), attach: false)) { XCTAssertEqual($0 as? InvoiceRenderError, .invalidDocument("json")) }
        XCTAssertThrowsError(try InvoiceRenderData.prepare(RenderFixtures.document("quote"), attach: true)) {
            XCTAssertEqual($0 as? InvoiceRenderError, .invalidDocument("attachment_not_allowed"))
        }
    }

    /// AK-R6b-4: keine Paketimporte, kein `eval`; Nutzerdaten kommen nur über `data.json`.
    func testAKR6b_4_templateImportsNothingAndEvaluatesNothing() {
        let template = InvoiceStandardLayout.template
        XCTAssertFalse(template.contains("@preview"))
        XCTAssertFalse(template.contains("#import"))
        XCTAssertFalse(template.contains("#include"))
        XCTAssertFalse(template.contains("eval("))
        XCTAssertTrue(template.contains("json(\"data.json\")"))
    }

    func testAKR6b_2_facturXMetadataJoinsExistingExtensionList() throws {
        let xmp = "<rdf:RDF><rdf:Description><pdfaExtension:schemas><rdf:Bag><rdf:li>old</rdf:li></rdf:Bag></pdfaExtension:schemas></rdf:Description></rdf:RDF>"
        let out = try XCTUnwrap(FacturXMetadata.insert(into: xmp, conformanceLevel: .en16931))
        XCTAssertEqual(out.components(separatedBy: "<pdfaExtension:schemas>").count, 2, "keine zweite Liste")
        XCTAssertTrue(out.contains("<rdf:li>old</rdf:li>"))
        for expected in ["<pdfaSchema:prefix>fx</pdfaSchema:prefix>", "urn:factur-x:pdfa:CrossIndustryDocument:invoice:1p0#",
                         "<fx:DocumentType>INVOICE</fx:DocumentType>", "<fx:DocumentFileName>factur-x.xml</fx:DocumentFileName>",
                         "<fx:Version>1.0</fx:Version>", "<fx:ConformanceLevel>EN 16931</fx:ConformanceLevel>"] {
            XCTAssertTrue(out.contains(expected), expected)
        }
        XCTAssertNil(FacturXMetadata.insert(into: out, conformanceLevel: .en16931), "nie doppelt")
        XCTAssertNil(FacturXMetadata.insert(into: "<rdf:RDF></rdf:RDF>", conformanceLevel: .en16931), "ohne Liste kein stilles Teilergebnis")
    }

    /// AK-R6b-4: Das Zeitlimit beendet den Prozess.
    func testAKR6b_4_timeoutKillsRenderer() async throws {
        let dir = try RenderFixtures.scratch(); defer { try? FileManager.default.removeItem(at: dir) }
        let fake = dir.appendingPathComponent("typst"), fonts = dir.appendingPathComponent("fonts"), pidFile = dir.appendingPathComponent("pid")
        try Data("#!/bin/sh\necho $$ > '\(pidFile.path)'\nexec sleep 60\n".utf8).write(to: fake)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
        try FileManager.default.createDirectory(at: fonts, withIntermediateDirectories: true)
        for font in InvoiceRenderer.requiredFonts { try Data().write(to: fonts.appendingPathComponent(font)) }
        var tools = RenderFixtures.tools
        tools.typst = fake.path; tools.fontDirectory = fonts.path; tools.timeout = 2; tools.tempRoot = dir.path
        let start = Date()
        do { _ = try await InvoiceRenderer(tools: tools).render(RenderFixtures.document("invoice")); XCTFail("kein Zeitlimit") } catch {
            XCTAssertEqual(error as? InvoiceRenderError, .timeout)
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 20)
        let pid = try XCTUnwrap(pid_t(String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        XCTAssertEqual(kill(pid, 0), -1, "Prozess \(pid) läuft noch")
        let left = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasPrefix("lh-render-") }
        XCTAssertEqual(left, [], "Arbeitsverzeichnis nicht entfernt")
    }

    func testMissingToolsAndFontsAreReported() async throws {
        var tools = RenderFixtures.tools
        tools.fontDirectory = "/nonexistent"
        await assertRender(tools, throws: .toolMissing("fonts"))
        let dir = try RenderFixtures.scratch(); defer { try? FileManager.default.removeItem(at: dir) }
        for font in InvoiceRenderer.requiredFonts { try Data().write(to: dir.appendingPathComponent(font)) }
        tools.fontDirectory = dir.path; tools.typst = "labhub-no-such-typst"
        await assertRender(tools, throws: .toolMissing("typst"))
    }

    private func assertRender(_ tools: InvoiceRenderTools, throws expected: InvoiceRenderError) async {
        do { _ = try await InvoiceRenderer(tools: tools).render(RenderFixtures.document("invoice")); XCTFail("kein Fehler \(expected)") } catch {
            XCTAssertEqual(error as? InvoiceRenderError, expected)
        }
    }

    /// Der Renderer bekommt keine Zugangsdaten des Hubs in seine Umgebung.
    func testToolProcessCanRunWithCleanEnvironment() async throws {
        let dir = try RenderFixtures.scratch(); defer { try? FileManager.default.removeItem(at: dir) }
        setenv("LABHUB_CANARY", "geheim", 1); defer { unsetenv("LABHUB_CANARY") }
        let inherited = try await ToolProcess.run("env", [], workDir: dir, timeout: 20)
        XCTAssertTrue(inherited.stdout.contains("LABHUB_CANARY=geheim"))
        let clean = try await ToolProcess.run("env", [], workDir: dir, timeout: 20, environment: ["HOME": dir.path], inheritEnvironment: false)
        XCTAssertEqual(clean.exitCode, 0, clean.stderr)
        XCTAssertFalse(clean.stdout.contains("LABHUB_CANARY"))
        XCTAssertTrue(clean.stdout.contains("HOME=\(dir.path)"))
    }

    /// AK-R6b-5 / Umfang: Typst per Digest und Schriften mit Prüfsumme in Worker und Worker-Test-Image, nie im API-Image.
    func testWorkerImagesPinTypstAndFontsApiImageHasNone() throws {
        let worker = try String(contentsOf: RenderFixtures.repo.appendingPathComponent("Dockerfile.worker"), encoding: .utf8)
        XCTAssertTrue(worker.contains("ghcr.io/typst/typst:0.15.1@sha256:032e292249bcd378480cc7c142cfa324b63ef8aadeb88d7e7230320c4c9c422f AS typst"))
        XCTAssertTrue(worker.contains("--checksum=sha256:9883fdd4a49d4fb66bd8177ba6625ef9a64aa45899767dde3d36aa425756b11e"))
        let stages = worker.components(separatedBy: "\nFROM ")
        for name in ["worker-tools", "worker-test"] {
            let stage = try XCTUnwrap(stages.first { $0.split(separator: "\n").first?.hasSuffix(" AS \(name)") == true }, name)
            XCTAssertTrue(stage.contains("COPY --from=typst /bin/typst /usr/local/bin/typst"), name)
            XCTAssertTrue(stage.contains("COPY --from=fonts /fonts/ \(InvoiceRenderTools().fontDirectory)/"), name)
        }
        XCTAssertTrue(stages.contains { $0.hasPrefix("worker-tools AS worker\n") })
        let api = try String(contentsOf: RenderFixtures.repo.appendingPathComponent("Dockerfile"), encoding: .utf8)
        XCTAssertFalse(api.lowercased().contains("typst"))
    }
}

// MARK: Mit Werkzeugen

final class InvoiceRenderToolTests: XCTestCase {

    private var renderer: InvoiceRenderer { InvoiceRenderer(tools: RenderFixtures.tools) }

    /// AK-R6b-1: fünf Referenzfälle: Seitenzahl und extrahierter Text gleich der Referenz.
    func testAKR6b_1_referenceCasesMatchPagesAndText() async throws {
        try await RenderFixtures.requireTools()
        for name in RenderFixtures.cases {
            let pdf = try await renderer.render(RenderFixtures.document(name))
            try RenderFixtures.keep(pdf, as: name)
            let text = try await RenderFixtures.extract(pdf)
            let reference = RenderFixtures.directory.appendingPathComponent(name + ".txt")
            if RenderFixtures.environment["LH_RENDER_UPDATE"] == "1" { try Data(text.utf8).write(to: reference) }
            XCTAssertEqual(text, String(decoding: (try? Data(contentsOf: reference)) ?? Data(), as: UTF8.self), name)
        }
    }

    /// AK-R6b-1: die fünf Bausteine, unabhängig von der Referenzdatei.
    func testAKR6b_1_referenceCasesCoverLayoutBlocks() async throws {
        try await RenderFixtures.requireTools()
        let long = try await RenderFixtures.extract(renderer.render(RenderFixtures.document("order_confirmation")))
        XCTAssertFalse(long.hasPrefix("Seiten: 1\n"), "mehrseitig")
        let pages = long.components(separatedBy: "=== Seitenende ===").filter { $0.contains("Position ") }
        XCTAssertGreaterThan(pages.count, 1)
        for page in pages {
            XCTAssertTrue(page.contains("Beschreibung"), "Tabellenkopf je Seite")
            XCTAssertTrue(page.contains("Musterbank"), "Fußzeile je Seite")
        }
        XCTAssertTrue(long.contains("Seite 2 von "))
        for n in 1...60 { XCTAssertTrue(long.contains(String(format: "Position %02d:", n)), "Position \(n)") }
        let invoice = try await RenderFixtures.extract(renderer.render(RenderFixtures.document("invoice")))
        for expected in ["Beispiel Werkstatt GmbH", "Kunde Beispiel AG", "RE-2026-0001", "Beschreibung", "Nettobetrag", "Gesamtbetrag 1.526,94 €", "IBAN", "Seite 1 von 1"] {
            XCTAssertTrue(invoice.contains(expected), expected)
        }
        let note = try await RenderFixtures.extract(renderer.render(RenderFixtures.document("delivery_note")))
        XCTAssertFalse(note.contains("€"))
    }

    /// AK-R6b-3: gleiche Eingabe ergibt gleiche Bytes: zwei Läufe, und gegen die Prüfsummen im Repo (gleich für amd64 und arm64).
    func testAKR6b_3_sameInputSameBytesAcrossRunsAndArchitectures() async throws {
        try await RenderFixtures.requireTools(qpdf: true)
        var lines: [String] = []
        for (name, attached) in RenderFixtures.cases.map({ ($0, false) }) + RenderFixtures.attachmentCases.map({ ($0, true) }) {
            let attachment = attached ? try RenderFixtures.attachment : nil
            let first = try await renderer.render(RenderFixtures.document(name), attachment: attachment)
            try await Task.sleep(for: .milliseconds(1100))  // eine Uhr im PDF fiele sonst nicht auf
            let second = try await renderer.render(RenderFixtures.document(name), attachment: attachment)
            let file = name + (attached ? "-xml" : "")
            XCTAssertEqual(first, second, file)
            try RenderFixtures.keep(first, as: file)
            lines.append("\(RenderFixtures.sha256(first))  \(file).pdf")
        }
        let got = lines.joined(separator: "\n") + "\n"
        print("AK-R6b-3 Prüfsummen:\n" + got)
        let reference = RenderFixtures.directory.appendingPathComponent("checksums.sha256")
        if RenderFixtures.environment["LH_RENDER_UPDATE"] == "1" { try Data(got.utf8).write(to: reference) }
        XCTAssertEqual(got, String(decoding: (try? Data(contentsOf: reference)) ?? Data(), as: UTF8.self))
    }

    /// AK-R6b-2: mit XML: Anhang mit `AFRelationship=Alternative`, unveränderte Bytes, `fx:`-Metadaten; ohne XML weder Anhang noch `fx:`.
    func testAKR6b_2_attachmentAndFacturXMetadata() async throws {
        try await RenderFixtures.requireTools(qpdf: true)
        let attachment = try RenderFixtures.attachment
        let with = try await renderer.render(RenderFixtures.document("invoice"), attachment: attachment)
        let without = try await renderer.render(RenderFixtures.document("invoice"))
        let plain = String(decoding: without, as: UTF8.self), enriched = String(decoding: with, as: UTF8.self)
        XCTAssertFalse(plain.contains("fx:")); XCTAssertFalse(plain.contains("factur-x.xml")); XCTAssertTrue(plain.contains("<pdfaid:part>3</pdfaid:part>"))
        for expected in ["<fx:ConformanceLevel>EN 16931</fx:ConformanceLevel>", "<fx:DocumentFileName>factur-x.xml</fx:DocumentFileName>",
                         "<pdfaSchema:prefix>fx</pdfaSchema:prefix>", "<pdfaid:part>3</pdfaid:part>"] {
            XCTAssertTrue(enriched.contains(expected), expected)
        }
        XCTAssertNotNil(enriched.range(of: "/AFRelationship\\s*/Alternative", options: .regularExpression))
        let dir = try RenderFixtures.scratch(); defer { try? FileManager.default.removeItem(at: dir) }
        try with.write(to: dir.appendingPathComponent("in.pdf"))
        let shown = try await ToolProcess.run(RenderFixtures.tools.qpdf, ["--show-attachment=factur-x.xml", "in.pdf"], workDir: dir, timeout: 60)
        XCTAssertEqual(shown.exitCode, 0, shown.stderr)
        XCTAssertEqual(Data(shown.stdout.utf8), attachment.xml)
    }

    /// AK-R6b-4: Typst-Syntax in Nutzertexten erscheint wörtlich, auch Zeichenfolgen, die Schriften sonst ersetzen.
    func testAKR6b_4_typstSyntaxInUserTextIsPrintedLiterally() async throws {
        try await RenderFixtures.requireTools()
        let hostile = ["#read(\"/etc/passwd\")", "#import \"@preview/x:0.1.0\"", "$sum_x^2$ *fett* _kursiv_ `code`", "<marke> @verweis // kein Kommentar", "\\u{41} [klammer] 3x4 -> --- 'a' \"b\""]
        let data = try RenderFixtures.document("invoice") { doc in
            var lines = doc["lines"] as? [[String: Any]] ?? []
            lines[0]["description"] = hostile.joined(separator: "\n")
            lines[0]["unit"] = "#panic()"
            doc["lines"] = lines
            doc["header_text"] = "#read(\"main.typ\")"
            doc["footer_text"] = "#sys.inputs"
            var sender = doc["sender"] as? [String: Any] ?? [:]
            sender["sender_name"] = "#panic(\"x\") GmbH"
            doc["sender"] = sender
        }
        let text = try await RenderFixtures.extract(renderer.render(data))
        for expected in hostile + ["#panic()", "#read(\"main.typ\")", "#sys.inputs", "#panic(\"x\") GmbH"] { XCTAssertTrue(text.contains(expected), expected + "\n" + text) }
        XCTAssertFalse(text.contains("root:"))
    }

    /// AK-R6b-4: auch der echte Renderer wird vom Zeitlimit beendet.
    func testAKR6b_4_timeoutAlsoStopsTypst() async throws {
        try await RenderFixtures.requireTools()
        var tools = RenderFixtures.tools
        tools.timeout = 0.01
        do { _ = try await InvoiceRenderer(tools: tools).render(RenderFixtures.document("order_confirmation")); XCTFail("kein Zeitlimit") } catch {
            XCTAssertEqual(error as? InvoiceRenderError, .timeout)
        }
    }

    /// Größter zulässiger Beleg (500 Positionen) bleibt innerhalb des Standard-Zeit- und Speicherlimits.
    func testLargestDocumentRendersWithinDefaultLimits() async throws {
        try await RenderFixtures.requireTools()
        let data = try RenderFixtures.document("order_confirmation") { doc in
            let line = (doc["lines"] as? [[String: Any]] ?? [])[0]
            doc["lines"] = (1...500).map { n -> [String: Any] in
                var l = line; l["position"] = n; l["description"] = "Zeile \(n): " + String(repeating: "Langer Beschreibungstext. ", count: 40); return l
            }
        }
        let start = Date()
        let pdf = try await renderer.render(data)
        print("500 Positionen: \(Date().timeIntervalSince(start)) s, \(pdf.count) Bytes")
        let text = try await RenderFixtures.extract(pdf)
        XCTAssertTrue(text.contains("Zeile 500:"))
    }

    /// Fehlt ein Zeichen in allen Schriften, entsteht ein Fehler statt eines nicht konformen PDF.
    func testUnsupportedCharacterFailsInsteadOfBrokenPDF() async throws {
        try await RenderFixtures.requireTools()
        let data = try RenderFixtures.document("invoice") { $0["header_text"] = "Zeichen ohne Glyphe: \u{10FFFD}" }
        do { _ = try await renderer.render(data); XCTFail("PDF/A mit fehlender Glyphe") } catch {
            guard case .failed(let tool, _, _)? = error as? InvoiceRenderError else { return XCTFail("\(error)") }
            XCTAssertEqual(tool, "typst")
        }
    }
}

// MARK: E2E

/// E2E: Beleg über die API anlegen und finalisieren, die gelieferten eingefrorenen Daten rendern (so übergibt sie ab R6c der Render-Job).
final class InvoiceRenderE2ETests: InvoiceTestBase, @unchecked Sendable {
    func testE2E_finalizedDocumentFromApiRendersToPDF() async throws {
        try await RenderFixtures.requireTools(qpdf: true)
        let w = try await world()
        let settings = try await call(app1, .PUT, base(w.tenantA) + "/settings", json: ["sender_name": "Muster GmbH", "city": "Musterstadt", "currency": "EUR", "iban": "DE89370400440532013000"], token: w.alice.token)
        XCTAssertEqual(settings.status, .ok, "\(settings.json)")
        let s = try await series(w, format: "RE-{N:4}")
        let seriesID = try XCTUnwrap(s.json["id"] as? String)
        let type = try await call(app1, .POST, base(w.tenantA) + "/document-types", json: ["code": "invoice", "name": "Rechnung", "kind": "invoice", "default_series_id": seriesID], token: w.alice.token)
        let contact = try await call(app1, .POST, "api/v1/tenants/\(w.tenantA)/contacts", json: ["kind": "organization", "display_name": "Kunde AG"], token: w.alice.token)
        let docs = base(w.tenantA) + "/documents"
        let body: [String: Any] = ["document_type_id": try XCTUnwrap(type.json["id"]), "contact_id": try XCTUnwrap(contact.json["id"]), "issue_date": "2026-11-23", "price_mode": "net",
                                   "skonto_percent": "2", "skonto_days": 10,
                                   "lines": [["kind": "item", "description": "Beratung", "quantity": "3", "unit_price": "49.99", "tax_rate": "19"],
                                             ["kind": "item", "description": "Material", "quantity": "2.5", "unit_price": "12.5", "tax_rate": "7"]],
                                   "charges": [["description": "Versand", "amount": "10", "tax_rate": "19"]]]
        let draft = try await call(app1, .POST, docs, json: body, token: w.alice.token)
        XCTAssertEqual(draft.status, .created, "\(draft.json)")
        let id = try XCTUnwrap(draft.json["id"] as? String)
        let final = try await call(app1, .POST, docs + "/\(id)/finalize", json: [String: Any](), token: w.alice.token)
        XCTAssertEqual(final.status, .ok, "\(final.json)")
        let number = try XCTUnwrap(final.json["number"] as? String)
        let frozen = try await InvoiceDocuments.fetch(try XCTUnwrap(UUID(uuidString: id)), tenant: try XCTUnwrap(UUID(uuidString: w.tenantA)), on: try XCTUnwrap(app2.db(.psql) as? any SQLDatabase))

        let renderer = InvoiceRenderer(tools: RenderFixtures.tools)
        let pdf = try await renderer.render(Data(frozen.utf8), attachment: try RenderFixtures.attachment)
        try RenderFixtures.keep(pdf, as: "e2e-api")
        let again = try await renderer.render(Data(frozen.utf8), attachment: try RenderFixtures.attachment)
        XCTAssertEqual(pdf, again)
        let text = try await RenderFixtures.extract(pdf)
        let gross = InvoiceRenderFormat.money(try XCTUnwrap(final.json["gross_total"] as? String), currency: "EUR")
        for expected in ["Rechnung \(number)", "Muster GmbH", "Kunde AG", "Beratung", "Versand (USt 19 %)", "Gesamtbetrag \(gross)", "2 % Skonto", "DE89370400440532013000"] {
            XCTAssertTrue(text.contains(expected), expected + "\n" + text)
        }
    }
}
