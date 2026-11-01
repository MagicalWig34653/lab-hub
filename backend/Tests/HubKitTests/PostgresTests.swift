import XCTVapor
import Fluent
import SQLKit
@testable import HubKit

/// Läuft gegen echtes Postgres (`DB_PASSWORD=… docker compose up -d db`); ohne erreichbare DB werden die Tests übersprungen.
/// Umgebung: TEST_DB_HOST (127.0.0.1), TEST_DB_PORT (15432), TEST_DB_NAME/USER (labhub), TEST_DB_PASSWORD (devtest-pw). Nur synthetische Daten.
final class PostgresTests: XCTestCase {
    var app: Application!
    var db: (any SQLDatabase)!

    override func setUp() async throws {
        let e = ProcessInfo.processInfo.environment
        let env = ["DB_HOST": e["TEST_DB_HOST"] ?? "127.0.0.1", "DB_PORT": e["TEST_DB_PORT"] ?? "15432",
                   "DB_NAME": e["TEST_DB_NAME"] ?? "labhub", "DB_USER": e["TEST_DB_USER"] ?? "labhub",
                   "DB_PASSWORD": e["TEST_DB_PASSWORD"] ?? "devtest-pw", "DB_TLS": "disable"]
        app = try await Application.make(.testing)
        try configure(app, environment: env)
        do {
            _ = try await (app.db(.psql) as! any SQLDatabase).raw("SELECT 1").all()
        } catch {
            try await app.asyncShutdown(); app = nil
            throw XCTSkip("Keine Postgres-Datenbank erreichbar")
        }
        db = (app.db(.psql) as! any SQLDatabase)
        // sauberer Zustand
        for t in ["jobs", "idempotency_keys", "counters", "schema_version", "_fluent_migrations"] {
            try await db.raw("DROP TABLE IF EXISTS \(unsafeRaw: t)").run()
        }
    }

    override func tearDown() async throws { if let app { try await app.asyncShutdown() } }

    func testReadyOnlyAfterMigration() async throws {
        let curFalse = await schemaIsCurrent(app!); XCTAssertFalse(curFalse)
        try await app.test(.GET, "ready") { res async in XCTAssertEqual(res.status, .serviceUnavailable) }
        try await migrateWithLock(app)
        let curTrue = await schemaIsCurrent(app!); XCTAssertTrue(curTrue)
        try await app.test(.GET, "ready") { res async in XCTAssertEqual(res.status, .ok) }
    }

    func testParallelMigrationsAreSafe() async throws {
        try await withThrowingTaskGroup(of: Void.self) { g in
            for _ in 0..<4 { g.addTask { [app] in try await migrateWithLock(app!) } }
            try await g.waitForAll()
        }
        let curTrue = await schemaIsCurrent(app!); XCTAssertTrue(curTrue)
    }

    func testCounterIsAtomicUnderConcurrency() async throws {
        try await migrateWithLock(app)
        let tenant = UUID(), counters = CounterService(db!)
        let n = 100
        var values: [Int64] = []
        try await withThrowingTaskGroup(of: Int64.self) { g in
            for _ in 0..<n { g.addTask { try await counters.next(tenant: tenant, key: "invoice-2026") } }
            for try await v in g { values.append(v) }
        }
        XCTAssertEqual(values.sorted(), (1...Int64(n)).map { $0 })
        let other = try await counters.next(tenant: UUID(), key: "invoice-2026")
        XCTAssertEqual(other, 1)
    }

    // MARK: WP-K6 counters

    private func inTx<T: Sendable>(_ body: @Sendable @escaping (any SQLDatabase) async throws -> T) async throws -> T {
        try await app.db(.psql).transaction { tx in try await body(tx as! any SQLDatabase) }
    }

    struct Boom: Error {}

    func testNextOnForeignTransaction_AK_K6_1() async throws {
        try await migrateWithLock(app)
        let tenant = UUID(), counters = CounterService(db!)
        let key = CounterKey(space: "invoice", name: "2026")
        let (a, b) = try await inTx { tx in
            (try await counters.next(tenant: tenant, key: key, on: tx), try await counters.next(tenant: tenant, key: key, on: tx))
        }
        XCTAssertEqual([a, b], [1, 2])
        let c = try await counters.next(tenant: tenant, key: key)
        XCTAssertEqual(c, 3)
    }

    func testRollbackReleasesNumber_AK_K6_2() async throws {
        try await migrateWithLock(app)
        let tenant = UUID(), counters = CounterService(db!)
        let key = CounterKey(space: "invoice", name: "2026")
        let first = try await counters.next(tenant: tenant, key: key)
        XCTAssertEqual(first, 1)
        do {
            try await inTx { tx in
                let n = try await counters.next(tenant: tenant, key: key, on: tx)
                XCTAssertEqual(n, 2)
                throw Boom()
            }
            XCTFail("Rollback erwartet")
        } catch is Boom {}
        let again = try await counters.next(tenant: tenant, key: key)
        XCTAssertEqual(again, 2)
    }

    func testEnsureAtLeastOnlyRaises_AK_K6_3() async throws {
        try await migrateWithLock(app)
        let tenant = UUID(), counters = CounterService(db!)
        let key = CounterKey(space: "invoice", name: "2026")
        let created = try await counters.ensureAtLeast(tenant: tenant, key: key, value: 50)
        XCTAssertEqual(created, 50)
        let lowered = try await counters.ensureAtLeast(tenant: tenant, key: key, value: 10)
        XCTAssertEqual(lowered, 50)
        let n = try await counters.next(tenant: tenant, key: key)
        XCTAssertEqual(n, 51)
        let raised = try await counters.ensureAtLeast(tenant: tenant, key: key, value: 100)
        XCTAssertEqual(raised, 100)
    }

    func testEnsureAtLeastCallsAuditHookOnlyOnChange_AK_K6_3() async throws {
        try await migrateWithLock(app)
        let tenant = UUID()
        let rec = AuditRecorder()
        let counters = CounterService(db!, auditHook: rec)
        let key = CounterKey(space: "invoice", name: "2026")
        _ = try await counters.ensureAtLeast(tenant: tenant, key: key, value: 50, reason: "import")
        _ = try await counters.ensureAtLeast(tenant: tenant, key: key, value: 10, reason: "import")
        _ = try await counters.ensureAtLeast(tenant: tenant, key: key, value: 70, reason: "import")
        let events = await rec.events
        XCTAssertEqual(events.map(\.previous), [nil, 50])
        XCTAssertEqual(events.map(\.new), [50, 70])
        XCTAssertEqual(events.first?.reason, "import")
        XCTAssertEqual(events.first?.key, key.rawValue)
    }

    func testTwoConnectionsThousandNumbersNoGapNoDuplicate_AK_K6_4() async throws {
        try await migrateWithLock(app)
        let tenant = UUID(), counters = CounterService(db!)
        let key = CounterKey(space: "invoice", name: "2026")
        var values: [Int64] = []
        try await withThrowingTaskGroup(of: [Int64].self) { g in
            for _ in 0..<2 {   // two workers, each batch in its own transaction (= own connection)
                g.addTask { [application = app!] in
                    var out: [Int64] = []
                    for _ in 0..<50 {
                        out += try await inTxOn(application) { tx in
                            var batch: [Int64] = []
                            for _ in 0..<10 { batch.append(try await counters.next(tenant: tenant, key: key, on: tx)) }
                            return batch
                        }
                    }
                    return out
                }
            }
            for try await v in g { values += v }
        }
        XCTAssertEqual(values.sorted(), (1...1000).map { Int64($0) })
    }

    func testIdempotency() async throws {
        try await migrateWithLock(app)
        let svc = IdempotencyService(db!), tenant = UUID()
        let calls = ActorCounter()
        let r1 = try await svc.execute(tenant: tenant, key: "k1", requestHash: "h") { await calls.inc(); return StoredResponse(status: 201, body: "{\"n\":1}") }
        let r2 = try await svc.execute(tenant: tenant, key: "k1", requestHash: "h") { await calls.inc(); return StoredResponse(status: 500, body: "x") }
        XCTAssertEqual(r1, r2)
        let c = await calls.value
        XCTAssertEqual(c, 1)
        do {
            _ = try await svc.execute(tenant: tenant, key: "k1", requestHash: "other") { StoredResponse(status: 200, body: "") }
            XCTFail("Konflikt erwartet")
        } catch { XCTAssertEqual(error as? IdempotencyError, .keyReusedWithDifferentRequest) }
        // parallel: work läuft genau einmal
        let par = ActorCounter()
        await withTaskGroup(of: Void.self) { g in
            for _ in 0..<10 { g.addTask {
                _ = try? await svc.execute(tenant: tenant, key: "k2", requestHash: "h") { await par.inc(); try await Task.sleep(for: .milliseconds(200)); return StoredResponse(status: 200, body: "ok") }
            } }
        }
        let pc = await par.value
        XCTAssertEqual(pc, 1)
    }

    func testJobLeaseHasSingleOwner() async throws {
        try await migrateWithLock(app)
        let jobs = JobService(db!)
        let id = try await jobs.enqueue(kind: "test")
        var winners: [String] = []
        await withTaskGroup(of: String?.self) { g in
            for i in 0..<10 { g.addTask { (try? await jobs.claim(owner: "w\(i)", leaseSeconds: 30)) != nil ? "w\(i)" : nil } }
            for await w in g { if let w { winners.append(w) } }
        }
        XCTAssertEqual(winners.count, 1)
        let owner = winners[0]
        let intruder = try await jobs.complete(id, owner: "other")
        XCTAssertFalse(intruder)
        let again = try await jobs.claim(owner: "late", leaseSeconds: 30)
        XCTAssertNil(again)
        let done = try await jobs.complete(id, owner: owner)
        XCTAssertTrue(done)
    }

    func testExpiredLeaseCanBeTakenOver() async throws {
        try await migrateWithLock(app)
        let jobs = JobService(db!)
        let id = try await jobs.enqueue(kind: "test")
        _ = try await jobs.claim(owner: "a", leaseSeconds: 1)
        try await Task.sleep(for: .milliseconds(1500))
        let b = try await jobs.claim(owner: "b", leaseSeconds: 30)
        XCTAssertEqual(b?.id, id)
        let aDone = try await jobs.complete(id, owner: "a")
        XCTAssertFalse(aDone)
    }
}

actor ActorCounter { var value = 0; func inc() { value += 1 } }

actor AuditRecorder: CounterAuditHook {
    var events: [CounterAuditEvent] = []
    func counterRaised(_ event: CounterAuditEvent, on db: any SQLDatabase) async throws { events.append(event) }
}

func inTxOn<T: Sendable>(_ app: Application, _ body: @Sendable @escaping (any SQLDatabase) async throws -> T) async throws -> T {
    try await app.db(.psql).transaction { tx in try await body(tx as! any SQLDatabase) }
}
