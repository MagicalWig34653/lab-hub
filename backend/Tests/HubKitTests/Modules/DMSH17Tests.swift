import XCTVapor
import Fluent
import SQLKit
@testable import HubKit

/// WP-H17, Codex-Befund 8 (Rest): Scheitert ein OCR-Job endgültig (Quarantäne nach Absturzschleife, Versuche erschöpft oder `permanent`),
/// muss auch der Eingangsvorgang in der Datenbank `failed_permanent` sein. Sonst zählt ihn die Übersicht als „in Verarbeitung“ und nicht als Fehler.
/// Zeit wird kontrolliert: abgelaufene Leases werden per SQL gesetzt, es gibt keine Wartezeiten.
final class H17OCRQuarantineSyncTests: DMSOCRTestBase {
    /// Job `maxAttempts`-mal mit abgelaufener Lease abholen (Absturzschleife); der vierte `claim` quarantänisiert im Kern.
    func crashLoop(_ owner: String = "crash") async throws {
        let jobs = JobService(db)
        for _ in 0..<3 {
            let claimed = try await jobs.claim(owner: owner, leaseSeconds: 30, kinds: [DMSOCR.kind])
            XCTAssertNotNil(claimed)
            try await db.raw("UPDATE jobs SET lease_until = now() - interval '1 second' WHERE kind = 'dms.ocr' AND state = 'running'").run()
        }
        let none = try await jobs.claim(owner: owner, leaseSeconds: 30, kinds: [DMSOCR.kind])
        XCTAssertNil(none)
    }

    func item(_ doc: String) async throws -> (state: String, code: String?, resume: String?) {
        let row = try await db.raw("SELECT state, error_code, resume_state FROM dms_ingest_items WHERE document_id = \(bind: UUID(uuidString: doc)!)").first()!
        return (try row.decode(column: "state", as: String.self), try row.decode(column: "error_code", as: String?.self), try row.decode(column: "resume_state", as: String?.self))
    }

    func stats(_ w: World, app: Application? = nil) async throws -> [String: Any] {
        let r = try await raw(app ?? app1, .GET, base(w.tenantA) + "/stats", token: w.alice.token)
        XCTAssertEqual(r.status, .ok, "\(r.json)")
        return r.json
    }

    /// AK-H17-1: Nach der Absturzschleife steht das Item in der Datenbank auf `failed_permanent` (`lease_expired`, Wiederaufnahme bei `ocr_queued`);
    /// Status und Übersicht zeigen den Fehler (Zähler `failed` statt `queued`); der Retry wirkt einmal, der Worker beendet den Vorgang, der Fehler verschwindet.
    func testAKH17_1_crashLoopMarksItemFailedAndRetryClearsIt() async throws {
        let w = try await world()
        let doc = try await newDoc(w.alice, w.tenantA, seed: "h17-crash")["id"] as! String
        let before = try await stats(w)
        XCTAssertEqual(before["queued"] as? Int, 1); XCTAssertEqual(before["failed"] as? Int, 0)

        try await crashLoop()
        let it = try await item(doc)
        XCTAssertEqual(it.state, "failed_permanent")
        XCTAssertEqual(it.code, "lease_expired")
        XCTAssertEqual(it.resume, "ocr_queued")
        let st = try await processing(w, doc)
        XCTAssertEqual(st.json["phase"] as? String, "failed", "\(st.json)")
        XCTAssertEqual(st.json["error_code"] as? String, "lease_expired")
        let after = try await stats(w)
        XCTAssertEqual(after["queued"] as? Int, 0, "\(after)"); XCTAssertEqual(after["failed"] as? Int, 1, "\(after)")

        let url = base(w.tenantA) + "/documents/\(doc)/processing/retry"
        let r = try await raw(app2, .POST, url, token: w.alice.token)
        XCTAssertEqual(r.status, .ok, "\(r.json)")
        XCTAssertEqual(r.json["phase"] as? String, "queued")
        try await aEq(try await itemState(doc), "ocr_queued")
        try await aEq(try await count("jobs", where: "kind = 'dms.ocr' AND state = 'queued'"), 1)
        let mid = try await stats(w); XCTAssertEqual(mid["failed"] as? Int, 0); XCTAssertEqual(mid["queued"] as? Int, 1)

        let engine = FakeOCREngine()
        let worker = makeWorker(engine)
        let run = Task { await worker.run() }
        try await waitFor("done after retry") { try await itemState(doc) == "done" }
        worker.requestShutdown(); await run.value
        XCTAssertEqual(engine.calls, 1)
        let end = try await stats(w); XCTAssertEqual(end["failed"] as? Int, 0); XCTAssertEqual(end["queued"] as? Int, 0)

        let again = try await raw(app1, .POST, url, token: w.alice.token)
        XCTAssertEqual(again.status, .conflict); XCTAssertEqual(again.problemCode, "ingest_not_failed")
    }

    /// AK-H17-2: Regulärer endgültiger Fehlschlag ohne `giveUp` des Handlers (Handler-Ausnahme bei der letzten Wiederholung, `permanent`): Item `failed_permanent`
    /// mit dem Fehlercode des Jobs. Ein Code außerhalb von `^[a-z0-9_.]{1,64}$` (Großbuchstaben, Bindestrich) lässt den Jobübergang nicht scheitern, das Item erhält `error`.
    func testAKH17_2_regularFinalFailureSyncsItem() async throws {
        let w = try await world()
        let jobs = JobService(db)
        // (a) Versuche erschöpft: dreimal holen und als Handlerfehler melden
        let a = try await newDoc(w.alice, w.tenantA, seed: "h17-attempts")["id"] as! String
        for i in 1...3 {
            let c = try await jobs.claim(owner: "w", leaseSeconds: 30, kinds: [DMSOCR.kind]); XCTAssertNotNil(c)
            let out = try await jobs.fail(c!.id, owner: "w", code: "handler_error", retryAfterSeconds: 0)
            XCTAssertEqual(out, i < 3 ? .retry : .failedPermanent)
            if i < 3 { try await aEq(try await item(a).state, "ocr_queued") }
        }
        let ia = try await item(a)
        XCTAssertEqual(ia.state, "failed_permanent"); XCTAssertEqual(ia.code, "handler_error"); XCTAssertEqual(ia.resume, "ocr_queued")

        // (b) `permanent` mit ungültigem Fehlercode für die Spalte (Großbuchstaben/Bindestrich bleiben im Job erhalten)
        let b = try await newDoc(w.alice, w.tenantA, seed: "h17-permanent")["id"] as! String
        let c = try await jobs.claim(owner: "w", leaseSeconds: 30, kinds: [DMSOCR.kind]); XCTAssertNotNil(c)
        let out = try await jobs.fail(c!.id, owner: "w", code: "Bad-Code", retryAfterSeconds: 0, permanent: true)
        XCTAssertEqual(out, .failedPermanent)
        try await aEq(try await scalar("SELECT last_error AS v FROM jobs WHERE id = '\(c!.id.uuidString)'", as: String.self), "Bad-Code")
        let ib = try await item(b)
        XCTAssertEqual(ib.state, "failed_permanent"); XCTAssertEqual(ib.code, "error")

        let st = try await processing(w, b)
        XCTAssertEqual(st.json["phase"] as? String, "failed", "\(st.json)")
        let retry = try await raw(app1, .POST, base(w.tenantA) + "/documents/\(b)/processing/retry", token: w.alice.token)
        XCTAssertEqual(retry.status, .ok, "\(retry.json)")
    }

    /// AK-H17-3: Kein Überschreiben und keine Fremdwirkung: Hat der Handler das Item schon auf `failed_permanent` gesetzt, bleibt sein Code; ein erledigtes Item und
    /// Jobs anderer Arten bleiben unberührt; `failed_retryable` wird bei endgültigem Job-Fehlschlag auf `failed_permanent` angehoben (Code des Jobs).
    func testAKH17_3_noOverwriteNoSideEffects() async throws {
        let w = try await world()
        let jobs = JobService(db)
        let own = try await newDoc(w.alice, w.tenantA, seed: "h17-own")["id"] as! String
        let done = try await newDoc(w.alice, w.tenantA, seed: "h17-done")["id"] as! String
        let retryable = try await newDoc(w.alice, w.tenantA, seed: "h17-retryable")["id"] as! String
        let foreign = try await newDoc(w.alice, w.tenantA, seed: "h17-foreign")["id"] as! String
        try await db.raw("UPDATE dms_ingest_items SET state = 'failed_permanent', error_code = 'ocr_failed', resume_state = 'ocr_queued' WHERE document_id = \(bind: UUID(uuidString: own)!)").run()
        try await db.raw("UPDATE dms_ingest_items SET state = 'done' WHERE document_id = \(bind: UUID(uuidString: done)!)").run()
        try await db.raw("UPDATE dms_ingest_items SET state = 'failed_retryable', error_code = 'ocr_failed', resume_state = 'ocr_queued' WHERE document_id = \(bind: UUID(uuidString: retryable)!)").run()
        // Item im Zustand `ocr_queued`, dessen `job_id` auf einen Job anderer Art zeigt: dessen Scheitern darf nichts ändern
        let other = try await jobs.enqueue(kind: "other.kind")
        try await db.raw("UPDATE dms_ingest_items SET job_id = \(bind: other) WHERE document_id = \(bind: UUID(uuidString: foreign)!)").run()

        // alle OCR-Jobs endgültig scheitern lassen, danach den Job anderer Art
        while let c = try await jobs.claim(owner: "w", leaseSeconds: 30, kinds: [DMSOCR.kind]) {
            _ = try await jobs.fail(c.id, owner: "w", code: "handler_error", retryAfterSeconds: 0, permanent: true)
        }
        let o = try await jobs.claim(owner: "w", leaseSeconds: 30, kinds: ["other.kind"]); XCTAssertNotNil(o)
        _ = try await jobs.fail(o!.id, owner: "w", code: "handler_error", retryAfterSeconds: 0, permanent: true)
        try await aEq(try await count("jobs", where: "state = 'failed_permanent'"), 5)

        let io = try await item(own); XCTAssertEqual(io.state, "failed_permanent"); XCTAssertEqual(io.code, "ocr_failed")   // eigener Code bleibt
        let id = try await item(done); XCTAssertEqual(id.state, "done"); XCTAssertNil(id.code)
        let ir = try await item(retryable); XCTAssertEqual(ir.state, "failed_permanent"); XCTAssertEqual(ir.code, "handler_error"); XCTAssertEqual(ir.resume, "ocr_queued")
        let ifo = try await item(foreign); XCTAssertEqual(ifo.state, "ocr_queued"); XCTAssertNil(ifo.code)   // Job anderer Art: keine Wirkung
    }

    /// AK-H17-4: Zwei Instanzen holen gleichzeitig nach der Absturzschleife: Item wird genau einmal und konsistent markiert (kein Fehler, ein Übergang), ein Retry wirkt einmal.
    func testAKH17_4_concurrentClaimsAfterCrashLoop() async throws {
        let w = try await world()
        let doc = try await newDoc(w.alice, w.tenantA, seed: "h17-two")["id"] as! String
        let jobs = JobService(db)
        for _ in 0..<3 {
            _ = try await jobs.claim(owner: "crash", leaseSeconds: 30, kinds: [DMSOCR.kind])
            try await db.raw("UPDATE jobs SET lease_until = now() - interval '1 second' WHERE kind = 'dms.ocr' AND state = 'running'").run()
        }
        let d1 = app1.db(.psql) as! any SQLDatabase, d2 = app2.db(.psql) as! any SQLDatabase
        async let x = JobService(d1).claim(owner: "w1", leaseSeconds: 30, kinds: [DMSOCR.kind])
        async let y = JobService(d2).claim(owner: "w2", leaseSeconds: 30, kinds: [DMSOCR.kind])
        let (c1, c2) = try await (x, y)
        XCTAssertNil(c1); XCTAssertNil(c2)
        let it = try await item(doc)
        XCTAssertEqual(it.state, "failed_permanent"); XCTAssertEqual(it.code, "lease_expired")
        try await aEq(try await count("jobs", where: "kind = 'dms.ocr' AND state = 'failed_permanent'"), 1)
        let url = base(w.tenantA) + "/documents/\(doc)/processing/retry"
        async let a = raw(app1, .POST, url, token: w.alice.token)
        async let b = raw(app2, .POST, url, token: w.alice.token)
        let statuses = try await [a.status, b.status].sorted { $0.code < $1.code }
        XCTAssertEqual(statuses, [.ok, .conflict])
        try await aEq(try await count("jobs", where: "kind = 'dms.ocr'"), 2)
    }

    /// AK-H17-5: Migration `dms_027`: bereits hängende Items (Job schon `failed_permanent`, Item `ocr_queued`) werden beim Einspielen berichtigt; Revert entfernt Trigger
    /// und Funktion, danach verhält sich der Kern wie vor H17 (H14-Retry bleibt möglich).
    func testAKH17_5_migrationBackfillAndRevert() async throws {
        let w = try await world()
        let doc = try await newDoc(w.alice, w.tenantA, seed: "h17-migrate")["id"] as! String
        try await CreateDMSOCRQuarantineSync().revert(on: app1.db(.psql))
        try await aEq(try await scalar("SELECT count(*)::bigint AS v FROM pg_trigger WHERE tgname = 'dms_ocr_job_quarantined'", as: Int64.self), 0)
        try await crashLoop()
        try await aEq(try await item(doc).state, "ocr_queued")                       // Altzustand: Item hängt
        let st = try await processing(w, doc)
        XCTAssertEqual(st.json["phase"] as? String, "failed", "\(st.json)")           // H14-Toleranz im Status bleibt
        try await CreateDMSOCRQuarantineSync().prepare(on: app1.db(.psql))
        let it = try await item(doc)
        XCTAssertEqual(it.state, "failed_permanent"); XCTAssertEqual(it.code, "lease_expired"); XCTAssertEqual(it.resume, "ocr_queued")
        try await aEq(try await scalar("SELECT count(*)::bigint AS v FROM pg_trigger WHERE tgname = 'dms_ocr_job_quarantined'", as: Int64.self), 1)
        let s = try await stats(w); XCTAssertEqual(s["failed"] as? Int, 1)
    }
}
