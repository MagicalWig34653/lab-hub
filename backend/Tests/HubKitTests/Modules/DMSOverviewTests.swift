import XCTVapor
import Fluent
import SQLKit
@testable import HubKit

// WP-D9: Backend-Lücken der Dokumentübersicht. Alles synthetisch (erfundene Titel, example.org).
// AK-D9-1 Summen je Währung (Filter, Mandant, Papierkorb)     AK-D9-2 Quelle (Befüllung, Filter, Backfill)
// AK-D9-3 Suche: Felder, Filter und Sortierung wie /documents  AK-D9-4 offene Vorschläge (Filter, Zählung)
// AK-D9-5 Zähler für das Dashboard (Mandant, Rechte)           AK-D9-6 Performance (EXPLAIN, 20 000 Dokumente)
final class DMSOverviewTests: DMSSourceTestBase {
    func api(_ w: World) -> String { base(w.tenantA) }

    func doc(_ w: World, _ seed: String, title: String? = nil, tenant: String? = nil, by: TestSession? = nil) async throws -> String {
        let r = try await upload(by ?? w.alice, tenant ?? w.tenantA, pdf(seed), query: title.map { "title=\($0)" } ?? "")
        XCTAssertEqual(r.status, .created, "\(r.json)")
        return r.json["id"] as! String
    }

    /// Extraktionszeile direkt (Übersichtsspalten); Datum als `YYYY-MM-DD`.
    func extract(_ id: String, tenant: String, kind: String = "invoice", amount: String? = nil, currency: String? = nil, date: String? = nil, due: String? = nil, ref: String? = nil) async throws {
        try await db.raw("""
            INSERT INTO dms_extractions (document_id, tenant_id, extractor_version, text_sha256, kind, kind_score, kind_certain, kind_reasons, scores, facts, amount, currency, extracted_date, due_date, reference)
            VALUES (\(bind: UUID(uuidString: id)!), \(bind: UUID(uuidString: tenant)!), 2, repeat('a', 64), \(bind: kind), 0.9, true, '[]'::jsonb, '[]'::jsonb, '[]'::jsonb,
                    \(bind: amount)::text::numeric, \(bind: currency), \(bind: date)::text::date, \(bind: due)::text::date, \(bind: ref))
            """).run()
    }

    func suggest(_ id: String, tenant: String, state: String = "open", n: Int = 1) async throws {
        for i in 0..<n {
            try await db.raw("""
                INSERT INTO dms_suggestions (tenant_id, document_id, kind, value, value_key, source, confidence, reason, state, decided_at)
                VALUES (\(bind: UUID(uuidString: tenant)!), \(bind: UUID(uuidString: id)!), 'tag', '{}'::jsonb, \(bind: "\(state)\(i)"), 'contact_match', 0.5, 'Test',
                        \(bind: state), CASE WHEN \(bind: state) = 'open' THEN NULL ELSE now() END)
                """).run()
        }
    }

    func ids(_ r: Resp) -> [String] { items(r).compactMap { $0["id"] as? String } }
    func get(_ w: World, _ path: String, token: String? = nil, via: Application? = nil) async throws -> Resp {
        try await call(via ?? app1, .GET, api(w) + path, token: token ?? w.alice.token)
    }
    func otherTenant(_ w: World) async throws -> (String, TestSession) {
        let b = (try await call(app1, .POST, "api/v1/tenants", json: ["name": "Zweiter Mandant"], token: w.alice.token)).json["id"] as! String
        let carol = try await addUser("owner", handle: "carol", tenant: b, by: w.alice)
        try await setModule(b, true, by: carol)
        return (b, carol)
    }

    // MARK: AK-D9-1

    func testAKD9_1_totalsPerCurrency() async throws {
        let w = try await world()
        let (tb, carol) = try await otherTenant(w)
        let a = try await doc(w, "t-a"), b = try await doc(w, "t-b"), c = try await doc(w, "t-c"), d = try await doc(w, "t-d"), e = try await doc(w, "t-e"), t = try await doc(w, "t-t")
        let x = try await doc(w, "t-x", tenant: tb, by: carol)
        try await extract(a, tenant: w.tenantA, amount: "0.10", currency: "EUR", ref: "R1")
        try await extract(b, tenant: w.tenantA, amount: "0.20", currency: "EUR")
        try await extract(c, tenant: w.tenantA, kind: "receipt", amount: "50.05", currency: "USD")
        try await extract(d, tenant: w.tenantA, amount: "5.00")
        try await extract(e, tenant: w.tenantA)    // ohne Betrag: zählt nicht
        try await extract(t, tenant: w.tenantA, amount: "999.00", currency: "EUR")
        try await extract(x, tenant: tb, amount: "7777.00", currency: "EUR")
        try await aEq((try await call(app1, .POST, api(w) + "/documents/\(t)/trash", json: ["reason": "Test"], token: w.alice.token)).status, .ok)

        func totals(_ q: String, token: String? = nil, tenant: String? = nil) async throws -> [[String: Any]] {
            let r = try await call(app1, .GET, "api/v1/tenants/\(tenant ?? w.tenantA)/dms/documents?totals=true\(q)", token: token ?? w.alice.token)
            XCTAssertEqual(r.status, .ok, "\(r.json)")
            return r.json["totals"] as? [[String: Any]] ?? []
        }
        func flat(_ t: [[String: Any]]) -> [String] { t.map { "\($0["currency"] as? String ?? "-")=\($0["sum"] as! String)/\($0["count"] as! Int)" } }
        // exakt als Decimal (0,10 + 0,20 = 0,30), mehrere Währungen getrennt, ohne Währung eigene Gruppe, Papierkorb und fremder Mandant ausgeschlossen
        try await aEq(flat(try await totals("")), ["EUR=0.30/2", "USD=50.05/1", "-=5.00/1"])
        try await aEq(flat(try await totals("&currency=EUR")), ["EUR=0.30/2"])
        try await aEq(flat(try await totals("&amount_min=0.15")), ["EUR=0.20/1", "USD=50.05/1", "-=5.00/1"])
        try await aEq(flat(try await totals("&amount_max=1&kind=invoice")), ["EUR=0.30/2"])
        try await aEq(flat(try await totals("&reference=R1")), ["EUR=0.10/1"])
        try await aEq(flat(try await totals("&kind=receipt")), ["USD=50.05/1"])
        try await aEq(flat(try await totals("&trashed=true")), ["EUR=999.00/1"])
        try await aEq(flat(try await totals("&kind=contract")), [])
        try await aEq(flat(try await totals("", token: carol.token, tenant: tb)), ["EUR=7777.00/1"])
        // Summe gilt für die ganze gefilterte Menge, nicht für die Seite
        let page = try await get(w, "/documents?totals=true&limit=1&currency=EUR")
        XCTAssertEqual(items(page).count, 1); XCTAssertEqual(flat(page.json["totals"] as! [[String: Any]]), ["EUR=0.30/2"])
        // ohne Parameter kein Feld; ungültiger Wert 422
        try await aNil(try await get(w, "/documents").json["totals"])
        try await aEq((try await get(w, "/documents?totals=maybe")).status, .unprocessableEntity)
        // Summe stimmt mit der Liste überein (gleiche Filter)
        let list = items(try await get(w, "/documents?limit=200&currency=EUR")).compactMap { ($0["extraction"] as? [String: Any])?["amount"] as? String }
        XCTAssertEqual(list.sorted(), ["0.10", "0.20"])
    }

    // MARK: AK-D9-2

    func testAKD9_2_sourceFilledByPathsAndFilter() async throws {
        let w = try await world()
        let up = try await doc(w, "s-up")
        try await aEq((try await get(w, "/documents/\(up)")).json["source"] as? String, "upload")
        // Share-/Scan-API
        let tok = try await call(app1, .POST, "api/v1/auth/api-tokens", json: ["name": "Scanner", "scopes": ["dms.upload"]], token: w.alice.token)
        let shared = try await raw(app1, .POST, api(w) + "/share", body: pdf("s-share"), token: tok.json["token"] as! String, headers: ["Content-Type": "application/octet-stream", "Idempotency-Key": UUID().uuidString])
        XCTAssertEqual(shared.status, .created, "\(shared.json)")
        // Mail
        let mr = try await call(app1, .POST, api(w) + "/sources", json: ["kind": "folder", "name": "Mail", "config": ["path": "scan"]], token: w.alice.token)
        let row = try await DMSSources.row(UUID(uuidString: mr.json["id"] as! String)!, tenant: UUID(uuidString: w.tenantA)!, on: sql(app1.db(.psql)))!
        let cfg = MailSourceConfig(host: "127.0.0.1", port: 993, username: "x", mailbox: "INBOX", processed_mailbox: nil, interval_seconds: 60, include_body: false, sender_contains: nil,
                                   subject_contains: nil, max_per_run: 50, keep_mail: "relevant")
        let eml = Data(["From: Shop <billing@example.org>", "To: mail@example.org", "Subject: Ihre Rechnung Nr. 1", "Message-ID: <d9@example.org>", "Date: Sun, 8 Nov 2026 10:00:00 +0100",
                        "MIME-Version: 1.0", "Content-Type: text/plain; charset=utf-8", "", "Rechnung Gesamtbetrag 10,00 EUR", ""].joined(separator: "\r\n").utf8)
        let res = try await DMSMailPoll.process(raw: eml, source: row, config: cfg, limits: limits(), objectStore: ObjectStoreConfig(kind: .db), db: app1.db(.psql), requestID: "d9")
        XCTAssertEqual(res.ingested, 1)
        // Konsumordner
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("labhub-d9-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: root) }
        let dir = URL(fileURLWithPath: root).appendingPathComponent(w.tenantA.lowercased()).appendingPathComponent("eingang")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try pdf("s-folder").write(to: dir.appendingPathComponent("scan.pdf"))
        let fr = try await call(app1, .POST, src(w.tenantA), json: ["kind": "folder", "name": "Ordner", "config": ["path": "eingang", "interval_seconds": 60, "stable_seconds": 0]], token: w.alice.token)
        let handler = DMSFolderScan.handler(storeConfig: { ObjectStoreConfig(kind: .db) }, root: root, limits: limits())
        let payload = String(decoding: try JSONEncoder().encode(DMSSources.SourcePayload(source_id: UUID(uuidString: fr.json["id"] as! String)!, tenant_id: UUID(uuidString: w.tenantA)!)), as: UTF8.self)
        for _ in 0..<2 { try await handler(ClaimedJob(id: UUID(), kind: DMSFolderScan.kind, payload: payload, attempts: 1), app1.db(.psql) as! any SQLDatabase) }

        let bySource = Dictionary(grouping: items(try await get(w, "/documents?limit=200")), by: { $0["source"] as? String ?? "?" })
        XCTAssertEqual(bySource.mapValues(\.count), ["upload": 1, "share": 1, "mail": 1, "folder": 1])
        for s in ["upload", "share", "mail", "folder"] {
            let r = try await get(w, "/documents?source=\(s)")
            XCTAssertEqual(items(r).count, 1, s); XCTAssertEqual(items(r).first?["source"] as? String, s)
            try await aEq(ids(try await get(w, "/search?source=\(s)")), ids(r), "Suche: \(s)")
        }
        try await aEq(items(try await get(w, "/documents?source=import")).count, 0)
        for bad in ["source=scanner", "source=Upload", "source="] { try await aEq((try await get(w, "/documents?\(bad)")).status, .unprocessableEntity, bad) }
        XCTAssertEqual(DMSDocumentSource(ingest: .shareExt), .share); XCTAssertEqual(DMSDocumentSource(ingest: .api), .api)
    }

    /// AK-D9-2 (Backfill): Migration neu anwenden leitet die Quelle aus dem frühesten Eingangsvorgang bzw. aus Mail-Verknüpfungen ab, sonst `unknown`.
    func testAKD9_2_backfill() async throws {
        let w = try await world()
        let tenant = UUID(uuidString: w.tenantA)!
        var d: [String: String] = [:]
        for k in ["upload", "folder", "mail", "share", "api", "import"] { d[k] = try await doc(w, "b-\(k)") }
        for (k, src, ref) in [("folder", "folder", nil), ("mail", "mail", "mail:x"), ("share", "share_ext", nil), ("api", "api", "other:1"), ("import", "api", "paperless:77")] as [(String, String, String?)] {
            try await db.raw("UPDATE dms_ingest_items SET source = \(bind: src), origin_ref = \(bind: ref) WHERE document_id = \(bind: UUID(uuidString: d[k]!)!)").run()
        }
        // später angelegter zweiter Vorgang ändert die Herkunft nicht
        try await db.raw("INSERT INTO dms_ingest_items (tenant_id, document_id, source, state, created_at) VALUES (\(bind: tenant), \(bind: UUID(uuidString: d["upload"]!)!), 'mail', 'received', now() + interval '1 hour')").run()
        // ohne Eingangsvorgang: unknown, mit Mail-Verknüpfung: mail
        let none = UUID(), linked = UUID(), mailParent = UUID()
        for (id, title) in [(none, "ohne"), (linked, "angehaengt"), (mailParent, "mail")] {
            try await db.raw("INSERT INTO dms_documents (id, tenant_id, title) VALUES (\(bind: id), \(bind: tenant), \(bind: title))").run()
        }
        try await db.raw("""
            INSERT INTO links (tenant_id, from_type, from_id, to_type, to_id, kind, source) VALUES (\(bind: tenant), 'dms.document', \(bind: linked), 'dms.document', \(bind: mailParent), 'mail_attachment', 'system')
            """).run()
        let m = CreateDMSDocumentSource()
        try await m.revert(on: app1.db(.psql))
        try await aEq(try await count("information_schema.columns", where: "table_name = 'dms_documents' AND column_name = 'source'"), 0)
        try await m.prepare(on: app1.db(.psql))
        func src(_ id: String) async throws -> String { try await scalar("SELECT source AS v FROM dms_documents WHERE id = '\(id)'", as: String.self) }
        for k in d.keys { try await aEq(try await src(d[k]!), k, k) }
        try await aEq(try await src(none.uuidString), "unknown")
        try await aEq(try await src(linked.uuidString), "mail"); try await aEq(try await src(mailParent.uuidString), "mail")
        try await aEq(try await count("pg_indexes", where: "indexname IN ('dms_documents_source', 'dms_suggestions_open_document', 'dms_ingest_items_failed')"), 3)
    }

    // MARK: AK-D9-3

    func testAKD9_3_searchMatchesListFiltersAndSort() async throws {
        let w = try await world()
        var d: [String: String] = [:]
        let spec: [(String, String, String?, String?, String?, String?, String?, String)] = [   // key, kind, amount, currency, date, due, ref, title
            ("a", "invoice", "300.00", "EUR", "2026-11-01", "2026-11-15", "A-1", "Alpha Rechnung"), ("b", "invoice", "1000.50", "EUR", "2026-11-03", nil, "B-2", "Beta Rechnung"),
            ("c", "receipt", "45.10", "EUR", "2026-11-02", "2026-11-10", "C-3", "Gamma Beleg"), ("d", "invoice", "2000.00", "USD", "2026-11-04", "2026-12-01", "D-4", "Delta Rechnung"),
            ("e", "other", nil, nil, nil, nil, nil, "Epsilon Notiz")]
        for (k, kind, amount, cur, date, due, ref, title) in spec {
            d[k] = try await doc(w, "q-\(k)", title: title.replacingOccurrences(of: " ", with: "%20"))
            try await extract(d[k]!, tenant: w.tenantA, kind: kind, amount: amount, currency: cur, date: date, due: due, ref: ref)
        }
        try await suggest(d["a"]!, tenant: w.tenantA)
        let key = Dictionary(uniqueKeysWithValues: d.map { ($1, $0) })
        func letters(_ r: Resp) -> [String] { ids(r).compactMap { key[$0] } }
        let filters = ["", "&kind=invoice", "&kind=receipt", "&kind=invoice&kind_certain=true", "&currency=EUR", "&currency=USD", "&amount_min=100&amount_max=1000.50", "&due_to=2026-11-15",
                       "&due_from=2026-11-11", "&extracted_from=2026-11-02&extracted_to=2026-11-03", "&reference=C-3", "&has_open_suggestions=true", "&has_open_suggestions=false", "&source=upload", "&source=mail"]
        for f in filters {
            let list = try await get(w, "/documents?limit=200" + f), search = try await get(w, "/search?limit=200" + f)
            XCTAssertEqual(search.status, .ok, "\(search.json)")
            XCTAssertEqual(Set(ids(search)), Set(ids(list)), "gleiche Menge bei \(f)")
            XCTAssertEqual(ids(search).count, ids(list).count, f)
        }
        for sort in ["amount", "extracted_date", "due_date", "created_at"] {
            for order in ["asc", "desc"] {
                let q = "&sort=\(sort)&order=\(order)"
                let expected = letters(try await get(w, "/documents?limit=200" + q))
                try await aEq(letters(try await get(w, "/search?limit=200" + q)), expected, q)
                // Cursor über Seiten
                var out: [String] = [], cursor: String?
                for _ in 0..<10 {
                    let r = try await get(w, "/search?limit=2\(q)" + (cursor.map { "&cursor=\($0)" } ?? ""))
                    XCTAssertEqual(r.status, .ok, "\(r.json)")
                    out += letters(r)
                    guard let n = r.json["next_cursor"] as? String else { break }
                    cursor = n
                }
                XCTAssertEqual(out, expected, "Seiten \(q)")
            }
        }
        try await aEq(Array(letters(try await get(w, "/search?sort=amount&order=desc")).prefix(4)), ["d", "b", "a", "c"])
        // Treffer tragen Quelle, Zählung und Übersichtswerte
        let hit = items(try await get(w, "/search?limit=200")).first { $0["id"] as? String == d["a"] }!
        let ex = hit["extraction"] as! [String: Any]
        XCTAssertEqual(ex["kind"] as? String, "invoice"); XCTAssertEqual(ex["amount"] as? String, "300.00"); XCTAssertEqual(ex["currency"] as? String, "EUR")
        XCTAssertEqual(ex["due_date"] as? String, "2026-11-15"); XCTAssertEqual(ex["extracted_date"] as? String, "2026-11-01"); XCTAssertEqual(ex["reference"] as? String, "A-1")
        XCTAssertEqual(hit["source"] as? String, "upload"); XCTAssertEqual(hit["open_suggestions"] as? Int, 1)
        let none = items(try await get(w, "/search?limit=200")).first { $0["id"] as? String == d["e"] }!
        XCTAssertNotNil(none["extraction"])    // Art `other` ohne Fakten
        // Relevanz bleibt Standard (Titelwort zuerst), mit Filter kombinierbar, Snippets bleiben
        let rel = try await get(w, "/search?q=Delta&kind=invoice")
        XCTAssertEqual(letters(rel), ["d"]); XCTAssertNotNil(items(rel).first?["score"])
        try await aEq(letters(try await get(w, "/search?q=Delta&kind=receipt")), [])
        let relSort = try await get(w, "/search?q=Rechnung&sort=relevance"); XCTAssertEqual(relSort.status, .ok)
        try await aEq(Set(letters(relSort)), ["a", "b", "d"])
        let q = try await get(w, "/search?q=Rechnung&sort=amount&order=desc&facets=true&count=true")
        try await aEq(letters(q), ["d", "b", "a"]); XCTAssertEqual(q.json["total"] as? Int, 3); XCTAssertNotNil(q.json["facets"])
        for bad in ["kind=zzz", "sort=title", "order=up", "source=x", "has_open_suggestions=maybe", "currency=eur"] {
            try await aEq((try await get(w, "/search?\(bad)")).status, .unprocessableEntity, bad)
        }
        // Papierkorb und fremder Mandant
        let (tb, carol) = try await otherTenant(w)
        try await aEq(items(try await call(app1, .GET, "api/v1/tenants/\(tb)/dms/search?kind=invoice&limit=200", token: carol.token)).count, 0)
        _ = try await call(app1, .POST, api(w) + "/documents/\(d["d"]!)/trash", json: ["reason": "Test"], token: w.alice.token)
        try await aEq(letters(try await get(w, "/search?kind=invoice&sort=amount")), ["a", "b"])
    }

    // MARK: AK-D9-4

    func testAKD9_4_openSuggestionsFilterAndCount() async throws {
        let w = try await world()
        let a = try await doc(w, "v-a"), b = try await doc(w, "v-b"), c = try await doc(w, "v-c")
        try await suggest(a, tenant: w.tenantA, n: 2); try await suggest(b, tenant: w.tenantA, state: "accepted"); try await suggest(b, tenant: w.tenantA, state: "rejected", n: 2)
        let yes = try await get(w, "/documents?has_open_suggestions=true"), no = try await get(w, "/documents?has_open_suggestions=false")
        try await aEq(ids(yes), [a]); try await aEq(Set(ids(no)), Set([b, c]))
        let all = Dictionary(uniqueKeysWithValues: items(try await get(w, "/documents")).map { ($0["id"] as! String, $0["open_suggestions"] as! Int) })
        XCTAssertEqual(all, [a: 2, b: 0, c: 0])
        try await aEq((try await get(w, "/documents/\(a)")).json["open_suggestions"] as? Int, 2)
        // Entscheidung (Ablehnung) über die API verringert die Zahl
        let sg = items(try await get(w, "/documents/\(a)/suggestions?state=open")).first!["id"] as! String
        try await aEq((try await call(app1, .POST, api(w) + "/suggestions/\(sg)/reject", token: w.alice.token)).status, .ok)
        try await aEq((try await get(w, "/documents/\(a)")).json["open_suggestions"] as? Int, 1)
        // Mandantentrennung: ein offener Vorschlag in A zählt in B nicht
        let (tb, carol) = try await otherTenant(w)
        _ = try await doc(w, "v-x", tenant: tb, by: carol)
        let rb = try await call(app1, .GET, "api/v1/tenants/\(tb)/dms/documents?has_open_suggestions=true", token: carol.token)
        try await aEq(items(rb).count, 0)
    }

    // MARK: AK-D9-5

    func testAKD9_5_statsAndPermissions() async throws {
        let w = try await world()
        let (tb, carol) = try await otherTenant(w)
        let q1 = try await doc(w, "z-q1"), q2 = try await doc(w, "z-q2"), done = try await doc(w, "z-done"), fail = try await doc(w, "z-fail"), old = try await doc(w, "z-old")
        let trashed = try await doc(w, "z-trash"), contract = try await doc(w, "z-contract"), fresh = try await doc(w, "z-fresh")
        _ = try await doc(w, "z-b", tenant: tb, by: carol)
        func state(_ id: String, _ s: String) async throws {
            let extra = s.hasPrefix("failed") ? ", error_code = 'ocr_failed', resume_state = 'hashed'" : ""
            try await db.raw(SQLQueryString("UPDATE dms_ingest_items SET state = '\(s)'\(extra) WHERE document_id = '\(id)'")).run()
        }
        try await state(done, "done"); try await state(fail, "failed_permanent"); try await state(q2, "failed_retryable"); try await state(old, "done"); try await state(contract, "done"); try await state(fresh, "done")
        try await state(trashed, "failed_permanent")
        try await aEq((try await call(app1, .POST, api(w) + "/documents/\(trashed)/trash", json: ["reason": "Test"], token: w.alice.token)).status, .ok)
        try await db.raw("UPDATE dms_documents SET created_at = now() - interval '30 days' WHERE id IN (\(bind: UUID(uuidString: old)!), \(bind: UUID(uuidString: contract)!))").run()
        try await extract(old, tenant: w.tenantA, due: "2026-11-01"); try await extract(contract, tenant: w.tenantA, kind: "contract", due: "2026-10-01")
        try await extract(fresh, tenant: w.tenantA, due: "2026-12-24"); try await extract(trashed, tenant: w.tenantA, due: "2026-01-01")
        try await suggest(q1, tenant: w.tenantA, n: 3); try await suggest(done, tenant: w.tenantA); try await suggest(trashed, tenant: w.tenantA); try await suggest(fail, tenant: w.tenantA, state: "accepted")

        let r = try await get(w, "/stats?today=2026-11-08")
        XCTAssertEqual(r.status, .ok, "\(r.json)")
        // queued: q1 (hashed), q2 (failed_retryable); fehlgeschlagen: fail (trashed zählt nicht); Vorschläge: q1, done; überfällig: old (Vertrag und Papierkorb nicht); neu: q1, q2, done, fail, fresh (nicht old/contract, nicht Papierkorb)
        XCTAssertEqual(r.json as NSDictionary, ["queued": 2, "failed": 1, "open_suggestions": 2, "overdue": 1, "new_last_7_days": 5] as NSDictionary)
        try await aEq((try await get(w, "/stats?today=2027-01-01")).json["overdue"] as? Int, 2)
        let b = try await call(app1, .GET, "api/v1/tenants/\(tb)/dms/stats", token: carol.token)
        XCTAssertEqual(b.json as NSDictionary, ["queued": 1, "failed": 0, "open_suggestions": 0, "overdue": 0, "new_last_7_days": 1] as NSDictionary, "nur Mandant B")
        // Rechte wie dms.document.read, zwei Instanzen gleiches Ergebnis
        let tax = try await addUser("tax_advisor", handle: "tax", tenant: w.tenantA, by: w.alice)
        let viewer = try await addUser("customer_viewer", handle: "view", tenant: w.tenantA, by: w.alice)
        try await aEq((try await get(w, "/stats", token: tax.token)).status, .ok)
        try await aEq((try await get(w, "/stats", token: viewer.token)).status, .forbidden)
        try await aEq((try await call(app2, .GET, api(w) + "/stats")).status, .unauthorized)
        try await aEq((try await call(app1, .GET, "api/v1/tenants/\(w.tenantA)/dms/stats", token: carol.token)).status, .notFound)   // fremder Mandant: 404
        try await aEq((try await get(w, "/stats?today=2026-13-01")).status, .unprocessableEntity)
        try await aEq((try await get(w, "/stats?today=2026-11-08", via: app2)).json as NSDictionary, r.json as NSDictionary)
    }

    // MARK: AK-D9-6

    /// 20 000 synthetische Dokumente: Ergebnis stimmt, Pläne der neuen Filter werden ausgegeben (Dokumentation im Handoff, kein hartes Zeitziel).
    func testAKD9_6_explainOn20kDocuments() async throws {
        let w = try await world()
        let t = UUID(uuidString: w.tenantA)!
        try await db.raw("""
            INSERT INTO dms_documents (id, tenant_id, title, source, created_at)
            SELECT gen_random_uuid(), \(bind: t), 'Dok ' || g, (ARRAY['upload', 'mail', 'folder', 'share', 'import', 'api', 'unknown'])[1 + g % 7], now() - (g || ' minutes')::interval FROM generate_series(1, 20000) g
            """).run()
        try await db.raw("""
            INSERT INTO dms_extractions (document_id, tenant_id, extractor_version, text_sha256, kind, kind_score, kind_certain, kind_reasons, scores, facts, amount, currency, due_date)
            SELECT d.id, d.tenant_id, 2, repeat('a', 64), 'invoice', 0.9, true, '[]'::jsonb, '[]'::jsonb, '[]'::jsonb, (row_number() OVER ())::numeric / 100, (ARRAY['EUR', 'USD'])[1 + (row_number() OVER ())::int % 2],
                   DATE '2026-01-01' + (row_number() OVER ())::int % 400
            FROM dms_documents d WHERE d.tenant_id = \(bind: t)
            """).run()
        try await db.raw("""
            INSERT INTO dms_suggestions (tenant_id, document_id, kind, value, value_key, source, confidence, reason)
            SELECT tenant_id, id, 'tag', '{}'::jsonb, 'k', 'contact_match', 0.5, 'Test' FROM dms_documents WHERE tenant_id = \(bind: t) AND title LIKE '%7'
            """).run()
        try await db.raw("ANALYZE dms_documents").run(); try await db.raw("ANALYZE dms_extractions").run(); try await db.raw("ANALYZE dms_suggestions").run()
        let sourceN = try await scalar("SELECT count(*)::bigint AS v FROM dms_documents WHERE source = 'mail'", as: Int64.self)
        try await aEq(items(try await get(w, "/documents?source=mail&limit=1&totals=true")).count, 1)
        let totals = try await get(w, "/documents?source=mail&totals=true&limit=1").json["totals"] as! [[String: Any]]
        XCTAssertEqual(totals.reduce(0) { $0 + ($1["count"] as! Int) }, Int(sourceN))
        try await aEq(Int(try await get(w, "/documents?has_open_suggestions=true&limit=200").json["next_cursor"] == nil ? 0 : 1), 1)
        var f = DMSDocuments.Filter(); f.source = "mail"
        var g = DMSDocuments.Filter(); g.hasOpenSuggestions = true
        var h = DMSDocuments.Filter(); h.currency = "EUR"; h.amountMin = "10"; h.amountMax = "50"
        for (name, flt) in [("source=mail", f), ("has_open_suggestions=true", g), ("currency+amount", h)] {
            let rows = try await db.raw("""
                EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF) SELECT d.id, \(unsafeRaw: DMSDocuments.extractionColumns) FROM dms_documents d \(unsafeRaw: DMSDocuments.extractionJoin)
                WHERE d.tenant_id = \(bind: t) AND d.trashed_at IS NULL \(DMSDocuments.extractionConditions(flt)) ORDER BY d.created_at, d.id LIMIT 51
                """).all()
            let plan = try rows.map { try $0.decode(column: "QUERY PLAN", as: String.self) }.joined(separator: "\n")
            print("EXPLAIN \(name)\n\(plan)")
        }
        let started = Date()
        _ = try await get(w, "/stats?today=2026-11-08")
        print("stats auf 20000 Dokumenten: \(Int(Date().timeIntervalSince(started) * 1000)) ms")
    }
}
