import XCTVapor
@testable import HubKit

/// WP-H9: Auslieferung der PWA durch das Backend (synthetisches Verzeichnis, keine Datenbank nötig).
final class PWAStaticTests: XCTestCase {
    static let indexHTML = """
        <!doctype html><html><head><title>t</title><link href="/_app/immutable/entry/start.abc.js" rel="modulepreload"></head>
        <body><div><script>{ import("/_app/immutable/entry/start.abc.js"); }</script></div></body></html>
        """

    private func makeDir() throws -> String {
        let dir = NSTemporaryDirectory() + "lh-pwa-\(UUID().uuidString)"
        let fm = FileManager.default
        try fm.createDirectory(atPath: dir + "/_app/immutable/entry", withIntermediateDirectories: true)
        try Self.indexHTML.write(toFile: dir + "/index.html", atomically: true, encoding: .utf8)
        try "export const x = 1;".write(toFile: dir + "/_app/immutable/entry/start.abc.js", atomically: true, encoding: .utf8)
        try "{\"version\":\"0\"}".write(toFile: dir + "/version.json", atomically: true, encoding: .utf8)
        try "SECRET-OUTSIDE".write(toFile: dir + "-secret.txt", atomically: true, encoding: .utf8)
        try fm.createSymbolicLink(atPath: dir + "/link.txt", withDestinationPath: dir + "-secret.txt")
        return dir
    }

    private func cleanup(_ dir: String) {
        try? FileManager.default.removeItem(atPath: dir)
        try? FileManager.default.removeItem(atPath: dir + "-secret.txt")
    }

    private func makeApp(_ env: [String: String]) async throws -> Application {
        let app = try await Application.make(.testing)
        try configure(app, environment: env)
        return app
    }

    func testRootAndDeepLinkServeIndexWithHeaders() async throws {
        let dir = try makeDir()
        defer { cleanup(dir) }
        let app = try await makeApp(["PWA_DIR": dir])
        defer { Task { try? await app.asyncShutdown() } }
        for path in ["/", "/dms/inbox", "/dms/documents/0f0f0f0f-0000-4000-8000-000000000000"] {
            try await app.test(.GET, path) { res async in
                XCTAssertEqual(res.status, .ok, path)
                XCTAssertEqual(res.body.string, Self.indexHTML, path)
                XCTAssertEqual(res.headers.first(name: .cacheControl), "no-cache", path)
                XCTAssertTrue(res.headers.first(name: .contentType)?.hasPrefix("text/html") ?? false)
            }
        }
    }

    func testSecurityHeadersAndCSP() async throws {
        let dir = try makeDir()
        defer { cleanup(dir) }
        let app = try await makeApp(["PWA_DIR": dir])
        defer { Task { try? await app.asyncShutdown() } }
        try await app.test(.GET, "/") { res async in
            let csp = res.headers.first(name: "Content-Security-Policy") ?? ""
            for part in ["default-src 'self'", "img-src 'self' blob: data:", "frame-src 'self' blob:", "connect-src 'self'", "object-src 'none'", "frame-ancestors 'none'"] {
                XCTAssertTrue(csp.contains(part), part)
            }
            XCTAssertFalse(csp.contains("unsafe-eval"))
            XCTAssertFalse(csp.contains("script-src 'self' 'unsafe-inline'"))
            let hash = PWAStaticMiddleware.inlineScriptHashes(Self.indexHTML)
            XCTAssertEqual(hash.count, 1)
            XCTAssertTrue(csp.contains("'sha256-\(hash[0])'"))
            XCTAssertEqual(res.headers.first(name: "X-Content-Type-Options"), "nosniff")
            XCTAssertEqual(res.headers.first(name: "Referrer-Policy"), "same-origin")
            XCTAssertNotNil(res.headers.first(name: "Permissions-Policy"))
            XCTAssertNil(res.headers.first(name: "Strict-Transport-Security"))
            XCTAssertNotNil(res.headers.first(name: "X-Request-Id"))
        }
    }

    func testHSTSOnlyWhenConfigured() async throws {
        let dir = try makeDir()
        defer { cleanup(dir) }
        let app = try await makeApp(["PWA_DIR": dir, "PWA_HSTS_MAX_AGE": "31536000"])
        defer { Task { try? await app.asyncShutdown() } }
        try await app.test(.GET, "/") { res async in
            XCTAssertEqual(res.headers.first(name: "Strict-Transport-Security"), "max-age=31536000")
        }
    }

    func testCacheHeadersForAssets() async throws {
        let dir = try makeDir()
        defer { cleanup(dir) }
        let app = try await makeApp(["PWA_DIR": dir])
        defer { Task { try? await app.asyncShutdown() } }
        try await app.test(.GET, "/_app/immutable/entry/start.abc.js") { res async in
            XCTAssertEqual(res.status, .ok)
            XCTAssertEqual(res.body.string, "export const x = 1;")
            XCTAssertEqual(res.headers.first(name: .cacheControl), "public, max-age=31536000, immutable")
            XCTAssertEqual(res.headers.first(name: "X-Content-Type-Options"), "nosniff")
        }
        try await app.test(.GET, "/version.json") { res async in
            XCTAssertEqual(res.status, .ok)
            XCTAssertEqual(res.headers.first(name: .cacheControl), "no-cache")
        }
        try await app.test(.GET, "/index.html") { res async in
            XCTAssertEqual(res.headers.first(name: .cacheControl), "no-cache")
        }
        var etag = ""
        try await app.test(.GET, "/") { res async in etag = res.headers.first(name: .eTag) ?? "" }
        XCTAssertFalse(etag.isEmpty)
        try await app.test(.GET, "/", headers: ["If-None-Match": etag]) { res async in XCTAssertEqual(res.status, .notModified) }
        try await app.test(.HEAD, "/dms/inbox") { res async in XCTAssertEqual(res.status, .ok) }
    }

    func testApiNeverFallsBackToIndex() async throws {
        let dir = try makeDir()
        defer { cleanup(dir) }
        let app = try await makeApp(["PWA_DIR": dir])
        defer { Task { try? await app.asyncShutdown() } }
        for path in ["/api/v1/nope", "/api/v1/tenants/x/dms/inbox", "/api", "/api/", "/API/v1/nope"] {
            try await app.test(.GET, path) { res async in
                XCTAssertEqual(res.status, .notFound, path)
                XCTAssertFalse(res.body.string.contains("<html"), path)
                XCTAssertTrue(res.headers.first(name: .contentType)?.contains("problem+json") ?? false, path)
                XCTAssertNil(res.headers.first(name: "Content-Security-Policy"), path)
            }
        }
        try await app.test(.GET, "/health") { res async in
            XCTAssertEqual(res.status, .ok)
            XCTAssertNil(res.headers.first(name: "Content-Security-Policy"))
        }
        try await app.test(.GET, "/ready") { res async in XCTAssertEqual(res.status, .ok) }
        try await app.test(.POST, "/dms/inbox") { res async in XCTAssertEqual(res.status, .notFound) }
    }

    func testPathTraversalIsRejected() async throws {
        let dir = try makeDir()
        defer { cleanup(dir) }
        let app = try await makeApp(["PWA_DIR": dir])
        defer { Task { try? await app.asyncShutdown() } }
        let leaf = (dir as NSString).lastPathComponent
        let attempts = ["/../\(leaf)-secret.txt", "/%2e%2e/\(leaf)-secret.txt", "/%2E%2E%2F\(leaf)-secret.txt", "/_app/../../\(leaf)-secret.txt",
                        "/..%5c\(leaf)-secret.txt", "/%2e%2e%5c%2e%2e%5cetc/passwd", "/..\\..\\etc\\passwd", "/%252e%252e/etc/passwd",
                        "/link.txt", "/.git/config", "/etc/passwd.txt", "/_app/immutable/%2e%2e/%2e%2e/index.html.bak"]
        for path in attempts {
            try await app.test(.GET, path) { res async in
                XCTAssertFalse(res.body.string.contains("SECRET-OUTSIDE"), path)
                XCTAssertFalse(res.body.string.contains("root:"), path)
                XCTAssertTrue(res.status == .notFound || res.status == .badRequest || res.body.string == Self.indexHTML, "\(path) -> \(res.status)")
            }
        }
        try await app.test(.GET, "/link.txt") { res async in XCTAssertEqual(res.status, .notFound) }
    }

    func testMissingAssetWithExtensionIs404() async throws {
        let dir = try makeDir()
        defer { cleanup(dir) }
        let app = try await makeApp(["PWA_DIR": dir])
        defer { Task { try? await app.asyncShutdown() } }
        try await app.test(.GET, "/_app/immutable/missing.js") { res async in XCTAssertEqual(res.status, .notFound) }
    }

    func testDisabledAndMisconfigured() async throws {
        let dir = try makeDir()
        defer { cleanup(dir) }
        let off = try await makeApp(["PWA_DIR": dir, "PWA_ENABLED": "false"])
        defer { Task { try? await off.asyncShutdown() } }
        try await off.test(.GET, "/") { res async in XCTAssertEqual(res.status, .notFound) }
        XCTAssertNil(try PWAConfig.fromEnvironment([:]))
        XCTAssertThrowsError(try PWAConfig.fromEnvironment(["PWA_DIR": dir + "-gibt-es-nicht"]))
        XCTAssertThrowsError(try PWAConfig.fromEnvironment(["PWA_DIR": dir, "PWA_ENABLED": "vielleicht"]))
        XCTAssertThrowsError(try PWAConfig.fromEnvironment(["PWA_DIR": dir, "PWA_HSTS_MAX_AGE": "x"]))
    }

    /// ObjectStoreConfig.validate() läuft in configure(): Fehlkonfiguration bricht den Start ab.
    func testConfigureValidatesObjectStore() async throws {
        let app = try await Application.make(.testing)
        defer { Task { try? await app.asyncShutdown() } }
        XCTAssertThrowsError(try configure(app, environment: ["OBJECT_STORE": "fs"]))
        let app2 = try await Application.make(.testing)
        defer { Task { try? await app2.asyncShutdown() } }
        XCTAssertThrowsError(try configure(app2, environment: ["OBJECT_STORE": "s3"]))
    }
}
