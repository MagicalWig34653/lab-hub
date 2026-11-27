import XCTVapor
import Fluent
import SQLKit
import Crypto
@testable import HubCore
@testable import HubKit
@testable import HubModuleDMS
@testable import HubModuleInvoice

// WP-BR1: Hub-Seite der Scan-Bridge (docs/SCAN-BRIDGE.md Abschnitt 3, Vertrag contracts/openapi.yaml). Nur synthetische Daten; Gerätekennungen sind Hashes erfundener Namen.
// Jede Probe läuft abwechselnd über zwei Anwendungsinstanzen (app1/app2) gegen dieselbe Datenbank.

class DMSScanTestBase: DMSTestBase {
    static let bridgeScopes = ["dms.scan.bridge", "dms.upload"]
    func scan(_ tenant: String) -> String { base(tenant) + "/scan" }

    func makeToken(_ s: TestSession, scopes: [String]? = nil, tenant: String? = nil) async throws -> String {
        var body: [String: Any] = ["name": "Bridge Flur", "scopes": scopes ?? Self.bridgeScopes]
        if let tenant { body["tenant_id"] = tenant }
        let r = try await call(app1, .POST, "api/v1/auth/api-tokens", json: body, token: s.token)
        XCTAssertEqual(r.status, .created, "\(r.json)")
        return r.json["token"] as? String ?? ""
    }

    func key(_ n: Int) -> String { SHA256.hash(data: Data("synthetic-device-\(n)".utf8)).map { String(format: "%02x", $0) }.joined() }

    func device(_ n: Int, name: String = "Flur-Scanner", sources: [String] = ["flatbed", "adf"], resolutions: [Int] = [150, 300, 600]) -> [String: Any] {
        ["key": key(n), "name": name, "capabilities": ["sources": sources, "resolutions": resolutions, "color_modes": ["color", "gray"], "formats": ["a4", "letter"]] as [String: Any]]
    }

    func register(_ token: String, _ tenant: String, devices: [[String: Any]]? = nil, name: String = "Bridge Flur", via: Application? = nil) async throws -> Resp {
        try await call(via ?? app1, .PUT, scan(tenant) + "/bridge", json: ["name": name, "version": "0.1.0", "devices": devices ?? [device(1)]], token: token)
    }

    struct Fixture { let w: World; let token: String; let device: String }

    func fixture() async throws -> Fixture {
        let w = try await world()
        let token = try await makeToken(w.alice)
        let r = try await register(token, w.tenantA)
        XCTAssertEqual(r.status, .ok, "\(r.json)")
        let device = ((r.json["devices"] as? [[String: Any]])?.first?["id"] as? String) ?? ""
        XCTAssertFalse(device.isEmpty)
        return Fixture(w: w, token: token, device: device)
    }

    func newJob(_ s: TestSession, _ tenant: String, _ device: String, extra: [String: Any] = [:], via: Application? = nil) async throws -> Resp {
        try await call(via ?? app1, .POST, scan(tenant) + "/jobs", json: ["device_id": device].merging(extra) { a, _ in a }, token: s.token)
    }

    func claim(_ token: String, _ tenant: String, via: Application? = nil) async throws -> Resp {
        try await call(via ?? app1, .POST, scan(tenant) + "/bridge/claim", token: token)
    }

    func report(_ token: String, _ tenant: String, _ job: String, _ body: [String: Any], via: Application? = nil) async throws -> Resp {
        try await call(via ?? app1, .PUT, scan(tenant) + "/bridge/jobs/\(job)", json: body, token: token)
    }

    func userAction(_ s: TestSession, _ tenant: String, _ job: String, _ action: String, via: Application? = nil) async throws -> Resp {
        try await call(via ?? app1, .POST, scan(tenant) + "/jobs/\(job)/\(action)", token: s.token)
    }

    func jobRow(_ id: String, _ column: String) async throws -> String {
        try await scalar("SELECT coalesce(\(column)::text, '') AS v FROM dms_scan_jobs WHERE id = '\(id)'", as: String.self)
    }

    /// Job anlegen und von der Bridge übernehmen (Zustand `claimed`).
    func claimedJob(_ f: Fixture, extra: [String: Any] = [:]) async throws -> String {
        let created = try await newJob(f.w.alice, f.w.tenantA, f.device, extra: extra)
        XCTAssertEqual(created.status, .created, "\(created.json)")
        let id = created.json["id"] as? String ?? ""
        let c = try await claim(f.token, f.w.tenantA)
        XCTAssertEqual(c.status, .ok, "\(c.json)")
        XCTAssertEqual(c.json["id"] as? String, id)
        return id
    }

    /// Abgeschlossener Upload der Bridge: Dokument über die Scan-API mit `Idempotency-Key: scan-<job>`.
    func uploadResult(_ f: Fixture, job: String, seed: String = "scan", via: Application? = nil) async throws -> String {
        let r = try await raw(via ?? app1, .POST, base(f.w.tenantA) + "/share?filename=Scan.pdf&title=Scan%20Flur", body: pdf(seed), token: f.token,
                              headers: ["Content-Type": "application/octet-stream", "Idempotency-Key": "scan-\(job)"])
        XCTAssertEqual(r.status, .created, "\(r.json)")
        return r.json["id"] as? String ?? ""
    }

    func parallelResp(_ n: Int, _ body: @escaping @Sendable (Int) async throws -> Resp) async throws -> [Resp] {
        try await withThrowingTaskGroup(of: Resp.self) { group in
            for i in 0..<n { group.addTask { try await body(i) } }
            var out: [Resp] = []
            for try await r in group { out.append(r) }
            return out
        }
    }

    func secondTenantOwner() async throws -> (session: TestSession, tenant: String) {
        let userID = UUID(), tenantID = UUID(), token = AuthSecrets.token()
        try await db.raw("INSERT INTO users (id, handle, display_name) VALUES (\(bind: userID), 'bob', 'Bob Synthetic')").run()
        try await db.raw("INSERT INTO tenants (id, name) VALUES (\(bind: tenantID), 'Mandant B')").run()
        try await db.raw("INSERT INTO memberships (tenant_id, user_id, role) VALUES (\(bind: tenantID), \(bind: userID), 'owner')").run()
        try await db.raw("INSERT INTO sessions (user_id, token_hash, kind, expires_at) VALUES (\(bind: userID), \(bind: AuthSecrets.hash(token)), 'normal', now() + interval '1 day')").run()
        let s = TestSession(token: token, userID: userID.uuidString, csrf: AuthSecrets.csrf(token), handle: "bob")
        try await setModule(tenantID.uuidString, true, by: s)
        return (s, tenantID.uuidString)
    }
}

// MARK: - AK-BR1-1 Tabellen, Routen, Vertrag, Geräteliste

final class DMSScanDeviceTests: DMSScanTestBase {
    /// AK-BR1-1: Tabellen laut Abschnitt 3, höchstens ein aktiver Auftrag je Gerät als Constraint, Migration rückbaubar und wieder anwendbar.
    func testAKBR1_1_tablesConstraintAndMigrationRevert() async throws {
        let f = try await fixture()
        for t in ["dms_scan_bridges", "dms_scan_devices", "dms_scan_jobs"] {
            try await aEq(try await count("information_schema.tables", where: "table_name = '\(t)'"), 1, t)
        }
        try await aEq(try await count("_fluent_migrations", where: "name = 'dms_028_scan_bridge'"), 1)
        // Constraint: zweiter aktiver Auftrag je Gerät scheitert in der Datenbank, nicht nur in der Route
        let user = UUID(uuidString: f.w.alice.userID)!
        let tenant = UUID(uuidString: f.w.tenantA)!, device = UUID(uuidString: f.device) ?? UUID()
        try await db.raw("INSERT INTO dms_scan_jobs (tenant_id, device_id, params, created_by) VALUES (\(bind: tenant), \(bind: device), '{}'::jsonb, \(bind: user))").run()
        do {
            try await db.raw("INSERT INTO dms_scan_jobs (tenant_id, device_id, params, created_by) VALUES (\(bind: tenant), \(bind: device), '{}'::jsonb, \(bind: user))").run()
            XCTFail("zweiter aktiver Auftrag je Gerät muss scheitern")
        } catch {}
        // erledigte Aufträge zählen nicht
        try await db.raw("UPDATE dms_scan_jobs SET state = 'cancelled', finished_at = now()").run()
        try await db.raw("INSERT INTO dms_scan_jobs (tenant_id, device_id, params, created_by) VALUES (\(bind: tenant), \(bind: device), '{}'::jsonb, \(bind: user))").run()
        // Gerätekennung nur als Hash: eine URL oder IP wird von der Datenbank abgelehnt
        do {
            try await db.raw("INSERT INTO dms_scan_devices (tenant_id, bridge_id, device_key, name, capabilities) SELECT tenant_id, bridge_id, 'http://192.168.1.5/escl', 'x', '{}'::jsonb FROM dms_scan_devices LIMIT 1").run()
            XCTFail("device_key muss ein SHA-256-Hash sein")
        } catch {}
        try await db.raw("DELETE FROM dms_scan_jobs").run()
        let migration = try XCTUnwrap(DMSModule().migrations.first { $0.name == "dms_028_scan_bridge" } as? any AsyncMigration)
        try await migration.revert(on: app1.db(.psql))
        for t in ["dms_scan_bridges", "dms_scan_devices", "dms_scan_jobs"] {
            try await aEq(try await count("information_schema.tables", where: "table_name = '\(t)'"), 0, t)
        }
        try await migration.prepare(on: app1.db(.psql))
        try await aEq(try await count("information_schema.tables", where: "table_name LIKE 'dms_scan_%'"), 3)
    }

    /// AK-BR1-1: die neuen Routen stehen in den Routentabellen (Bridge-Routen als Token-Routen mit `dms.source.manage`, Nutzerrouten mit `dms.scan.use`) und im Vertrag.
    func testAKBR1_1_routesAreRegisteredAndDocumented() throws {
        let prefix = "/api/v1/tenants/{tenant}/dms/scan"
        let tokenRoutes = Set(app1.moduleTokenRoutes.map { "\($0.method) \($0.path) \($0.permission)" })
        for r in ["PUT \(prefix)/bridge", "POST \(prefix)/bridge/claim", "PUT \(prefix)/bridge/jobs/{job}"] {
            XCTAssertTrue(tokenRoutes.contains("\(r) dms.source.manage"), r)
        }
        let sessionRoutes = Set(app1.moduleRoutes.map { "\($0.method) \($0.path) \($0.permission)" })
        for r in ["GET \(prefix)/devices", "POST \(prefix)/jobs", "GET \(prefix)/jobs/{job}", "POST \(prefix)/jobs/{job}/next-page", "POST \(prefix)/jobs/{job}/finish", "POST \(prefix)/jobs/{job}/cancel"] {
            XCTAssertTrue(sessionRoutes.contains("\(r) dms.scan.use"), r)
        }
        let documented = try OpenAPIContract.operations()
        for r in ["PUT /bridge", "POST /bridge/claim", "PUT /bridge/jobs/{job}", "GET /devices", "POST /jobs", "GET /jobs/{job}", "POST /jobs/{job}/next-page", "POST /jobs/{job}/finish", "POST /jobs/{job}/cancel"] {
            let parts = r.split(separator: " ", maxSplits: 1)
            XCTAssertTrue(documented.contains("\(parts[0]) \(prefix)\(parts[1])"), r)
        }
        XCTAssertTrue(DMSModule().tokenScopes.contains("dms.scan.bridge"))
        XCTAssertTrue(DMSModule().permissions.contains { $0.name == "dms.scan.use" })
    }

    /// AK-BR1-1: Registrierung (Lebenszeichen, Version, vollständige Liste). Die Liste ersetzt die bisherige, Geräte-IDs bleiben stabil, Zwei-Instanzen-Aufruf
    /// legt genau eine Bridge je Token an, die Nutzerliste zeigt nur aktive Geräte mit Fähigkeiten und Online-Zustand aus der Datenbankzeit.
    func testAKBR1_1_registrationReplacesListAndUserSeesDevices() async throws {
        let f = try await fixture()
        let t = f.w.tenantA
        try await aEq(try await count("dms_scan_bridges"), 1)
        let first = f.device
        let two = try await register(f.token, t, devices: [device(2, name: "Büro-Scanner")], via: app2)
        XCTAssertEqual(two.status, .ok, "\(two.json)")
        let secondID = ((two.json["devices"] as? [[String: Any]])?.first?["id"] as? String) ?? ""
        XCTAssertNotEqual(secondID, first)
        XCTAssertEqual(two.json["lease_seconds"] as? Int, 60)
        try await aEq(try await count("dms_scan_bridges"), 1)
        try await aEq(try await count("dms_scan_devices", where: "active"), 1)
        try await aEq(try await count("dms_scan_devices"), 2, "entfernte Geräte bleiben für alte Aufträge erhalten")
        let list = try await call(app1, .GET, scan(t) + "/devices", token: f.w.alice.token)
        XCTAssertEqual(list.status, .ok, "\(list.json)")
        let items = list.json["items"] as? [[String: Any]] ?? []
        XCTAssertEqual(items.map { $0["id"] as? String }, [secondID])
        XCTAssertEqual(items.first?["name"] as? String, "Büro-Scanner")
        XCTAssertEqual(items.first?["online"] as? Bool, true)
        XCTAssertEqual(items.first?["busy"] as? Bool, false)
        let caps = items.first?["capabilities"] as? [String: Any] ?? [:]
        XCTAssertEqual(caps["sources"] as? [String], ["flatbed", "adf"])
        XCTAssertEqual(caps["resolutions"] as? [Int], [150, 300, 600])
        XCTAssertNil(items.first?["key"], "die Gerätekennung bleibt bei der Bridge")
        // wieder auftauchendes Gerät behält seine ID
        let back = try await register(f.token, t, devices: [device(1), device(2, name: "Büro-Scanner")])
        let ids = Set((back.json["devices"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String })
        XCTAssertEqual(ids, [first, secondID])
        // gleichzeitige Erstregistrierung einer zweiten Bridge: genau eine Zeile je Token
        let other = try await makeToken(f.w.alice)
        let results = try await parallelResp(8) { i in try await self.register(other, t, devices: [self.device(10 + i % 2)], name: "Bridge Büro", via: i % 2 == 0 ? self.app1 : self.app2) }
        XCTAssertTrue(results.allSatisfy { $0.status == .ok }, "\(results.map(\.status))")
        try await aEq(try await count("dms_scan_bridges"), 2)
        // Online-Zustand aus der Datenbankzeit
        try await db.raw("UPDATE dms_scan_bridges SET last_seen_at = now() - interval '5 minutes'").run()
        let offline = try await call(app2, .GET, scan(t) + "/devices", token: f.w.alice.token)
        XCTAssertTrue((offline.json["items"] as? [[String: Any]] ?? []).allSatisfy { $0["online"] as? Bool == false })
        _ = try await register(f.token, t, devices: [device(1)])
        let online = try await call(app1, .GET, scan(t) + "/devices", token: f.w.alice.token)
        XCTAssertTrue((online.json["items"] as? [[String: Any]] ?? []).contains { $0["id"] as? String == first && $0["online"] as? Bool == true })
        try await aEq(try await auditCount("dms.scan.bridge.registered", tenant: t), 2)
    }

    /// AK-BR1-1 (Sicherheit): Geräteliste ist unvertrauenswürdig. Nur Hash-Kennungen, Positivliste für Fähigkeiten, Grenzen, keine unbekannten Schlüssel.
    func testAKBR1_1_registrationRejectsHostileInput() async throws {
        let f = try await fixture()
        let t = f.w.tenantA
        func bad(_ label: String, _ body: [String: Any], file: StaticString = #filePath, line: UInt = #line) async throws {
            let r = try await call(app1, .PUT, scan(t) + "/bridge", json: body, token: f.token)
            XCTAssertEqual(r.status, .unprocessableEntity, "\(label): \(r.json)", file: file, line: line)
            XCTAssertEqual(r.problemCode, "validation_failed", label, file: file, line: line)
        }
        func with(_ patch: (inout [String: Any]) -> Void) -> [String: Any] {
            var d = device(1); patch(&d)
            return ["name": "B", "version": "1", "devices": [d]]
        }
        func caps(_ key: String, _ value: Any) -> [String: Any] {
            with { d in var c = d["capabilities"] as! [String: Any]; c[key] = value; d["capabilities"] = c }
        }
        try await bad("URL als Kennung", with { $0["key"] = "http://192.168.1.5:80/eSCL" })
        try await bad("IP als Kennung", with { $0["key"] = "192.168.1.5" })
        try await bad("Großbuchstaben-Hash", with { $0["key"] = key(1).uppercased() })
        try await bad("Name leer", with { $0["name"] = "" })
        try await bad("Name mit Zeilenumbruch", with { $0["name"] = "Scanner\nX" })
        try await bad("Name zu lang", with { $0["name"] = String(repeating: "n", count: 101) })
        try await bad("unbekannte Quelle", caps("sources", ["flatbed", "feeder; rm -rf /"]))
        try await bad("Quelle doppelt", caps("sources", ["adf", "adf"]))
        try await bad("Auflösung zu klein", caps("resolutions", [10]))
        try await bad("Auflösung zu groß", caps("resolutions", [100_000]))
        try await bad("Auflösung als Text", caps("resolutions", ["300"]))
        try await bad("zu viele Auflösungen", caps("resolutions", Array(100...120)))
        try await bad("Quellen leer", caps("sources", [String]()))
        try await bad("Farbmodus unbekannt", caps("color_modes", ["rgb48"]))
        try await bad("Format unbekannt", caps("formats", ["a0"]))
        try await bad("unbekannte Fähigkeit", caps("duplex_url", "http://x"))
        try await bad("unbekannter Schlüssel am Gerät", with { $0["url"] = "http://192.168.1.5" })
        try await bad("Gerät doppelt", ["name": "B", "version": "1", "devices": [device(1), device(1)]])
        try await bad("17 Geräte", ["name": "B", "version": "1", "devices": (0..<17).map { device($0) }])
        try await bad("Version fehlt", ["name": "B", "devices": [device(1)]])
        try await bad("Name der Bridge zu lang", ["name": String(repeating: "n", count: 101), "version": "1", "devices": [device(1)]])
        try await bad("unbekannter Schlüssel", ["name": "B", "version": "1", "devices": [device(1)], "url": "http://x"])
        try await bad("Geräteliste fehlt", ["name": "B", "version": "1"])
        let raw = try await self.raw(app1, .PUT, scan(t) + "/bridge", body: Data("kein json".utf8), token: f.token, headers: ["Content-Type": "application/json"])
        XCTAssertEqual(raw.status, .unprocessableEntity)
        // nichts hat die gespeicherte Liste verändert
        try await aEq(try await count("dms_scan_devices", where: "active"), 1)
        try await aEq(try await scalar("SELECT device_key AS v FROM dms_scan_devices WHERE active", as: String.self), key(1))
        // 16 Geräte sind erlaubt
        let max = try await register(f.token, t, devices: (0..<16).map { device($0) })
        XCTAssertEqual(max.status, .ok, "\(max.json)")
    }
}

// MARK: - AK-BR1-2 Aufträge, Lease, Zustände

final class DMSScanJobTests: DMSScanTestBase {
    /// AK-BR1-2: Auftrag mit Standardwerten aus den Fähigkeiten, Parameter nur aus der Positivliste und nur, was das Gerät kann; ein aktiver Auftrag je Gerät.
    func testAKBR1_2_createValidatesParametersAndOneActiveJobPerDevice() async throws {
        let f = try await fixture()
        let t = f.w.tenantA
        let created = try await newJob(f.w.alice, t, f.device)
        XCTAssertEqual(created.status, .created, "\(created.json)")
        XCTAssertEqual(created.json["state"] as? String, "queued")
        let params = created.json["params"] as? [String: Any] ?? [:]
        XCTAssertEqual(params["source"] as? String, "flatbed")
        XCTAssertEqual(params["resolution"] as? Int, 300)
        XCTAssertEqual(params["color"] as? String, "color")
        XCTAssertEqual(params["format"] as? String, "a4")
        XCTAssertEqual(params["archive"] as? Bool, false)
        XCTAssertEqual(created.json["pages"] as? Int, 0)
        XCTAssertEqual((created.json["created_by"] as? String)?.lowercased(), nil, "Auftraggeber steht nicht in der Antwort")
        let busy = try await newJob(f.w.alice, t, f.device, via: app2)
        XCTAssertEqual(busy.status, .conflict)
        XCTAssertEqual(busy.problemCode, "scan_device_busy")
        let devices = try await call(app1, .GET, scan(t) + "/devices", token: f.w.alice.token)
        XCTAssertEqual((devices.json["items"] as? [[String: Any]])?.first?["busy"] as? Bool, true)
        _ = try await userAction(f.w.alice, t, created.json["id"] as? String ?? "", "cancel")
        // Parameter
        let type = try await call(app1, .POST, base(t) + "/types", json: ["name": "Rechnung"], token: f.w.alice.token)
        let typeID = type.json["id"] as? String ?? ""
        let ok = try await newJob(f.w.alice, t, f.device, extra: ["source": "adf", "resolution": 600, "color": "gray", "format": "letter", "title": "Strom 2026", "document_type_id": typeID, "archive": true])
        XCTAssertEqual(ok.status, .created, "\(ok.json)")
        XCTAssertEqual((ok.json["params"] as? [String: Any])?["title"] as? String, "Strom 2026")
        XCTAssertEqual((ok.json["params"] as? [String: Any])?["document_type_id"] as? String, typeID.lowercased())
        _ = try await userAction(f.w.alice, t, ok.json["id"] as? String ?? "", "cancel")
        for (extra, field) in [(["source": "adf_duplex"], "source"), (["source": "feeder"], "source"), (["resolution": 1200], "resolution"), (["resolution": "300"], "resolution"),
                               (["color": "bw"], "color"), (["format": "a3"], "format"), (["title": ""], "title"), (["title": "x\ny"], "title"),
                               (["archive": "ja"], "archive"), (["document_type_id": "kein-uuid"], "document_type_id"), (["document_type_id": UUID().uuidString], "document_type_id"),
                               (["url": "http://192.168.1.5"], "url"), (["scanimage_args": "--help"], "scanimage_args")] as [([String: Any], String)] {
            let r = try await newJob(f.w.alice, t, f.device, extra: extra)
            XCTAssertEqual(r.status, .unprocessableEntity, "\(extra): \(r.json)")
            XCTAssertTrue((r.json["errors"] as? [[String: Any]] ?? []).contains { $0["field"] as? String == field }, "\(extra): \(r.json)")
        }
        let missing = try await call(app1, .POST, scan(t) + "/jobs", json: [String: Any](), token: f.w.alice.token)
        XCTAssertEqual(missing.status, .unprocessableEntity)
        let unknown = try await newJob(f.w.alice, t, UUID().uuidString)
        XCTAssertEqual(unknown.status, .notFound)
        try await aEq(try await count("dms_scan_jobs", where: "state = 'queued'"), 0)
        // Bridge länger als 60 s still: kein neuer Auftrag (sonst startet ein Scan überraschend)
        try await db.raw("UPDATE dms_scan_bridges SET last_seen_at = now() - interval '2 minutes'").run()
        let offline = try await newJob(f.w.alice, t, f.device)
        XCTAssertEqual(offline.status, .conflict)
        XCTAssertEqual(offline.problemCode, "scan_bridge_offline")
        try await aEq(try await auditCount("dms.scan.job.created", tenant: t), 2)
    }

    /// AK-BR1-2 (Zwei-Instanzen): gleichzeitig angelegte Aufträge für dasselbe Gerät ergeben genau einen (Constraint, nicht nur Prüfung in der Route).
    func testAKBR1_2_concurrentCreatesOnTwoInstancesYieldOneJob() async throws {
        let f = try await fixture()
        let results = try await parallelResp(10) { i in try await self.newJob(f.w.alice, f.w.tenantA, f.device, via: i % 2 == 0 ? self.app1 : self.app2) }
        XCTAssertEqual(results.filter { $0.status == .created }.count, 1, "\(results.map(\.status))")
        XCTAssertEqual(results.filter { $0.status == .conflict && $0.problemCode == "scan_device_busy" }.count, 9, "\(results.map { "\($0.status) \($0.problemCode ?? "")" })")
        try await aEq(try await count("dms_scan_jobs"), 1)
    }

    /// AK-BR1-2: zwei Verbindungen (zwei Instanzen) übernehmen denselben Auftrag genau einmal, die Lease läuft über die Datenbankzeit.
    func testAKBR1_2_twoConnectionsClaimExactlyOnceWithDatabaseLease() async throws {
        let f = try await fixture()
        let t = f.w.tenantA
        let none = try await claim(f.token, t)
        XCTAssertEqual(none.status, .noContent, "kein Auftrag: 204")
        let created = try await newJob(f.w.alice, t, f.device)
        let id = created.json["id"] as? String ?? ""
        let results = try await parallelResp(12) { i in try await self.claim(f.token, t, via: i % 2 == 0 ? self.app1 : self.app2) }
        XCTAssertEqual(results.filter { $0.status == .ok }.count, 1, "\(results.map(\.status))")
        XCTAssertEqual(results.filter { $0.status == .noContent }.count, 11)
        let won = try XCTUnwrap(results.first { $0.status == .ok })
        XCTAssertEqual(won.json["id"] as? String, id)
        XCTAssertEqual(won.json["device_key"] as? String, key(1))
        XCTAssertEqual(won.json["state"] as? String, "claimed")
        XCTAssertEqual(won.json["lease_seconds"] as? Int, 60)
        XCTAssertEqual((won.json["params"] as? [String: Any])?["resolution"] as? Int, 300)
        try await aEq(try await jobRow(id, "state"), "claimed")
        // Lease relativ zur Datenbankuhr: jetzt + 60 s (Toleranz für die Laufzeit der Anfrage)
        try await aEq(try await scalar("SELECT (lease_until > now() + interval '50 seconds' AND lease_until <= now() + interval '60 seconds') AS v FROM dms_scan_jobs WHERE id = '\(id)'", as: Bool.self), true)
        // Heartbeat verlängert ab Datenbank-now(), egal wie weit die Lease schon gelaufen ist
        try await db.raw("UPDATE dms_scan_jobs SET lease_until = now() + interval '5 seconds' WHERE id = '\(id)'").run()
        let beat = try await report(f.token, t, id, [:], via: app2)
        XCTAssertEqual(beat.status, .ok, "\(beat.json)")
        XCTAssertEqual(beat.json["state"] as? String, "claimed")
        XCTAssertEqual(beat.json["commands"] as? [String], [])
        try await aEq(try await scalar("SELECT (lease_until > now() + interval '50 seconds') AS v FROM dms_scan_jobs WHERE id = '\(id)'", as: Bool.self), true)
        // keine Instanzuhr in der Scan-Logik (ADR 0003)
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/HubModuleDMS/Scan")
        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil).filter { $0.pathExtension == "swift" }
        XCTAssertFalse(files.isEmpty)
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            XCTAssertFalse(text.contains("Date()") || text.contains("Date.now") || text.contains("Task.sleep"), "\(file.lastPathComponent): Instanzuhr")
        }
    }

    /// AK-BR1-2: Läuft die Lease ab, wird der Auftrag `failed` (`bridge_lost`) und nie automatisch wiederholt; das Gerät ist wieder frei.
    /// Ein spätes Ergebnis derselben Bridge setzt ihn auf `done` (Idempotency-Key verhindert ein zweites Dokument), eine andere Bridge kann das nicht.
    func testAKBR1_2_leaseExpiryFailsWithoutRetryAndLateResultIsAccepted() async throws {
        let f = try await fixture()
        let t = f.w.tenantA
        let id = try await claimedJob(f)
        _ = try await report(f.token, t, id, ["state": "scanning"])
        try await db.raw("UPDATE dms_scan_jobs SET lease_until = now() - interval '1 second' WHERE id = '\(id)'").run()
        // jeder Aufruf der Bridge löst den Ablauf aus: kein erneutes Übernehmen
        for i in 0..<3 {
            let again = try await claim(f.token, t, via: i % 2 == 0 ? app2 : app1)
            XCTAssertEqual(again.status, .noContent)
        }
        try await aEq(try await jobRow(id, "state"), "failed")
        try await aEq(try await jobRow(id, "error_code"), "bridge_lost")
        try await aEq(try await jobRow(id, "lease_until"), "")
        try await aEq(try await count("dms_scan_jobs", where: "state = 'queued' OR claimed_at IS NULL"), 0)
        let seen = try await call(app2, .GET, scan(t) + "/jobs/\(id)", token: f.w.alice.token)
        XCTAssertEqual(seen.json["state"] as? String, "failed")
        XCTAssertEqual(seen.json["error_code"] as? String, "bridge_lost")
        try await aEq(try await auditCount("dms.scan.job.failed", tenant: t), 1)
        // Heartbeat und Zwischenzustände einer verlorenen Bridge werden nicht mehr angenommen
        let late = try await report(f.token, t, id, ["state": "scanning"])
        XCTAssertEqual(late.status, .conflict)
        XCTAssertEqual(late.problemCode, "scan_transition_invalid")
        // das Gerät ist frei: neuer Auftrag möglich, der alte bleibt `failed`
        let next = try await newJob(f.w.alice, t, f.device)
        XCTAssertEqual(next.status, .created, "\(next.json)")
        // spätes Ergebnis: Upload mit dem Schlüssel des alten Auftrags, dann `done`
        let doc = try await uploadResult(f, job: id)
        let other = try await makeToken(f.w.alice)
        _ = try await register(other, t, devices: [device(2)], name: "Andere Bridge")
        let foreign = try await report(other, t, id, ["state": "done", "document_id": doc])
        XCTAssertEqual(foreign.status, .notFound, "eine andere Bridge kennt den Auftrag nicht")
        let done = try await report(f.token, t, id, ["state": "done", "document_id": doc, "pages": 2], via: app2)
        XCTAssertEqual(done.status, .ok, "\(done.json)")
        XCTAssertEqual(done.json["state"] as? String, "done")
        try await aEq(try await jobRow(id, "state"), "done")
        try await aEq(try await jobRow(id, "error_code"), "")
        try await aEq(try await jobRow(id, "document_id"), doc.lowercased())
        let sameAgain = try await report(f.token, t, id, ["state": "done", "document_id": doc])
        XCTAssertEqual(sameAgain.status, .ok, "Wiederholung des Ergebnisses ist unschädlich")
        try await aEq(try await count("dms_documents"), 1)
        try await aEq(try await auditCount("dms.scan.job.done", tenant: t), 1)
        // eine nach dem Ablauf gescheiterte Bridge darf auch nicht andere Zielzustände setzen
        let afterFail = try await report(f.token, t, next.json["id"] as? String ?? "", ["state": "done", "document_id": doc])
        XCTAssertEqual(afterFail.status, .conflict, "ein nie übernommener Auftrag kann nicht `done` werden")
    }

    /// AK-BR1-2: nicht abgeholte Aufträge verfallen nach 5 Minuten (`failed`/`expired`), ein Scan startet nie überraschend später.
    func testAKBR1_2_unclaimedJobsExpire() async throws {
        let f = try await fixture()
        let t = f.w.tenantA
        let created = try await newJob(f.w.alice, t, f.device)
        let id = created.json["id"] as? String ?? ""
        try await db.raw("UPDATE dms_scan_jobs SET created_at = now() - interval '299 seconds' WHERE id = '\(id)'").run()
        let still = try await call(app1, .GET, scan(t) + "/jobs/\(id)", token: f.w.alice.token)
        XCTAssertEqual(still.json["state"] as? String, "queued")
        try await db.raw("UPDATE dms_scan_jobs SET created_at = now() - interval '301 seconds' WHERE id = '\(id)'").run()
        let none = try await claim(f.token, t, via: app2)
        XCTAssertEqual(none.status, .noContent)
        let seen = try await call(app1, .GET, scan(t) + "/jobs/\(id)", token: f.w.alice.token)
        XCTAssertEqual(seen.json["state"] as? String, "failed")
        XCTAssertEqual(seen.json["error_code"] as? String, "expired")
        let fresh = try await newJob(f.w.alice, t, f.device)
        XCTAssertEqual(fresh.status, .created, "das Gerät ist wieder frei")
    }

    /// AK-BR1-2: Zustandsmaschine der Bridge (nur erlaubte Übergänge, Seitenzahl, Fehlercode, Ergebnis nur mit Dokument), Nutzerbefehle werden in der Antwort geliefert.
    func testAKBR1_2_stateMachineAndUserCommands() async throws {
        let f = try await fixture()
        let t = f.w.tenantA
        let id = try await claimedJob(f)
        // ungültige Eingaben
        for (body, label) in [(["state": "queued"], "queued"), (["state": "teleport"], "unbekannt"), (["pages": -1], "negativ"), (["pages": 501], "zu viele Seiten"), (["pages": "3"], "Text"),
                              (["state": "failed"], "failed ohne Code"), (["state": "failed", "error_code": "Kaputt!"], "Code ungültig"), (["state": "failed", "error_code": String(repeating: "a", count: 65)], "Code zu lang"),
                              (["state": "scanning", "document_id": UUID().uuidString], "Dokument ohne done"), (["state": "scanning", "url": "http://x"], "unbekannter Schlüssel"),
                              (["state": "done"], "done ohne Dokument"), (["document_id": "kein-uuid", "state": "done"], "Dokument ungültig")] as [([String: Any], String)] {
            let r = try await report(f.token, t, id, body)
            XCTAssertEqual(r.status, .unprocessableEntity, "\(label): \(r.json)")
        }
        // ungültige Übergänge
        for (state, label) in [("claimed", "claimed->claimed"), ("waiting_for_page", "claimed->waiting"), ("uploading", "claimed->uploading")] {
            let r = try await report(f.token, t, id, ["state": state])
            XCTAssertEqual(r.status, .conflict, label)
            XCTAssertEqual(r.problemCode, "scan_transition_invalid", label)
        }
        try await aEq(try await jobRow(id, "state"), "claimed")
        let scanning = try await report(f.token, t, id, ["state": "scanning", "pages": 0])
        XCTAssertEqual(scanning.status, .ok, "\(scanning.json)")
        // Nutzerbefehle: nächste Seite erst, wenn die Bridge auf die nächste Seite wartet
        let tooEarly = try await userAction(f.w.alice, t, id, "next-page")
        XCTAssertEqual(tooEarly.status, .conflict)
        XCTAssertEqual(tooEarly.problemCode, "scan_command_invalid")
        let waiting = try await report(f.token, t, id, ["state": "waiting_for_page", "pages": 1])
        XCTAssertEqual(waiting.json["commands"] as? [String], [])
        let next = try await userAction(f.w.alice, t, id, "next-page", via: app2)
        XCTAssertEqual(next.status, .ok, "\(next.json)")
        XCTAssertEqual(next.json["state"] as? String, "waiting_for_page")
        XCTAssertEqual(next.json["command"] as? String, "next_page")
        let heartbeat = try await report(f.token, t, id, [:], via: app1)
        XCTAssertEqual(heartbeat.json["commands"] as? [String], ["next_page"], "der Befehl bleibt, bis die Bridge den Zustand wechselt")
        let again = try await report(f.token, t, id, ["state": "scanning", "pages": 1])
        XCTAssertEqual(again.status, .ok)
        XCTAssertEqual(again.json["commands"] as? [String], [])
        try await aEq(try await jobRow(id, "command"), "")
        let page2 = try await report(f.token, t, id, ["state": "waiting_for_page", "pages": 2])
        XCTAssertEqual(page2.status, .ok)
        let finish = try await userAction(f.w.alice, t, id, "finish")
        XCTAssertEqual(finish.status, .ok)
        let hb = try await report(f.token, t, id, [:])
        XCTAssertEqual(hb.json["commands"] as? [String], ["finish"])
        let uploading = try await report(f.token, t, id, ["state": "uploading", "pages": 2])
        XCTAssertEqual(uploading.json["commands"] as? [String], [])
        let tooLate = try await userAction(f.w.alice, t, id, "next-page")
        XCTAssertEqual(tooLate.status, .conflict)
        let tooLateCancel = try await userAction(f.w.alice, t, id, "cancel")
        XCTAssertEqual(tooLateCancel.status, .conflict, "beim Hochladen ist Abbrechen nicht mehr möglich")
        // Ergebnis nur mit einem Dokument dieses Auftrags
        let unrelated = try await upload(f.w.alice, t, pdf("fremd"))
        let wrong = try await report(f.token, t, id, ["state": "done", "document_id": unrelated.json["id"] as? String ?? ""])
        XCTAssertEqual(wrong.status, .unprocessableEntity, "Dokument stammt nicht aus dem Upload mit Schlüssel scan-<job>")
        let ghost = try await report(f.token, t, id, ["state": "done", "document_id": UUID().uuidString])
        XCTAssertEqual(ghost.status, .unprocessableEntity)
        let doc = try await uploadResult(f, job: id, seed: "ergebnis")
        let done = try await report(f.token, t, id, ["state": "done", "document_id": doc, "pages": 2])
        XCTAssertEqual(done.status, .ok, "\(done.json)")
        XCTAssertEqual(done.json["commands"] as? [String], [])
        let seen = try await call(app2, .GET, scan(t) + "/jobs/\(id)", token: f.w.alice.token)
        XCTAssertEqual(seen.json["state"] as? String, "done")
        XCTAssertEqual(seen.json["document_id"] as? String, doc.lowercased())
        XCTAssertEqual(seen.json["pages"] as? Int, 2)
        // abgeschlossen bleibt abgeschlossen
        let back = try await report(f.token, t, id, ["state": "scanning"])
        XCTAssertEqual(back.status, .conflict)
        let cancelDone = try await userAction(f.w.alice, t, id, "cancel")
        XCTAssertEqual(cancelDone.status, .conflict)
        try await aEq(try await jobRow(id, "lease_until"), "")
        // Fehlerweg mit Code
        let id2 = try await claimedJob(f)
        let failed = try await report(f.token, t, id2, ["state": "failed", "error_code": "feeder_empty"])
        XCTAssertEqual(failed.status, .ok)
        let seen2 = try await call(app1, .GET, scan(t) + "/jobs/\(id2)", token: f.w.alice.token)
        XCTAssertEqual(seen2.json["error_code"] as? String, "feeder_empty")
    }

    /// AK-BR1-2: Abbrechen. Nicht abgeholt = sofort `cancelled`; läuft er, erfährt es die Bridge über den Befehl und bestätigt mit `cancelled`; ein Abbruch ist
    /// stärker als ein späterer Befehl; verliert die Bridge die Lease nach dem Abbruch, ist der Auftrag `cancelled` und nicht `failed`.
    func testAKBR1_2_cancel() async throws {
        let f = try await fixture()
        let t = f.w.tenantA
        let queued = try await newJob(f.w.alice, t, f.device)
        let queuedID = queued.json["id"] as? String ?? ""
        let c1 = try await userAction(f.w.alice, t, queuedID, "cancel")
        XCTAssertEqual(c1.status, .ok, "\(c1.json)")
        XCTAssertEqual(c1.json["state"] as? String, "cancelled")
        try await aEq((try await claim(f.token, t)).status, .noContent, "ein abgebrochener Auftrag wird nie übernommen")
        let c1b = try await userAction(f.w.alice, t, queuedID, "cancel", via: app2)
        XCTAssertEqual(c1b.status, .conflict, "schon beendet")
        // laufender Auftrag
        let id = try await claimedJob(f)
        _ = try await report(f.token, t, id, ["state": "scanning"])
        let c2 = try await userAction(f.w.alice, t, id, "cancel", via: app2)
        XCTAssertEqual(c2.status, .ok)
        XCTAssertEqual(c2.json["state"] as? String, "scanning")
        XCTAssertEqual(c2.json["command"] as? String, "cancel")
        let afterCancel = try await userAction(f.w.alice, t, id, "next-page")
        XCTAssertEqual(afterCancel.status, .conflict, "nach Abbruch keine weiteren Befehle")
        let hb = try await report(f.token, t, id, [:])
        XCTAssertEqual(hb.json["commands"] as? [String], ["cancel"])
        let ack = try await report(f.token, t, id, ["state": "cancelled"])
        XCTAssertEqual(ack.status, .ok, "\(ack.json)")
        try await aEq(try await jobRow(id, "state"), "cancelled")
        try await aEq(try await jobRow(id, "lease_until"), "")
        // die Bridge darf nicht ohne Abbruchwunsch abbrechen
        let id3 = try await claimedJob(f)
        let rogue = try await report(f.token, t, id3, ["state": "cancelled"])
        XCTAssertEqual(rogue.status, .conflict)
        // Lease verloren, nachdem der Nutzer abgebrochen hat
        _ = try await userAction(f.w.alice, t, id3, "cancel")
        try await db.raw("UPDATE dms_scan_jobs SET lease_until = now() - interval '1 second' WHERE id = '\(id3)'").run()
        _ = try await claim(f.token, t)
        try await aEq(try await jobRow(id3, "state"), "cancelled")
        try await aEq(try await auditCount("dms.scan.job.cancelled", tenant: t), 3)
    }
}

// MARK: - AK-BR1-3 Mandantentrennung, Rechte, Scope

final class DMSScanAccessTests: DMSScanTestBase {
    private func bridgeCalls(_ token: String, _ tenant: String, job: String, via: Application? = nil) async throws -> [Resp] {
        let app = via ?? app1!
        return [try await register(token, tenant, via: app), try await claim(token, tenant, via: app), try await report(token, tenant, job, ["state": "scanning"], via: app)]
    }

    /// AK-BR1-3: Mandantentrennung. Fremde Sitzung, fremdes Token, fremde Auftrags- und Geräte-IDs: immer 404, ohne Wirkung und ohne Auskunft.
    func testAKBR1_3_tenantSeparation() async throws {
        let f = try await fixture()
        let t = f.w.tenantA
        let (bob, tenantB) = try await secondTenantOwner()
        let jobA = (try await newJob(f.w.alice, t, f.device)).json["id"] as? String ?? ""
        let before = try await scalar("SELECT concat_ws('|', (SELECT count(*) FROM dms_scan_jobs), (SELECT state FROM dms_scan_jobs LIMIT 1), (SELECT count(*) FROM dms_scan_devices)) AS v", as: String.self)
        // Bob (Mandant B) auf den Pfaden von Mandant A
        for (method, path, body) in [(HTTPMethod.GET, "/devices", nil), (.POST, "/jobs", ["device_id": f.device]), (.GET, "/jobs/\(jobA)", nil), (.POST, "/jobs/\(jobA)/next-page", nil),
                                     (.POST, "/jobs/\(jobA)/finish", nil), (.POST, "/jobs/\(jobA)/cancel", nil)] as [(HTTPMethod, String, [String: Any]?)] {
            let r = try await call(app2, method, scan(t) + path, json: body, token: bob.token)
            XCTAssertEqual(r.status, .notFound, "\(method) \(path)")
            XCTAssertEqual(r.problemCode, "not_found")
        }
        // Alice (nur Mandant A) auf Mandant B
        let aliceOnB = try await call(app1, .GET, scan(tenantB) + "/devices", token: f.w.alice.token)
        XCTAssertEqual(aliceOnB.status, .notFound)
        // das Token von A auf Pfaden von B
        for r in try await bridgeCalls(f.token, tenantB, job: jobA) { XCTAssertEqual(r.status, .notFound); XCTAssertEqual(r.problemCode, "not_found") }
        // Bobs Bridge in B sieht nichts von A
        let tokenB = try await makeToken(bob, tenant: tenantB)
        let regB = try await register(tokenB, tenantB, devices: [device(1)], name: "Bridge B")
        XCTAssertEqual(regB.status, .ok, "\(regB.json)")
        XCTAssertNotEqual(((regB.json["devices"] as? [[String: Any]])?.first?["id"] as? String), f.device, "gleiche Gerätekennung in einem anderen Mandanten ist ein anderes Gerät")
        try await aEq((try await claim(tokenB, tenantB)).status, .noContent, "kein Auftrag aus Mandant A")
        try await aEq((try await report(tokenB, tenantB, jobA, ["state": "scanning"])).status, .notFound)
        try await aEq((try await call(app1, .GET, scan(tenantB) + "/jobs/\(jobA)", token: bob.token)).status, .notFound)
        try await aEq((try await userAction(bob, tenantB, jobA, "cancel")).status, .notFound)
        try await aEq((try await newJob(bob, tenantB, f.device)).status, .notFound, "Gerät eines anderen Mandanten")
        let devicesB = try await call(app2, .GET, scan(tenantB) + "/devices", token: bob.token)
        XCTAssertEqual((devicesB.json["items"] as? [[String: Any]])?.count, 1)
        // nichts in A hat sich verändert
        try await aEq(try await scalar("SELECT concat_ws('|', (SELECT count(*) FROM dms_scan_jobs WHERE tenant_id = '\(t)'), (SELECT state FROM dms_scan_jobs WHERE tenant_id = '\(t)' LIMIT 1), (SELECT count(*) FROM dms_scan_devices WHERE tenant_id = '\(t)')) AS v", as: String.self),
                      before)
        // zwei Bridges im selben Mandanten: jede sieht nur ihre Geräte und ihre Aufträge
        let second = try await makeToken(f.w.alice)
        let regSecond = try await register(second, t, devices: [device(2)], name: "Bridge Büro")
        let deviceTwo = ((regSecond.json["devices"] as? [[String: Any]])?.first?["id"] as? String) ?? ""
        try await aEq((try await claim(second, t)).status, .noContent, "der Auftrag gehört zum Gerät der ersten Bridge")
        try await aEq((try await report(second, t, jobA, [:])).status, .notFound)
        let jobTwo = (try await newJob(f.w.alice, t, deviceTwo)).json["id"] as? String ?? ""
        let mine = try await claim(second, t, via: app2)
        XCTAssertEqual(mine.json["id"] as? String, jobTwo)
        XCTAssertEqual(mine.json["device_key"] as? String, key(2))
        try await aEq((try await report(f.token, t, jobTwo, [:])).status, .notFound)
    }

    /// AK-BR1-3: Rechte. Nutzerrouten mit `dms.scan.use` (Owner, Buchhaltung, Mitglied; nicht Steuerberater, Kundenansicht), Bridge-Routen mit `dms.source.manage`
    /// der Rolle des Token-Inhabers; fehlendes Recht = 403 ohne Wirkung.
    func testAKBR1_3_permissionsPerRole() async throws {
        let f = try await fixture()
        let t = f.w.tenantA
        let permissions = DMSModule().permissions
        XCTAssertEqual(permissions.first { $0.name == "dms.scan.use" }?.roles, [.accountant, .member])
        let job = (try await newJob(f.w.alice, t, f.device)).json["id"] as? String ?? ""
        for role in [Role.accountant, .member, .taxAdvisor, .customerViewer] {
            let user = try await addUser(role.rawValue, handle: "u_" + role.rawValue, tenant: t, by: f.w.alice)
            let allowed = role == .accountant || role == .member
            let list = try await call(app2, .GET, scan(t) + "/devices", token: user.token)
            XCTAssertEqual(list.status, allowed ? .ok : .forbidden, role.rawValue)
            let get = try await call(app1, .GET, scan(t) + "/jobs/\(job)", token: user.token)
            XCTAssertEqual(get.status, allowed ? .ok : .forbidden, role.rawValue)
            for action in ["next-page", "finish", "cancel"] where !allowed {
                try await aEq((try await userAction(user, t, job, action)).status, .forbidden, "\(role.rawValue) \(action)")
            }
            let created = try await newJob(user, t, f.device)
            XCTAssertEqual(created.status, allowed ? .conflict : .forbidden, "\(role.rawValue): erlaubt = Gerät belegt, verboten = 403")
            // Bridge-Token dieses Nutzers: nur mit `dms.source.manage` (Buchhaltung) nutzbar
            let token = try await makeToken(user)
            let bridgeAllowed = role == .accountant
            let r = try await register(token, t, devices: [device(20 + permissions.count)], name: "Bridge \(role.rawValue)")
            XCTAssertEqual(r.status, bridgeAllowed ? .ok : .forbidden, "\(role.rawValue): \(r.json)")
            let claimed = try await claim(token, t)
            XCTAssertEqual(claimed.status == .forbidden, !bridgeAllowed, role.rawValue)
        }
        try await aEq(try await scalar("SELECT state AS v FROM dms_scan_jobs WHERE id = '\(job)'", as: String.self), "queued", "verbotene Aufrufe wirken nicht")
        try await aEq(try await count("dms_scan_bridges"), 2, "nur die Bridge der Buchhaltung ist zusätzlich entstanden")
        // Mitglied darf einen Scan starten und abbrechen
        let member = try await addUser("member", handle: "mitglied", tenant: t, by: f.w.alice)
        try await aEq((try await userAction(member, t, job, "cancel")).status, .ok)
    }

    /// AK-BR1-3: falscher Scope. Bridge-Routen brauchen `dms.scan.bridge`, das Ergebnis `dms.upload`; Sitzungen, Tokens ohne Scope, widerrufene Tokens: 401;
    /// Bridge-Tokens öffnen keine Nutzerrouten; deaktiviertes Modul: 404.
    func testAKBR1_3_scopesAndTokenKinds() async throws {
        let f = try await fixture()
        let t = f.w.tenantA
        let job = try await claimedJob(f)
        let uploadOnly = try await makeToken(f.w.alice, scopes: ["dms.upload"])
        let bridgeOnly = try await makeToken(f.w.alice, scopes: ["dms.scan.bridge"])
        for r in try await bridgeCalls(uploadOnly, t, job: job, via: app2) { XCTAssertEqual(r.status, .unauthorized); XCTAssertEqual(r.problemCode, "unauthorized") }
        for r in try await bridgeCalls(f.w.alice.token, t, job: job) { XCTAssertEqual(r.status, .unauthorized, "eine Sitzung ist kein Bridge-Token") }
        for r in try await bridgeCalls("lhp_" + String(repeating: "x", count: 43), t, job: job) { XCTAssertEqual(r.status, .unauthorized) }
        let anonymous = try await call(app1, .POST, scan(t) + "/bridge/claim")
        XCTAssertEqual(anonymous.status, .unauthorized)
        // Bridge-Scope ohne Upload-Scope: Registrierung und Aufträge gehen, das Ergebnis nicht
        let regOnly = try await register(bridgeOnly, t, devices: [device(3)], name: "Nur Bridge")
        XCTAssertEqual(regOnly.status, .ok, "\(regOnly.json)")
        let shareDenied = try await raw(app1, .POST, base(t) + "/share", body: pdf("ohne-scope"), token: bridgeOnly, headers: ["Content-Type": "application/octet-stream", "Idempotency-Key": "scan-\(job)"])
        XCTAssertEqual(shareDenied.status, .unauthorized)
        try await aEq(try await count("dms_documents"), 0)
        // Bridge-Token auf Nutzerrouten und umgekehrt
        for (method, path) in [(HTTPMethod.GET, "/devices"), (.GET, "/jobs/\(job)"), (.POST, "/jobs/\(job)/cancel")] {
            let r = try await call(app1, method, scan(t) + path, token: f.token)
            XCTAssertEqual(r.status, .unauthorized, "\(method) \(path)")
        }
        try await aEq(try await jobRow(job, "state"), "claimed")
        // Widerruf wirkt sofort auf der anderen Instanz
        let tokens = try await call(app1, .GET, "api/v1/auth/api-tokens", token: f.w.alice.token)
        let tokenID = ((tokens.json["items"] as? [[String: Any]]) ?? []).first { ($0["scopes"] as? [String])?.contains("dms.scan.bridge") == true && ($0["scopes"] as? [String])?.contains("dms.upload") == true }?["id"] as? String ?? ""
        XCTAssertFalse(tokenID.isEmpty)
        try await aEq((try await report(f.token, t, job, [:], via: app2)).status, .ok)
        let revoked = try await call(app1, .DELETE, "api/v1/auth/api-tokens/\(tokenID)", token: f.w.alice.token)
        XCTAssertEqual(revoked.status, .noContent)
        for r in try await bridgeCalls(f.token, t, job: job, via: app2) { XCTAssertEqual(r.status, .unauthorized) }
        // Token mit Scope, aber der Vertrag kennt nur deklarierte Scopes
        let unknown = try await call(app1, .POST, "api/v1/auth/api-tokens", json: ["name": "x", "scopes": ["dms.scan.admin"]], token: f.w.alice.token)
        XCTAssertEqual(unknown.status, .unprocessableEntity)
        // Modul aus: 404 module_disabled auch auf den Token-Routen
        try await setModule(t, false, by: f.w.alice)
        let off = try await register(bridgeOnly, t, devices: [device(3)])
        XCTAssertEqual(off.status, .notFound)
        XCTAssertEqual(off.problemCode, "module_disabled")
        let offUser = try await call(app1, .GET, scan(t) + "/devices", token: f.w.alice.token)
        XCTAssertEqual(offUser.problemCode, "module_disabled")
    }
}

// MARK: - AK-BR1-4 Ergebnis über die Scan-API

final class DMSScanResultTests: DMSScanTestBase {
    /// AK-BR1-4: Der Upload mit `Idempotency-Key: scan-<job>` über die vorhandene Scan-API erzeugt genau ein Dokument (auch bei Wiederholung und über zwei Instanzen),
    /// die Bridge meldet dessen ID am Auftrag, der Nutzer sieht sie.
    func testAKBR1_4_uploadWithScanKeyCreatesOneDocument() async throws {
        let f = try await fixture()
        let t = f.w.tenantA
        let id = try await claimedJob(f, extra: ["title": "Scan Flur"])
        _ = try await report(f.token, t, id, ["state": "scanning", "pages": 1])
        _ = try await report(f.token, t, id, ["state": "uploading", "pages": 1])
        let body = pdf("zwei-instanzen", padding: 200)
        let results = try await parallelResp(6) { i in
            let r = try await self.raw(i % 2 == 0 ? self.app1 : self.app2, .POST, self.base(t) + "/share?filename=Scan.pdf&title=Scan%20Flur", body: body, token: f.token,
                                       headers: ["Content-Type": "application/octet-stream", "Idempotency-Key": "scan-\(id)"])
            return Resp(status: r.status, json: r.json, headers: r.headers)
        }
        XCTAssertTrue(results.allSatisfy { $0.status == .created || $0.status == .conflict }, "\(results.map(\.status))")
        XCTAssertGreaterThanOrEqual(results.filter { $0.status == .created }.count, 1)
        try await aEq(try await count("dms_documents"), 1, "genau ein Dokument trotz gleichzeitiger Wiederholungen")
        try await aEq(try await count("idempotency_keys", where: "key = 'scan-\(id)'"), 1)
        let doc = try await db.raw("SELECT id::text AS v FROM dms_documents LIMIT 1").first()?.decode(column: "v", as: String.self) ?? ""
        let done = try await report(f.token, t, id, ["state": "done", "document_id": doc, "pages": 1], via: app2)
        XCTAssertEqual(done.status, .ok, "\(done.json)")
    }

    /// AK-BR1-4: derselbe Ablauf in einer Reihe: ein Dokument mit Quelle `share_ext` und Herkunft des Tokens; Wiederholung liefert dasselbe Dokument;
    /// anderer Inhalt unter demselben Schlüssel scheitert (422); das Dokument gehört dem Mandanten und ist über die Routen lesbar.
    func testAKBR1_4_sequenceYieldsSameDocumentAndSourceShareExt() async throws {
        let f = try await fixture()
        let t = f.w.tenantA
        let id = try await claimedJob(f, extra: ["title": "Scan Flur"])
        let first = try await raw(app1, .POST, base(t) + "/share?filename=Scan.pdf&title=Scan%20Flur", body: pdf("reihe"), token: f.token,
                                  headers: ["Content-Type": "application/octet-stream", "Idempotency-Key": "scan-\(id)"])
        XCTAssertEqual(first.status, .created, "\(first.json)")
        let again = try await raw(app2, .POST, base(t) + "/share?filename=Scan.pdf&title=Scan%20Flur", body: pdf("reihe"), token: f.token,
                                  headers: ["Content-Type": "application/octet-stream", "Idempotency-Key": "scan-\(id)"])
        XCTAssertEqual(again.status, .created)
        XCTAssertEqual(again.json["id"] as? String, first.json["id"] as? String)
        try await aEq(try await count("dms_documents"), 1)
        let other = try await raw(app1, .POST, base(t) + "/share?filename=Scan.pdf&title=Scan%20Flur", body: pdf("anderer-inhalt"), token: f.token,
                                  headers: ["Content-Type": "application/octet-stream", "Idempotency-Key": "scan-\(id)"])
        XCTAssertEqual(other.status, .unprocessableEntity)
        XCTAssertEqual(other.problemCode, "idempotency_key_reused")
        try await aEq(try await count("dms_documents"), 1)
        try await aEq(try await count("dms_ingest_items", where: "source = 'share_ext'"), 1)
        let doc = first.json["id"] as? String ?? ""
        let done = try await report(f.token, t, id, ["state": "scanning"])
        XCTAssertEqual(done.status, .ok)
        _ = try await report(f.token, t, id, ["state": "uploading", "pages": 3])
        let finished = try await report(f.token, t, id, ["state": "done", "document_id": doc, "pages": 3], via: app2)
        XCTAssertEqual(finished.status, .ok, "\(finished.json)")
        let seen = try await call(app1, .GET, scan(t) + "/jobs/\(id)", token: f.w.alice.token)
        XCTAssertEqual(seen.json["document_id"] as? String, doc.lowercased())
        let document = try await call(app1, .GET, base(t) + "/documents/\(doc)", token: f.w.alice.token)
        XCTAssertEqual(document.status, .ok)
        XCTAssertEqual(document.json["title"] as? String, "Scan Flur")
        // ein Dokument aus einem anderen Mandanten kann nicht als Ergebnis gemeldet werden
        let (bob, tenantB) = try await secondTenantOwner()
        let foreign = try await upload(bob, tenantB, pdf("fremd-b"))
        XCTAssertEqual(foreign.status, .created)
        let id2 = try await claimedJob(f)
        _ = try await report(f.token, t, id2, ["state": "scanning"])
        _ = try await report(f.token, t, id2, ["state": "uploading"])
        let steal = try await report(f.token, t, id2, ["state": "done", "document_id": foreign.json["id"] as? String ?? ""])
        XCTAssertEqual(steal.status, .unprocessableEntity)
        try await aEq(try await jobRow(id2, "state"), "uploading")
    }
}
