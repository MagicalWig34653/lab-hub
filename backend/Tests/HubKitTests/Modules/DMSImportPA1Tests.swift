import XCTVapor
import Fluent
import SQLKit
import Crypto
import Logging
@testable import HubCore
@testable import HubKit
@testable import HubModuleDMS

// WP-PA1: Befunde des Laufs gegen eine ECHTE paperless-ngx-Instanz (3.5.1, API-Version 10, `scripts/e2e-paperless-import.sh`) als schnelle Regressionstests.
// Der Mock (`PaperlessMock`) liefert dieselben Antwortformen wie die echte Instanz; die Fixture ist die synthetische aus `Tests/Fixtures/paperless-synthetic`.
// AK-PA1-2 Export und API liefern dieselben Hashes; PA1-4 fehlendes Recht und eingeschraenkte Sicht; PA1-5 feste API-Version; PA1-6 Pruefsummen ueber die API;
// PA1-7 Token weg, sobald der Lauf endet; PA1-8 mehrere Fassungen je Dokument.

final class DMSImportPA1Tests: DMSImportTestBase {
    func apiSource(_ m: PaperlessMock, token: String = d6Token) -> [String: Any] { ["kind": "api", "base_url": "http://127.0.0.1:\(m.port)", "token": token] }

    func mock(_ configure: (PaperlessMock) -> Void = { _ in }) async throws -> PaperlessMock {
        let m = try await PaperlessMock(token: d6Token, fixture: Self.fixture)
        configure(m)
        addTeardownBlock { await m.stop() }
        return m
    }

    func originalHash(_ pk: Int) async throws -> String? {
        try await db.raw("""
            SELECT f.sha256 AS v FROM dms_document_files f JOIN dms_ingest_items i ON i.document_id = f.document_id WHERE i.origin_ref = \(bind: "paperless:\(pk)") AND f.role = 'original'
            """).first()?.decode(column: "v", as: String.self)
    }

    /// Fuegt dem kopierten Export eine zweite Fassung von Dokument 101 hinzu, so wie `document_exporter` sie schreibt: eigener Eintrag mit `root_document`, `version_index`,
    /// eigenen Dateien und Pruefsummen, aber ohne Korrespondent, Typ und Tags (die haengen am Wurzeldokument).
    func addExportVersion(_ dir: URL) throws {
        let manifestURL = dir.appendingPathComponent("manifest.json")
        var manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as! [[String: Any]]
        let bytes = PaperlessMock.secondVersion(101)
        try bytes.write(to: dir.appendingPathComponent("0000901.pdf"))
        manifest.append(["model": "documents.document", "pk": 901, "__exported_file_name__": "0000901.pdf",
                         "fields": ["title": "Stromrechnung Januar 2023", "content": "Zweite Fassung mit anderem Text", "created": "2023-02-01", "added": "2023-02-04T09:15:00.000000Z", "checksum": PaperlessMock.sha(bytes),
                                    "filename": "0000901.pdf", "mime_type": "application/pdf", "owner": 1, "correspondent": NSNull(), "document_type": NSNull(), "storage_path": NSNull(), "tags": [Int](),
                                    "archive_serial_number": NSNull(), "root_document": 101, "version_index": 1, "version_label": "Fassung zwei"] as [String: Any]])
        try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys]).write(to: manifestURL)
    }

    // MARK: PA1-5

    /// AK-PA1-5: jede Anfrage nennt die geprueft getestete API-Version (`Accept: application/json; version=10`); lehnt die Instanz sie ab (406), meldet der Lauf `source_api_version_unsupported`.
    func testAKPA1_5_apiVersionIsPinned() async throws {
        let w = try await world()
        let m = try await mock()
        let ok = try await runAndReport(w, mode: "dry_run", source: apiSource(m))
        XCTAssertEqual(ok.state, "done", "\(ok.report)")
        XCTAssertFalse(m.requests.isEmpty)
        XCTAssertTrue(m.requests.allSatisfy { $0.accept == "application/json; version=10" }, "\(m.requests.map { $0.accept ?? "-" })")
        let old = try await mock { $0.apiVersion = 9 }
        let r = try await runAndReport(w, mode: "dry_run", source: apiSource(old))
        XCTAssertEqual(r.state, "failed"); XCTAssertEqual(r.report["error_code"] as? String, "source_api_version_unsupported", "\(r.report)")
    }

    // MARK: PA1-4

    /// AK-PA1-4: fehlendes Leserecht (403) ist ein eigener Befund, kein falsches Token (401); ein Benutzer mit eingeschraenkter Sicht liefert nur das fuer ihn Sichtbare, nicht sichtbare
    /// Stammdaten melden `reference_not_visible` (nicht `reference_unknown`), der Bericht nennt die Einschraenkung.
    func testAKPA1_4_missingPermissionAndLimitedVisibility() async throws {
        let w = try await world()
        let denied = try await mock { $0.forbidden = true }
        let d = try await runAndReport(w, mode: "dry_run", source: apiSource(denied))
        XCTAssertEqual(d.state, "failed"); XCTAssertEqual(d.report["error_code"] as? String, "source_permission_denied", "\(d.report)")
        let wrong = try await runAndReport(w, mode: "dry_run", source: apiSource(denied, token: "falsch"))
        XCTAssertEqual(wrong.report["error_code"] as? String, "source_auth_failed")
        // Leser: 8 von 10 Dokumenten sichtbar, keine Stammdaten
        let reader = try await mock { $0.hideReferences = true; $0.visibleDocuments = [101, 102, 103, 104, 105, 106, 107, 108] }
        let r = try await runAndReport(w, mode: "import", source: apiSource(reader))
        XCTAssertEqual(r.state, "done", "\(r.report)")
        XCTAssertEqual(counts(r.report)["documents_seen"], 8); XCTAssertEqual(counts(r.report)["documents_imported"], 8)
        try await aEq(try await count("dms_documents"), 8)
        XCTAssertGreaterThan(finding(r.report, "reference_not_visible").total, 0, "\(r.report["findings"] ?? [:])")
        XCTAssertEqual(finding(r.report, "reference_unknown").total, 0)
        XCTAssertEqual((r.report["rights"] as? [String: Any])?["visibility_note_code"] as? String, "api_visible_to_token_user_only")
        try await aEq(try await count("dms_tags"), 0); try await aEq(try await count("contacts", where: "is_correspondent"), 0)
    }

    // MARK: PA1-6

    /// AK-PA1-6: die API liefert Pruefsummen (`versions[].checksum`, `metadata.archive_checksum`): jede Datei wird geprueft und im Bericht als geprueft gezaehlt. Weicht die Auslieferung
    /// vom gemeldeten Hash ab, wird das Dokument nicht uebernommen (`checksum_mismatch`, `archive_checksum_mismatch`). Liefert die Quelle keine, steht das im Bericht (`files_without_checksum`).
    func testAKPA1_6_checksumsFromTheApiAreVerified() async throws {
        let w = try await world()
        let clean = try await mock()
        let ok = try await runAndReport(w, mode: "dry_run", source: apiSource(clean))
        XCTAssertEqual(counts(ok.report)["files_without_checksum"] ?? 0, 0)
        XCTAssertEqual(counts(ok.report)["files_checksum_verified"], 12, "10 Originale + 2 Archivdateien")
        XCTAssertTrue(clean.requests.contains { $0.path == "/api/documents/107/metadata/" }, "Archivpruefsumme ueber die Metadaten")
        let bad = try await mock { $0.corruptOriginal = [102]; $0.corruptArchive = [107] }
        let r = try await runAndReport(w, mode: "import", source: apiSource(bad))
        XCTAssertEqual(r.state, "done", "\(r.report)")
        XCTAssertEqual(finding(r.report, "checksum_mismatch").refs, ["document:102"])
        XCTAssertEqual(finding(r.report, "archive_checksum_mismatch").refs, ["document:107"])
        try await aEq(try await count("dms_documents"), 9, "Dokument 102 wegen Hash-Abweichung nicht uebernommen")
        try await aEq(try await count("dms_document_files", where: "role = 'archive'"), 1, "Archivdatei 107 verworfen, 108 uebernommen")
        let h102 = try await originalHash(102); XCTAssertNil(h102)
        let none = try await mock { $0.provideChecksums = false }
        let n = try await runAndReport(w, mode: "dry_run", source: apiSource(none))
        XCTAssertEqual(counts(n.report)["files_without_checksum"], 10, "aeltere Staende ohne Pruefsummen: im Bericht ausgewiesen")
    }

    // MARK: PA1-7

    /// AK-PA1-7: das gespeicherte Token wird geloescht, sobald der Lauf endet: fertig, fehlgeschlagen, abgebrochen (wartend und laufend); waehrend des Laufs bleibt es fuer die Fortsetzung.
    func testAKPA1_7_tokenIsRemovedWhenTheRunEnds() async throws {
        let w = try await world()
        func secrets(_ id: String) async throws -> (has: Bool, stored: Int64) {
            let r = try await call(app1, .GET, imports(w.tenantA) + "/\(id)", token: w.alice.token)
            return (r.json["has_secret"] as? Bool ?? true, try await scalar("SELECT count(*)::bigint AS v FROM dms_imports WHERE id = '\(id)' AND secret_enc IS NOT NULL", as: Int64.self))
        }
        let m = try await mock()
        // wartend: Token vorhanden, Abbruch loescht es
        let queued = try await startRun(w, source: apiSource(m), mode: "dry_run")
        let qid = queued.json["id"] as! String
        var s = try await secrets(qid); XCTAssertTrue(s.has); XCTAssertEqual(s.stored, 1)
        let c = try await call(app2, .POST, imports(w.tenantA) + "/\(qid)/cancel", token: w.alice.token)
        XCTAssertEqual(c.json["state"] as? String, "cancelled"); XCTAssertEqual(c.json["has_secret"] as? Bool, false)
        s = try await secrets(qid); XCTAssertFalse(s.has); XCTAssertEqual(s.stored, 0)
        // fertig (Trockenlauf und Import) und fehlgeschlagen (falsches Token)
        for (mode, source) in [("dry_run", apiSource(m)), ("import", apiSource(m)), ("dry_run", apiSource(m, token: "falsch"))] {
            let r = try await runAndReport(w, mode: mode, source: source)
            let t = try await secrets(r.id)
            XCTAssertFalse(t.has, "Lauf \(r.state)"); XCTAssertEqual(t.stored, 0, "Lauf \(r.state)")
        }
        // laufend abgebrochen: das Token bleibt bis zum Ende, danach weg
        let appRef = UnsafeSendableBox(self), token = w.alice.token, tenant = w.tenantA
        let runID = UnsafeSendableBox(""), during = UnsafeSendableBox(true)
        let hook: @Sendable (Int) async throws -> Void = { n in
            let t = appRef.value
            if n == 2 {
                let r = try await t.call(t.app1, .POST, t.imports(tenant) + "/\(runID.value)/cancel", token: token)
                XCTAssertEqual(r.status, .ok, "\(r.json)")
            }
            if n == 1 { during.value = try await t.secrets(for: runID.value) }
        }
        let other = try await mock()
        let started = try await startRun(w, source: ["kind": "api", "base_url": "http://127.0.0.1:\(other.port)/", "token": d6Token], mode: "import")
        runID.value = started.json["id"] as! String
        try await finish(runID.value, worker: JobWorker(db: db, kinds: [DMSImport.kind], handlers: [DMSImport.kind: handler(afterDocument: hook)], leaseSeconds: 30, pollInterval: .milliseconds(100), logger: Logger(label: "pa1.w")))
        XCTAssertTrue(during.value, "waehrend des Laufs ist das Token noch gespeichert (Fortsetzung nach Absturz)")
        let end = try await call(app1, .GET, imports(w.tenantA) + "/\(runID.value)", token: w.alice.token)
        XCTAssertEqual(end.json["state"] as? String, "cancelled"); XCTAssertEqual(end.json["has_secret"] as? Bool, false)
        let t = try await secrets(runID.value); XCTAssertEqual(t.stored, 0)
        let leaked = try await databaseDumpContains(d6Token); XCTAssertFalse(leaked)
    }

    func secrets(for id: String) async throws -> Bool {
        try await scalar("SELECT (secret_enc IS NOT NULL) AS v FROM dms_imports WHERE id = '\(id)'", as: Bool.self)
    }

    // MARK: PA1-8 und PA1-2

    /// Erwartete Originale je Paperless-ID: die synthetische Fixture, bei Dokument 101 die neueste (zweite) Fassung.
    func expectedOriginals() throws -> [Int: String] {
        var h = Dictionary(uniqueKeysWithValues: try fixtureHashes().original.map { (Int($0.key), $0.value) })
        h[101] = PaperlessMock.sha(PaperlessMock.secondVersion(101))
        return h
    }

    /// AK-PA1-8 (Export): ein Dokument mit mehreren Fassungen ist EIN Dokument; uebernommen wird die neueste Fassung (wie in Paperless angezeigt), die aelteren zaehlt der Bericht
    /// (`versions_skipped`, Befund `document_versions_skipped`). Die Fassung traegt keine Stammdaten: Korrespondent, Typ und Tags kommen vom Wurzeldokument.
    func testAKPA1_8_exportVersionsAreOneDocument() async throws {
        let w = try await world()
        try addExportVersion(try install(tenant: w.tenantA))
        let r = try await runAndReport(w, mode: "import")
        XCTAssertEqual(r.state, "done", "\(r.report)")
        XCTAssertEqual(counts(r.report)["documents_seen"], 10, "die Fassung ist kein eigenes Dokument")
        XCTAssertEqual(counts(r.report)["documents_imported"], 10)
        XCTAssertEqual(counts(r.report)["versions_skipped"], 1)
        XCTAssertEqual(finding(r.report, "document_versions_skipped").refs, ["document:101"])
        try await aEq(try await count("dms_documents"), 10)
        for (pk, sha) in try expectedOriginals() { let got = try await originalHash(pk); XCTAssertEqual(got, sha, "Original \(pk) ueber den Export") }
        let tags = try await scalar("""
            SELECT count(*)::bigint AS v FROM dms_document_tags t JOIN dms_ingest_items i ON i.document_id = t.document_id WHERE i.origin_ref = 'paperless:101'
            """, as: Int64.self)
        XCTAssertEqual(tags, 2, "Tags des Wurzeldokuments bleiben")
    }

    /// AK-PA1-8 und PA1-2 (API): dieselben Dokumente und Hashes wie ueber den Export; die neueste Fassung wird geladen, die Pruefsumme stammt aus `versions`.
    func testAKPA1_8_apiVersionsMatchTheExport() async throws {
        let w = try await world()
        let m = try await mock { $0.versioned = [101] }
        let r = try await runAndReport(w, mode: "import", source: apiSource(m))
        XCTAssertEqual(r.state, "done", "\(r.report)")
        XCTAssertEqual(counts(r.report)["documents_seen"], 10); XCTAssertEqual(counts(r.report)["documents_imported"], 10)
        XCTAssertEqual(counts(r.report)["versions_skipped"], 1)
        XCTAssertEqual(finding(r.report, "document_versions_skipped").refs, ["document:101"])
        XCTAssertEqual(counts(r.report)["files_without_checksum"] ?? 0, 0)
        try await aEq(try await count("dms_documents"), 10)
        for (pk, sha) in try expectedOriginals() { let got = try await originalHash(pk); XCTAssertEqual(got, sha, "Original \(pk) ueber die API") }
    }

    // MARK: PA1-2 Papierkorb

    /// AK-PA1-2: `document_exporter` schreibt auch Dokumente, Notizen und Feldwerte aus dem Papierkorb (`deleted_at` gesetzt); die API liefert sie nicht. Beide Wege muessen dasselbe
    /// liefern: nichts davon wird importiert, geloeschte Dokumente zaehlt der Bericht (`documents_in_trash`, Befund `document_in_trash_skipped`).
    func testAKPA1_2_trashedEntriesOfTheExportAreSkipped() async throws {
        let w = try await world()
        let dir = try install(tenant: w.tenantA)
        let manifestURL = dir.appendingPathComponent("manifest.json")
        var manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as! [[String: Any]]
        let gone = "2026-11-27T09:00:00.000Z"
        let bytes = PaperlessMock.secondVersion(950)
        try bytes.write(to: dir.appendingPathComponent("0000950.pdf"))
        manifest.append(["model": "documents.document", "pk": 950, "__exported_file_name__": "0000950.pdf",
                         "fields": ["title": "Im Papierkorb", "content": "geloescht", "created": "2023-09-01", "added": "2023-09-01T10:00:00.000000Z", "checksum": PaperlessMock.sha(bytes), "filename": "0000950.pdf",
                                    "mime_type": "application/pdf", "owner": NSNull(), "correspondent": NSNull(), "document_type": NSNull(), "storage_path": NSNull(), "tags": [Int](),
                                    "archive_serial_number": 900, "deleted_at": gone] as [String: Any]])
        manifest.append(["model": "documents.note", "pk": 950, "fields": ["document": 101, "note": "geloeschte Notiz", "created": "2023-09-01T10:00:00.000000Z", "deleted_at": gone] as [String: Any]])
        try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys]).write(to: manifestURL)
        let r = try await runAndReport(w, mode: "import")
        XCTAssertEqual(r.state, "done", "\(r.report)")
        XCTAssertEqual(counts(r.report)["documents_seen"], 10)
        XCTAssertEqual(counts(r.report)["documents_imported"], 10)
        XCTAssertEqual(counts(r.report)["documents_in_trash"], 1)
        XCTAssertEqual(finding(r.report, "document_in_trash_skipped").refs, ["document:950"])
        XCTAssertEqual(counts(r.report)["notes_imported"], 3, "geloeschte Notiz nicht uebernommen")
        XCTAssertEqual(counts(r.report)["asn_max_seen"], 17, "die Nummer eines geloeschten Dokuments hebt den Zaehler nicht")
        try await aEq(try await count("dms_documents"), 10)
        try await aEq(try await count("dms_document_notes", where: "body = 'geloeschte Notiz'"), 0)
    }
}
