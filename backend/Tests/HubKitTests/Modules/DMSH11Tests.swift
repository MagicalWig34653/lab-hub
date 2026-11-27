import XCTVapor
import Fluent
import SQLKit
@testable import HubCore
@testable import HubKit
@testable import HubModuleDMS
@testable import HubModuleInvoice

// WP-H11 (Codex-Review 17.11.2026, hohe Befunde). Nur synthetische Daten.
//  AK-H11-1: Paperless-Zahlen außerhalb von Int64 bzw. nicht endlich brechen den Worker nicht ab (Quelldaten ungültig -> nil).
//  AK-H11-2: Export und OCR-Archiv respektieren die Mandanten-Quota (`storage_quota_exceeded`, keine files-Zeile, Job endgültig fehlgeschlagen).
//  AK-H11-3: Der Dateideskriptor des Filesystem-Stores wird bei Abbruch und Lesefehler geschlossen.

final class H11ParsingTests: XCTestCase {
    func testAKH11_1_numbersOutsideInt64AreRejected() {
        XCTAssertNil(PL.int(1e100))
        XCTAssertNil(PL.int(-1e100))
        XCTAssertNil(PL.int(Double.infinity))
        XCTAssertNil(PL.int(-Double.infinity))
        XCTAssertNil(PL.int(Double.nan))
        XCTAssertNil(PL.int(-1e19))
        XCTAssertNil(PL.int(9.3e18))
        XCTAssertEqual(PL.int(42.0), 42)
        XCTAssertEqual(PL.int(-7.0), -7)
        XCTAssertNil(PL.int(1.5))
        XCTAssertEqual(PL.int(Int64.max), Int64.max)
    }
}

final class H11FilesystemFDTests: XCTestCase {
    var root: URL!
    override func setUp() async throws { root = FileManager.default.temporaryDirectory.appendingPathComponent("labhub-h11-\(UUID().uuidString)") }
    override func tearDown() async throws { try? FileManager.default.removeItem(at: root) }

    private func openFDs() -> Int { ((try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd")) ?? []).count }

    /// Stream nach einem Chunk verworfen (Client-Abbruch): kein offener Deskriptor.
    func testAKH11_3_abandonedStreamClosesDescriptor() async throws {
        let store = FilesystemObjectStore(root: root)
        let data = [UInt8](repeating: 7, count: 3 * objectStoreChunkSize)
        let stored = try await store.put(tenant: UUID(), stream: streamOf(data), expectedSHA256: nil)
        let before = openFDs()
        for _ in 0..<20 {
            let stream = try await store.get(stored.key)
            var it = stream.makeAsyncIterator()
            let first = try await it.next()
            XCTAssertNotNil(first)
        }
        XCTAssertEqual(openFDs(), before, "abandoned downloads leak file descriptors")
    }

    /// Lesefehler (hier: Verzeichnis statt Datei, read liefert EISDIR): Deskriptor wird geschlossen.
    func testAKH11_3_readErrorClosesDescriptor() async throws {
        let store = FilesystemObjectStore(root: root)
        let key = try ObjectKey(tenantID: UUID(), sha256: sha256Hex(Array("h11".utf8)))
        try FileManager.default.createDirectory(at: root.appendingPathComponent(key.path), withIntermediateDirectories: true)
        let before = openFDs()
        for _ in 0..<20 {
            let stream = try await store.get(key)
            do { for try await _ in stream {}; XCTFail("expected read error") } catch {}
        }
        XCTAssertEqual(openFDs(), before, "failed reads leak file descriptors")
    }
}

final class H11ExportQuotaTests: DMSRevisionTestBase {
    func testAKH11_2_exportRespectsQuota() async throws {
        let w = try await world()
        _ = try await newDoc(w.alice, w.tenantA, seed: "h11-exp")
        let used = try await count("files")
        XCTAssertGreaterThan(used, 0)
        let usedBytes = try await scalar("SELECT COALESCE(sum(size_bytes),0)::bigint AS v FROM files WHERE tenant_id = '\(w.tenantA)'", as: Int64.self)
        let r = try await raw(app1, .POST, base(w.tenantA) + "/exports", body: Data("{}".utf8), token: w.alice.token, headers: ["Content-Type": "application/json"])
        let id = try XCTUnwrap(r.json["id"] as? String, "\(r.json)")
        let inner = DMSExport.handler(tempRoot: NSTemporaryDirectory(), quotaBytes: usedBytes) { s in try ObjectStoreConfig(kind: .db).makeStore(db: s) }
        // The handler marks the export `failed` before the worker quarantines the job. Hold the handler's return back, as a loaded machine does.
        let slowTail: JobHandler = { job, db in
            do { try await inner(job, db) } catch { try? await Task.sleep(for: .milliseconds(400)); throw error }
        }
        let handlers: [String: JobHandler] = [DMSExport.kind: slowTail]
        let worker = JobWorker(db: app1.db(.psql) as! any SQLDatabase, kinds: [DMSExport.kind], handlers: handlers, leaseSeconds: 30, pollInterval: .milliseconds(100), retryBackoffSeconds: 0, logger: Logger(label: "test.h11"))
        let run = Task { await worker.run() }
        // Wait for the end of the chain (export failed AND job quarantined): a shutdown in between would release the job instead.
        try await waitFor("export failed and job quarantined") {
            let exportState = try await scalar("SELECT state AS v FROM dms_exports WHERE id = '\(id)'", as: String.self)
            let quarantined = try await count("jobs", where: "kind = 'dms.export' AND state = 'failed_permanent'")
            return exportState == "failed" && quarantined == 1
        }
        worker.requestShutdown(); await run.value
        try await aEq(try await scalar("SELECT error_code AS v FROM dms_exports WHERE id = '\(id)'", as: String.self), "storage_quota_exceeded")
        try await aEq(try await count("files"), used)
        try await aEq(try await count("jobs", where: "kind = 'dms.export' AND state = 'failed_permanent'"), 1)
    }
}

final class H11OCRQuotaTests: DMSOCRTestBase {
    func testAKH11_2_ocrArchiveRespectsQuota() async throws {
        let w = try await world()
        let up = try await upload(w.alice, w.tenantA, pdf("h11-ocr"))
        let docID = up.json["id"] as! String
        let used = try await count("files")
        let usedBytes = try await scalar("SELECT COALESCE(sum(size_bytes),0)::bigint AS v FROM files WHERE tenant_id = '\(w.tenantA)'", as: Int64.self)
        let h = DMSOCR.handler(engine: FakeOCREngine(), tempRoot: NSTemporaryDirectory(), quotaBytes: usedBytes) { s in try ObjectStoreConfig(kind: .db).makeStore(db: s) }
        let worker = JobWorker(db: app1.db(.psql) as! any SQLDatabase, kinds: [DMSOCR.kind], handlers: [DMSOCR.kind: h], leaseSeconds: 30, pollInterval: .milliseconds(100), retryBackoffSeconds: 0, logger: Logger(label: "test.h11"))
        let run = Task { await worker.run() }
        try await waitFor("ocr failed") { try await itemState(docID) == "failed_permanent" }
        worker.requestShutdown(); await run.value
        try await aEq(try await scalar("SELECT error_code AS v FROM dms_ingest_items WHERE document_id = '\(docID)'", as: String.self), "storage_quota_exceeded")
        try await aEq(try await count("files"), used)
        try await aEq(try await count("dms_document_files", where: "document_id = '\(docID)' AND role = 'archive'"), 0)
    }
}
