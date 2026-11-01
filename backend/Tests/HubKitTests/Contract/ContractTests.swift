import XCTVapor
@testable import HubKit

/// Minimaler Leser für `contracts/openapi.yaml` (ohne YAML-Abhängigkeit): Pfade auf Einrückung 2, Methoden auf Einrückung 4.
enum OpenAPIContract {
    static var url: URL {
        // backend/Tests/HubKitTests/Contract/ContractTests.swift -> Repo-Wurzel
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("contracts/openapi.yaml")
    }
    static func lines() throws -> [String] { try String(contentsOf: url, encoding: .utf8).components(separatedBy: "\n") }

    /// "GET /health"-Einträge
    static func operations() throws -> Set<String> {
        var result = Set<String>(), inPaths = false, path: String?
        let methods: Set<String> = ["get", "put", "post", "delete", "patch", "head", "options"]
        for line in try lines() {
            if line.hasPrefix("paths:") { inPaths = true; continue }
            if inPaths, let f = line.first, f != " ", f != "#" { break }
            guard inPaths else { continue }
            if line.hasPrefix("  /"), line.hasSuffix(":") { path = String(line.dropFirst(2).dropLast()) }
            else if line.hasPrefix("    "), !line.hasPrefix("     "), line.hasSuffix(":"), let p = path {
                let m = line.trimmingCharacters(in: .whitespaces).dropLast().lowercased()
                if methods.contains(String(m)) { result.insert("\(m.uppercased()) \(p)") }
            }
        }
        return result
    }

    /// Werte der Aufzählung unter `schemas.Problem.properties.code.enum`.
    static func problemCodes() throws -> Set<String> {
        var result = Set<String>(), inProblem = false, inEnum = false, inSchemas = false
        for line in try lines() {
            if line.hasPrefix("  schemas:") { inSchemas = true; continue }
            if inSchemas, line.hasPrefix("    Problem:") { inProblem = true; continue }
            if inProblem, line.hasPrefix("    "), !line.hasPrefix("     ") { break }
            guard inProblem else { continue }
            if line.contains("enum:") { inEnum = true; continue }
            if inEnum {
                let t = line.trimmingCharacters(in: .whitespaces)
                if t.hasPrefix("- ") { result.insert(String(t.dropFirst(2))) } else { break }
            }
        }
        return result
    }

    /// Pflichtfelder von `Problem` (Zeile `required: [a, b]`).
    static func problemRequired() throws -> Set<String> {
        var inProblem = false, inSchemas = false
        for line in try lines() {
            if line.hasPrefix("  schemas:") { inSchemas = true; continue }
            if inSchemas, line.hasPrefix("    Problem:") { inProblem = true; continue }
            if inProblem, line.contains("required:") {
                let inner = line.split(separator: "[").last?.dropLast() ?? ""
                return Set(inner.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
            }
        }
        return []
    }

    static func serverOperations(_ app: Application) -> Set<String> {
        var result = Set<String>()
        for route in app.routes.all where route.method != .HEAD {
            let path = "/" + route.path.map { "\($0)" }.map { $0.hasPrefix(":") ? "{\($0.dropFirst())}" : $0 }.joined(separator: "/")
            result.insert("\(route.method.rawValue) \(path)")
        }
        return result
    }

    static func diff(documented: Set<String>, actual: Set<String>) -> (missingInContract: Set<String>, missingInServer: Set<String>) {
        (actual.subtracting(documented), documented.subtracting(actual))
    }
}

final class ContractTests: XCTestCase {
    private func makeApp() async throws -> Application {
        let app = try await Application.make(.testing)
        try configure(app)
        return app
    }

    /// AK-K4-1: Routen und Vertrag stimmen überein.
    func testAKK4_1_RoutesMatchContract() async throws {
        let app = try await makeApp(); defer { Task { try? await app.asyncShutdown() } }
        let d = OpenAPIContract.diff(documented: try OpenAPIContract.operations(), actual: OpenAPIContract.serverOperations(app))
        XCTAssertEqual(d.missingInContract, [], "Routen ohne Vertragseintrag")
        XCTAssertEqual(d.missingInServer, [], "Vertragseinträge ohne Route")
        XCTAssertTrue(try OpenAPIContract.operations().isSuperset(of: ["GET /health", "GET /ready", "GET /api/version"]))
    }

    /// AK-K4-1: eine undokumentierte Route lässt den Vergleich fehlschlagen (der Test kann also rot werden).
    func testAKK4_1_UndocumentedRouteIsDetected() async throws {
        let app = try await makeApp(); defer { Task { try? await app.asyncShutdown() } }
        app.get("api", "v1", "tenants", ":tenant", "secret") { _ in "x" }
        let d = OpenAPIContract.diff(documented: try OpenAPIContract.operations(), actual: OpenAPIContract.serverOperations(app))
        XCTAssertEqual(d.missingInContract, ["GET /api/v1/tenants/{tenant}/secret"])
    }

    /// AK-K4-1: eine entfernte Route (nur im Vertrag) wird erkannt.
    func testAKK4_1_MissingRouteIsDetected() throws {
        // WP-K1: der Vertrag wächst mit jedem WP; "actual" ist daher der dokumentierte Stand ohne die erfundene Route.
        let d = OpenAPIContract.diff(documented: try OpenAPIContract.operations().union(["GET /nope"]),
                                     actual: try OpenAPIContract.operations())
        XCTAssertEqual(d.missingInServer, ["GET /nope"])
    }

    private func assertProblem(_ res: XCTHTTPResponse, status: HTTPStatus, code: String, file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(res.status, status, file: file, line: line)
        XCTAssertEqual(res.headers.contentType?.serialize(), "application/problem+json", file: file, line: line)
        let p = try res.content.decode(ProblemDetails.self)
        XCTAssertEqual(p.code, code, file: file, line: line)
        XCTAssertEqual(p.status, Int(status.code), file: file, line: line)
        XCTAssertEqual(p.title, ProblemCatalog.message(code), file: file, line: line)
        XCTAssertEqual(p.type, "https://hub.example.org/errors/\(code)", file: file, line: line)
        XCTAssertFalse(p.request_id.isEmpty, file: file, line: line)
        XCTAssertEqual(res.headers.first(name: "X-Request-Id"), p.request_id, file: file, line: line)
        // Schema aus dem Vertrag: Pflichtfelder vorhanden, Code in der Aufzählung
        let json = try JSONSerialization.jsonObject(with: Data(buffer: res.body)) as? [String: Any] ?? [:]
        for field in try OpenAPIContract.problemRequired() { XCTAssertNotNil(json[field], "Pflichtfeld \(field)", file: file, line: line) }
        XCTAssertTrue(try OpenAPIContract.problemCodes().contains(p.code), "Code \(p.code) nicht im Vertrag", file: file, line: line)
    }

    /// AK-K4-2: jede Fehlerantwort entspricht dem Problem-Schema.
    func testAKK4_2_ErrorResponsesMatchSchema() async throws {
        let app = try await makeApp(); defer { Task { try? await app.asyncShutdown() } }
        app.get("t", "hub") { _ -> String in throw HubError(.conflict, "conflict", detail: "synthetic", errors: [FieldError(field: "name", code: "required")]) }
        app.get("t", "abort") { _ -> String in throw Abort(.forbidden) }
        app.get("t", "boom") { _ -> String in struct Secret: Error {}; throw Secret() }
        app.get("t", "abort500") { _ -> String in throw Abort(.internalServerError, reason: "db password leaked") }
        app.get("t", "page") { req -> String in _ = try HubPageRequest(req); return "ok" }
        try await app.test(.GET, "does/not/exist") { res async throws in try assertProblem(res, status: .notFound, code: "not_found") }
        try await app.test(.POST, "health") { res async throws in try assertProblem(res, status: .notFound, code: "not_found") }
        try await app.test(.GET, "t/hub") { res async throws in
            try assertProblem(res, status: .conflict, code: "conflict")
            let p = try res.content.decode(ProblemDetails.self)
            XCTAssertEqual(p.errors, [FieldError(field: "name", code: "required")])
            XCTAssertEqual(p.detail, "synthetic")
        }
        try await app.test(.GET, "t/abort") { res async throws in try assertProblem(res, status: .forbidden, code: "forbidden") }
        try await app.test(.GET, "t/boom") { res async throws in try assertProblem(res, status: .internalServerError, code: "internal_error") }
        try await app.test(.GET, "t/abort500") { res async throws in
            try assertProblem(res, status: .internalServerError, code: "internal_error")
            XCTAssertFalse(res.body.string.contains("password"), "5xx darf keine Interna nennen")
        }
        try await app.test(.GET, "t/page?limit=0") { res async throws in try assertProblem(res, status: .badRequest, code: "invalid_limit") }
        try await app.test(.GET, "t/page?limit=201") { res async throws in try assertProblem(res, status: .badRequest, code: "invalid_limit") }
        try await app.test(.GET, "t/page?cursor=%25%25") { res async throws in try assertProblem(res, status: .badRequest, code: "invalid_cursor") }
    }

    /// AK-K4-2: auch /ready (503) liefert Problem Details; alle Katalogcodes stehen im Vertrag und haben deutsche Meldungen.
    func testAKK4_2_ReadyFailureAndCatalogMatchContract() async throws {
        let app = try await Application.make(.testing); defer { Task { try? await app.asyncShutdown() } }
        app.hubReadiness = Readiness(check: { false })
        try configure(app)
        try await app.test(.GET, "ready") { res async throws in try assertProblem(res, status: .serviceUnavailable, code: "service_unavailable") }
        XCTAssertEqual(Set(ProblemCatalog.codes), try OpenAPIContract.problemCodes())
        for c in ProblemCatalog.codes { XCTAssertTrue(ProblemCatalog.message(c).hasSuffix("."), "Meldung \(c)") }
    }

    /// AK-K4-2: Idempotency-Key fehlt = Problem 400 (ohne Datenbank prüfbar).
    func testAKK4_2_MissingIdempotencyKeyIsProblem() async throws {
        let app = try await makeApp(); defer { Task { try? await app.asyncShutdown() } }
        app.grouped(IdempotencyMiddleware()).post("api", "v1", "tenants", ":tenant", "x") { _ in "x" }
        try await app.test(.POST, "api/v1/tenants/\(UUID())/x") { res async throws in try assertProblem(res, status: .badRequest, code: "idempotency_key_required") }
    }

    /// WP-K4: X-Request-Id wird erzeugt bzw. gültig übernommen, ungültig ersetzt.
    func testRequestIdGeneratedAdoptedAndSanitized() async throws {
        let app = try await makeApp(); defer { Task { try? await app.asyncShutdown() } }
        try await app.test(.GET, "health") { res async throws in XCTAssertNotNil(UUID(uuidString: res.headers.first(name: "X-Request-Id") ?? "")) }
        try await app.test(.GET, "health", headers: ["X-Request-Id": "abc-123_x.y"]) { res async throws in XCTAssertEqual(res.headers.first(name: "X-Request-Id"), "abc-123_x.y") }
        try await app.test(.GET, "health", headers: ["X-Request-Id": "bad id\u{7f}!"]) { res async throws in
            XCTAssertNotEqual(res.headers.first(name: "X-Request-Id"), "bad id\u{7f}!")
            XCTAssertNotNil(UUID(uuidString: res.headers.first(name: "X-Request-Id") ?? ""))
        }
        try await app.test(.GET, "nope", headers: ["X-Request-Id": "keep-me"]) { res async throws in
            XCTAssertEqual(res.headers.first(name: "X-Request-Id"), "keep-me")
            XCTAssertEqual(try res.content.decode(ProblemDetails.self).request_id, "keep-me")
        }
    }

    /// WP-K4: Versionsendpunkt (ohne Datenbank: schema = null).
    func testVersionEndpoint() async throws {
        let app = try await makeApp(); defer { Task { try? await app.asyncShutdown() } }
        try await app.test(.GET, "api/version") { res async throws in
            XCTAssertEqual(res.status, .ok)
            let v = try res.content.decode(VersionInfo.self)
            XCTAssertEqual(v.api, "1"); XCTAssertEqual(v.server, HubVersion.server); XCTAssertNil(v.schema)
        }
    }

    /// AK-K4-3 (Teil): Cursor-Roundtrip und Page-Hülle.
    func testAKK4_3_CursorRoundtripAndEnvelope() throws {
        let c = PageCursor(createdAt: "2026-11-01 10:00:00.123456+00", id: UUID())
        XCTAssertEqual(try PageCursor.decode(c.encoded()), c)
        XCTAssertFalse(c.encoded().contains("=") || c.encoded().contains("+") || c.encoded().contains("/"))
        XCTAssertThrowsError(try PageCursor.decode("%%%"))
        let rows = (0..<4).map { PageCursor(createdAt: "t\($0)", id: UUID()) }
        let withMore = HubPage(fetched: rows, limit: 3, cursorOf: { $0 })
        XCTAssertEqual(withMore.items.count, 3)
        XCTAssertEqual(try withMore.next_cursor.map(PageCursor.decode), rows[2])
        XCTAssertNil(HubPage(fetched: Array(rows.prefix(3)), limit: 3, cursorOf: { $0 }).next_cursor)
    }
}

extension PageCursor: Content {}
