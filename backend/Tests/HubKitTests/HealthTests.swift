import XCTVapor
@testable import HubKit

final class HealthTests: XCTestCase {
    func testHealthReturnsOK() async throws {
        let app = try await Application.make(.testing)
        defer { Task { try? await app.asyncShutdown() } }
        try configure(app)
        try await app.test(.GET, "health") { response async in
            XCTAssertEqual(response.status, .ok)
            XCTAssertTrue(response.body.string.contains("ok"))
        }
    }

    func testReadyReturns503WhenNotReady() async throws {
        let app = try await Application.make(.testing)
        defer { Task { try? await app.asyncShutdown() } }
        app.hubReadiness = Readiness(check: { false })
        try configure(app)
        try await app.test(.GET, "ready") { response async in
            XCTAssertEqual(response.status, .serviceUnavailable)
        }
    }
}

final class ConfigTests: XCTestCase {
    func testSecretFileTakesPrecedenceAndTrims() throws {
        let path = NSTemporaryDirectory() + "lh-test-secret-\(UUID().uuidString)"
        try "synthetic-secret\n".write(toFile: path, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: path) }
        let c = try XCTUnwrap(HubConfig.fromEnvironment(["DB_HOST": "h", "DB_PASSWORD": "plain", "DB_PASSWORD_FILE": path, "DB_TLS": "disable", "AUTO_MIGRATE": "true"]))
        XCTAssertEqual(c.dbPassword, "synthetic-secret")
        XCTAssertEqual(c.dbTLS, .disable)
        XCTAssertTrue(c.autoMigrate)
        XCTAssertEqual(c.dbPort, 5432)
    }
    func testMissingHostMeansNoDatabase() throws { XCTAssertNil(try HubConfig.fromEnvironment([:])) }
    func testBadTLSFails() { XCTAssertThrowsError(try HubConfig.fromEnvironment(["DB_HOST": "h", "DB_PASSWORD": "p", "DB_TLS": "x"])) }
}
