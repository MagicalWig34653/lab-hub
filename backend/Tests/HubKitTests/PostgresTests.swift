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
