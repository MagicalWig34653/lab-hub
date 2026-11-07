import XCTVapor
import Fluent
import SQLKit
@testable import HubKit

// WP-O2: OCR-Job `dms.ocr`. Alle Dokumente sind selbst erzeugt und synthetisch (Text aus dem Test).
// Zwei Gruppen:
//  - Ohne Werkzeuge lauffähig (Host): Zustandsautomat, Handler mit Testengine, genau einmal mit zwei Workern (AK-O2-6), Status-Route, Prozess-Limits.
//  - Mit ocrmypdf/Tesseract/Ghostscript (Worker-Image): AK-O2-1…5 mit der echten Engine. Fehlen die Werkzeuge, werden diese Tests mit Meldung
//    übersprungen; im Container laufen sie über `scripts/ocr-container-test.sh`.

/// Testengine: kein Werkzeug nötig, zählt Aufrufe, liefert Text und eine kleine Archivdatei.
final class FakeOCREngine: OCRExtracting, @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    private var inFlight = 0, maxInFlight = 0
    var delay: Duration = .zero
    var behavior: (@Sendable (Int) throws -> Void)?
    var calls: Int { lock.lock(); defer { lock.unlock() }; return n }
    var peak: Int { lock.lock(); defer { lock.unlock() }; return maxInFlight }

    private func begin() -> Int { lock.withLock { n += 1; inFlight += 1; maxInFlight = max(maxInFlight, inFlight); return n } }
    private func end() { lock.withLock { inFlight -= 1 } }

    func extract(input: URL, mime: String, workDir: URL) async throws -> OCRExtraction {
        let call = begin()
        defer { end() }
        if delay > .zero { try await Task.sleep(for: delay) }
        try behavior?(call)
        let archive = workDir.appendingPathComponent("archive.pdf")
        try Data("%PDF-1.7\n% synthetic archive \(call) \(UUID())\n%%EOF\n".utf8).write(to: archive)
        return OCRExtraction(text: "Synthetischer Rechnungstext Nummer 4711", lang: "de", engine: "fake", archive: archive, pages: 1, usedOCR: true, pdfa: true)
    }
}

class DMSOCRTestBase: DMSTestBase {
    override var testModules: [any HubModule] { [DMSModule(objectStore: ObjectStoreConfig(kind: .db), maxUploadBytes: Self.uploadLimit, enqueueOCR: true)] }

    func handler(_ engine: any OCRExtracting) -> JobHandler {
        DMSOCR.handler(engine: engine, tempRoot: NSTemporaryDirectory()) { s in try ObjectStoreConfig(kind: .db).makeStore(db: s) }
    }

    func makeWorker(_ engine: any OCRExtracting, on app: Application? = nil, backoff: Int = 0) -> JobWorker {
        JobWorker(db: (app ?? app1).db(.psql) as! any SQLDatabase, kinds: [DMSOCR.kind], handlers: [DMSOCR.kind: handler(engine)], leaseSeconds: 30,
                  pollInterval: .milliseconds(100), retryBackoffSeconds: backoff, logger: Logger(label: "test.ocr"))
    }

    func itemState(_ doc: String) async throws -> String {
        try await scalar("SELECT state AS v FROM dms_ingest_items WHERE document_id = '\(doc)'", as: String.self)
    }

    func waitFor(_ what: String, timeout: Double = 60, _ cond: () async throws -> Bool) async throws {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end { if try await cond() { return }; try await Task.sleep(for: .milliseconds(100)) }
        XCTFail("Zeitüberschreitung: \(what)")
    }

    func processing(_ w: World, _ doc: String, token: String? = nil, tenant: String? = nil, app: Application? = nil) async throws -> Raw {
        try await raw(app ?? app1, .GET, base(tenant ?? w.tenantA) + "/documents/\(doc)/processing", token: token ?? w.alice.token)
    }
}

final class DMSOCRPipelineTests: DMSOCRTestBase {

    /// Upload mit Worker-Anbindung: Antwort enthält `ingest_item_id`, der Job `dms.ocr` (Priorität manuell) liegt in derselben Transaktion, Item steht auf `ocr_queued`.
    func testUploadEnqueuesOcrJobAndReturnsIngestItem() async throws {
        let w = try await world()
        let doc = try await newDoc(w.alice, w.tenantA, seed: "ocr-enqueue")
        let docID = doc["id"] as! String
        let itemID = try XCTUnwrap(doc["ingest_item_id"] as? String)
        try await aEq(try await scalar("SELECT id::text AS v FROM dms_ingest_items WHERE document_id = '\(docID)'", as: String.self).uppercased(), itemID.uppercased())
        try await aEq(try await itemState(docID), "ocr_queued")
        try await aEq(try await count("jobs", where: "kind = 'dms.ocr' AND priority = \(DMSOCR.priorityManual) AND state = 'queued' AND payload::jsonb->>'ingest_item_id' ILIKE '\(itemID)'"), 1)
        // Wiederholung mit gleichem Idempotency-Key: kein zweiter Job
        let key = UUID().uuidString
        let r1 = try await upload(w.alice, w.tenantA, pdf("ocr-idem"), key: key), r2 = try await upload(w.alice, w.tenantA, pdf("ocr-idem"), key: key, via: app2)
        XCTAssertEqual(r1.status, .created); XCTAssertEqual(r2.status, .created)
        XCTAssertEqual(r1.json["ingest_item_id"] as? String, r2.json["ingest_item_id"] as? String)
        try await aEq(try await count("jobs", where: "kind = 'dms.ocr'"), 2)
    }

    /// Ohne Worker-Anbindung (Standard-Initialisierer) bleibt es beim bisherigen Verhalten: kein Job, Zustand nach dem Upload `hashed` (D2/O1-Tests prüfen das).
    func testModuleWithoutOcrIsTheDefault() {
        XCTAssertFalse(DMSModule().enqueueOCR)
        XCTAssertTrue(DMSModule(enqueueOCR: true).enqueueOCR)
    }

    /// Kompletter Ablauf mit Testengine: hashed -> ocr_queued -> ocr_done -> classified -> done; Text sofort durchsuchbar; Archivdatei herunterladbar; Original unverändert.
    func testOcrJobCompletesIngestChainAndIndexesText() async throws {
        let w = try await world()
        let original = pdf("ocr-chain")
        let up = try await upload(w.alice, w.tenantA, original)
        let docID = up.json["id"] as! String
        let before = try await processing(w, docID)
        XCTAssertEqual(before.status, .ok); XCTAssertEqual(before.json["phase"] as? String, "queued"); XCTAssertEqual(before.json["state"] as? String, "ocr_queued")
        XCTAssertEqual(before.json["ingest_item_id"] as? String, up.json["ingest_item_id"] as? String)

        let engine = FakeOCREngine()
        let worker = makeWorker(engine)
        let run = Task { await worker.run() }
        try await waitFor("done") { try await itemState(docID) == "done" }
        worker.requestShutdown(); await run.value

        let after = try await processing(w, docID)
        XCTAssertEqual(after.json["phase"] as? String, "done")
        XCTAssertEqual(after.json["has_archive"] as? Bool, true)
        XCTAssertEqual((after.json["text"] as? [String: Any])?["engine"] as? String, "fake")
        XCTAssertEqual((after.json["steps"] as? [[String: Any]])?.compactMap { $0["state"] as? String }, ["received", "stored", "hashed", "ocr_queued", "ocr_done", "classified", "done"])
        try await aEq(try await count("dms_document_texts", where: "document_id = '\(docID)'"), 1)
        try await aEq(try await count("jobs", where: "kind = 'dms.ocr' AND state = 'done'"), 1)
        try await aEq(try await auditCount("dms.ingest.ocr_done", tenant: w.tenantA), 1)
        // Suche findet den Text (S1-Index, per Trigger)
        let enc = "Rechnungstext".addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
        let hit = try await raw(app2, .GET, base(w.tenantA) + "/search?q=\(enc)&fuzzy=false", token: w.alice.token)
        XCTAssertEqual((hit.json["items"] as? [[String: Any]])?.count, 1, "\(hit.json)")
        // Archivversion als Rolle archive, Original byte-identisch
        let arch = try await raw(app2, .GET, base(w.tenantA) + "/documents/\(docID)/file?role=archive", token: w.alice.token)
        XCTAssertEqual(arch.status, .ok); XCTAssertTrue(String(decoding: arch.body.prefix(8), as: UTF8.self).hasPrefix("%PDF-1.7"))
        let orig = try await raw(app1, .GET, base(w.tenantA) + "/documents/\(docID)/file", token: w.alice.token)
        XCTAssertEqual(orig.body, original)
        try await aEq(try await count("dms_document_files", where: "document_id = '\(docID)' AND role = 'archive'"), 1)
    }

    /// AK-O2-6 (AK-D2): Zwei Worker auf zwei Verbindungen verarbeiten 16 Dokumente; jedes genau einmal (ein Engine-Aufruf, ein Text, eine Archivzeile, ein Übergang je Zustand).
    func testAKO2_6_twoWorkersProcessEachDocumentExactlyOnce() async throws {
        let w = try await world()
        var docs: [String] = []
        for i in 0..<16 { docs.append(try await newDoc(w.alice, w.tenantA, seed: "ocr-two-\(i)")["id"] as! String) }
        let engine = FakeOCREngine()
        engine.delay = .milliseconds(40)
        let w1 = makeWorker(engine, on: app1), w2 = makeWorker(engine, on: app2)
        let r1 = Task { await w1.run() }, r2 = Task { await w2.run() }
        try await waitFor("alle done") { try await count("dms_ingest_items", where: "state = 'done'") == 16 }
        w1.requestShutdown(); w2.requestShutdown(); await r1.value; await r2.value
        XCTAssertEqual(engine.calls, 16, "genau ein Engine-Lauf je Dokument")
        XCTAssertGreaterThanOrEqual(engine.peak, 2, "beide Worker haben tatsächlich parallel gearbeitet")
        try await aEq(try await count("dms_document_texts"), 16)
        try await aEq(try await scalar("SELECT count(DISTINCT document_id)::bigint AS v FROM dms_document_texts", as: Int64.self), 16)
        try await aEq(try await count("dms_document_files", where: "role = 'archive'"), 16)
        try await aEq(try await count("dms_ingest_transitions", where: "state = 'done'"), 16)
        try await aEq(try await count("jobs", where: "kind = 'dms.ocr' AND state = 'done' AND attempts = 1"), 16)
        try await aEq(try await auditCount("dms.ingest.ocr_done", tenant: w.tenantA), 16)
    }

    /// AK-O2-6, Variante Absturz/Lease-Verlust: Dasselbe Item läuft gleichzeitig in zwei Handlern (zwei Verbindungen) und noch einmal als Doppel-Job nach Abschluss;
    /// es entsteht genau ein Ergebnis (Zeilensperre, Zustandsprüfung), der Nachzügler tut nichts.
    func testAKO2_6_concurrentHandlersAndDuplicateJobYieldOneResult() async throws {
        let w = try await world()
        let doc = try await newDoc(w.alice, w.tenantA, seed: "ocr-race")
        let docID = doc["id"] as! String, itemID = UUID(uuidString: doc["ingest_item_id"] as! String)!
        let engine = FakeOCREngine(); engine.delay = .milliseconds(300)
        let payload = #"{"ingest_item_id":"\#(itemID)","tenant_id":"\#(w.tenantA)"}"#
        let job = ClaimedJob(id: UUID(), kind: DMSOCR.kind, payload: payload, attempts: 1)
        let h = handler(engine)
        let dbs: [any SQLDatabase] = [app1.db(.psql) as! any SQLDatabase, app2.db(.psql) as! any SQLDatabase]
        await withTaskGroup(of: Void.self) { g in
            for i in 0..<2 { g.addTask { try? await h(job, dbs[i]) } }
        }
        try await aEq(try await itemState(docID), "done")
        try await aEq(try await count("dms_document_texts", where: "document_id = '\(docID)'"), 1)
        try await aEq(try await count("dms_document_files", where: "document_id = '\(docID)' AND role = 'archive'"), 1)
        let calls = engine.calls
        try await h(job, dbs[0])   // Doppel-Job nach Abschluss
        XCTAssertEqual(engine.calls, calls, "fertiges Item wird nicht erneut verarbeitet")
        try await aEq(try await count("dms_document_texts", where: "document_id = '\(docID)'"), 1)
        try await aEq(try await auditCount("dms.ingest.ocr_done", tenant: w.tenantA), 1)
    }

    /// Dauerhafter Fehler (z. B. verschlüsseltes PDF): sofort Quarantäne, Item `failed_permanent` mit Code, Status-Route zeigt `failed`; kein Text.
    func testPermanentFailureQuarantinesItem() async throws {
        let w = try await world()
        let docID = try await newDoc(w.alice, w.tenantA, seed: "ocr-perm")["id"] as! String
        let engine = FakeOCREngine(); engine.behavior = { _ in throw OCRFailure(code: "pdf_encrypted", permanent: true) }
        let worker = makeWorker(engine)
        let run = Task { await worker.run() }
        try await waitFor("quarantine") { try await count("jobs", where: "kind = 'dms.ocr' AND state = 'failed_permanent'") == 1 }
        worker.requestShutdown(); await run.value
        XCTAssertEqual(engine.calls, 1)
        try await aEq(try await itemState(docID), "failed_permanent")
        let st = try await processing(w, docID)
        XCTAssertEqual(st.json["phase"] as? String, "failed"); XCTAssertEqual(st.json["error_code"] as? String, "pdf_encrypted")
        try await aEq(try await count("dms_document_texts", where: "document_id = '\(docID)'"), 0)
        try await aEq(try await scalar("SELECT last_error AS v FROM jobs WHERE kind = 'dms.ocr'", as: String.self), "pdf_encrypted")
    }

    /// Vorübergehender Fehler: nach Wiederholung Erfolg (Zustand wechselt failed_retryable -> ocr_queued -> done); bei dauerhaft vorübergehendem Fehler nach 3 Versuchen Quarantäne.
    func testRetryableFailureRecoversAndPoisonEndsPermanent() async throws {
        let w = try await world()
        let ok = try await newDoc(w.alice, w.tenantA, seed: "ocr-retry-ok")["id"] as! String
        let engine = FakeOCREngine(); engine.behavior = { call in if call == 1 { throw OCRFailure(code: "ocr_timeout", permanent: false) } }
        let worker = makeWorker(engine)
        let run = Task { await worker.run() }
        try await waitFor("recovered") { try await itemState(ok) == "done" }
        worker.requestShutdown(); await run.value
        XCTAssertEqual(engine.calls, 2)
        try await aEq(try await scalar("SELECT attempts AS v FROM jobs WHERE kind = 'dms.ocr'", as: Int32.self), 2)

        let bad = try await newDoc(w.alice, w.tenantA, seed: "ocr-retry-bad")["id"] as! String
        let poison = FakeOCREngine(); poison.behavior = { _ in throw OCRFailure(code: "ocr_timeout", permanent: false) }
        let worker2 = makeWorker(poison)
        let run2 = Task { await worker2.run() }
        try await waitFor("poison") { try await itemState(bad) == "failed_permanent" }
        try await waitFor("job quarantined") { try await count("jobs", where: "state = 'failed_permanent'") == 1 }
        worker2.requestShutdown(); await run2.value
        XCTAssertEqual(poison.calls, DMSOCR.maxAttempts)
        try await aEq(try await scalar("SELECT error_code AS v FROM dms_ingest_items WHERE document_id = '\(bad)'", as: String.self), "ocr_timeout")
    }

    /// Status-Route: Mandantentrennung (fremder Mandant 404), unbekannte ID 404, Dokument ohne Eingangsvorgang -> `none`, anonym 401.
    func testProcessingRouteTenantIsolationAndShape() async throws {
        let w = try await world()
        let docID = try await newDoc(w.alice, w.tenantA, seed: "ocr-status")["id"] as! String
        let tenantB = (try await call(app1, .POST, "api/v1/tenants", json: ["name": "Zweiter Mandant"], token: w.alice.token)).json["id"] as! String
        let carol = try await addUser("owner", handle: "carol", tenant: tenantB, by: w.alice)
        try await setModule(tenantB, true, by: carol)
        let foreign = try await processing(w, docID, token: carol.token, tenant: tenantB)
        XCTAssertEqual(foreign.status, .notFound)
        let unknown = try await processing(w, UUID().uuidString)
        XCTAssertEqual(unknown.status, .notFound)
        let anon = try await raw(app1, .GET, base(w.tenantA) + "/documents/\(docID)/processing", token: "x")
        XCTAssertEqual(anon.status, .unauthorized)
        let bare = UUID()
        try await db.raw("INSERT INTO dms_documents (id, tenant_id, title) VALUES (\(bind: bare), \(bind: UUID(uuidString: w.tenantA)!), 'ohne Eingang')").run()
        let none = try await processing(w, bare.uuidString)
        XCTAssertEqual(none.status, .ok); XCTAssertEqual(none.json["phase"] as? String, "none"); XCTAssertNil(none.json["ingest_item_id"] as? String)
    }

    /// Migration dms_019: Spalte job_id, Revert und erneutes Anwenden.
    func testMigrationOcrRevertAndReapply() async throws {
        _ = try await world(enable: false)
        try await aEq(try await count("_fluent_migrations", where: "name = 'dms_019_ocr'"), 1)
        try await aEq(try await count("information_schema.columns", where: "table_name = 'dms_ingest_items' AND column_name = 'job_id'"), 1)
        try await CreateDMSOCR().revert(on: app1.db(.psql))
        try await aEq(try await count("information_schema.columns", where: "table_name = 'dms_ingest_items' AND column_name = 'job_id'"), 0)
        try await CreateDMSOCR().prepare(on: app1.db(.psql))
        try await aEq(try await count("information_schema.columns", where: "table_name = 'dms_ingest_items' AND column_name = 'job_id'"), 1)
    }
}

/// Reine Funktionen und Prozess-Limits (ohne OCR-Werkzeuge).
final class OCRUnitTests: XCTestCase {
    func testNormalizationDehyphenationAndLanguage() {
        let engine = OCRToolEngine(config: OCRConfig())
        XCTAssertEqual(engine.normalize("Rech-\nnung vom Ost-\nWest und Zu\u{0308}rich\u{0C}Seite 2"), "Rechnung vom Ost-\nWest und Zürich\n\nSeite 2")
        XCTAssertEqual(OCRToolEngine(config: OCRConfig(dehyphenate: false)).normalize("Rech-\nnung"), "Rech-\nnung")
        XCTAssertEqual(OCRToolEngine.detectLanguage("Please find the invoice for the order that we are sending to you"), "en")
        XCTAssertEqual(OCRToolEngine.detectLanguage("Bitte beachten Sie die Rechnung und den Betrag für die Lieferung"), "de")
        var c = OCRConfig(); c.maxTextCharacters = 10
        XCTAssertEqual(OCRToolEngine(config: c).normalize("abcdefghijklmnop").count, 10)
    }

    func testConfigFromEnvironmentRejectsNonsense() {
        let c = OCRConfig.fromEnvironment(["OCR_TIMEOUT_SECONDS": "-5", "OCR_MAX_PAGES": "x", "OCR_LANGUAGES": "deu+eng;rm", "OCR_TMPDIR": "relativ", "OCR_MEMORY_MB": "1024"])
        XCTAssertEqual(c.timeoutSeconds, 600); XCTAssertEqual(c.maxPages, 300); XCTAssertEqual(c.languages, "deu+eng"); XCTAssertEqual(c.memoryMB, 1024)
        XCTAssertNotEqual(c.tempRoot, "relativ")
    }

    func scratch() throws -> URL {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("lh-o2-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    /// AK-O2-4 (Mechanismus): Ein hängender Prozess wird nach dem Zeitlimit hart beendet; der Aufruf kehrt zügig zurück und meldet `timedOut`.
    func testAKO2_4_timeLimitKillsRunawayProcess() async throws {
        let dir = try scratch(); defer { try? FileManager.default.removeItem(at: dir) }
        let start = Date()
        let r = try await OCRProcess.run("sh", ["-c", "sleep 60"], workDir: dir, timeout: 1)
        XCTAssertTrue(r.timedOut)
        XCTAssertLessThan(Date().timeIntervalSince(start), 10)
        XCTAssertNotEqual(r.exitCode, 0)
    }

    /// AK-O2-4 (Abbruch): Cancellation beendet den Fremdprozess (Worker-Shutdown, Lease-Verlust).
    func testAKO2_4_cancellationKillsProcess() async throws {
        let dir = try scratch(); defer { try? FileManager.default.removeItem(at: dir) }
        let task = Task { try await OCRProcess.run("sh", ["-c", "sleep 60"], workDir: dir, timeout: 120) }
        try await Task.sleep(for: .milliseconds(300))
        let start = Date()
        task.cancel()
        let r = try await task.value
        XCTAssertLessThan(Date().timeIntervalSince(start), 10)
        XCTAssertFalse(r.timedOut); XCTAssertNotEqual(r.exitCode, 0)
    }

    /// AK-O2-4 (Speicher, Linux): Adressraumlimit lässt eine große Allokation scheitern, kleine laufen.
    func testAKO2_4_memoryLimitStopsGreedyProcess() async throws {
        #if os(Linux)
        let dir = try scratch(); defer { try? FileManager.default.removeItem(at: dir) }
        guard (try? await OCRProcess.run("python3", ["-c", "pass"], workDir: dir, timeout: 20))?.exitCode == 0 else { throw XCTSkip("python3 fehlt") }
        let big = try await OCRProcess.run("python3", ["-I", "-c", "x = bytearray(1 << 30)"], workDir: dir, timeout: 30, memoryBytes: 256 << 20)
        XCTAssertNotEqual(big.exitCode, 0, "1 GiB bei 256 MiB Limit")
        XCTAssertFalse(big.timedOut)
        let small = try await OCRProcess.run("python3", ["-I", "-c", "x = bytearray(1 << 20)"], workDir: dir, timeout: 30, memoryBytes: 1 << 30)
        XCTAssertEqual(small.exitCode, 0, small.stderr)
        #else
        throw XCTSkip("Speicherlimit (ulimit -v) wird nur unter Linux gesetzt; Prüfung im Container (scripts/ocr-container-test.sh)")
        #endif
    }
}
