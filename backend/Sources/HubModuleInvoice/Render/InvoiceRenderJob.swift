import Vapor
import Fluent
import SQLKit
import HubCore

// WP-R6c: Job `invoice.render`. Finalisieren reiht ihn in derselben Transaktion ein (Rollback = kein Job); der Worker rendert NUR aus den eingefrorenen Daten
// (`InvoiceDocuments.fetch`), speichert das PDF inhaltsadressiert im Objektspeicher, registriert die Datei in `files` und schreibt die Zustandszeile
// (`invoice_render_states`, unveränderlich) mit `ON CONFLICT DO NOTHING`. Nach der Zustandszeile wird nie neu gerendert; die Prüfung steht vor dem Rendern
// und noch einmal unter der Zeilensperre des Belegs. Abschluss nur als Lease-Besitzer (Versuchsnummer des Abholens, Lease noch gültig, Datenbankuhr).
// Nutzlast des Jobs: nur Mandant und Beleg (keine Belegdaten). Fehlercodes im Job: kurze Codes ohne Belegtext (`InvoiceRenderError.failed.diagnostics` bleibt im Prozess).

/// Was der Job vom Renderer braucht. Produktiv `InvoiceToolRenderer` (Typst, qpdf); die Tests setzen einen Zähler ein.
protocol InvoiceRendering: Sendable {
    var layoutKey: String { get }
    var layoutVersion: Int { get }
    /// Kurze Angabe zur Werkzeugversion (z. B. `typst 0.15.1`), wird je Ergebnis gespeichert.
    func rendererVersion() async throws -> String
    func render(_ documentJSON: Data) async throws -> Data
}

/// Einstellungen des Renderers aus der Worker-Umgebung (`RENDER_*`, siehe `deploy/README.md`).
struct InvoiceRenderConfig: Sendable {
    var tools = InvoiceRenderTools()

    static func fromEnvironment(_ env: [String: String] = ProcessInfo.processInfo.environment) -> InvoiceRenderConfig {
        var c = InvoiceRenderConfig()
        func path(_ key: String) -> String? { env[key].flatMap { $0.isEmpty ? nil : $0 } }
        if let v = path("RENDER_TYPST") { c.tools.typst = v }
        if let v = path("RENDER_QPDF") { c.tools.qpdf = v }
        if let v = path("RENDER_FONT_DIR"), v.hasPrefix("/") { c.tools.fontDirectory = v }
        if let v = path("RENDER_TMPDIR"), v.hasPrefix("/") { c.tools.tempRoot = v }
        if let v = env["RENDER_TIMEOUT_SECONDS"].flatMap(Int.init), (1...3600).contains(v) { c.tools.timeout = TimeInterval(v) }
        return c
    }
}

struct InvoiceToolRenderer: InvoiceRendering {
    let tools: InvoiceRenderTools
    var layoutKey: String { InvoiceStandardLayout.key }
    var layoutVersion: Int { InvoiceStandardLayout.version }

    init(_ config: InvoiceRenderConfig = .fromEnvironment()) { self.tools = config.tools }

    func rendererVersion() async throws -> String {
        let dir = URL(fileURLWithPath: tools.tempRoot, isDirectory: true).appendingPathComponent("lh-render-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: dir) }
        let result = try await ToolProcess.run(tools.typst, ["--version"], workDir: dir, timeout: 30, environment: ["HOME": dir.path], inheritEnvironment: false)
        guard result.exitCode == 0, !result.timedOut else { throw InvoiceRenderError.toolMissing("typst") }
        let line = result.stdout.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let clean = String(String.UnicodeScalarView(line.unicodeScalars.filter { $0.value >= 32 && $0.value < 127 }.prefix(120))).trimmingCharacters(in: .whitespaces)
        return clean.isEmpty ? "typst" : clean
    }

    func render(_ documentJSON: Data) async throws -> Data { try await InvoiceRenderer(tools: tools).render(documentJSON) }

    /// Vorabprüfung beim Start des Workers: Typst, qpdf und die gepinnten Schriften müssen vorhanden sein, sonst liefe jeder Auftrag in die Quarantäne.
    static func preflight(_ config: InvoiceRenderConfig) async -> String? {
        let tools = config.tools
        for font in InvoiceRenderer.requiredFonts where !FileManager.default.fileExists(atPath: tools.fontDirectory + "/" + font) {
            return "Schrift fehlt: \(tools.fontDirectory)/\(font)"
        }
        let dir = URL(fileURLWithPath: tools.tempRoot, isDirectory: true).appendingPathComponent("lh-render-preflight-\(UUID().uuidString)", isDirectory: true)
        guard (try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])) != nil
        else { return "Arbeitsverzeichnis nicht beschreibbar: \(tools.tempRoot)" }
        defer { try? FileManager.default.removeItem(at: dir) }
        for tool in [tools.typst, tools.qpdf] {
            let r = try? await ToolProcess.run(tool, ["--version"], workDir: dir, timeout: 30, environment: ["HOME": dir.path], inheritEnvironment: false)
            if r?.exitCode != 0 { return "Werkzeug fehlt oder startet nicht: \(tool)" }
        }
        return nil
    }
}

enum InvoiceRenderJob {
    static let kind = "invoice.render"
    /// Sichtbares Ergebnis für Nutzer: vor Massenläufen (Import), nach manuellen Uploads (siehe `DMSOCR.priorityManual`).
    static let priority = 5

    struct Payload: Codable, Sendable { let tenant_id: UUID; let document_id: UUID }

    /// Reiht einen Auftrag ein und merkt ihn als jüngsten Auftrag des Belegs (`invoice_render_jobs`). Läuft auf der übergebenen Verbindung/Transaktion:
    /// Rollback des Aufrufers nimmt Auftrag und Merkzeile mit zurück.
    @discardableResult
    static func enqueue(document: UUID, tenant: UUID, on s: any SQLDatabase) async throws -> UUID {
        let payload = String(decoding: try JSONEncoder().encode(Payload(tenant_id: tenant, document_id: document)), as: UTF8.self)
        let job = try await JobService(s).enqueue(kind: kind, payload: payload, priority: priority)
        try await s.raw("""
            INSERT INTO invoice_render_jobs (document_id, tenant_id, job_id) VALUES (\(bind: document), \(bind: tenant), \(bind: job))
            ON CONFLICT (document_id) DO UPDATE SET job_id = EXCLUDED.job_id, updated_at = now()
            """).run()
        return job
    }

    private struct Frozen: Decodable { let status: String; let content_hash: String? }

    static func handler(renderer: any InvoiceRendering, storeFactory: @escaping @Sendable (any SQLDatabase) throws -> any ObjectStore) -> JobHandler {
        return { job, s in
            guard let payload = try? JSONDecoder().decode(Payload.self, from: Data(job.payload.utf8)) else { throw PermanentJobError(code: "payload_invalid") }
            try await process(job: job, payload: payload, renderer: renderer, storeFactory: storeFactory, s: s)
        }
    }

    private static func stateExists(_ document: UUID, tenant: UUID, on s: any SQLDatabase) async throws -> Bool {
        try await s.raw("SELECT 1 AS x FROM invoice_render_states WHERE tenant_id = \(bind: tenant) AND document_id = \(bind: document)").first() != nil
    }

    private static func process(job: ClaimedJob, payload: Payload, renderer: any InvoiceRendering, storeFactory: @escaping @Sendable (any SQLDatabase) throws -> any ObjectStore, s: any SQLDatabase) async throws {
        let tenant = payload.tenant_id, document = payload.document_id
        // Fertig ist fertig: kein zweites Rendern, auch nicht mit anderer Werkzeug- oder Layoutversion
        if try await stateExists(document, tenant: tenant, on: s) { return }

        let json: String
        do { json = try await InvoiceDocuments.fetch(document, tenant: tenant, on: s) }
        catch let e as HubError where e.status == .notFound { throw PermanentJobError(code: "document_missing") }
        guard let frozen = try? JSONDecoder().decode(Frozen.self, from: Data(json.utf8)), frozen.status == "final", let inputHash = frozen.content_hash
        else { throw PermanentJobError(code: "document_not_final") }

        let version = String(try await renderer.rendererVersion().prefix(128))
        try Task.checkCancellation()
        let pdf: Data
        do { pdf = try await renderer.render(Data(json.utf8)) }
        catch is CancellationError { throw CancellationError() }
        catch let e as InvoiceRenderError {
            switch e {
            case .notFinal, .invalidDocument: throw PermanentJobError(code: "render_invalid_document")
            // gleiche Eingabe, gleicher Fehler: Wiederholen hilft nicht (der Fehlertext kann Belegtext enthalten und wird nicht protokolliert)
            case .failed: throw PermanentJobError(code: "render_failed")
            // Zeitlimit und fehlende Werkzeuge können vorübergehend sein: normale Wiederholung (3 Versuche)
            case .timeout, .toolMissing: throw e
            }
        }
        try Task.checkCancellation()

        let store = try storeFactory(s)
        let stored = try await store.put(tenant: tenant, stream: byteStream(pdf), expectedSHA256: nil)
        guard let database = s as? any Database else { throw PermanentJobError(code: "database_unavailable") }
        let layoutKey = renderer.layoutKey, layoutVersion = renderer.layoutVersion
        _ = try await invoiceTransaction(database) { tx -> Bool in
            // Nur als Lease-Besitzer: dieser Abholversuch ist noch der aktuelle und die Lease nach Datenbankuhr gültig. Sonst schreibt der Handler nichts.
            guard try await tx.raw("""
                SELECT 1 AS x FROM jobs WHERE id = \(bind: job.id) AND state = 'running' AND attempts = \(bind: job.attempts) AND lease_until >= now() FOR UPDATE
                """).first() != nil else { throw CancellationError() }
            // Zeilensperre des Belegs: parallele Ausführungen schreiben nacheinander, die zweite sieht die Zustandszeile und legt nichts an
            guard let doc = try await tx.raw("""
                SELECT status, content_hash FROM invoice_documents WHERE tenant_id = \(bind: tenant) AND id = \(bind: document) FOR UPDATE
                """).first() else { throw PermanentJobError(code: "document_missing") }
            guard try doc.decode(column: "status", as: String.self) == "final", try doc.decode(column: "content_hash", as: String?.self) == inputHash
            else { throw PermanentJobError(code: "document_not_final") }
            if try await stateExists(document, tenant: tenant, on: tx) { return false }
            // Blob-Sperre wie beim DMS-Upload: ab hier kann kein Aufräumweg die Bytes verwerfen, bis die Zeile mit der Zustandszeile committed ist
            try await FileRecordService.lockBlob(tenant: tenant, sha256: stored.key.sha256, on: tx)
            // Der Speicher für diese Prüfung gehört zur Verbindung der Transaktion (bei OBJECT_STORE=db liest er über sie; eine zweite Verbindung würde den Pool leerlaufen lassen)
            guard try await storeFactory(tx).exists(stored.key) else { throw InvoiceRenderJobError.blobMissing }
            let file = try await FileRecordService(tx).register(stored, backend: store.kind, contentType: "application/pdf")
            guard try await tx.raw("""
                INSERT INTO invoice_render_states (tenant_id, document_id, layout_key, layout_version, input_hash, pdf_sha256, file_id, renderer_version)
                VALUES (\(bind: tenant), \(bind: document), \(bind: layoutKey), \(bind: layoutVersion), \(bind: inputHash), \(bind: stored.key.sha256), \(bind: file), \(bind: version))
                ON CONFLICT (document_id) DO NOTHING RETURNING id
                """).first() != nil else { return false }
            try await AuditLog.record(AuditEvent(action: "invoice.document.rendered", actor: nil, tenant: tenant, subjectType: "invoice.document", subjectID: document.uuidString,
                                                 meta: ["layout_version": .number(Int64(layoutVersion)), "bytes": .number(stored.size)]), on: tx)
            return true
        }
    }

    /// PDF-Bytes als Strom für den Objektspeicher (in Blöcken der Speichergröße).
    private static func byteStream(_ data: Data) -> ByteStream {
        let offset = UnsafeSendableBox<Int>(0)
        return ByteStream(unfolding: {
            guard offset.value < data.count else { return nil }
            let end = min(offset.value + objectStoreChunkSize, data.count)
            defer { offset.value = end }
            return ByteBuffer(data: data[offset.value..<end])
        })
    }
}

enum InvoiceRenderJobError: Error { case blobMissing }
