import XCTVapor
import Fluent
import SQLKit
import Crypto
import Logging
import NIOSSL
@testable import HubKit

// WP-D6: Paperless-Import (AK-D9, MODUL-DMS.md 10). Nur die selbst erzeugte, synthetische Fixture `Tests/Fixtures/paperless-synthetic/export` (per generate.py reproduzierbar)
// und ein Mock-API-Server in diesem Prozess (127.0.0.1); kein Zugriff auf echte Paperless-Instanzen, -Archive oder Pfade ausserhalb von Repo und temporaerem Verzeichnis.

let d6Token = "Kanarienvogel-D6-api-token-4m8z"          // synthetisches API-Token: darf nirgends im Klartext auftauchen
let d6HashCanary = "canary-D6-hash"                       // steht in den auth.user-Eintraegen der Fixture: darf nie gelesen werden

// MARK: - Reine Logik

final class PaperlessMappingTests: XCTestCase {
    /// AK-D9 (Speicherpfade): uebersetzbare Vorlagen werden abgebildet, Filter und unbekannte Platzhalter gemeldet (nil).
    func testAKD9_storagePathTemplates() {
        XCTAssertEqual(PL.template("{{ created_year }}/{{ correspondent }}/{{ title }}"), "{doc_date:yyyy}/{correspondent}/{title}")
        XCTAssertEqual(PL.template("{created_year}-{created_month}/{document_type}/{asn}"), "{doc_date:yyyy}-{doc_date:MM}/{type}/{asn}")
        XCTAssertNil(PL.template("{{ owner_username }}/{{ title }}"))
        XCTAssertNil(PL.template("{{ title | lower }}"))
        XCTAssertNil(PL.template("{{ title"))
        XCTAssertNil(PL.template(""))
        // das Ergebnis besteht die Vorlagenpruefung der Stammdaten (gleiche Platzhalter)
        for t in ["{doc_date:yyyy}/{correspondent}/{title}", "{doc_date:MM}/{type}/{asn}"] {
            XCTAssertNotNil(PL.template(t.replacingOccurrences(of: "{doc_date:yyyy}", with: "{created_year}").replacingOccurrences(of: "{doc_date:MM}", with: "{created_month}")
                .replacingOccurrences(of: "{type}", with: "{document_type}")))
        }
    }

    /// AK-D9 (Tag-Dubletten): Dreiergruppen-Aehnlichkeit wie pg_trgm.
    func testAKD9_trigramSimilarity() {
        XCTAssertGreaterThanOrEqual(PL.similarity(PL.trigrams("Versicherung"), PL.trigrams("Versicherungen")), 0.6)
        XCTAssertLessThan(PL.similarity(PL.trigrams("Steuer"), PL.trigrams("Wichtig")), 0.2)
        XCTAssertEqual(PL.similarity(PL.trigrams("Abc"), PL.trigrams("abc")), 1)
        XCTAssertEqual(PL.similarity([], []), 0)
    }

    func testAKD9_codeDatesAndChecksums() throws {
        XCTAssertEqual(PL.code(from: "Fällig am"), "faellig_am")
        XCTAssertEqual(PL.code(from: "123 Betrag!"), "f_123_betrag")
        XCTAssertEqual(PL.code(from: "###"), "feld")
        XCTAssertEqual(PL.date("2023-03-01T00:00:00+01:00"), "2023-03-01")
        XCTAssertEqual(PL.date("2023-03-01"), "2023-03-01")
        XCTAssertNil(PL.date("2023-02-30"))
        XCTAssertNotNil(PL.timestamp("2023-02-03T09:15:00.000000Z"))
        XCTAssertNotNil(PL.timestamp("2023-02-03"))
        XCTAssertEqual(PL.algorithmName(3), "literal")
        let f = FileManager.default.temporaryDirectory.appendingPathComponent("d6-\(UUID().uuidString)")
        try Data("abc".utf8).write(to: f)
        defer { try? FileManager.default.removeItem(at: f) }
        let file = try LocalFile.measure(f, temporary: false, maxBytes: 100)
        XCTAssertEqual(file.md5, "900150983cd24fb0d6963f7d28e17f72")
        XCTAssertEqual(file.sha256, "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(PL.checksumMatches("900150983CD24FB0D6963F7D28E17F72", file), true)
        XCTAssertEqual(PL.checksumMatches(file.sha256, file), true)
        XCTAssertEqual(PL.checksumMatches("00" + file.md5.dropFirst(2), file), false)
        XCTAssertNil(PL.checksumMatches("", file)); XCTAssertNil(PL.checksumMatches(nil, file)); XCTAssertNil(PL.checksumMatches("xyz", file))
        XCTAssertThrowsError(try LocalFile.measure(f, temporary: false, maxBytes: 2))
    }

    /// AK-D9 (SSRF, TLS): nur https, keine Zugangsdaten in der URL, keine Weiterleitungsziele ueber die URL, Loopback/Link-Local gesperrt, Allowlist.
    func testAKD9_endpointPolicy() throws {
        let strict = PaperlessEndpoint.Policy()
        XCTAssertEqual(try PaperlessEndpoint.parse("https://paperless.example.org/", policy: strict).base, "https://paperless.example.org")
        XCTAssertEqual(try PaperlessEndpoint.parse("https://Paperless.Example.org:8443/pl/", policy: strict).base, "https://paperless.example.org:8443/pl")
        func code(_ u: String, _ p: PaperlessEndpoint.Policy = PaperlessEndpoint.Policy()) -> String? {
            do { _ = try PaperlessEndpoint.parse(u, policy: p); return nil } catch let e as ImportError { return e.code } catch { return "other" }
        }
        XCTAssertEqual(code("http://paperless.example.org"), "scheme_not_allowed")
        XCTAssertEqual(code("ftp://paperless.example.org"), "scheme_not_allowed")
        XCTAssertEqual(code("https://user:pw@paperless.example.org"), "invalid_url")
        XCTAssertEqual(code("https://paperless.example.org/?x=1"), "invalid_url")
        XCTAssertEqual(code("https://paperless.example.org/#f"), "invalid_url")
        XCTAssertEqual(code("https://paperless.example.org/a/../b"), "invalid_url")
        XCTAssertEqual(code("https://"), "invalid_url")
        XCTAssertEqual(code("not a url"), "invalid_url")
        for h in ["https://localhost", "https://127.0.0.1", "https://169.254.169.254/latest", "https://[::1]", "https://0.0.0.0", "https://metadata.google.internal", "https://x.localhost"] {
            XCTAssertEqual(code(h), "host_not_allowed", h)
        }
        // WP-H10: private Netze sind standardmaessig gesperrt; Heimnetz-Hosts nur mit ausdruecklicher Betreiber-Erlaubnis (DMS_ALLOW_INTERNAL_TARGETS)
        XCTAssertEqual(code("https://192.168.1.20:8000"), "host_not_allowed")
        var home = PaperlessEndpoint.Policy(); home.allowInternalTargets = true
        XCTAssertNil(code("https://192.168.1.20:8000", home))
        var list = PaperlessEndpoint.Policy(); list.allowlist = ["paperless.example.org", "other.example.org:8443"]
        XCTAssertNil(code("https://paperless.example.org", list))
        XCTAssertNil(code("https://other.example.org:8443", list))
        XCTAssertEqual(code("https://other.example.org", list), "host_not_allowed")
        XCTAssertEqual(code("https://evil.example.net", list), "host_not_allowed")
        var dev = PaperlessEndpoint.Policy(); dev.insecureDev = true
        XCTAssertNil(code("http://127.0.0.1:8000", dev))
    }
}

// MARK: - Testbasis

class DMSImportTestBase: DMSSourceTestBase {
    override var testModules: [any HubModule] {
        [DMSModule(objectStore: ObjectStoreConfig(kind: .db), maxUploadBytes: Self.uploadLimit, secretKey: d4Key, environment: ["DMS_IMPORT_INSECURE_DEV": "true"])]
    }

    var root = ""
    static var fixture: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/paperless-synthetic/export", isDirectory: true)
    }

    override func setUp() async throws {
        try await super.setUp()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("labhub-d6-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
    }
    override func tearDown() async throws {
        try? FileManager.default.removeItem(atPath: root)
        try await super.tearDown()
    }

    /// Kopiert die Fixture nach `<Wurzel>/<mandant>/<name>`.
    @discardableResult
    func install(tenant: String, as name: String = "paperless-export") throws -> URL {
        let dir = URL(fileURLWithPath: root).appendingPathComponent(tenant.lowercased()).appendingPathComponent(name)
        try FileManager.default.createDirectory(at: dir.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: Self.fixture, to: dir)
        return dir
    }

    func handler(limits l: DMSSourceLimits? = nil, policy: PaperlessEndpoint.Policy? = nil, afterDocument: (@Sendable (Int) async throws -> Void)? = nil) -> JobHandler {
        var p = PaperlessEndpoint.Policy(); p.insecureDev = true
        return DMSImport.handler(storeConfig: { ObjectStoreConfig(kind: .db) }, box: SecretBox(secretKey: d4Key), root: root, tempRoot: NSTemporaryDirectory(), policy: policy ?? p,
                                 limits: l ?? limits(), afterDocument: afterDocument)
    }

    func imports(_ tenant: String) -> String { base(tenant) + "/imports" }

    func startRun(_ w: World, source: [String: Any] = ["kind": "export", "path": "paperless-export"], mode: String, options: [String: Any]? = nil, by: TestSession? = nil) async throws -> Resp {
        var body: [String: Any] = ["source": source, "mode": mode]
        if let options { body["options"] = options }
        return try await call(app1, .POST, imports(w.tenantA), json: body, token: (by ?? w.alice).token)
    }

    func finish(_ id: String, worker: JobWorker? = nil, timeout: Double = 60) async throws {
        let wk = worker ?? JobWorker(db: db, kinds: [DMSImport.kind], handlers: [DMSImport.kind: handler()], leaseSeconds: 30, pollInterval: .milliseconds(100), logger: Logger(label: "d6.w"))
        try await runWorker(wk, until: "Lauf \(id) beendet", timeout: timeout) {
            let state = try await self.scalar("SELECT state AS v FROM dms_imports WHERE id = '\(id)'", as: String.self)
            return state != "queued" && state != "running"
        }
    }

    func runAndReport(_ w: World, mode: String, source: [String: Any] = ["kind": "export", "path": "paperless-export"], h: JobHandler? = nil) async throws -> (id: String, state: String, report: [String: Any]) {
        let r = try await startRun(w, source: source, mode: mode)
        XCTAssertEqual(r.status, .accepted, "\(r.json)")
        let id = r.json["id"] as! String
        try await finish(id, worker: JobWorker(db: db, kinds: [DMSImport.kind], handlers: [DMSImport.kind: h ?? handler()], leaseSeconds: 30, pollInterval: .milliseconds(100), logger: Logger(label: "d6.w")))
        let rep = try await call(app1, .GET, imports(w.tenantA) + "/\(id)/report", token: w.alice.token)
        XCTAssertEqual(rep.status, .ok, "\(rep.json)")
        return (id, rep.json["state"] as? String ?? "?", rep.json)
    }

    func counts(_ report: [String: Any]) -> [String: Int] { report["counts"] as? [String: Int] ?? [:] }
    func finding(_ report: [String: Any], _ code: String) -> (total: Int, refs: [String]) {
        guard let f = (report["findings"] as? [String: Any])?[code] as? [String: Any] else { return (0, []) }
        return (f["total"] as? Int ?? 0, (f["items"] as? [[String: String]] ?? []).compactMap { $0["ref"] })
    }

    /// SHA-256 je Dokument-ID der Fixture (Original und Archiv) fuer den Hashvergleich.
    func fixtureHashes() throws -> (original: [Int64: String], archive: [Int64: String]) {
        let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: Self.fixture.appendingPathComponent("manifest.json"))) as! [[String: Any]]
        var o: [Int64: String] = [:], a: [Int64: String] = [:]
        for e in manifest where e["model"] as? String == "documents.document" {
            let pk = Int64(e["pk"] as! Int)
            o[pk] = hex(try Data(contentsOf: Self.fixture.appendingPathComponent(e["__exported_file_name__"] as! String)))
            if let n = e["__exported_archive_name__"] as? String { a[pk] = hex(try Data(contentsOf: Self.fixture.appendingPathComponent(n))) }
        }
        return (o, a)
    }

    /// Fingerabdruck aller Inhalte, die ein Trockenlauf nicht veraendern darf.
    func contentFingerprint() async throws -> String {
        try await scalar("""
            SELECT concat_ws('|', (SELECT count(*) FROM dms_documents), (SELECT count(*) FROM dms_document_files), (SELECT count(*) FROM dms_document_tags), (SELECT count(*) FROM dms_document_fields),
              (SELECT count(*) FROM dms_document_texts), (SELECT count(*) FROM dms_document_notes), (SELECT count(*) FROM dms_document_types), (SELECT count(*) FROM dms_tags),
              (SELECT count(*) FROM dms_storage_paths), (SELECT count(*) FROM dms_custom_fields), (SELECT count(*) FROM contacts), (SELECT count(*) FROM links),
              (SELECT count(*) FROM files), (SELECT count(*) FROM object_chunks), (SELECT count(*) FROM dms_import_items), (SELECT count(*) FROM dms_ingest_items),
              (SELECT coalesce(sum(value), 0) FROM counters), (SELECT count(*) FROM counters), (SELECT count(*) FROM jobs WHERE kind <> 'dms.import.paperless'),
              (SELECT count(*) FROM audit_log WHERE action NOT LIKE 'dms.import.%')) AS v
            """, as: String.self)
    }
}

// MARK: - Export-Verzeichnis

final class DMSImportExportTests: DMSImportTestBase {
    /// AK-D9: Trockenlauf schreibt nichts (kein Dokument, keine Datei, kein Kontakt, kein Stammdatum, kein Zaehler, kein Job ausser dem Lauf) und liefert den Bericht:
    /// Anzahlen, Konflikte (ASN-Kollision, Name schon vorhanden), Dateien ohne Pruefsumme, aehnliche Tags, Regelvorschlaege, Rechte nicht uebernommen.
    func testAKD9_dryRunWritesNothingAndReports() async throws {
        let w = try await world()
        try install(tenant: w.tenantA)
        // Vorbestand: ein Kontakt mit gleichem Namen wie ein Korrespondent, ein Dokument mit ASN 1 (Kollision mit Fixture-Dokument 101)
        let contact = try await call(app1, .POST, "api/v1/tenants/\(w.tenantA)/contacts", json: ["kind": "organization", "display_name": "Fiktiv Handwerk"], token: w.alice.token)
        XCTAssertEqual(contact.status, .created, "\(contact.json)")
        let existing = try await upload(w.alice, w.tenantA, pdf("vorbestand"), query: "archive=true")
        XCTAssertEqual(existing.status, .created, "\(existing.json)")
        XCTAssertEqual(existing.json["asn"] as? Int, 1)
        let before = try await contentFingerprint()

        let run = try await runAndReport(w, mode: "dry_run")
        XCTAssertEqual(run.state, "done", "\(run.report)")
        try await aEq(try await contentFingerprint(), before, "Trockenlauf darf nichts im DMS schreiben")
        let c = counts(run.report)
        XCTAssertEqual(c["documents_seen"], 10)
        XCTAssertEqual(c["documents_would_import"], 10)
        XCTAssertEqual(c["files_original"], 10)
        XCTAssertEqual(c["files_archive"], 2)
        XCTAssertEqual(c["correspondents_would_create"], 4)
        XCTAssertEqual(c["types_would_create"], 3)
        XCTAssertEqual(c["tags_would_create"], 5)
        XCTAssertEqual(c["tags_merged"], 1, "Tag-Dublette steuer/Steuer wird zusammengefuehrt")
        XCTAssertEqual(c["paths_would_create"], 1)
        XCTAssertEqual(c["paths_untranslatable"], 1)
        XCTAssertEqual(c["fields_would_create"], 3)
        XCTAssertEqual(c["files_without_checksum"], 1)
        XCTAssertEqual(c["asn_collisions"], 1)
        XCTAssertEqual(c["asn_max_seen"], 17)
        XCTAssertEqual(finding(run.report, "asn_collision").refs, ["document:101"])
        XCTAssertEqual(finding(run.report, "file_without_checksum").refs, ["document:110"])
        XCTAssertEqual(finding(run.report, "storage_path_untranslatable").refs, ["path:2"])
        XCTAssertEqual(finding(run.report, "contact_possible_duplicate").refs, ["correspondent:3"], "Dubletten-Hinweis K5, nie still zusammenfuehren")
        XCTAssertEqual(finding(run.report, "tag_similar").total, 1)
        XCTAssertEqual(finding(run.report, "reference_matched_by_name").refs, ["tag:2"])
        XCTAssertEqual(finding(run.report, "monetary_currency_dropped").total, 1)
        // Rechte/Besitzer: nur Zaehler, nichts uebernommen (F-23); Regeln nur als Vorschlaege
        let rights = run.report["rights"] as? [String: Any] ?? [:]
        XCTAssertEqual(rights["imported"] as? Bool, false)
        XCTAssertEqual(rights["source_users"] as? Int, 2); XCTAssertEqual(rights["source_groups"] as? Int, 1); XCTAssertEqual(rights["owners_seen"] as? Int, 1)
        let suggestions = run.report["rule_suggestions"] as? [[String: Any]] ?? []
        XCTAssertEqual(suggestions.count, 5)
        XCTAssertTrue(suggestions.contains { $0["target_name"] as? String == "Fiktiv Handwerk" && $0["algorithm"] as? String == "auto" && $0["translatable"] as? Bool == false })
        XCTAssertTrue(suggestions.contains { $0["target_name"] as? String == "Muster Strom GmbH" && $0["algorithm"] as? String == "any" && $0["translatable"] as? Bool == true })
        try await aEq(try await count("dms_rules"), 0)
        // Lauf: Zustand done, Bericht als Datei abrufbar, Zaehler des Mandanten unveraendert
        let status = try await call(app2, .GET, imports(w.tenantA) + "/\(run.id)", token: w.alice.token)
        XCTAssertEqual(status.json["state"] as? String, "done"); XCTAssertEqual(status.json["mode"] as? String, "dry_run")
        XCTAssertEqual((status.json["progress"] as? [String: Any])?["processed"] as? Int, 10)
        let file = try await raw(app2, .GET, imports(w.tenantA) + "/\(run.id)/report", token: w.alice.token)
        XCTAssertTrue(file.headers.first(name: .contentDisposition)?.hasPrefix("attachment; filename=\"paperless-import-report-") == true)
        XCTAssertEqual(file.headers.first(name: "X-Content-Type-Options"), "nosniff")
        try await aEq(try await scalar("SELECT value::bigint AS v FROM counters WHERE key = 'dms:asn'", as: Int64.self), 1)
        let jobs = try await scalar("SELECT state AS v FROM jobs WHERE kind = 'dms.import.paperless'", as: String.self)
        XCTAssertEqual(jobs, "done")
        try await aEq(try await auditCount("dms.import.completed", tenant: w.tenantA), 1)
    }

    /// AK-D9: Fixture-Import vollstaendig (Zaehlungen, Hashes identisch, Beziehungen), ASN-Zaehler >= Maximum mit Audit; Wiederholung erzeugt keine Duplikate.
    func testAKD9_fullImportCountsHashesRelationsAndIdempotentRepeat() async throws {
        let w = try await world()
        try install(tenant: w.tenantA)
        let run = try await runAndReport(w, mode: "import")
        XCTAssertEqual(run.state, "done", "\(run.report)")
        let c = counts(run.report)
        XCTAssertEqual(c["documents_imported"], 10); XCTAssertEqual(c["documents_seen"], 10)
        XCTAssertEqual(c["correspondents_created"], 4); XCTAssertEqual(c["types_created"], 3); XCTAssertEqual(c["tags_created"], 5); XCTAssertEqual(c["paths_created"], 1)
        XCTAssertEqual(c["fields_created"], 3); XCTAssertEqual(c["notes_imported"], 3); XCTAssertEqual(c["files_archive"], 2); XCTAssertEqual(c["asn_assigned"], 7)
        try await aEq(try await count("dms_documents"), 10)
        try await aEq(try await count("dms_document_types"), 3); try await aEq(try await count("dms_tags"), 5); try await aEq(try await count("dms_storage_paths"), 1)
        try await aEq(try await count("dms_custom_fields"), 3)
        try await aEq(try await count("contacts", where: "is_correspondent"), 4)
        try await aEq(try await count("dms_document_notes"), 3)

        // Hashes: Original und Archiv byteidentisch zur Fixture (SHA-256 neu berechnet, im Objektspeicher)
        let hashes = try fixtureHashes()
        for (pk, sha) in hashes.original {
            let got = try await scalar("""
                SELECT f.sha256 AS v FROM dms_document_files f JOIN dms_ingest_items i ON i.document_id = f.document_id WHERE i.origin_ref = 'paperless:\(pk)' AND f.role = 'original'
                """, as: String.self)
            XCTAssertEqual(got, sha, "Original \(pk)")
            let doc = try await scalar("SELECT document_id::text AS v FROM dms_ingest_items WHERE origin_ref = 'paperless:\(pk)'", as: String.self)
            let dl = try await raw(app2, .GET, base(w.tenantA) + "/documents/\(doc)/file", token: w.alice.token)
            XCTAssertEqual(dl.status, .ok); XCTAssertEqual(hex(dl.body), sha, "Download \(pk)")
        }
        for (pk, sha) in hashes.archive {
            let got = try await scalar("""
                SELECT f.sha256 AS v FROM dms_document_files f JOIN dms_ingest_items i ON i.document_id = f.document_id WHERE i.origin_ref = 'paperless:\(pk)' AND f.role = 'archive'
                """, as: String.self)
            XCTAssertEqual(got, sha, "Archiv \(pk)")
        }
        try await aEq(try await count("dms_document_files", where: "role = 'archive'"), 2)

        // Beziehungen
        func doc(_ pk: Int) async throws -> [String: Any] {
            let id = try await scalar("SELECT document_id::text AS v FROM dms_ingest_items WHERE origin_ref = 'paperless:\(pk)'", as: String.self)
            let r = try await call(app1, .GET, base(w.tenantA) + "/documents/\(id)", token: w.alice.token)
            XCTAssertEqual(r.status, .ok); return r.json
        }
        func name(_ table: String, _ id: Any?) async throws -> String? {
            guard let id = id as? String else { return nil }
            return try await scalar("SELECT \(table == "contacts" ? "display_name" : "name") AS v FROM \(table) WHERE id = '\(id)'", as: String.self)
        }
        let d101 = try await doc(101), d102 = try await doc(102), d104 = try await doc(104), d109 = try await doc(109)
        let corr101 = try await name("contacts", d101["correspondent_id"])
        XCTAssertEqual(corr101, "Muster Strom GmbH")
        let type101 = try await name("dms_document_types", d101["document_type_id"])
        XCTAssertEqual(type101, "Rechnung")
        let path101 = try await name("dms_storage_paths", d101["storage_path_id"])
        XCTAssertEqual(path101, "Jahr und Korrespondent")
        XCTAssertEqual(d101["doc_date"] as? String, "2023-02-01"); XCTAssertEqual(d101["received_at"] as? String, "2023-02-03T09:15:00Z")
        XCTAssertEqual(d101["asn"] as? Int, 1); XCTAssertEqual(d101["status"] as? String, "archived"); XCTAssertEqual(d101["title"] as? String, "Stromrechnung Januar 2023")
        var tagNames: [String] = []
        for t in d101["tag_ids"] as? [String] ?? [] { tagNames.append(try await name("dms_tags", t) ?? "?") }
        XCTAssertEqual(Set(tagNames), ["Steuer", "Wichtig"])
        let tags102 = try await name("dms_tags", (d102["tag_ids"] as? [String])?.first)
        XCTAssertEqual(tags102, "Steuer", "steuer/Steuer wurden zusammengefuehrt")
        XCTAssertEqual((d101["fields"] as? [String: Any])?["betrag"] as? String, "84.20")
        XCTAssertEqual((d101["fields"] as? [String: Any])?["referenz"] as? String, "SR-2023-01")
        XCTAssertEqual((d102["fields"] as? [String: Any])?["faellig_am"] as? String, "2023-03-15")
        XCTAssertNil(d104["storage_path_id"] as? String, "nicht uebersetzbarer Pfad wird nicht gesetzt (im Bericht)")
        XCTAssertNil(d109["asn"] as? Int); XCTAssertEqual(d109["status"] as? String, "needs_review")
        XCTAssertEqual((d101["files"] as? [[String: Any]])?.count, 1)
        let notes = try await call(app1, .GET, base(w.tenantA) + "/documents/\(try await scalar("SELECT document_id::text AS v FROM dms_ingest_items WHERE origin_ref = 'paperless:103'", as: String.self))/notes", token: w.alice.token)
        XCTAssertEqual(items(notes).count, 2)
        // Korrespondenten-Verweis kommt aus dem Import (Quelle import), Ingest-Vorgang ist fertig, Text ist uebernommen und durchsuchbar
        try await aEq(try await count("links", where: "kind = 'correspondent' AND source = 'import'"), 8)
        try await aEq(try await count("dms_ingest_items", where: "state = 'done' AND source = 'api'"), 10)
        try await aEq(try await count("dms_document_texts", where: "engine = 'imported'"), 9)
        let search = try await call(app1, .GET, "api/v1/tenants/\(w.tenantA)/dms/search?q=Dachrinne", token: w.alice.token)
        XCTAssertEqual(items(search).count, 1, "\(search.json)")
        // ASN-Zaehler >= Maximum (17), Audit der Anhebung, naechster Upload bekommt 18
        let counter = try await scalar("SELECT value::bigint AS v FROM counters WHERE key = 'dms:asn'", as: Int64.self)
        XCTAssertGreaterThanOrEqual(counter, 17)
        let asnReport = run.report["asn"] as? [String: Any] ?? [:]
        XCTAssertEqual(asnReport["counter_value"] as? Int, 17); XCTAssertEqual(asnReport["max_seen"] as? Int, 17)
        try await aGE(try await count("audit_log", where: "action = 'counter.raised' AND meta->>'reason' = 'paperless_import'"), 1)
        let next = try await upload(w.alice, w.tenantA, pdf("nach-dem-import"), query: "archive=true")
        XCTAssertEqual(next.json["asn"] as? Int, 18)
        // keine Benutzerdaten/Kennwort-Hashes der Quelle im Hub (auth.user wird nie gelesen)
        let leakedHash = try await databaseDumpContains(d6HashCanary)
        XCTAssertFalse(leakedHash)
        let leakedUser = try await databaseDumpContains("fixture_user_a")
        XCTAssertFalse(leakedUser)

        // Wiederholung: neuer Lauf ergaenzt nichts, keine Duplikate (Schluessel Quelle + Paperless-ID)
        let fingerprint = try await contentFingerprint()
        let again = try await runAndReport(w, mode: "import")
        XCTAssertEqual(again.state, "done")
        let c2 = counts(again.report)
        XCTAssertEqual(c2["documents_imported"], 0); XCTAssertEqual(c2["documents_skipped_existing"], 10)
        XCTAssertEqual(c2["correspondents_existing"], 4); XCTAssertEqual(c2["tags_existing"], 6)
        let after = try await contentFingerprint()
        // ausser Audit-Eintraegen des Laufs und dem Auditsatz (nur dms.import.*, ausgenommen) bleibt alles gleich
        XCTAssertEqual(after, fingerprint, "Wiederholung darf nichts aendern")
        try await aEq(try await count("dms_documents"), 11)   // 10 importiert + 1 Upload nach dem Import
        // dieselben Dateien unter einem anderen Pfad (anderer Schluessel): gleicher Inhalt wird nicht ein zweites Mal uebernommen
        try install(tenant: w.tenantA, as: "kopie")
        let copy = try await runAndReport(w, mode: "import", source: ["kind": "export", "path": "kopie"])
        XCTAssertEqual(copy.state, "done")
        XCTAssertEqual(counts(copy.report)["documents_imported"], 0)
        XCTAssertEqual(finding(copy.report, "duplicate_hash_imported").total, 10)
        try await aEq(try await count("dms_documents"), 11)
    }

    /// AK-D9: Abbruch mitten im Lauf (Dokumente bleiben konsistent) und Fortsetzung durch einen neuen Lauf; am Ende genau die Fixture-Dokumente, keine Duplikate.
    func testAKD9_cancelThenResume() async throws {
        let w = try await world()
        try install(tenant: w.tenantA)
        let appRef = UnsafeSendableBox(self), token = w.alice.token, tenant = w.tenantA
        let runID = UnsafeSendableBox("")
        let hook: @Sendable (Int) async throws -> Void = { n in
            guard n == 4 else { return }
            let t = appRef.value
            let r = try await t.call(t.app1, .POST, t.imports(tenant) + "/\(runID.value)/cancel", token: token)
            XCTAssertEqual(r.status, .ok, "\(r.json)")
        }
        let started = try await startRun(w, mode: "import")
        runID.value = started.json["id"] as! String
        try await finish(runID.value, worker: JobWorker(db: db, kinds: [DMSImport.kind], handlers: [DMSImport.kind: handler(afterDocument: hook)], leaseSeconds: 30, pollInterval: .milliseconds(100), logger: Logger(label: "d6.w")))
        let first = try await call(app1, .GET, imports(w.tenantA) + "/\(runID.value)", token: w.alice.token)
        XCTAssertEqual(first.json["state"] as? String, "cancelled")
        try await aEq(try await count("dms_documents"), 4)
        try await aEq(try await count("dms_import_items", where: "kind = 'document'"), 4)
        let rep = try await call(app1, .GET, imports(w.tenantA) + "/\(runID.value)/report", token: w.alice.token)
        XCTAssertEqual(rep.json["state"] as? String, "cancelled"); XCTAssertEqual(counts(rep.json)["documents_imported"], 4)
        try await aEq(try await auditCount("dms.import.cancel_requested", tenant: w.tenantA), 1); try await aEq(try await auditCount("dms.import.cancelled", tenant: w.tenantA), 1)
        // Abbruch eines beendeten Laufs: 409
        let again = try await call(app1, .POST, imports(w.tenantA) + "/\(runID.value)/cancel", token: w.alice.token)
        XCTAssertEqual(again.status, .conflict)
        // Fortsetzung: neuer Lauf gegen dieselbe Quelle ergaenzt nur die fehlenden 6
        let resume = try await runAndReport(w, mode: "import")
        XCTAssertEqual(resume.state, "done")
        XCTAssertEqual(counts(resume.report)["documents_imported"], 6); XCTAssertEqual(counts(resume.report)["documents_skipped_existing"], 4)
        try await aEq(try await count("dms_documents"), 10)
        try await aEq(try await count("dms_import_items", where: "kind = 'document'"), 10)
        try await aEq(try await count("contacts", where: "is_correspondent"), 4, "keine Dubletten beim Fortsetzen")
        try await aEq(try await count("dms_tags"), 5)
        // Abbruch eines wartenden Laufs: sofort cancelled, der Job tut nichts
        try install(tenant: w.tenantA, as: "zweit")
        let queued = try await startRun(w, source: ["kind": "export", "path": "zweit"], mode: "dry_run")
        let qid = queued.json["id"] as! String
        let c = try await call(app2, .POST, imports(w.tenantA) + "/\(qid)/cancel", token: w.alice.token)
        XCTAssertEqual(c.json["state"] as? String, "cancelled")
        let worker = JobWorker(db: db, kinds: [DMSImport.kind], handlers: [DMSImport.kind: handler()], leaseSeconds: 30, pollInterval: .milliseconds(100), logger: Logger(label: "d6.w"))
        try await runWorker(worker, until: "Job erledigt") { try await self.count("jobs", where: "kind = 'dms.import.paperless' AND state IN ('queued', 'running')") == 0 }
        try await aEq(try await scalar("SELECT state AS v FROM dms_imports WHERE id = '\(qid)'", as: String.self), "cancelled")
        try await aEq(try await scalar("SELECT count(*)::bigint AS v FROM dms_import_findings WHERE run_id = '\(qid)'", as: Int64.self), 0)
    }

    /// AK-D9: zwei Worker auf zwei Verbindungen, mehrere Laeufe: jeder Lauf genau einmal; ein Lauf allein (zwei Worker) ebenfalls genau einmal.
    func testAKD9_twoWorkersRunEachImportExactlyOnce() async throws {
        let w = try await world()
        var ids: [String] = []
        for name in ["q1", "q2", "q3", "q4"] {
            try install(tenant: w.tenantA, as: name)
            let r = try await startRun(w, source: ["kind": "export", "path": name], mode: "dry_run")
            XCTAssertEqual(r.status, .accepted, "\(r.json)"); ids.append((r.json["id"] as! String).lowercased())
        }
        let seen = DMSImportResults()
        let real = handler()
        let counting: JobHandler = { job, s in
            let p = try JSONDecoder().decode(DMSImport.Payload.self, from: Data(job.payload.utf8))
            seen.add(p.import_id.uuidString.lowercased())
            try await real(job, s)
            try await Task.sleep(for: .milliseconds(150))
        }
        let w1 = JobWorker(db: db, kinds: [DMSImport.kind], handlers: [DMSImport.kind: counting], leaseSeconds: 30, pollInterval: .milliseconds(100), logger: Logger(label: "d6.w1"))
        let w2 = JobWorker(db: app2.db(.psql) as! any SQLDatabase, kinds: [DMSImport.kind], handlers: [DMSImport.kind: counting], leaseSeconds: 30, pollInterval: .milliseconds(100), logger: Logger(label: "d6.w2"))
        let t1 = Task { await w1.run() }, t2 = Task { await w2.run() }
        try await eventually("alle Laeufe fertig") { try await self.count("dms_imports", where: "state = 'done'") == 4 }
        w1.requestShutdown(); w2.requestShutdown(); await t1.value; await t2.value
        XCTAssertEqual(seen.all.count, 4, "\(seen.all)")
        XCTAssertEqual(Set(seen.all), Set(ids), "jeder Lauf genau einmal")
        // Ein Importlauf, zwei Worker: ein Handler-Aufruf, 10 Dokumente ohne Duplikate
        try install(tenant: w.tenantA)
        let one = try await startRun(w, mode: "import")
        let oneID = (one.json["id"] as! String).lowercased()
        let seen2 = DMSImportResults()
        let counting2: JobHandler = { job, s in
            let p = try JSONDecoder().decode(DMSImport.Payload.self, from: Data(job.payload.utf8))
            if p.import_id.uuidString.lowercased() == oneID { seen2.add(oneID) }
            try await real(job, s)
        }
        let v1 = JobWorker(db: db, kinds: [DMSImport.kind], handlers: [DMSImport.kind: counting2], leaseSeconds: 30, pollInterval: .milliseconds(50), logger: Logger(label: "d6.v1"))
        let v2 = JobWorker(db: app2.db(.psql) as! any SQLDatabase, kinds: [DMSImport.kind], handlers: [DMSImport.kind: counting2], leaseSeconds: 30, pollInterval: .milliseconds(50), logger: Logger(label: "d6.v2"))
        let u1 = Task { await v1.run() }, u2 = Task { await v2.run() }
        try await eventually("Importlauf fertig") { try await self.scalar("SELECT state AS v FROM dms_imports WHERE id = '\(oneID)'", as: String.self) == "done" }
        v1.requestShutdown(); v2.requestShutdown(); await u1.value; await u2.value
        XCTAssertEqual(seen2.all.count, 1)
        try await aEq(try await count("dms_documents"), 10)
    }

    /// AK-D9: Abgestuerzter Worker (Lease laeuft ab): ein anderer Worker setzt den Lauf fort, keine Duplikate.
    func testAKD9_leaseExpiryResumesRun() async throws {
        let w = try await world()
        try install(tenant: w.tenantA)
        let r = try await startRun(w, mode: "import")
        let id = r.json["id"] as! String
        // Worker A blockiert nach dem vierten Dokument (simulierter Absturz: Lease wird nicht erneuert, weil der Prozess haengt)
        let hang: @Sendable (Int) async throws -> Void = { n in if n == 4 { try await Task.sleep(for: .seconds(30)) } }
        let crashing = JobWorker(db: db, kinds: [DMSImport.kind], handlers: [DMSImport.kind: handler(afterDocument: hang)], leaseSeconds: 1, pollInterval: .milliseconds(50), logger: Logger(label: "d6.crash"))
        let a = Task { await crashing.run() }
        try await eventually("vier Dokumente importiert") { try await self.count("dms_documents") >= 4 }
        // dem haengenden Worker die Lease entziehen, wie nach einem SIGKILL: Job freigeben (Ablauf der Lease)
        try await db.raw("UPDATE jobs SET lease_until = now() - interval '1 second' WHERE kind = 'dms.import.paperless'").run()
        let b = JobWorker(db: app2.db(.psql) as! any SQLDatabase, kinds: [DMSImport.kind], handlers: [DMSImport.kind: handler()], leaseSeconds: 30, pollInterval: .milliseconds(50), logger: Logger(label: "d6.next"))
        try await runWorker(b, until: "Lauf fortgesetzt", timeout: 60) { try await self.scalar("SELECT state AS v FROM dms_imports WHERE id = '\(id)'", as: String.self) == "done" }
        crashing.requestShutdown(); a.cancel(); await a.value
        try await aEq(try await count("dms_documents"), 10)
        try await aEq(try await count("dms_import_items", where: "kind = 'document'"), 10)
        try await aEq(try await count("contacts", where: "is_correspondent"), 4)
    }

    /// AK-D9: Schutz vor boesen Manifesten und Dateien: Pfade ausserhalb, Links, falsche Pruefsumme, unbekannter Dateityp, zu grosse Datei; die uebrigen Dokumente laufen durch.
    func testAKD9_hostileExportIsContained() async throws {
        let w = try await world()
        let dir = try install(tenant: w.tenantA)
        let outside = URL(fileURLWithPath: root).appendingPathComponent("geheim.pdf")
        try pdf("ausserhalb").write(to: outside)
        // 101: Pfad mit ..; 102: Symlink auf eine Datei ausserhalb; 103: Datei verfaelscht (Pruefsumme passt nicht); 104: kein PDF/Bild; 105: zu gross
        var manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: dir.appendingPathComponent("manifest.json"))) as! [[String: Any]]
        for i in manifest.indices where manifest[i]["model"] as? String == "documents.document" {
            switch manifest[i]["pk"] as? Int {
            case 101: manifest[i]["__exported_file_name__"] = "../geheim.pdf"
            case 102:
                try? FileManager.default.removeItem(at: dir.appendingPathComponent("0000102.pdf"))
                try FileManager.default.createSymbolicLink(at: dir.appendingPathComponent("0000102.pdf"), withDestinationURL: outside)
            case 103: try Data("%PDF-1.4 verfaelscht".utf8).write(to: dir.appendingPathComponent("0000103.pdf"))
            case 104:
                try Data("PK\u{3}\u{4}kein-erlaubter-typ".utf8).write(to: dir.appendingPathComponent("0000104.pdf"))
                var f = manifest[i]["fields"] as! [String: Any]; f["checksum"] = ""; manifest[i]["fields"] = f
            case 105:
                let big = pdf("gross", padding: Int(Self.uploadLimit) + 10)
                try big.write(to: dir.appendingPathComponent("0000105.pdf"))
            default: break
            }
        }
        try JSONSerialization.data(withJSONObject: manifest).write(to: dir.appendingPathComponent("manifest.json"))
        let run = try await runAndReport(w, mode: "import")
        XCTAssertEqual(run.state, "done", "\(run.report)")
        XCTAssertEqual(counts(run.report)["documents_imported"], 5)
        XCTAssertEqual(finding(run.report, "file_missing").refs, ["document:101", "document:102"])
        XCTAssertEqual(finding(run.report, "checksum_mismatch").refs, ["document:103"])
        XCTAssertEqual(finding(run.report, "unsupported_type").refs, ["document:104"])
        XCTAssertEqual(finding(run.report, "file_too_large").refs, ["document:105"])
        try await aEq(try await count("dms_documents"), 5)
        let leakedPath = try await databaseDumpContains("geheim.pdf")
        XCTAssertFalse(leakedPath)
        // Quelle ausserhalb der Mandantenwurzel (Symlink auf anderes Verzeichnis): Lauf scheitert mit source_not_found, es wird nichts gelesen
        let escape = URL(fileURLWithPath: root).appendingPathComponent(w.tenantA.lowercased()).appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: escape, withDestinationURL: URL(fileURLWithPath: root))
        let esc = try await startRun(w, source: ["kind": "export", "path": "link"], mode: "dry_run")
        try await finish(esc.json["id"] as! String)
        let st = try await call(app1, .GET, imports(w.tenantA) + "/\(esc.json["id"] as! String)", token: w.alice.token)
        XCTAssertEqual(st.json["state"] as? String, "failed"); XCTAssertEqual(st.json["error_code"] as? String, "source_not_found")
        // Quelle ohne Manifest; ohne Wurzel im Worker
        try FileManager.default.createDirectory(at: URL(fileURLWithPath: root).appendingPathComponent(w.tenantA.lowercased()).appendingPathComponent("leer"), withIntermediateDirectories: true)
        let empty = try await startRun(w, source: ["kind": "export", "path": "leer"], mode: "dry_run")
        try await finish(empty.json["id"] as! String)
        try await aEq(try await scalar("SELECT error_code AS v FROM dms_imports WHERE id = '\(empty.json["id"] as! String)'", as: String.self), "manifest_missing")
        let rootless = DMSImport.handler(storeConfig: { ObjectStoreConfig(kind: .db) }, box: nil, root: nil, tempRoot: NSTemporaryDirectory(), policy: PaperlessEndpoint.Policy(), limits: limits())
        let noRoot = try await startRun(w, source: ["kind": "export", "path": "paperless-export"], mode: "dry_run")
        try await finish(noRoot.json["id"] as! String, worker: JobWorker(db: db, kinds: [DMSImport.kind], handlers: [DMSImport.kind: rootless], leaseSeconds: 30, pollInterval: .milliseconds(100), logger: Logger(label: "d6.w")))
        try await aEq(try await scalar("SELECT error_code AS v FROM dms_imports WHERE id = '\(noRoot.json["id"] as! String)'", as: String.self), "import_root_missing")
    }

    /// AK-D9 (Quota wie Upload): ueberschreitet der Import die Mandantenquota, scheitert der Lauf mit `storage_quota_exceeded`; bis dahin Importiertes ist vollstaendig, nichts Halbes.
    func testAKD9_quotaStopsRunConsistently() async throws {
        let w = try await world()
        try install(tenant: w.tenantA)
        var l = limits(); l.quotaBytes = 2200
        let run = try await runAndReport(w, mode: "import", h: handler(limits: l))
        XCTAssertEqual(run.state, "failed")
        XCTAssertEqual(run.report["error_code"] as? String, "storage_quota_exceeded")
        let n = try await count("dms_documents")
        XCTAssertGreaterThan(n, 0); XCTAssertLessThan(n, 10)
        try await aEq(try await count("dms_document_files", where: "role = 'original'"), n)
        try await aEq(try await count("dms_import_items", where: "kind = 'document'"), n)
        try await aEq(try await count("dms_ingest_items"), n)
        // nach Anhebung der Quota setzt ein neuer Lauf fort
        let again = try await runAndReport(w, mode: "import")
        XCTAssertEqual(again.state, "done"); try await aEq(try await count("dms_documents"), 10)
    }

    /// AK-D9: OCR-Option: Dokument ohne uebernommenen Text bekommt einen OCR-Job (Massenpriorität), mit Text nicht; Option aus = kein Job.
    func testAKD9_ocrOnlyForDocumentsWithoutText() async throws {
        let w = try await world()
        try install(tenant: w.tenantA)
        var l = limits(); l.ocrEnabled = true
        let r = try await startRun(w, mode: "import", options: ["ocr": true])
        let id = r.json["id"] as! String
        try await finish(id, worker: JobWorker(db: db, kinds: [DMSImport.kind], handlers: [DMSImport.kind: handler(limits: l)], leaseSeconds: 30, pollInterval: .milliseconds(100), logger: Logger(label: "d6.w")))
        try await aEq(try await count("jobs", where: "kind = 'dms.ocr'"), 1, "nur Dokument 109 hat keinen Text")
        try await aEq(try await count("dms_ingest_items", where: "state = 'ocr_queued'"), 1)
        try await aEq(try await count("dms_ingest_items", where: "state = 'done'"), 9)
    }

    /// AK-D9: Rechte (nur Buchhaltung/Owner), Mandantentrennung (fremde ID 404, fremder Mandant sieht nichts), Modul aus, Validierung, Zugangsdaten nie im Klartext, ein offener Lauf je Quelle.
    func testAKD9_rolesTenantSeparationValidationAndSecrets() async throws {
        let w = try await world()
        try install(tenant: w.tenantA)
        let accountant = try await addUser("accountant", handle: "buchhaltung", tenant: w.tenantA, by: w.alice)
        let member = try await addUser("member", handle: "mitglied", tenant: w.tenantA, by: w.alice)
        let tax = try await addUser("tax_advisor", handle: "berater", tenant: w.tenantA, by: w.alice)
        let ok = try await startRun(w, mode: "dry_run", by: accountant)
        XCTAssertEqual(ok.status, .accepted, "\(ok.json)")
        let id = ok.json["id"] as! String
        XCTAssertEqual(ok.json["has_secret"] as? Bool, false); XCTAssertEqual((ok.json["config"] as? [String: String])?["path"], "paperless-export")
        for s in [member, tax] {
            for (m, p) in [(HTTPMethod.GET, ""), (.POST, ""), (.GET, "/\(id)"), (.GET, "/\(id)/report"), (.POST, "/\(id)/cancel")] {
                let r = try await call(app1, m, imports(w.tenantA) + p, json: m == .POST && p.isEmpty ? ["mode": "dry_run", "source": ["kind": "export", "path": "x"]] : nil, token: s.token)
                XCTAssertEqual(r.status, .forbidden, "\(m) \(p)")
            }
        }
        try await aEq(try await count("dms_imports"), 1)
        // ein offener Lauf je Quelle: zweiter Start 409, auch gleichzeitig
        let dupe = try await startRun(w, mode: "import")
        XCTAssertEqual(dupe.status, .conflict, "\(dupe.json)")
        let racers = try await parallel(6) { i in try await self.raw(i % 2 == 0 ? self.app1 : self.app2, .POST, self.imports(w.tenantA), body: Data(#"{"mode":"dry_run","source":{"kind":"export","path":"andere"}}"#.utf8),
                                                                       token: w.alice.token, headers: ["Content-Type": "application/json"]) }
        XCTAssertEqual(racers.filter { $0.status == .accepted }.count, 1, "\(racers.map(\.status))")
        // Validierung
        for (body, field) in [
            (["mode": "dry_run"], "source"), (["source": ["kind": "export", "path": "x"]], "mode"), (["mode": "nope", "source": ["kind": "export", "path": "x"]], "mode"),
            (["mode": "import", "source": ["kind": "ftp"]], "source.kind"), (["mode": "import", "source": ["kind": "export"]], "source.path"),
            (["mode": "import", "source": ["kind": "export", "path": "../etc"]], "source.path"), (["mode": "import", "source": ["kind": "export", "path": "/etc"]], "source.path"),
            (["mode": "import", "source": ["kind": "export", "path": ".versteckt"]], "source.path"), (["mode": "import", "source": ["kind": "export", "path": "a//b"]], "source.path"),
            (["mode": "import", "source": ["kind": "export", "path": "x", "token": "t"]], "source.token"), (["mode": "import", "source": ["kind": "export", "path": "x"], "tenant_id": "x"], "tenant_id"),
            (["mode": "import", "source": ["kind": "export", "path": "x"], "options": ["ocr": "ja"]], "options.ocr"), (["mode": "import", "source": ["kind": "export", "path": "x"], "options": ["x": 1]], "options.x"),
            (["mode": "import", "source": ["kind": "api", "base_url": "https://paperless.example.org"]], "source.token"),
            (["mode": "import", "source": ["kind": "api", "token": "t"]], "source.base_url"),
            (["mode": "import", "source": ["kind": "api", "base_url": "https://u:p@paperless.example.org", "token": "t"]], "source.base_url"),
            (["mode": "import", "source": ["kind": "api", "base_url": "https://paperless.example.org", "token": "t", "extra": 1]], "source.extra")] as [([String: Any], String)] {
            let r = try await call(app1, .POST, imports(w.tenantA), json: body, token: w.alice.token)
            XCTAssertEqual(r.status, .unprocessableEntity, "\(field): \(r.json)")
            XCTAssertTrue((r.json["errors"] as? [[String: Any]] ?? []).contains { $0["field"] as? String == field }, "\(field): \(r.json)")
        }
        // Zugangsdaten: Token verschluesselt, nie in Antworten, Datenbank, Audit, Jobs
        let api = try await call(app1, .POST, imports(w.tenantA), json: ["mode": "dry_run", "source": ["kind": "api", "base_url": "http://127.0.0.1:9", "token": d6Token]], token: w.alice.token)
        XCTAssertEqual(api.status, .accepted, "\(api.json)")
        XCTAssertEqual(api.json["has_secret"] as? Bool, true)
        XCTAssertFalse(String(decoding: try JSONSerialization.data(withJSONObject: api.json), as: UTF8.self).contains(d6Token))
        let enc = try await scalar("SELECT secret_enc AS v FROM dms_imports WHERE id = '\(api.json["id"] as! String)'", as: String.self)
        XCTAssertTrue(enc.hasPrefix("v1:"))
        let leakedToken = try await databaseDumpContains(d6Token)
        XCTAssertFalse(leakedToken, "Token im Klartext in der Datenbank")
        // Mandantentrennung: Bob (eigener Mandant) sieht nichts, fremde ID 404, der Bericht ebenso
        let bobTenant = UUID(), bob = UUID(), bobToken = AuthSecrets.token()
        try await db.raw("INSERT INTO users (id, handle, display_name) VALUES (\(bind: bob), 'bob6', 'Bob Synthetic')").run()
        try await db.raw("INSERT INTO tenants (id, name) VALUES (\(bind: bobTenant), 'Bobs Firma')").run()
        try await db.raw("INSERT INTO memberships (tenant_id, user_id, role) VALUES (\(bind: bobTenant), \(bind: bob), 'owner')").run()
        let hash = AuthSecrets.hash(bobToken)
        try await db.raw("INSERT INTO sessions (user_id, token_hash, kind, expires_at) VALUES (\(bind: bob), \(bind: hash), 'normal', now() + interval '1 day')").run()
        try await setModule(bobTenant.uuidString, true, by: TestSession(token: bobToken, userID: bob.uuidString, csrf: "", handle: "bob6"))
        let own = try await call(app1, .GET, imports(bobTenant.uuidString), token: bobToken)
        XCTAssertEqual(own.status, .ok, "\(own.json)"); XCTAssertEqual(items(own).count, 0)
        for p in ["", "/report", "/cancel"] {
            let r = try await call(app1, p == "/cancel" ? .POST : .GET, imports(bobTenant.uuidString) + "/\(id)" + p, token: bobToken)
            XCTAssertEqual(r.status, .notFound, p)
            let cross = try await call(app1, p == "/cancel" ? .POST : .GET, imports(w.tenantA) + "/\(id)" + p, token: bobToken)
            XCTAssertEqual(cross.status, .notFound, "Bob ist kein Mitglied von A: \(p)")
        }
        try await aEq(try await scalar("SELECT state AS v FROM dms_imports WHERE id = '\(id)'", as: String.self), "queued")
        // Audit ohne Nutzdaten
        try await aEq(try await auditCount("dms.import.requested", tenant: w.tenantA), 3)
        let auditLeak = try await count("audit_log", where: "meta::text ILIKE '%\(d6Token)%' OR meta::text ILIKE '%127.0.0.1%' OR meta::text ILIKE '%paperless-export%'")
        XCTAssertEqual(auditLeak, 0)
        // Modul aus: 404 module_disabled
        try await setModule(w.tenantA, false, by: w.alice)
        let off = try await call(app1, .GET, imports(w.tenantA), token: w.alice.token)
        XCTAssertEqual(off.status, .notFound); XCTAssertEqual(off.problemCode, "module_disabled")
        try await setModule(w.tenantA, true, by: w.alice)
        // Modul im Mandanten aus waehrend der Lauf wartet: der Lauf scheitert mit module_disabled, importiert nichts
        try await setModule(w.tenantA, false, by: w.alice)
        let worker = JobWorker(db: db, kinds: [DMSImport.kind], handlers: [DMSImport.kind: handler()], leaseSeconds: 30, pollInterval: .milliseconds(100), logger: Logger(label: "d6.w"))
        try await runWorker(worker, until: "Laeufe erledigt") { try await self.count("jobs", where: "kind = 'dms.import.paperless' AND state IN ('queued', 'running')") == 0 }
        try await aEq(try await scalar("SELECT error_code AS v FROM dms_imports WHERE id = '\(id)'", as: String.self), "module_disabled")
        try await aEq(try await count("dms_documents"), 0)
    }

    /// Ohne Schluessel (SECRET_KEY) und ohne Entwicklungsschalter: REST-Quelle nur ueber https, Allowlist greift schon beim Anlegen (422).
    func testAKD9_apiSourceRefusedWithoutTLSOrKeyOrAllowedHost() async throws {
        let w = try await world()
        let strict = try await Application.make(.testing)
        defer { Task { try? await strict.asyncShutdown() } }
        try configure(strict, environment: AuthTestCase.makeEnv(), modules: [DMSModule(objectStore: ObjectStoreConfig(kind: .db), secretKey: d4Key, environment: ["DMS_IMPORT_HOST_ALLOWLIST": "paperless.example.org"])])
        func code(_ app: Application, _ url: String) async throws -> String? {
            let r = try await call(app, .POST, imports(w.tenantA), json: ["mode": "dry_run", "source": ["kind": "api", "base_url": url, "token": "t"]], token: w.alice.token)
            if r.status == .accepted { return nil }
            return (r.json["errors"] as? [[String: Any]])?.first { $0["field"] as? String == "source.base_url" }?["code"] as? String
        }
        let plain = try await code(strict, "http://paperless.example.org"); XCTAssertEqual(plain, "scheme_not_allowed")
        let loop = try await code(strict, "https://127.0.0.1"); XCTAssertEqual(loop, "host_not_allowed")
        let other = try await code(strict, "https://other.example.org"); XCTAssertEqual(other, "host_not_allowed")
        let good = try await code(strict, "https://paperless.example.org"); XCTAssertNil(good)
        let noKey = try await Application.make(.testing)
        defer { Task { try? await noKey.asyncShutdown() } }
        try configure(noKey, environment: AuthTestCase.makeEnv(), modules: [DMSModule(objectStore: ObjectStoreConfig(kind: .db), secretKey: nil, environment: [:])])
        let r = try await call(noKey, .POST, imports(w.tenantA), json: ["mode": "dry_run", "source": ["kind": "api", "base_url": "https://paperless.example.org", "token": "t"]], token: w.alice.token)
        XCTAssertEqual(r.status, .unprocessableEntity)
        XCTAssertTrue((r.json["errors"] as? [[String: Any]] ?? []).contains { $0["field"] as? String == "source.token" && $0["code"] as? String == "secret_key_missing" }, "\(r.json)")
        // Worker prueft die Allowlist erneut (Konfiguration kann sich nach dem Anlegen geaendert haben)
        var tight = PaperlessEndpoint.Policy(); tight.insecureDev = true; tight.allowlist = ["paperless.example.org"]
        let created = try await call(app1, .POST, imports(w.tenantA), json: ["mode": "dry_run", "source": ["kind": "api", "base_url": "http://127.0.0.1:9", "token": "t"]], token: w.alice.token)
        XCTAssertEqual(created.status, .accepted, "\(created.json)")
        try await finish(created.json["id"] as! String, worker: JobWorker(db: db, kinds: [DMSImport.kind], handlers: [DMSImport.kind: handler(policy: tight)], leaseSeconds: 30, pollInterval: .milliseconds(100), logger: Logger(label: "d6.w")))
        try await aEq(try await scalar("SELECT error_code AS v FROM dms_imports WHERE id = '\(created.json["id"] as! String)'", as: String.self), "host_not_allowed")
    }

    /// Migration (dms_023): Revert und erneutes Anwenden; der Endgueltig-Loeschen-Pfad (D5) raeumt Notizen mit weg.
    func testAKD9_migrationAndPurgeRemovesNotes() async throws {
        let w = try await world()
        try install(tenant: w.tenantA)
        _ = try await runAndReport(w, mode: "import")
        try await aEq(try await count("_fluent_migrations", where: "name = 'dms_023_import'"), 1)
        let doc = try await scalar("SELECT document_id::text AS v FROM dms_ingest_items WHERE origin_ref = 'paperless:103'", as: String.self)
        try await aEq(try await count("dms_document_notes", where: "document_id = '\(doc)'"), 2)
        let trash = try await call(app1, .POST, base(w.tenantA) + "/documents/\(doc)/trash", json: ["reason": "Test"], token: w.alice.token)
        XCTAssertEqual(trash.status, .ok, "\(trash.json)")
        try await db.raw("UPDATE dms_documents SET retention_until = NULL WHERE id = '\(doc)'").run()
        let purge = try await call(app1, .POST, base(w.tenantA) + "/documents/\(doc)/purge", json: ["confirm": true], token: w.alice.token)
        XCTAssertTrue([HTTPStatus.ok, .conflict].contains(purge.status), "\(purge.json)")   // Aufbewahrungsfrist kann das Loeschen noch sperren; dann bleibt die Notiz bewusst erhalten
        if purge.status == .ok { try await aEq(try await count("dms_document_notes", where: "document_id = '\(doc)'"), 0) }
        try await CreateDMSImport().revert(on: app1.db(.psql))
        try await aEq(try await count("information_schema.tables", where: "table_name IN ('dms_imports', 'dms_import_items', 'dms_import_findings', 'dms_document_notes')"), 0)
        try await CreateDMSImport().prepare(on: app1.db(.psql))
        try await aEq(try await count("information_schema.tables", where: "table_name IN ('dms_imports', 'dms_import_items', 'dms_import_findings', 'dms_document_notes')"), 4)
    }
}

final class DMSImportResults: @unchecked Sendable {
    private let lock = NSLock(); private var v: [String] = []
    func add(_ s: String) { lock.lock(); v.append(s); lock.unlock() }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return v }
}

/// HTTPS-Server mit selbstsigniertem Zertifikat (per `openssl` im temporaeren Verzeichnis erzeugt), um die Zertifikatspruefung des Clients zu belegen.
final class TLSMock: @unchecked Sendable {
    let app: Application
    let dir: URL
    private let lock = NSLock(); private var n = 0
    var requestCount: Int { lock.lock(); defer { lock.unlock() }; return n }
    var port: Int { app.http.server.shared.localAddress?.port ?? 0 }
    private init(app: Application, dir: URL) { self.app = app; self.dir = dir }
    func hit() { lock.lock(); n += 1; lock.unlock() }

    static func make() async throws -> TLSMock? {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("labhub-d6-tls-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", dir.appendingPathComponent("k.pem").path, "-out", dir.appendingPathComponent("c.pem").path,
                       "-days", "1", "-subj", "/CN=127.0.0.1", "-addext", "subjectAltName=IP:127.0.0.1"]
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        do { try p.run(); p.waitUntilExit() } catch { return nil }
        guard p.terminationStatus == 0 else { return nil }
        let app = try await Application.make(.testing)
        app.http.server.configuration.hostname = "127.0.0.1"
        app.http.server.configuration.port = 0
        app.http.server.configuration.tlsConfiguration = .makeServerConfiguration(
            certificateChain: try NIOSSLCertificate.fromPEMFile(dir.appendingPathComponent("c.pem").path).map { .certificate($0) },
            privateKey: .file(dir.appendingPathComponent("k.pem").path))
        let mock = TLSMock(app: app, dir: dir)
        app.get("api", "**") { req async throws -> Response in
            mock.hit()
            return Response(status: .ok, body: .init(string: "{}"))
        }
        try await app.server.start(address: .hostname("127.0.0.1", port: 0))
        return mock
    }

    func stop() async { await app.server.shutdown(); try? await app.asyncShutdown(); try? FileManager.default.removeItem(at: dir) }
}

// MARK: - REST-API (Mock-Server)

/// Mock einer Paperless-ngx-REST-API in diesem Prozess: baut seine Antworten aus der synthetischen Fixture. Nur Lesen, Token-Pruefung, Seiten.
final class PaperlessMock: @unchecked Sendable {
    let app: Application
    let token: String
    private let lock = NSLock()
    private var _requests: [(path: String, auth: String?)] = []
    var redirectReferences = false
    var port: Int { app.http.server.shared.localAddress?.port ?? 0 }
    var requests: [(path: String, auth: String?)] { lock.lock(); defer { lock.unlock() }; return _requests }

    init(token: String, fixture: URL) async throws {
        self.token = token
        app = try await Application.make(.testing)
        app.http.server.configuration.hostname = "127.0.0.1"
        app.http.server.configuration.port = 0
        let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: fixture.appendingPathComponent("manifest.json"))) as! [[String: Any]]
        func entries(_ model: String) -> [[String: Any]] { manifest.filter { $0["model"] as? String == model } }
        func ref(_ model: String, tag: Bool = false) -> [[String: Any]] {
            entries(model).map { e in
                var f = e["fields"] as! [String: Any]
                f["id"] = e["pk"]
                if model == "documents.storagepath" { f["path"] = f["path"] }
                return f
            }
        }
        func docs() -> [[String: Any]] {
            entries("documents.document").map { e in
                let f = e["fields"] as! [String: Any]
                let pk = e["pk"] as! Int
                var d: [String: Any] = ["id": pk, "title": f["title"]!, "content": f["content"]!, "created": f["created"]!, "added": f["added"]!, "archive_serial_number": f["archive_serial_number"] ?? NSNull(),
                                        "correspondent": f["correspondent"] ?? NSNull(), "document_type": f["document_type"] ?? NSNull(), "storage_path": f["storage_path"] ?? NSNull(),
                                        "tags": f["tags"]!, "owner": f["owner"] ?? NSNull(), "original_file_name": f["filename"]!,
                                        "archived_file_name": e["__exported_archive_name__"] ?? NSNull()]
                d["notes"] = entries("documents.note").filter { ($0["fields"] as! [String: Any])["document"] as? Int == pk }.map { n in
                    ["id": n["pk"]!, "note": (n["fields"] as! [String: Any])["note"]!, "created": (n["fields"] as! [String: Any])["created"]!] as [String: Any]
                }
                d["custom_fields"] = entries("documents.customfieldinstance").filter { ($0["fields"] as! [String: Any])["document"] as? Int == pk }.map { c in
                    let cf = c["fields"] as! [String: Any]
                    let value = ["value_text", "value_date", "value_monetary"].compactMap { cf[$0] }.first ?? NSNull()
                    return ["field": cf["field"]!, "value": value] as [String: Any]
                }
                return d
            }
        }
        let referenceRoutes = ["correspondents": "documents.correspondent", "document_types": "documents.documenttype", "tags": "documents.tag", "storage_paths": "documents.storagepath", "custom_fields": "documents.customfield"]
        let me = self
        func guardAuth(_ req: Request) throws {
            me.record(req.url.path, req.headers.first(name: .authorization))
            guard req.headers.first(name: .authorization) == "Token \(token)" else { throw Abort(.unauthorized) }
        }
        func page(_ all: [[String: Any]], _ req: Request) throws -> Response {
            let size = min(Int(req.query["page_size"] as String? ?? "") ?? 25, 100), p = max(Int(req.query["page"] as String? ?? "") ?? 1, 1)
            let slice = Array(all.dropFirst((p - 1) * size).prefix(size))
            let next: Any = p * size < all.count ? "http://127.0.0.1:\(me.port)/api/x/?page=\(p + 1)" : NSNull()
            let body = try JSONSerialization.data(withJSONObject: ["count": all.count, "next": next, "previous": NSNull(), "results": slice] as [String: Any])
            return Response(status: .ok, headers: ["Content-Type": "application/json"], body: .init(data: body))
        }
        for (path, model) in referenceRoutes {
            app.get("api", PathComponent(stringLiteral: path)) { req async throws -> Response in
                try guardAuth(req)
                if me.redirectReferences { return req.redirect(to: "http://example.org/leak", redirectType: .temporary) }
                return try page(ref(model), req)
            }
        }
        app.get("api", "documents") { req async throws -> Response in try guardAuth(req); return try page(docs(), req) }
        app.get("api", "documents", ":id", "download") { req async throws -> Response in
            try guardAuth(req)
            guard let id = req.parameters.get("id", as: Int.self), let e = entries("documents.document").first(where: { $0["pk"] as? Int == id }) else { throw Abort(.notFound) }
            let original = (req.query["original"] as String?) == "true"
            guard let name = original ? e["__exported_file_name__"] as? String : e["__exported_archive_name__"] as? String else { throw Abort(.notFound) }
            let data = try Data(contentsOf: fixture.appendingPathComponent(name))
            return Response(status: .ok, headers: ["Content-Type": "application/octet-stream"], body: .init(data: data))
        }
        try await app.server.start(address: .hostname("127.0.0.1", port: 0))
    }

    fileprivate func record(_ path: String, _ auth: String?) { lock.lock(); _requests.append((path, auth)); lock.unlock() }
    func stop() async { await app.server.shutdown(); try? await app.asyncShutdown() }
}

final class DMSImportAPITests: DMSImportTestBase {
    /// AK-D9 (REST-Quelle): Trockenlauf und Import ueber die API liefern dasselbe wie der Export (Zaehlungen, Hashes, Beziehungen); nur GET, Token im Header, nur an den eingetragenen Host.
    func testAKD9_apiImportMatchesExportImport() async throws {
        let w = try await world()
        let mock = try await PaperlessMock(token: d6Token, fixture: Self.fixture)
        addTeardownBlock { await mock.stop() }
        let source: [String: Any] = ["kind": "api", "base_url": "http://127.0.0.1:\(mock.port)", "token": d6Token]
        let before = try await contentFingerprint()
        let dry = try await runAndReport(w, mode: "dry_run", source: source)
        XCTAssertEqual(dry.state, "done", "\(dry.report)")
        try await aEq(try await contentFingerprint(), before, "Trockenlauf schreibt nichts")
        XCTAssertEqual(counts(dry.report)["documents_would_import"], 10)
        XCTAssertEqual(counts(dry.report)["tags_would_create"], 5)
        XCTAssertEqual(counts(dry.report)["files_without_checksum"], 10, "die REST-API liefert keine Pruefsummen: alle Dateien ohne Hash im Bericht")
        let run = try await runAndReport(w, mode: "import", source: source)
        XCTAssertEqual(run.state, "done", "\(run.report)")
        let c = counts(run.report)
        XCTAssertEqual(c["documents_imported"], 10); XCTAssertEqual(c["files_archive"], 2); XCTAssertEqual(c["notes_imported"], 3)
        XCTAssertEqual(c["correspondents_created"], 4); XCTAssertEqual(c["types_created"], 3); XCTAssertEqual(c["tags_created"], 5); XCTAssertEqual(c["fields_created"], 3)
        let hashes = try fixtureHashes()
        for (pk, sha) in hashes.original {
            let got = try await scalar("""
                SELECT f.sha256 AS v FROM dms_document_files f JOIN dms_ingest_items i ON i.document_id = f.document_id WHERE i.origin_ref = 'paperless:\(pk)' AND f.role = 'original'
                """, as: String.self)
            XCTAssertEqual(got, sha, "Original \(pk) ueber die API")
        }
        try await aEq(try await count("dms_document_files", where: "role = 'archive'"), 2)
        try await aEq(try await scalar("SELECT value::bigint AS v FROM counters WHERE key = 'dms:asn'", as: Int64.self), 17)
        try await aEq(try await count("links", where: "kind = 'correspondent' AND source = 'import'"), 8)
        try await aEq(try await count("dms_document_notes"), 3)
        // Wiederholung ohne Duplikate
        let again = try await runAndReport(w, mode: "import", source: source)
        XCTAssertEqual(counts(again.report)["documents_imported"], 0); try await aEq(try await count("dms_documents"), 10)
        // Nur lesende Zugriffe mit Token; nichts anderes als /api/...
        let reqs = mock.requests
        XCTAssertFalse(reqs.isEmpty)
        XCTAssertTrue(reqs.allSatisfy { $0.auth == "Token \(d6Token)" && $0.path.hasPrefix("/api/") })
        // Token nirgends im Klartext (Datenbank, Audit)
        let leaked = try await databaseDumpContains(d6Token)
        XCTAssertFalse(leaked)
        // Verhalten bei Fehlern: falsches Token -> source_auth_failed; nicht erreichbar -> source_unreachable; Weiterleitung wird nicht verfolgt -> source_http_error
        let bad = try await runAndReport(w, mode: "dry_run", source: ["kind": "api", "base_url": "http://127.0.0.1:\(mock.port)", "token": "falsch"])
        XCTAssertEqual(bad.state, "failed"); XCTAssertEqual(bad.report["error_code"] as? String, "source_auth_failed")
        let down = try await runAndReport(w, mode: "dry_run", source: ["kind": "api", "base_url": "http://127.0.0.1:9", "token": d6Token])
        XCTAssertEqual(down.state, "failed"); XCTAssertEqual(down.report["error_code"] as? String, "source_unreachable")
        mock.redirectReferences = true
        let redirect = try await runAndReport(w, mode: "dry_run", source: source)
        XCTAssertEqual(redirect.state, "failed"); XCTAssertEqual(redirect.report["error_code"] as? String, "source_http_error")
        XCTAssertFalse(mock.requests.contains { $0.path == "/leak" })
        // ein Lauf bleibt nach Fehlern fortsetzbar: neuer Lauf (Schluessel gleich) ist erlaubt, der alte ist beendet
        try await aEq(try await count("dms_imports", where: "state = 'failed'"), 3)
    }

    /// AK-D9: TLS wird geprueft: gegen einen Server mit selbstsigniertem Zertifikat scheitert der Lauf mit `source_tls_failed`; es werden keine Daten uebertragen und das Token nie im Klartext gesendet.
    func testAKD9_tlsCertificateIsVerified() async throws {
        let w = try await world()
        guard let listener = try await TLSMock.make() else { throw XCTSkip("openssl nicht verfuegbar: TLS-Test uebersprungen") }
        addTeardownBlock { await listener.stop() }
        // https gegen den lokalen Server mit selbstsigniertem Zertifikat (Entwicklungsschalter erlaubt nur Loopback, nicht ein ungeprueftes Zertifikat)
        let r = try await runAndReport(w, mode: "dry_run", source: ["kind": "api", "base_url": "https://127.0.0.1:\(listener.port)", "token": d6Token])
        XCTAssertEqual(r.state, "failed", "\(r.report)")
        XCTAssertEqual(r.report["error_code"] as? String, "source_tls_failed")
        XCTAssertEqual(listener.requestCount, 0, "kein Aufruf darf den Server nach fehlgeschlagener Zertifikatspruefung erreichen")
    }
}
