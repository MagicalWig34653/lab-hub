import XCTVapor
import Fluent
import SQLKit
@testable import HubKit

/// WP-O1: Ingest-Zustandsautomat (`dms_ingest_items`). Nur synthetische Dateien.
final class DMSIngestTests: DMSTestBase {

    func ingestID(_ docID: String) async throws -> UUID {
        try await scalar("SELECT id AS v FROM dms_ingest_items WHERE document_id = '\(docID)'", as: UUID.self)
    }

    func state(_ id: UUID) async throws -> String { try await scalar("SELECT state AS v FROM dms_ingest_items WHERE id = '\(id)'", as: String.self) }
    func transitions(_ id: UUID) async throws -> Int64 { try await count("dms_ingest_transitions", where: "ingest_item_id = '\(id)'") }

    /// Upload legt genau ein Ingest-Item an (Quelle upload, Zustand hashed, Übergänge received/stored/hashed protokolliert) plus Audit `dms.ingest.received`.
    func testUploadCreatesIngestItem() async throws {
        let w = try await world()
        let doc = try await newDoc(w.alice, w.tenantA, seed: "ingest-1")
        let id = try await ingestID(doc["id"] as! String)
        try await aEq(try await state(id), "hashed")
        try await aEq(try await transitions(id), 3)
        try await aEq(try await scalar("SELECT source AS v FROM dms_ingest_items WHERE id = '\(id)'", as: String.self), "upload")
        try await aEq(try await auditCount("dms.ingest.received", tenant: w.tenantA), 1)
        // Wiederholter Upload mit gleichem Idempotency-Key legt kein zweites Item an
        let key = UUID().uuidString
        let r1 = try await upload(w.alice, w.tenantA, pdf("ingest-2"), key: key)
        let r2 = try await upload(w.alice, w.tenantA, pdf("ingest-2"), key: key, via: app2)
        XCTAssertEqual(r1.status, .created); XCTAssertEqual(r2.status, .created)
        try await aEq(try await count("dms_ingest_items"), 2)
    }

    /// AK-O1-1: Jeder Übergang ist idempotent: Wiederholung ohne Effekt, nichts doppelt protokolliert; Überspringen scheitert; Rückwärts ist ein No-op.
    func testAKO1_1_ingestTransitionsAreIdempotent() async throws {
        let w = try await world()
        let tenant = UUID(uuidString: w.tenantA)!
        let doc = try await newDoc(w.alice, w.tenantA, seed: "ingest-idem")
        let id = try await ingestID(doc["id"] as! String)
        let db = app1.db(.psql)
        let first = try await DMSIngest.advance(id, tenant: tenant, to: .ocrQueued, on: db)
        let again = try await DMSIngest.advance(id, tenant: tenant, to: .ocrQueued, on: db)
        XCTAssertTrue(first); XCTAssertFalse(again)
        try await aEq(try await state(id), "ocr_queued"); try await aEq(try await transitions(id), 4)
        // rückwärts: No-op, Zustand bleibt
        let back = try await DMSIngest.advance(id, tenant: tenant, to: .stored, on: db)
        XCTAssertFalse(back)
        try await aEq(try await state(id), "ocr_queued")
        // Überspringen ist verboten und ändert nichts
        do { _ = try await DMSIngest.advance(id, tenant: tenant, to: .classified, on: db); XCTFail("skip must fail") } catch let e as HubError { XCTAssertEqual(e.status, .conflict) }
        try await aEq(try await state(id), "ocr_queued"); try await aEq(try await transitions(id), 4)
        // restliche Kette, jeweils doppelt
        for s in [DMSIngest.State.ocrDone, .classified, .done] {
            let a = try await DMSIngest.advance(id, tenant: tenant, to: s, on: db), b = try await DMSIngest.advance(id, tenant: tenant, to: s, on: db)
            XCTAssertTrue(a); XCTAssertFalse(b)
        }
        try await aEq(try await state(id), "done"); try await aEq(try await transitions(id), 7)
        // abgeschlossen: Fehlermeldung ist ein No-op
        let late = try await DMSIngest.fail(id, tenant: tenant, code: "late", retryable: true, on: db)
        XCTAssertFalse(late)
        try await aEq(try await state(id), "done")
    }

    /// AK-O1-1 mit zwei Instanzen: 16 parallele gleiche Übergänge über beide Verbindungen -> genau ein Effekt, eine Zeile je Zustand.
    func testAKO1_1_parallelAdvanceFromTwoInstancesHasExactlyOneEffect() async throws {
        let w = try await world()
        let tenant = UUID(uuidString: w.tenantA)!
        let doc = try await newDoc(w.alice, w.tenantA, seed: "ingest-par")
        let id = try await ingestID(doc["id"] as! String)
        let dbs: [any Database] = [app1.db(.psql), app2.db(.psql)]
        let wins = try await withThrowingTaskGroup(of: Bool.self) { g in
            for i in 0..<16 { g.addTask { try await DMSIngest.advance(id, tenant: tenant, to: .ocrQueued, on: dbs[i % 2]) } }
            var n = 0
            for try await r in g where r { n += 1 }
            return n
        }
        XCTAssertEqual(wins, 1)
        try await aEq(try await transitions(id), 4)
        try await aEq(try await count("dms_ingest_transitions", where: "ingest_item_id = '\(id)' AND state = 'ocr_queued'"), 1)
    }

    /// Fehlerzustände: retryable/permanent idempotent, Fortschritt aus Fehler heraus verboten, manuelles Wiederholen kehrt zum letzten guten Zustand zurück.
    func testFailAndRetry() async throws {
        let w = try await world()
        let tenant = UUID(uuidString: w.tenantA)!
        let doc = try await newDoc(w.alice, w.tenantA, seed: "ingest-fail")
        let id = try await ingestID(doc["id"] as! String)
        let db = app1.db(.psql)
        _ = try await DMSIngest.advance(id, tenant: tenant, to: .ocrQueued, on: db)
        let f1 = try await DMSIngest.fail(id, tenant: tenant, code: "ocr_timeout", retryable: true, on: db)
        let f2 = try await DMSIngest.fail(id, tenant: tenant, code: "ocr_timeout", retryable: true, on: db)
        XCTAssertTrue(f1); XCTAssertFalse(f2)
        try await aEq(try await state(id), "failed_retryable")
        try await aEq(try await scalar("SELECT error_code AS v FROM dms_ingest_items WHERE id = '\(id)'", as: String.self), "ocr_timeout")
        do { _ = try await DMSIngest.advance(id, tenant: tenant, to: .ocrDone, on: db); XCTFail("advance from failed must fail") } catch let e as HubError { XCTAssertEqual(e.status, .conflict) }
        // Eskalation auf permanent (Quarantäne)
        let p = try await DMSIngest.fail(id, tenant: tenant, code: "ocr_failed", retryable: false, on: db)
        XCTAssertTrue(p)
        try await aEq(try await state(id), "failed_permanent")
        let p2 = try await DMSIngest.fail(id, tenant: tenant, code: "ocr_failed", retryable: false, on: db)
        XCTAssertFalse(p2)
        // manuell wiederholen: zurück auf ocr_queued, zweites Wiederholen ohne Wirkung, danach geht es weiter
        let r1 = try await DMSIngest.retry(id, tenant: tenant, on: db), r2 = try await DMSIngest.retry(id, tenant: tenant, on: db)
        XCTAssertTrue(r1); XCTAssertFalse(r2)
        try await aEq(try await state(id), "ocr_queued")
        try await aEq(try await scalar("SELECT error_code IS NULL AS v FROM dms_ingest_items WHERE id = '\(id)'", as: Bool.self), true)
        let next = try await DMSIngest.advance(id, tenant: tenant, to: .ocrDone, on: db)
        XCTAssertTrue(next)
    }

    /// Mandantentrennung: fremde Mandanten-ID -> 404 (kein Zugriff über fremde Item-ID); Datenbank verhindert Verweis auf fremdes Dokument.
    func testIngestIsTenantScoped() async throws {
        let w = try await world()
        let doc = try await newDoc(w.alice, w.tenantA, seed: "ingest-tenant")
        let id = try await ingestID(doc["id"] as! String)
        let other = UUID()
        do { _ = try await DMSIngest.advance(id, tenant: other, to: .ocrQueued, on: app1.db(.psql)); XCTFail("must be hidden") } catch let e as HubError { XCTAssertEqual(e.status, .notFound) }
        try await aEq(try await state(id), "hashed")
        do {
            _ = try await db.raw("INSERT INTO dms_ingest_items (tenant_id, document_id, source, state) VALUES (\(bind: other), \(bind: UUID(uuidString: doc["id"] as! String)!), 'upload', 'received')").run()
            XCTFail("cross-tenant reference must fail")
        } catch {}
    }

    /// Migration `dms_017_ingest`: eingetragen, Revert und erneutes Anwenden funktionieren.
    func testIngestMigrationRevertAndReapply() async throws {
        _ = try await world(enable: false)
        try await aEq(try await count("_fluent_migrations", where: "name = 'dms_017_ingest'"), 1)
        let m = CreateDMSIngest()
        try await m.revert(on: app1.db(.psql))
        try await aEq(try await count("information_schema.tables", where: "table_name LIKE 'dms\\_ingest\\_%'"), 0)
        try await m.prepare(on: app1.db(.psql))
        try await aEq(try await count("information_schema.tables", where: "table_name LIKE 'dms\\_ingest\\_%'"), 2)
    }
}
