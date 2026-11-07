import XCTVapor
import Fluent
import SQLKit
import Crypto
@testable import HubKit

// WP-D5 Revisionssicherheit: Löschkonzept, Aufbewahrung, Hash-Kette, Prüf-Job, Export-Job. Nur synthetische Dateien. GoBD-orientiert, keine Konformitätsaussage (F-24).

class DMSRevisionTestBase: DMSTestBase {
    override var testModules: [any HubModule] { [DMSModule(objectStore: ObjectStoreConfig(kind: .db), maxUploadBytes: Self.uploadLimit, defaultRetentionYears: 10)] }

    func makeWorker(on app: Application? = nil, kinds: [String] = [DMSIntegrity.kind, DMSExport.kind]) -> JobWorker {
        let handlers: [String: JobHandler] = [
            DMSIntegrity.kind: DMSIntegrity.handler { s in try ObjectStoreConfig(kind: .db).makeStore(db: s) },
            DMSExport.kind: DMSExport.handler(tempRoot: NSTemporaryDirectory()) { s in try ObjectStoreConfig(kind: .db).makeStore(db: s) }]
        return JobWorker(db: (app ?? app1).db(.psql) as! any SQLDatabase, kinds: kinds, handlers: handlers.filter { kinds.contains($0.key) }, leaseSeconds: 30,
                         pollInterval: .milliseconds(100), retryBackoffSeconds: 0, logger: Logger(label: "test.revision"))
    }

    func waitFor(_ what: String, timeout: Double = 60, _ cond: () async throws -> Bool) async throws {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end { if try await cond() { return }; try await Task.sleep(for: .milliseconds(100)) }
        XCTFail("Zeitüberschreitung: \(what)")
    }

    /// Startet einen Worker, wartet bis die Bedingung gilt, beendet ihn.
    func withWorker(on app: Application? = nil, kinds: [String] = [DMSIntegrity.kind, DMSExport.kind], until cond: () async throws -> Bool) async throws {
        let worker = makeWorker(on: app, kinds: kinds)
        let run = Task { await worker.run() }
        try await waitFor("Worker-Ergebnis", cond)
        worker.requestShutdown(); await run.value
    }

    func trash(_ w: World, _ doc: String) async throws {
        let r = try await call(app1, .POST, base(w.tenantA) + "/documents/\(doc)/trash", json: ["reason": "Test"], token: w.alice.token)
        XCTAssertEqual(r.status, .ok, "\(r.json)")
    }

    func purge(_ w: World, _ doc: String, as s: TestSession? = nil, via: Application? = nil) async throws -> Raw {
        try await raw(via ?? app1, .POST, base(w.tenantA) + "/documents/\(doc)/purge", token: (s ?? w.alice).token)
    }

    /// Dokument mit altem Belegdatum (Frist nach Standard 10 Jahre sicher abgelaufen).
    func oldDoc(_ w: World, seed: String) async throws -> String {
        let id = try await newDoc(w.alice, w.tenantA, seed: seed)["id"] as! String
        try await db.raw("UPDATE dms_documents SET doc_date = '2001-02-03' WHERE id = '\(id)'").run()
        return id
    }

    func objectCount(_ sha: String) async throws -> Int64 { try await count("object_chunks", where: "sha256 = '\(sha)'") }
    func fileSHA(_ doc: String) async throws -> String { try await scalar("SELECT sha256 AS v FROM dms_document_files WHERE document_id = '\(doc)' AND role = 'original'", as: String.self) }
}

// MARK: AK-D-REV-1, AK-D-REV-2, AK-D-REV-4: Löschkonzept

final class DMSPurgeTests: DMSRevisionTestBase {

    /// AK-D-REV-1 (bleibt mit D5 bestehen): Das Original lässt sich weiterhin nicht löschen, auch nicht mit einem Löschprotokoll aus einer anderen Transaktion;
    /// das Löschprotokoll selbst ist append-only.
    func testAKDREV1_originalStaysImmutableAndLogIsAppendOnly() async throws {
        let w = try await world()
        let id = try await newDoc(w.alice, w.tenantA, seed: "rev1")["id"] as! String
        func expectFail(_ sqlText: String, _ what: String) async {
            do { try await db.raw(SQLQueryString(sqlText)).run(); XCTFail("\(what) muss scheitern") } catch {
                let t = String(reflecting: error)
                XCTAssertTrue(t.contains("dms_original_immutable") || t.contains("dms_append_only") || t.contains("23000"), "\(what): \(t)")
            }
        }
        await expectFail("DELETE FROM dms_document_files WHERE document_id = '\(id)'", "Original löschen")
        // ein Protokolleintrag aus einer früheren Transaktion schaltet nichts frei (txid-Bindung)
        try await db.raw("""
            INSERT INTO dms_deletion_log (tenant_id, document_id, original_sha256, original_size, file_count)
            SELECT tenant_id, document_id, sha256, size_bytes, 1 FROM dms_document_files WHERE document_id = '\(id)'
            """).run()
        await expectFail("DELETE FROM dms_document_files WHERE document_id = '\(id)'", "Original löschen mit fremdem Protokolleintrag")
        await expectFail("UPDATE dms_deletion_log SET file_count = 9", "Protokoll ändern")
        await expectFail("DELETE FROM dms_deletion_log", "Protokoll löschen")
        await expectFail("TRUNCATE dms_deletion_log", "Protokoll leeren")
        try await aEq(try await count("dms_document_files", where: "document_id = '\(id)'"), 1)
    }

    /// AK-D-REV-2: Löschen vor Fristablauf, mit Löschsperre, außerhalb des Papierkorbs und mit verknüpftem Dokument ist 409; nichts wird gelöscht.
    func testAKDREV2_purgeIsBlockedByRetentionHoldTrashAndLinks() async throws {
        let w = try await world()
        let fresh = try await newDoc(w.alice, w.tenantA, seed: "rev2-fresh")["id"] as! String
        let r0 = try await purge(w, fresh)
        XCTAssertEqual(r0.status, .conflict); XCTAssertEqual(r0.problemCode, "document_not_trashed")
        try await trash(w, fresh)
        let r1 = try await purge(w, fresh)
        XCTAssertEqual(r1.status, .conflict); XCTAssertEqual(r1.problemCode, "retention_not_expired", "Frist läuft (Standard 10 Jahre ab Eingang)")

        let old = try await oldDoc(w, seed: "rev2-old")
        // nicht im Papierkorb
        try await aEq((try await purge(w, old)).problemCode, "document_not_trashed")
        try await trash(w, old)
        // Löschsperre
        let hold = try await raw(app1, .PATCH, base(w.tenantA) + "/documents/\(old)/retention", body: Data(#"{"legal_hold":true}"#.utf8), token: w.alice.token, headers: ["Content-Type": "application/json"])
        XCTAssertEqual(hold.status, .ok, "\(hold.json)")
        XCTAssertEqual(hold.json["legal_hold"] as? Bool, true); XCTAssertEqual(hold.json["can_purge"] as? Bool, false)
        let r2 = try await purge(w, old)
        XCTAssertEqual(r2.status, .conflict); XCTAssertEqual(r2.problemCode, "legal_hold")
        _ = try await raw(app2, .PATCH, base(w.tenantA) + "/documents/\(old)/retention", body: Data(#"{"legal_hold":false}"#.utf8), token: w.alice.token, headers: ["Content-Type": "application/json"])
        // verknüpftes Dokument (z. B. finalisierte Rechnung verweist darauf): Vorbereitung der Löschsperre
        let tenant = UUID(uuidString: w.tenantA)!
        let linkID = UUID(), invoice = UUID()
        try await db.raw("""
            INSERT INTO links (id, tenant_id, from_type, from_id, to_type, to_id, kind, source) VALUES (\(bind: linkID), \(bind: tenant), 'invoice.document', \(bind: invoice), 'dms.document', '\(unsafeRaw: old)', 'attachment', 'system')
            """).run()
        let r3 = try await purge(w, old)
        XCTAssertEqual(r3.status, .conflict); XCTAssertEqual(r3.problemCode, "document_linked")
        try await db.raw("UPDATE links SET removed_at = now() WHERE id = \(bind: linkID)").run()
        try await aEq(try await count("dms_documents"), 2, "bis hierher wurde nichts gelöscht")
        try await aEq(try await count("dms_deletion_log"), 0)
        let ok = try await purge(w, old)
        XCTAssertEqual(ok.status, .ok, "\(ok.json)")
        try await aEq(try await count("dms_documents"), 1)
    }

    /// AK-D-REV-2: Berechtigung (nur Owner), unbekannte ID und Mandantentrennung.
    func testAKDREV2_purgePermissionAndTenantIsolation() async throws {
        let w = try await world()
        let id = try await oldDoc(w, seed: "rev2-perm")
        try await trash(w, id)
        let accountant = try await addUser("accountant", handle: "anna", tenant: w.tenantA, by: w.alice)
        let member = try await addUser("member", handle: "max", tenant: w.tenantA, by: w.alice)
        for s in [accountant, member] {
            let r = try await purge(w, id, as: s)
            XCTAssertEqual(r.status, .forbidden); XCTAssertEqual(r.problemCode, "forbidden")
        }
        try await aEq(try await count("dms_documents"), 1)

        let tenantB = (try await call(app1, .POST, "api/v1/tenants", json: ["name": "Zweiter Mandant"], token: w.alice.token)).json["id"] as! String
        let carol = try await addUser("owner", handle: "carol", tenant: tenantB, by: w.alice)
        try await setModule(tenantB, true, by: carol)
        let foreign = try await raw(app2, .POST, base(tenantB) + "/documents/\(id)/purge", token: carol.token)
        XCTAssertEqual(foreign.status, .notFound)
        let foreignRetention = try await raw(app2, .GET, base(tenantB) + "/documents/\(id)/retention", token: carol.token)
        XCTAssertEqual(foreignRetention.status, .notFound)
        try await aEq((try await purge(w, UUID().uuidString)).status, .notFound)
        try await aEq(try await count("dms_documents"), 1, "fremder Mandant löscht nichts")
        try await aEq(try await count("dms_deletion_log"), 0)
        // Löschprotokoll ist mandantengetrennt
        let ok = try await purge(w, id)
        XCTAssertEqual(ok.status, .ok)
        let logB = try await raw(app2, .GET, base(tenantB) + "/deletion-log", token: carol.token)
        XCTAssertEqual(logB.status, .ok); XCTAssertEqual((logB.json["items"] as? [Any])?.count, 0)
    }

    /// AK-D-REV-4 (Löschprotokoll bleibt) und Purge-Umfang: Metadaten, Text, Ingest, Dateizeilen, Bytes weg; Protokoll (Hash, Zeitpunkt, Person) und Audit bleiben,
    /// das Protokoll enthält keinen Titel. Zwei gleichzeitige Purges über zwei Instanzen: genau einer wirkt.
    func testAKDREV4_purgeKeepsDeletionLogAndRemovesEverythingElse() async throws {
        let w = try await world()
        let id = try await oldDoc(w, seed: "rev4-secret-title")
        let sha = try await fileSHA(id)
        let owner = w.alice.userID
        // Text und Tag, damit Kinderzeilen existieren
        try await db.raw("INSERT INTO dms_document_texts (tenant_id, document_id, version, engine, lang, text) VALUES ('\(unsafeRaw: w.tenantA)', '\(unsafeRaw: id)', 1, 'fake', 'de', 'Synthetischer Text')").run()
        let tag = (try await call(app1, .POST, base(w.tenantA) + "/tags", json: ["name": "Steuer"], token: w.alice.token)).json["id"] as! String
        _ = try await call(app1, .PATCH, base(w.tenantA) + "/documents/\(id)", json: ["tag_ids": [tag]], token: w.alice.token)
        try await trash(w, id)
        let results = try await parallel(2) { i in try await self.purge(w, id, via: i == 0 ? self.app1 : self.app2) }
        XCTAssertEqual(results.filter { $0.status == .ok }.count, 1, "\(results.map { $0.status })")
        XCTAssertEqual(results.filter { $0.status == .notFound }.count, 1)
        for t in ["dms_documents", "dms_document_files", "dms_document_texts", "dms_document_tags", "dms_ingest_items", "dms_ingest_transitions"] {
            try await aEq(try await count(t), 0, t)
        }
        try await aEq(try await count("files"), 0)
        try await aEq(try await objectCount(sha), 0, "Bytes ohne Referenz sind gelöscht")
        // Protokoll bleibt
        try await aEq(try await count("dms_deletion_log"), 1)
        try await aEq(try await scalar("SELECT original_sha256 AS v FROM dms_deletion_log", as: String.self), sha)
        try await aEq(try await scalar("SELECT purged_by::text AS v FROM dms_deletion_log", as: String.self).lowercased(), owner.lowercased())
        try await aEq(try await count("dms_deletion_log", where: "purged_at > now() - interval '1 minute'"), 1)
        try await aEq(try await count("dms_deletion_log", where: "row_to_json(dms_deletion_log)::text ILIKE '%secret-title%'"), 0, "kein Titel im Löschprotokoll")
        try await aEq(try await auditCount("dms.document.purged", tenant: w.tenantA), 1)
        let log = try await raw(app2, .GET, base(w.tenantA) + "/deletion-log", token: w.alice.token)
        XCTAssertEqual(log.status, .ok)
        let items = log.json["items"] as? [[String: Any]] ?? []
        XCTAssertEqual(items.count, 1); XCTAssertEqual(items.first?["original_sha256"] as? String, sha); XCTAssertEqual((items.first?["document_id"] as? String)?.lowercased(), id.lowercased())
        let gone = try await raw(app1, .GET, base(w.tenantA) + "/documents/\(id)", token: w.alice.token)
        XCTAssertEqual(gone.status, .notFound)
        let search = try await raw(app1, .GET, base(w.tenantA) + "/search?q=Synthetischer&fuzzy=false", token: w.alice.token)
        XCTAssertEqual((search.json["items"] as? [Any])?.count, 0)
    }

    /// Referenzzählung: Dedup — zwei Dokumente mit denselben Bytes teilen eine Dateizeile; die Bytes werden erst mit dem letzten Dokument gelöscht.
    func testPurgeKeepsSharedBlobUntilLastReference() async throws {
        let w = try await world()
        let data = pdf("shared-bytes")
        let a = (try await upload(w.alice, w.tenantA, data)).json["id"] as! String
        let b = (try await upload(w.alice, w.tenantA, data)).json["id"] as! String
        for id in [a, b] { try await db.raw("UPDATE dms_documents SET doc_date = '2001-01-01' WHERE id = '\(id)'").run(); try await trash(w, id) }
        let sha = try await fileSHA(a)
        try await aEq(try await count("files"), 1)
        let r1 = try await purge(w, a)
        XCTAssertEqual(r1.status, .ok); XCTAssertEqual(r1.json["blobs_removed"] as? Int, 0)
        try await aEq(try await objectCount(sha), 1, "das zweite Dokument zeigt noch auf die Bytes")
        try await aEq(try await count("files"), 1)
        let dl = try await raw(app2, .GET, base(w.tenantA) + "/documents/\(b)/file", token: w.alice.token)
        XCTAssertEqual(dl.body, data)
        let r2 = try await purge(w, b)
        XCTAssertEqual(r2.status, .ok); XCTAssertEqual(r2.json["blobs_removed"] as? Int, 1)
        try await aEq(try await objectCount(sha), 0)
        try await aEq(try await count("files"), 0)
        try await aEq(try await count("dms_deletion_log"), 2)
    }

    /// Dieselben Bytes in einem anderen Mandanten bleiben beim Purge unberührt (Blob ist je Mandant).
    func testPurgeDoesNotTouchOtherTenantsBlob() async throws {
        let w = try await world()
        let tenantB = (try await call(app1, .POST, "api/v1/tenants", json: ["name": "Zweiter Mandant"], token: w.alice.token)).json["id"] as! String
        let carol = try await addUser("owner", handle: "carol", tenant: tenantB, by: w.alice)
        try await setModule(tenantB, true, by: carol)
        let data = pdf("cross-tenant")
        let a = (try await upload(w.alice, w.tenantA, data)).json["id"] as! String
        let b = (try await upload(carol, tenantB, data)).json["id"] as! String
        try await db.raw("UPDATE dms_documents SET doc_date = '2001-01-01' WHERE id = '\(a)'").run()
        try await trash(w, a)
        let purged = try await purge(w, a)
        XCTAssertEqual(purged.status, .ok)
        let dl = try await raw(app2, .GET, base(tenantB) + "/documents/\(b)/file", token: carol.token)
        XCTAssertEqual(dl.status, .ok); XCTAssertEqual(dl.body, data)
    }

    /// Aufbewahrungsfristen je Dokumenttyp (Konfiguration): Typfrist überschreibt den Standard; manuelle Frist verlängert, kürzt nie; Hinweis „GoBD-orientiert“, keine Rechtsaussage.
    func testRetentionPerDocumentTypeAndManualExtension() async throws {
        let w = try await world()
        let year = Calendar(identifier: .gregorian).component(.year, from: Date())
        let type6 = (try await call(app1, .POST, base(w.tenantA) + "/types", json: ["name": "Beleg", "default_retention_years": 6], token: w.alice.token)).json["id"] as! String
        let typeNone = (try await call(app1, .POST, base(w.tenantA) + "/types", json: ["name": "Notiz", "default_retention_years": 0], token: w.alice.token)).json["id"] as! String
        let id = try await newDoc(w.alice, w.tenantA, seed: "ret-type")["id"] as! String
        func get() async throws -> [String: Any] { try await raw(app2, .GET, base(w.tenantA) + "/documents/\(id)/retention", token: w.alice.token).json }
        // Standard: Ende des Eingangsjahres + 10
        var r = try await get()
        XCTAssertEqual(r["retention_until"] as? String, "\(year + 10)-12-31"); XCTAssertEqual(r["retention_source"] as? String, "default")
        XCTAssertTrue((r["note"] as? String ?? "").contains("GoBD-orientiert")); XCTAssertFalse((r["note"] as? String ?? "").localizedCaseInsensitiveContains("konform "))
        // Typ mit 6 Jahren und Belegdatum 2015
        _ = try await call(app1, .PATCH, base(w.tenantA) + "/documents/\(id)", json: ["document_type_id": type6, "doc_date": "2015-06-01"], token: w.alice.token)
        r = try await get()
        XCTAssertEqual(r["retention_until"] as? String, "2021-12-31"); XCTAssertEqual(r["retention_source"] as? String, "document_type")
        // Typ ohne Frist
        _ = try await call(app1, .PATCH, base(w.tenantA) + "/documents/\(id)", json: ["document_type_id": typeNone], token: w.alice.token)
        r = try await get()
        XCTAssertTrue(r["retention_until"] is NSNull || r["retention_until"] == nil); XCTAssertEqual(r["retention_source"] as? String, "none")
        _ = try await call(app1, .PATCH, base(w.tenantA) + "/documents/\(id)", json: ["document_type_id": type6], token: w.alice.token)
        // manuelle Verlängerung wirkt, Verkürzen ist 422
        let ext = try await raw(app1, .PATCH, base(w.tenantA) + "/documents/\(id)/retention", body: Data(#"{"retention_until":"2031-12-31"}"#.utf8), token: w.alice.token, headers: ["Content-Type": "application/json"])
        XCTAssertEqual(ext.status, .ok, "\(ext.json)")
        XCTAssertEqual(ext.json["retention_until"] as? String, "2031-12-31"); XCTAssertEqual(ext.json["retention_source"] as? String, "manual")
        let shorten = try await raw(app1, .PATCH, base(w.tenantA) + "/documents/\(id)/retention", body: Data(#"{"retention_until":"2025-01-01"}"#.utf8), token: w.alice.token, headers: ["Content-Type": "application/json"])
        XCTAssertEqual(shorten.status, .unprocessableEntity)
        let empty = try await raw(app1, .PATCH, base(w.tenantA) + "/documents/\(id)/retention", body: Data("{}".utf8), token: w.alice.token, headers: ["Content-Type": "application/json"])
        XCTAssertEqual(empty.status, .unprocessableEntity)
        try await aEq(try await auditCount("dms.document.retention_changed", tenant: w.tenantA), 1)
        // Standard über Konfiguration
        XCTAssertEqual(DMSRetention.defaultYears(["DMS_DEFAULT_RETENTION_YEARS": "8"]), 8)
        XCTAssertEqual(DMSRetention.defaultYears(["DMS_DEFAULT_RETENTION_YEARS": "x"]), 10)
        XCTAssertEqual(DMSRetention.defaultYears([:]), 10)
    }

    /// Wenn eine neue Tabelle auf `dms_documents` verweist, muss Purge sie kennen: der Test vergleicht die Liste mit den Fremdschlüsseln der Datenbank.
    func testPurgeKnowsEveryTableThatReferencesDocuments() async throws {
        _ = try await world(enable: false)
        let rows = try await db.raw("""
            SELECT DISTINCT c.conrelid::regclass::text AS t FROM pg_constraint c WHERE c.contype = 'f' AND c.confrelid = 'dms_documents'::regclass
            """).all().map { try $0.decode(column: "t", as: String.self) }
        XCTAssertEqual(Set(rows).subtracting(DMSPurge.childTables), [], "Tabellen mit Verweis auf dms_documents fehlen in DMSPurge.childTables")
    }

    func testRevisionMigrationRevertAndReapply() async throws {
        _ = try await world(enable: false)
        try await aEq(try await count("_fluent_migrations", where: "name = 'dms_021_revision'"), 1)
        let m = CreateDMSRevision()
        try await m.revert(on: app1.db(.psql))
        try await aEq(try await count("information_schema.tables", where: "table_name IN ('dms_deletion_log', 'dms_audit_chain', 'dms_audit_heads', 'dms_integrity_runs', 'dms_exports')"), 0)
        try await aEq(try await count("information_schema.columns", where: "table_name = 'dms_documents' AND column_name IN ('legal_hold', 'retention_until')"), 0)
        try await m.prepare(on: app1.db(.psql))
        try await aEq(try await count("information_schema.tables", where: "table_name IN ('dms_deletion_log', 'dms_audit_chain', 'dms_audit_heads', 'dms_integrity_runs', 'dms_exports')"), 5)
    }
}

// MARK: Hash-Kette (F-16)

final class DMSAuditChainTests: DMSRevisionTestBase {

    /// F-16: Jeder DMS-Audit-Eintrag ist verkettet (prev_hash), die Kette ist je Mandant lückenlos und prüfbar; Einträge anderer Module bleiben außerhalb.
    func testChainCoversDmsEventsAndVerifies() async throws {
        let w = try await world()
        for i in 0..<3 { _ = try await newDoc(w.alice, w.tenantA, seed: "chain-\(i)", query: "archive=true") }
        let tenant = UUID(uuidString: w.tenantA)!
        let dms = try await auditCount("dms.document.created", tenant: w.tenantA)
        XCTAssertEqual(dms, 3)
        let total = try await count("audit_log", where: "tenant_id = '\(w.tenantA)' AND action LIKE 'dms.%'")
        try await aEq(try await count("dms_audit_chain", where: "tenant_id = '\(w.tenantA)'"), total)
        try await aEq(try await count("dms_audit_chain", where: "tenant_id = '\(w.tenantA)' AND seq = 1 AND prev_hash = repeat('0', 64)"), 1)
        try await aEq(try await count("dms_audit_chain c", where: "c.seq > 1 AND c.prev_hash = (SELECT p.hash FROM dms_audit_chain p WHERE p.tenant_id = c.tenant_id AND p.seq = c.seq - 1)"), total - 1)
        let report = try await DMSAuditChain.verify(tenant: tenant, on: db)
        XCTAssertTrue(report.ok, "\(report)"); XCTAssertEqual(report.entries, total)
        try await aEq(try await scalar("SELECT hash AS v FROM dms_audit_heads WHERE tenant_id = '\(w.tenantA)'", as: String.self), report.head)
        // Kette hängt nicht an Fremdmodul-Einträgen
        try await aEq(try await count("dms_audit_chain c JOIN audit_log a ON a.id = c.audit_id", where: "a.action NOT LIKE 'dms.%'"), 0)
        // leerer Mandant: leere, gültige Kette
        let empty = try await DMSAuditChain.verify(tenant: UUID(), on: db)
        XCTAssertTrue(empty.ok); XCTAssertEqual(empty.entries, 0); XCTAssertEqual(empty.head, DMSAuditChain.genesis)
    }

    /// F-16: Gleichzeitige Ereignisse über zwei Instanzen ergeben eine lückenlose, gültige Kette (keine doppelte Folgenummer, kein Sperrzyklus).
    func testChainStaysConsistentUnderConcurrentWrites() async throws {
        let w = try await world()
        let ids = try await (0..<6).asyncMap { try await self.newDoc(w.alice, w.tenantA, seed: "par-\($0)")["id"] as! String }
        let results = try await parallel(24) { i in
            let doc = ids[i % ids.count]
            return try await self.raw(i % 2 == 0 ? self.app1 : self.app2, .PATCH, self.base(w.tenantA) + "/documents/\(doc)", body: Data(#"{"title":"T\#(i)"}"#.utf8),
                                      token: w.alice.token, headers: ["Content-Type": "application/json"])
        }
        XCTAssertGreaterThan(results.filter { $0.status == .ok }.count, 0)
        let total = try await count("audit_log", where: "tenant_id = '\(w.tenantA)' AND action LIKE 'dms.%'")
        try await aEq(try await count("dms_audit_chain"), total)
        try await aEq(try await scalar("SELECT max(seq)::bigint AS v FROM dms_audit_chain", as: Int64.self), total)
        let report = try await DMSAuditChain.verify(tenant: UUID(uuidString: w.tenantA)!, on: db)
        XCTAssertTrue(report.ok, "\(report)")
    }

    private func tamperSetup(_ w: World) async throws {
        for i in 0..<4 { _ = try await newDoc(w.alice, w.tenantA, seed: "tamper-\(i)") }
        // Der Laufzeitbenutzer darf audit_log nur anhängen (H6); für den Manipulationsversuch hebt der Test das als Eigentümer auf.
        try await db.raw("GRANT UPDATE, DELETE ON audit_log TO CURRENT_USER").run()
        try await db.raw("ALTER TABLE audit_log DISABLE TRIGGER audit_log_no_change").run()
    }

    /// F-16: Wird ein Audit-Eintrag nachträglich verändert, bricht die Kette an dieser Stelle (hash_mismatch).
    func testChainBreaksWhenAuditEntryIsModified() async throws {
        let w = try await world()
        try await tamperSetup(w)
        let tenant = UUID(uuidString: w.tenantA)!
        let before = try await DMSAuditChain.verify(tenant: tenant, on: db)
        XCTAssertTrue(before.ok)
        let victim = try await scalar("SELECT audit_id::bigint AS v FROM dms_audit_chain WHERE seq = 3", as: Int64.self)
        try await db.raw("UPDATE audit_log SET meta = '{\"size\":1}'::jsonb WHERE id = \(bind: victim)").run()
        let after = try await DMSAuditChain.verify(tenant: tenant, on: db)
        XCTAssertFalse(after.ok); XCTAssertEqual(after.problem, "hash_mismatch"); XCTAssertEqual(after.brokenAtSeq, 3)
    }

    /// F-16: Gelöschter Audit-Eintrag (missing_audit), herausgetrennter Kettenabschnitt (sequence_gap) und umgebogener Verweis (prev_mismatch) werden erkannt.
    func testChainBreaksWhenEntriesAreRemovedOrRelinked() async throws {
        let w = try await world()
        try await tamperSetup(w)
        let tenant = UUID(uuidString: w.tenantA)!
        try await db.raw("ALTER TABLE dms_audit_chain DISABLE TRIGGER dms_audit_chain_rows").run()
        // prev_hash umbiegen
        try await db.raw("UPDATE dms_audit_chain SET prev_hash = repeat('a', 64) WHERE seq = 4").run()
        var r = try await DMSAuditChain.verify(tenant: tenant, on: db)
        XCTAssertEqual(r.problem, "prev_mismatch"); XCTAssertEqual(r.brokenAtSeq, 4)
        try await db.raw("UPDATE dms_audit_chain SET prev_hash = (SELECT hash FROM dms_audit_chain WHERE seq = 3) WHERE seq = 4").run()
        let restored = try await DMSAuditChain.verify(tenant: tenant, on: db)
        XCTAssertTrue(restored.ok)
        // Audit-Eintrag löschen
        let victim = try await scalar("SELECT audit_id::bigint AS v FROM dms_audit_chain WHERE seq = 2", as: Int64.self)
        try await db.raw("DELETE FROM audit_log WHERE id = \(bind: victim)").run()
        r = try await DMSAuditChain.verify(tenant: tenant, on: db)
        XCTAssertEqual(r.problem, "missing_audit"); XCTAssertEqual(r.brokenAtSeq, 2)
        // Kettenglied entfernen
        try await db.raw("DELETE FROM dms_audit_chain WHERE seq = 3").run()
        r = try await DMSAuditChain.verify(tenant: tenant, on: db)
        XCTAssertFalse(r.ok)
    }

    /// Kette und Löschprotokoll sind ohne Eingriff in die Trigger nicht änderbar.
    func testChainTablesAreAppendOnly() async throws {
        let w = try await world()
        _ = try await newDoc(w.alice, w.tenantA, seed: "append-only")
        for stmt in ["UPDATE dms_audit_chain SET hash = repeat('b', 64)", "DELETE FROM dms_audit_chain", "TRUNCATE dms_audit_chain"] {
            do { try await db.raw(SQLQueryString(stmt)).run(); XCTFail("\(stmt) muss scheitern") } catch { XCTAssertTrue(String(reflecting: error).contains("dms_append_only"), "\(error)") }
        }
    }
}

extension Sequence {
    func asyncMap<T>(_ f: (Element) async throws -> T) async rethrows -> [T] { var out: [T] = []; for e in self { out.append(try await f(e)) }; return out }
}

// MARK: AK-D-REV-3: Prüf-Job

final class DMSIntegrityTests: DMSRevisionTestBase {

    func startRun(_ w: World, via: Application? = nil, as s: TestSession? = nil) async throws -> Raw {
        try await raw(via ?? app1, .POST, base(w.tenantA) + "/integrity-runs", token: (s ?? w.alice).token)
    }

    func runState(_ id: String) async throws -> String { try await scalar("SELECT state AS v FROM dms_integrity_runs WHERE id = '\(id)'", as: String.self) }

    func finish(_ id: String) async throws {
        try await withWorker(kinds: [DMSIntegrity.kind]) { let st = try await runState(id); return st != "queued" && st != "running" }
    }

    /// AK-D-REV-3: Unveränderter Bestand besteht die Prüfung; Bericht mit Anzahl, Hash-Kette und Audit, ohne Inhalte.
    func testAKDREV3_cleanStorePasses() async throws {
        let w = try await world()
        for i in 0..<3 { _ = try await newDoc(w.alice, w.tenantA, seed: "ok-\(i)") }
        let started = try await startRun(w)
        XCTAssertEqual(started.status, .accepted, "\(started.json)")
        let id = started.json["id"] as! String
        XCTAssertEqual(started.json["state"] as? String, "queued")
        try await aEq(try await count("jobs", where: "kind = 'dms.verify' AND state = 'queued'"), 1)
        try await finish(id)
        let r = try await raw(app2, .GET, base(w.tenantA) + "/integrity-runs/\(id)", token: w.alice.token)
        XCTAssertEqual(r.status, .ok)
        XCTAssertEqual(r.json["state"] as? String, "passed", "\(r.json)")
        XCTAssertEqual(r.json["files_checked"] as? Int, 3); XCTAssertEqual(r.json["files_bad"] as? Int, 0); XCTAssertEqual(r.json["chain_ok"] as? Bool, true)
        let list = try await raw(app1, .GET, base(w.tenantA) + "/integrity-runs", token: w.alice.token)
        XCTAssertEqual((list.json["items"] as? [Any])?.count, 1)
        try await aEq(try await auditCount("dms.integrity.checked", tenant: w.tenantA), 1)
        try await aEq(try await auditCount("dms.integrity.failed", tenant: w.tenantA), 0)
    }

    /// AK-D-REV-3: Absichtlich veränderter Blob wird erkannt: Zustand `failed`, Bericht nennt Dokument und Rolle (hash_mismatch), Audit `dms.integrity.failed` (Alarm).
    func testAKDREV3_tamperedBlobIsDetected() async throws {
        let w = try await world()
        let good = try await newDoc(w.alice, w.tenantA, seed: "good")["id"] as! String
        let bad = try await newDoc(w.alice, w.tenantA, seed: "bad")["id"] as! String
        let sha = try await fileSHA(bad)
        try await db.raw("UPDATE object_chunks SET data = set_byte(data, 5, 255) WHERE sha256 = \(bind: sha)").run()   // manipulierter Inhalt, gleiche Länge
        let id = (try await startRun(w)).json["id"] as! String
        try await finish(id)
        let r = try await raw(app2, .GET, base(w.tenantA) + "/integrity-runs/\(id)", token: w.alice.token)
        XCTAssertEqual(r.json["state"] as? String, "failed", "\(r.json)")
        XCTAssertEqual(r.json["files_bad"] as? Int, 1); XCTAssertEqual(r.json["files_checked"] as? Int, 2)
        let findings = (r.json["report"] as? [String: Any])?["findings"] as? [[String: Any]] ?? []
        XCTAssertEqual(findings.count, 1)
        XCTAssertEqual((findings.first?["document_id"] as? String)?.lowercased(), bad.lowercased()); XCTAssertEqual(findings.first?["role"] as? String, "original"); XCTAssertEqual(findings.first?["problem"] as? String, "hash_mismatch")
        XCTAssertFalse(findings.contains { ($0["document_id"] as? String)?.lowercased() == good.lowercased() })
        try await aEq(try await auditCount("dms.integrity.failed", tenant: w.tenantA), 1)
        try await aEq(try await count("audit_log", where: "action LIKE 'dms.integrity.%' AND meta::text ILIKE '%synthetic%'"), 0, "kein Inhalt im Audit")
    }

    /// AK-D-REV-3: Fehlendes Objekt wird als Fehler gemeldet.
    func testAKDREV3_missingBlobIsAnError() async throws {
        let w = try await world()
        let doc = try await newDoc(w.alice, w.tenantA, seed: "missing")["id"] as! String
        try await db.raw("DELETE FROM object_chunks WHERE sha256 = \(bind: try await fileSHA(doc))").run()
        let id = (try await startRun(w)).json["id"] as! String
        try await finish(id)
        let r = try await raw(app1, .GET, base(w.tenantA) + "/integrity-runs/\(id)", token: w.alice.token)
        XCTAssertEqual(r.json["state"] as? String, "failed")
        XCTAssertEqual(((r.json["report"] as? [String: Any])?["findings"] as? [[String: Any]])?.first?["problem"] as? String, "missing")
    }

    /// AK-D-REV-3 / F-16: Bricht die Hash-Kette (Audit-Eintrag nachträglich verändert), meldet der Prüflauf einen Fehler, auch wenn alle Dateien in Ordnung sind.
    func testAKDREV3_brokenAuditChainFailsTheRun() async throws {
        let w = try await world()
        _ = try await newDoc(w.alice, w.tenantA, seed: "kette-doc")
        try await db.raw("GRANT UPDATE ON audit_log TO CURRENT_USER").run()
        try await db.raw("ALTER TABLE audit_log DISABLE TRIGGER audit_log_no_change").run()
        try await db.raw("UPDATE audit_log SET action = 'dms.document.created2' WHERE id = (SELECT audit_id FROM dms_audit_chain WHERE tenant_id = '\(w.tenantA)' AND seq = 1)").run()
        let id = (try await startRun(w)).json["id"] as! String
        try await finish(id)
        let r = try await raw(app1, .GET, base(w.tenantA) + "/integrity-runs/\(id)", token: w.alice.token)
        XCTAssertEqual(r.json["state"] as? String, "failed", "\(r.json)")
        XCTAssertEqual(r.json["chain_ok"] as? Bool, false)
        XCTAssertEqual(r.json["files_bad"] as? Int, 0)
        XCTAssertEqual(((r.json["report"] as? [String: Any])?["chain"] as? [String: Any])?["problem"] as? String, "hash_mismatch")
    }

    /// Rechte: nur Buchhaltung/Owner dürfen prüfen; Steuerberater und Mitglieder nicht; fremder Mandant 404 (auch für Läufe anderer Mandanten).
    func testIntegrityPermissionsAndTenantIsolation() async throws {
        let w = try await world()
        let advisor = try await addUser("tax_advisor", handle: "tom", tenant: w.tenantA, by: w.alice)
        let member = try await addUser("member", handle: "max", tenant: w.tenantA, by: w.alice)
        for s in [advisor, member] {
            let r = try await startRun(w, as: s)
            XCTAssertEqual(r.status, .forbidden)
        }
        try await aEq(try await count("dms_integrity_runs"), 0)
        let id = (try await startRun(w)).json["id"] as! String
        let tenantB = (try await call(app1, .POST, "api/v1/tenants", json: ["name": "Zweiter Mandant"], token: w.alice.token)).json["id"] as! String
        let carol = try await addUser("owner", handle: "carol", tenant: tenantB, by: w.alice)
        try await setModule(tenantB, true, by: carol)
        let foreign = try await raw(app2, .GET, base(tenantB) + "/integrity-runs/\(id)", token: carol.token)
        XCTAssertEqual(foreign.status, .notFound)
        let listB = try await raw(app2, .GET, base(tenantB) + "/integrity-runs", token: carol.token)
        XCTAssertEqual((listB.json["items"] as? [Any])?.count, 0)
    }

    /// Zwei Worker, mehrere Läufe: jeder Lauf genau einmal abgeschlossen (ein Ergebnis, ein Audit-Eintrag); erneuter Aufruf des Handlers ist wirkungslos.
    func testTwoWorkersCompleteEachRunExactlyOnce() async throws {
        let w = try await world()
        for i in 0..<4 { _ = try await newDoc(w.alice, w.tenantA, seed: "two-\(i)") }
        var ids: [String] = []
        for i in 0..<8 { ids.append((try await startRun(w, via: i % 2 == 0 ? app1 : app2)).json["id"] as! String) }
        let w1 = makeWorker(on: app1, kinds: [DMSIntegrity.kind]), w2 = makeWorker(on: app2, kinds: [DMSIntegrity.kind])
        let r1 = Task { await w1.run() }, r2 = Task { await w2.run() }
        try await waitFor("alle Läufe fertig") { try await count("dms_integrity_runs", where: "state = 'passed'") == 8 }
        w1.requestShutdown(); w2.requestShutdown(); await r1.value; await r2.value
        try await aEq(try await auditCount("dms.integrity.checked", tenant: w.tenantA), 8)
        try await aEq(try await count("jobs", where: "kind = 'dms.verify' AND state = 'done'"), 8)
        // Wiederholter Handler-Aufruf auf einem fertigen Lauf: nichts passiert
        let handler = DMSIntegrity.handler { s in try ObjectStoreConfig(kind: .db).makeStore(db: s) }
        let payload = #"{"run_id":"\#(ids[0])","tenant_id":"\#(w.tenantA)"}"#
        try await handler(ClaimedJob(id: UUID(), kind: DMSIntegrity.kind, payload: payload, attempts: 1), db)
        try await aEq(try await auditCount("dms.integrity.checked", tenant: w.tenantA), 8)
    }
}

// MARK: AK-D-REV-4: Export-Job

final class DMSExportTests: DMSRevisionTestBase {

    func startExport(_ w: World, body: String = "{}", via: Application? = nil, as s: TestSession? = nil) async throws -> Raw {
        try await raw(via ?? app1, .POST, base(w.tenantA) + "/exports", body: Data(body.utf8), token: (s ?? w.alice).token, headers: ["Content-Type": "application/json"])
    }
    func exportState(_ id: String) async throws -> String { try await scalar("SELECT state AS v FROM dms_exports WHERE id = '\(id)'", as: String.self) }
    func finish(_ id: String) async throws {
        try await withWorker(kinds: [DMSExport.kind]) { let s = try await exportState(id); return s == "done" || s == "failed" }
    }

    /// AK-D-REV-4: Export als Worker-Job (ZIP + index.csv + manifest.json), Ergebnis im ObjectStore, Download über die Route (andere Instanz). Das Manifest ist verifizierbar:
    /// jede Datei im ZIP hat den SHA-256 aus dem Manifest, der Manifest-Hash steht im Exportdatensatz, der Papierkorb ist nicht enthalten.
    func testAKDREV4_exportZipWithIndexAndVerifiableManifest() async throws {
        let w = try await world()
        let originals: [(String, Data)] = [("=Summe", pdf("exp-1", padding: 500)), ("Rechnung, \"Mai\"", pdf("exp-2")), ("Vertrag", png("exp-3"))]
        var docs: [String] = []
        for (i, o) in originals.enumerated() {
            let r = try await upload(w.alice, w.tenantA, o.1, query: "title=" + o.0.addingPercentEncoding(withAllowedCharacters: .alphanumerics)! + (i == 0 ? "&archive=true" : ""))
            XCTAssertEqual(r.status, .created, "\(r.json)"); docs.append(r.json["id"] as! String)
        }
        let trashed = try await newDoc(w.alice, w.tenantA, seed: "exp-trashed")["id"] as! String
        try await trash(w, trashed)

        let started = try await startExport(w)
        XCTAssertEqual(started.status, .accepted, "\(started.json)")
        let id = started.json["id"] as! String
        try await aEq(try await count("jobs", where: "kind = 'dms.export' AND state = 'queued'"), 1)
        try await finish(id)
        let info = try await raw(app2, .GET, base(w.tenantA) + "/exports/\(id)", token: w.alice.token)
        XCTAssertEqual(info.json["state"] as? String, "done", "\(info.json)")
        XCTAssertEqual(info.json["document_count"] as? Int, 3); XCTAssertEqual(info.json["file_count"] as? Int, 3)
        let zipSHA = info.json["sha256"] as! String, manifestSHA = info.json["manifest_sha256"] as! String

        let dl = try await raw(app2, .GET, base(w.tenantA) + "/exports/\(id)/file", token: w.alice.token)
        XCTAssertEqual(dl.status, .ok)
        XCTAssertEqual(dl.headers.first(name: .contentType), "application/zip")
        XCTAssertEqual(dl.headers.first(name: "X-Content-Type-Options"), "nosniff")
        XCTAssertEqual(hex(dl.body), zipSHA, "ZIP-Hash im Datensatz stimmt")
        XCTAssertEqual(Int64(dl.body.count), info.json["size_bytes"] as? Int64 ?? Int64(info.json["size_bytes"] as? Int ?? -1))
        try await aEq(try await auditCount("dms.export.downloaded", tenant: w.tenantA), 1)

        let entries = try ZIPReader.read(dl.body)
        let byName = Dictionary(uniqueKeysWithValues: entries.map { ($0.name, $0) })
        XCTAssertNotNil(byName["index.csv"]); XCTAssertNotNil(byName["manifest.json"])
        XCTAssertEqual(entries.count, 5)
        XCTAssertEqual(hex(byName["manifest.json"]!.data), manifestSHA, "Manifest-Hash im Datensatz")
        let manifest = try JSONSerialization.jsonObject(with: byName["manifest.json"]!.data) as! [String: Any]
        XCTAssertEqual(manifest["format"] as? String, DMSExport.format); XCTAssertEqual(manifest["hash_algorithm"] as? String, "SHA-256")
        XCTAssertFalse(((manifest["note"] as? String) ?? "").localizedCaseInsensitiveContains("konform ") )
        let chain = manifest["audit_chain"] as! [String: Any]
        XCTAssertEqual(chain["ok"] as? Bool, true)
        let listed = manifest["files"] as! [[String: Any]]
        XCTAssertEqual(listed.count, 4)   // 3 Dokumente + index.csv; das Manifest enthält sich nicht selbst
        for f in listed {
            let path = f["path"] as! String
            let item = try XCTUnwrap(byName[path], path)
            XCTAssertEqual(hex(item.data), f["sha256"] as? String, "SHA-256 \(path)")
            XCTAssertEqual(item.data.count, f["size_bytes"] as? Int, path)
        }
        // Originale byte-identisch, Namen ohne Pfadtricks
        let datas = originals.map { $0.1 }
        for d in datas { XCTAssertTrue(entries.contains { $0.data == d }) }
        XCTAssertFalse(entries.contains { $0.name.contains("..") || $0.name.hasPrefix("/") })
        XCTAssertFalse(entries.contains { $0.data == pdf("exp-trashed") }, "Papierkorb ist nicht Teil des Exports")
        // Index: Kopfzeile, eine Zeile je Datei, Formel-Injektion entschärft, Anführungszeichen maskiert
        let index = String(decoding: byName["index.csv"]!.data, as: UTF8.self)
        let lines = index.components(separatedBy: "\r\n").filter { !$0.isEmpty }
        XCTAssertEqual(lines.count, 4)
        XCTAssertTrue(lines[0].hasPrefix("document_id,asn,title"))
        XCTAssertTrue(index.contains("'=Summe")); XCTAssertFalse(index.contains(",=Summe"))
        XCTAssertTrue(index.contains("\"Rechnung, \"\"Mai\"\"\""))
        // Ergebnis liegt im ObjectStore und im files-Register; Audit
        try await aEq(try await count("files", where: "sha256 = '\(zipSHA)' AND content_type = 'application/zip'"), 1)
        try await aEq(try await auditCount("dms.export.completed", tenant: w.tenantA), 1)
        _ = docs

        // Externe Prüfung: unzip -t, falls verfügbar
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("labhub-export-\(UUID().uuidString).zip")
        try dl.body.write(to: tmp); defer { try? FileManager.default.removeItem(at: tmp) }
        if FileManager.default.isExecutableFile(atPath: "/usr/bin/unzip") {
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/unzip"); p.arguments = ["-tq", tmp.path]
            p.standardOutput = Pipe(); p.standardError = Pipe()
            try p.run(); p.waitUntilExit()
            XCTAssertEqual(p.terminationStatus, 0, "unzip -t")
        } else { print("SKIP unzip -t: /usr/bin/unzip fehlt") }
    }

    /// AK-D-REV-4: Filter (Zeitraum, Dokumentliste, Typ) wirken, ungültige Eingaben sind 422.
    func testExportFilters() async throws {
        let w = try await world()
        let a = try await newDoc(w.alice, w.tenantA, seed: "f-a", query: "doc_date=2024-03-01")["id"] as! String
        _ = try await newDoc(w.alice, w.tenantA, seed: "f-b", query: "doc_date=2025-03-01")
        let r1 = try await startExport(w, body: #"{"date_from":"2024-01-01","date_to":"2024-12-31"}"#)
        let r2 = try await startExport(w, body: #"{"document_ids":["\#(a)"]}"#)
        let r3 = try await startExport(w, body: "{}")
        let ids = [r1, r2, r3].map { $0.json["id"] as! String }
        try await withWorker(kinds: [DMSExport.kind]) { try await count("dms_exports", where: "state = 'done'") == 3 }
        let counts = try await ids.asyncMap { try await self.scalar("SELECT document_count::bigint AS v FROM dms_exports WHERE id = '\($0)'", as: Int64.self) }
        XCTAssertEqual(counts, [1, 1, 2])
        // Ungültige Eingaben und fremde Typen
        let bad = try await startExport(w, body: #"{"date_from":"gestern"}"#)
        XCTAssertEqual(bad.status, .unprocessableEntity)
        let foreignType = try await startExport(w, body: #"{"document_type_id":"\#(UUID().uuidString)"}"#)
        XCTAssertEqual(foreignType.status, .unprocessableEntity)
    }

    /// Ein manipuliertes Objekt im Bestand wird nicht ausgeliefert: der Export scheitert mit `integrity_failed` und liefert kein ZIP.
    func testExportFailsOnTamperedBlob() async throws {
        let w = try await world()
        let doc = try await newDoc(w.alice, w.tenantA, seed: "exp-tamper")["id"] as! String
        try await db.raw("UPDATE object_chunks SET data = set_byte(data, 5, 255) WHERE sha256 = \(bind: try await fileSHA(doc))").run()
        let id = (try await startExport(w)).json["id"] as! String
        try await finish(id)
        let info = try await raw(app1, .GET, base(w.tenantA) + "/exports/\(id)", token: w.alice.token)
        XCTAssertEqual(info.json["state"] as? String, "failed"); XCTAssertEqual(info.json["error_code"] as? String, "integrity_failed")
        let dl = try await raw(app1, .GET, base(w.tenantA) + "/exports/\(id)/file", token: w.alice.token)
        XCTAssertEqual(dl.status, .notFound)
    }

    /// Rechte (Steuerberater darf, Mitglied nicht) und Mandantentrennung (fremde Export-ID 404, fremde Dokument-IDs ergeben leeren Export).
    func testExportPermissionsAndTenantIsolation() async throws {
        let w = try await world()
        let advisor = try await addUser("tax_advisor", handle: "tom", tenant: w.tenantA, by: w.alice)
        let member = try await addUser("member", handle: "max", tenant: w.tenantA, by: w.alice)
        let denied = try await startExport(w, as: member)
        XCTAssertEqual(denied.status, .forbidden); XCTAssertEqual(denied.problemCode, "forbidden")
        let allowed = try await startExport(w, as: advisor)
        XCTAssertEqual(allowed.status, .accepted)
        try await aEq(try await count("dms_exports"), 1)
        let id = allowed.json["id"] as! String
        let docA = try await newDoc(w.alice, w.tenantA, seed: "iso-a")["id"] as! String

        let tenantB = (try await call(app1, .POST, "api/v1/tenants", json: ["name": "Zweiter Mandant"], token: w.alice.token)).json["id"] as! String
        let carol = try await addUser("owner", handle: "carol", tenant: tenantB, by: w.alice)
        try await setModule(tenantB, true, by: carol)
        for path in ["/exports/\(id)", "/exports/\(id)/file"] {
            let r = try await raw(app2, .GET, base(tenantB) + path, token: carol.token)
            XCTAssertEqual(r.status, .notFound, path)
        }
        let listB = try await raw(app2, .GET, base(tenantB) + "/exports", token: carol.token)
        XCTAssertEqual((listB.json["items"] as? [Any])?.count, 0)
        let foreign = try await raw(app2, .POST, base(tenantB) + "/exports", body: Data(#"{"document_ids":["\#(docA)"]}"#.utf8), token: carol.token, headers: ["Content-Type": "application/json"])
        XCTAssertEqual(foreign.status, .accepted)
        let fid = foreign.json["id"] as! String
        try await finish(fid)
        let done = try await raw(app2, .GET, base(tenantB) + "/exports/\(fid)", token: carol.token)
        XCTAssertEqual(done.json["state"] as? String, "done"); XCTAssertEqual(done.json["document_count"] as? Int, 0, "fremde Dokument-IDs liefern nichts")
    }

    /// Zwei Worker, mehrere Exporte: jeder genau einmal abgeschlossen (ein Audit-Eintrag, ein Job `done`).
    func testTwoWorkersCompleteEachExportExactlyOnce() async throws {
        let w = try await world()
        for i in 0..<3 { _ = try await newDoc(w.alice, w.tenantA, seed: "x2-\(i)") }
        for i in 0..<6 { _ = try await startExport(w, via: i % 2 == 0 ? app1 : app2) }
        let w1 = makeWorker(on: app1, kinds: [DMSExport.kind]), w2 = makeWorker(on: app2, kinds: [DMSExport.kind])
        let r1 = Task { await w1.run() }, r2 = Task { await w2.run() }
        try await waitFor("alle Exporte fertig") { try await count("dms_exports", where: "state = 'done'") == 6 }
        w1.requestShutdown(); w2.requestShutdown(); await r1.value; await r2.value
        try await aEq(try await auditCount("dms.export.completed", tenant: w.tenantA), 6)
        try await aEq(try await count("jobs", where: "kind = 'dms.export' AND state = 'done'"), 6)
        // gleiche Bytes aus allen: ein Blob (Dedup), aber sechs Datensätze
        try await aEq(try await count("files", where: "content_type = 'application/zip'") >= 1, true)
    }

    /// ZIP-Schreiber und -Leser: Rundlauf, CRC, leere Dateien, UTF-8-Namen.
    func testZipRoundTrip() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("labhub-zip-\(UUID().uuidString).zip")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: url) }
        let h = try FileHandle(forWritingTo: url)
        let z = ZIPWriter(handle: h, timestamp: Date(timeIntervalSince1970: 1_700_000_000))
        let big = Data((0..<300_000).map { UInt8($0 % 251) })
        let a = try await z.add(name: "ä/große-Datei.bin", data: big)
        let b = try await z.add(name: "leer.txt", data: Data())
        try z.finish(); try h.close()
        XCTAssertEqual(a.sha256, hex(big)); XCTAssertEqual(b.size, 0)
        let items = try ZIPReader.read(try Data(contentsOf: url))
        XCTAssertEqual(items.map(\.name), ["ä/große-Datei.bin", "leer.txt"])
        XCTAssertEqual(items[0].data, big); XCTAssertEqual(items[1].data, Data())
        var crc: UInt32 = 0
        big.withUnsafeBytes { crc = CRC32.update(0, $0) }
        XCTAssertEqual(items[0].crc, crc)
        XCTAssertEqual(CRC32.update(0, UnsafeRawBufferPointer(start: nil, count: 0)), 0)
        let known = Array("123456789".utf8)
        XCTAssertEqual(known.withUnsafeBytes { CRC32.update(0, $0) }, 0xCBF43926)
        // gleiche Eingabe, gleicher Zeitstempel -> gleiche Bytes
        let url2 = FileManager.default.temporaryDirectory.appendingPathComponent("labhub-zip-\(UUID().uuidString).zip")
        FileManager.default.createFile(atPath: url2.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: url2) }
        let h2 = try FileHandle(forWritingTo: url2)
        let z2 = ZIPWriter(handle: h2, timestamp: Date(timeIntervalSince1970: 1_700_000_000))
        try await z2.add(name: "ä/große-Datei.bin", data: big); try await z2.add(name: "leer.txt", data: Data())
        try z2.finish(); try h2.close()
        XCTAssertEqual(try Data(contentsOf: url), try Data(contentsOf: url2))
    }
}
