import XCTVapor
import Fluent
import SQLKit
import Logging
import NIOCore
import NIOPosix
import NIOSSL
import AsyncHTTPClient
@testable import HubCore
@testable import HubKit
@testable import HubModuleDMS

// WP-PA1R: unabhängiger Sicherheits-Review des Paperless-Imports (vor PA3). Nur synthetische Daten, nur Verbindungen zu Servern in diesem Prozess (127.0.0.1).

// MARK: - SSRF: geprüfter Host == verbundener Host

final class DMSImportReviewURLTests: XCTestCase {
    private func code(_ raw: String, _ policy: PaperlessEndpoint.Policy) -> String? {
        do { _ = try PaperlessEndpoint.parse(raw, policy: policy); return nil } catch let e as ImportError { return e.code } catch { return "other" }
    }

    /// AK-PA1R-1: Der geprüfte Host muss derselbe sein, zu dem verbunden wird. Prozentkodierte oder nicht als ASCII geschriebene Hosts und nicht kanonische
    /// IP-Schreibweisen werden abgelehnt (sie bedeuten für Prüfung und HTTP-Client Verschiedenes), auch wenn interne Ziele erlaubt sind.
    func testAKPA1R_1_ambiguousHostsAreRejected() {
        var home = PaperlessEndpoint.Policy(); home.allowInternalTargets = true
        let ambiguous = [
            "https://127.0.0.1%23.import.example.org",                 // '#': Client verbindet zu 127.0.0.1
            "https://127.0.0.1%2F.import.example.org",                 // '/'
            "https://127.0.0.1%3F.import.example.org",                 // '?'
            "https://127.0.0.1%3A8443%2F.import.example.org",          // Port im Host
            "https://a.example.org%3A80%40127.0.0.1",                  // '@': Zugangsdaten + anderer Host
            "https://x%40127.0.0.1",
            "https://%31%32%37.0.0.1",
            "https://paperless%2Eexample.org",
            "https://b%C3%BCcher.example",                             // geprüft „bücher“, verbunden „xn--…“
            "https://%EF%BC%91%EF%BC%92%EF%BC%97.0.0.1",               // Vollbreiten-Ziffern -> 127.0.0.1
        ]
        for raw in ambiguous {
            XCTAssertNotNil(code(raw, PaperlessEndpoint.Policy()), raw)
            XCTAssertEqual(code(raw, home), "invalid_url", raw)
        }
        // IPv4 nur kanonisch: inet_aton liest führende Nullen oktal, andere Parser dezimal (macOS: `0127.0.0.1` verbindet zu 127.0.0.1)
        for raw in ["https://0127.0.0.1", "https://010.0.0.1", "https://0x08.8.8.8", "https://134744072", "https://8.8.2056"] {
            XCTAssertEqual(code(raw, PaperlessEndpoint.Policy()), "invalid_url", raw)
            XCTAssertEqual(code(raw, home), "invalid_url", raw)
        }
        // interne Ziele in anderer Schreibweise melden ohne Erlaubnis weiter den bisherigen Code
        XCTAssertEqual(code("https://127.1", PaperlessEndpoint.Policy()), "host_not_allowed")
        XCTAssertEqual(code("https://0x7f000001", PaperlessEndpoint.Policy()), "host_not_allowed")
    }

    /// AK-PA1R-1: Für jede angenommene Adresse liest der Parser des HTTP-Clients genau den geprüften Host (sonst greift die festgelegte IP nicht).
    func testAKPA1R_1_acceptedURLsKeepTheCheckedHost() throws {
        let accepted = ["https://paperless.example.org", "https://PaperLess.Example.org.:8443/pl/", "https://xn--bcher-kva.example", "https://my_host.example.org",
                        "https://8.8.8.8:8443", "https://[2606:4700::1111]", "https://[2606:4700::1111]:8443/x"]
        let brackets = CharacterSet(charactersIn: "[]")
        for raw in accepted {
            let e = try PaperlessEndpoint.parse(raw, policy: PaperlessEndpoint.Policy())
            let used = try XCTUnwrap(URL(string: e.base + "/api/tags/")?.host, raw)
            XCTAssertEqual(used.trimmingCharacters(in: brackets), e.host.trimmingCharacters(in: brackets), raw)
        }
    }

    /// AK-PA1R-1: Nachweis am Netz. Der Name „löst öffentlich auf“ (Resolver des Tests, wie ein DNS-Server des Angreifers), interne Ziele sind gesperrt;
    /// trotzdem darf keine Verbindung zu einem Dienst auf 127.0.0.1 entstehen.
    func testAKPA1R_1_noConnectionToLoopbackPastTheTargetCheck() async throws {
        let listener = try await CountingListener.make()
        addTeardownBlock { await listener.stop() }
        var policy = PaperlessEndpoint.Policy()
        policy.resolver = { _ in [.v4([93, 184, 216, 34])] }
        var raws = ["https://127.0.0.1%3A\(listener.port)%2F.import.example.org", "https://x%40127.0.0.1:\(listener.port)"]
        #if canImport(Darwin)
        raws.append("https://0127.0.0.1:\(listener.port)")   // nur macOS: dort liest der Connect die führende Null dezimal (unter Linux ginge er nach außen)
        #endif
        for raw in raws {
            do {
                let endpoint = try PaperlessEndpoint.parse(raw, policy: policy)
                let pinned = try await PaperlessEndpoint.vetTarget(endpoint, policy: policy)
                let client = PaperlessAPISource.makeClient(host: endpoint.host, pinnedIP: pinned)
                let source = PaperlessAPISource(endpoint: endpoint, token: "synthetic-token", tempRoot: FileManager.default.temporaryDirectory, client: client)
                _ = try? await source.references()
                try await client.shutdown()
            } catch is ImportError {}   // abgelehnt: gut
            try await Task.sleep(for: .milliseconds(200))
            XCTAssertEqual(listener.connections, 0, "Verbindung zu 127.0.0.1 trotz Zielprüfung: \(raw)")
        }
    }
}

/// TCP-Server auf 127.0.0.1, der nur Verbindungen zählt und sie sofort schließt.
final class CountingListener: @unchecked Sendable {
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock(); private var n = 0
        var value: Int { lock.lock(); defer { lock.unlock() }; return n }
        func hit() { lock.lock(); n += 1; lock.unlock() }
    }
    private let channel: any Channel
    private let counter: Counter
    var port: Int { channel.localAddress!.port! }
    var connections: Int { counter.value }
    private init(_ channel: any Channel, _ counter: Counter) { self.channel = channel; self.counter = counter }
    static func make() async throws -> CountingListener {
        let counter = Counter()
        let channel = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .childChannelInitializer { child in counter.hit(); return child.close() }
            .bind(host: "127.0.0.1", port: 0).get()
        return CountingListener(channel, counter)
    }
    func stop() async { try? await channel.close() }
}

// MARK: - TLS bei festgelegter IP

final class DMSImportReviewTLSTests: XCTestCase {
    private func openssl(_ arguments: [String], in dir: URL) throws -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["openssl"] + arguments
        p.currentDirectoryURL = dir
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }

    /// AK-PA1R-2: Der Connect geht an die festgelegte IP, geprüft wird das Zertifikat trotzdem gegen den eingetragenen Namen. Mit einer Test-Zertifizierungsstelle
    /// (nur im Test; im Betrieb gilt allein der System-Speicher) gelingt der passende Name, ein anderer Name scheitert, und ohne diese Stelle scheitert auch der passende.
    func testAKPA1R_2_pinnedConnectVerifiesTheConfiguredName() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("labhub-pa1r-tls-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        try Data("subjectAltName=DNS:paperless.test\nbasicConstraints=CA:FALSE\nextendedKeyUsage=serverAuth\n".utf8).write(to: dir.appendingPathComponent("ext.cnf"))
        guard try openssl(["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", "ca.key", "-out", "ca.pem", "-days", "1", "-subj", "/CN=LabHub Test CA"], in: dir),
              try openssl(["req", "-newkey", "rsa:2048", "-nodes", "-keyout", "leaf.key", "-out", "leaf.csr", "-subj", "/CN=paperless.test"], in: dir),
              try openssl(["x509", "-req", "-in", "leaf.csr", "-CA", "ca.pem", "-CAkey", "ca.key", "-CAcreateserial", "-out", "leaf.pem", "-days", "1", "-extfile", "ext.cnf"], in: dir)
        else { throw XCTSkip("openssl nicht verfuegbar: TLS-Test uebersprungen") }

        let app = try await Application.make(.testing)
        app.http.server.configuration.tlsConfiguration = .makeServerConfiguration(
            certificateChain: try NIOSSLCertificate.fromPEMFile(dir.appendingPathComponent("leaf.pem").path).map { .certificate($0) },
            privateKey: .privateKey(try NIOSSLPrivateKey(file: dir.appendingPathComponent("leaf.key").path, format: .pem)))
        app.get("ok") { _ in "ok" }
        try await app.server.start(address: .hostname("127.0.0.1", port: 0))
        addTeardownBlock { await app.server.shutdown(); try? await app.asyncShutdown() }
        let port = try XCTUnwrap(app.http.server.shared.localAddress?.port)
        let ca = try NIOSSLCertificate.fromPEMFile(dir.appendingPathComponent("ca.pem").path)

        // wie im Betrieb: Einstellungen aus `clientConfiguration`; NIOSSL-Stapel wie unter Linux (MultiThreadedEventLoopGroup)
        var lastError = ""
        func fetch(_ host: String, trustTestCA: Bool) async throws -> Bool {
            var config = PaperlessAPISource.clientConfiguration(host: host, pinnedIP: "127.0.0.1")
            XCTAssertEqual(config.tlsConfiguration?.certificateVerification, .fullVerification)
            XCTAssertEqual(config.tlsConfiguration?.minimumTLSVersion, .tlsv12)
            if trustTestCA { config.tlsConfiguration?.additionalTrustRoots = [.certificates(ca)] }
            config.timeout = .init(connect: .seconds(5), read: .seconds(10))
            let client = HTTPClient(eventLoopGroupProvider: .shared(MultiThreadedEventLoopGroup.singleton), configuration: config)
            do {
                let r = try await client.execute(HTTPClientRequest(url: "https://\(host):\(port)/ok"), timeout: .seconds(8))
                try await client.shutdown()
                return r.status == .ok
            } catch {
                try? await client.shutdown()
                lastError = "\(type(of: error)): \(error)"
                return false
            }
        }
        let matching = try await fetch("paperless.test", trustTestCA: true)
        XCTAssertTrue(matching, "passender Name über die festgelegte IP: \(lastError)")
        let wrong = try await fetch("other.test", trustTestCA: true)
        XCTAssertFalse(wrong, "falscher Name trotz gültiger Kette")
        let untrusted = try await fetch("paperless.test", trustTestCA: false)
        XCTAssertFalse(untrusted, "unbekannte Zertifizierungsstelle")
    }
}

// MARK: - Token und Lauf nach Absturzschleife

final class DMSImportReviewOrphanTests: DMSImportTestBase {
    private func apiRun(_ w: World, port: Int = 9) async throws -> String {
        let r = try await startRun(w, source: ["kind": "api", "base_url": "http://127.0.0.1:\(port)", "token": d6Token], mode: "import")
        XCTAssertEqual(r.status, .accepted, "\(r.json)")
        return r.json["id"] as? String ?? ""
    }

    /// So sieht die Datenbank aus, nachdem der Worker dreimal mitten im Lauf starb (OOM, SIGKILL): Job `running`, Lease abgelaufen, keine Versuche mehr.
    private func crashThreeTimes(_ run: String) async throws {
        try await db.raw("UPDATE jobs SET state = 'running', attempts = 3, lease_owner = 'w-dead', lease_until = now() - interval '1 second' WHERE id = (SELECT job_id FROM dms_imports WHERE id = \(unsafeRaw: "'\(run)'"))").run()
        try await db.raw("UPDATE dms_imports SET state = 'running', started_at = now() WHERE id = \(unsafeRaw: "'\(run)'")").run()
    }

    /// Worker wie im Befehl `worker`: Handler UND Aufräumschritte des Moduls.
    private func worker(_ database: any SQLDatabase, _ name: String) -> JobWorker {
        let sweeps = testModules.flatMap { $0.jobSweeps(environment: [:]).filter { $0.key == DMSImport.kind }.values }
        return JobWorker(db: database, kinds: [DMSImport.kind], handlers: [DMSImport.kind: handler()], leaseSeconds: 30, pollInterval: .milliseconds(50), logger: Logger(label: name), sweeps: sweeps)
    }

    private func state(_ run: String) async throws -> String {
        try await scalar("SELECT concat_ws('|', state, coalesce(error_code, '-'), (secret_enc IS NOT NULL)::text, (finished_at IS NOT NULL)::text) AS v FROM dms_imports WHERE id = '\(run)'", as: String.self)
    }

    /// AK-PA1R-3: Gibt die Job-Verwaltung den Lauf auf (Absturzschleife), endet der Lauf, das Token wird gelöscht, es gibt Bericht und Audit-Eintrag,
    /// und ein neuer Lauf gegen dieselbe Quelle ist wieder möglich. Zwei Worker: genau ein Abschluss.
    func testAKPA1R_3_runOfACrashLoopedJobIsClosedAndTokenRemoved() async throws {
        let w = try await world()
        let id = try await apiRun(w)
        try await crashThreeTimes(id)
        try await aEq(try await state(id), "running|-|true|false")

        let a = worker(db, "pa1r.a"), b = worker(app2.db(.psql) as! any SQLDatabase, "pa1r.b")
        let u1 = Task { await a.run() }, u2 = Task { await b.run() }
        try? await eventually("verwaister Lauf beendet", timeout: 15) { try await self.state(id).hasPrefix("failed|") }
        a.requestShutdown(); b.requestShutdown(); await u1.value; await u2.value

        try await aEq(try await state(id), "failed|worker_lost|false|true")
        try await aEq(try await count("audit_log", where: "action = 'dms.import.failed' AND subject_id = '\(id.uppercased())'") + count("audit_log", where: "action = 'dms.import.failed' AND subject_id = '\(id.lowercased())'"), 1)
        let report = try await call(app1, .GET, imports(w.tenantA) + "/\(id)/report", token: w.alice.token)
        XCTAssertEqual(report.status, .ok, "\(report.json)")
        XCTAssertEqual(report.json["error_code"] as? String, "worker_lost")
        _ = try await apiRun(w)   // vorher: 409 import_already_open, für immer
    }

    /// AK-PA1R-3: Wurde der Abbruch gewünscht, endet der verwaiste Lauf als `cancelled`. Wartende Läufe, laufende Läufe mit gültiger Lease und
    /// abgelaufene Leases mit verbleibenden Versuchen (ein anderer Worker setzt fort) bleiben unberührt.
    func testAKPA1R_3_cancelledOrphanAndHealthyRunsAreTreatedCorrectly() async throws {
        let w = try await world()
        let cancelled = try await apiRun(w, port: 9)
        try await crashThreeTimes(cancelled)
        let c = try await call(app1, .POST, imports(w.tenantA) + "/\(cancelled)/cancel", token: w.alice.token)
        XCTAssertEqual(c.status, .ok, "\(c.json)")
        let alive = try await apiRun(w, port: 10)
        try await crashThreeTimes(alive)
        try await db.raw("UPDATE jobs SET lease_until = now() + interval '1 hour' WHERE id = (SELECT job_id FROM dms_imports WHERE id = \(unsafeRaw: "'\(alive)'"))").run()
        let waiting = try await apiRun(w, port: 11)
        try await db.raw("UPDATE jobs SET run_at = now() + interval '1 hour' WHERE id = (SELECT job_id FROM dms_imports WHERE id = \(unsafeRaw: "'\(waiting)'"))").run()

        let one = worker(db, "pa1r.c")
        let task = Task { await one.run() }
        try? await eventually("abgebrochener verwaister Lauf beendet", timeout: 15) { try await self.state(cancelled).hasPrefix("cancelled|") }
        try await Task.sleep(for: .milliseconds(500))
        one.requestShutdown(); await task.value

        try await aEq(try await state(cancelled), "cancelled|-|false|true")
        try await aEq(try await state(alive), "running|-|true|false")
        try await aEq(try await state(waiting), "queued|-|true|false")
    }
}

// MARK: - `next` der Seitenabfrage

final class DMSImportReviewNextTests: XCTestCase {
    private final class Seen: @unchecked Sendable {
        private let lock = NSLock(); private var pages: [String] = []
        func add(_ p: String) { lock.lock(); pages.append(p); lock.unlock() }
        var all: [String] { lock.lock(); defer { lock.unlock() }; return pages }
    }

    /// AK-PA1R-4: Das Feld `next` der Antwort wird nie als Adresse verwendet (die Seitennummer bildet der Hub selbst): ein Server, der auf einen fremden Host zeigt,
    /// bekommt weder eine Verbindung noch das Token. (Zuvor nur durch Lesen des Codes belegt, `docs/handoff/WP-PA1.md`.)
    func testAKPA1R_4_nextLinkIsNeverFollowed() async throws {
        let foreign = try await CountingListener.make()
        addTeardownBlock { await foreign.stop() }
        let seen = Seen()
        let app = try await Application.make(.testing)
        app.get("api", "**") { req -> Response in
            let page = req.query[String.self, at: "page"] ?? "-"
            seen.add(page)
            var headers = HTTPHeaders(); headers.contentType = .json
            let body = page == "1" ? "{\"count\":2,\"next\":\"http://127.0.0.1:\(foreign.port)/steal\",\"results\":[{\"id\":1,\"name\":\"eins\"}]}" : "{\"count\":2,\"next\":null,\"results\":[]}"
            return Response(status: .ok, headers: headers, body: .init(string: body))
        }
        try await app.server.start(address: .hostname("127.0.0.1", port: 0))
        addTeardownBlock { await app.server.shutdown(); try? await app.asyncShutdown() }
        var policy = PaperlessEndpoint.Policy(); policy.insecureDev = true
        let endpoint = try PaperlessEndpoint.parse("http://127.0.0.1:\(try XCTUnwrap(app.http.server.shared.localAddress?.port))", policy: policy)
        let client = PaperlessAPISource.makeClient()
        let source = PaperlessAPISource(endpoint: endpoint, token: "synthetic-token", tempRoot: FileManager.default.temporaryDirectory, client: client)
        let refs = try await source.references()
        try await client.shutdown()
        XCTAssertEqual(refs.tags.count, 1)
        XCTAssertTrue(seen.all.contains("2"), "die zweite Seite wird mit selbst gebildeter Seitennummer abgefragt")
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(foreign.connections, 0, "`next` darf nicht verfolgt werden")
    }
}
