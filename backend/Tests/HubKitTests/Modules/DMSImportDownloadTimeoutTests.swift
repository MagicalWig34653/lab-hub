import XCTVapor
import NIOCore
import NIOPosix
import AsyncHTTPClient
@testable import HubCore
@testable import HubKit
@testable import HubModuleDMS

// WP-PA3V (Karte B337F781): Zeitlimit beim Download großer Dateien. Vermutung aus dem PA1-Review: `client.execute(req, timeout: .seconds(120))` begrenze die GANZE
// Anfrage einschließlich des Datenstroms, ein Scan auf langsamer Leitung brächte `source_unreachable`. Messung (27./28.11.2026, async-http-client 1.36.2): trifft nicht zu,
// die Frist endet mit dem Antwortkopf; den Datenstrom begrenzt nur die Leerlauffrist (`read`, 60 s). Diese Tests halten das fest (Gegenprobe, nicht Fix). Nur ein Server in
// diesem Prozess (127.0.0.1), erfundene Bytes; Fristen in Sekunden statt Minuten, das Verhalten ist dasselbe.

final class DMSImportDownloadTimeoutTests: XCTestCase {
    private let chunk = 64 * 1024

    /// Server wie die Download-Route von Paperless: `chunks` Blöcke zu 64 KiB, zwischen den Blöcken `gap` Wartezeit; mit `stallAfter` bleibt er nach so vielen Blöcken stehen.
    private func makeSource(chunks: Int, gap: Duration, stallAfter: Int? = nil, read: TimeAmount = .seconds(60), tune: (inout PaperlessAPISource) -> Void) async throws -> PaperlessAPISource {
        let app = try await Application.make(.testing)
        let size = chunks * chunk
        let n = chunk
        app.get("api", "documents", ":id", "download") { _ -> Response in
            var headers = HTTPHeaders()
            headers.contentType = .pdf
            headers.replaceOrAdd(name: .contentLength, value: String(size))
            // Wie `DMSUpload`: der Strom endet immer mit `.end` oder `.error` (sonst bricht Vapor im Debug-Build mit einer Assertion ab, wenn der Client vorher trennt).
            return Response(status: .ok, headers: headers, body: .init(asyncStream: { writer in
                do {
                    for i in 0..<chunks {
                        if let stall = stallAfter, i == stall { try await Task.sleep(for: .seconds(5)) }
                        try await writer.write(.buffer(ByteBuffer(repeating: UInt8(i % 251), count: n)))
                        try await Task.sleep(for: gap)
                    }
                    try await writer.write(.end)
                } catch { try? await writer.write(.error(error)) }
            }))
        }
        try await app.server.start(address: .hostname("127.0.0.1", port: 0))
        addTeardownBlock { await app.server.shutdown(); try? await app.asyncShutdown() }
        var policy = PaperlessEndpoint.Policy(); policy.insecureDev = true
        let endpoint = try PaperlessEndpoint.parse("http://127.0.0.1:\(try XCTUnwrap(app.http.server.shared.localAddress?.port))", policy: policy)
        var config = PaperlessAPISource.clientConfiguration(host: nil, pinnedIP: nil)
        config.timeout = .init(connect: .seconds(5), read: read)
        let client = HTTPClient(eventLoopGroupProvider: .shared(MultiThreadedEventLoopGroup.singleton), configuration: config)
        addTeardownBlock { try? await client.shutdown() }
        var source = PaperlessAPISource(endpoint: endpoint, token: "synthetic-token", tempRoot: FileManager.default.temporaryDirectory, client: client)
        tune(&source)
        return source
    }

    private func code(_ source: PaperlessAPISource) async -> String? {
        do {
            let file = try await source.materialize(PLDoc(id: 1), .original, maxBytes: 100 * 1024 * 1024)
            if let file { try? FileManager.default.removeItem(at: file.url) }
            return nil
        } catch let e as ImportError { return e.code } catch { return "other:\(error)" }
    }

    /// AK-PA3V-1: Läuft der Datenstrom länger als die Frist für die Anfrage (hier 2 s gegen 4 s Übertragung), wird die Datei trotzdem vollständig geladen:
    /// Die Frist für JSON-Anfragen gilt nicht für den Download einer großen Datei.
    func testAKPA3V_1_longDownloadIsNotCutOffByTheRequestTimeout() async throws {
        let source = try await makeSource(chunks: 8, gap: .milliseconds(500)) { $0.requestTimeout = .seconds(2) }
        let file = try await source.materialize(PLDoc(id: 1), .original, maxBytes: 100 * 1024 * 1024)
        let f = try XCTUnwrap(file)
        addTeardownBlock { try? FileManager.default.removeItem(at: f.url) }
        XCTAssertEqual(f.size, Int64(8 * chunk))
    }

    /// AK-PA3V-2: Bleibt der Server mitten im Strom stehen, endet der Download nach der Leerlauffrist des Clients (hier 1 s), nicht erst nach der Gesamtfrist.
    func testAKPA3V_2_stalledDownloadEndsAfterTheIdleTimeout() async throws {
        let source = try await makeSource(chunks: 4, gap: .milliseconds(50), stallAfter: 2, read: .seconds(1)) { _ in }
        let started = ContinuousClock.now
        let c = await code(source)
        XCTAssertEqual(c, "source_unreachable")
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(15))
    }
}
