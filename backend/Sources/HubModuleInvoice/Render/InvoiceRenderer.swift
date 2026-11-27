import Foundation
import HubCore

// WP-R6b (ADR 0008): eingefrorene Belegdaten (JSON wie `InvoiceDocuments.fetch`, Dezimal-Strings) → PDF/A-3b.
// Typst und qpdf laufen als eigene Prozesse mit Zeit- und Speicherlimit in einem Arbeitsverzeichnis unter `tempRoot`; Nutzerdaten gehen nur als
// `data.json` an die Vorlage, nie als Typst-Quelltext. Gleiche Eingabe ergibt gleiche Bytes (Zeitstempel = Finalisierungszeitpunkt, feste Schriften).
// Keine Datenbank, kein Job: das ist WP-R6c.

/// E-Rechnungs-XML, das in das PDF eingebettet wird (`AFRelationship=Alternative`). Erzeugung und Prüfung des XML sind WP-R5.
struct InvoiceRenderAttachment: Sendable {
    let xml: Data
    var conformanceLevel: FacturXMetadata.Level = .en16931
}

enum InvoiceRenderError: Error, Equatable {
    case notFinal
    case invalidDocument(String)
    case toolMissing(String)
    case timeout
    /// `diagnostics` kann Belegtext enthalten: nie ungeprüft protokollieren oder ausliefern.
    case failed(tool: String, exitCode: Int32, diagnostics: String)
}

struct InvoiceRenderTools: Sendable {
    var typst = "typst"
    var qpdf = "qpdf"
    /// Gepinnte Schriften aus dem Worker-Image (`Dockerfile.worker`).
    var fontDirectory = "/usr/local/share/lab-hub/fonts"
    var tempRoot = "/tmp"
    /// Sekunden je Prozess.
    var timeout: TimeInterval = 60
    /// Adressraumlimit je Prozess (nur Linux).
    var memoryBytes: Int64? = 1 << 30
}

struct InvoiceRenderer: Sendable {
    /// Ohne diese Dateien nähme Typst still eine Ersatzschrift und das PDF sähe anders aus.
    static let requiredFonts = ["Inter-Regular.ttf", "Inter-Bold.ttf"]

    var tools = InvoiceRenderTools()

    func render(_ documentJSON: Data, attachment: InvoiceRenderAttachment? = nil) async throws -> Data {
        let prepared = try InvoiceRenderData.prepare(documentJSON, attach: attachment != nil)
        guard Self.requiredFonts.allSatisfy({ FileManager.default.fileExists(atPath: tools.fontDirectory + "/" + $0) }) else { throw InvoiceRenderError.toolMissing("fonts") }
        let dir = URL(fileURLWithPath: tools.tempRoot, isDirectory: true).appendingPathComponent("lh-render-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: dir) }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(prepared.data).write(to: dir.appendingPathComponent("data.json"))
        try Data(InvoiceStandardLayout.template.utf8).write(to: dir.appendingPathComponent("main.typ"))
        if let attachment { try attachment.xml.write(to: dir.appendingPathComponent(FacturXMetadata.fileName)) }

        // Paketverzeichnisse zeigen ins Leere: die Vorlage importiert nichts, und ein Paket würde auch nicht geladen
        let packages = dir.appendingPathComponent("packages").path
        try await run("typst", tools.typst, [
            "compile", "--root", dir.path, "--ignore-system-fonts", "--font-path", tools.fontDirectory,
            "--package-path", packages, "--package-cache-path", packages, "--pdf-standard", "a-3b",
            "--creation-timestamp", String(prepared.createdAt), "--jobs", "1", "main.typ", "out.pdf"
        ], dir: dir)
        guard let attachment else { return try Data(contentsOf: dir.appendingPathComponent("out.pdf")) }
        return try await addFacturXMetadata(attachment.conformanceLevel, dir: dir)
    }

    /// `fx:`-Metadaten (ADR 0008 Punkt 3): XMP-Strom über `qpdf --update-from-json` ersetzen. `--newline-before-endstream` verlangt PDF/A.
    private func addFacturXMetadata(_ level: FacturXMetadata.Level, dir: URL) async throws -> Data {
        try await run("qpdf", tools.qpdf, ["--json=2", "--json-stream-data=inline", "out.pdf", "objects.json"], dir: dir)
        let update = try FacturXMetadata.update(qpdfJSON: Data(contentsOf: dir.appendingPathComponent("objects.json")), conformanceLevel: level)
        try update.write(to: dir.appendingPathComponent("update.json"))
        try await run("qpdf", tools.qpdf, ["out.pdf", "--update-from-json=update.json", "--deterministic-id", "--newline-before-endstream", "final.pdf"], dir: dir)
        return try Data(contentsOf: dir.appendingPathComponent("final.pdf"))
    }

    private func run(_ name: String, _ executable: String, _ arguments: [String], dir: URL) async throws {
        let result = try await ToolProcess.run(executable, arguments, workDir: dir, timeout: tools.timeout, memoryBytes: tools.memoryBytes,
                                               environment: ["HOME": dir.path, "LC_ALL": "C.UTF-8"], inheritEnvironment: false)
        try Task.checkCancellation()
        if result.timedOut { throw InvoiceRenderError.timeout }
        // 127: Shell bzw. `timeout` hat das Programm nicht gefunden
        if result.exitCode == 127 { throw InvoiceRenderError.toolMissing(name) }
        guard result.exitCode == 0 else { throw InvoiceRenderError.failed(tool: name, exitCode: result.exitCode, diagnostics: String(result.stderr.prefix(2000))) }
    }
}
