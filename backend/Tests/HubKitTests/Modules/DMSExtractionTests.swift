import XCTVapor
import Fluent
import SQLKit
import Crypto
@testable import HubKit

// WP-D7: Extraktion (Dokumentart + Fakten) und Mail-Original (.eml) / HTML-Verarbeitung. Alles synthetisch (erfundene Firmen, example.org, Test-IBAN).
// AK-D7-1  Original-.eml byte-identisch und unveränderlich        AK-D7-2  HTML-Mail ohne Anhang wird als Rechnung erkannt (Felder korrekt)
// AK-D7-3  PDF-Anhang erkannt, mit der Mail verknüpft (mail_attachment)    AK-D7-4  Negativfälle nie als Rechnung (Korpus: ExtractionTests, hier Mails)
// AK-D7-5  Beträge exakt als Decimal (ExtractionTests)               AK-D7-6  Wiederholung erzeugt keine Duplikate (Message-ID + Hash)
// AK-D7-7  HTML nur mit Schutz-Headern, Remote-Inhalte nie geladen   AK-D7-8  Mandantentrennung    AK-D7-9  Rechte erlaubt/verboten
// AK-D7-10 zwei Worker: Extraktion genau einmal                      AK-D7-11 Schwellen/Korpus (ExtractionTests)   AK-D7-12 deterministisch, Neu-Lauf, Audit
// AK-D7-13 Felder in Liste/Details, Filter und Sortierung             AK-D7-14 HTML -> Text   AK-D7-15 Vorschläge, nichts angewendet
// AK-D7-16 DocumentFacts und Ereignis (Outbox)                         AK-D7-17 Migration

// MARK: - HTML -> Text (ohne Datenbank)

final class HTMLTextTests: XCTestCase {
    /// AK-D7-14: Entitäten, Tabellen als Zeilen, br/p/li, style/script verworfen, Remote-Inhalte erscheinen nie.
    func testAKD7_14_extractsTextFromHTML() {
        let html = """
        <!DOCTYPE html><html><head><title>Ignoriert</title><style>.a { color: red }</style><script>alert('x')</script></head>
        <body><!-- Kommentar -->
        <p>Guten Tag M&uuml;ller,<br>Ihre Rechnung &amp; Zahlungsinfo:</p>
        <img src="https://tracker.example.org/pixel.gif" alt="">
        <table><tr><td>Rechnungsnummer</td><td>4711</td></tr><tr><td>Gesamtbetrag</td><td>119,00&nbsp;&euro;</td></tr></table>
        <ul><li>Eins</li><li>Zwei &#8211; &#x20AC;</li></ul>
        <a href="https://remote.example.org/x">Link-Text</a><noscript>nope</noscript>
        </body></html>
        """
        let text = HTMLText.extract(html)
        XCTAssertEqual(text, "Guten Tag Müller,\nIhre Rechnung & Zahlungsinfo:\n\nRechnungsnummer | 4711\nGesamtbetrag | 119,00 €\n\n- Eins\n- Zwei – €\n\nLink-Text")
        for forbidden in ["tracker", "pixel", "alert", "color", "Ignoriert", "Kommentar", "remote.example.org", "nope"] { XCTAssertFalse(text.contains(forbidden), forbidden) }
    }

    /// AK-D7-14: robust gegen kaputtes und feindliches HTML (offene Tags, riesige Eingabe, tiefe Verschachtelung, unbekannte Entitäten).
    func testAKD7_14_robustAndBounded() {
        XCTAssertEqual(HTMLText.extract("a < b and c > d"), "a < b and c > d")
        XCTAssertEqual(HTMLText.extract("<p>offen"), "offen")
        XCTAssertEqual(HTMLText.extract("<script>alert(1)"), "", "fehlender Endtag: Rest entfällt")
        XCTAssertEqual(HTMLText.extract("x &unknown; y &#0; &#xD800; z"), "x &unknown; y &#0; &#xD800; z")
        let deep = String(repeating: "<div>", count: 50_000) + "Tief" + String(repeating: "</div>", count: 50_000)
        XCTAssertEqual(HTMLText.extract(deep), "Tief")
        let huge = String(repeating: "<p>Zeile mit Text</p>", count: 400_000)   // > 2 MiB
        let start = Date()
        let out = HTMLText.extract(huge)
        XCTAssertLessThan(Date().timeIntervalSince(start), 15)
        XCTAssertLessThanOrEqual(out.count, HTMLText.maxOutput)
        let longTag = "<a " + String(repeating: "x", count: 10_000) + ">Text</a>"
        XCTAssertTrue(HTMLText.extract(longTag).contains("Text"))
        let nul = HTMLText.extract("A\u{0}B<br>C")
        XCTAssertFalse(nul.contains("\u{0}"))
    }
}

// MARK: - Extraktion und Mail mit Datenbank

final class DMSExtractionTests: DMSRulesTestBase {
    static let vat = "DE123456789"

    // MARK: Hilfen

    func html(subject: String = "Ihre Rechnung Nr. 4711", seller: String = "Beispiel Shop GmbH", extraRows: String = "", remote: String = "") -> String {
        """
        <html><head><style>td { color: red }</style></head><body>
        <h1>Rechnung</h1><p>Vielen Dank für Ihre Bestellung bei \(seller).</p>
        <table>
        <tr><td>Rechnungsnummer</td><td>4711</td></tr>
        <tr><td>Rechnungsdatum</td><td>07.11.2026</td></tr>
        <tr><td>Fällig am</td><td>21.11.2026</td></tr>
        <tr><td>Nettobetrag</td><td>100,00 €</td></tr>
        <tr><td>MwSt 19 %</td><td>19,00 €</td></tr>
        <tr><td>Gesamtbetrag</td><td>119,00 €</td></tr>
        </table>\(extraRows)
        <p>Bitte überweisen Sie an IBAN DE89 3704 0044 0532 0130 00. USt-IdNr. \(Self.vat)</p>
        \(remote)</body></html>
        """
    }

    func mime(subject: String, id: String, html: String? = nil, text: String? = nil, attachments: [(String, String, Data)] = [], from: String = "Beispiel Shop <billing@example.org>") -> Data {
        var lines = ["From: \(from)", "To: mail@example.org", "Subject: \(subject)", "Message-ID: <\(id)@example.org>", "Date: Sun, 8 Nov 2026 10:00:00 +0100", "MIME-Version: 1.0",
                     "Content-Type: multipart/mixed; boundary=\"d7m\"", ""]
        if let text, let html {
            lines += ["--d7m", "Content-Type: multipart/alternative; boundary=\"d7a\"", "", "--d7a", "Content-Type: text/plain; charset=utf-8", "", text, "", "--d7a", "Content-Type: text/html; charset=utf-8", "", html, "", "--d7a--", ""]
        } else if let html { lines += ["--d7m", "Content-Type: text/html; charset=utf-8", "", html, ""] }
        else if let text { lines += ["--d7m", "Content-Type: text/plain; charset=utf-8", "", text, ""] }
        for (name, type, data) in attachments {
            lines += ["--d7m", "Content-Type: \(type); name=\"\(name)\"", "Content-Disposition: attachment; filename=\"\(name)\"", "Content-Transfer-Encoding: base64", "",
                      data.base64EncodedString(options: [.lineLength76Characters, .endLineWithCarriageReturn, .endLineWithLineFeed]), ""]
        }
        lines += ["--d7m--", ""]
        return Data(lines.joined(separator: "\r\n").utf8)
    }

    /// Eine Quelle (Ordner genügt: `process` braucht nur Mandant, ID und Ersteller) und der Konfigurationsstand.
    func mailSource(_ w: World, keep: String? = "relevant") async throws -> (DMSSourceRow, MailSourceConfig) {
        let r = try await call(app1, .POST, base(w.tenantA) + "/sources", json: ["kind": "folder", "name": "Test \(UUID().uuidString.prefix(6))", "config": ["path": "scan"]], token: w.alice.token)
        XCTAssertEqual(r.status, .created, "\(r.json)")
        let row = try await DMSSources.row(UUID(uuidString: r.json["id"] as! String)!, tenant: UUID(uuidString: w.tenantA)!, on: sql(app1.db(.psql)))!
        let config = MailSourceConfig(host: "127.0.0.1", port: 993, username: "x", mailbox: "INBOX", processed_mailbox: nil, interval_seconds: 60, include_body: false, sender_contains: nil,
                                      subject_contains: nil, max_per_run: 50, keep_mail: keep)
        return (row, config)
    }

    func ingest(_ raw: Data, _ w: World, _ source: (DMSSourceRow, MailSourceConfig), ocr: Bool = false) async throws -> DMSMailPoll.MessageResult {
        var l = DMSSourceLimits(); l.maxUploadBytes = Self.uploadLimit; l.ocrEnabled = ocr
        return try await DMSMailPoll.process(raw: raw, source: source.0, config: source.1, limits: l, objectStore: ObjectStoreConfig(kind: .db), db: app1.db(.psql), requestID: "d7-test")
    }

    func docs(_ w: World, query: String = "") async throws -> [[String: Any]] {
        items(try await call(app1, .GET, base(w.tenantA) + "/documents?limit=200" + query, token: w.alice.token))
    }

    func mailDoc(_ w: World) async throws -> String {
        try await scalar("SELECT d.id::text AS v FROM dms_documents d JOIN dms_document_files f ON f.document_id = d.id AND f.role = 'original' WHERE d.tenant_id = '\(w.tenantA)' AND f.mime = 'message/rfc822' ORDER BY d.created_at DESC LIMIT 1", as: String.self)
    }

    func extraction(_ w: World, _ doc: String, via: Application? = nil) async throws -> Resp {
        try await call(via ?? app1, .GET, base(w.tenantA) + "/documents/\(doc)/extraction", token: w.alice.token)
    }

    // MARK: WP-H10

    /// AK-H10-4: Meta-Refresh, `<base>`, `<link>` und Formular-Aktionen werden im gespeicherten HTML-Derivat entschärft; das Original (.eml) bleibt byte-identisch.
    func testAKH10_4_htmlDerivativeIsNeutralized() async throws {
        let w = try await world()
        let source = try await mailSource(w)
        let hostile = #"<meta http-equiv="refresh" content="0;url=https://evil.example.org/x"><META HTTP-EQUIV=Refresh CONTENT='0; URL=https://evil.example.org/y'><base href="https://evil.example.org/"><link rel="prefetch" href="https://evil.example.org/p"><me<meta>ta http-equiv=refresh content="0;url=https://evil.example.org/z"><form action="https://evil.example.org/post" method="post"><button formaction="https://evil.example.org/other">Senden</button></form>"#
        let eml = mime(subject: "Ihre Rechnung Nr. 4711", id: "inv-h10-4", html: html(remote: hostile))
        let r = try await ingest(eml, w, source)
        XCTAssertEqual(r.ingested, 1); XCTAssertEqual(r.failed, 0)
        let doc = try await mailDoc(w)
        let h = try await raw(app1, .GET, base(w.tenantA) + "/documents/\(doc)/file?role=derivative", token: w.alice.token)
        XCTAssertEqual(h.status, .ok)
        let body = String(decoding: h.body, as: UTF8.self).lowercased()
        XCTAssertTrue(body.contains("<h1>rechnung</h1>"), "Inhalt bleibt")
        for forbidden in ["<meta", "http-equiv", "refresh", "<base", "<link", "<form", "</form", "action=", "evil.example.org/x", "evil.example.org/post", "evil.example.org/other"] {
            XCTAssertFalse(body.contains(forbidden), "Derivat enthält noch \(forbidden)")
        }
        let csp = h.headers.first(name: "Content-Security-Policy") ?? ""
        for directive in ["default-src 'none'", "sandbox", "frame-src 'none'", "base-uri 'none'", "form-action 'none'"] { XCTAssertTrue(csp.contains(directive), directive) }
        let original = try await raw(app1, .GET, base(w.tenantA) + "/documents/\(doc)/file", token: w.alice.token)
        XCTAssertEqual(original.body, eml, "das Original bleibt unverändert")
    }

    func testAKH10_4_neutralizeUnit() {
        let cases = ["<meta http-equiv=refresh content=0;url=x>", "<META\nHTTP-EQUIV='refresh'>", "<base href=//x>", "<link rel=a href=b>", "<me<meta>ta http-equiv=refresh>", "<meta/http-equiv=refresh>",
                     "<form action=x><input formaction=y></form>", "<FORM\tACTION=\"x\">", "<<meta http-equiv=refresh>"]
        for c in cases {
            let out = HTMLSafety.neutralize(c).lowercased()
            for f in ["<meta", "refresh", "<base", "<link", "<form", "action"] { XCTAssertFalse(out.contains(f), "\(c) -> \(out)") }
        }
        XCTAssertEqual(HTMLSafety.neutralize("<p>Hallo <b>Welt</b> &amp; Co. <a href=\"https://example.org\">Link</a></p>"), "<p>Hallo <b>Welt</b> &amp; Co. <a href=\"https://example.org\">Link</a></p>")
        let t0 = Date()
        _ = HTMLSafety.neutralize(String(repeating: "<meta ", count: 50_000) + String(repeating: "a", count: 100_000))
        _ = HTMLSafety.neutralize(String(repeating: "action=\"", count: 50_000))
        XCTAssertLessThan(Date().timeIntervalSince(t0), 5)
    }

    // MARK: AK-D7-1 / AK-D7-2 / AK-D7-7

    /// AK-D7-2: HTML-Mail ohne Anhang -> Rechnung mit richtigen Feldern, Text im Suchindex, HTML als Derivat. AK-D7-1: Original byte-identisch, in der Datenbank unveränderlich.
    /// AK-D7-7: Auslieferung des HTML nur mit Schutz-Headern.
    func testAKD7_1_2_7_htmlMailInvoiceWithoutAttachment() async throws {
        let w = try await world()
        let source = try await mailSource(w)
        let remote = #"<img src="https://tracker.example.org/pixel.gif?u=1"><link rel="stylesheet" href="https://remote.example.org/a.css"><script>fetch('https://remote.example.org/x')</script>"#
        let eml = mime(subject: "Ihre Rechnung Nr. 4711", id: "inv-4711", html: html(remote: remote))
        let r = try await ingest(eml, w, source)
        XCTAssertEqual(r.ingested, 1); XCTAssertEqual(r.failed, 0)
        let doc = try await mailDoc(w)

        // Original byte-identisch (Hash und Download), Rolle original, Mime message/rfc822
        let download = try await raw(app2, .GET, base(w.tenantA) + "/documents/\(doc)/file", token: w.alice.token)
        XCTAssertEqual(download.status, .ok)
        XCTAssertEqual(download.body, eml)
        XCTAssertEqual(download.headers.first(name: .contentType), "message/rfc822")
        XCTAssertEqual(download.headers.first(name: "Content-Security-Policy"), "default-src 'none'; sandbox; frame-src 'none'; base-uri 'none'; form-action 'none'")
        let storedHash = try await scalar("SELECT sha256 AS v FROM dms_document_files WHERE document_id = '\(doc)' AND role = 'original'", as: String.self)
        XCTAssertEqual(storedHash, SHA256.hash(data: eml).map { String(format: "%02x", $0) }.joined())
        // unveränderlich (Trigger auf Datenbankebene)
        let sqlDB = try sql(app1.db(.psql))
        do { try await sqlDB.raw("UPDATE dms_document_files SET sha256 = repeat('0', 64) WHERE document_id = \(bind: UUID(uuidString: doc)!) AND role = 'original'").run(); XCTFail("Original änderbar") } catch {}
        do { try await sqlDB.raw("DELETE FROM dms_document_files WHERE document_id = \(bind: UUID(uuidString: doc)!) AND role = 'original'").run(); XCTFail("Original löschbar") } catch {}

        // Erkennung und Felder
        let e = try await extraction(w, doc)
        XCTAssertEqual(e.status, .ok, "\(e.json)")
        XCTAssertEqual(e.json["kind"] as? String, "invoice"); XCTAssertEqual(e.json["kind_certain"] as? Bool, true)
        XCTAssertEqual(e.json["amount"] as? String, "119.00"); XCTAssertEqual(e.json["currency"] as? String, "EUR")
        XCTAssertEqual(e.json["extracted_date"] as? String, "2026-11-07"); XCTAssertEqual(e.json["due_date"] as? String, "2026-11-21"); XCTAssertEqual(e.json["reference"] as? String, "4711")
        let invoice = try XCTUnwrap(e.json["invoice"] as? [String: Any])
        XCTAssertEqual(invoice["number"] as? String, "4711"); XCTAssertEqual(invoice["gross"] as? String, "119.00"); XCTAssertEqual(invoice["net"] as? String, "100.00"); XCTAssertEqual(invoice["tax"] as? String, "19.00")
        XCTAssertEqual(invoice["seller_iban"] as? String, ExtractionCorpus.ibanDE); XCTAssertEqual(invoice["seller_vat_id"] as? String, Self.vat); XCTAssertEqual(invoice["seller_name"] as? String, "Beispiel Shop GmbH")
        let facts = try XCTUnwrap(e.json["facts"] as? [[String: Any]])
        XCTAssertTrue(facts.allSatisfy { ($0["reason"] as? String)?.isEmpty == false && $0["confidence"] is Double })
        XCTAssertNotNil(facts.first { $0["type"] as? String == "amount_gross" }?["source"] as? [String: Any])
        // Details und Liste tragen die Felder
        let detail = try await docJSON(w, doc)
        XCTAssertEqual((detail["extraction"] as? [String: Any])?["kind"] as? String, "invoice")
        XCTAssertNotNil((detail["extraction"] as? [String: Any])?["facts"])
        let listed = try await docs(w).first { ($0["id"] as? String)?.lowercased() == doc.lowercased() }
        XCTAssertEqual((listed?["extraction"] as? [String: Any])?["amount"] as? String, "119.00")
        XCTAssertNil((listed?["extraction"] as? [String: Any])?["facts"], "Liste ohne Faktenliste")
        // Text im Suchindex (aus HTML abgeleitet, ohne Remote-Inhalte)
        let text = try await scalar("SELECT text AS v FROM dms_document_texts WHERE document_id = '\(doc)'", as: String.self)
        XCTAssertTrue(text.contains("Rechnungsnummer | 4711")); XCTAssertTrue(text.hasPrefix("Betreff: Ihre Rechnung Nr. 4711"))
        for s in ["tracker.example.org", "remote.example.org", "fetch(", "color: red"] { XCTAssertFalse(text.contains(s), s) }
        let hit = try await call(app1, .GET, base(w.tenantA) + "/search?q=Gesamtbetrag&fuzzy=false", token: w.alice.token)
        XCTAssertEqual(items(hit).count, 1, "\(hit.json)")
        try await aEq(try await scalar("SELECT state AS v FROM dms_ingest_items WHERE document_id = '\(doc)'", as: String.self), "done")

        // HTML-Derivat: Rolle derivative, nur mit Schutz-Headern (auch inline), Remote-Verweise nur als gespeicherte Bytes, nie geladen
        let files = (detail["files"] as? [[String: Any]])?.compactMap { $0["role"] as? String }
        XCTAssertEqual(Set(files ?? []), ["original", "derivative"])
        for disposition in ["attachment", "inline"] {
            let h = try await raw(app2, .GET, base(w.tenantA) + "/documents/\(doc)/file?role=derivative&disposition=\(disposition)", token: w.alice.token)
            XCTAssertEqual(h.status, .ok)
            XCTAssertEqual(h.headers.first(name: "Content-Security-Policy"), "default-src 'none'; sandbox; frame-src 'none'; base-uri 'none'; form-action 'none'")
            XCTAssertEqual(h.headers.first(name: "X-Content-Type-Options"), "nosniff")
            XCTAssertEqual(h.headers.first(name: .contentType), "text/html; charset=utf-8")
            XCTAssertTrue(h.headers.first(name: .contentDisposition)?.hasPrefix(disposition) == true)
            XCTAssertEqual(h.headers.first(name: .cacheControl), "private, no-store")
            XCTAssertTrue(String(decoding: h.body, as: UTF8.self).contains("<h1>Rechnung</h1>"))
        }
        let noToken = try await raw(app1, .GET, base(w.tenantA) + "/documents/\(doc)/file?role=derivative", token: "")
        XCTAssertEqual(noToken.status.code, 401)
    }

    // MARK: AK-D7-3 / AK-D7-6

    /// AK-D7-3: PDF-Anhang wird (nach OCR/Textschicht) als Rechnung erkannt und mit der Mail verknüpft; AK-D7-6: Wiederholung desselben Poll-Inhalts erzeugt nichts doppelt.
    func testAKD7_3_6_pdfAttachmentRecognizedLinkedAndIdempotent() async throws {
        let w = try await world()
        let source = try await mailSource(w, keep: "always")
        let engine = ScriptedOCREngine()
        engine.set("anhang-1", ExtractionCorpus.invoices[0].text)
        let raw = mime(subject: "Rechnung RE-2026-0042", id: "pdf-1", text: "Guten Tag, anbei die Rechnung.", attachments: [("Rechnung.pdf", "application/pdf", pdf("anhang-1"))])
        let r1 = try await ingest(raw, w, source, ocr: true)
        XCTAssertEqual(r1.ingested, 2, "Mail + Anhang"); XCTAssertEqual(r1.failed, 0)
        try await drain(engine)
        let attachment = try await scalar("SELECT d.id::text AS v FROM dms_documents d JOIN dms_document_files f ON f.document_id = d.id AND f.role = 'original' WHERE f.mime = 'application/pdf'", as: String.self)
        let mail = try await mailDoc(w)
        let e = try await extraction(w, attachment)
        XCTAssertEqual(e.json["kind"] as? String, "invoice"); XCTAssertEqual(e.json["amount"] as? String, "178.50"); XCTAssertEqual(e.json["reference"] as? String, "RE-2026-0042")
        // Verknüpfung Anhang -> Mail
        try await aEq(try await count("links", where: "from_type = 'dms.document' AND from_id = '\(attachment)' AND to_type = 'dms.document' AND to_id = '\(mail)' AND kind = 'mail_attachment' AND source = 'system' AND removed_at IS NULL"), 1)
        // Wiederholung (neu eingeliefert, gleiche Message-ID): keine neuen Dokumente, Links, Texte, Ereignisse
        let before = try await scalar("SELECT concat_ws('|', (SELECT count(*) FROM dms_documents), (SELECT count(*) FROM links), (SELECT count(*) FROM dms_document_texts), (SELECT count(*) FROM dms_event_outbox), (SELECT count(*) FROM dms_suggestions)) AS v", as: String.self)
        let r2 = try await ingest(raw, w, source, ocr: true)
        XCTAssertEqual(r2.ingested, 0); XCTAssertEqual(r2.duplicates, 2); XCTAssertEqual(r2.failed, 0)
        let after = try await scalar("SELECT concat_ws('|', (SELECT count(*) FROM dms_documents), (SELECT count(*) FROM links), (SELECT count(*) FROM dms_document_texts), (SELECT count(*) FROM dms_event_outbox), (SELECT count(*) FROM dms_suggestions)) AS v", as: String.self)
        XCTAssertEqual(before, after)
        // gleicher Anhang in einer anderen Mail: eigenes Mail-Dokument, Anhang bleibt Duplikat-Hinweis der Quelle? (anderer Message-ID-Schlüssel = neues Element)
        let other = mime(subject: "Rechnung RE-2026-0042 (Kopie)", id: "pdf-2", text: "Kopie", attachments: [("Rechnung.pdf", "application/pdf", pdf("anhang-1"))])
        let r3 = try await ingest(other, w, source, ocr: true)
        XCTAssertEqual(r3.ingested, 2)
        try await aEq(try await count("dms_documents"), 4)
        try await aEq(try await count("links", where: "kind = 'mail_attachment'"), 2)
    }

    /// Standardmodus `relevant`: eine Mail mit erkanntem Mailtext wird abgelegt, eine Alltagsmail nicht; Anhänge werden wie in D4 immer aufgenommen.
    func testRelevantModeStoresOnlyRecognizedMails() async throws {
        let w = try await world()
        let source = try await mailSource(w)
        _ = try await ingest(mime(subject: "Hallo", id: "plain-1", text: "Wir treffen uns morgen um zehn."), w, source)
        try await aEq(try await count("dms_documents"), 0, "Alltagsmail: weder Dokument noch Anhang")
        _ = try await ingest(mime(subject: "Fotos", id: "plain-2", text: "Anbei die Fotos.", attachments: [("foto.png", "image/png", png("d7"))]), w, source)
        try await aEq(try await count("dms_documents"), 1, "nur der Anhang, kein Mail-Original")
        try await aEq(try await count("dms_document_files", where: "mime = 'message/rfc822'"), 0)
        let never = try await mailSource(w, keep: "never")
        _ = try await ingest(mime(subject: "Ihre Rechnung Nr. 4711", id: "never-1", html: html()), w, never)
        try await aEq(try await count("dms_document_files", where: "mime = 'message/rfc822'"), 0, "keep_mail=never")
        // Konfiguration: Wert wird geprüft
        let bad = try await call(app1, .POST, base(w.tenantA) + "/sources", json: ["kind": "folder", "name": "x", "config": ["path": "scan", "keep_mail": "x"]], token: w.alice.token)
        XCTAssertEqual(bad.status, .unprocessableEntity)
    }

    // MARK: AK-D7-4

    /// AK-D7-4: Newsletter, Versandbestätigung, Mahnung und Spam mit „Rechnung“ im Betreff werden nie als Rechnung markiert (Modus `always`, damit sie sichtbar sind).
    func testAKD7_4_negativeMailsAreNeverInvoices() async throws {
        let w = try await world()
        let source = try await mailSource(w, keep: "always")
        var n = 0
        for c in ExtractionCorpus.others {
            n += 1
            let bodyHTML = "<html><body><p>" + c.text.replacingOccurrences(of: "\n", with: "<br>") + "</p></body></html>"
            _ = try await ingest(mime(subject: c.subject ?? c.name, id: "neg-\(n)", html: bodyHTML), w, source)
        }
        try await aEq(try await count("dms_document_files", where: "mime = 'message/rfc822'"), Int64(ExtractionCorpus.others.count))
        try await aEq(try await count("dms_extractions", where: "kind = 'invoice' AND kind_certain"), 0, "keine Falsch-Positive")
        try await aEq(try await count("dms_extractions", where: "kind = 'reminder'"), 3, "Mahnungen werden als Mahnung erkannt")
        let invoices = try await docs(w, query: "&kind=invoice&kind_certain=true")
        XCTAssertTrue(invoices.isEmpty)
    }

    // MARK: AK-D7-10 / AK-D7-12 / AK-D7-16

    /// AK-D7-10: 12 Dokumente, zwei Worker: je Dokument genau eine Extraktion (runs = 1), ein Ereignis, Vorschläge ohne Doppelte.
    func testAKD7_10_twoWorkersExtractExactlyOnce() async throws {
        let w = try await world()
        _ = try await makeType(w, "Rechnung")
        let engine = ScriptedOCREngine()
        var ids: [String] = []
        for i in 0..<12 { ids.append(try await uploadText(w, engine, seed: "zw-\(i)", text: ExtractionCorpus.invoices[0].text.replacingOccurrences(of: "RE-2026-0042", with: "RE-2026-1\(i)"))) }
        try await drain(engine, workers: 2)
        try await aEq(try await count("dms_extractions"), 12)
        try await aEq(try await count("dms_extractions", where: "runs = 1"), 12)
        try await aEq(try await count("dms_event_outbox", where: "type = 'dms.document.classified'"), 12)
        for id in ids { try await aEq(try await count("dms_suggestions", where: "document_id = '\(id)' AND source = 'extraction' AND kind = 'type'"), 1, id) }
        try await aEq(try await auditCount("dms.extraction.completed", tenant: w.tenantA), 12)
    }

    /// AK-D7-12: Neu-Lauf (Recht dms.document.update, Audit) ist idempotent und deterministisch; AK-D7-16: stabile Leseschnittstelle `DocumentFacts` und Outbox-Ereignis.
    func testAKD7_12_16_rerunIsIdempotentAuditedAndFactsInterface() async throws {
        let w = try await world()
        _ = try await makeType(w, "Rechnung")
        let engine = ScriptedOCREngine()
        let doc = try await uploadText(w, engine, seed: "rerun", text: ExtractionCorpus.invoices[0].text)
        try await drain(engine)
        let first = try await extraction(w, doc)
        let outbox = try await count("dms_event_outbox")
        let suggestionsBefore = try await count("dms_suggestions")
        for _ in 0..<2 {
            let r = try await call(app2, .POST, base(w.tenantA) + "/documents/\(doc)/extraction/run", token: w.alice.token)
            XCTAssertEqual(r.status, .ok, "\(r.json)")
            XCTAssertEqual(r.json["facts"] as? [[String: Any]] != nil, true)
            XCTAssertEqual(NSDictionary(dictionary: r.json.filter { $0.key != "updated_at" }), NSDictionary(dictionary: first.json.filter { $0.key != "updated_at" }), "gleicher Text = gleiches Ergebnis")
        }
        try await aEq(try await count("dms_extractions", where: "document_id = '\(doc)' AND runs = 3"), 1)
        try await aEq(try await count("dms_event_outbox"), outbox, "Ereignis je (Version, Text, Art) genau einmal")
        try await aEq(try await count("dms_suggestions"), suggestionsBefore, "keine doppelten Vorschläge")
        try await aEq(try await auditCount("dms.extraction.rerun", tenant: w.tenantA), 2)
        try await aEq(try await scalar("SELECT extractor_version::int AS v FROM dms_extractions WHERE document_id = '\(doc)'", as: Int.self), ExtractionResult.version)

        // DocumentFacts (interne Schnittstelle für andere Module)
        let facts = try await DMSExtraction.loadFacts(document: UUID(uuidString: doc)!, tenant: UUID(uuidString: w.tenantA)!, on: sql(app1.db(.psql)))
        let profile = try XCTUnwrap(facts?.invoice)
        XCTAssertEqual(profile, InvoiceProfile(number: "RE-2026-0042", issue_date: "2026-11-08", due_date: "2026-11-22", gross: "178.50", net: "150.00", tax: "28.50", currency: "EUR",
                                                seller_name: "Muster Werkstatt GmbH", seller_iban: ExtractionCorpus.ibanDE, seller_vat_id: Self.vat))
        let payload = try await scalar("SELECT payload::text AS v FROM dms_event_outbox WHERE subject_id = '\(doc)'", as: String.self)
        XCTAssertTrue(payload.contains("\"kind\": \"invoice\"") || payload.contains("\"kind\":\"invoice\""), payload)
        try await aEq(try await count("dms_event_outbox", where: "subject_id = '\(doc)' AND delivered_at IS NULL"), 1)
        // Nicht-Rechnung: kein Rechnungsprofil
        let other = try await uploadText(w, engine, seed: "vertrag", text: ExtractionCorpus.all.first { $0.name == "vertrag" }!.text)
        try await drain(engine)
        let f2 = try await DMSExtraction.loadFacts(document: UUID(uuidString: other)!, tenant: UUID(uuidString: w.tenantA)!, on: sql(app1.db(.psql)))
        XCTAssertEqual(f2?.kind, .contract); XCTAssertNil(f2?.invoice)
        // Papierkorb: 409; Dokument ohne Text: 409
        _ = try await call(app1, .POST, base(w.tenantA) + "/documents/\(doc)/trash", json: ["reason": "Test"], token: w.alice.token)
        let trashed = try await call(app1, .POST, base(w.tenantA) + "/documents/\(doc)/extraction/run", token: w.alice.token)
        XCTAssertEqual(trashed.status, .conflict)
    }

    // MARK: AK-D7-13

    /// AK-D7-13: Betrag, Währung, Datum, Fälligkeit, Referenz, Art in Liste/Details; Filter und Sortierung (mit Cursor über mehrere Seiten); fehlende Werte am Ende.
    func testAKD7_13_listFieldsFilterAndSort() async throws {
        let w = try await world()
        let engine = ScriptedOCREngine()
        func inv(_ n: String, _ amount: String, _ date: String, _ due: String?, _ cur: String = "EUR") -> String {
            "Rechnung\nRechnungsnummer: \(n)\nRechnungsdatum: \(date)\n" + (due.map { "Fällig am: \($0)\n" } ?? "") + "Gesamtbetrag \(amount) \(cur)"
        }
        var d: [String: String] = [:]
        d["a"] = try await uploadText(w, engine, seed: "l-a", text: inv("A-1", "300,00", "01.11.2026", "15.11.2026"))
        d["b"] = try await uploadText(w, engine, seed: "l-b", text: inv("B-2", "1.000,50", "03.11.2026", nil))
        d["c"] = try await uploadText(w, engine, seed: "l-c", text: inv("C-3", "45,10", "02.11.2026", "10.11.2026"))
        d["d"] = try await uploadText(w, engine, seed: "l-d", text: inv("D-4", "2.000,00", "04.11.2026", "01.12.2026", "USD"))
        d["x"] = try await uploadText(w, engine, seed: "l-x", text: "Hallo Welt ohne Struktur")
        try await drain(engine)
        let key = Dictionary(uniqueKeysWithValues: d.map { ($1, $0) })
        func order(_ q: String) async throws -> [String] { try await docs(w, query: q).compactMap { key[$0["id"] as? String ?? ""] } }
        func paged(_ q: String) async throws -> [String] {
            var out: [String] = [], cursor: String? = nil
            for _ in 0..<10 {
                let r = try await call(app1, .GET, base(w.tenantA) + "/documents?limit=2\(q)" + (cursor.map { "&cursor=\($0)" } ?? ""), token: w.alice.token)
                XCTAssertEqual(r.status, .ok, "\(r.json)")
                out += items(r).compactMap { key[$0["id"] as? String ?? ""] }
                guard let next = r.json["next_cursor"] as? String else { break }
                cursor = next
            }
            return out
        }
        let amountAsc = try await order("&sort=amount&order=asc"), amountDesc = try await order("&sort=amount&order=desc")
        XCTAssertEqual(amountAsc, ["c", "a", "b", "d", "x"]); XCTAssertEqual(amountDesc, ["d", "b", "a", "c", "x"])
        let dateAsc = try await order("&sort=extracted_date"), dueAsc = try await order("&sort=due_date"), dueDesc = try await order("&sort=due_date&order=desc")
        XCTAssertEqual(dateAsc, ["a", "c", "b", "d", "x"])
        XCTAssertEqual(Array(dueAsc.prefix(3)), ["c", "a", "d"]); XCTAssertEqual(Set(dueAsc.suffix(2)), ["b", "x"], "fehlende Fälligkeit am Ende")
        XCTAssertEqual(Array(dueDesc.prefix(3)), ["d", "a", "c"]); XCTAssertEqual(Set(dueDesc.suffix(2)), ["b", "x"])
        let pagedAmount = try await paged("&sort=amount&order=desc"), pagedDue = try await paged("&sort=due_date")
        XCTAssertEqual(pagedAmount, amountDesc, "Cursor über Seiten, nichts doppelt oder verloren"); XCTAssertEqual(pagedDue, dueAsc)
        XCTAssertEqual(Set(pagedDue).count, 5)
        // Filter
        let kindInvoice = try await order("&kind=invoice&sort=amount"), kindOther = try await order("&kind=other")
        XCTAssertEqual(kindInvoice, ["c", "a", "b", "d"]); XCTAssertEqual(kindOther, ["x"])
        let usd = try await order("&currency=USD"), range = try await order("&amount_min=100&amount_max=1000.50&sort=amount")
        XCTAssertEqual(usd, ["d"]); XCTAssertEqual(range, ["a", "b"])
        let dueTo = try await order("&due_to=2026-11-15&sort=due_date"), extracted = try await order("&extracted_from=2026-11-02&extracted_to=2026-11-03&sort=extracted_date")
        XCTAssertEqual(dueTo, ["c", "a"]); XCTAssertEqual(extracted, ["c", "b"])
        let ref = try await order("&reference=C-3"), certain = try await order("&kind=invoice&kind_certain=true&sort=amount&order=desc")
        XCTAssertEqual(ref, ["c"]); XCTAssertEqual(certain, ["d", "b", "a", "c"])
        let first = try await docs(w, query: "&sort=amount&order=desc").first
        XCTAssertEqual((first?["extraction"] as? [String: Any])?["amount"] as? String, "2000.00")
        XCTAssertEqual((first?["extraction"] as? [String: Any])?["currency"] as? String, "USD")
        for bad in ["kind=zzz", "currency=eur", "amount_min=1e3", "due_to=2026-13-01", "sort=title", "order=up", "kind_certain=maybe"] {
            let r = try await call(app1, .GET, base(w.tenantA) + "/documents?\(bad)", token: w.alice.token)
            XCTAssertEqual(r.status, .unprocessableEntity, bad)
        }
    }

    // MARK: AK-D7-15

    /// AK-D7-15: Vorschläge (Dokumenttyp, Datum, Titel, Korrespondent über USt-ID) mit Quelle und Begründung; nichts wird still angewendet; Annahme wirkt; ohne Typ im Mandanten kein Typ-Vorschlag.
    func testAKD7_15_suggestionsAreNotApplied() async throws {
        let w = try await world()
        let engine = ScriptedOCREngine()
        // erst ohne Typ im Mandanten
        let noType = try await uploadText(w, engine, seed: "s-0", text: ExtractionCorpus.invoices[0].text, query: "filename=scan0.pdf&title=scan0")
        try await drain(engine)
        let type = try await makeType(w, "Eingangsrechnung")
        let contact = try await makeContact(w, ["kind": "organization", "display_name": "Muster Werkstatt GmbH", "vat_id": Self.vat])
        let doc = try await uploadText(w, engine, seed: "s-1", text: ExtractionCorpus.invoices[0].text)
        try await drain(engine)
        try await aEq(try await suggestions(w, doc: noType).filter { $0["kind"] as? String == "type" }.count, 0, "kein Typ angelegt: nichts vorschlagen")
        let list = try await suggestions(w, doc: doc)
        let byKind = Dictionary(grouping: list, by: { $0["kind"] as! String })
        XCTAssertEqual(byKind["type"]?.first?["source"] as? String, "extraction")
        XCTAssertEqual((byKind["type"]?.first?["value"] as? [String: Any])?["document_type_id"] as? String, type.lowercased())
        XCTAssertEqual((byKind["date"]?.first?["value"] as? [String: Any])?["doc_date"] as? String, "2026-11-08")
        XCTAssertEqual(byKind["correspondent"]?.first?["source"] as? String, "contact_match")
        XCTAssertEqual((byKind["correspondent"]?.first?["value"] as? [String: Any])?["contact_id"] as? String, contact.lowercased())
        for s in list where s["source"] as? String == "extraction" { XCTAssertEqual(s["state"] as? String, "open"); XCTAssertFalse((s["reason"] as? String ?? "").isEmpty) }
        let d = try await docJSON(w, doc)
        XCTAssertNil(d["document_type_id"] as? String); XCTAssertNil(d["doc_date"] as? String); XCTAssertNil(d["correspondent_id"] as? String)
        // Annehmen wirkt
        let typeSuggestion = byKind["type"]!.first!["id"] as! String
        let accepted = try await call(app1, .POST, base(w.tenantA) + "/suggestions/\(typeSuggestion)/accept", token: w.alice.token)
        XCTAssertEqual(accepted.status, .ok, "\(accepted.json)")
        try await aEq(try await docJSON(w, doc)["document_type_id"] as? String, type)
    }

    // MARK: AK-D7-8 / AK-D7-9

    func testAKD7_8_tenantIsolation() async throws {
        let w = try await world()
        let tenantB = (try await call(app1, .POST, "api/v1/tenants", json: ["name": "Zweiter Mandant"], token: w.alice.token)).json["id"] as! String
        let carol = try await addUser("owner", handle: "carol", tenant: tenantB, by: w.alice)
        try await setModule(tenantB, true, by: carol)
        let source = try await mailSource(w)
        let raw = mime(subject: "Ihre Rechnung Nr. 4711", id: "iso-1", html: html())
        _ = try await ingest(raw, w, source)
        let doc = try await mailDoc(w)
        let b = base(tenantB)
        for (m, p) in [(HTTPMethod.GET, "/documents/\(doc)/extraction"), (.POST, "/documents/\(doc)/extraction/run"), (.GET, "/documents/\(doc)"), (.GET, "/documents/\(doc)/file?role=derivative")] {
            let r = try await call(app2, m, b + p, token: carol.token)
            XCTAssertEqual(r.status, .notFound, "\(m) \(p)")
        }
        try await aEq(items(try await call(app2, .GET, b + "/documents?kind=invoice", token: carol.token)).count, 0)
        // Datenbank: Extraktion in B für ein Dokument aus A scheitert am zusammengesetzten Fremdschlüssel
        do {
            try await sql(app1.db(.psql)).raw("""
                INSERT INTO dms_extractions (document_id, tenant_id, extractor_version, text_sha256, kind, kind_score, kind_certain, kind_reasons, scores, facts)
                VALUES (\(bind: UUID(uuidString: doc)!), \(bind: UUID(uuidString: tenantB)!), 1, repeat('a', 64), 'invoice', 0.9, true, '[]'::jsonb, '[]'::jsonb, '[]'::jsonb)
                """).run()
            XCTFail("Fremdschlüssel über Mandantengrenze")
        } catch {}
        // dieselbe Mail in B ist ein eigenes Dokument, nichts wird über Mandanten als Duplikat oder Idempotenz gewertet
        let r = try await call(app1, .POST, b + "/sources", json: ["kind": "folder", "name": "B", "config": ["path": "scan"]], token: carol.token)
        let rowB = try await DMSSources.row(UUID(uuidString: r.json["id"] as! String)!, tenant: UUID(uuidString: tenantB)!, on: sql(app1.db(.psql)))!
        var l = DMSSourceLimits(); l.maxUploadBytes = Self.uploadLimit; l.ocrEnabled = false
        let res = try await DMSMailPoll.process(raw: raw, source: rowB, config: source.1, limits: l, objectStore: ObjectStoreConfig(kind: .db), db: app1.db(.psql), requestID: "d7-b")
        XCTAssertEqual(res.ingested, 1)
        try await aEq(try await count("dms_extractions", where: "tenant_id = '\(tenantB)'"), 1)
        try await aEq(try await count("dms_extractions", where: "tenant_id = '\(w.tenantA)'"), 1)
    }

    func testAKD7_9_permissions() async throws {
        let w = try await world()
        let source = try await mailSource(w)
        _ = try await ingest(mime(subject: "Ihre Rechnung Nr. 4711", id: "perm-1", html: html()), w, source)
        let doc = try await mailDoc(w)
        let tax = try await addUser("tax_advisor", handle: "tax", tenant: w.tenantA, by: w.alice)
        let member = try await addUser("member", handle: "mem", tenant: w.tenantA, by: w.alice)
        let viewer = try await addUser("customer_viewer", handle: "view", tenant: w.tenantA, by: w.alice)
        let p = base(w.tenantA) + "/documents/\(doc)/extraction"
        let before = try await scalar("SELECT runs::int AS v FROM dms_extractions WHERE document_id = '\(doc)'", as: Int.self)
        let read = try await call(app1, .GET, p, token: tax.token); XCTAssertEqual(read.status, .ok)
        let readViewer = try await call(app1, .GET, p, token: viewer.token); XCTAssertEqual(readViewer.status, .forbidden)
        for s in [tax, viewer] {
            let r = try await call(app1, .POST, p + "/run", token: s.token)
            XCTAssertEqual(r.status, .forbidden)
        }
        try await aEq(try await scalar("SELECT runs::int AS v FROM dms_extractions WHERE document_id = '\(doc)'", as: Int.self), before, "verboten ändert nichts")
        try await aEq(try await auditCount("dms.extraction.rerun", tenant: w.tenantA), 0)
        let ok = try await call(app1, .POST, p + "/run", token: member.token); XCTAssertEqual(ok.status, .ok, "\(ok.json)")
        let anon = try await call(app1, .GET, p); XCTAssertEqual(anon.status, .unauthorized)
        try await aEq(try await auditCount("dms.extraction.rerun", tenant: w.tenantA), 1)
    }

    // MARK: AK-D7-17

    func testAKD7_17_migrationRevertAndReapply() async throws {
        let w = try await world()
        let engine = ScriptedOCREngine()
        _ = try await makeType(w, "Rechnung")
        _ = try await uploadText(w, engine, seed: "mig", text: ExtractionCorpus.invoices[0].text)
        try await drain(engine)
        try await aEq(try await count("dms_suggestions", where: "source = 'extraction'") > 0, true)
        try await CreateDMSExtraction().revert(on: app1.db(.psql))
        try await aEq(try await count("information_schema.tables", where: "table_name IN ('dms_extractions', 'dms_event_outbox')"), 0)
        try await aEq(try await count("dms_suggestions", where: "source = 'extraction'"), 0)
        try await CreateDMSExtraction().prepare(on: app1.db(.psql))
        try await aEq(try await count("information_schema.tables", where: "table_name IN ('dms_extractions', 'dms_event_outbox')"), 2)
        XCTAssertNotNil(DMSPurge.childTables.firstIndex(of: "dms_extractions"))
    }
}
