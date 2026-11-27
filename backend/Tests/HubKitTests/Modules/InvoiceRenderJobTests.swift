import XCTVapor
import Fluent
import SQLKit
import Crypto
@testable import HubCore
@testable import HubKit
@testable import HubModuleDMS
@testable import HubModuleInvoice

// WP-R6c: Render-Job `invoice.render` (Lease, Speicherung, Zustandstabelle), PDF-Download. Nur synthetische Belege.
// Die Tests dieser Datei brauchen weder Typst noch qpdf: der Renderer ist ein Zähler mit festen Bytes (`FakeRenderer`); alles andere
// (Datenbank, Job-Dienst, Worker-Schleife, Objektspeicher, Routen) ist echt. Der echte Renderer läuft im E2E-Test unten (`InvoiceRenderWorkerE2ETests`).

/// Ersatz für Typst: zählt Aufrufe, liefert je Beleg feste Bytes (mit `%PDF-`, damit auch das DMS sie als PDF annimmt), kann scheitern.
final class FakeRenderer: InvoiceRendering, @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    private var failuresLeft: Int
    let delay: Duration
    let layoutKey: String
    let layoutVersion: Int
    let version: String
    /// Ändert die Bytes (zweite „Rendererversion“): ein fertiges PDF darf dadurch nie ersetzt werden.
    let variant: String

    init(delay: Duration = .zero, failFirst: Int = 0, layoutVersion: Int = 1, version: String = "fake 1.0", variant: String = "") {
        self.delay = delay; self.failuresLeft = failFirst; self.layoutKey = "standard"; self.layoutVersion = layoutVersion; self.version = version; self.variant = variant
    }

    var callCount: Int { lock.lock(); defer { lock.unlock() }; return calls }
    func failNext(_ n: Int) { lock.lock(); failuresLeft = n; lock.unlock() }

    func rendererVersion() async throws -> String { version }

    /// Zählt den Aufruf; `true`, wenn er scheitern soll (synchron, wegen der Sperre).
    private func register() -> Bool {
        lock.lock(); defer { lock.unlock() }
        calls += 1
        guard failuresLeft > 0 else { return false }
        failuresLeft -= 1
        return true
    }

    func render(_ documentJSON: Data) async throws -> Data {
        let fail = register()
        if delay > .zero { try await Task.sleep(for: delay) }
        if fail { throw InvoiceRenderError.failed(tool: "typst", exitCode: 1, diagnostics: "geheimer Belegtext") }
        let number = ((try? JSONSerialization.jsonObject(with: documentJSON)) as? [String: Any])?["number"] as? String ?? "?"
        return Data("%PDF-1.4\n% synthetic render \(variant) of \(number)\n1 0 obj\n<< /Type /Catalog >>\nendobj\ntrailer\n<< /Root 1 0 R >>\n%%EOF\n".utf8)
    }
}

struct RenderResp: @unchecked Sendable {
    let status: HTTPStatus
    let headers: HTTPHeaders
    let body: Data
    var json: [String: Any] { (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:] }
    var problemCode: String? { json["code"] as? String }
}

class InvoiceRenderTestBase: InvoiceTestBase {
    struct Setup {
        let w: World
        let typeID: String
        let contact: String
        var docs: String { "api/v1/tenants/\(w.tenantA)/invoice/documents" }
    }

    /// Absender, Serie `RE-{N:4}`, Belegtyp „Rechnung“ mit Standardserie, ein Kontakt.
    func setup() async throws -> Setup {
        let w = try await world()
        let put = try await call(app1, .PUT, base(w.tenantA) + "/settings", json: ["sender_name": "Muster GmbH", "city": "Musterstadt", "currency": "EUR"], token: w.alice.token)
        XCTAssertEqual(put.status, .ok, "\(put.json)")
        let s = try await series(w, format: "RE-{N:4}")
        XCTAssertEqual(s.status, .created, "\(s.json)")
        let t = try await call(app1, .POST, base(w.tenantA) + "/document-types", json: ["code": "invoice", "name": "Rechnung", "kind": "invoice", "default_series_id": s.json["id"] as! String], token: w.alice.token)
        XCTAssertEqual(t.status, .created, "\(t.json)")
        let c = try await call(app1, .POST, "api/v1/tenants/\(w.tenantA)/contacts", json: ["kind": "organization", "display_name": "Kunde AG"], token: w.alice.token)
        XCTAssertEqual(c.status, .created, "\(c.json)")
        return Setup(w: w, typeID: t.json["id"] as! String, contact: c.json["id"] as! String)
    }

    func draftBody(_ s: Setup) -> [String: Any] {
        ["document_type_id": s.typeID, "contact_id": s.contact, "issue_date": "2026-11-23", "currency": "EUR", "price_mode": "net",
         "lines": [["kind": "item", "description": "Beratung", "quantity": "3", "unit_price": "49.99", "tax_rate": "19"]]]
    }

    func draft(_ s: Setup) async throws -> String {
        let r = try await call(app1, .POST, s.docs, json: draftBody(s), token: s.w.alice.token)
        XCTAssertEqual(r.status, .created, "\(r.json)")
        return r.json["id"] as! String
    }

    @discardableResult
    func finalize(_ s: Setup, _ id: String, via: Application? = nil, headers: [String: String] = [:]) async throws -> Resp {
        try await call(via ?? app1, .POST, s.docs + "/\(id)/finalize", json: [String: Any](), token: s.w.alice.token, headers: headers)
    }

    /// Neuer finaler Beleg; Rückgabe: Id.
    func finalDocument(_ s: Setup) async throws -> String {
        let id = try await draft(s)
        let r = try await finalize(s, id)
        XCTAssertEqual(r.status, .ok, "\(r.json)")
        return id
    }

    func raw(_ app: Application, _ method: HTTPMethod, _ path: String, token: String? = nil, headers extra: [String: String] = [:]) async throws -> RenderResp {
        var headers = HTTPHeaders()
        if let token { headers.bearerAuthorization = BearerAuthorization(token: token) }
        for (k, v) in extra { headers.replaceOrAdd(name: k, value: v) }
        let box = UnsafeSendableBox<RenderResp?>(nil)
        try await app.test(method, path, headers: headers) { res async throws in
            box.value = RenderResp(status: res.status, headers: res.headers, body: Data(buffer: res.body))
        }
        return box.value!
    }

    func pdf(_ s: Setup, _ id: String, token: String? = nil, via: Application? = nil, headers: [String: String] = [:]) async throws -> RenderResp {
        try await raw(via ?? app1, .GET, s.docs + "/\(id)/pdf", token: token ?? s.w.alice.token, headers: headers)
    }

    func renderRequest(_ s: Setup, _ id: String, token: String? = nil, via: Application? = nil) async throws -> RenderResp {
        try await raw(via ?? app1, .POST, s.docs + "/\(id)/render", token: token ?? s.w.alice.token)
    }

    static func store(_ s: any SQLDatabase) throws -> any ObjectStore { try ObjectStoreConfig(kind: .db).makeStore(db: s) }

    func makeWorker(_ app: Application, _ renderer: any InvoiceRendering, lease: Int = 30) -> JobWorker {
        JobWorker(db: app.db(.psql) as! any SQLDatabase, kinds: [InvoiceRenderJob.kind],
                  handlers: [InvoiceRenderJob.kind: InvoiceRenderJob.handler(renderer: renderer, storeFactory: Self.store)],
                  leaseSeconds: lease, pollInterval: .milliseconds(50), retryBackoffSeconds: 0, logger: Logger(label: "test.render"))
    }

    struct NoRow: Error, CustomStringConvertible { let query: String; var description: String { "keine Zeile: \(query)" } }

    /// Wie `scalar`, aber ein Fehler statt eines Absturzes, wenn die Abfrage keine Zeile liefert.
    func value<T: Decodable & Sendable>(_ sqlText: String, as type: T.Type) async throws -> T {
        guard let row = try await db.raw(SQLQueryString(sqlText)).first() else { throw NoRow(query: sqlText) }
        return try row.decode(column: "v", as: T.self)
    }

    func waitFor(_ what: String, timeout: Double = 25, _ cond: () async throws -> Bool) async throws {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end { if try await cond() { return }; try await Task.sleep(for: .milliseconds(50)) }
        XCTFail("Zeitüberschreitung: \(what)")
    }

    /// Startet die Worker, wartet bis die Bedingung gilt, beendet sie.
    func withWorkers(_ workers: [JobWorker], until cond: () async throws -> Bool) async throws {
        let runs = workers.map { w in Task { await w.run() } }
        defer { for w in workers { w.requestShutdown() } }
        try await waitFor("Worker-Ergebnis", cond)
        for w in workers { w.requestShutdown() }
        for r in runs { await r.value }
    }

    func jobsDone() async throws -> Int64 { try await count("jobs", where: "kind = 'invoice.render' AND state = 'done'") }

    struct StateRow: Equatable {
        let id: String, fileID: String, pdfSHA: String, inputHash: String, layoutKey: String, layoutVersion: Int, rendererVersion: String, createdAt: String
    }

    func states(_ doc: String) async throws -> [StateRow] {
        try await db.raw(SQLQueryString("""
            SELECT id::text AS id, file_id::text AS file_id, pdf_sha256, input_hash, layout_key, layout_version, renderer_version, created_at::text AS created_at
            FROM invoice_render_states WHERE document_id = '\(doc)'
            """)).all().map { r in
            StateRow(id: try r.decode(column: "id", as: String.self), fileID: try r.decode(column: "file_id", as: String.self), pdfSHA: try r.decode(column: "pdf_sha256", as: String.self),
                     inputHash: try r.decode(column: "input_hash", as: String.self), layoutKey: try r.decode(column: "layout_key", as: String.self),
                     layoutVersion: try r.decode(column: "layout_version", as: Int.self), rendererVersion: try r.decode(column: "renderer_version", as: String.self),
                     createdAt: try r.decode(column: "created_at", as: String.self))
        }
    }

    func sha(_ d: Data) -> String { SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined() }
}

// MARK: AK-R6c-1 zwei Worker, AK-R6c-2 Finalisieren, AK-R6c-3 nie neu

final class InvoiceRenderJobTests: InvoiceRenderTestBase {

    /// AK-R6c-1: Zwei Worker (zwei Instanzen, gleiche Datenbank) erzeugen für vier Belege genau vier PDF und genau eine Zustandszeile je Beleg.
    func testAKR6c_1_twoWorkersProduceExactlyOnePDFAndOneStateRowPerDocument() async throws {
        let s = try await setup()
        let renderer = FakeRenderer(delay: .milliseconds(40))
        var ids: [String] = []
        for _ in 0..<4 { ids.append(try await finalDocument(s)) }
        try await aEq(try await count("jobs", where: "kind = 'invoice.render' AND state = 'queued'"), 4, "Finalisieren legt je Beleg einen Job an")
        try await withWorkers([makeWorker(app1, renderer), makeWorker(app2, renderer)]) { try await jobsDone() == 4 }
        try await aEq(try await count("invoice_render_states"), 4)
        try await aEq(try await value("SELECT count(DISTINCT document_id)::bigint AS v FROM invoice_render_states", as: Int64.self), 4, "genau eine Zeile je Beleg")
        try await aEq(try await count("files", where: "content_type = 'application/pdf'"), 4)
        try await aEq(try await value("SELECT count(DISTINCT sha256)::bigint AS v FROM object_chunks", as: Int64.self), 4, "vier gespeicherte PDF")
        XCTAssertEqual(renderer.callCount, 4, "jeder Job wird von genau einem Worker ausgeführt")
        try await aEq(try await count("jobs", where: "kind = 'invoice.render' AND attempts = 1"), 4)
        for id in ids {
            let rows = try await states(id)
            XCTAssertEqual(rows.count, 1)
            let r = try await pdf(s, id)
            XCTAssertEqual(r.status, .ok)
            XCTAssertEqual(rows.first?.pdfSHA, sha(r.body), "Zustandszeile und ausgelieferte Bytes gehören zusammen")
        }
    }

    /// AK-R6c-1: Mehrere Jobs für denselben Beleg (z. B. Wiederholung nach Fehler) und zwei Worker: es bleibt bei einem PDF und einer Zustandszeile.
    func testAKR6c_1_duplicateJobsForOneDocumentStillStoreOnePDF() async throws {
        let s = try await setup()
        let id = try await finalDocument(s)
        let tenant = UUID(uuidString: s.w.tenantA)!, document = UUID(uuidString: id)!
        for _ in 0..<3 { _ = try await InvoiceRenderJob.enqueue(document: document, tenant: tenant, on: db) }
        try await aEq(try await count("jobs", where: "kind = 'invoice.render'"), 4)
        let renderer = FakeRenderer(delay: .milliseconds(40))
        try await withWorkers([makeWorker(app1, renderer), makeWorker(app2, renderer)]) { try await jobsDone() == 4 }
        let rows = try await states(id)
        XCTAssertEqual(rows.count, 1)
        try await aEq(try await count("files", where: "content_type = 'application/pdf'"), 1)
        try await aEq(try await value("SELECT count(DISTINCT sha256)::bigint AS v FROM object_chunks", as: Int64.self), 1)
        XCTAssertGreaterThanOrEqual(renderer.callCount, 1)
        XCTAssertEqual(rows.first?.layoutKey, "standard"); XCTAssertEqual(rows.first?.layoutVersion, 1); XCTAssertEqual(rows.first?.rendererVersion, "fake 1.0")
        let hash = try await value("SELECT content_hash AS v FROM invoice_documents WHERE id = '\(id)'", as: String.self)
        XCTAssertEqual(rows.first?.inputHash, hash, "Inhalt-Hash der Eingabe = eingefrorener Belegstand")
    }

    /// AK-R6c-1: Abschluss nur als Lease-Besitzer: Ein Worker, dessen Lease abgelaufen ist und dessen Job ein anderer übernahm, schreibt nichts.
    func testAKR6c_1_staleLeaseHolderWritesNothing() async throws {
        let s = try await setup()
        let id = try await finalDocument(s)
        let jobs = JobService(db), renderer = FakeRenderer()
        let staleClaim = try await jobs.claim(owner: "w1", leaseSeconds: 1, kinds: [InvoiceRenderJob.kind])
        let stale = try XCTUnwrap(staleClaim)
        try await waitFor("Lease von w1 abgelaufen") { try await value("SELECT (lease_until < now()) AS v FROM jobs WHERE id = '\(stale.id)'", as: Bool.self) }
        let currentClaim = try await jobs.claim(owner: "w2", leaseSeconds: 30, kinds: [InvoiceRenderJob.kind])
        let current = try XCTUnwrap(currentClaim)
        XCTAssertEqual(current.id, stale.id); XCTAssertEqual(current.attempts, 2)
        let handler = InvoiceRenderJob.handler(renderer: renderer, storeFactory: Self.store)
        do { try await handler(stale, db); XCTFail("abgelaufene Lease darf nichts schreiben") } catch { XCTAssertTrue(error is CancellationError, "\(error)") }
        try await aEq(try await count("invoice_render_states"), 0)
        try await aEq(try await count("files"), 0)
        try await handler(current, db)
        let rows = try await states(id)
        XCTAssertEqual(rows.count, 1)
    }

    /// AK-R6c-1: Ein Auftrag mit unlesbarer Nutzlast oder unbekanntem Beleg geht ohne Wiederholung in die Quarantäne (kein Endlosversuch).
    func testAKR6c_1_invalidPayloadOrUnknownDocumentIsPermanent() async throws {
        let s = try await setup()
        let draftID = try await draft(s)
        let tenant = s.w.tenantA
        let bad = try await JobService(db).enqueue(kind: InvoiceRenderJob.kind, payload: "{}")
        let unknown = try await JobService(db).enqueue(kind: InvoiceRenderJob.kind, payload: #"{"tenant_id":"\#(tenant)","document_id":"\#(UUID().uuidString)"}"#)
        let notFinal = try await JobService(db).enqueue(kind: InvoiceRenderJob.kind, payload: #"{"tenant_id":"\#(tenant)","document_id":"\#(draftID)"}"#)
        let renderer = FakeRenderer()
        try await withWorkers([makeWorker(app1, renderer)]) { try await count("jobs", where: "kind = 'invoice.render' AND state = 'failed_permanent'") == 3 }
        for job in [bad, unknown, notFinal] { try await aEq(try await value("SELECT attempts::int AS v FROM jobs WHERE id = '\(job)'", as: Int.self), 1) }
        XCTAssertEqual(renderer.callCount, 0)
        try await aEq(try await count("invoice_render_states"), 0)
    }

    // MARK: AK-R6c-2

    /// AK-R6c-2: Scheitert das Finalisieren nach dem Einreihen (hier: Audit-Eintrag, in der Datenbank erzwungen), bleibt weder ein Job noch ein Beleg-Zustand,
    /// der Beleg bleibt Entwurf und es wird keine Nummer verbraucht. Kontrolle: danach klappt dasselbe Finalisieren und legt genau einen Job an.
    func testAKR6c_2_rollbackDuringFinalizeLeavesNoJob() async throws {
        let s = try await setup()
        let id = try await draft(s)
        try await db.raw(SQLQueryString("""
            CREATE FUNCTION test_fail_finalize_audit() RETURNS trigger LANGUAGE plpgsql AS $$
            BEGIN IF NEW.action = 'invoice.document.finalized' THEN RAISE EXCEPTION 'synthetic failure after enqueue'; END IF; RETURN NEW; END $$
            """)).run()
        try await db.raw("CREATE TRIGGER test_fail_finalize_audit BEFORE INSERT ON audit_log FOR EACH ROW EXECUTE FUNCTION test_fail_finalize_audit()").run()
        addTeardownBlock { [db] in
            try? await db!.raw("DROP TRIGGER IF EXISTS test_fail_finalize_audit ON audit_log").run()
            try? await db!.raw("DROP FUNCTION IF EXISTS test_fail_finalize_audit()").run()
        }
        let failed = try await finalize(s, id)
        XCTAssertEqual(failed.status, .internalServerError, "\(failed.json)")
        try await aEq(try await count("jobs", where: "kind = 'invoice.render'"), 0, "kein Job nach Rollback")
        try await aEq(try await count("invoice_render_jobs"), 0)
        try await aEq(try await count("invoice_render_states"), 0)
        try await aEq(try await value("SELECT status AS v FROM invoice_documents WHERE id = '\(id)'", as: String.self), "draft")
        try await aEq(try await count("counters"), 0, "Nummernzähler zurückgerollt")

        try await db.raw("DROP TRIGGER test_fail_finalize_audit ON audit_log").run()
        let ok = try await finalize(s, id)
        XCTAssertEqual(ok.status, .ok, "\(ok.json)")
        XCTAssertEqual(ok.json["number"] as? String, "RE-0001", "die Nummer wurde vom gescheiterten Versuch nicht verbraucht")
        try await aEq(try await count("jobs", where: "kind = 'invoice.render' AND state = 'queued'"), 1)
        try await aEq(try await count("invoice_render_jobs", where: "document_id = '\(id)'"), 1)
        let payload = try await value("SELECT payload AS v FROM jobs WHERE kind = 'invoice.render'", as: String.self)
        XCTAssertTrue(payload.localizedCaseInsensitiveContains(id), payload); XCTAssertTrue(payload.localizedCaseInsensitiveContains(s.w.tenantA), payload)
        XCTAssertFalse(payload.localizedCaseInsensitiveContains("Muster GmbH"), "keine Belegdaten im Job")
    }

    /// AK-R6c-2: Wiederholte Anfragen (zweites Finalisieren, Wiederholung mit Idempotency-Key über die zweite Instanz) legen keinen zweiten Job an.
    func testAKR6c_2_repeatedFinalizeCreatesOneJobOnly() async throws {
        let s = try await setup()
        let id = try await draft(s)
        let key = ["Idempotency-Key": "finalize-" + UUID().uuidString]
        let first = try await finalize(s, id, headers: key)
        XCTAssertEqual(first.status, .ok, "\(first.json)")
        let replay = try await finalize(s, id, via: app2, headers: key)
        XCTAssertEqual(replay.status, .ok, "\(replay.json)")
        let again = try await finalize(s, id, via: app2)
        XCTAssertEqual(again.status, .conflict)
        try await aEq(try await count("jobs", where: "kind = 'invoice.render'"), 1)
    }

    // MARK: AK-R6c-3

    /// AK-R6c-3: Ein fertiges PDF wird nie neu erzeugt oder geändert: weder durch einen weiteren Job (auch mit neuer Layout-/Rendererversion), noch durch
    /// `POST render`, noch per SQL (Trigger); der Download liefert dieselben Bytes.
    func testAKR6c_3_finishedPDFIsNeverRenderedOrChangedAgain() async throws {
        let s = try await setup()
        let id = try await finalDocument(s)
        let renderer = FakeRenderer()
        try await withWorkers([makeWorker(app1, renderer)]) { try await jobsDone() == 1 }
        let before = try await states(id)
        XCTAssertEqual(before.count, 1)
        let first = try await pdf(s, id)
        XCTAssertEqual(first.status, .ok)
        XCTAssertEqual(renderer.callCount, 1)

        // weiterer Job für denselben Beleg, andere Worker-Instanz mit neuer Version: keine Neuerzeugung
        _ = try await InvoiceRenderJob.enqueue(document: UUID(uuidString: id)!, tenant: UUID(uuidString: s.w.tenantA)!, on: db)
        let newer = FakeRenderer(layoutVersion: 2, version: "fake 2.0", variant: "v2")
        try await withWorkers([makeWorker(app2, newer)]) { try await jobsDone() == 2 }
        XCTAssertEqual(newer.callCount, 0, "fertiges PDF wird nicht erneut gerendert")
        XCTAssertEqual(renderer.callCount, 1)
        let afterJob = try await states(id)
        XCTAssertEqual(afterJob, before, "Zustandszeile unverändert (Id, Datei, Prüfsumme, Zeitpunkt, Layoutversion, Rendererversion)")

        // POST render: meldet „fertig“, legt keinen Job und keine Zeile an
        let again = try await renderRequest(s, id, via: app2)
        XCTAssertEqual(again.status, .ok, "\(again.json)")
        XCTAssertEqual(again.json["status"] as? String, "ready")
        try await aEq(try await count("jobs", where: "kind = 'invoice.render'"), 2)
        try await aEq(try await count("invoice_render_states"), 1)

        // per SQL nicht änderbar und nicht löschbar
        for statement in ["UPDATE invoice_render_states SET pdf_sha256 = repeat('a', 64) WHERE document_id = '\(id)'", "UPDATE invoice_render_states SET layout_version = 9",
                          "DELETE FROM invoice_render_states WHERE document_id = '\(id)'", "DELETE FROM invoice_render_states"] {
            do { try await db.raw(SQLQueryString(statement)).run(); XCTFail("Zustandszeile änderbar: \(statement)") } catch {}
        }
        let awaited1 = try await states(id)
        XCTAssertEqual(awaited1, before)

        // Download: gleiche Bytes, Prüfsumme als ETag, Wiederholung auf der anderen Instanz
        let second = try await pdf(s, id, via: app2)
        XCTAssertEqual(second.body, first.body)
        XCTAssertEqual(second.headers.first(name: .eTag), "\"\(before[0].pdfSHA)\"")
        XCTAssertEqual(sha(second.body), before[0].pdfSHA)
    }

    /// AK-R6c-3: Scheitert das Rendern, gibt es nie ein halbes Ergebnis; erst `POST render` stößt eine neue Erzeugung an, genau einmal, und fertige Belege bleiben tabu.
    func testAKR6c_3_failedRenderThenRetryCreatesExactlyOneResult() async throws {
        let s = try await setup()
        let id = try await finalDocument(s)
        let renderer = FakeRenderer(failFirst: 1)
        try await withWorkers([makeWorker(app1, renderer)]) { try await count("jobs", where: "kind = 'invoice.render' AND state = 'failed_permanent'") == 1 }
        try await aEq(try await count("invoice_render_states"), 0)
        try await aEq(try await count("files"), 0)
        try await aEq(try await value("SELECT last_error AS v FROM jobs WHERE kind = 'invoice.render'", as: String.self), "render_failed", "nur ein Code, kein Belegtext")
        let failed = try await pdf(s, id)
        XCTAssertEqual(failed.status, .conflict); XCTAssertEqual(failed.problemCode, "render_failed")
        XCTAssertFalse(String(decoding: failed.body, as: UTF8.self).contains("geheimer Belegtext"))

        let retry = try await renderRequest(s, id)
        XCTAssertEqual(retry.status, .accepted, "\(retry.json)"); XCTAssertEqual(retry.json["status"] as? String, "pending")
        let twice = try await renderRequest(s, id, via: app2)
        XCTAssertEqual(twice.status, .accepted)
        try await aEq(try await count("jobs", where: "kind = 'invoice.render' AND state = 'queued'"), 1, "zweiter Aufruf legt keinen zweiten Job an")
        let pending = try await pdf(s, id)
        XCTAssertEqual(pending.status, .conflict); XCTAssertEqual(pending.problemCode, "render_pending")
        XCTAssertNotNil(pending.headers.first(name: "Retry-After"))

        try await withWorkers([makeWorker(app2, renderer)]) { let n = try await states(id).count; let d = try await jobsDone(); return n == 1 && d == 1 }
        let done = try await pdf(s, id)
        XCTAssertEqual(done.status, .ok)
        XCTAssertTrue(String(decoding: done.body, as: UTF8.self).hasPrefix("%PDF-"))
        try await aEq(try await count("invoice_render_states"), 1)
        let ready = try await renderRequest(s, id)
        XCTAssertEqual(ready.status, .ok); XCTAssertEqual(ready.json["status"] as? String, "ready")
        try await aEq(try await count("jobs", where: "kind = 'invoice.render'"), 2)
    }

    /// Vor R6c finalisierte Belege haben keinen Job: der Download meldet das mit eigenem Code, `POST render` reiht den Job einmalig ein.
    func testAKR6c_3_documentFinalizedBeforeR6cCanBeRendered() async throws {
        let s = try await setup()
        let id = try await finalDocument(s)
        try await db.raw("DELETE FROM invoice_render_jobs").run()
        try await db.raw("DELETE FROM jobs").run()
        let none = try await pdf(s, id)
        XCTAssertEqual(none.status, .conflict); XCTAssertEqual(none.problemCode, "render_not_started")
        let start = try await renderRequest(s, id)
        XCTAssertEqual(start.status, .accepted, "\(start.json)")
        _ = try await renderRequest(s, id, via: app2)
        try await aEq(try await count("jobs", where: "kind = 'invoice.render'"), 1)
        try await withWorkers([makeWorker(app1, FakeRenderer())]) { let n = try await states(id).count; let d = try await jobsDone(); return n == 1 && d == 1 }
        try await aEq((try await pdf(s, id)).status, .ok)
    }

    // MARK: Migration

    /// Migration `invoice_030_render`: Tabellen und Funktionen zurückbaubar und wieder anwendbar, auch bei deaktiviertem Modul vorhanden.
    func testAKR6c_migrationRevertAndReapply() async throws {
        _ = try await world(enable: false)
        let tables = ["invoice_render_states", "invoice_render_jobs"]
        for tbl in tables { try await aEq(try await count("information_schema.tables", where: "table_name = '\(tbl)'"), 1, tbl) }
        try await aEq(try await count("_fluent_migrations", where: "name = 'invoice_030_render'"), 1)
        let m = try XCTUnwrap(InvoiceModule().migrations.first { $0.name == "invoice_030_render" } as? any AsyncMigration), database = app1.db(.psql)
        try await m.revert(on: database)
        for tbl in tables { try await aEq(try await count("information_schema.tables", where: "table_name = '\(tbl)'"), 0, tbl) }
        try await aEq(try await count("pg_proc", where: "proname LIKE 'invoice\\_render\\_%'"), 0)
        try await m.prepare(on: database)
        for tbl in tables { try await aEq(try await count("information_schema.tables", where: "table_name = '\(tbl)'"), 1, tbl) }
    }
}

// MARK: AK-R6c-4 Mandanten und Rechte

final class InvoiceRenderAccessTests: InvoiceRenderTestBase {

    /// AK-R6c-4: Fremder Mandant 404 auf beiden Routen (Pfad des anderen Mandanten, fremde Beleg-Id im eigenen Mandanten, unbekannte und ungültige Id).
    func testAKR6c_4_foreignTenantIs404() async throws {
        let s = try await setup()
        let id = try await finalDocument(s)
        try await withWorkers([makeWorker(app1, FakeRenderer())]) { try await jobsDone() == 1 }
        let tenantB = (try await call(app1, .POST, "api/v1/tenants", json: ["name": "Zweiter Mandant"], token: s.w.alice.token)).json["id"] as! String
        let carol = try await addUser("owner", handle: "carol", tenant: tenantB, by: s.w.alice)
        try await setModule(tenantB, true, by: carol)
        let b = "api/v1/tenants/\(tenantB)/invoice/documents"
        for (method, path) in [(HTTPMethod.GET, "/\(id)/pdf"), (.POST, "/\(id)/render")] {
            let foreignPath = try await raw(app2, method, s.docs + path, token: carol.token)            // Carol im Mandanten A
            XCTAssertEqual(foreignPath.status, .notFound, "\(method) A-Pfad")
            let foreignID = try await raw(app1, method, b + path, token: carol.token)                   // Beleg von A im eigenen Mandanten B
            XCTAssertEqual(foreignID.status, .notFound, "\(method) fremde Id")
            let unknown = try await raw(app1, method, s.docs + "/\(UUID().uuidString)" + (method == .GET ? "/pdf" : "/render"), token: s.w.alice.token)
            XCTAssertEqual(unknown.status, .notFound, "\(method) unbekannt")
            let invalid = try await raw(app1, method, s.docs + "/kein-uuid" + (method == .GET ? "/pdf" : "/render"), token: s.w.alice.token)
            XCTAssertEqual(invalid.status, .notFound, "\(method) ungültig")
        }
        try await aEq(try await count("jobs", where: "kind = 'invoice.render'"), 1, "keine Nebenwirkung der fremden Aufrufe")
        // Datenbank: ein Zustand eines Mandanten kann nicht auf die Datei oder den Beleg eines anderen zeigen
        let otherFile = try await value("SELECT id::text AS v FROM files", as: String.self)
        do {
            try await db.raw(SQLQueryString("""
                INSERT INTO invoice_render_states (tenant_id, document_id, layout_key, layout_version, input_hash, pdf_sha256, file_id, renderer_version)
                VALUES ('\(tenantB)', '\(id)', 'standard', 1, 'x', repeat('b', 64), '\(otherFile)', 'x')
                """)).run()
            XCTFail("Zustand über die Mandantengrenze")
        } catch {}
    }

    /// AK-R6c-4: Rechte: Lesen (PDF) owner/accountant/member/tax_advisor, Anstoßen (`POST render`) nur owner/accountant; Verbot = 403 ohne Nebenwirkung; anonym 401.
    func testAKR6c_4_permissionMatrix() async throws {
        let s = try await setup()
        let id = try await finalDocument(s)
        try await withWorkers([makeWorker(app1, FakeRenderer())]) { try await jobsDone() == 1 }
        var sessions: [Role: TestSession] = [.owner: s.w.alice]
        for role in Role.allCases where role != .owner { sessions[role] = try await addUser(role.rawValue, handle: "u_" + role.rawValue, tenant: s.w.tenantA, by: s.w.alice) }
        let declared = InvoiceModule().permissions
        func allowed(_ role: Role, _ p: String) -> Bool { declared.contains { $0.name == p && (role == .owner || $0.roles.contains(role)) } }
        let jobsBefore = try await count("jobs")
        for role in Role.allCases {
            let token = sessions[role]!.token
            XCTAssertEqual(allowed(role, "invoice.document.read"), [.owner, .accountant, .member, .taxAdvisor].contains(role), role.rawValue)
            let read = try await pdf(s, id, token: token, via: app2)
            XCTAssertEqual(read.status, allowed(role, "invoice.document.read") ? .ok : .forbidden, "pdf \(role.rawValue)")
            if !allowed(role, "invoice.document.read") { XCTAssertEqual(read.problemCode, "forbidden") }
            let trigger = try await renderRequest(s, id, token: token)
            XCTAssertEqual(trigger.status, allowed(role, "invoice.document.finalize") ? .ok : .forbidden, "render \(role.rawValue)")
        }
        XCTAssertEqual(allowed(.accountant, "invoice.document.finalize"), true); XCTAssertEqual(allowed(.member, "invoice.document.finalize"), false)
        try await aEq(try await count("jobs"), jobsBefore, "verbotene und erlaubte Aufrufe legen bei fertigem PDF keinen Job an")
        let anonymousGet = try await raw(app1, .GET, s.docs + "/\(id)/pdf"), anonymousPost = try await raw(app1, .POST, s.docs + "/\(id)/render")
        XCTAssertEqual(anonymousGet.status, .unauthorized); XCTAssertEqual(anonymousPost.status, .unauthorized)
    }

    /// AK-R6c-4: Entwurf hat kein PDF (409 `document_not_final`, kein Job); ist das Modul aus, antworten beide Routen 404 `module_disabled`.
    func testAKR6c_4_draftAndDisabledModule() async throws {
        let s = try await setup()
        let id = try await draft(s)
        for (method, path) in [(HTTPMethod.GET, "/pdf"), (.POST, "/render")] {
            let r = try await raw(app1, method, s.docs + "/\(id)" + path, token: s.w.alice.token)
            XCTAssertEqual(r.status, .conflict, "\(method)"); XCTAssertEqual(r.problemCode, "document_not_final")
        }
        try await aEq(try await count("jobs", where: "kind = 'invoice.render'"), 0)
        let final = try await finalDocument(s)
        let pending = try await renderRequest(s, final)
        XCTAssertEqual(pending.status, .accepted); XCTAssertEqual(pending.json["status"] as? String, "pending")
        try await aEq(try await count("jobs", where: "kind = 'invoice.render'"), 1, "läuft schon: kein zweiter Job")
        try await setModule(s.w.tenantA, false, by: s.w.alice)
        for (method, path) in [(HTTPMethod.GET, "/pdf"), (.POST, "/render")] {
            let r = try await raw(app1, method, s.docs + "/\(final)" + path, token: s.w.alice.token)
            XCTAssertEqual(r.status, .notFound, "\(method)"); XCTAssertEqual(r.problemCode, "module_disabled")
        }
    }
}

// MARK: AK-R6c-5 keine Löschung referenzierter Dateien

final class InvoiceRenderFileSafetyTests: InvoiceRenderTestBase {
    override var testModules: [any HubModule] { [InvoiceModule(), DMSModule(objectStore: ObjectStoreConfig(kind: .db), defaultRetentionYears: 10)] }

    private func enableDMS(_ w: World) async throws {
        let r = try await call(app1, .PUT, "api/v1/tenants/\(w.tenantA)/modules/dms", json: ["enabled": true], token: w.alice.token)
        XCTAssertEqual(r.status, .ok, "\(r.json)")
    }

    /// Lädt dieselben Bytes als DMS-Dokument mit altem Belegdatum hoch (Aufbewahrungsfrist sicher abgelaufen) und legt es in den Papierkorb.
    private func trashedOldDMSDocument(_ w: World, bytes: Data) async throws -> String {
        let box = UnsafeSendableBox<RenderResp?>(nil)
        var headers = HTTPHeaders()
        headers.bearerAuthorization = BearerAuthorization(token: w.alice.token)
        headers.replaceOrAdd(name: "Content-Type", value: "application/octet-stream"); headers.replaceOrAdd(name: "Idempotency-Key", value: UUID().uuidString)
        try await app1.test(.POST, "api/v1/tenants/\(w.tenantA)/dms/uploads", headers: headers, body: ByteBuffer(data: bytes)) { res async throws in
            box.value = RenderResp(status: res.status, headers: res.headers, body: Data(buffer: res.body))
        }
        XCTAssertEqual(box.value?.status, .created, "\(box.value?.json ?? [:])")
        let doc = try XCTUnwrap(box.value?.json["id"] as? String)
        try await db.raw(SQLQueryString("UPDATE dms_documents SET doc_date = '2001-02-03' WHERE id = '\(doc)'")).run()
        let trash = try await call(app1, .POST, "api/v1/tenants/\(w.tenantA)/dms/documents/\(doc)/trash", json: ["reason": "Test"], token: w.alice.token)
        XCTAssertEqual(trash.status, .ok, "\(trash.json)")
        return doc
    }

    /// AK-R6c-5: Das DMS löscht ein Dokument endgültig, dessen Datei (gleiche Bytes) auch das Beleg-PDF ist: Dokument und DMS-Verweis verschwinden, die Datei
    /// (`files`-Zeile und Bytes) bleibt, das PDF ist weiter abrufbar.
    private func purgeScenario(pdfFirst: Bool) async throws {
        let s = try await setup()
        try await enableDMS(s.w)
        let id = try await finalDocument(s)
        let renderer = FakeRenderer()
        let tenant = UUID(uuidString: s.w.tenantA)!
        // Bytes des künftigen PDF: der Fake leitet sie aus der Belegnummer ab, also vorab dieselben Bytes bauen
        let number = try await value("SELECT number AS v FROM invoice_documents WHERE id = '\(id)'", as: String.self)
        let bytes = try await renderer.render(Data(#"{"number":"\#(number)"}"#.utf8))
        var dmsDoc: String? = nil
        if !pdfFirst { dmsDoc = try await trashedOldDMSDocument(s.w, bytes: bytes) }
        try await withWorkers([makeWorker(app1, FakeRenderer())]) { try await jobsDone() == 1 }
        if pdfFirst { dmsDoc = try await trashedOldDMSDocument(s.w, bytes: bytes) }
        let doc = try XCTUnwrap(dmsDoc)
        let key = try ObjectKey(tenantID: tenant, sha256: sha(bytes))
        let stateBefore = try await states(id)
        XCTAssertEqual(stateBefore.first?.pdfSHA, key.sha256, "gleiche Bytes im DMS und als Beleg-PDF (pdfFirst=\(pdfFirst))")
        let sharedFile = try await value("SELECT file_id::text AS v FROM dms_document_files WHERE document_id = '\(doc)' AND role = 'original'", as: String.self)
        XCTAssertEqual(sharedFile, stateBefore.first?.fileID, "eine files-Zeile je Mandant und Hash")

        let purge = try await call(app1, .POST, "api/v1/tenants/\(s.w.tenantA)/dms/documents/\(doc)/purge", token: s.w.alice.token)
        XCTAssertEqual(purge.status, .ok, "Löschen des DMS-Dokuments darf an der Beleg-Datei nicht scheitern: \(purge.json)")
        try await aEq(try await count("dms_documents", where: "id = '\(doc)'"), 0)
        try await aEq(try await count("files", where: "id = '\(sharedFile)'"), 1, "referenzierte Datei bleibt")
        let awaited2 = try await Self.store(db).exists(key)
        XCTAssertTrue(awaited2, "Bytes bleiben")
        let download = try await pdf(s, id)
        XCTAssertEqual(download.status, .ok); XCTAssertEqual(download.body, bytes)
        let awaited3 = try await states(id)
        XCTAssertEqual(awaited3, stateBefore)
    }

    func testAKR6c_5_dmsPurgeKeepsFileReferencedByInvoicePDF_pdfFirst() async throws { try await purgeScenario(pdfFirst: true) }
    func testAKR6c_5_dmsPurgeKeepsFileReferencedByInvoicePDF_dmsFirst() async throws { try await purgeScenario(pdfFirst: false) }

    /// AK-R6c-5: Während eine Transaktion die Datei unter der Blob-Sperre des Kerns anlegt (so macht es der Render-Job), wartet das Aufräumen des DMS und
    /// sieht danach die Zeile: Die Bytes bleiben.
    func testAKR6c_5_cleanupWaitsForTransactionRegisteringTheFile() async throws {
        let tenant = UUID(), store = try Self.store(db)
        let bytes = Data("%PDF-1.4\n% synthetic race\n".utf8)
        let stored = try await store.put(tenant: tenant, stream: ByteStream { c in c.yield(ByteBuffer(data: bytes)); c.finish() }, expectedSHA256: nil)
        let locked = UnsafeSendableBox(false)
        let writer = app2.db(.psql)
        let register = Task {
            try await writer.transaction { tx in
                let s = try sql(tx)
                try await FileRecordService.lockBlob(tenant: tenant, sha256: stored.key.sha256, on: s)
                locked.value = true
                try await Task.sleep(for: .milliseconds(700))
                _ = try await FileRecordService(s).register(stored, backend: .db, contentType: "application/pdf")
            }
        }
        try await waitFor("Sperre gehalten") { locked.value }
        let start = Date()
        await DMSUpload.discardIfUnreferenced(stored.key, store: store, db: app1.db(.psql), logger: Logger(label: "test"))
        XCTAssertGreaterThan(Date().timeIntervalSince(start), 0.3, "Aufräumen muss auf die Sperre warten")
        try await register.value
        let present = try await store.exists(stored.key)
        XCTAssertTrue(present)
    }

    /// Rolling Update: Instanzen vor R6c sperren je Datei nur mit dem Schlüssel `dms-blob:`; die DMS-Sperre muss ihn weiter nehmen, sonst laufen alte und neue
    /// Instanzen beim Aufräumen und Hochladen ungesperrt nebeneinander.
    func testAKR6c_5_dmsBlobLockStaysCompatibleWithOlderInstances() async throws {
        let tenant = UUID(), sha = String(repeating: "a", count: 64)
        let locked = UnsafeSendableBox(false)
        let old = app2.db(.psql)
        let holder = Task {
            try await old.transaction { tx in
                try await sql(tx).raw("SELECT pg_advisory_xact_lock(hashtextextended(\(bind: "dms-blob:\(tenant.uuidString):\(sha)"), 0))").run()
                locked.value = true
                try await Task.sleep(for: .milliseconds(700))
            }
        }
        try await waitFor("alte Sperre gehalten") { locked.value }
        let start = Date()
        try await app1.db(.psql).transaction { tx in try await DMSUpload.lockBlob(tenant: tenant, sha256: sha, on: try sql(tx)) }
        XCTAssertGreaterThan(Date().timeIntervalSince(start), 0.3, "neue Instanz muss auf die alte Sperre warten")
        try await holder.value
    }

    /// AK-R6c-5: Die Aufräumwege des DMS für unreferenzierte Bytes (`discardIfUnreferenced`, `removeBlobIfUnreferenced`) und das Löschen der `files`-Zeile selbst
    /// lassen eine vom Beleg-PDF referenzierte Datei unangetastet; der Beleg selbst ist nicht löschbar.
    func testAKR6c_5_cleanupPathsAndDatabaseKeepReferencedFile() async throws {
        let s = try await setup()
        let id = try await finalDocument(s)
        try await withWorkers([makeWorker(app1, FakeRenderer())]) { try await jobsDone() == 1 }
        let stateRows = try await states(id)
        let row = try XCTUnwrap(stateRows.first)
        let key = try ObjectKey(tenantID: UUID(uuidString: s.w.tenantA)!, sha256: row.pdfSHA)
        let store = try Self.store(db)
        let awaited4 = try await store.exists(key)
        XCTAssertTrue(awaited4)

        await DMSUpload.discardIfUnreferenced(key, config: ObjectStoreConfig(kind: .db), db: app1.db(.psql), logger: Logger(label: "test"))
        await DMSUpload.discardIfUnreferenced(key, store: store, db: app1.db(.psql), logger: Logger(label: "test"))
        let awaited5 = try await store.exists(key)
        XCTAssertTrue(awaited5, "Aufräumen nach fehlgeschlagenem Upload")
        let removed = try await DMSPurge.removeBlobIfUnreferenced(key, config: ObjectStoreConfig(kind: .db), db: app1.db(.psql))
        let afterPurgeCleanup = try await store.exists(key)
        XCTAssertFalse(removed); XCTAssertTrue(afterPurgeCleanup, "Aufräumen nach endgültigem Löschen")

        for statement in ["DELETE FROM files WHERE id = '\(row.fileID)'", "DELETE FROM files", "DELETE FROM invoice_documents WHERE id = '\(id)'",
                          "TRUNCATE invoice_render_states"] {
            do { try await db.raw(SQLQueryString(statement)).run(); XCTFail("löschbar: \(statement)") } catch {}
        }
        try await aEq(try await count("files", where: "id = '\(row.fileID)'"), 1)
        try await aEq(try await count("invoice_render_states", where: "document_id = '\(id)'"), 1)
        let awaited6 = try await store.exists(key)
        XCTAssertTrue(awaited6)
        let download = try await pdf(s, id)
        XCTAssertEqual(download.status, .ok); XCTAssertEqual(sha(download.body), row.pdfSHA)
        // Der Fremdschlüssel verbietet das Löschen ausdrücklich (kein CASCADE, kein SET NULL)
        let deleteRule = try await value("""
            SELECT string_agg(confdeltype::text, ',') AS v FROM pg_constraint WHERE conrelid = 'invoice_render_states'::regclass AND confrelid = 'files'::regclass
            """, as: String?.self) ?? ""
        XCTAssertEqual(deleteRule, "r", "RESTRICT: weder CASCADE (c) noch SET NULL (n) noch SET DEFAULT (d)")
    }
}

// MARK: AK-R6c-6 E2E mit echtem Worker-Prozess

/// AK-R6c-6: Beleg über die API anlegen und finalisieren, zwei echte `App worker`-Prozesse (echter Renderer: Typst, qpdf, Schriften) erzeugen das PDF, die API liefert es.
/// Ohne Werkzeuge (lokal außerhalb des Worker-Test-Images) wird übersprungen; in der CI nicht (`scripts/ci-backend.sh`).
final class InvoiceRenderWorkerE2ETests: InvoiceRenderTestBase {
    override var testModules: [any HubModule] { InstalledModules.all }

    private func startWorker(lease: Int = 30, kinds: String = InvoiceRenderJob.kind, environment: [String: String] = [:], output: Pipe? = nil) throws -> Process {
        guard let bin = WorkerProcessTests.appBinary else { throw XCTSkip("App-Executable nicht gefunden (neben dem Testbundle); Mehrprozess-Test übersprungen") }
        let p = Process()
        p.executableURL = bin
        p.arguments = ["worker", "--kinds", kinds, "--lease-seconds", String(lease), "--poll-ms", "200", "--retry-backoff-seconds", "0"]
        var env = ProcessInfo.processInfo.environment
        for (k, v) in HubTestDB.env { env[k] = v }
        // Werkzeugpfade wie im Render-Test (`LH_TEST_*`), im Worker-Test-Image gelten die Standardpfade
        for (test, real) in [("LH_TEST_TYPST", "RENDER_TYPST"), ("LH_TEST_QPDF", "RENDER_QPDF"), ("LH_TEST_FONT_DIR", "RENDER_FONT_DIR"), ("LH_TEST_RENDER_TMP", "RENDER_TMPDIR")] {
            if let v = env[test] { env[real] = v }
        }
        for (k, v) in environment { env[k] = v }
        p.environment = env
        p.standardOutput = output ?? FileHandle.nullDevice as Any; p.standardError = output ?? FileHandle.nullDevice as Any
        try p.run()
        return p
    }

    /// Vorabprüfung: Fehlt Typst oder eine Schrift, beendet sich der Worker mit Status 1 und klarer Meldung (sonst liefen alle Aufträge in die Quarantäne).
    /// Braucht keine Render-Werkzeuge.
    func testAKR6c_6_workerRefusesToStartWithoutRenderTools() async throws {
        for (env, expected) in [(["RENDER_TYPST": "/nonexistent/typst", "RENDER_FONT_DIR": NSTemporaryDirectory()], "Schrift fehlt"),
                                (["RENDER_TYPST": "/nonexistent/typst"], "Werkzeug fehlt oder startet nicht")] as [([String: String], String)] {
            let fontDir = FileManager.default.temporaryDirectory.appendingPathComponent("lh-fonts-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: fontDir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: fontDir) }
            var environment = env
            if expected != "Schrift fehlt" {   // Schriften vorhanden (leere Dateien genügen der Vorabprüfung), nur Typst fehlt
                for f in InvoiceRenderer.requiredFonts { FileManager.default.createFile(atPath: fontDir.appendingPathComponent(f).path, contents: Data()) }
                environment["RENDER_FONT_DIR"] = fontDir.path
            }
            let pipe = Pipe()
            let p = try startWorker(environment: environment, output: pipe)
            defer { if p.isRunning { kill(p.processIdentifier, SIGKILL) } }
            let end = Date().addingTimeInterval(60)
            while p.isRunning, Date() < end { try await Task.sleep(for: .milliseconds(20)) }
            XCTAssertFalse(p.isRunning, "Worker läuft trotz fehlender Werkzeuge")
            XCTAssertEqual(p.terminationStatus, 1, expected)
            try? pipe.fileHandleForWriting.close()
            let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            XCTAssertTrue(text.contains(expected), "\(expected): \(text.suffix(400))")
        }
    }

    func testAKR6c_6_e2eRealWorkerRendersFinalizedDocumentAndApiDeliversPDF() async throws {
        try await RenderFixtures.requireTools(qpdf: true)
        let s = try await setup()
        let ids = [try await finalDocument(s), try await finalDocument(s), try await finalDocument(s)]
        let early = try await pdf(s, ids[0])
        XCTAssertEqual(early.status, .conflict); XCTAssertEqual(early.problemCode, "render_pending", "vor dem Worker ist das PDF noch in Arbeit")
        let a = try startWorker(), b = try startWorker()
        defer { for p in [a, b] where p.isRunning { kill(p.processIdentifier, SIGKILL) } }
        try await waitFor("drei PDF erzeugt", timeout: 120) { let n = try await count("invoice_render_states"); let d = try await jobsDone(); return n == 3 && d == 3 }
        XCTAssertTrue(a.isRunning && b.isRunning)
        try await aEq(try await value("SELECT count(DISTINCT document_id)::bigint AS v FROM invoice_render_states", as: Int64.self), 3)
        try await aEq(try await count("files", where: "content_type = 'application/pdf'"), 3)
        for id in ids {
            let number = try await value("SELECT number AS v FROM invoice_documents WHERE id = '\(id)'", as: String.self)
            let r = try await pdf(s, id, via: app2)
            XCTAssertEqual(r.status, .ok)
            XCTAssertEqual(r.headers.first(name: .contentType), "application/pdf")
            XCTAssertTrue(String(decoding: r.body.prefix(5), as: UTF8.self) == "%PDF-")
            let stateRows = try await states(id)
            let state = try XCTUnwrap(stateRows.first)
            XCTAssertEqual(state.pdfSHA, sha(r.body)); XCTAssertEqual(state.layoutKey, "standard"); XCTAssertEqual(state.layoutVersion, InvoiceStandardLayout.version)
            XCTAssertTrue(state.rendererVersion.contains("typst"), state.rendererVersion)
            let text = try await RenderFixtures.extract(r.body)
            XCTAssertTrue(text.contains("Rechnung \(number)"), text); XCTAssertTrue(text.contains("Muster GmbH")); XCTAssertTrue(text.contains("Kunde AG")); XCTAssertTrue(text.contains("Beratung"))
            let again = try await renderRequest(s, id)
            XCTAssertEqual(again.status, .ok); XCTAssertEqual(again.json["status"] as? String, "ready")
        }
        try await aEq(try await count("jobs", where: "kind = 'invoice.render'"), 3, "kein weiterer Job, kein zweites PDF")
    }
}
