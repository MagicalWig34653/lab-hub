import XCTVapor
import Fluent
import SQLKit
@testable import HubKit

/// WP-H12 (Codex-Befund 7): Idempotency-Key mit Lease statt dauerhafter Sperre. Nur synthetische Daten.
final class IdempotencyLeaseTests: XCTestCase {
    var app: Application!
    var app2: Application!
    var db: (any SQLDatabase)!
    var db2: (any SQLDatabase)!

    override func setUp() async throws {
        app = try await Application.make(.testing)
        try configure(app, environment: HubTestDB.env)
        do { _ = try await (app.db(.psql) as! any SQLDatabase).raw("SELECT 1").all() } catch {
            try await app.asyncShutdown(); app = nil
            throw XCTSkip("Keine Postgres-Datenbank erreichbar")
        }
        db = (app.db(.psql) as! any SQLDatabase)
        try await HubTestDB.dropAll(db)
        try await migrateWithLock(app)
        app2 = try await Application.make(.testing)
        try configure(app2, environment: HubTestDB.env)
        db2 = (app2.db(.psql) as! any SQLDatabase)
    }

    override func tearDown() async throws {
        if let app2 { try await app2.asyncShutdown() }
        if let app { try await app.asyncShutdown() }
    }

    private func seed(_ tenant: UUID, _ key: String, hash: String = "h", ageSeconds: Int, state: String = "in_progress") async throws {
        let status: Int? = state == "done" ? 200 : nil
        let body: String? = state == "done" ? "old" : nil
        try await db.raw("""
            INSERT INTO idempotency_keys (tenant_id, key, request_hash, state, response_status, response_body, created_at, locked_at)
            VALUES (\(bind: tenant), \(bind: key), \(bind: hash), \(bind: state), \(bind: status), \(bind: body),
                    now() - make_interval(secs => \(bind: ageSeconds)), now() - make_interval(secs => \(bind: ageSeconds)))
            """).run()
    }

    /// AK-H12-1: eine abgelaufene `in_progress`-Zeile (Absturz) wird übernommen, `work` läuft, Ergebnis wird gespeichert.
    func testAKH12_1_staleInProgressIsTakenOver() async throws {
        let svc = IdempotencyService(db, leaseSeconds: 60), tenant = UUID()
        try await seed(tenant, "k", ageSeconds: 3600)
        let calls = ActorCounter()
        let r = try await svc.execute(tenant: tenant, key: "k", requestHash: "h") { await calls.inc(); return StoredResponse(status: 201, body: "new") }
        XCTAssertEqual(r.body, "new")
        let again = try await svc.execute(tenant: tenant, key: "k", requestHash: "h") { await calls.inc(); return StoredResponse(status: 500, body: "x") }
        XCTAssertEqual(again, r)
        let n = await calls.value
        XCTAssertEqual(n, 1)
    }

    /// AK-H12-2: eine frische `in_progress`-Zeile bleibt `inProgress`; abweichender Hash bleibt Konflikt, auch bei abgelaufener Lease.
    func testAKH12_2_freshInProgressBlocksAndHashMismatchConflicts() async throws {
        let svc = IdempotencyService(db, leaseSeconds: 60), tenant = UUID()
        try await seed(tenant, "fresh", ageSeconds: 1)
        do {
            _ = try await svc.execute(tenant: tenant, key: "fresh", requestHash: "h") { XCTFail("darf nicht laufen"); return StoredResponse(status: 200, body: "") }
            XCTFail("inProgress erwartet")
        } catch { XCTAssertEqual(error as? IdempotencyError, .inProgress) }
        try await seed(tenant, "stale-other", hash: "x", ageSeconds: 3600)
        do {
            _ = try await svc.execute(tenant: tenant, key: "stale-other", requestHash: "h") { StoredResponse(status: 200, body: "") }
            XCTFail("Konflikt erwartet")
        } catch { XCTAssertEqual(error as? IdempotencyError, .keyReusedWithDifferentRequest) }
    }

    /// AK-H12-3 (Zwei Instanzen): zwei Dienste auf getrennten Verbindungen übernehmen dieselbe abgelaufene Zeile, `work` läuft genau einmal.
    func testAKH12_3_twoInstancesTakeOverExactlyOnce() async throws {
        let a = IdempotencyService(db, leaseSeconds: 60), b = IdempotencyService(db2, leaseSeconds: 60), tenant = UUID()
        try await seed(tenant, "k", ageSeconds: 3600)
        let calls = ActorCounter()
        await withTaskGroup(of: Void.self) { g in
            for svc in [a, b, a, b, a, b] { g.addTask {
                _ = try? await svc.execute(tenant: tenant, key: "k", requestHash: "h") { await calls.inc(); try await Task.sleep(for: .milliseconds(300)); return StoredResponse(status: 200, body: "ok") }
            } }
        }
        let n = await calls.value
        XCTAssertEqual(n, 1)
        let r = try await b.execute(tenant: tenant, key: "k", requestHash: "h") { XCTFail("darf nicht laufen"); return StoredResponse(status: 0, body: "") }
        XCTAssertEqual(r.body, "ok")
    }

    /// AK-H12-4: Fachänderung und `done` in einer Transaktion: scheitert `work`, bleibt weder Fachänderung noch Key; Erfolg schreibt beides.
    func testAKH12_4_atomicWorkAndDone() async throws {
        let svc = IdempotencyService(db), tenant = UUID()
        struct Boom: Error {}
        do {
            _ = try await svc.executeAtomic(tenant: tenant, key: "a", requestHash: "h") { tx in
                _ = try await CounterService(tx).next(tenant: tenant, key: "h12"); throw Boom()
            }
            XCTFail("Fehler erwartet")
        } catch is Boom {}
        let keys = try await db.raw("SELECT 1 AS x FROM idempotency_keys WHERE tenant_id = \(bind: tenant)").all().count
        let counters = try await db.raw("SELECT 1 AS x FROM counters WHERE tenant_id = \(bind: tenant)").all().count
        XCTAssertEqual(keys, 0); XCTAssertEqual(counters, 0)
        let ok = try await svc.executeAtomic(tenant: tenant, key: "a", requestHash: "h") { tx in
            let v = try await CounterService(tx).next(tenant: tenant, key: "h12"); return StoredResponse(status: 201, body: "\(v)")
        }
        let replay = try await svc.executeAtomic(tenant: tenant, key: "a", requestHash: "h") { _ in XCTFail("darf nicht laufen"); return StoredResponse(status: 0, body: "") }
        XCTAssertEqual(ok, replay)
        let value = try await db.raw("SELECT value FROM counters WHERE tenant_id = \(bind: tenant)").first()!.decode(column: "value", as: Int64.self)
        XCTAssertEqual(value, 1)
    }

    /// AK-H12-5: alte Keys werden gelöscht (erledigte und lange hängende), junge bleiben.
    func testAKH12_5_purgeExpired() async throws {
        let svc = IdempotencyService(db, leaseSeconds: 60), tenant = UUID()
        try await seed(tenant, "old-done", ageSeconds: 40 * 86400, state: "done")
        try await seed(tenant, "old-stuck", ageSeconds: 40 * 86400)
        try await seed(tenant, "young", ageSeconds: 3600, state: "done")
        let removed = try await svc.purgeExpired(retentionSeconds: 7 * 86400)
        XCTAssertEqual(removed, 2)
        let left = try await db.raw("SELECT key FROM idempotency_keys WHERE tenant_id = \(bind: tenant)").all().map { try $0.decode(column: "key", as: String.self) }
        XCTAssertEqual(left, ["young"])
    }
}

/// WP-H12 (Codex-Befund 10): DMS wieder an -> Job-Kette der aktiven Quellen wird neu angestoßen (idempotent).
final class DMSReactivationTests: DMSSourceTestBase {
    func folder(_ name: String, _ path: String) -> [String: Any] {
        ["kind": "folder", "name": name, "config": ["path": path, "interval_seconds": 60, "stable_seconds": 0]]
    }

    /// AK-H12-6: DMS aus, offene Jobs enden (Kette reißt ab), DMS an -> genau ein neuer Job je aktiver Quelle; zweiter Aufruf ändert nichts; deaktivierte Quelle bleibt ohne Job.
    func testAKH12_6_reactivationRestartsChainOncePerEnabledSource() async throws {
        let w = try await world()
        let a = src(w.tenantA), t = w.alice.token
        let f1 = try await call(app1, .POST, a, json: folder("F1", "scan1"), token: t)
        let f2 = try await call(app1, .POST, a, json: folder("F2", "scan2"), token: t)
        let off = try await call(app1, .POST, a, json: folder("F3", "scan3"), token: t)
        XCTAssertEqual(f1.status, .created, "\(f1.json)"); XCTAssertEqual(f2.status, .created, "\(f2.json)"); XCTAssertEqual(off.status, .created, "\(off.json)")
        let offID = off.json["id"] as! String
        let patched = try await call(app1, .PATCH, a + "/\(offID)", json: ["enabled": false], token: t)
        XCTAssertEqual(patched.status, .ok, "\(patched.json)")
        try await setModule(w.tenantA, false, by: w.alice)
        // Worker läuft bei abgeschaltetem DMS: die Jobs enden ohne Folgejob
        try await db.raw("UPDATE jobs SET state = 'done', finished_at = now() WHERE kind = 'dms.folder.scan'").run()
        try await aEq(try await count("jobs", where: "kind = 'dms.folder.scan' AND state IN ('queued', 'running')"), 0)
        try await setModule(w.tenantA, true, by: w.alice)
        try await aEq(try await count("jobs", where: "kind = 'dms.folder.scan' AND state IN ('queued', 'running')"), 2)
        try await aEq(try await count("jobs", where: "kind = 'dms.folder.scan' AND state IN ('queued', 'running') AND payload LIKE '%\(offID.uppercased())%'"), 0)
        // zweiter Aufruf (Modul bleibt an; direkter onActivate-Aufruf über die zweite Instanz) erzeugt nichts Neues
        let tenant = UUID(uuidString: w.tenantA)!
        for _ in 0..<2 { try await DMSModule(objectStore: ObjectStoreConfig(kind: .db)).onActivate(tenant: tenant, on: db) }
        try await aEq(try await count("jobs", where: "kind = 'dms.folder.scan' AND state IN ('queued', 'running')"), 2)
    }
}
