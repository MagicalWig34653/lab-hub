import XCTVapor
import Fluent
import SQLKit
@testable import HubCore
@testable import HubKit
@testable import HubModuleDMS

// WP-PA7 Teil 3 (AK-PA7-3): Der Prüflauf `dms.verify` wird ohne Hand periodisch eingeplant, alte Export-ZIPs werden nach der Frist entfernt.
// Beides läuft als Aufräumschritt der Worker (`jobSweeps`), alle Entscheidungen fallen in der Datenbank (`now()`, Sperren). Nur synthetische Dateien.

class DMSMaintenanceBase: DMSRevisionTestBase, @unchecked Sendable {
    var sqlApp2: any SQLDatabase { app2.db(.psql) as! any SQLDatabase }

    /// Der Aufräumschritt, wie ihn der Worker für diese Job-Art aufruft (Umgebung wie beim Prozess).
    func sweep(_ kind: String, _ environment: [String: String] = [:]) throws -> JobSweep {
        try XCTUnwrap(DMSModule().jobSweeps(environment: environment)[kind], "kein Aufräumschritt für \(kind)")
    }

    func runs(_ tenant: String) async throws -> Int64 { try await count("dms_integrity_runs", where: "tenant_id = '\(tenant)'") }

    /// Verschiebt alle Prüfläufe des Mandanten in die Vergangenheit (Datenbankzeit).
    func ageRuns(_ tenant: String, hours: Int) async throws {
        try await db.raw("UPDATE dms_integrity_runs SET created_at = created_at - make_interval(hours => \(unsafeRaw: String(hours))) WHERE tenant_id = '\(unsafeRaw: tenant)'").run()
    }

    func finishRuns() async throws {
        try await withWorker(kinds: [DMSIntegrity.kind]) { try await count("dms_integrity_runs", where: "state IN ('queued', 'running')") == 0 }
    }

    func secondTenant(_ w: World, name: String) async throws -> World {
        let id = (try await call(app1, .POST, "api/v1/tenants", json: ["name": name], token: w.alice.token)).json["id"] as! String
        let owner = try await addUser("owner", handle: "o\(UUID().uuidString.prefix(8).lowercased())", tenant: id, by: w.alice)
        try await setModule(id, true, by: owner)
        return World(alice: owner, tenantA: id)
    }

    struct Export { let id: String; let sha: String; let size: Int64 }

    /// Legt über die API einen Export an und lässt ihn von einem Worker fertigstellen.
    func finishedExport(_ w: World) async throws -> Export {
        let r = try await raw(app1, .POST, base(w.tenantA) + "/exports", body: Data("{}".utf8), token: w.alice.token, headers: ["Content-Type": "application/json"])
        XCTAssertEqual(r.status, .accepted, "\(r.json)")
        let id = r.json["id"] as! String
        try await withWorker(kinds: [DMSExport.kind]) { try await exportState(id) == "done" }
        return Export(id: id, sha: try await scalar("SELECT sha256 AS v FROM dms_exports WHERE id = '\(id)'", as: String.self),
                      size: try await scalar("SELECT size_bytes AS v FROM dms_exports WHERE id = '\(id)'", as: Int64.self))
    }

    func exportState(_ id: String) async throws -> String { try await scalar("SELECT state AS v FROM dms_exports WHERE id = '\(id)'", as: String.self) }

    func ageExport(_ id: String, days: Int) async throws {
        try await db.raw("UPDATE dms_exports SET finished_at = now() - make_interval(days => \(unsafeRaw: String(days))) WHERE id = '\(unsafeRaw: id)'").run()
    }

    func fileRows(_ tenant: String, _ sha: String) async throws -> Int64 { try await count("files", where: "tenant_id = '\(tenant)' AND sha256 = '\(sha)'") }
    func usedBytes(_ tenant: String) async throws -> Int64 {
        try await scalar("SELECT COALESCE(sum(size_bytes), 0)::bigint AS v FROM files WHERE tenant_id = '\(tenant)'", as: Int64.self)
    }
}

// MARK: AK-PA7-3 Prüflauf periodisch

final class DMSVerifyScheduleTests: DMSMaintenanceBase {

    /// AK-PA7-3: Ohne Hand entsteht für einen Mandanten mit Bestand genau ein Prüflauf (Lauf, Job, Audit); er läuft durch. Weitere Aufrufe ändern nichts.
    /// Ein Mandant ohne Dateien bekommt keinen Lauf.
    func testAKPA7_3_tenantWithDocumentsGetsExactlyOneScheduledRun() async throws {
        let w = try await world()
        let empty = try await secondTenant(w, name: "Leer")
        _ = try await newDoc(w.alice, w.tenantA, seed: "plan-1")
        let run = try sweep(DMSIntegrity.kind)
        try await run(db)
        try await aEq(try await runs(w.tenantA), 1)
        try await aEq(try await runs(empty.tenantA), 0)
        try await aEq(try await count("jobs", where: "kind = 'dms.verify' AND state = 'queued'"), 1)
        try await aEq(try await count("dms_integrity_runs", where: "requested_by IS NULL AND job_id IS NOT NULL"), 1)
        try await aEq(try await auditCount("dms.integrity.scheduled", tenant: w.tenantA), 1)
        try await run(db); try await run(sqlApp2)
        try await aEq(try await runs(w.tenantA), 1)
        try await finishRuns()
        try await aEq(try await count("dms_integrity_runs", where: "state = 'passed' AND files_checked = 1"), 1)
        try await run(db)
        try await aEq(try await runs(w.tenantA), 1)
    }

    /// AK-PA7-3: Periodisch: erst nach Ablauf des Abstands (Standard 7 Tage, Datenbankzeit) folgt der nächste Lauf.
    func testAKPA7_3_nextRunOnlyAfterTheInterval() async throws {
        let w = try await world()
        _ = try await newDoc(w.alice, w.tenantA, seed: "abstand")
        let run = try sweep(DMSIntegrity.kind)
        try await run(db); try await finishRuns()
        try await ageRuns(w.tenantA, hours: 167)
        try await run(db)
        try await aEq(try await runs(w.tenantA), 1, "6 Tage 23 Stunden: noch nicht fällig")
        try await ageRuns(w.tenantA, hours: 2)
        try await run(db); try await run(sqlApp2)
        try await aEq(try await runs(w.tenantA), 2)
    }

    /// AK-PA7-3: Abstand einstellbar (`DMS_VERIFY_INTERVAL_HOURS`), 0 schaltet den Zeitplan ab; ungültige Werte gelten als Standard.
    func testAKPA7_3_intervalIsConfigurableAndZeroDisables() async throws {
        let w = try await world()
        _ = try await newDoc(w.alice, w.tenantA, seed: "einstellbar")
        try await sweep(DMSIntegrity.kind, ["DMS_VERIFY_INTERVAL_HOURS": "0"])(db)
        try await aEq(try await runs(w.tenantA), 0)
        let hourly = try sweep(DMSIntegrity.kind, ["DMS_VERIFY_INTERVAL_HOURS": "1"])
        try await hourly(db); try await finishRuns()
        try await ageRuns(w.tenantA, hours: 2)
        try await sweep(DMSIntegrity.kind, ["DMS_VERIFY_INTERVAL_HOURS": "-5"])(db)   // ungültig: Standard 168 h
        try await aEq(try await runs(w.tenantA), 1)
        try await hourly(db)
        try await aEq(try await runs(w.tenantA), 2)
    }

    /// AK-PA7-3: Ein Lauf von Hand zählt für den Abstand; ein noch offener Lauf (Job wartet oder läuft) wird auch nach dem Abstand nicht verdoppelt.
    func testAKPA7_3_manualRunCountsAndOpenRunsDoNotPileUp() async throws {
        let w = try await world()
        _ = try await newDoc(w.alice, w.tenantA, seed: "von-hand")
        let started = try await raw(app1, .POST, base(w.tenantA) + "/integrity-runs", token: w.alice.token)
        XCTAssertEqual(started.status, .accepted, "\(started.json)")
        let run = try sweep(DMSIntegrity.kind)
        try await run(db)
        try await aEq(try await runs(w.tenantA), 1)
        try await ageRuns(w.tenantA, hours: 400)   // Rückstau: Job wartet noch
        try await run(db)
        try await aEq(try await runs(w.tenantA), 1)
        // Job endgültig gescheitert, Lauf bleibt „queued“ liegen: nach dem Abstand kommt ein neuer
        try await db.raw("UPDATE jobs SET state = 'failed_permanent' WHERE kind = 'dms.verify'").run()
        try await run(db)
        try await aEq(try await runs(w.tenantA), 2)
    }

    /// AK-PA7-3: Ein Lauf mit Zustand `error` (Speicher nicht erreichbar) wird nach einem Tag wiederholt, nicht erst nach dem vollen Abstand.
    func testAKPA7_3_errorRunIsRetriedAfterOneDay() async throws {
        let w = try await world()
        _ = try await newDoc(w.alice, w.tenantA, seed: "fehler")
        let run = try sweep(DMSIntegrity.kind)
        try await run(db)
        try await db.raw("UPDATE jobs SET state = 'failed_permanent' WHERE kind = 'dms.verify'").run()
        try await db.raw("UPDATE dms_integrity_runs SET state = 'error', error_code = 'store_unavailable', finished_at = now()").run()
        try await ageRuns(w.tenantA, hours: 23)
        try await run(db)
        try await aEq(try await runs(w.tenantA), 1)
        try await ageRuns(w.tenantA, hours: 2)
        try await run(db)
        try await aEq(try await runs(w.tenantA), 2)
    }

    /// AK-PA7-3: Abgeschaltetes DMS (Mandant oder Installation) bekommt keinen geplanten Lauf.
    func testAKPA7_3_disabledModuleIsNotScheduled() async throws {
        let w = try await world()
        _ = try await newDoc(w.alice, w.tenantA, seed: "aus")
        let run = try sweep(DMSIntegrity.kind)
        try await setModule(w.tenantA, false, by: w.alice)
        try await run(db)
        try await aEq(try await runs(w.tenantA), 0)
        try await setModule(w.tenantA, true, by: w.alice)
        try await db.raw("INSERT INTO installation_modules (module_key, enabled) VALUES ('dms', false) ON CONFLICT (module_key) DO UPDATE SET enabled = false").run()
        try await run(db)
        try await aEq(try await runs(w.tenantA), 0)
        try await db.raw("UPDATE installation_modules SET enabled = true WHERE module_key = 'dms'").run()
        try await run(db)
        try await aEq(try await runs(w.tenantA), 1)
    }

    /// Stateless (ADR 0003): Zwei Instanzen prüfen gleichzeitig und wiederholt; je Mandant entsteht genau ein Lauf.
    func testAKPA7_3_twoInstancesRacingScheduleOneRunPerTenant() async throws {
        let w = try await world()
        var tenants = [w]
        for i in 0..<3 { tenants.append(try await secondTenant(w, name: "Renn \(i)")) }
        for t in tenants { _ = try await newDoc(t.alice, t.tenantA, seed: "renn-\(t.tenantA)") }
        let run = try sweep(DMSIntegrity.kind)
        let a = db!, b = sqlApp2
        try await withThrowingTaskGroup(of: Void.self) { group in
            for i in 0..<12 { group.addTask { try await run(i % 2 == 0 ? a : b) } }
            try await group.waitForAll()
        }
        for t in tenants {
            try await aEq(try await runs(t.tenantA), 1, "genau ein Lauf je Mandant")
            try await aEq(try await auditCount("dms.integrity.scheduled", tenant: t.tenantA), 1)
        }
        try await aEq(try await count("jobs", where: "kind = 'dms.verify'"), 4)
    }
}

// MARK: AK-PA7-3 Alte Export-ZIPs entfernen

final class DMSExportExpiryTests: DMSMaintenanceBase {

    /// AK-PA7-3: Nach der Frist (Standard 30 Tage ab Fertigstellung) verschwinden Datei, Objekt und Download; der Eintrag bleibt als `expired` mit Prüfsumme.
    /// Jüngere Exporte und Dokumente bleiben unberührt, die Quota wird frei.
    func testAKPA7_3_expiredExportZipIsRemoved() async throws {
        let w = try await world()
        _ = try await newDoc(w.alice, w.tenantA, seed: "frist")
        let old = try await finishedExport(w)
        let young = try await finishedExport(w)
        try await ageExport(old.id, days: 31)
        try await ageExport(young.id, days: 29)
        let before = try await usedBytes(w.tenantA)
        let expire = try sweep(DMSExport.kind)
        try await expire(db)

        try await aEq(try await exportState(old.id), "expired")
        try await aEq(try await fileRows(w.tenantA, old.sha), 0)
        try await aEq(try await objectCount(old.sha), 0, "Bytes entfernt")
        try await aEq(try await usedBytes(w.tenantA), before - old.size)
        try await aEq(try await auditCount("dms.export.expired", tenant: w.tenantA), 1)
        let out = try await raw(app2, .GET, base(w.tenantA) + "/exports/\(old.id)", token: w.alice.token)
        XCTAssertEqual(out.json["state"] as? String, "expired", "\(out.json)")
        XCTAssertNotNil(out.json["expired_at"] as? String)
        XCTAssertEqual(out.json["sha256"] as? String, old.sha, "Prüfsumme bleibt als Nachweis")
        let gone = try await raw(app1, .GET, base(w.tenantA) + "/exports/\(old.id)/file", token: w.alice.token)
        XCTAssertEqual(gone.status, .notFound)

        try await aEq(try await exportState(young.id), "done")
        let kept = try await raw(app1, .GET, base(w.tenantA) + "/exports/\(young.id)/file", token: w.alice.token)
        XCTAssertEqual(kept.status, .ok); XCTAssertEqual(hex(kept.body), young.sha)
        try await aEq(try await count("dms_document_files", where: "role = 'original'"), 1)
        try await expire(sqlApp2)
        try await aEq(try await auditCount("dms.export.expired", tenant: w.tenantA), 1, "wiederholbar ohne Wirkung")
    }

    /// AK-PA7-3: Frist einstellbar (`DMS_EXPORT_RETENTION_DAYS`), 0 behält alles.
    func testAKPA7_3_exportRetentionIsConfigurableAndZeroKeeps() async throws {
        let w = try await world()
        _ = try await newDoc(w.alice, w.tenantA, seed: "frist-env")
        let export = try await finishedExport(w)
        try await ageExport(export.id, days: 400)
        try await sweep(DMSExport.kind, ["DMS_EXPORT_RETENTION_DAYS": "0"])(db)
        try await aEq(try await exportState(export.id), "done")
        try await ageExport(export.id, days: 2)
        try await sweep(DMSExport.kind, ["DMS_EXPORT_RETENTION_DAYS": "abc"])(db)   // ungültig: Standard 30
        try await aEq(try await exportState(export.id), "done")
        try await sweep(DMSExport.kind, ["DMS_EXPORT_RETENTION_DAYS": "1"])(db)
        try await aEq(try await exportState(export.id), "expired")
    }

    /// AK-PA7-3: Nutzt noch jemand dieselben Bytes (eine Dokumentdatei oder ein zweiter, jüngerer Export), bleiben Datei und Objekt erhalten.
    func testAKPA7_3_expiryKeepsBytesThatAreStillReferenced() async throws {
        let w = try await world()
        let doc = try await newDoc(w.alice, w.tenantA, seed: "geteilt")["id"] as! String
        let asDocument = try await finishedExport(w)
        // Die Upload-Route nimmt kein ZIP an; eine Dokumentdatei auf derselben `files`-Zeile entsteht daher direkt.
        try await db.raw("""
            INSERT INTO dms_document_files (tenant_id, document_id, role, file_id, mime, size_bytes, sha256)
            SELECT f.tenant_id, '\(unsafeRaw: doc)', 'derivative', f.id, 'application/zip', f.size_bytes, f.sha256 FROM files f
            WHERE f.tenant_id = '\(unsafeRaw: w.tenantA)' AND f.sha256 = \(bind: asDocument.sha)
            """).run()
        try await ageExport(asDocument.id, days: 31)

        let first = try await finishedExport(w)
        let twin = UUID()
        try await db.raw("""
            INSERT INTO dms_exports (id, tenant_id, state, finished_at, document_count, file_count, size_bytes, sha256, manifest_sha256, file_id)
            SELECT \(bind: twin), tenant_id, 'done', now(), document_count, file_count, size_bytes, sha256, manifest_sha256, file_id FROM dms_exports WHERE id = '\(unsafeRaw: first.id)'
            """).run()
        try await ageExport(first.id, days: 31)

        let expire = try sweep(DMSExport.kind)
        try await expire(db)
        try await aEq(try await exportState(asDocument.id), "expired")
        try await aEq(try await exportState(first.id), "expired")
        for sha in [asDocument.sha, first.sha] {
            try await aEq(try await fileRows(w.tenantA, sha), 1)
            try await aGE(try await objectCount(sha), 1)
        }
        let stillThere = try await raw(app1, .GET, base(w.tenantA) + "/exports/\(twin.uuidString)/file", token: w.alice.token)
        XCTAssertEqual(stillThere.status, .ok); XCTAssertEqual(hex(stillThere.body), first.sha)
        // Läuft auch der Zwilling ab, geht das ZIP
        try await ageExport(twin.uuidString, days: 31)
        try await expire(db)
        try await aEq(try await fileRows(w.tenantA, first.sha), 0)
        try await aEq(try await objectCount(first.sha), 0)
        try await aEq(try await fileRows(w.tenantA, asDocument.sha), 1)
    }

    /// Stateless (ADR 0003): Zwei Instanzen räumen gleichzeitig auf; jeder Export läuft genau einmal ab.
    func testAKPA7_3_twoInstancesExpireEachExportOnce() async throws {
        let w = try await world()
        _ = try await newDoc(w.alice, w.tenantA, seed: "zwei-frist")
        var exports: [Export] = []
        for _ in 0..<4 { exports.append(try await finishedExport(w)) }
        for e in exports { try await ageExport(e.id, days: 31) }
        let expire = try sweep(DMSExport.kind)
        let a = db!, b = sqlApp2
        try await withThrowingTaskGroup(of: Void.self) { group in
            for i in 0..<8 { group.addTask { try await expire(i % 2 == 0 ? a : b) } }
            try await group.waitForAll()
        }
        try await aEq(try await count("dms_exports", where: "state = 'expired' AND file_id IS NULL"), 4)
        try await aEq(try await auditCount("dms.export.expired", tenant: w.tenantA), 4)
        for e in exports { try await aEq(try await objectCount(e.sha), 0) }
    }

    /// Migration `dms_032_export_expiry`: Revert stellt den alten Zustandsraum her (abgelaufene Exporte werden `failed`/`expired`), erneutes Anwenden geht.
    func testAKPA7_3_migrationRevertsAndReapplies() async throws {
        let w = try await world()
        _ = try await newDoc(w.alice, w.tenantA, seed: "migration")
        let export = try await finishedExport(w)
        try await ageExport(export.id, days: 31)
        try await sweep(DMSExport.kind)(db)
        let migration = try XCTUnwrap(DMSModule().migrations.first { $0.name == "dms_032_export_expiry" } as? any AsyncMigration)
        try await migration.revert(on: app1.db(.psql))
        try await aEq(try await exportState(export.id), "failed")
        try await aEq(try await count("dms_exports", where: "error_code = 'expired'"), 1)
        try await aEq(try await count("information_schema.columns", where: "table_name = 'dms_exports' AND column_name = 'expired_at'"), 0)
        try await migration.prepare(on: app1.db(.psql))
        try await aEq(try await count("information_schema.columns", where: "table_name = 'dms_exports' AND column_name = 'expired_at'"), 1)
    }
}

// MARK: AK-PA7-3 E2E mit zwei echten Worker-Prozessen

/// Zwei echte `App worker`-Prozesse (zwei Instanzen) gegen dieselbe Datenbank: Bestand über die API, kein Auslösen von Hand.
final class DMSMaintenanceE2ETests: DMSMaintenanceBase, @unchecked Sendable {
    override var testModules: [any HubModule] { InstalledModules.all }

    private var logs: [URL] = []

    private func startWorker(_ name: String) throws -> Process {
        guard let bin = WorkerProcessTests.appBinary else { throw XCTSkip("App-Executable nicht gefunden (neben dem Testbundle); Mehrprozess-Test übersprungen") }
        let log = FileManager.default.temporaryDirectory.appendingPathComponent("lh-pa7-\(name)-\(UUID().uuidString).log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        logs.append(log)
        let handle = try FileHandle(forWritingTo: log)
        let p = Process()
        p.executableURL = bin
        p.arguments = ["worker", "--kinds", "dms.verify,dms.export", "--lease-seconds", "30", "--poll-ms", "100", "--retry-backoff-seconds", "0"]
        var env = ProcessInfo.processInfo.environment
        for (k, v) in HubTestDB.env { env[k] = v }
        for k in ["DMS_VERIFY_INTERVAL_HOURS", "DMS_EXPORT_RETENTION_DAYS", "OBJECT_STORE"] { env[k] = nil }   // Standardwerte wie im Compose
        p.environment = env
        p.standardOutput = handle; p.standardError = handle
        try p.run()
        return p
    }

    private func lockWaiters() async throws -> Int64 {
        try await count("pg_stat_activity", where: "datname = current_database() AND wait_event_type = 'Lock'")
    }

    /// AK-PA7-3 (E2E): Beide Instanzen sehen denselben fälligen Mandanten im selben Moment (der Test hält die Tabelle der Läufe gesperrt, bis beide warten).
    /// Es entsteht genau ein geplanter Prüflauf. Nach Ablauf des Abstands folgt genau ein weiterer; ein abgelaufenes Export-ZIP wird genau einmal entfernt.
    func testAKPA7_3_twoWorkerProcessesScheduleExactlyOneRunAndExpireTheExport() async throws {
        try XCTSkipIf(WorkerProcessTests.appBinary == nil, "App-Executable nicht gefunden (neben dem Testbundle); Mehrprozess-Test übersprungen")
        let w = try await world()
        for i in 0..<3 { _ = try await newDoc(w.alice, w.tenantA, seed: "e2e-\(i)") }
        let processes = UnsafeSendableBox<[Process]>([])
        defer {
            for p in processes.value where p.isRunning { kill(p.processIdentifier, SIGKILL) }
            for log in logs { try? FileManager.default.removeItem(at: log) }
        }

        // Tor: solange diese Transaktion läuft, kann niemand einen Lauf einfügen. Lesen bleibt möglich.
        try await app2.db(.psql).transaction { tx in
            try await sql(tx).raw("LOCK TABLE dms_integrity_runs IN EXCLUSIVE MODE").run()
            processes.value = [try self.startWorker("a"), try self.startWorker("b")]
            let end = Date().addingTimeInterval(60)
            while try await self.lockWaiters() < 2, Date() < end { try await Task.sleep(for: .milliseconds(100)) }
            let waiting = try await self.lockWaiters()
            XCTAssertGreaterThanOrEqual(waiting, 2, "beide Instanzen müssen gleichzeitig am Einplanen sein")
        }
        let workers = processes.value

        try await waitFor("geplanter Lauf bestanden") { try await count("dms_integrity_runs", where: "state = 'passed'") >= 1 }
        try await Task.sleep(for: .seconds(3))   // rund 30 weitere Durchgänge je Instanz
        try await aEq(try await runs(w.tenantA), 1, "genau ein geplanter Prüflauf")
        try await aEq(try await count("dms_integrity_runs", where: "state = 'passed' AND requested_by IS NULL AND files_checked = 3 AND files_bad = 0 AND chain_ok"), 1)
        try await aEq(try await count("jobs", where: "kind = 'dms.verify'"), 1)
        try await aEq(try await auditCount("dms.integrity.scheduled", tenant: w.tenantA), 1)
        try await aEq(try await auditCount("dms.integrity.checked", tenant: w.tenantA), 1)

        // periodisch: der Abstand ist abgelaufen
        try await ageRuns(w.tenantA, hours: 169)
        try await waitFor("zweiter Lauf bestanden") { try await count("dms_integrity_runs", where: "state = 'passed'") >= 2 }
        try await Task.sleep(for: .seconds(2))
        try await aEq(try await runs(w.tenantA), 2)
        try await aEq(try await auditCount("dms.integrity.scheduled", tenant: w.tenantA), 2)

        // Export über die API, eine der Instanzen erzeugt ihn; nach Ablauf der Frist räumt eine ihn weg
        let r = try await raw(app1, .POST, base(w.tenantA) + "/exports", body: Data("{}".utf8), token: w.alice.token, headers: ["Content-Type": "application/json"])
        XCTAssertEqual(r.status, .accepted, "\(r.json)")
        let export = r.json["id"] as! String
        try await waitFor("Export fertig") { try await exportState(export) == "done" }
        let sha = try await scalar("SELECT sha256 AS v FROM dms_exports WHERE id = '\(export)'", as: String.self)
        try await aGE(try await objectCount(sha), 1)
        try await ageExport(export, days: 31)
        try await waitFor("Export abgelaufen") { try await exportState(export) == "expired" }
        try await waitFor("ZIP entfernt") { try await objectCount(sha) == 0 }
        try await Task.sleep(for: .seconds(2))
        try await aEq(try await auditCount("dms.export.expired", tenant: w.tenantA), 1)
        try await aEq(try await fileRows(w.tenantA, sha), 0)

        XCTAssertTrue(workers.allSatisfy(\.isRunning), "beide Instanzen laufen noch")
        for log in logs {
            let text = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
            XCTAssertTrue(text.contains("Worker gestartet"), text)
            XCTAssertFalse(text.contains("Aufräumschritt fehlgeschlagen"), text)
        }
        for p in workers { kill(p.processIdentifier, SIGTERM) }
        let end = Date().addingTimeInterval(20)
        while workers.contains(where: \.isRunning), Date() < end { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertTrue(workers.allSatisfy { !$0.isRunning && $0.terminationStatus == 0 })
    }
}
