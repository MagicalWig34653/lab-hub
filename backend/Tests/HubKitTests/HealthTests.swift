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
