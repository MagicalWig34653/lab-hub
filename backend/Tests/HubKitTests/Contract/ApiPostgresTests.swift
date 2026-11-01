import XCTVapor
import Fluent
import SQLKit
@testable import HubKit

/// Postgres-Tests für WP-K4 (Pagination, Idempotency-Middleware). Umgebung wie `PostgresTests`; ohne DB übersprungen. Nur synthetische Daten.
final class ApiPostgresTests: XCTestCase {
    var app: Application!
    var app2: Application!
    var db: (any SQLDatabase)!

    static var env: [String: String] {
        let e = ProcessInfo.processInfo.environment
        return ["DB_HOST": e["TEST_DB_HOST"] ?? "127.0.0.1", "DB_PORT": e["TEST_DB_PORT"] ?? "15432",
                "DB_NAME": e["TEST_DB_NAME"] ?? "labhub", "DB_USER": e["TEST_DB_USER"] ?? "labhub",
                "DB_PASSWORD": e["TEST_DB_PASSWORD"] ?? "devtest-pw", "DB_TLS": "disable"]
    }

    override func setUp() async throws {
        app = try await Application.make(.testing)
        try configure(app, environment: Self.env)
        do { _ = try await (app.db(.psql) as! any SQLDatabase).raw("SELECT 1").all() } catch {
            try await app.asyncShutdown(); app = nil
            throw XCTSkip("Keine Postgres-Datenbank erreichbar")
        }
        db = (app.db(.psql) as! any SQLDatabase)
        // Nur eigene Tabellen anfassen: parallel laufende PostgresTests setzen das Basisschema zurück.
        try await db.raw("DROP TABLE IF EXISTS k4_items").run()
        try await db.raw("CREATE TABLE IF NOT EXISTS idempotency_keys (tenant_id uuid NOT NULL, key text NOT NULL, request_hash text NOT NULL, state text NOT NULL DEFAULT 'in_progress', response_status integer, response_body text, created_at timestamptz NOT NULL DEFAULT now(), PRIMARY KEY (tenant_id, key))").run()
    }

    override func tearDown() async throws {
        if let db { try? await db.raw("DROP TABLE IF EXISTS k4_items").run() }
        if let app2 { try await app2.asyncShutdown() }
        if let app { try await app.asyncShutdown() }
    }

    struct Row: Content, Equatable { let id: UUID; let ts: String }

    func fetchPage(_ db: any SQLDatabase, _ req: HubPageRequest) async throws -> HubPage<Row> {
        let sqlRows: [any SQLRow]
        if let c = req.cursor {
            sqlRows = try await db.raw("""
                SELECT id, created_at::text AS ts FROM k4_items
                WHERE (created_at, id) > (\(bind: c.createdAt)::text::timestamptz, \(bind: c.id))
                ORDER BY created_at, id LIMIT \(literal: req.limit + 1)
                """).all()
        } else {
            sqlRows = try await db.raw("SELECT id, created_at::text AS ts FROM k4_items ORDER BY created_at, id LIMIT \(literal: req.limit + 1)").all()
        }
        let rows = try sqlRows.map { Row(id: try $0.decode(column: "id", as: UUID.self), ts: try $0.decode(column: "ts", as: String.self)) }
        return HubPage(fetched: rows, limit: req.limit, cursorOf: { PageCursor(createdAt: $0.ts, id: $0.id) })
    }

    /// AK-K4-3: 10 000 synthetische Zeilen (viele mit identischem created_at), parallele Einfügungen während der Traversierung:
    /// jede Ausgangszeile genau einmal, nie ein Duplikat.
    func testAKK4_3_PaginationNoDuplicatesNoGapsUnderConcurrentInserts() async throws {
        try await db.raw("CREATE TABLE k4_items (id uuid PRIMARY KEY DEFAULT gen_random_uuid(), created_at timestamptz NOT NULL DEFAULT now(), n int NOT NULL)").run()
        // now() ist je Statement konstant: Blöcke mit identischem created_at prüfen den id-Tiebreaker
        for _ in 0..<10 { try await db.raw("INSERT INTO k4_items (n) SELECT g FROM generate_series(1, 1000) g").run() }
        let originals = Set(try await db.raw("SELECT id FROM k4_items").all().map { try $0.decode(column: "id", as: UUID.self) })
        XCTAssertEqual(originals.count, 10_000)

        let db = self.db!
        let stop = ActorFlag()
        let inserter = Task {
            var inserted = 0
            while await !stop.value {
                try await db.raw("INSERT INTO k4_items (created_at, n) SELECT clock_timestamp(), g FROM generate_series(1, 25) g").run()
                inserted += 25
            }
            return inserted
        }

        var seen: [UUID] = [], cursor: PageCursor?, pages = 0
        repeat {
            let page = try await fetchPage(db, HubPageRequest(limit: 137, cursor: cursor))
            seen.append(contentsOf: page.items.map(\.id)); pages += 1
            cursor = try page.next_cursor.map(PageCursor.decode)
            if pages == 5 { try await Task.sleep(for: .milliseconds(50)) }
        } while cursor != nil
        await stop.set()
        let inserted = try await inserter.value

        XCTAssertEqual(Set(seen).count, seen.count, "Duplikate")
        XCTAssertTrue(originals.isSubset(of: Set(seen)), "Lücken: \(originals.subtracting(Set(seen)).count) fehlen")
        XCTAssertTrue(seen.count >= 10_000 && seen.count <= 10_000 + inserted)
        XCTAssertGreaterThan(inserted, 0, "Einfügungen liefen nicht parallel")
    }

    /// AK-K4-3: Seitenzahl bei fester Datenmenge und letzte Seite ohne Cursor.
    func testAKK4_3_ExactPageCount() async throws {
        try await db.raw("CREATE TABLE k4_items (id uuid PRIMARY KEY DEFAULT gen_random_uuid(), created_at timestamptz NOT NULL DEFAULT now(), n int NOT NULL)").run()
        try await db.raw("INSERT INTO k4_items (n) SELECT g FROM generate_series(1, 250) g").run()
        var cursor: PageCursor?, sizes: [Int] = []
        repeat {
            let page = try await fetchPage(db, HubPageRequest(limit: 100, cursor: cursor))
            sizes.append(page.items.count); cursor = try page.next_cursor.map(PageCursor.decode)
        } while cursor != nil
        XCTAssertEqual(sizes, [100, 100, 50])
    }

    private func registerEcho(_ a: Application, counter: ActorCounter) {
        a.grouped(IdempotencyMiddleware()).post("api", "v1", "tenants", ":tenant", "echo") { req async throws -> Response in
            await counter.inc()
            try await Task.sleep(for: .milliseconds(150))
            let r = Response(status: .created, body: .init(string: "{\"n\":\(await counter.value)}"))
            r.headers.contentType = .json
            return r
        }
    }

    /// AK-K4-2/WP-K4: gleicher Key + gleicher Request = gespeicherte Antwort; anderer Request = 422 Problem; zwei Instanzen teilen den Zustand.
    func testIdempotencyMiddlewareReplaysAndDetectsReuseAcrossInstances() async throws {
        app2 = try await Application.make(.testing)
        try configure(app2, environment: Self.env)
        let calls = ActorCounter()
        registerEcho(app, counter: calls); registerEcho(app2, counter: calls)
        let tenant = UUID(), key = "k-\(UUID())"
        let h: HTTPHeaders = ["Idempotency-Key": key, "Content-Type": "application/json"]
        let path = "api/v1/tenants/\(tenant)/echo"
        var first = ""
        try await app.test(.POST, path, headers: h, beforeRequest: { $0.body = ByteBuffer(string: "{\"a\":1}") }) { res async throws in
            XCTAssertEqual(res.status, .created); first = res.body.string
        }
        try await app2.test(.POST, path, headers: h, beforeRequest: { $0.body = ByteBuffer(string: "{\"a\":1}") }) { res async throws in
            XCTAssertEqual(res.status, .created); XCTAssertEqual(res.body.string, first)
        }
        let c = await calls.value; XCTAssertEqual(c, 1)
        try await app2.test(.POST, path, headers: h, beforeRequest: { $0.body = ByteBuffer(string: "{\"a\":2}") }) { res async throws in
            XCTAssertEqual(res.status, .unprocessableEntity)
            XCTAssertEqual(res.headers.contentType?.serialize(), "application/problem+json")
            XCTAssertEqual(try res.content.decode(ProblemDetails.self).code, "idempotency_key_reused")
        }
        let c2 = await calls.value; XCTAssertEqual(c2, 1)
        try await app.test(.POST, path, headers: ["Content-Type": "application/json"]) { res async throws in
            XCTAssertEqual(try res.content.decode(ProblemDetails.self).code, "idempotency_key_required")
        }
        try await db.raw("DELETE FROM idempotency_keys WHERE tenant_id = \(bind: tenant)").run()
    }

    /// Parallele gleiche Requests über zwei Instanzen: Arbeit läuft genau einmal; übrige erhalten die Antwort oder 409 `idempotency_in_progress`.
    func testIdempotencyMiddlewareParallelRunsWorkOnce() async throws {
        app2 = try await Application.make(.testing)
        try configure(app2, environment: Self.env)
        let calls = ActorCounter()
        registerEcho(app, counter: calls); registerEcho(app2, counter: calls)
        let tenant = UUID(), key = "p-\(UUID())", path = "api/v1/tenants/\(tenant)/echo"
        let a = app!, b = app2!
        let statuses = await withTaskGroup(of: UInt.self) { g -> [UInt] in
            for i in 0..<6 { g.addTask {
                var s: UInt = 0
                try? await (i % 2 == 0 ? a : b).test(.POST, path, headers: ["Idempotency-Key": key], beforeRequest: { $0.body = ByteBuffer(string: "x") }) { res async throws in s = UInt(res.status.code) }
                return s
            } }
            var out: [UInt] = []; for await s in g { out.append(s) }; return out
        }
        let c = await calls.value; XCTAssertEqual(c, 1)
        XCTAssertTrue(statuses.allSatisfy { $0 == 201 || $0 == 409 }, "\(statuses)")
        XCTAssertTrue(statuses.contains(201))
        try await db.raw("DELETE FROM idempotency_keys WHERE tenant_id = \(bind: tenant)").run()
    }

    /// WP-K4: /api/version nennt die Schemaversion aus der Datenbank (oder null, wenn keine Tabelle existiert).
    func testVersionEndpointWithDatabase() async throws {
        try await app.test(.GET, "api/version") { res async throws in
            XCTAssertEqual(res.status, .ok)
            _ = try res.content.decode(VersionInfo.self)
        }
    }
}

actor ActorFlag { var value = false; func set() { value = true } }
