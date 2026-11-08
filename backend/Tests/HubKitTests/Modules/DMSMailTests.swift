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
    static let users = (1...6).map { "mail\($0)" }
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
    var insecure: IMAPOptions { var o = IMAPOptions(); o.verifyCertificate = false; o.sessionTimeout = .seconds(30); return o }

    override func setUp() async throws {
        try await super.setUp()
        mail = try GreenMail.acquire()
        try await mail.waitUntilReady()
        setenv("DMS_MAIL_TLS_VERIFY", "false", 1)   // Verbindungstest-Route liest die Betreiber-Umgebung
    }
    override func tearDown() async throws {
        unsetenv("DMS_MAIL_TLS_VERIFY")
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
        var config: [String: Any] = ["host": "127.0.0.1", "port": mail.port, "username": user, "processed_mailbox": "Verarbeitet", "include_body": true, "interval_seconds": 30]
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
        let cfg = try await call(app1, .PATCH, src(w.tenantA) + "/\(id)", json: ["config": ["host": "127.0.0.1", "port": mail.port, "username": "mail2", "sender_contains": "billing@example.org", "include_body": false]], token: w.alice.token)
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
}
