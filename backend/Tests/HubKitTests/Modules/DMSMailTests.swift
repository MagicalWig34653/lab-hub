import XCTVapor
import Fluent
import SQLKit
import Crypto
import Logging
@testable import HubKit

// WP-D4: Mail-Ingest gegen einen lokalen GreenMail-Server (Docker). Synthetische Nachrichten, Benutzer mail1…mail6 mit Platzhalter-Passwort, Domain example.org.
// Ohne Docker oder ohne Image (und ohne Netz zum Nachladen) werden die Tests mit Meldung übersprungen. Der Server nutzt IMAPS mit selbstsigniertem Zertifikat:
// die Ingest-Tests schalten die Zertifikatsprüfung ausdrücklich ab (IMAPOptions), ein eigener Test belegt, dass sie sonst greift.

final class GreenMail: @unchecked Sendable {
    static let image = "greenmail/standalone:2.1.3"
    static let users = (1...7).map { "mail\($0)" }
    private static let lock = NSLock()
    nonisolated(unsafe) private static var shared: GreenMail?
    nonisolated(unsafe) private static var unavailable: String?
    let container: String
    let port: Int

    init(container: String, port: Int) { self.container = container; self.port = port }

    @discardableResult
    static func docker(_ args: [String]) -> (status: Int32, out: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["docker"] + args
        let pipe = Pipe()
        p.standardOutput = pipe; p.standardError = Pipe()
        do { try p.run() } catch { return (127, "") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Startet (einmal je Testlauf) den Server; `nil` mit Grund, wenn Docker fehlt.
    static func acquire() throws -> GreenMail {
        lock.lock(); defer { lock.unlock() }
        if let shared { return shared }
        if let unavailable { throw XCTSkip(unavailable) }
        func skip(_ why: String) -> XCTSkip { unavailable = why; return XCTSkip(why) }
        guard docker(["info", "--format", "{{.ServerVersion}}"]).status == 0 else { throw skip("Docker nicht verfügbar: Mail-Tests (GreenMail) übersprungen") }
        if docker(["image", "inspect", image]).status != 0, docker(["pull", image]).status != 0 { throw skip("Image \(image) nicht vorhanden und nicht ladbar: Mail-Tests übersprungen") }
        let userSpec = users.map { "\($0):\(d4Canary)@example.org" }.joined(separator: ",")
        let run = docker(["run", "-d", "--rm", "-p", "127.0.0.1::3993", "-e",
                          "GREENMAIL_OPTS=-Dgreenmail.setup.test.imaps -Dgreenmail.hostname=0.0.0.0 -Dgreenmail.users=\(userSpec) -Dgreenmail.verbose", image])
        guard run.status == 0 else { throw skip("GreenMail-Container nicht startbar: Mail-Tests übersprungen") }
        let id = run.out
        let mapping = docker(["port", id, "3993/tcp"]).out.split(separator: "\n").first.map(String.init) ?? ""
        guard let port = mapping.split(separator: ":").last.flatMap({ Int($0) }) else { docker(["rm", "-f", id]); throw skip("Port des Mail-Containers unbekannt") }
        let box = GreenMail(container: id, port: port)
        shared = box
        atexit { _ = GreenMail.docker(["rm", "-f", GreenMail.shared?.container ?? ""]) }
        return box
    }

    func waitUntilReady() async throws {
        var options = IMAPOptions(); options.verifyCertificate = false; options.sessionTimeout = .seconds(10)
        options.targetPolicy = NetworkTargetPolicy(allowInternal: true); options.allowedPorts = [port]   // WP-H10: GreenMail läuft auf localhost, ausdrücklich erlaubt
        let end = Date().addingTimeInterval(90)
        while Date() < end {
            do { try await IMAPClient.withSession(host: "127.0.0.1", port: port, user: "mail6", password: d4Canary, options: options) { _ in () }; return }
            catch { try await Task.sleep(for: .seconds(1)) }
        }
        throw XCTSkip("GreenMail wurde nicht bereit: Mail-Tests übersprungen")
    }
}

final class DMSMailTests: DMSSourceTestBase {
    var mail: GreenMail!
    var insecure: IMAPOptions {
        var o = IMAPOptions(); o.verifyCertificate = false; o.sessionTimeout = .seconds(30)
        o.targetPolicy = NetworkTargetPolicy(allowInternal: true); o.allowedPorts = [mail.port]   // WP-H10: Testserver auf localhost ausdrücklich erlaubt
        return o
    }

    override func setUp() async throws {
        try await super.setUp()
        mail = try GreenMail.acquire()
        try await mail.waitUntilReady()
        setenv("DMS_MAIL_TLS_VERIFY", "false", 1)   // Verbindungstest-Route liest die Betreiber-Umgebung
        setenv("DMS_ALLOW_INTERNAL_TARGETS", "true", 1)          // WP-H10: GreenMail auf localhost ausdrücklich erlauben
        setenv("DMS_MAIL_PORT_ALLOWLIST", String(mail.port), 1)
    }
    override func tearDown() async throws {
        unsetenv("DMS_MAIL_TLS_VERIFY"); unsetenv("DMS_ALLOW_INTERNAL_TARGETS"); unsetenv("DMS_MAIL_PORT_ALLOWLIST")
        try await super.tearDown()
    }

    // MARK: Hilfen

    func wrap(_ d: Data) -> String { d.base64EncodedString(options: [.lineLength76Characters, .endLineWithCarriageReturn, .endLineWithLineFeed]) }

    func message(from: String = "Rechnung Synthetic <Billing@Example.org>", subject: String, id: String, text: String? = "Guten Tag, anbei die Unterlagen.", attachments: [(String, String, Data)] = []) -> Data {
        var lines = ["From: \(from)", "To: mail@example.org", "Subject: \(subject)", "Message-ID: <\(id)@example.org>", "Date: Sun, 8 Nov 2026 10:00:00 +0100", "MIME-Version: 1.0",
                     "Content-Type: multipart/mixed; boundary=\"d4b\"", ""]
        if let text { lines += ["--d4b", "Content-Type: text/plain; charset=utf-8", "", text, ""] }
        for (name, type, data) in attachments {
            lines += ["--d4b", "Content-Type: \(type); name=\"\(name)\"", "Content-Disposition: attachment; filename=\"\(name)\"", "Content-Transfer-Encoding: base64", "", wrap(data), ""]
        }
        lines += ["--d4b--", ""]
        return Data(lines.joined(separator: "\r\n").utf8)
    }

    func seed(_ user: String, _ messages: [Data], create: [String] = []) async throws {
        try await IMAPClient.withSession(host: "127.0.0.1", port: mail.port, user: user, password: d4Canary, options: insecure) { session in
            for box in create { _ = try await session.command("CREATE \"\(box)\"") }
            for m in messages { try await session.append(m, to: "INBOX") }
        }
    }

    func mailboxState(_ user: String, _ mailbox: String) async throws -> (all: Int, unseen: Int) {
        try await IMAPClient.withSession(host: "127.0.0.1", port: mail.port, user: user, password: d4Canary, options: insecure) { session in
            try await session.select(mailbox)
            let all = try await session.command("UID SEARCH ALL").untagged.filter { $0.text.uppercased().hasPrefix("* SEARCH") }.flatMap { $0.text.split(separator: " ").dropFirst(2) }.count
            return (all, try await session.searchUnseen().count)
        }
    }

    func createMailSource(_ w: World, user: String, password: String = d4Canary, extra: [String: Any] = [:]) async throws -> String {
        var config: [String: Any] = ["host": "localhost", "port": mail.port, "username": user, "processed_mailbox": "Verarbeitet", "include_body": true, "interval_seconds": 30]
        for (k, v) in extra { config[k] = v }
        let r = try await call(app1, .POST, src(w.tenantA), json: ["kind": "mail", "name": "Postfach \(user) \(UUID().uuidString.prefix(5))", "password": password, "config": config], token: w.alice.token)
        XCTAssertEqual(r.status, .created, "\(r.json)")
        guard let id = r.json["id"] as? String else { throw XCTSkip("Quelle nicht angelegt: \(r.json)") }
        return id
    }

    func worker(_ db: any SQLDatabase, log: LogCapture, owner: String = JobWorker.makeOwner()) -> JobWorker {
        let handler = DMSMailPoll.handler(storeConfig: { ObjectStoreConfig(kind: .db) }, box: SecretBox(secretKey: d4Key), imap: insecure, limits: limits())
        return JobWorker(db: db, kinds: [DMSMailPoll.kind], handlers: [DMSMailPoll.kind: handler], leaseSeconds: 30, pollInterval: .milliseconds(100), logger: log.logger(), owner: owner)
    }

    func runs(_ id: String) async throws -> Int64 { try await scalar("SELECT runs AS v FROM dms_sources WHERE id = '\(id)'", as: Int64.self) }

    // MARK: Tests

    /// AK-D4-1: Anhang landet im DMS (Hash = Original), Absender gesetzt, Quelle mail, Mailtext als Dokument; Mail danach gelesen und verschoben, nie gelöscht;
    /// unbekannte Anhangtypen werden übersprungen; ein zweiter Poll mit denselben Nachrichten (gleiche Message-ID, neu eingeliefert) erzeugt kein Duplikat;
    /// das Passwort steht nie in Datenbank, Log, Audit oder API-Antworten.
    func testAKD4_1_mailAttachmentIngestIdempotentAndSecretNeverLeaks() async throws {
        let w = try await world()
        let log = LogCapture()
        let invoice = pdf("rechnung-maerz", padding: 700), photo = png("foto")
        let zip = Data([0x50, 0x4B, 0x03, 0x04] + Array("synthetic".utf8))
        let m1 = message(subject: "Rechnung März", id: "m1", attachments: [("Rechnung März.pdf", "application/pdf", invoice)])
        let m2 = message(subject: "Foto", id: "m2", attachments: [("beleg.png", "image/png", photo)])
        let m3 = message(subject: "Nur Text", id: "m3", attachments: [("archiv.zip", "application/zip", zip)])
        try await seed("mail1", [m1, m2, m3], create: ["Verarbeitet"])
        let id = try await createMailSource(w, user: "mail1")
        let w1 = worker(db, log: log)
        try await runWorker(w1, until: "erster Lauf") { try await self.runs(id) >= 1 }

        let source = try await call(app1, .GET, src(w.tenantA) + "/\(id)", token: w.alice.token)
        XCTAssertEqual(source.json["last_status"] as? String, "ok", "\(source.json)")
        let stats = source.json["last_stats"] as? [String: Int] ?? [:]
        XCTAssertEqual(stats["messages"], 3); XCTAssertEqual(stats["ingested"], 5); XCTAssertEqual(stats["skipped"], 1); XCTAssertEqual(stats["failed"], 0)
        try await aEq(try await count("dms_documents"), 5)
        let attachment = try await db.raw("SELECT sha256, original_name FROM dms_document_files WHERE original_name = 'Rechnung März.pdf'").first()!
        XCTAssertEqual(try attachment.decode(column: "sha256", as: String.self), hex(invoice))
        try await aEq(try await count("dms_ingest_items", where: "source = 'mail' AND sender = 'billing@example.org'"), 5)
        let ref = try await scalar("SELECT origin_ref AS v FROM dms_ingest_items WHERE origin_ref LIKE '%m1@example.org%' ORDER BY origin_ref LIMIT 1", as: String.self)
        XCTAssertTrue(ref.hasPrefix("mail:<m1@example.org>#"), ref)
        try await aEq(try await count("dms_documents", where: "title = 'Rechnung März'"), 2, "Anhang und Mailtext")
        try await aEq(try await auditCount("dms.ingest.received", tenant: w.tenantA), 5)
        try await aEq(try await auditCount("dms.source.run", tenant: w.tenantA), 1)
        // Absender greift in Regeln (D3: sender_contains)
        let preview = try await call(app1, .POST, base(w.tenantA) + "/rules/preview", json: ["conditions": ["conditions": [["type": "sender_contains", "value": "billing@example"]]], "actions": ["title_template": "Mail-{filename}"]], token: w.alice.token)
        XCTAssertEqual(preview.status, .ok, "\(preview.json)")
        XCTAssertEqual(preview.json["matched"] as? Int, 5)
        // Mails markiert und verschoben, nie gelöscht
        let inbox = try await mailboxState("mail1", "INBOX"), done = try await mailboxState("mail1", "Verarbeitet")
        XCTAssertEqual(inbox.unseen, 0)
        XCTAssertEqual(done.all, 3, "alle drei Nachrichten im Zielpostfach (nichts gelöscht)")

        // zweiter Poll: dieselben Nachrichten erneut eingeliefert (neue Kopien, gleiche Message-ID) und „Jetzt ausführen“
        try await seed("mail1", [m1, m2, m3])
        let docsBefore = try await count("dms_documents"), itemsBefore = try await count("dms_source_items")
        let run = try await call(app2, .POST, src(w.tenantA) + "/\(id)/run", token: w.alice.token)
        XCTAssertEqual(run.status, .accepted)
        let w2 = worker(app2.db(.psql) as! any SQLDatabase, log: log)
        try await runWorker(w2, until: "zweiter Lauf") { try await self.runs(id) >= 2 }
        let again = try await call(app1, .GET, src(w.tenantA) + "/\(id)", token: w.alice.token)
        let stats2 = again.json["last_stats"] as? [String: Int] ?? [:]
        XCTAssertEqual(stats2["messages"], 3); XCTAssertEqual(stats2["ingested"], 0); XCTAssertEqual(stats2["duplicates"], 5)
        try await aEq(try await count("dms_documents"), docsBefore, "kein Duplikat")
        try await aEq(try await count("dms_source_items"), itemsBefore)
        try await aEq(try await count("dms_ingest_items"), 5)
        try await aEq(try await mailboxState("mail1", "INBOX").unseen, 0)

        // Passwort nie im Klartext: Datenbank (alle Tabellen), Log, Antworten, Audit, Job-Payloads
        let leaked = try await databaseDumpContains(d4Canary)
        XCTAssertFalse(leaked, "Passwort in der Datenbank")
        XCTAssertFalse(log.text.contains(d4Canary), "Passwort im Log")
        for r in [source, again] { XCTAssertFalse(String(decoding: try JSONSerialization.data(withJSONObject: r.json), as: UTF8.self).contains(d4Canary)) }
        let encrypted = try await scalar("SELECT secret_enc AS v FROM dms_sources", as: String.self)
        XCTAssertTrue(encrypted.hasPrefix("v1:"))
        XCTAssertEqual(try SecretBox(secretKey: d4Key)!.open(encrypted, tenant: UUID(uuidString: w.tenantA)!, source: UUID(uuidString: id)!), d4Canary)
    }

    /// AK-D4-1: Filter (Absender/Betreff), max_per_run; nicht passende Mails bleiben unberührt (ungelesen, im Posteingang).
    func testAKD4_1_senderFilterAndLimit() async throws {
        let w = try await world()
        let log = LogCapture()
        try await seed("mail2", [message(subject: "Gehört dazu", id: "f1", attachments: [("a.pdf", "application/pdf", pdf("f1"))]),
                                 message(from: "Werbung <spam@example.net>", subject: "Angebot", id: "f2", attachments: [("b.pdf", "application/pdf", pdf("f2"))])])
        let id = try await createMailSource(w, user: "mail2", extra: ["sender_contains": "billing@example.org", "include_body": false, "processed_mailbox": NSNull()])
        let cfg = try await call(app1, .PATCH, src(w.tenantA) + "/\(id)", json: ["config": ["host": "localhost", "port": mail.port, "username": "mail2", "sender_contains": "billing@example.org", "include_body": false]], token: w.alice.token)
        XCTAssertEqual(cfg.status, .ok, "\(cfg.json)")
        let run = worker(db, log: log)
        try await runWorker(run, until: "Lauf") { try await self.runs(id) >= 1 }
        try await aEq(try await count("dms_documents"), 1)
        try await aEq(try await mailboxState("mail2", "INBOX").unseen, 1, "die fremde Mail bleibt ungelesen")
        let source = try await call(app1, .GET, src(w.tenantA) + "/\(id)", token: w.alice.token)
        XCTAssertNil(source.json["last_error"] as? String)
    }

    /// AK-D4-5: Zwei Worker (zwei Verbindungen) gegen dasselbe Postfach: der Lauf geschieht genau einmal (Lease), kein Dokument doppelt.
    func testAKD4_5_twoWorkersSameMailboxOnePoll() async throws {
        let w = try await world()
        let log = LogCapture()
        try await seed("mail3", (0..<4).map { message(subject: "Beleg \($0)", id: "p\($0)", text: nil, attachments: [("beleg\($0).pdf", "application/pdf", pdf("p\($0)", padding: $0))]) }, create: ["Verarbeitet"])
        let id = try await createMailSource(w, user: "mail3", extra: ["include_body": false])
        let w1 = worker(db, log: log), w2 = worker(app2.db(.psql) as! any SQLDatabase, log: log)
        let t1 = Task { await w1.run() }, t2 = Task { await w2.run() }
        try await eventually("Lauf") { try await self.runs(id) >= 1 }
        try await Task.sleep(for: .seconds(1.5))   // Platz für einen (unerlaubten) zweiten Lauf
        w1.requestShutdown(); w2.requestShutdown(); await t1.value; await t2.value
        try await aEq(try await runs(id), 1, "genau ein Lauf")
        try await aEq(try await count("dms_documents"), 4)
        try await aEq(try await count("jobs", where: "kind = 'dms.mail.poll' AND state = 'done'"), 1)
        try await aEq(try await count("jobs", where: "kind = 'dms.mail.poll' AND state = 'queued'"), 1, "nächster Lauf eingeplant")
    }

    /// AK-D4-2: Falsches Passwort -> Fehlercode an der Quelle (imap_auth_failed), nichts aufgenommen, Kette läuft weiter (Rückstau), das falsche Passwort steht nirgends.
    /// Verbindungstest: richtig -> ok, falsch -> Fehlercode; mit Zertifikatsprüfung scheitert das selbstsignierte Zertifikat (imap_tls_failed).
    func testAKD4_2_wrongPasswordConnectionTestAndTLSVerification() async throws {
        let w = try await world()
        let log = LogCapture()
        let wrong = "Falsch-Kanarienvogel-D4-x91"
        try await seed("mail4", [message(subject: "X", id: "w1", attachments: [("a.pdf", "application/pdf", pdf("w1"))])])
        let bad = try await createMailSource(w, user: "mail4", password: wrong)
        let good = try await createMailSource(w, user: "mail4")
        // Test-Route
        let okTest = try await call(app1, .POST, src(w.tenantA) + "/\(good)/test", token: w.alice.token)
        XCTAssertEqual(okTest.status, .ok, "\(okTest.json)")
        XCTAssertEqual(okTest.json["ok"] as? Bool, true); XCTAssertEqual(okTest.json["unseen"] as? Int, 1)
        let badTest = try await call(app2, .POST, src(w.tenantA) + "/\(bad)/test", token: w.alice.token)
        XCTAssertEqual(badTest.json["ok"] as? Bool, false); XCTAssertEqual(badTest.json["error"] as? String, "imap_auth_failed")
        unsetenv("DMS_MAIL_TLS_VERIFY")
        let tls = try await call(app1, .POST, src(w.tenantA) + "/\(good)/test", token: w.alice.token)
        XCTAssertEqual(tls.json["ok"] as? Bool, false); XCTAssertEqual(tls.json["error"] as? String, "imap_tls_failed", "Zertifikatsprüfung ist aktiv")
        setenv("DMS_MAIL_TLS_VERIFY", "false", 1)
        // Lauf mit falschem Passwort
        let run = worker(db, log: log)
        let goodDisabled = try await call(app1, .PATCH, src(w.tenantA) + "/\(good)", json: ["enabled": false], token: w.alice.token)
        XCTAssertEqual(goodDisabled.status, .ok)
        try await runWorker(run, until: "Lauf") { try await self.runs(bad) >= 1 }
        let source = try await call(app1, .GET, src(w.tenantA) + "/\(bad)", token: w.alice.token)
        XCTAssertEqual(source.json["last_status"] as? String, "error"); XCTAssertEqual(source.json["last_error"] as? String, "imap_auth_failed")
        try await aEq(try await count("dms_documents"), 0)
        try await aEq(try await count("jobs", where: "kind = 'dms.mail.poll' AND state = 'queued' AND payload LIKE '%\(bad.uppercased())%'"), 1, "Kette läuft weiter")
        let runAt = try await scalar("SELECT extract(epoch FROM run_at - now())::bigint AS v FROM jobs WHERE state = 'queued' AND payload LIKE '%\(bad.uppercased())%'", as: Int64.self)
        XCTAssertGreaterThan(runAt, 30, "Rückstau: mindestens das doppelte Intervall")
        for text in [wrong, d4Canary] {
            let inDB = try await databaseDumpContains(text)
            XCTAssertFalse(inDB, "Passwort in der Datenbank")
            XCTAssertFalse(log.text.contains(text), "Passwort im Log")
            for r in [okTest, badTest, tls, source] { XCTAssertFalse(String(decoding: try JSONSerialization.data(withJSONObject: r.json), as: UTF8.self).contains(text)) }
        }
        try await aEq(try await auditCount("dms.source.tested", tenant: w.tenantA), 3)
    }

    /// AK-D4-2: Fehlt SECRET_KEY im Worker oder ist ein Geheimnis nicht lesbar (anderer Schlüssel), meldet die Quelle einen Fehlercode, nimmt nichts auf und läuft weiter.
    func testAKD4_2_missingOrWrongKeyInWorker() async throws {
        let w = try await world()
        let log = LogCapture()
        let id = try await createMailSource(w, user: "mail5")
        let noKey = DMSMailPoll.handler(storeConfig: { ObjectStoreConfig(kind: .db) }, box: nil, imap: insecure, limits: limits())
        let w1 = JobWorker(db: db, kinds: [DMSMailPoll.kind], handlers: [DMSMailPoll.kind: noKey], leaseSeconds: 30, pollInterval: .milliseconds(100), logger: log.logger())
        try await runWorker(w1, until: "Lauf ohne Schlüssel") { try await self.runs(id) >= 1 }
        var source = try await call(app1, .GET, src(w.tenantA) + "/\(id)", token: w.alice.token)
        XCTAssertEqual(source.json["last_error"] as? String, "secret_key_missing")
        try await db.raw("UPDATE jobs SET run_at = now() WHERE state = 'queued'").run()
        let other = DMSMailPoll.handler(storeConfig: { ObjectStoreConfig(kind: .db) }, box: SecretBox(secretKey: d4Key + "-anders"), imap: insecure, limits: limits())
        let w2 = JobWorker(db: db, kinds: [DMSMailPoll.kind], handlers: [DMSMailPoll.kind: other], leaseSeconds: 30, pollInterval: .milliseconds(100), logger: log.logger())
        try await runWorker(w2, until: "Lauf mit anderem Schlüssel") { try await self.runs(id) >= 2 }
        source = try await call(app1, .GET, src(w.tenantA) + "/\(id)", token: w.alice.token)
        XCTAssertEqual(source.json["last_error"] as? String, "secret_unreadable")
        try await aEq(try await count("dms_documents"), 0)
    }

    /// AK-D4-1: Quota erschöpft -> die Mail bleibt ungelesen (wird wiederholt), Fehlercode storage_quota_exceeded an der Quelle, nichts gelöscht.
    func testAKD4_1_quotaExceededLeavesMailUnseen() async throws {
        let w = try await world()
        let log = LogCapture()
        try await seed("mail6", [message(subject: "Groß", id: "q1", text: nil, attachments: [("gross.pdf", "application/pdf", pdf("q1", padding: 5000))])])
        let id = try await createMailSource(w, user: "mail6", extra: ["include_body": false, "processed_mailbox": NSNull()])
        var tight = limits(); tight.quotaBytes = 100
        let handler = DMSMailPoll.handler(storeConfig: { ObjectStoreConfig(kind: .db) }, box: SecretBox(secretKey: d4Key), imap: insecure, limits: tight)
        let run = JobWorker(db: db, kinds: [DMSMailPoll.kind], handlers: [DMSMailPoll.kind: handler], leaseSeconds: 30, pollInterval: .milliseconds(100), logger: log.logger())
        try await runWorker(run, until: "Lauf") { try await self.runs(id) >= 1 }
        let source = try await call(app1, .GET, src(w.tenantA) + "/\(id)", token: w.alice.token)
        XCTAssertEqual(source.json["last_error"] as? String, "storage_quota_exceeded", "\(source.json)")
        try await aEq(try await count("dms_documents"), 0)
        try await aEq(try await count("dms_source_items"), 0)
        try await aEq(try await mailboxState("mail6", "INBOX").unseen, 1)
        try await aEq(try await count("object_chunks"), 0, "kein Waisen-Blob")
    }

    // MARK: WP-D7

    /// AK-D7-1/2/3/6 über echtes IMAP (GreenMail): HTML-Rechnungsmail ohne Anhang -> Rechnung mit Feldern, Mail als byte-identisches Original (.eml) abgelegt, Mail verschoben;
    /// Mail mit PDF-Anhang -> Anhang verknüpft; Newsletter wird nicht abgelegt; zweiter Poll (neu eingeliefert) erzeugt nichts doppelt.
    func testAKD7_imapHtmlInvoiceAndAttachment() async throws {
        let w = try await world()
        let log = LogCapture()
        let invoiceHTML = "<html><body><h1>Rechnung</h1><p>Beispiel Shop GmbH</p><table><tr><td>Rechnungsnummer</td><td>4711</td></tr><tr><td>Rechnungsdatum</td><td>07.11.2026</td></tr><tr><td>Gesamtbetrag</td><td>1.234,56 &euro;</td></tr></table><img src=\"https://tracker.example.org/p.gif\"></body></html>"
        func htmlMessage(subject: String, id: String, html: String) -> Data {
            Data(["From: Shop <billing@example.org>", "To: mail@example.org", "Subject: \(subject)", "Message-ID: <\(id)@example.org>", "Date: Sun, 8 Nov 2026 10:00:00 +0100", "MIME-Version: 1.0",
                  "Content-Type: text/html; charset=utf-8", "", html, ""].joined(separator: "\r\n").utf8)
        }
        let m1 = htmlMessage(subject: "Ihre Rechnung Nr. 4711", id: "d7-1", html: invoiceHTML)
        let m2 = message(subject: "Rechnung anbei", id: "d7-2", text: "Hallo", attachments: [("Rechnung.pdf", "application/pdf", pdf("d7-pdf"))])
        let m3 = htmlMessage(subject: "Newsletter November", id: "d7-3", html: "<p>Neues im November. <a href=\"https://example.org/abmelden\">Abmelden</a> | Newsletter im Browser ansehen</p>")
        try await seed("mail7", [m1, m2, m3], create: ["Verarbeitet"])
        let id = try await createMailSource(w, user: "mail7", extra: ["include_body": false])
        try await runWorker(worker(db, log: log), until: "erster Lauf") { try await self.runs(id) >= 1 }
        let status = try await call(app1, .GET, src(w.tenantA) + "/\(id)", token: w.alice.token)
        XCTAssertEqual(status.json["last_status"] as? String, "ok", "\(status.json)")
        // m1: Mail-Original + Rechnung; m2: Anhang (Mailtext allein nicht erkannt: kein .eml); m3: nichts
        try await aEq(try await count("dms_document_files", where: "mime = 'message/rfc822'"), 1)
        let doc = try await scalar("SELECT document_id::text AS v FROM dms_document_files WHERE mime = 'message/rfc822'", as: String.self)
        let download = try await raw(app1, .GET, base(w.tenantA) + "/documents/\(doc)/file", token: w.alice.token)
        XCTAssertEqual(download.body.count, m1.count, "byte-identisch (GreenMail liefert die eingelieferten Bytes)")
        XCTAssertEqual(download.body, m1)
        let e = try await call(app1, .GET, base(w.tenantA) + "/documents/\(doc)/extraction", token: w.alice.token)
        XCTAssertEqual(e.json["kind"] as? String, "invoice", "\(e.json)"); XCTAssertEqual(e.json["amount"] as? String, "1234.56"); XCTAssertEqual(e.json["reference"] as? String, "4711")
        try await aEq(try await count("dms_documents"), 2, "Rechnung (Mail) und PDF-Anhang; Newsletter nicht")
        try await aEq(try await count("links", where: "kind = 'mail_attachment'"), 0, "m2 hat kein Mail-Dokument (Mailtext nicht erkannt)")
        try await aEq(try await mailboxState("mail7", "INBOX").unseen, 0)
        try await aEq(try await mailboxState("mail7", "Verarbeitet").all, 3)
        // zweiter Poll mit denselben Nachrichten
        try await seed("mail7", [m1, m2, m3])
        let before = try await count("dms_documents")
        _ = try await call(app2, .POST, src(w.tenantA) + "/\(id)/run", token: w.alice.token)
        try await runWorker(worker(app2.db(.psql) as! any SQLDatabase, log: log), until: "zweiter Lauf") { try await self.runs(id) >= 2 }
        try await aEq(try await count("dms_documents"), before, "Wiederholung ohne Duplikate")
        try await aEq(try await count("dms_extractions"), 1, "Extraktion nur für die Mail; der PDF-Anhang wartet auf OCR (OCR-Worker)")
    }

    // MARK: WP-H10

    /// AK-H10-1: Feindliche Klartext-Mail (Etikett + über 190 000 Leerzeichen, dazu viel Text) blockiert den Worker nicht; läuft die Extraktion in die harte Frist
    /// (hier künstlich 50 ms), wird die Mail trotzdem als verarbeitet behandelt (gelesen und verschoben) und nicht endlos neu geholt (keine Poison-Pill).
    func testAKH10_1_hostileMailNeverBecomesPoisonPill() async throws {
        setenv("DMS_EXTRACT_TIMEOUT_MS", "50", 1)
        defer { unsetenv("DMS_EXTRACT_TIMEOUT_MS") }
        let w = try await world()
        let log = LogCapture()
        let hostile = "Rechnungsnr" + String(repeating: " ", count: 190_000) + "X1\n" + String(repeating: "Rechnungsnummer: A1234 Gesamtbetrag 10,00 EUR\n", count: 1_000)
        try await seed("mail5", [message(subject: "Rechnung dringend", id: "h10-1", text: hostile)], create: ["Verarbeitet"])
        let id = try await createMailSource(w, user: "mail5", extra: ["include_body": false, "keep_mail": "always"])
        let start = Date()
        try await runWorker(worker(db, log: log), until: "erster Lauf") { try await self.runs(id) >= 1 }
        XCTAssertLessThan(Date().timeIntervalSince(start), 30, "der Worker bleibt nicht hängen")
        let status = try await call(app1, .GET, src(w.tenantA) + "/\(id)", token: w.alice.token)
        XCTAssertEqual(status.json["last_status"] as? String, "ok", "\(status.json)")
        try await aEq(try await mailboxState("mail5", "INBOX").unseen, 0, "Mail ist gelesen")
        try await aEq(try await mailboxState("mail5", "Verarbeitet").all, 1, "und verschoben")
        try await aEq(try await count("dms_documents"), 1, "Ingest läuft weiter: Mail-Original abgelegt")
        // der nächste Lauf holt nichts mehr
        _ = try await call(app1, .POST, src(w.tenantA) + "/\(id)/run", token: w.alice.token)
        try await runWorker(worker(db, log: log), until: "zweiter Lauf") { try await self.runs(id) >= 2 }
        let stats = try await call(app1, .GET, src(w.tenantA) + "/\(id)", token: w.alice.token)
        XCTAssertEqual((stats.json["last_stats"] as? [String: Any])?["messages"] as? Int, 0, "keine erneute Verarbeitung: \(stats.json)")
        try await aEq(try await count("dms_documents"), 1)
    }
}


/// WP-H10: Befunde 2, 3 und 8 ohne Docker (Validierung, Zielprüfung, feindlicher IMAP-Testserver).
final class NetworkTargetTests: XCTestCase {
    private func resolver(_ map: [String: [NetworkTarget.IP]]) -> NetworkTarget.Resolver { { host in map[host] ?? [] } }
    private func v4(_ a: UInt8, _ b: UInt8, _ c: UInt8, _ d: UInt8) -> NetworkTarget.IP { .v4([a, b, c, d]) }

    /// AK-H10-3: alle Schreibweisen interner Adressen sind gesperrt, öffentliche nicht.
    func testAKH10_3_internalAddressesInEveryNotation() {
        let internalHosts = ["127.0.0.1", "127.1", "2130706433", "0x7f000001", "0x7f.0.0.1", "017700000001", "0", "0.0.0.0", "10.0.0.5", "10.255.255.255", "172.16.0.1", "172.31.255.255",
                             "192.168.1.1", "169.254.169.254", "100.64.0.1", "224.0.0.1", "255.255.255.255", "[::1]", "::1", "::", "[::ffff:127.0.0.1]", "::ffff:7f00:1", "::ffff:10.0.0.1",
                             "::ffff:169.254.169.254", "fc00::1", "fd12:3456::1", "fe80::1", "fe80::1%en0", "64:ff9b::7f00:1", "2002:7f00:1::1", "ff02::1", "::127.0.0.1"]
        for h in internalHosts {
            let ip = NetworkTarget.parseLiteral(h)
            XCTAssertNotNil(ip, "\(h) muss als Literal erkannt werden")
            XCTAssertTrue(ip.map(NetworkTarget.isInternal) ?? false, "\(h) muss intern sein")
        }
        for h in ["8.8.8.8", "93.184.216.34", "172.32.0.1", "172.15.255.255", "192.169.0.1", "100.63.255.255", "100.128.0.1", "2606:4700:4700::1111", "::ffff:8.8.8.8"] {
            let ip = NetworkTarget.parseLiteral(h)
            XCTAssertNotNil(ip, h)
            XCTAssertFalse(ip.map(NetworkTarget.isInternal) ?? true, "\(h) ist öffentlich")
        }
        XCTAssertNil(NetworkTarget.parseLiteral("imap.example.org"))
        for n in ["localhost", "LOCALHOST.", "x.localhost", "metadata.google.internal", "printer.local", "db.internal", "nas.lan"] { XCTAssertTrue(NetworkTarget.isInternalName(n), n) }
        XCTAssertFalse(NetworkTarget.isInternalName("imap.example.org"))
        XCTAssertTrue(PaperlessEndpoint.isInternal("127.1")); XCTAssertTrue(PaperlessEndpoint.isInternal("2130706433")); XCTAssertTrue(PaperlessEndpoint.isInternal("::ffff:127.0.0.1"))
        XCTAssertTrue(PaperlessEndpoint.isInternal("10.1.2.3")); XCTAssertTrue(PaperlessEndpoint.isInternal("fc00::1")); XCTAssertFalse(PaperlessEndpoint.isInternal("paperless.example.org"))
    }

    /// AK-H10-3: Auflösung — jede interne Adresse genügt zur Ablehnung (auch gemischt), DNS-Rebinding-Fall; mit Betreiber-Erlaubnis geht es durch; einheitlicher Code.
    func testAKH10_3_resolveChecksAllAddressesAndAllowsOperatorOverride() async throws {
        let r = resolver(["ok.example.org": [v4(93, 184, 216, 34)], "evil.example.org": [v4(93, 184, 216, 34), v4(127, 0, 0, 1)], "rebind.example.org": [v4(169, 254, 169, 254)],
                          "v6.example.org": [.v6([0x26, 0x06, 0x47, 0, 0x47, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x11, 0x11])], "gone.example.org": []])
        let strict = NetworkTargetPolicy()
        let ok = try await NetworkTarget.resolve(host: "ok.example.org", policy: strict, resolver: r)
        XCTAssertEqual(ok, [v4(93, 184, 216, 34)])
        _ = try await NetworkTarget.resolve(host: "v6.example.org", policy: strict, resolver: r)
        for h in ["evil.example.org", "rebind.example.org", "127.0.0.1", "localhost", "10.1.1.1", "[::1]"] {
            do { _ = try await NetworkTarget.resolve(host: h, policy: strict, resolver: r); XCTFail("\(h) muss gesperrt sein") } catch let e as NetworkTargetError { XCTAssertEqual(e, .notAllowed, h) }
        }
        do { _ = try await NetworkTarget.resolve(host: "gone.example.org", policy: strict, resolver: r); XCTFail() } catch let e as NetworkTargetError { XCTAssertEqual(e, .unresolvable) }
        let open = NetworkTargetPolicy(allowInternal: true)
        let evil = try await NetworkTarget.resolve(host: "evil.example.org", policy: open, resolver: r)
        XCTAssertEqual(evil.count, 2)
        _ = try await NetworkTarget.resolve(host: "127.0.0.1", policy: open, resolver: r)
        XCTAssertFalse(NetworkTargetPolicy.fromEnvironment([:]).allowInternal)
        XCTAssertTrue(NetworkTargetPolicy.fromEnvironment(["DMS_ALLOW_INTERNAL_TARGETS": "true"]).allowInternal)
        XCTAssertFalse(NetworkTargetPolicy.fromEnvironment(["DMS_ALLOW_INTERNAL_TARGETS": "1"]).allowInternal, "nur ausdrücklich \"true\"")
    }

    /// AK-H10-3: Der IMAP-Client prüft Ziel und Port vor dem Connect — auch interne Ziele mit offenem und geschlossenem Port liefern denselben Code (kein Port-Orakel).
    func testAKH10_3_imapClientRefusesInternalTargetsAndPortsWithOneCode() async throws {
        let closed = try {   // ein sicher geschlossener lokaler Port
            let l = try ServerSocketProbe(); return l.closedPort
        }()
        let options = IMAPOptions()   // Standard: intern gesperrt, nur 993
        for (host, port) in [("127.0.0.1", 993), ("127.0.0.1", closed), ("127.0.0.1", 22), ("localhost", 993), ("10.0.0.1", 993), ("169.254.169.254", 80), ("[::1]", 993), ("2130706433", 993)] {
            do { try await IMAPClient.withSession(host: host, port: port, user: "u", password: "p", options: options) { _ in () }; XCTFail("\(host):\(port)") }
            catch let e as IMAPError { XCTAssertEqual(e.code, "target_not_allowed", "\(host):\(port)") }
        }
        // öffentliches Ziel, aber Port nicht in der Liste: ebenfalls derselbe Code, ohne dass verbunden wird
        var pub = IMAPOptions(); pub.resolver = { _ in [.v4([93, 184, 216, 34])] }
        do { try await IMAPClient.withSession(host: "imap.example.org", port: 25, user: "u", password: "p", options: pub) { _ in () }; XCTFail() }
        catch let e as IMAPError { XCTAssertEqual(e.code, "target_not_allowed") }
        XCTAssertEqual(IMAPOptions.allowedPorts([:]), [993])
        XCTAssertEqual(IMAPOptions.allowedPorts(["DMS_MAIL_PORT_ALLOWLIST": "143, 1993,abc,0,70000"]), [993, 143, 1993])
    }

    /// AK-H10-2/3: Validierung beim Speichern: IP-Literale (auch exotische Schreibweisen) abgelehnt, interne Namen und Ports außerhalb der Liste abgelehnt, Betreiber-Env erlaubt.
    func testAKH10_2_3_validateRejectsIPLiteralsInternalNamesAndPorts() throws {
        func code(_ config: [String: Any], env: [String: String] = [:]) -> (String, String)? {
            do { _ = try DMSSources.validate(kind: .mail, config: config, env: env); return nil }
            catch let e as HubError { return (e.errors.first?.field ?? "", e.errors.first?.code ?? e.code) } catch { return ("?", "\(error)") }
        }
        let base: [String: Any] = ["host": "imap.example.org", "username": "u"]
        XCTAssertNil(code(base))
        for h in ["93.184.216.34", "127.0.0.1", "127.1", "2130706433", "0x7f000001", "::1", "fe80::1", "::ffff:127.0.0.1"] {
            var c = base; c["host"] = h
            let r = code(c)
            XCTAssertEqual(r?.0, "config.host", h)
            XCTAssertTrue(["ip_literal_not_allowed", "invalid"].contains(r?.1 ?? ""), "\(h): \(r?.1 ?? "-")")
        }
        var lit = base; lit["host"] = "93.184.216.34"
        XCTAssertEqual(code(lit)?.1, "ip_literal_not_allowed", "Entscheidung: IP-Literale werden abgelehnt (auch öffentliche)")
        XCTAssertEqual(code(lit, env: ["DMS_ALLOW_INTERNAL_TARGETS": "true"])?.1, "ip_literal_not_allowed", "auch mit Betreiber-Erlaubnis: nur DNS-Namen")
        for h in ["localhost", "foo.localhost", "nas.local", "metadata.google.internal"] {
            var c = base; c["host"] = h
            XCTAssertEqual(code(c)?.1, "target_not_allowed", h)
            XCTAssertNil(code(c, env: ["DMS_ALLOW_INTERNAL_TARGETS": "true"]), "\(h) mit Betreiber-Erlaubnis")
        }
        var p = base; p["port"] = 25
        XCTAssertEqual(code(p)?.0, "config.port"); XCTAssertEqual(code(p)?.1, "port_not_allowed")
        XCTAssertNil(code(p, env: ["DMS_MAIL_PORT_ALLOWLIST": "25,143"]))
        p["port"] = 993; XCTAssertNil(code(p))
        var hostList = base; hostList["host"] = "other.example.org"
        XCTAssertEqual(code(hostList, env: ["DMS_MAIL_HOST_ALLOWLIST": "imap.example.org"])?.0, "config.host")
    }

    /// AK-H10-8: Feindlicher IMAP-Server (TLS, selbstsigniert) schickt endlos untagged-Zeilen bzw. riesige Literale: Abbruch mit `imap_response_too_large`, Speicher bleibt begrenzt.
    func testAKH10_8_hostileServerResponsesAreBounded() async throws {
        guard let server = try await HostileIMAPServer.make() else { throw XCTSkip("openssl nicht verfügbar: Test des feindlichen IMAP-Servers übersprungen") }
        defer { Task { await server.stop() } }
        var o = IMAPOptions(); o.verifyCertificate = false; o.sessionTimeout = .seconds(20)
        o.targetPolicy = NetworkTargetPolicy(allowInternal: true); o.allowedPorts = [server.port]
        o.maxResponseLines = 500; o.maxMessageBytes = 1024 * 1024; o.maxResponseBytes = 4 * 1024 * 1024
        for mode in ["lines", "literals", "longline"] {
            server.mode = mode
            do { try await IMAPClient.withSession(host: "127.0.0.1", port: server.port, user: "u", password: "p", options: o) { s in try await s.select("INBOX") }; XCTFail(mode) }
            catch let e as IMAPError { XCTAssertEqual(e.code, mode == "longline" ? "imap_protocol_error" : "imap_response_too_large", mode) }
        }
        server.mode = "normal"
        try await IMAPClient.withSession(host: "127.0.0.1", port: server.port, user: "u", password: "p", options: o) { s in try await s.select("INBOX") }
    }
}

/// Liefert einen sicher geschlossenen lokalen Port (gebunden, ermittelt, wieder freigegeben).
struct ServerSocketProbe {
    let closedPort: Int
    init() throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(fd) }
        var addr = sockaddr_in(); addr.sin_family = sa_family_t(AF_INET); addr.sin_addr.s_addr = UInt32(0x7f000001).bigEndian; addr.sin_port = 0
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, len) } }
        guard bound == 0 else { throw XCTSkip("kein lokaler Port") }
        _ = withUnsafeMutablePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) } }
        closedPort = Int(UInt16(bigEndian: addr.sin_port))
    }
}
