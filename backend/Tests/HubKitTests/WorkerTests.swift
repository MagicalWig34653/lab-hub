import XCTVapor
import Fluent
import SQLKit
@testable import HubKit

/// WP-O1: Job-Erweiterung (Priorität, Poison, Lease-Erneuerung, Release) und Worker-Befehl. Nur synthetische Daten.
/// Die Prozesstests starten das gebaute `App`-Executable (`App worker`); fehlt es neben dem Testbundle, werden sie übersprungen.
class JobTestBase: AuthTestCase {
    var jobs: JobService { JobService(db) }

    struct JobRow { let state: String; let attempts: Int; let owner: String?; let leaseActive: Bool; let priority: Int; let lastError: String? }

    func jobRow(_ id: UUID) async throws -> JobRow {
        let r = try await db.raw("""
            SELECT state, attempts, lease_owner, (lease_until IS NOT NULL AND lease_until > now()) AS active, priority, last_error FROM jobs WHERE id = \(bind: id)
            """).first()!
        return JobRow(state: try r.decode(column: "state", as: String.self), attempts: try r.decode(column: "attempts", as: Int.self),
                      owner: try r.decode(column: "lease_owner", as: String?.self), leaseActive: try r.decode(column: "active", as: Bool.self),
                      priority: try r.decode(column: "priority", as: Int.self), lastError: try r.decode(column: "last_error", as: String?.self))
    }

    func waitFor(_ what: String, timeout: Double = 30, _ cond: () async throws -> Bool) async throws {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if try await cond() { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTFail("Timeout: \(what)")
    }
}

final class JobServiceTests: JobTestBase {

    /// AK-O1-1: Jeder Übergang eines Jobs ist idempotent (Wiederholung ohne Effekt, auch von der falschen Partei).
    func testAKO1_1_jobTransitionsAreIdempotent() async throws {
        let id = try await jobs.enqueue(kind: "t.a")
        let c = try await jobs.claim(owner: "w1", leaseSeconds: 30)
        XCTAssertEqual(c?.id, id)
        XCTAssertEqual(c?.attempts, 1)
        // renew: wiederholbar, nur Besitzer
        let r1 = try await jobs.renew(id, owner: "w1", leaseSeconds: 30), r2 = try await jobs.renew(id, owner: "w1", leaseSeconds: 30)
        let r3 = try await jobs.renew(id, owner: "w2", leaseSeconds: 30)
        XCTAssertTrue(r1); XCTAssertTrue(r2); XCTAssertFalse(r3)
        // release: zweimal und von Fremden ohne Wirkung; zählt nicht als Versuch
        try await jobs.release(id, owner: "w2")
        var row = try await jobRow(id); XCTAssertEqual(row.state, "running")
        try await jobs.release(id, owner: "w1"); try await jobs.release(id, owner: "w1")
        row = try await jobRow(id)
        XCTAssertEqual(row.state, "queued"); XCTAssertNil(row.owner); XCTAssertEqual(row.attempts, 0)
        // complete: genau einmal
        _ = try await jobs.claim(owner: "w1", leaseSeconds: 30)
        let d1 = try await jobs.complete(id, owner: "w1"), d2 = try await jobs.complete(id, owner: "w1")
        XCTAssertTrue(d1); XCTAssertFalse(d2)
        // fail nach done: ohne Wirkung
        let o = try await jobs.fail(id, owner: "w1", code: "late", retryAfterSeconds: 0)
        XCTAssertEqual(o, .notOwner)
        row = try await jobRow(id); XCTAssertEqual(row.state, "done")
        // fail: Wiederholung ohne Wirkung (zweiter Aufruf ist nicht mehr Besitzer)
        let id2 = try await jobs.enqueue(kind: "t.a")
        _ = try await jobs.claim(owner: "w1", leaseSeconds: 30)
        let f1 = try await jobs.fail(id2, owner: "w1", code: "boom", retryAfterSeconds: 0), f2 = try await jobs.fail(id2, owner: "w1", code: "boom", retryAfterSeconds: 0)
        XCTAssertEqual(f1, .retry); XCTAssertEqual(f2, .notOwner)
        row = try await jobRow(id2); XCTAssertEqual(row.state, "queued"); XCTAssertEqual(row.lastError, "boom"); XCTAssertEqual(row.attempts, 1)
    }

    /// AK-O1-3: Ein Job, der immer scheitert, wird nach 3 Versuchen `failed_permanent` und nie wieder abgeholt.
    func testAKO1_3_poisonJobFailsPermanentlyAfterThreeAttempts() async throws {
        let id = try await jobs.enqueue(kind: "t.poison")
        for attempt in 1...3 {
            let c = try await jobs.claim(owner: "w\(attempt)", leaseSeconds: 30)
            XCTAssertEqual(c?.attempts, attempt)
            let o = try await jobs.fail(id, owner: "w\(attempt)", code: "handler_error", retryAfterSeconds: 0)
            XCTAssertEqual(o, attempt < 3 ? .retry : .failedPermanent)
        }
        let row = try await jobRow(id)
        XCTAssertEqual(row.state, "failed_permanent"); XCTAssertEqual(row.attempts, 3); XCTAssertEqual(row.lastError, "handler_error")
        let none = try await jobs.claim(owner: "w4", leaseSeconds: 30)
        XCTAssertNil(none)
        // sofort permanent
        let id2 = try await jobs.enqueue(kind: "t.poison")
        _ = try await jobs.claim(owner: "x", leaseSeconds: 30)
        let o2 = try await jobs.fail(id2, owner: "x", code: "unsupported", retryAfterSeconds: 0, permanent: true)
        XCTAssertEqual(o2, .failedPermanent)
    }

    /// AK-O1-3: Auch ein Job, der den Worker jedes Mal abstürzen lässt (Lease läuft nur ab), wird nach 3 Versuchen Quarantäne.
    func testAKO1_3_crashLoopingJobIsQuarantinedByClaim() async throws {
        let id = try await jobs.enqueue(kind: "t.crash")
        for attempt in 1...3 {
            let c = try await jobs.claim(owner: "crash\(attempt)", leaseSeconds: 1)
            XCTAssertEqual(c?.id, id, "attempt \(attempt)")
            try await Task.sleep(for: .milliseconds(1300))
        }
        let c = try await jobs.claim(owner: "w4", leaseSeconds: 30)
        XCTAssertNil(c)
        let row = try await jobRow(id)
        XCTAssertEqual(row.state, "failed_permanent"); XCTAssertEqual(row.attempts, 3); XCTAssertFalse(row.leaseActive)
    }

    /// Priorität (ADR 0006 Nr. 4): höhere Zahl zuerst, bei Gleichstand ältere zuerst; Art-Filter wird eingehalten.
    func testPriorityOrderAndKindFilter() async throws {
        let low = try await jobs.enqueue(kind: "t.a", priority: 0)
        let bulk = try await jobs.enqueue(kind: "t.b", priority: 5)
        let high = try await jobs.enqueue(kind: "t.a", priority: 10)
        let low2 = try await jobs.enqueue(kind: "t.a", priority: 0)
        let c1 = try await jobs.claim(owner: "w", leaseSeconds: 30, kinds: ["t.a"])
        let c2 = try await jobs.claim(owner: "w", leaseSeconds: 30, kinds: ["t.a"])
        let c3 = try await jobs.claim(owner: "w", leaseSeconds: 30, kinds: ["t.a"])
        XCTAssertEqual(c1?.id, high); XCTAssertEqual(c2?.id, low); XCTAssertEqual(c3?.id, low2)
        let none = try await jobs.claim(owner: "w", leaseSeconds: 30, kinds: ["t.a"])
        XCTAssertNil(none)
        let b = try await jobs.claim(owner: "w", leaseSeconds: 30, kinds: ["t.x", "t.b"])
        XCTAssertEqual(b?.id, bulk)
    }

    /// Zwei Verbindungen (zwei Instanzen): paralleles Abholen vieler Jobs vergibt jeden genau einmal.
    func testParallelClaimsFromTwoInstancesGiveEachJobOnce() async throws {
        let a = JobService(db), b = JobService(app2.db(.psql) as! any SQLDatabase)
        for _ in 0..<20 { try await a.enqueue(kind: "t.par") }
        let claimed = await withTaskGroup(of: [UUID].self) { g in
            for i in 0..<8 { g.addTask {
                let svc = i % 2 == 0 ? a : b
                var mine: [UUID] = []
                while let c = try? await svc.claim(owner: "p\(i)", leaseSeconds: 30, kinds: ["t.par"]) { mine.append(c.id) }
                return mine
            } }
            var all: [UUID] = []
            for await m in g { all += m }
            return all
        }
        XCTAssertEqual(claimed.count, 20); XCTAssertEqual(Set(claimed).count, 20)
    }

    /// Migration 017: Spalten `priority` (Standard 0) und `last_error`; Revert und erneutes Anwenden funktionieren; bestehende Jobs bleiben gültig.
    func testMigrationJobsPriorityRevertAndReapply() async throws {
        let id = try await jobs.enqueue(kind: "t.a")
        var row = try await jobRow(id); XCTAssertEqual(row.priority, 0)
        let v = try await scalar("SELECT max(version)::bigint AS v FROM schema_version", as: Int64.self)
        XCTAssertEqual(v, 17)
        let m = CreateJobsPriority()
        try await m.revert(on: app1.db(.psql))
        let gone = try await scalar("SELECT count(*)::bigint AS v FROM information_schema.columns WHERE table_name = 'jobs' AND column_name IN ('priority', 'last_error')", as: Int64.self)
        XCTAssertEqual(gone, 0)
        let back = try await scalar("SELECT max(version)::bigint AS v FROM schema_version", as: Int64.self)
        XCTAssertEqual(back, 15)
        try await m.prepare(on: app1.db(.psql))
        row = try await jobRow(id); XCTAssertEqual(row.priority, 0)
    }
}

/// In-Prozess-Worker (Schleife, Lease-Erneuerung, Graceful Shutdown).
final class JobWorkerTests: JobTestBase {
    final class Counter: @unchecked Sendable {
        private let lock = NSLock(); private var n = 0
        func inc() -> Int { lock.lock(); defer { lock.unlock() }; n += 1; return n }
        var value: Int { lock.lock(); defer { lock.unlock() }; return n }
    }

    func makeWorker(_ handlers: [String: JobHandler], lease: Int = 30, backoff: Int = 0) -> JobWorker {
        JobWorker(db: db, kinds: Array(handlers.keys), handlers: handlers, leaseSeconds: lease, pollInterval: .milliseconds(100),
                  retryBackoffSeconds: backoff, logger: Logger(label: "test.worker"))
    }

    /// AK-O1-3 über den Worker: Handler wirft immer -> genau 3 Aufrufe, dann failed_permanent; ein gesunder Job daneben läuft durch.
    func testAKO1_3_workerQuarantinesPoisonJobAndContinues() async throws {
        let calls = Counter()
        let poison = try await jobs.enqueue(kind: "t.poison")
        let good = try await jobs.enqueue(kind: "t.good")
        let worker = makeWorker(["t.poison": { _, _ in _ = calls.inc(); throw NSError(domain: "synthetic", code: 1) }, "t.good": { _, _ in }])
        let run = Task { await worker.run() }
        try await waitFor("poison quarantined") { try await jobRow(poison).state == "failed_permanent" }
        try await waitFor("good done") { try await jobRow(good).state == "done" }
        worker.requestShutdown(); await run.value
        XCTAssertEqual(calls.value, 3)
        let row = try await jobRow(poison); XCTAssertEqual(row.attempts, 3); XCTAssertEqual(row.lastError, "handler_error")
    }

    /// Ein `PermanentJobError` überspringt die Wiederholungen.
    func testPermanentErrorSkipsRetries() async throws {
        let calls = Counter()
        let id = try await jobs.enqueue(kind: "t.perm")
        let worker = makeWorker(["t.perm": { _, _ in _ = calls.inc(); throw PermanentJobError(code: "unsupported_input") }])
        let run = Task { await worker.run() }
        try await waitFor("failed") { try await jobRow(id).state == "failed_permanent" }
        worker.requestShutdown(); await run.value
        XCTAssertEqual(calls.value, 1)
        let lastError = try await jobRow(id).lastError
        XCTAssertEqual(lastError, "unsupported_input")
    }

    /// AK-O1-4 (in-Prozess): Shutdown während eines Jobs bricht den Handler ab und gibt die Lease sofort frei.
    func testAKO1_4_shutdownReleasesLeaseOfRunningJob() async throws {
        let started = Counter()
        let id = try await jobs.enqueue(kind: "t.long")
        let worker = makeWorker(["t.long": { _, _ in _ = started.inc(); try await Task.sleep(for: .seconds(120)) }])
        let run = Task { await worker.run() }
        try await waitFor("started") { started.value == 1 }
        worker.requestShutdown(); await run.value
        let row = try await jobRow(id)
        XCTAssertEqual(row.state, "queued"); XCTAssertNil(row.owner); XCTAssertFalse(row.leaseActive); XCTAssertEqual(row.attempts, 0)
        let other = try await jobs.claim(owner: "other", leaseSeconds: 30)
        XCTAssertEqual(other?.id, id)
    }

    /// Lease-Erneuerung: ein Job, der länger läuft als die Lease, bleibt dem Worker; ein zweiter Worker (zweite Verbindung) holt ihn nicht ab.
    func testLeaseRenewalKeepsLongJobFromSecondWorker() async throws {
        let started = Counter(), finish = Counter()
        let id = try await jobs.enqueue(kind: "t.renew")
        let slow = makeWorker(["t.renew": { _, _ in _ = started.inc(); while finish.value == 0 { try await Task.sleep(for: .milliseconds(100)) } }], lease: 2)
        let run = Task { await slow.run() }
        try await waitFor("started") { started.value == 1 }
        let second = JobService(app2.db(.psql) as! any SQLDatabase)
        try await Task.sleep(for: .milliseconds(4500))   // mehr als zwei Lease-Längen
        let stolen = try await second.claim(owner: "thief", leaseSeconds: 30)
        XCTAssertNil(stolen)
        _ = finish.inc()
        try await waitFor("done") { try await jobRow(id).state == "done" }
        slow.requestShutdown(); await run.value
        let attempts = try await jobRow(id).attempts
        XCTAssertEqual(attempts, 1)
    }
}

/// Mehrprozess-Tests mit echten `App worker`-Prozessen gegen dieselbe Datenbank.
final class WorkerProcessTests: JobTestBase {
    /// Das `App`-Executable kennt alle installierten Module; die Datenbank muss deren Migrationen tragen, sonst startet der Worker nicht (Schema nicht aktuell).
    override var testModules: [any HubModule] { InstalledModules.all }

    static var appBinary: URL? {
        let url = Bundle(for: WorkerProcessTests.self).bundleURL.deletingLastPathComponent().appendingPathComponent("App")
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }

    func startWorker(lease: Int = 2) throws -> Process {
        guard let bin = Self.appBinary else { throw XCTSkip("App-Executable nicht gefunden (neben dem Testbundle); Mehrprozess-Test übersprungen") }
        let p = Process()
        p.executableURL = bin
        p.arguments = ["worker", "--kinds", "worker.selftest", "--lease-seconds", String(lease), "--poll-ms", "200", "--retry-backoff-seconds", "0"]
        var env = ProcessInfo.processInfo.environment
        for (k, v) in HubTestDB.env { env[k] = v }
        env["WORKER_ENABLE_SELFTEST"] = "1"
        p.environment = env
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        try p.run()
        return p
    }

    /// Wartet ohne `waitUntilExit` (das dreht die RunLoop und kann Swift-Concurrency-Threads blockieren) per Abfrage auf das Prozessende.
    func reap(_ p: Process, timeout: Double = 20) async {
        let end = Date().addingTimeInterval(timeout)
        while p.isRunning, Date() < end { try? await Task.sleep(for: .milliseconds(20)) }
    }

    func stop(_ ps: [Process]) { for p in ps where p.isRunning { kill(p.processIdentifier, SIGKILL) } }

    /// AK-O1-2: Kill -9 eines Workers mitten im Job -> nach Lease-Ablauf übernimmt ein anderer Prozess und schließt ab.
    /// Währenddessen hält die Lease-Erneuerung den Job dem ersten Worker (Lease 2 s, Beobachtung 4,5 s).
    func testAKO1_2_kill9WorkerJobIsTakenOverByOtherProcess() async throws {
        let id = try await jobs.enqueue(kind: "worker.selftest", payload: #"{"sleep_first_ms": 600000}"#)
        let a = try startWorker()
        defer { stop([a]) }
        try await waitFor("A claimed") { try await jobRow(id).state == "running" }
        let b = try startWorker()
        defer { stop([b]) }
        try await Task.sleep(for: .milliseconds(4500))
        var row = try await jobRow(id)
        XCTAssertEqual(row.state, "running"); XCTAssertEqual(row.attempts, 1, "B darf den erneuerten Job nicht übernehmen")
        XCTAssertTrue(row.leaseActive)
        kill(a.processIdentifier, SIGKILL); await reap(a)
        XCTAssertEqual(a.terminationReason, .uncaughtSignal)
        try await waitFor("B finished the job after lease expiry", timeout: 30) { try await jobRow(id).state == "done" }
        row = try await jobRow(id)
        XCTAssertEqual(row.attempts, 2); XCTAssertNil(row.owner)
        XCTAssertTrue(b.isRunning)
    }

    /// AK-O1-4: SIGTERM gibt die Lease frei (Job sofort wieder abholbar, Versuch zählt nicht), Prozess endet mit Status 0.
    func testAKO1_4_sigtermReleasesLeaseAndExitsCleanly() async throws {
        let id = try await jobs.enqueue(kind: "worker.selftest", payload: #"{"sleep_first_ms": 600000}"#)
        let a = try startWorker(lease: 60)
        defer { stop([a]) }
        try await waitFor("A claimed") { try await jobRow(id).state == "running" }
        kill(a.processIdentifier, SIGTERM)
        await reap(a)
        XCTAssertFalse(a.isRunning, "Worker beendet sich nach SIGTERM")
        XCTAssertEqual(a.terminationReason, .exit); XCTAssertEqual(a.terminationStatus, 0)
        let row = try await jobRow(id)
        XCTAssertEqual(row.state, "queued"); XCTAssertNil(row.owner); XCTAssertFalse(row.leaseActive); XCTAssertEqual(row.attempts, 0)
        let next = try await jobs.claim(owner: "other", leaseSeconds: 30)
        XCTAssertEqual(next?.id, id)
    }

    /// AK-O1-3 über Prozesse: scheiternder Job -> `failed_permanent` nach 3 Versuchen, nie mehr als 3 über beide Prozesse.
    func testAKO1_3_poisonJobAcrossTwoProcesses() async throws {
        let id = try await jobs.enqueue(kind: "worker.selftest", payload: #"{"fail": true}"#)
        let a = try startWorker(), b = try startWorker()
        defer { stop([a, b]) }
        try await waitFor("quarantined", timeout: 60) { try await jobRow(id).state == "failed_permanent" }
        try await Task.sleep(for: .milliseconds(800))
        let row = try await jobRow(id)
        XCTAssertEqual(row.attempts, 3); XCTAssertEqual(row.state, "failed_permanent")
    }
}
