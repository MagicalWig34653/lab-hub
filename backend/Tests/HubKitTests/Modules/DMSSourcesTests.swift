import XCTVapor
import Fluent
import SQLKit
import Crypto
import Logging
@testable import HubKit

// WP-D4: Quellen (Mail-IMAP, Konsumordner), API-Token, Share-/Scan-API. Nur synthetische Mails/Dateien, Adressen und Hosts example.org bzw. 127.0.0.1.
// Mail-Tests laufen gegen einen lokalen GreenMail-Server (Docker, Image greenmail/standalone, TLS mit selbstsigniertem Zertifikat); ohne Docker werden sie mit Meldung übersprungen.

let d4Key = "synthetic-secret-key-for-tests-0123456789"
let d4Canary = "Kanarienvogel-D4-pw-7g3q"       // synthetisches Passwort: darf nirgends im Klartext auftauchen

class DMSSourceTestBase: DMSTestBase {
    override var testModules: [any HubModule] { [DMSModule(objectStore: ObjectStoreConfig(kind: .db), maxUploadBytes: Self.uploadLimit, secretKey: d4Key)] }

    var sourcesBase: String { "" }
    func src(_ tenant: String) -> String { base(tenant) + "/sources" }

    func limits() -> DMSSourceLimits { var l = DMSSourceLimits(); l.maxUploadBytes = Self.uploadLimit; l.ocrEnabled = false; return l }

    func eventually(_ what: String, timeout: Double = 40, _ cond: () async throws -> Bool) async throws {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if try await cond() { return }
            try await Task.sleep(for: .milliseconds(150))
        }
        XCTFail("Timeout: \(what)")
    }

    func runWorker(_ worker: JobWorker, until what: String, timeout: Double = 40, _ cond: () async throws -> Bool) async throws {
        let task = Task { await worker.run() }
        defer { worker.requestShutdown() }
        try await eventually(what, timeout: timeout, cond)
        worker.requestShutdown()
        await task.value
    }

    func jobs() -> JobService { JobService(db) }

    /// Alle Zeilen aller Tabellen als Text (Suche nach Geheimnissen in der Datenbank).
    func databaseDumpContains(_ needle: String) async throws -> Bool {
        let tables = try await db.raw("SELECT table_name FROM information_schema.tables WHERE table_schema = current_schema() AND table_type = 'BASE TABLE'").all()
            .map { try $0.decode(column: "table_name", as: String.self) }
        for t in tables {
            let n = try await db.raw(SQLQueryString("SELECT count(*)::bigint AS n FROM \"\(t)\" x WHERE x::text ILIKE '%' || \(needle.sqlLiteral) || '%'")).first()!.decode(column: "n", as: Int64.self)
            if n > 0 { return true }
        }
        return false
    }
}

private extension String {
    var sqlLiteral: String { "'" + replacingOccurrences(of: "'", with: "''") + "'" }
}

final class LogCapture: @unchecked Sendable {
    private let lock = NSLock(); private var lines: [String] = []
    func add(_ s: String) { lock.lock(); lines.append(s); lock.unlock() }
    var text: String { lock.lock(); defer { lock.unlock() }; return lines.joined(separator: "\n") }
    func logger() -> Logger { Logger(label: "d4.capture") { _ in CaptureHandler(box: self) } }
}
struct CaptureHandler: LogHandler {
    let box: LogCapture
    var metadata: Logger.Metadata = [:]
    var logLevel: Logger.Level = .trace
    subscript(metadataKey key: String) -> Logger.Metadata.Value? { get { metadata[key] } set { metadata[key] = newValue } }
    func log(event: LogEvent) { box.add("\(event.level) \(event.message) \(event.metadata ?? [:]) \(metadata)") }
}

// MARK: - Reine Logik (kein Datenbankbedarf)

final class MailParserTests: XCTestCase {
    private func b64(_ d: Data) -> String { d.base64EncodedString(options: [.lineLength76Characters, .endLineWithCarriageReturn, .endLineWithLineFeed]) }

    /// AK-D4-1 (Parser): Absender, Message-ID, kodierter Betreff, Mehrteiligkeit (verschachtelt), base64/quoted-printable, Dateiname nach RFC 2231 und 2047.
    func testAKD4_1_parsesMultipartMail() {
        let pdf = Data("%PDF-1.4\n% synthetic\n".utf8)
        let raw = [
            "From: =?UTF-8?B?UmVjaG51bmcgU3ludGhldGlj?= <Billing@Example.ORG>", "Message-ID: <abc.123@example.org>",
            "Subject: =?UTF-8?Q?Rechnung_f=C3=BCr_M=C3=A4rz?=", "Date: Sun, 8 Nov 2026 10:00:00 +0100", "MIME-Version: 1.0",
            "Content-Type: multipart/mixed; boundary=\"outer\"", "",
            "--outer", "Content-Type: multipart/alternative; boundary=\"inner\"", "",
            "--inner", "Content-Type: text/plain; charset=utf-8", "Content-Transfer-Encoding: quoted-printable", "", "Guten Tag, anbei die Rechnung f=C3=BCr M=C3=A4rz.=", " Danke", "",
            "--inner", "Content-Type: text/html; charset=utf-8", "", "<p>HTML</p>", "--inner--", "",
            "--outer", "Content-Type: application/pdf; name=\"fallback.pdf\"", "Content-Disposition: attachment; filename*=UTF-8''Rechnung%20M%C3%A4rz.pdf",
            "Content-Transfer-Encoding: base64", "", b64(pdf), "--outer--", ""].joined(separator: "\r\n")
        let mail = MailParser.parse(Data(raw.utf8))
        XCTAssertEqual(mail.from, "billing@example.org")
        XCTAssertEqual(mail.messageID, "<abc.123@example.org>")
        XCTAssertEqual(mail.subject, "Rechnung für März")
        XCTAssertTrue(mail.textBody?.contains("Rechnung für März. Danke") == true, mail.textBody ?? "nil")
        XCTAssertEqual(mail.attachments.count, 1)
        XCTAssertEqual(mail.attachments.first?.filename, "Rechnung März.pdf")
        XCTAssertEqual(mail.attachments.first?.data, pdf)
    }

    /// AK-D4-1: Eingabe ist unvertrauenswürdig: tiefe Verschachtelung, viele Teile und kaputte Kodierung brechen nichts.
    func testAKD4_1_parserLimitsAndGarbage() {
        var raw = "Content-Type: multipart/mixed; boundary=\"b0\"\r\n\r\n"
        for i in 0..<30 { raw += "--b\(i)\r\nContent-Type: multipart/mixed; boundary=\"b\(i + 1)\"\r\n\r\n" }
        let deep = MailParser.parse(Data(raw.utf8))
        XCTAssertTrue(deep.attachments.isEmpty)
        var many = "Content-Type: multipart/mixed; boundary=\"x\"\r\n\r\n"
        for i in 0..<500 { many += "--x\r\nContent-Type: application/octet-stream\r\nContent-Disposition: attachment; filename=\"f\(i).bin\"\r\n\r\nabc\r\n" }
        many += "--x--\r\n"
        XCTAssertLessThanOrEqual(MailParser.parse(Data(many.utf8)).attachments.count, MailParser.maxParts)
        let garbage = MailParser.parse(Data([0xFF, 0x00, 0xFE, 0x0A, 0x0A, 0x41]))
        XCTAssertNil(garbage.from)
        let badB64 = MailParser.parse(Data("Content-Type: application/pdf\r\nContent-Disposition: attachment; filename=\"a.pdf\"\r\nContent-Transfer-Encoding: base64\r\n\r\n%%%%\r\n".utf8))
        XCTAssertEqual(badB64.attachments.first?.data.count, 0)
        XCTAssertNil(MailParser.address("kein-at-zeichen"))
        XCTAssertEqual(MailParser.address("\"Name, Test\" <a.b@example.org>"), "a.b@example.org")
    }

    /// AK-D4-1: Mailtext als PDF ist ein gültiges, erkanntes PDF (Magic Bytes) und enthält Kopf und Text.
    func testAKD4_1_bodyPDFIsRecognizedAsPDF() {
        let pdf = MailBodyPDF.render(subject: "Betreff (Test)", from: "a@example.org", date: nil, body: "Zeile 1\nZeile 2 mit Umlaut ä und (Klammern)\\")
        XCTAssertEqual(DMSFileKind.sniff(Array(pdf.prefix(12))), .pdf)
        let text = String(decoding: pdf, as: UTF8.self)
        XCTAssertTrue(text.contains("Zeile 1") && text.contains("Betreff \\(Test\\)"))
        XCTAssertTrue(text.hasSuffix("%%EOF\n"))
    }
}

final class SecretBoxTests: XCTestCase {
    /// AK-D4-2: Verschlüsselung ohne Klartext, Bindung an Mandant und Quelle, Manipulation und falscher Schlüssel werden erkannt, kurzer Schlüssel nicht erlaubt.
    func testAKD4_2_secretBoxRoundtripAndBinding() throws {
        let box = try XCTUnwrap(SecretBox(secretKey: d4Key))
        let tenant = UUID(), source = UUID()
        let sealed = try box.seal(d4Canary, tenant: tenant, source: source)
        XCTAssertTrue(sealed.hasPrefix("v1:"))
        XCTAssertFalse(sealed.contains(d4Canary))
        XCTAssertFalse(String(decoding: Data(base64Encoded: String(sealed.dropFirst(3)))!, as: UTF8.self).contains(d4Canary))
        XCTAssertEqual(try box.open(sealed, tenant: tenant, source: source), d4Canary)
        XCTAssertNotEqual(sealed, try box.seal(d4Canary, tenant: tenant, source: source), "zufälliger Nonce")
        XCTAssertThrowsError(try box.open(sealed, tenant: tenant, source: UUID()))      // andere Quelle
        XCTAssertThrowsError(try box.open(sealed, tenant: UUID(), source: source))      // anderer Mandant
        var data = Data(base64Encoded: String(sealed.dropFirst(3)))!
        data[data.count - 1] ^= 1
        XCTAssertThrowsError(try box.open("v1:" + data.base64EncodedString(), tenant: tenant, source: source))
        XCTAssertThrowsError(try box.open("klartext", tenant: tenant, source: source))
        let other = try XCTUnwrap(SecretBox(secretKey: d4Key + "x"))
        XCTAssertThrowsError(try other.open(sealed, tenant: tenant, source: source))
        XCTAssertNil(SecretBox(secretKey: "kurz"))
        XCTAssertNil(SecretBox(secretKey: nil))
    }

    func testSecretKeyFromFileEnvironment() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("d4-secret-\(UUID().uuidString)").path
        try Data((d4Key + "\n").utf8).write(to: URL(fileURLWithPath: path))
        defer { try? FileManager.default.removeItem(atPath: path) }
        let fromFile = try XCTUnwrap(SecretBox.fromEnvironment(["SECRET_KEY_FILE": path]))
        let fromValue = try XCTUnwrap(SecretBox.fromEnvironment(["SECRET_KEY": d4Key]))
        let t = UUID(), s = UUID()
        XCTAssertEqual(try fromValue.open(try fromFile.seal("x", tenant: t, source: s), tenant: t, source: s), "x")
        XCTAssertNil(SecretBox.fromEnvironment([:]))
    }
}

// MARK: - API-Token und Share-/Scan-API

final class ApiTokenTests: DMSSourceTestBase {
    func makeToken(_ s: TestSession, scopes: [String] = ["dms.upload"], via: Application? = nil) async throws -> (id: String, token: String) {
        let r = try await call(via ?? app1, .POST, "api/v1/auth/api-tokens", json: ["name": "Scanner Flur", "scopes": scopes], token: s.token)
        XCTAssertEqual(r.status, .created, "\(r.json)")
        return (r.json["id"] as? String ?? "", r.json["token"] as? String ?? "")
    }

    func share(_ token: String, _ tenant: String, _ data: Data, key: String? = nil, query: String = "", via: Application? = nil) async throws -> Raw {
        var headers = ["Content-Type": "application/octet-stream"]
        if let key { headers["Idempotency-Key"] = key }
        return try await raw(via ?? app1, .POST, base(tenant) + "/share" + (query.isEmpty ? "" : "?" + query), body: data, token: token, headers: headers)
    }

    /// AK-D4-4: Erstellen (Klartext nur einmal), Liste ohne Klartext, nur der Hash in der Datenbank, Audit ohne Token, Widerruf wirkt sofort auf der anderen Instanz.
    func testAKD4_4_createListRevokeAndHashOnly() async throws {
        let w = try await world()
        let (id, token) = try await makeToken(w.alice)
        XCTAssertTrue(token.hasPrefix("lhp_"))
        XCTAssertEqual(token.utf8.count, 47)
        let list = try await call(app2, .GET, "api/v1/auth/api-tokens", token: w.alice.token)
        XCTAssertEqual(items(list).count, 1)
        XCTAssertNil(items(list).first?["token"])
        XCTAssertEqual(items(list).first?["scopes"] as? [String], ["dms.upload"])
        let stored = try await scalar("SELECT token_hash AS v FROM api_tokens", as: String.self)
        XCTAssertEqual(stored, AuthSecrets.hash(token))
        let leaked = try await databaseDumpContains(token)
        XCTAssertFalse(leaked, "Token-Klartext in der Datenbank")
        try await aEq(try await auditCount("auth.api_token.created", tenant: w.tenantA), 0)   // nutzerbezogen, ohne Mandant
        try await aEq(try await count("audit_log", where: "action = 'auth.api_token.created'"), 1)

        let ok = try await share(token, w.tenantA, pdf("token-ok"), via: app1)
        XCTAssertEqual(ok.status, .created, "\(ok.json)")
        let revoke = try await call(app1, .DELETE, "api/v1/auth/api-tokens/\(id)", token: w.alice.token)
        XCTAssertEqual(revoke.status, .noContent)
        let again = try await call(app2, .DELETE, "api/v1/auth/api-tokens/\(id)", token: w.alice.token)
        XCTAssertEqual(again.status, .noContent, "idempotent")
        try await aEq(try await count("audit_log", where: "action = 'auth.api_token.revoked'"), 1)
        let denied = try await share(token, w.tenantA, pdf("token-revoked"), via: app2)
        XCTAssertEqual(denied.status, .unauthorized)
        XCTAssertEqual(denied.problemCode, "unauthorized")
        try await aEq(try await count("dms_documents"), 1)
    }

    /// AK-D4-4: Scope-Prüfung, Ablauf, Eingabeprüfung; ein Token ist keine Sitzung und eine Sitzung kein Token.
    func testAKD4_4_scopeExpiryAndNoSessionConfusion() async throws {
        let w = try await world()
        let (id, token) = try await makeToken(w.alice)
        let unknownScope = try await call(app1, .POST, "api/v1/auth/api-tokens", json: ["name": "x", "scopes": ["dms.admin"]], token: w.alice.token)
        XCTAssertEqual(unknownScope.status, .unprocessableEntity)
        for body in [["name": "", "scopes": ["dms.upload"]], ["name": "x", "scopes": []], ["name": "x", "scopes": ["dms.upload"], "expires_in_days": 0],
                     ["name": "x", "scopes": ["dms.upload"], "expires_in_days": 9999], ["name": "x", "scopes": ["dms.upload"], "extra": 1]] as [[String: Any]] {
            let r = try await call(app1, .POST, "api/v1/auth/api-tokens", json: body, token: w.alice.token)
            XCTAssertEqual(r.status, .unprocessableEntity, "\(body)")
        }
        // anderer Scope in der Datenbank: kein Zugriff
        try await db.raw("UPDATE api_tokens SET scopes = ARRAY['other.scope'] WHERE id = \(bind: UUID(uuidString: id)!)").run()
        let wrongScope = try await share(token, w.tenantA, pdf("scope"))
        XCTAssertEqual(wrongScope.status, .unauthorized)
        try await db.raw("UPDATE api_tokens SET scopes = ARRAY['dms.upload'] WHERE id = \(bind: UUID(uuidString: id)!)").run()
        try await aEq((try await share(token, w.tenantA, pdf("scope-ok"))).status, .created)
        // abgelaufen
        try await db.raw("UPDATE api_tokens SET expires_at = now() - interval '1 second' WHERE id = \(bind: UUID(uuidString: id)!)").run()
        try await aEq((try await share(token, w.tenantA, pdf("expired"), via: app2)).status, .unauthorized)
        // Sitzungstoken an der Share-Route, Token an normalen Routen und an der Token-Verwaltung: 401
        try await aEq((try await share(w.alice.token, w.tenantA, pdf("session"))).status, .unauthorized)
        try await db.raw("UPDATE api_tokens SET expires_at = now() + interval '1 day' WHERE id = \(bind: UUID(uuidString: id)!)").run()
        try await aEq((try await raw(app1, .GET, base(w.tenantA) + "/documents", token: token)).status, .unauthorized)
        try await aEq((try await raw(app1, .GET, "api/v1/auth/api-tokens", token: token)).status, .unauthorized)
        try await aEq((try await raw(app1, .POST, "api/v1/auth/api-tokens", body: Data(#"{"name":"x","scopes":["dms.upload"]}"#.utf8), token: token, headers: ["Content-Type": "application/json"])).status, .unauthorized)
        try await aEq((try await share("lhp_" + String(repeating: "A", count: 43), w.tenantA, pdf("fake"))).status, .unauthorized)
        try await aEq((try await share("", w.tenantA, pdf("empty"))).status, .unauthorized)
        // deaktivierter Nutzer
        try await db.raw("UPDATE users SET disabled_at = now() WHERE id = \(bind: UUID(uuidString: w.alice.userID)!)").run()
        try await aEq((try await share(token, w.tenantA, pdf("disabled"))).status, .unauthorized)
    }

    /// AK-D4-4: Mandantentrennung (fremder Mandant 404), Modulschalter, Rollenrechte; fremde Tokens sind unsichtbar (404).
    func testAKD4_4_tenantSeparationRolesAndForeignTokens() async throws {
        let w = try await world()
        let bob = try await bootstrapSecondUser()
        let bobTenant = try await scalar("SELECT tenant_id::text AS v FROM memberships WHERE user_id = '\(bob.userID)'", as: String.self)
        try await setModule(bobTenant, true, by: bob)
        let (aliceID, aliceToken) = try await makeToken(w.alice)
        let (_, bobToken) = try await makeToken(bob)
        // Alices Token im Mandanten von Bob: 404, nichts angelegt
        let foreign = try await share(aliceToken, bobTenant, pdf("fremd"))
        XCTAssertEqual(foreign.status, .notFound)
        XCTAssertEqual(foreign.problemCode, "not_found")
        try await aEq(try await count("dms_documents", where: "tenant_id = '\(bobTenant)'"), 0)
        try await aEq((try await share(bobToken, bobTenant, pdf("bob"))).status, .created)
        try await aEq((try await share(bobToken, w.tenantA, pdf("bob-in-a"))).status, .notFound)
        // unbekannter/ungültiger Mandant
        try await aEq((try await share(aliceToken, UUID().uuidString, pdf("x"))).status, .notFound)
        // fremdes Token widerrufen/sehen: 404 und kein Effekt
        let steal = try await call(app1, .DELETE, "api/v1/auth/api-tokens/\(aliceID)", token: bob.token)
        XCTAssertEqual(steal.status, .notFound)
        try await aEq(items(try await call(app1, .GET, "api/v1/auth/api-tokens", token: bob.token)).count, 1)
        try await aEq((try await share(aliceToken, w.tenantA, pdf("still-works"))).status, .created)
        // Modul im Mandanten aus: 404 module_disabled
        try await setModule(w.tenantA, false, by: w.alice)
        let off = try await share(aliceToken, w.tenantA, pdf("off"))
        XCTAssertEqual(off.status, .notFound)
        XCTAssertEqual(off.problemCode, "module_disabled")
        try await setModule(w.tenantA, true, by: w.alice)
        // Rolle ohne Recht (Mandantsicht: Steuerberater darf nicht anlegen): 403, auch mit gültigem Token
        let advisor = try await addUser("tax_advisor", handle: "berater", tenant: w.tenantA, by: w.alice)
        let (_, advisorToken) = try await makeToken(advisor)
        let forbidden = try await share(advisorToken, w.tenantA, pdf("berater"))
        XCTAssertEqual(forbidden.status, .forbidden)
        let member = try await addUser("member", handle: "mitglied", tenant: w.tenantA, by: w.alice)
        let (_, memberToken) = try await makeToken(member)
        try await aEq((try await share(memberToken, w.tenantA, pdf("mitglied"))).status, .created)
    }

    private func bootstrapSecondUser() async throws -> TestSession {
        // zweiter, unabhängiger Mandant: Bootstrap ist nur einmal möglich, daher Einladung als Owner eines neuen Mandanten über SQL-freie Registrierung nicht verfügbar;
        // stattdessen Nutzer und Mandant direkt anlegen und eine Sitzung ausstellen (nur Testdaten).
        let userID = UUID(), tenantID = UUID(), token = AuthSecrets.token()
        try await db.raw("INSERT INTO users (id, handle, display_name) VALUES (\(bind: userID), 'bob', 'Bob Synthetic')").run()
        try await db.raw("INSERT INTO tenants (id, name) VALUES (\(bind: tenantID), 'Mandant B')").run()
        try await db.raw("INSERT INTO memberships (tenant_id, user_id, role) VALUES (\(bind: tenantID), \(bind: userID), 'owner')").run()
        try await db.raw("INSERT INTO sessions (user_id, token_hash, kind, expires_at) VALUES (\(bind: userID), \(bind: AuthSecrets.hash(token)), 'normal', now() + interval '1 day')").run()
        return TestSession(token: token, userID: userID.uuidString, csrf: AuthSecrets.csrf(token), handle: "bob")
    }

    /// AK-D4-4: Share-API legt Dokument mit Quelle share_ext an, Eingang auditiert; ohne Idempotency-Key erzeugt dieselbe Datei kein zweites Dokument,
    /// mit anderem Titel entsteht ein neues; unbekannter Typ 415, zu groß 413; mit Idempotency-Key gilt dessen Semantik; Eingangsvorgang trägt den Token als Herkunft.
    func testAKD4_4_shareUploadIdempotentAndValidated() async throws {
        let w = try await world()
        let (id, token) = try await makeToken(w.alice)
        let data = pdf("scan-1", padding: 500)
        let first = try await share(token, w.tenantA, data, query: "filename=Scan%20Flur.pdf")
        XCTAssertEqual(first.status, .created, "\(first.json)")
        XCTAssertEqual(first.json["title"] as? String, "Scan Flur")
        let again = try await share(token, w.tenantA, data, query: "filename=Scan%20Flur.pdf", via: app2)
        XCTAssertEqual(again.status, .created)
        XCTAssertEqual(again.json["id"] as? String, first.json["id"] as? String, "Wiederholung liefert dasselbe Dokument")
        try await aEq(try await count("dms_documents"), 1)
        let other = try await share(token, w.tenantA, data, query: "filename=Scan%20Flur.pdf&title=Anderer%20Titel")
        XCTAssertEqual(other.status, .created)
        XCTAssertNotEqual(other.json["id"] as? String, first.json["id"] as? String)
        try await aEq(try await count("dms_documents"), 2)
        let ingest = try await db.raw("SELECT source, origin_ref FROM dms_ingest_items ORDER BY created_at LIMIT 1").first()!
        XCTAssertEqual(try ingest.decode(column: "source", as: String.self), "share_ext")
        XCTAssertEqual(try ingest.decode(column: "origin_ref", as: String?.self), "api_token:\(id.lowercased())")
        let creator = try await scalar("SELECT created_by::text AS v FROM dms_documents ORDER BY created_at LIMIT 1", as: String.self)
        XCTAssertEqual(creator.lowercased(), w.alice.userID.lowercased())
        try await aEq(try await auditCount("dms.document.created", tenant: w.tenantA), 2)
        // Typ und Größe
        let text = try await share(token, w.tenantA, Data("kein dokument".utf8))
        XCTAssertEqual(text.status, .unsupportedMediaType)
        let big = try await share(token, w.tenantA, pdf("big", padding: Int(Self.uploadLimit) + 10))
        XCTAssertEqual(big.status, .payloadTooLarge)
        try await aEq(try await count("dms_documents"), 2)
        // expliziter Idempotency-Key: gleicher Key + anderer Inhalt = 422
        let keyed = try await share(token, w.tenantA, pdf("keyed"), key: "k-\(UUID().uuidString)")
        XCTAssertEqual(keyed.status, .created)
        let reuse = try await share(token, w.tenantA, pdf("keyed-other"), key: "k-fixed")
        XCTAssertEqual(reuse.status, .created)
        let conflict = try await share(token, w.tenantA, pdf("keyed-different"), key: "k-fixed")
        XCTAssertEqual(conflict.status, .unprocessableEntity)
        XCTAssertEqual(conflict.problemCode, "idempotency_key_reused")
        // zwei Instanzen gleichzeitig dieselbe Datei: genau ein Dokument
        let same = pdf("parallel", padding: 100)
        let results = try await parallel(8) { i in try await self.share(token, w.tenantA, same, query: "filename=p.pdf", via: i % 2 == 0 ? self.app1 : self.app2) }
        XCTAssertTrue(results.allSatisfy { $0.status == .created || $0.status == .conflict }, "\(results.map(\.status))")
        try await aEq(try await count("dms_ingest_items", where: "origin_ref LIKE 'api_token:%' AND document_id IN (SELECT id FROM dms_documents WHERE title = 'p')"), 1)
    }

    /// AK-D4-4: Route ist in der Routentabelle für Token-Routen, nicht in der Sitzungsmatrix; Rechte kommen aus dem Modul.
    func testShareRouteRegistered() throws {
        XCTAssertEqual(app1.moduleTokenRoutes.map { "\($0.method) \($0.path) \($0.permission)" }, ["POST /api/v1/tenants/{tenant}/dms/share dms.document.create"])
        XCTAssertFalse(app1.moduleRoutes.contains { $0.path.hasSuffix("/share") })
    }
}

// MARK: - Quellen-Verwaltung

final class DMSSourceAdminTests: DMSSourceTestBase {
    func folderBody(_ name: String = "Scanner-Ordner", path: String = "scanner") -> [String: Any] {
        ["kind": "folder", "name": name, "config": ["path": path, "interval_seconds": 60, "stable_seconds": 0]]
    }

    /// AK-D4-6 (Quellen-Verwaltung): CRUD mit Prüfung, Audit, Passwort nie in Antworten/DB-Klartext, Rechte je Rolle, Mandantentrennung (fremde ID 404), zwei Instanzen.
    func testAKD4_6_crudValidationAuditAndNoSecretInResponses() async throws {
        let w = try await world()
        let a = src(w.tenantA), t = w.alice.token
        let mail: [String: Any] = ["kind": "mail", "name": "Rechnungspostfach", "password": d4Canary,
                                   "config": ["host": "imap.example.org", "username": "rechnung@example.org", "processed_mailbox": "Verarbeitet", "include_body": true]]
        let created = try await call(app1, .POST, a, json: mail, token: t)
        XCTAssertEqual(created.status, .created, "\(created.json)")
        XCTAssertEqual(created.json["has_secret"] as? Bool, true)
        let cfg = created.json["config"] as? [String: Any] ?? [:]
        XCTAssertEqual(cfg["port"] as? Int, 993)
        XCTAssertEqual(cfg["mailbox"] as? String, "INBOX")
        XCTAssertNil(cfg["password"])
        let id = created.json["id"] as! String
        // Antworten (auch Liste und Einzelabruf über die andere Instanz) enthalten nie das Passwort
        let get = try await call(app2, .GET, a + "/\(id)", token: t)
        let list = try await call(app2, .GET, a, token: t)
        for r in [created, get, list] { XCTAssertFalse(String(decoding: try JSONSerialization.data(withJSONObject: r.json), as: UTF8.self).contains(d4Canary)) }
        // in der Datenbank nur verschlüsselt, in Audit und Jobs nicht vorhanden
        let leaked = try await databaseDumpContains(d4Canary)
        XCTAssertFalse(leaked, "Passwort im Klartext in der Datenbank")
        let enc = try await scalar("SELECT secret_enc AS v FROM dms_sources", as: String.self)
        XCTAssertTrue(enc.hasPrefix("v1:"))
        try await aEq(try await auditCount("dms.source.created", tenant: w.tenantA), 1)
        // erster Lauf ist eingeplant (genau ein offener Job)
        try await aEq(try await count("jobs", where: "kind = 'dms.mail.poll' AND state = 'queued'"), 1)
        // Prüfungen
        for (body, field) in [
            (["kind": "mail", "name": "x", "config": ["host": "imap.example.org", "username": "u"]], "password"),                         // Passwort fehlt
            (["kind": "mail", "name": "x", "password": "p", "config": ["host": "ex ample", "username": "u"]], "config.host"),
            (["kind": "mail", "name": "x", "password": "p", "config": ["host": "imap.example.org", "username": "u", "port": 70000]], "config.port"),
            (["kind": "mail", "name": "x", "password": "p", "config": ["host": "imap.example.org", "username": "u", "passwort": "p"]], "config.passwort"),   // unbekannter Schlüssel
            (["kind": "mail", "name": "x", "password": "p", "config": ["host": "imap.example.org", "username": "u", "interval_seconds": 5]], "config.interval_seconds"),
            (["kind": "folder", "name": "x", "password": "p", "config": ["path": "scan"]], "password"),
            (["kind": "folder", "name": "x", "config": ["path": "../etc"]], "config.path"),
            (["kind": "folder", "name": "x", "config": ["path": "/etc"]], "config.path"),
            (["kind": "folder", "name": "x", "config": ["path": "a/../b"]], "config.path"),
            (["kind": "folder", "name": "x", "config": ["path": ".versteckt"]], "config.path"),
            (["kind": "ftp", "name": "x", "config": [:]], "kind"),
            (["kind": "folder", "name": "", "config": ["path": "scan"]], "name"),
            (["kind": "folder", "name": "x", "config": ["path": "scan"], "tenant_id": "x"], "tenant_id")] as [([String: Any], String)] {
            let r = try await call(app1, .POST, a, json: body, token: t)
            XCTAssertEqual(r.status, .unprocessableEntity, "\(field): \(r.json)")
            XCTAssertTrue((r.json["errors"] as? [[String: Any]] ?? []).contains { $0["field"] as? String == field }, "\(field): \(r.json)")
        }
        let dupe = try await call(app1, .POST, a, json: mail, token: t)
        XCTAssertEqual(dupe.status, .conflict)
        // Ändern: Passwort ersetzen, Konfiguration, deaktivieren; Passwort bleibt unsichtbar
        let patch = try await call(app2, .PATCH, a + "/\(id)", json: ["password": "Neues-Passwort-D4", "enabled": false, "name": "Umbenannt"], token: t)
        XCTAssertEqual(patch.status, .ok, "\(patch.json)")
        XCTAssertEqual(patch.json["enabled"] as? Bool, false)
        try await aEq(try await auditCount("dms.source.updated", tenant: w.tenantA), 1)
        let leaked2 = try await databaseDumpContains("Neues-Passwort-D4")
        XCTAssertFalse(leaked2)
        let run = try await call(app1, .POST, a + "/\(id)/run", token: t)
        XCTAssertEqual(run.status, .conflict, "deaktivierte Quelle läuft nicht")
        let badPatch = try await call(app1, .PATCH, a + "/\(id)", json: ["config": ["host": "imap.example.org"]], token: t)
        XCTAssertEqual(badPatch.status, .unprocessableEntity)
        // Löschen
        let del = try await call(app1, .DELETE, a + "/\(id)", token: t)
        XCTAssertEqual(del.status, .noContent)
        try await aEq((try await call(app2, .GET, a + "/\(id)", token: t)).status, .notFound)
        try await aEq(try await auditCount("dms.source.deleted", tenant: w.tenantA), 1)
        // Audit enthält keine Nutzdaten (nur Zähler/Kennzeichen)
        let auditLeak = try await count("audit_log", where: "meta::text ILIKE '%example.org%' OR meta::text ILIKE '%\(d4Canary)%'")
        XCTAssertEqual(auditLeak, 0)
    }

    /// AK-D4-6: Rechte (Buchhaltung ja, Mitglied/Steuerberater nein), fremder Mandant 404, Modul aus 404 module_disabled; ohne SECRET_KEY 422 (Feld password, Code secret_key_missing).
    func testAKD4_6_rolesTenantSeparationAndMissingKey() async throws {
        let w = try await world()
        let accountant = try await addUser("accountant", handle: "buchhaltung", tenant: w.tenantA, by: w.alice)
        let member = try await addUser("member", handle: "mitglied", tenant: w.tenantA, by: w.alice)
        let created = try await call(app1, .POST, src(w.tenantA), json: folderBody(), token: accountant.token)
        XCTAssertEqual(created.status, .created, "\(created.json)")
        let id = created.json["id"] as! String
        for s in [member] {
            for (m, p) in [(HTTPMethod.GET, ""), (.POST, ""), (.GET, "/\(id)"), (.PATCH, "/\(id)"), (.DELETE, "/\(id)"), (.POST, "/\(id)/run"), (.POST, "/\(id)/test")] {
                let r = try await call(app1, m, src(w.tenantA) + p, json: m == .GET || m == .DELETE ? nil : folderBody("Fremd"), token: s.token)
                XCTAssertEqual(r.status, .forbidden, "\(m) \(p)")
            }
        }
        try await aEq(try await count("dms_sources"), 1)
        // zweiter Mandant
        let bobTenant = UUID(), bob = UUID(), token = AuthSecrets.token()
        try await db.raw("INSERT INTO users (id, handle, display_name) VALUES (\(bind: bob), 'bob', 'Bob Synthetic')").run()
        try await db.raw("INSERT INTO tenants (id, name) VALUES (\(bind: bobTenant), 'Mandant B')").run()
        try await db.raw("INSERT INTO memberships (tenant_id, user_id, role) VALUES (\(bind: bobTenant), \(bind: bob), 'owner')").run()
        try await db.raw("INSERT INTO sessions (user_id, token_hash, kind, expires_at) VALUES (\(bind: bob), \(bind: AuthSecrets.hash(token)), 'normal', now() + interval '1 day')").run()
        try await setModule(bobTenant.uuidString, true, by: TestSession(token: token, userID: bob.uuidString, csrf: "", handle: "bob"))
        // Bob sieht/ändert die Quelle von A nicht, auch nicht über seinen eigenen Mandantenpfad
        for (m, p) in [(HTTPMethod.GET, ""), (.PATCH, ""), (.DELETE, ""), (.POST, "/run"), (.POST, "/test")] {
            let r = try await call(app2, m, src(bobTenant.uuidString) + "/\(id)" + p, json: m == .PATCH ? ["enabled": false] : nil, token: token)
            XCTAssertEqual(r.status, .notFound, "\(m) \(p)")
        }
        let viaA = try await call(app1, .GET, src(w.tenantA) + "/\(id)", token: token)
        XCTAssertEqual(viaA.status, .notFound, "Bob ist kein Mitglied von A")
        try await aEq(items(try await call(app1, .GET, src(bobTenant.uuidString), token: token)).count, 0)
        // Modul im Mandanten aus
        try await setModule(w.tenantA, false, by: w.alice)
        let off = try await call(app1, .GET, src(w.tenantA), token: w.alice.token)
        XCTAssertEqual(off.status, .notFound); XCTAssertEqual(off.problemCode, "module_disabled")
        try await setModule(w.tenantA, true, by: w.alice)
        // Eine Quelle läuft nicht mehr, wenn das Modul aus ist: Handler tut nichts (Kette endet)
        // ohne Schlüssel: Mail-Quelle nicht anlegbar
        let noKey = try await Application.make(.testing)
        defer { Task { try? await noKey.asyncShutdown() } }
        try configure(noKey, environment: AuthTestCase.makeEnv(), modules: [DMSModule(objectStore: ObjectStoreConfig(kind: .db), secretKey: nil, environment: [:])])
        let r = try await call(noKey, .POST, src(w.tenantA), json: ["kind": "mail", "name": "M", "password": "p", "config": ["host": "imap.example.org", "username": "u"]], token: w.alice.token)
        XCTAssertEqual(r.status, .unprocessableEntity)
        XCTAssertTrue((r.json["errors"] as? [[String: Any]] ?? []).contains { $0["field"] as? String == "password" && $0["code"] as? String == "secret_key_missing" }, "\(r.json)")
    }

    /// AK-D4-5 (Lease): Zwei Worker auf zwei Verbindungen, mehrere Quellen: jeder Mail-Lauf genau einmal je Quelle; gleichzeitiges „Jetzt ausführen“ erzeugt höchstens einen offenen Job je Quelle.
    func testAKD4_5_twoWorkersPollEachSourceExactlyOnce() async throws {
        let w = try await world()
        var ids: [String] = []
        for i in 0..<6 {
            let r = try await call(app1, .POST, src(w.tenantA), json: ["kind": "mail", "name": "Postfach \(i)", "password": "p\(i)", "config": ["host": "imap.example.org", "username": "u\(i)"]], token: w.alice.token)
            XCTAssertEqual(r.status, .created, "\(r.json)"); ids.append(r.json["id"] as! String)
        }
        let runs = results()
        let handler: JobHandler = { job, _ in
            let p = try JSONDecoder().decode(DMSSources.SourcePayload.self, from: Data(job.payload.utf8))
            runs.add(p.source_id.uuidString.lowercased())
            try await Task.sleep(for: .milliseconds(250))   // ein Lauf dauert; der andere Worker darf ihn nicht ebenfalls holen
        }
        let w1 = JobWorker(db: db, kinds: [DMSMailPoll.kind], handlers: [DMSMailPoll.kind: handler], leaseSeconds: 30, pollInterval: .milliseconds(100), logger: Logger(label: "d4.w1"))
        let w2 = JobWorker(db: app2.db(.psql) as! any SQLDatabase, kinds: [DMSMailPoll.kind], handlers: [DMSMailPoll.kind: handler], leaseSeconds: 30, pollInterval: .milliseconds(100), logger: Logger(label: "d4.w2"))
        let t1 = Task { await w1.run() }, t2 = Task { await w2.run() }
        try await eventually("alle Läufe") { try await self.count("jobs", where: "kind = 'dms.mail.poll' AND state = 'done'") == 6 }
        w1.requestShutdown(); w2.requestShutdown(); await t1.value; await t2.value
        XCTAssertEqual(runs.all.count, 6)
        XCTAssertEqual(Set(runs.all), Set(ids.map { $0.lowercased() }), "jede Quelle genau einmal")
        // gleichzeitiges Einplanen: höchstens ein offener Job je Quelle
        let first = ids[0]
        let rs = try await parallel(8) { i in try await self.raw(i % 2 == 0 ? self.app1 : self.app2, .POST, self.src(w.tenantA) + "/\(first)/run", token: w.alice.token) }
        XCTAssertTrue(rs.allSatisfy { $0.status == .accepted }, "\(rs.map(\.status))")
        try await aEq(try await count("jobs", where: "kind = 'dms.mail.poll' AND state IN ('queued', 'running') AND payload LIKE '%\(first.uppercased())%'"), 1)
    }

    final class results: @unchecked Sendable {
        private let lock = NSLock(); private var v: [String] = []
        func add(_ s: String) { lock.lock(); v.append(s); lock.unlock() }
        var all: [String] { lock.lock(); defer { lock.unlock() }; return v }
    }

    /// Migration: Rücknahme und erneute Anwendung (Expand/Contract), Idempotenzdaten gehen mit der Quelle.
    func testD4MigrationRevertAndReapply() async throws {
        _ = try await world(enable: false)
        let before = try await count("information_schema.tables", where: "table_name IN ('dms_sources', 'dms_source_items', 'dms_folder_observations', 'api_tokens')")
        XCTAssertEqual(before, 4)
        try await CreateDMSSources().revert(on: app1.db(.psql))
        try await CreateApiTokens().revert(on: app1.db(.psql))
        try await aEq(try await count("information_schema.tables", where: "table_name IN ('dms_sources', 'dms_source_items', 'dms_folder_observations', 'api_tokens')"), 0)
        try await CreateApiTokens().prepare(on: app1.db(.psql))
        try await CreateDMSSources().prepare(on: app1.db(.psql))
        try await aEq(try await count("information_schema.tables", where: "table_name IN ('dms_sources', 'dms_source_items', 'dms_folder_observations', 'api_tokens')"), 4)
    }
}

// MARK: - Konsumordner

final class DMSFolderTests: DMSSourceTestBase {
    var root = ""

    override func setUp() async throws {
        try await super.setUp()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("labhub-d4-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
    }
    override func tearDown() async throws {
        try? FileManager.default.removeItem(atPath: root)
        try await super.tearDown()
    }

    func folder(_ tenant: String, _ sub: String = "eingang") throws -> URL {
        let u = URL(fileURLWithPath: root).appendingPathComponent(tenant.lowercased()).appendingPathComponent(sub)
        try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    func createSource(_ w: World, path: String = "eingang", stable: Int = 0) async throws -> String {
        let r = try await call(app1, .POST, src(w.tenantA), json: ["kind": "folder", "name": "Ordner \(UUID().uuidString.prefix(6))", "config": ["path": path, "interval_seconds": 60, "stable_seconds": stable]], token: w.alice.token)
        XCTAssertEqual(r.status, .created, "\(r.json)")
        guard let id = r.json["id"] as? String else { throw XCTSkip("Quelle nicht angelegt: \(r.status) \(r.json)") }
        return id
    }

    /// Ein Lauf des Handlers (wie der Worker, ohne Wartezeit); Rückgabe: letzte Statistik.
    @discardableResult
    func scan(_ tenant: String, _ source: String, root override: String? = nil, via: Application? = nil) async throws -> [String: Int] {
        let handler = DMSFolderScan.handler(storeConfig: { ObjectStoreConfig(kind: .db) }, root: override ?? root, limits: limits())
        let payload = String(decoding: try JSONEncoder().encode(DMSSources.SourcePayload(source_id: UUID(uuidString: source)!, tenant_id: UUID(uuidString: tenant)!)), as: UTF8.self)
        try await handler(ClaimedJob(id: UUID(), kind: DMSFolderScan.kind, payload: payload, attempts: 1), (via ?? app1).db(.psql) as! any SQLDatabase)
        let r = try await call(app1, .GET, src(tenant) + "/\(source)", token: tokenOfOwner)
        return r.json["last_stats"] as? [String: Int] ?? [:]
    }

    var tokenOfOwner = ""

    /// AK-D4-3 (Stabilität): Eine halb kopierte Datei wird nicht gelesen. Erste Messung -> warten; Größe ändert sich -> weiter warten (Messung zurückgesetzt);
    /// erst zwei gleiche Messungen -> aufgenommen und nach processed/ verschoben. Der Inhalt entspricht der vollständigen Datei.
    func testAKD4_3_halfCopiedFileIsNotRead() async throws {
        let w = try await world(); tokenOfOwner = w.alice.token
        let dir = try folder(w.tenantA)
        let id = try await createSource(w)
        let full = pdf("folder-1", padding: 4000)
        let target = dir.appendingPathComponent("Scan-Mai.pdf")
        try full.prefix(1000).write(to: target)
        var stats = try await scan(w.tenantA, id)
        XCTAssertEqual(stats["waiting"], 1); XCTAssertEqual(stats["ingested"], 0)
        try await aEq(try await count("dms_documents"), 0)
        // Kopiervorgang läuft weiter: Größe ändert sich
        let handle = try FileHandle(forWritingTo: target)
        try handle.seekToEnd(); try handle.write(contentsOf: full.dropFirst(1000).prefix(1500)); try handle.close()
        stats = try await scan(w.tenantA, id)
        XCTAssertEqual(stats["waiting"], 1, "Größe geändert: weiter warten"); XCTAssertEqual(stats["ingested"], 0)
        try await aEq(try await count("dms_documents"), 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.path))
        // Kopiervorgang fertig, zwei gleiche Messungen
        let h2 = try FileHandle(forWritingTo: target)
        try h2.seekToEnd(); try h2.write(contentsOf: full.dropFirst(2500)); try h2.close()
        stats = try await scan(w.tenantA, id)
        XCTAssertEqual(stats["waiting"], 1); XCTAssertEqual(stats["ingested"], 0)
        stats = try await scan(w.tenantA, id, via: app2)
        XCTAssertEqual(stats["ingested"], 1, "\(stats)")
        try await aEq(try await count("dms_documents"), 1)
        let doc = try await db.raw("SELECT sha256, original_name FROM dms_document_files WHERE role = 'original'").first()!
        XCTAssertEqual(try doc.decode(column: "sha256", as: String.self), hex(full))
        XCTAssertEqual(try doc.decode(column: "original_name", as: String?.self), "Scan-Mai.pdf")
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("processed/Scan-Mai.pdf").path))
        let ingest = try await db.raw("SELECT source, origin_ref FROM dms_ingest_items").first()!
        XCTAssertEqual(try ingest.decode(column: "source", as: String.self), "folder")
        try await aEq(try await count("dms_folder_observations"), 0)
        try await aEq(try await auditCount("dms.ingest.received", tenant: w.tenantA), 1)
    }

    /// AK-D4-3: stable_seconds verlangt, dass die gleiche Messung mindestens so lange zurückliegt (Datenbankzeit).
    func testAKD4_3_stableSecondsRespected() async throws {
        let w = try await world(); tokenOfOwner = w.alice.token
        let dir = try folder(w.tenantA)
        let id = try await createSource(w, stable: 3600)
        try pdf("slow").write(to: dir.appendingPathComponent("a.pdf"))
        try await scan(w.tenantA, id)
        let stats = try await scan(w.tenantA, id)
        XCTAssertEqual(stats["waiting"], 1); XCTAssertEqual(stats["ingested"], 0)
        try await db.raw("UPDATE dms_folder_observations SET first_seen_at = now() - interval '2 hours'").run()
        let final = try await scan(w.tenantA, id)
        XCTAssertEqual(final["ingested"], 1)
    }

    /// AK-D4-3 (Absturz): Zwischen Speichern und Verschieben stürzt der Lauf ab -> die Datei liegt noch da; der nächste Lauf erzeugt kein Duplikat und verschiebt nur.
    /// Dieselbe Datei erneut abgelegt (gleicher Inhalt) -> ebenfalls kein zweites Dokument, Name in processed/ kollisionsfrei.
    func testAKD4_3_crashBetweenCommitAndMoveCreatesNoDuplicate() async throws {
        let w = try await world(); tokenOfOwner = w.alice.token
        let dir = try folder(w.tenantA)
        let id = try await createSource(w)
        let data = pdf("crash", padding: 300)
        try data.write(to: dir.appendingPathComponent("r.pdf"))
        try await scan(w.tenantA, id); try await scan(w.tenantA, id)
        try await aEq(try await count("dms_documents"), 1)
        // Simulation: Verschieben ist nicht geschehen (Datei wieder im Eingang)
        try data.write(to: dir.appendingPathComponent("r.pdf"))
        try await scan(w.tenantA, id)
        let stats = try await scan(w.tenantA, id)
        XCTAssertEqual(stats["duplicates"], 1); XCTAssertEqual(stats["ingested"], 0)
        try await aEq(try await count("dms_documents"), 1)
        try await aEq(try await count("dms_source_items"), 1)
        let processed = try FileManager.default.contentsOfDirectory(atPath: dir.appendingPathComponent("processed").path)
        XCTAssertEqual(processed.count, 2, "\(processed)")
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".pdf") }.isEmpty)
    }

    /// AK-D4-3: Nicht verarbeitbare Dateien (falscher Typ, zu groß, leer) gehen nach failed/, ohne Dokument; Dotfiles, Unterordner und Links werden ignoriert.
    func testAKD4_3_failedFilesAndIgnoredEntries() async throws {
        let w = try await world(); tokenOfOwner = w.alice.token
        let dir = try folder(w.tenantA)
        let id = try await createSource(w)
        try Data("Text, kein Dokument".utf8).write(to: dir.appendingPathComponent("notiz.txt"))
        try pdf("big", padding: Int(Self.uploadLimit) + 100).write(to: dir.appendingPathComponent("riesig.pdf"))
        try Data().write(to: dir.appendingPathComponent("leer.pdf"))
        try pdf("versteckt").write(to: dir.appendingPathComponent(".versteckt.pdf"))
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("unterordner"), withIntermediateDirectories: true)
        try pdf("im-unterordner").write(to: dir.appendingPathComponent("unterordner/x.pdf"))
        let outside = URL(fileURLWithPath: root).appendingPathComponent("geheim.pdf")
        try pdf("ausserhalb").write(to: outside)
        try FileManager.default.createSymbolicLink(at: dir.appendingPathComponent("link.pdf"), withDestinationURL: outside)
        try await scan(w.tenantA, id)
        let stats = try await scan(w.tenantA, id)
        XCTAssertEqual(stats["failed"], 3, "\(stats)")
        XCTAssertEqual(stats["ingested"], 0)
        try await aEq(try await count("dms_documents"), 0)
        let failed = Set(try FileManager.default.contentsOfDirectory(atPath: dir.appendingPathComponent("failed").path))
        XCTAssertEqual(failed, ["notiz.txt", "riesig.pdf", "leer.pdf"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent(".versteckt.pdf").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("unterordner/x.pdf").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path), "Link-Ziel unberührt")
    }

    /// AK-D4-3 (Mandantentrennung): Der Ordner liegt unter <Wurzel>/<mandant>/…; ein Link aus dem Mandantenordner hinaus wird nicht verfolgt (folder_not_found);
    /// fehlende Wurzel und fehlender Ordner werden als Fehlercode an der Quelle sichtbar, die Kette läuft weiter (Rückstau).
    func testAKD4_3_tenantRootSymlinkAndErrorReporting() async throws {
        let w = try await world(); tokenOfOwner = w.alice.token
        let id = try await createSource(w, path: "fehlt")
        var stats = try await scan(w.tenantA, id)
        XCTAssertEqual(stats["files"], 0)
        var source = try await call(app1, .GET, src(w.tenantA) + "/\(id)", token: w.alice.token)
        XCTAssertEqual(source.json["last_status"] as? String, "error")
        XCTAssertEqual(source.json["last_error"] as? String, "folder_not_found")
        // Link aus dem Mandantenordner auf ein fremdes Verzeichnis
        let other = URL(fileURLWithPath: root).appendingPathComponent(UUID().uuidString.lowercased()).appendingPathComponent("eingang")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try pdf("fremd").write(to: other.appendingPathComponent("fremd.pdf"))
        let tenantDir = URL(fileURLWithPath: root).appendingPathComponent(w.tenantA.lowercased())
        try FileManager.default.createDirectory(at: tenantDir, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: tenantDir.appendingPathComponent("fehlt"), withDestinationURL: other)
        stats = try await scan(w.tenantA, id)
        source = try await call(app1, .GET, src(w.tenantA) + "/\(id)", token: w.alice.token)
        XCTAssertEqual(source.json["last_error"] as? String, "folder_not_found")
        try await aEq(try await count("dms_documents"), 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: other.appendingPathComponent("fremd.pdf").path))
        // keine Wurzel konfiguriert (Worker ohne eingebundenes Volume)
        let handler = DMSFolderScan.handler(storeConfig: { ObjectStoreConfig(kind: .db) }, root: nil, limits: limits())
        let payload = String(decoding: try JSONEncoder().encode(DMSSources.SourcePayload(source_id: UUID(uuidString: id)!, tenant_id: UUID(uuidString: w.tenantA)!)), as: UTF8.self)
        try await handler(ClaimedJob(id: UUID(), kind: DMSFolderScan.kind, payload: payload, attempts: 1), db)
        source = try await call(app1, .GET, src(w.tenantA) + "/\(id)", token: w.alice.token)
        XCTAssertEqual(source.json["last_error"] as? String, "folder_root_missing")
        XCTAssertEqual(source.json["runs"] as? Int, 3)
        // Quelle gelöscht oder Modul aus: der Handler tut nichts
        try await setModule(w.tenantA, false, by: w.alice)
        let before = try await count("audit_log")
        try await handler(ClaimedJob(id: UUID(), kind: DMSFolderScan.kind, payload: payload, attempts: 1), db)
        try await aEq(try await count("audit_log"), before)
        try await aEq(try await scalar("SELECT runs AS v FROM dms_sources", as: Int64.self), 3)
    }

    /// AK-D4-3 + AK-D4-5: Zwei Worker scannen gleichzeitig denselben Ordner: jede Datei genau einmal aufgenommen.
    func testAKD4_5_concurrentScansIngestEachFileOnce() async throws {
        let w = try await world(); tokenOfOwner = w.alice.token
        let dir = try folder(w.tenantA)
        let id = try await createSource(w)
        for i in 0..<6 { try pdf("parallel-\(i)", padding: 200 + i).write(to: dir.appendingPathComponent("d\(i).pdf")) }
        try await scan(w.tenantA, id)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for i in 0..<4 { group.addTask { _ = try await self.scan(w.tenantA, id, via: i % 2 == 0 ? self.app1 : self.app2) } }
            try await group.waitForAll()
        }
        try await aEq(try await count("dms_documents"), 6)
        try await aEq(try await count("dms_source_items"), 6)
    }

    /// D3-Anbindung: Quelle `folder` greift in Regeln (`source_is`).
    func testFolderSourceVisibleToRules() async throws {
        let w = try await world(); tokenOfOwner = w.alice.token
        let dir = try folder(w.tenantA)
        let id = try await createSource(w)
        try pdf("regel").write(to: dir.appendingPathComponent("Beleg.pdf"))
        try await scan(w.tenantA, id); try await scan(w.tenantA, id)
        let preview = try await call(app1, .POST, base(w.tenantA) + "/rules/preview", json: ["conditions": ["conditions": [["type": "source_is", "value": "folder"]]], "actions": ["title_template": "Ordner-{filename}"]], token: w.alice.token)
        XCTAssertEqual(preview.status, .ok, "\(preview.json)")
        XCTAssertEqual(preview.json["matched"] as? Int, 1)
    }
}
