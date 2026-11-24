import XCTVapor
import Fluent
import SQLKit
@testable import HubKit

/// WP-H14, Codex-Befund 8: Quarantaene einer Absturzschleife im Kern laesst den Eingangsvorgang auf `ocr_queued`; das Wiederholen muss trotzdem wirken.
final class H14OCRQuarantineTests: DMSOCRTestBase {
    /// Job `maxAttempts`-mal mit abgelaufener Lease abholen (Absturzschleife), danach greift die Quarantaene des Kerns.
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

    /// AK-H14-1: Nach der Absturzschleife zeigt der Status `failed` (Code `lease_expired`) und der manuelle Retry reiht neu ein; der Worker beendet den Vorgang.
    func testAKH14_1_crashLoopQuarantineIsRetryable() async throws {
        let w = try await world()
        let doc = try await newDoc(w.alice, w.tenantA, seed: "h14-crash")["id"] as! String
        try await aEq(try await itemState(doc), "ocr_queued")
        try await crashLoop()
        try await aEq(try await count("jobs", where: "kind = 'dms.ocr' AND state = 'failed_permanent' AND last_error = 'lease_expired'"), 1)

        let st = try await processing(w, doc)
        XCTAssertEqual(st.json["phase"] as? String, "failed", "\(st.json)")
        XCTAssertEqual(st.json["error_code"] as? String, "lease_expired")

        let url = base(w.tenantA) + "/documents/\(doc)/processing/retry"
        let r = try await raw(app2, .POST, url, token: w.alice.token)
        XCTAssertEqual(r.status, .ok, "\(r.json)")
        XCTAssertEqual(r.json["phase"] as? String, "queued")
        try await aEq(try await count("jobs", where: "kind = 'dms.ocr'"), 2)
        try await aEq(try await count("jobs", where: "kind = 'dms.ocr' AND state = 'queued'"), 1)

        let engine = FakeOCREngine()
        let worker = makeWorker(engine)
        let run = Task { await worker.run() }
        try await waitFor("done after retry") { try await itemState(doc) == "done" }
        worker.requestShutdown(); await run.value
        XCTAssertEqual(engine.calls, 1)

        // zweiter Retry: nichts mehr zu wiederholen
        let again = try await raw(app1, .POST, url, token: w.alice.token)
        XCTAssertEqual(again.status, .conflict); XCTAssertEqual(again.problemCode, "ingest_not_failed")
    }

    /// AK-H14-2: Zwei gleichzeitige Retries nach der Quarantaene: genau einer wirkt, genau ein neuer Job.
    func testAKH14_2_parallelRetriesAfterCrashLoop() async throws {
        let w = try await world()
        let doc = try await newDoc(w.alice, w.tenantA, seed: "h14-par")["id"] as! String
        try await crashLoop()
        let url = base(w.tenantA) + "/documents/\(doc)/processing/retry"
        async let a = raw(app1, .POST, url, token: w.alice.token)
        async let b = raw(app2, .POST, url, token: w.alice.token)
        let statuses = try await [a.status, b.status].sorted { $0.code < $1.code }
        XCTAssertEqual(statuses, [.ok, .conflict])
        try await aEq(try await count("jobs", where: "kind = 'dms.ocr'"), 2)
    }

    /// AK-H14-3: Ein regulaer wartender oder laufender Job ist kein Fehler: Retry bleibt 409.
    func testAKH14_3_queuedItemIsNotRetryable() async throws {
        let w = try await world()
        let doc = try await newDoc(w.alice, w.tenantA, seed: "h14-queued")["id"] as! String
        let r = try await raw(app1, .POST, base(w.tenantA) + "/documents/\(doc)/processing/retry", token: w.alice.token)
        XCTAssertEqual(r.status, .conflict); XCTAssertEqual(r.problemCode, "ingest_not_failed")
        let st = try await processing(w, doc)
        XCTAssertEqual(st.json["phase"] as? String, "queued")
    }
}

/// WP-H14, Codex-Befund 4: generische Link-Route und `dms.document`.
final class H14LinkGuardTests: DMSTestBase {
    func links(_ w: World) -> String { "api/v1/tenants/\(w.tenantA)/links" }

    func contact(_ w: World) async throws -> String {
        let r = try await call(app1, .POST, "api/v1/tenants/\(w.tenantA)/contacts", json: ["kind": "organization", "display_name": "H14 Fiktiv GmbH"], token: w.alice.token)
        XCTAssertEqual(r.status, .created, "\(r.json)")
        return r.json["id"] as! String
    }

    func body(_ doc: String, _ contact: String) -> [String: Any] {
        ["from_type": "dms.document", "from_id": doc, "to_type": "contact", "to_id": contact, "kind": "correspondent"]
    }

    func rev(_ doc: String) async throws -> Int64 { try await scalar("SELECT rev::bigint AS v FROM dms_documents WHERE id = '\(doc)'", as: Int64.self) }

    /// AK-H14-4: Modul aus: 4xx, kein Link.
    func testAKH14_4_moduleOffRejectsDocumentLink() async throws {
        let w = try await world()
        let doc = try await newDoc(w.alice, w.tenantA, seed: "h14-off")["id"] as! String
        let c = try await contact(w)
        try await setModule(w.tenantA, false, by: w.alice)
        let r = try await call(app1, .POST, links(w), json: body(doc, c), token: w.alice.token)
        XCTAssertEqual(r.status, .notFound, "\(r.json)")
        try await aEq(try await count("links"), 0)
    }

    /// AK-H14-5: Papierkorb: 409; unbekanntes Dokument: 404; kein Link, `rev` unveraendert.
    func testAKH14_5_trashedAndUnknownDocument() async throws {
        let w = try await world()
        let doc = try await newDoc(w.alice, w.tenantA, seed: "h14-trash")["id"] as! String
        let c = try await contact(w)
        let t = try await call(app1, .POST, base(w.tenantA) + "/documents/\(doc)/trash", json: ["reason": "Test"], token: w.alice.token)
        XCTAssertEqual(t.status, .ok, "\(t.json)")
        let before = try await rev(doc)
        let r = try await call(app1, .POST, links(w), json: body(doc, c), token: w.alice.token)
        XCTAssertEqual(r.status, .conflict, "\(r.json)")
        XCTAssertEqual(r.json["code"] as? String ?? r.json["error"] as? String, "document_trashed", "\(r.json)")
        let unknown = try await call(app1, .POST, links(w), json: body(UUID().uuidString, c), token: w.alice.token)
        XCTAssertEqual(unknown.status, .notFound)
        try await aEq(try await count("links"), 0)
        try await aEq(try await rev(doc), before)
    }

    /// AK-H14-6: Erfolg erhoeht `rev` (Entfernen und Rueckgaengig ebenfalls), Papierkorb sperrt auch diese; nicht unterstuetzte dms.*-Typen: 422.
    func testAKH14_6_successBumpsRevAndRemoveRestoreAreGuarded() async throws {
        let w = try await world()
        let doc = try await newDoc(w.alice, w.tenantA, seed: "h14-ok")["id"] as! String
        let c = try await contact(w)
        let r0 = try await rev(doc)
        let r = try await call(app2, .POST, links(w), json: body(doc, c), token: w.alice.token)
        XCTAssertEqual(r.status, .created, "\(r.json)")
        let r1 = try await rev(doc)
        XCTAssertEqual(r1, r0 + 1)
        let linkID = r.json["id"] as! String
        let rm = try await call(app1, .DELETE, links(w) + "/\(linkID)", token: w.alice.token)
        XCTAssertEqual(rm.status, .noContent)
        try await aEq(try await rev(doc), r1 + 1)
        // Papierkorb: Rueckgaengig gesperrt
        _ = try await call(app1, .POST, base(w.tenantA) + "/documents/\(doc)/trash", json: ["reason": "Test"], token: w.alice.token)
        let rs = try await call(app1, .POST, links(w) + "/\(linkID)/restore", token: w.alice.token)
        XCTAssertEqual(rs.status, .conflict, "\(rs.json)")
        // fremder dms.*-Typ
        var bad = body(doc, c); bad["from_type"] = "dms.secret"
        let b = try await call(app1, .POST, links(w), json: bad, token: w.alice.token)
        XCTAssertEqual(b.status, .unprocessableEntity)
    }

    /// AK-H14-7: DMS-interne Aufrufer (Korrespondent ueber PATCH) bleiben erlaubt und erhoehen `rev` genau einmal.
    func testAKH14_7_internalCallersUnchanged() async throws {
        let w = try await world()
        let doc = try await newDoc(w.alice, w.tenantA, seed: "h14-int")["id"] as! String
        let c = try await contact(w)
        let r0 = try await rev(doc)
        let p = try await call(app1, .PATCH, base(w.tenantA) + "/documents/\(doc)", json: ["correspondent_id": c], token: w.alice.token, headers: ["If-Match": "\(r0)"])
        XCTAssertEqual(p.status, .ok, "\(p.json)")
        try await aEq(try await rev(doc), r0 + 1)
        try await aEq(try await count("links", where: "removed_at IS NULL"), 1)
    }

    /// AK-H14-8: Leseroute. Bei abgeschaltetem DMS verraet `GET /links` keine Dokument-Verknuepfungen (weder ueber das Dokument noch ueber den Kontakt);
    /// mit aktivem DMS und Leserecht bleibt alles sichtbar.
    func testAKH14_8_listHidesDocumentLinksWhenModuleOff() async throws {
        let w = try await world()
        let doc = try await newDoc(w.alice, w.tenantA, seed: "h14-read")["id"] as! String
        let c = try await contact(w)
        let created = try await call(app1, .POST, links(w), json: body(doc, c), token: w.alice.token)
        XCTAssertEqual(created.status, .created, "\(created.json)")
        let byDocument = links(w) + "?type=dms.document&id=\(doc)", byContact = links(w) + "?type=contact&id=\(c)"

        // Modul an: beide Sichten zeigen den Link.
        try await aEq(items(try await call(app2, .GET, byDocument, token: w.alice.token)).count, 1)
        try await aEq(items(try await call(app2, .GET, byContact, token: w.alice.token)).count, 1)

        // Modul aus: Dokumentsicht 404 `module_disabled`, Kontaktsicht ohne den Dokument-Link (auch mit include_removed).
        try await setModule(w.tenantA, false, by: w.alice)
        let off = try await call(app1, .GET, byDocument, token: w.alice.token)
        XCTAssertEqual(off.status, .notFound, "\(off.json)")
        let offContact = try await call(app2, .GET, byContact + "&include_removed=true", token: w.alice.token)
        XCTAssertEqual(offContact.status, .ok, "\(offContact.json)")
        try await aEq(items(offContact).count, 0)

        // Wieder an: sichtbar, der Link selbst blieb unveraendert.
        try await setModule(w.tenantA, true, by: w.alice)
        try await aEq(items(try await call(app1, .GET, byDocument, token: w.alice.token)).count, 1)
        try await aEq(try await count("links", where: "removed_at IS NULL"), 1)
    }

    /// AK-H14-9: Kontakt-zu-Kontakt-Verknuepfungen bleiben bei abgeschaltetem DMS unberuehrt sichtbar (der Filter trifft nur `dms.*`-Seiten).
    func testAKH14_9_nonDocumentLinksStayVisibleWhenModuleOff() async throws {
        let w = try await world()
        let a = try await contact(w), b = try await contact(w)
        let r = try await call(app1, .POST, links(w), json: ["from_type": "contact", "from_id": a, "to_type": "contact", "to_id": b, "kind": "related"], token: w.alice.token)
        XCTAssertEqual(r.status, .created, "\(r.json)")
        try await setModule(w.tenantA, false, by: w.alice)
        let l = try await call(app2, .GET, links(w) + "?type=contact&id=\(a)", token: w.alice.token)
        XCTAssertEqual(l.status, .ok, "\(l.json)")
        try await aEq(items(l).count, 1)
    }
}
