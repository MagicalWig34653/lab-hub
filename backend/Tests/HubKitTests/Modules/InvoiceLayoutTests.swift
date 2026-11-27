import XCTVapor
import Fluent
import SQLKit
import Crypto
@testable import HubCore
@testable import HubKit
@testable import HubModuleInvoice

// WP-R6d: Layoutmodell V1 (versionierte Mandantendaten), Parameter (FRONTEND.md Abschnitt 13 Stufe 1), Logo-Upload, Zuordnung je Belegart/Serie,
// Vorschau eines Entwurfs über den Worker. Nur synthetische Daten. Ohne Typst laufen alle Tests außer `InvoiceLayoutRenderTests` (Renderer ist der
// Zähler `FakeRenderer`, der Layout und Parameter in die Bytes schreibt); der echte Renderer läuft in `InvoiceLayoutRenderTests` und im E2E.

/// Kleine, gültige Bilder für Upload und Render (PNG mit unkomprimierten Deflate-Blöcken, JPEG nur als Kopf mit SOF0).
enum TestImages {
    private static let crcTable: [UInt32] = (0..<256).map { n -> UInt32 in
        var c = UInt32(n)
        for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1 }
        return c
    }
    static func crc32(_ bytes: [UInt8]) -> UInt32 {
        var c: UInt32 = 0xFFFFFFFF
        for b in bytes { c = crcTable[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
        return c ^ 0xFFFFFFFF
    }
    private static func be32(_ v: UInt32) -> [UInt8] { [UInt8(v >> 24), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)] }
    private static func chunk(_ type: String, _ data: [UInt8]) -> [UInt8] {
        let body = Array(type.utf8) + data
        return be32(UInt32(data.count)) + body + be32(crc32(body))
    }

    /// RGB-PNG `width`×`height` in einer Farbe. `declared` überschreibt die Maße im Kopf (für die Prüfung zu großer Bilder).
    static func png(width: Int = 8, height: Int = 4, rgb: (UInt8, UInt8, UInt8) = (31, 78, 121), declared: (Int, Int)? = nil) -> Data {
        var raw: [UInt8] = []
        for _ in 0..<height { raw.append(0); for _ in 0..<width { raw += [rgb.0, rgb.1, rgb.2] } }
        // zlib: Kopf, ein gespeicherter Block, Adler-32
        var a: UInt32 = 1, b: UInt32 = 0
        for x in raw { a = (a + UInt32(x)) % 65521; b = (b + a) % 65521 }
        let len = UInt16(raw.count)
        let zlib: [UInt8] = [0x78, 0x01, 0x01, UInt8(len & 0xFF), UInt8(len >> 8), UInt8(~len & 0xFF), UInt8(~len >> 8)] + raw + be32((b << 16) | a)
        let (w, h) = declared ?? (width, height)
        let ihdr = be32(UInt32(w)) + be32(UInt32(h)) + [8, 2, 0, 0, 0]
        return Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] + chunk("IHDR", ihdr) + chunk("IDAT", zlib) + chunk("IEND", []))
    }

    /// JPEG-Kopf (SOI, SOF0 mit Maßen, EOI): genügt der Formatprüfung, wird aber nicht gerendert.
    static func jpeg(width: Int = 40, height: Int = 20) -> Data {
        let sof: [UInt8] = [0xFF, 0xC0, 0x00, 0x11, 0x08, UInt8(height >> 8), UInt8(height & 0xFF), UInt8(width >> 8), UInt8(width & 0xFF), 0x03,
                            0x01, 0x22, 0x00, 0x02, 0x11, 0x01, 0x03, 0x11, 0x01]
        return Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46, 0x49, 0x46, 0x00, 0x01, 0x01, 0x00, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00] + sof + [0xFF, 0xD9])
    }
}

class InvoiceLayoutTestBase: InvoiceRenderTestBase {
    func layoutsPath(_ s: Setup) -> String { base(s.w.tenantA) + "/layouts" }

    /// Vollständige Parameter (alle Felder der Stufe 1). Fußtext mit Typst-Syntax: muss wörtlich bleiben.
    func params(logo: String? = nil, header: String = "Kopftext {{number}} für {{recipient}}", font: String = "Libertinus Serif") -> [String: Any] {
        var p: [String: Any] = ["schema": 1, "base": "standard", "font": font, "colors": ["accent": "#1F4E79", "text": "#202020"],
                                "texts": ["header": header, "footer": "Fußtext #read(\"/etc/hosts\") – {{sender}}, {{issue_date}}, {{due_date}}"]]
        if let logo { p["logo"] = ["sha256": logo, "width_mm": 35, "align": "right"] }
        return p
    }

    func upload(_ s: Setup, _ data: Data, type: String?, token: String? = nil, via: Application? = nil, tenant: String? = nil) async throws -> RenderResp {
        var headers = HTTPHeaders()
        headers.bearerAuthorization = BearerAuthorization(token: token ?? s.w.alice.token)
        if let type { headers.replaceOrAdd(name: .contentType, value: type) }
        let box = UnsafeSendableBox<RenderResp?>(nil)
        try await (via ?? app1).test(.POST, base(tenant ?? s.w.tenantA) + "/layouts/logos", headers: headers, body: ByteBuffer(data: data)) { res async throws in
            box.value = RenderResp(status: res.status, headers: res.headers, body: Data(buffer: res.body))
        }
        return box.value!
    }

    func logo(_ s: Setup, _ data: Data = TestImages.png()) async throws -> String {
        let r = try await upload(s, data, type: "image/png")
        XCTAssertEqual(r.status, .created, String(decoding: r.body, as: UTF8.self))
        return try XCTUnwrap(r.json["sha256"] as? String)
    }

    func createLayout(_ s: Setup, name: String = "Hausstil", params p: [String: Any], token: String? = nil, via: Application? = nil) async throws -> Resp {
        try await call(via ?? app1, .POST, layoutsPath(s), json: ["name": name, "params": p], token: token ?? s.w.alice.token)
    }

    func newVersion(_ s: Setup, _ layout: String, params p: [String: Any], via: Application? = nil) async throws -> Resp {
        try await call(via ?? app1, .POST, layoutsPath(s) + "/\(layout)/versions", json: ["params": p], token: s.w.alice.token)
    }

    func assign(_ s: Setup, _ items: [[String: Any]], token: String? = nil) async throws -> Resp {
        try await call(app1, .PUT, base(s.w.tenantA) + "/layout-assignments", json: ["items": items], token: token ?? s.w.alice.token)
    }

    func preview(_ s: Setup, _ doc: String, body: [String: Any] = [:], token: String? = nil, via: Application? = nil) async throws -> Resp {
        try await call(via ?? app1, .POST, s.docs + "/\(doc)/preview", json: body, token: token ?? s.w.alice.token)
    }

    func previewPDF(_ s: Setup, _ id: String, token: String? = nil, via: Application? = nil) async throws -> RenderResp {
        try await raw(via ?? app1, .GET, base(s.w.tenantA) + "/previews/\(id)", token: token ?? s.w.alice.token)
    }

    func makeWorkers(_ app: Application, _ renderer: any InvoiceRendering) -> JobWorker {
        JobWorker(db: app.db(.psql) as! any SQLDatabase, kinds: [InvoiceRenderJob.kind, InvoicePreviewJob.kind],
                  handlers: [InvoiceRenderJob.kind: InvoiceRenderJob.handler(renderer: renderer, storeFactory: Self.store),
                             InvoicePreviewJob.kind: InvoicePreviewJob.handler(renderer: renderer, storeFactory: Self.store)],
                  leaseSeconds: 30, pollInterval: .milliseconds(50), retryBackoffSeconds: 0, logger: Logger(label: "test.layout"))
    }

    func jsonEqual(_ a: Any?, _ b: Any?) -> Bool {
        guard let a, let b, let da = try? JSONSerialization.data(withJSONObject: a, options: [.sortedKeys]),
              let db = try? JSONSerialization.data(withJSONObject: b, options: [.sortedKeys]) else { return false }
        return da == db
    }

    func previewsDone() async throws -> Int64 { try await count("jobs", where: "kind = 'invoice.preview' AND state = 'done'") }
}

// MARK: AK-R6d-1 Roundtrip, AK-R6d-2 Layoutversion bleibt

final class InvoiceLayoutTests: InvoiceLayoutTestBase {

    /// AK-R6d-1: Speichern → Laden (andere Instanz) → Rendern ohne Verlust: alle Parameter kommen unverändert zurück und genau so beim Renderer an,
    /// einschließlich der Logo-Bytes. Neue Version: Nummer steigt, alte Version bleibt abrufbar und unverändert.
    func testAKR6d_1_roundtripSaveLoadRenderWithoutLoss() async throws {
        let s = try await setup()
        let png = TestImages.png(width: 12, height: 6)
        let sha = try await logo(s, png)
        let p = params(logo: sha)
        let created = try await createLayout(s, params: p)
        XCTAssertEqual(created.status, .created, "\(created.json)")
        let id = try XCTUnwrap(created.json["id"] as? String)
        XCTAssertEqual(created.json["version"] as? Int, 1)
        XCTAssertTrue(jsonEqual(created.json["params"], p), "\(created.json)")

        let loaded = try await call(app2, .GET, layoutsPath(s) + "/\(id)", token: s.w.alice.token)
        XCTAssertEqual(loaded.status, .ok)
        XCTAssertTrue(jsonEqual(loaded.json["params"], p), "Laden über die zweite Instanz liefert dieselben Parameter: \(loaded.json)")
        XCTAssertEqual(loaded.json["name"] as? String, "Hausstil")
        let list = try await call(app2, .GET, layoutsPath(s), token: s.w.alice.token)
        XCTAssertEqual(items(list).count, 1); XCTAssertEqual(items(list).first?["id"] as? String, id)

        // Zuordnung „alle Rechnungen“ und Rendern: der Renderer bekommt exakt die gespeicherten Parameter und die Logo-Bytes
        let a = try await assign(s, [["document_kind": "invoice", "layout_id": id]])
        XCTAssertEqual(a.status, .ok, "\(a.json)")
        let doc = try await finalDocument(s)
        let renderer = FakeRenderer()
        try await withWorkers([makeWorkers(app1, renderer)]) { try await jobsDone() == 1 }
        let used = try XCTUnwrap(renderer.layouts.last)
        XCTAssertEqual(used.key, id.lowercased()); XCTAssertEqual(used.version, 1)
        XCTAssertTrue(jsonEqual(try JSONSerialization.jsonObject(with: Data(try XCTUnwrap(used.params).canonicalJSON.utf8)), p))
        XCTAssertEqual(used.logo, png, "Logo-Bytes unverändert")
        let stateRows = try await states(doc)
        let state = try XCTUnwrap(stateRows.first)
        XCTAssertEqual(state.layoutKey, id.lowercased()); XCTAssertEqual(state.layoutVersion, 1)
        let pdf = try await pdf(s, doc)
        XCTAssertEqual(pdf.status, .ok)

        // Version 2: neue Nummer, Version 1 unverändert abrufbar
        var p2 = p; p2["font"] = "Inter"; p2["colors"] = ["accent": "#AA0000", "text": "#000000"]; p2.removeValue(forKey: "logo")
        let v2 = try await newVersion(s, id, params: p2, via: app2)
        XCTAssertEqual(v2.status, .created, "\(v2.json)"); XCTAssertEqual(v2.json["version"] as? Int, 2)
        XCTAssertTrue(jsonEqual(v2.json["params"], p2))
        let old = try await call(app1, .GET, layoutsPath(s) + "/\(id)/versions/1", token: s.w.alice.token)
        XCTAssertEqual(old.status, .ok); XCTAssertTrue(jsonEqual(old.json["params"], p))
        let current = try await call(app1, .GET, layoutsPath(s) + "/\(id)", token: s.w.alice.token)
        XCTAssertEqual(current.json["version"] as? Int, 2); XCTAssertTrue(jsonEqual(current.json["params"], p2))
    }

    /// AK-R6d-1: Die Aufbereitung übernimmt jeden Parameter in die Vorlagendaten; Platzhalter werden in Swift ersetzt, Typst-Syntax bleibt Text.
    func testAKR6d_1_prepareCarriesEveryParameter() throws {
        let p = try InvoiceLayoutParams.parse(params(logo: String(repeating: "a", count: 64)))
        let prepared = try InvoiceRenderData.prepare(RenderFixtures.document("invoice"), attach: false,
                                                     layout: InvoiceRenderLayout(key: "k", version: 3, params: p, logo: TestImages.png(), logoType: "image/png"))
        let layout = try XCTUnwrap(prepared.data.layout)
        XCTAssertEqual(layout.font, "Libertinus Serif"); XCTAssertEqual(layout.accent, "#1F4E79"); XCTAssertEqual(layout.text, "#202020")
        XCTAssertEqual(layout.logo?.file, "logo.png"); XCTAssertEqual(layout.logo?.width, 35); XCTAssertEqual(layout.logo?.align, "right")
        let number = prepared.data.number
        XCTAssertEqual(layout.headerText, "Kopftext \(number) für \(prepared.data.recipientLines.first ?? "")")
        XCTAssertTrue(try XCTUnwrap(layout.footerText).hasPrefix("Fußtext #read(\"/etc/hosts\") – \(prepared.data.senderName), "), layout.footerText ?? "")
        // ohne Layout: keine Layoutdaten (das Standardlayout bleibt bytegleich zu R6b)
        XCTAssertNil(try InvoiceRenderData.prepare(RenderFixtures.document("invoice"), attach: false).data.layout)
    }

    /// AK-R6d-1: Parameter werden streng geprüft (unbekannte Felder, Schrift außerhalb der Liste, Farben, Maße, Platzhalter, Längen).
    func testAKR6d_1_invalidParametersAreRejected() async throws {
        let s = try await setup()
        let cases: [(String, (inout [String: Any]) -> Void, String, String)] = [
            ("unbekanntes Feld", { $0["elements"] = [] }, "params.elements", "unknown"),
            ("Schrift", { $0["font"] = "Comic Sans" }, "params.font", "not_allowed"),
            ("Farbe", { $0["colors"] = ["accent": "red", "text": "#000000"] }, "params.colors.accent", "invalid"),
            ("Schema", { $0["schema"] = 2 }, "params.schema", "unsupported"),
            ("Basis", { $0["base"] = "custom" }, "params.base", "unsupported"),
            ("Platzhalter", { $0["texts"] = ["header": "{{password}}"] }, "params.texts.header", "unknown_placeholder"),
            ("Länge", { $0["texts"] = ["footer": String(repeating: "x", count: 2001)] }, "params.texts.footer", "too_long"),
            ("Logo fehlt", { $0["logo"] = ["sha256": String(repeating: "b", count: 64), "width_mm": 30, "align": "left"] }, "params.logo.sha256", "not_found"),
            ("Logobreite", { $0["logo"] = ["sha256": String(repeating: "b", count: 64), "width_mm": 500, "align": "left"] }, "params.logo.width_mm", "invalid"),
        ]
        for (what, change, field, code) in cases {
            var p = params(); change(&p)
            let r = try await createLayout(s, params: p)
            XCTAssertEqual(r.status, .unprocessableEntity, what)
            let errors = r.json["errors"] as? [[String: Any]] ?? []
            XCTAssertTrue(errors.contains { $0["field"] as? String == field && $0["code"] as? String == code }, "\(what): \(r.json)")
        }
        try await aEq(try await count("invoice_layouts"), 0, "nichts gespeichert")
    }

    /// AK-R6d-2: Finale Belege behalten ihre Layoutversion: Beleg A wird mit Version 1 finalisiert, dann entsteht Version 2 und erst danach läuft der Worker.
    /// A rendert mit Version 1, der danach finalisierte Beleg B mit Version 2. Versionen sind per SQL weder änderbar noch löschbar.
    func testAKR6d_2_finalDocumentKeepsItsLayoutVersion() async throws {
        let s = try await setup()
        let created = try await createLayout(s, params: params(header: "Version eins"))
        let id = try XCTUnwrap(created.json["id"] as? String)
        let h1 = try await assign(s, [["document_kind": "invoice", "layout_id": id]])
        XCTAssertEqual((h1).status, .ok)
        let docA = try await finalDocument(s)
        let h2 = try await newVersion(s, id, params: params(header: "Version zwei"))
        XCTAssertEqual((h2).status, .created)
        let docB = try await finalDocument(s)
        let frozenA = try await value("SELECT v.version AS v FROM invoice_documents d JOIN invoice_layout_versions v ON v.id = d.layout_version_id WHERE d.id = '\(docA)'", as: Int.self)
        XCTAssertEqual(frozenA, 1, "beim Finalisieren eingefroren")

        let renderer = FakeRenderer()
        try await withWorkers([makeWorkers(app1, renderer), makeWorkers(app2, renderer)]) { try await jobsDone() == 2 }
        let rowsA = try await states(docA), rowsB = try await states(docB)
        let stateA = try XCTUnwrap(rowsA.first), stateB = try XCTUnwrap(rowsB.first)
        XCTAssertEqual(stateA.layoutVersion, 1); XCTAssertEqual(stateB.layoutVersion, 2)
        let pdfA = String(decoding: (try await pdf(s, docA)).body, as: UTF8.self), pdfB = String(decoding: (try await pdf(s, docB)).body, as: UTF8.self)
        XCTAssertTrue(pdfA.contains("Version eins") && !pdfA.contains("Version zwei"), pdfA)
        XCTAssertTrue(pdfB.contains("Version zwei"), pdfB)

        // Version 3 nach dem Rendern: das fertige PDF bleibt, POST render legt nichts an
        let h3 = try await newVersion(s, id, params: params(header: "Version drei"))
        XCTAssertEqual((h3).status, .created)
        let h4 = try await renderRequest(s, docA)
        XCTAssertEqual((h4).status, .ok)
        try await aEq(try await states(docA), [stateA])

        // Unveränderlich in der Datenbank
        for stmt in ["UPDATE invoice_layout_versions SET params = '{}'::jsonb", "DELETE FROM invoice_layout_versions", "TRUNCATE invoice_layout_versions CASCADE",
                     "UPDATE invoice_documents SET layout_version_id = NULL WHERE id = '\(docA)'"] {
            do { try await db.raw(SQLQueryString(stmt)).run(); XCTFail("erlaubt: \(stmt)") } catch {}
        }
        try await aEq(try await count("invoice_layout_versions"), 3)
    }

    /// Zuordnung: Belegart und Serie > nur Serie > nur Belegart > Vorgabe > Standardlayout. Ohne Zuordnung bleibt das Standardlayout (wie R6c).
    func testAKR6d_assignmentResolutionOrder() async throws {
        let s = try await setup()
        let seriesID = try await value("SELECT id::text AS v FROM invoice_series LIMIT 1", as: String.self)
        var ids: [String] = []
        for n in ["Vorgabe", "Art", "Serie", "ArtSerie"] {
            let created = try await createLayout(s, name: n, params: params(header: n))
            ids.append(try XCTUnwrap(created.json["id"] as? String))
        }
        let none = try await finalDocument(s)
        let noneRow = try await db.raw(SQLQueryString("SELECT layout_version_id FROM invoice_documents WHERE id = '\(none)'")).first()
        XCTAssertNil(try noneRow?.decode(column: "layout_version_id", as: UUID?.self) ?? nil)
        var expected: [(String, String)] = []
        let steps: [[[String: Any]]] = [
            [["layout_id": ids[0]]],
            [["layout_id": ids[0]], ["document_kind": "invoice", "layout_id": ids[1]]],
            [["layout_id": ids[0]], ["document_kind": "invoice", "layout_id": ids[1]], ["series_id": seriesID, "layout_id": ids[2]]],
            [["layout_id": ids[0]], ["document_kind": "invoice", "layout_id": ids[1]], ["series_id": seriesID, "layout_id": ids[2]],
             ["document_kind": "invoice", "series_id": seriesID, "layout_id": ids[3]]]]
        for (i, step) in steps.enumerated() {
            let r = try await assign(s, step)
            XCTAssertEqual(r.status, .ok, "\(r.json)"); XCTAssertEqual(items(r).count, step.count)
            expected.append((try await finalDocument(s), ids[i]))
        }
        for (doc, layout) in expected {
            let got = try await value("SELECT v.layout_id::text AS v FROM invoice_documents d JOIN invoice_layout_versions v ON v.id = d.layout_version_id WHERE d.id = '\(doc)'", as: String.self)
            XCTAssertEqual(got.lowercased(), layout.lowercased())
        }
        let listed = try await call(app2, .GET, base(s.w.tenantA) + "/layout-assignments", token: s.w.alice.token)
        XCTAssertEqual(items(listed).count, 4)
        // Doppelte Zuordnung und ungültige Belegart werden abgelehnt
        let dup = try await assign(s, [["document_kind": "invoice", "layout_id": ids[0]], ["document_kind": "invoice", "layout_id": ids[1]]])
        XCTAssertEqual(dup.status, .unprocessableEntity)
        let kind = try await assign(s, [["document_kind": "bill", "layout_id": ids[0]]])
        XCTAssertEqual(kind.status, .unprocessableEntity)
        let h6 = try await call(app1, .GET, base(s.w.tenantA) + "/layout-assignments", token: s.w.alice.token)
        XCTAssertEqual(items(h6).count, 4, "abgelehnt ändert nichts")
    }

    /// Migration `invoice_031_layouts`: zurückbaubar und wieder anwendbar, auch bei deaktiviertem Modul vorhanden.
    func testAKR6d_migrationRevertAndReapply() async throws {
        _ = try await world(enable: false)
        let tables = ["invoice_layouts", "invoice_layout_versions", "invoice_layout_assets", "invoice_layout_assignments", "invoice_previews"]
        for tbl in tables { try await aEq(try await count("information_schema.tables", where: "table_name = '\(tbl)'"), 1, tbl) }
        try await aEq(try await count("information_schema.columns", where: "table_name = 'invoice_documents' AND column_name = 'layout_version_id'"), 1)
        let m = try XCTUnwrap(InvoiceModule().migrations.first { $0.name == "invoice_031_layouts" } as? any AsyncMigration), database = app1.db(.psql)
        try await m.revert(on: database)
        for tbl in tables { try await aEq(try await count("information_schema.tables", where: "table_name = '\(tbl)'"), 0, tbl) }
        try await aEq(try await count("information_schema.columns", where: "table_name = 'invoice_documents' AND column_name = 'layout_version_id'"), 0)
        try await aEq(try await count("pg_proc", where: "proname LIKE 'invoice\\_layout\\_%'"), 0)
        try await m.prepare(on: database)
        for tbl in tables { try await aEq(try await count("information_schema.tables", where: "table_name = '\(tbl)'"), 1, tbl) }
    }
}

// MARK: AK-R6d-3 Logo-Upload

final class InvoiceLayoutLogoTests: InvoiceLayoutTestBase {

    /// AK-R6d-3: Nur PNG und JPEG mit passenden Bytes, höchstens 512 KiB und 2000×2000 Pixel. Abgelehnte Fälle speichern nichts.
    func testAKR6d_3_logoUploadAcceptsOnlyCheckedFormatsAndSizes() async throws {
        let s = try await setup()
        let png = try await upload(s, TestImages.png(width: 20, height: 10), type: "image/png")
        XCTAssertEqual(png.status, .created, String(decoding: png.body, as: UTF8.self))
        XCTAssertEqual(png.json["width"] as? Int, 20); XCTAssertEqual(png.json["height"] as? Int, 10); XCTAssertEqual(png.json["content_type"] as? String, "image/png")
        XCTAssertEqual(png.json["sha256"] as? String, sha(TestImages.png(width: 20, height: 10)))
        let jpeg = try await upload(s, TestImages.jpeg(width: 300, height: 120), type: "image/jpeg")
        XCTAssertEqual(jpeg.status, .created, String(decoding: jpeg.body, as: UTF8.self))
        XCTAssertEqual(jpeg.json["width"] as? Int, 300); XCTAssertEqual(jpeg.json["height"] as? Int, 120)
        let again = try await upload(s, TestImages.png(width: 20, height: 10), type: "image/png", via: app2)
        XCTAssertEqual(again.status, .created, "gleiche Bytes: gleiche Antwort, keine zweite Zeile")
        try await aEq(try await count("invoice_layout_assets"), 2)
        let assetsBefore = try await count("invoice_layout_assets"), filesBefore = try await count("files")

        var big = TestImages.png().prefix(33)   // Signatur und IHDR
        big.append(Data(repeating: 0, count: 600 * 1024))
        let svg = Data("<svg xmlns=\"http://www.w3.org/2000/svg\"><script>alert(1)</script></svg>".utf8)
        let gif = Data("GIF89a".utf8) + Data(repeating: 0, count: 20)
        var truncated = TestImages.png(); truncated.removeLast(12)
        var badCRC = TestImages.png(); badCRC[29] ^= 0xFF
        let rejected: [(String, Data, String?, HTTPStatus, String?)] = [
            ("SVG", svg, "image/svg+xml", .unsupportedMediaType, nil),
            ("GIF", gif, "image/gif", .unsupportedMediaType, nil),
            ("ohne Typ", TestImages.png(), nil, .unsupportedMediaType, nil),
            ("GIF als PNG", gif, "image/png", .unprocessableEntity, "type_mismatch"),
            ("JPEG als PNG", TestImages.jpeg(), "image/png", .unprocessableEntity, "type_mismatch"),
            ("PNG abgeschnitten", truncated, "image/png", .unprocessableEntity, "invalid"),
            ("PNG Prüfsumme", badCRC, "image/png", .unprocessableEntity, "invalid"),
            ("zu viele Pixel", TestImages.png(declared: (5000, 10)), "image/png", .unprocessableEntity, "dimensions"),
            ("leer", Data(), "image/png", .unprocessableEntity, "invalid"),
            ("zu groß", Data(big), "image/png", .payloadTooLarge, nil),
        ]
        for (what, data, type, status, code) in rejected {
            let r = try await upload(s, data, type: type)
            XCTAssertEqual(r.status, status, "\(what): \(String(decoding: r.body, as: UTF8.self))")
            if let code {
                let errors = r.json["errors"] as? [[String: Any]] ?? []
                XCTAssertTrue(errors.contains { $0["field"] as? String == "logo" && $0["code"] as? String == code }, "\(what): \(r.json)")
            }
        }
        try await aEq(try await count("invoice_layout_assets"), assetsBefore, "abgelehnt: keine Zeile")
        try await aEq(try await count("files"), filesBefore, "abgelehnt: keine Datei")
    }
}

// MARK: AK-R6d-4 Mandanten und Rechte

final class InvoiceLayoutAccessTests: InvoiceLayoutTestBase {

    /// AK-R6d-4: Fremder Mandant: Layout, Version, Logo, Zuordnung und Vorschau des anderen Mandanten sind 404 bzw. nicht verwendbar.
    func testAKR6d_4_foreignTenantIs404() async throws {
        let s = try await setup()
        let sha = try await logo(s)
        let h7 = try await createLayout(s, params: params(logo: sha))
        let id = try XCTUnwrap((h7).json["id"] as? String)
        let doc = try await draft(s)
        let pv = try await preview(s, doc)
        XCTAssertEqual(pv.status, .accepted, "\(pv.json)")
        let previewID = try XCTUnwrap(pv.json["id"] as? String)

        let tenantB = (try await call(app1, .POST, "api/v1/tenants", json: ["name": "Zweiter Mandant"], token: s.w.alice.token)).json["id"] as! String
        let carol = try await addUser("owner", handle: "carol", tenant: tenantB, by: s.w.alice)
        try await setModule(tenantB, true, by: carol)
        let b = base(tenantB)
        // Pfade des eigenen Mandanten B mit Ids aus A
        for path in ["/layouts/\(id)", "/layouts/\(id)/versions/1", "/previews/\(previewID)"] {
            let r = try await call(app2, .GET, b + path, token: carol.token)
            XCTAssertEqual(r.status, .notFound, path)
        }
        let h8 = try await call(app1, .POST, b + "/layouts/\(id)/versions", json: ["params": params()], token: carol.token)
        XCTAssertEqual((h8).status, .notFound)
        let h9 = try await call(app1, .GET, b + "/layouts", token: carol.token)
        XCTAssertEqual(items(h9).count, 0)
        let foreignAssign = try await call(app1, .PUT, b + "/layout-assignments", json: ["items": [["layout_id": id]]], token: carol.token)
        XCTAssertEqual(foreignAssign.status, .unprocessableEntity, "fremdes Layout nicht zuordenbar")
        let foreignLogo = try await call(app1, .POST, b + "/layouts", json: ["name": "x", "params": params(logo: sha)], token: carol.token)
        XCTAssertEqual(foreignLogo.status, .unprocessableEntity, "Logo des anderen Mandanten nicht verwendbar")
        let h10 = try await call(app1, .POST, b + "/documents/\(doc)/preview", json: [String: Any](), token: carol.token)
        XCTAssertEqual((h10).status, .notFound)
        let h11 = try await call(app1, .POST, s.docs + "/\(doc)/preview", json: ["layout_id": UUID().uuidString], token: s.w.alice.token)
        XCTAssertEqual((h11).status, .unprocessableEntity)
        // Pfad des Mandanten A ohne Mitgliedschaft
        let dave = try await addUser("owner", handle: "dave", tenant: tenantB, by: carol)
        for path in ["/layouts", "/layouts/\(id)", "/previews/\(previewID)", "/layout-assignments"] {
            let r = try await call(app1, .GET, base(s.w.tenantA) + path, token: dave.token)
            XCTAssertEqual(r.status, .notFound, path)
        }
        // SQL: Version mit Layout eines anderen Mandanten ist unmöglich
        do {
            try await db.raw(SQLQueryString("INSERT INTO invoice_layout_versions (tenant_id, layout_id, version, params) VALUES ('\(tenantB)', '\(id)', 9, '{}'::jsonb)")).run()
            XCTFail("Version über die Mandantengrenze")
        } catch {}
    }

    /// AK-R6d-4: Rechte: Layouts lesen wie Stammdaten, ändern nur Buchhaltung/Owner, Vorschau anfordern wer Belege bearbeitet, abrufen wer Belege liest.
    func testAKR6d_4_permissionMatrix() async throws {
        let s = try await setup()
        let h12 = try await createLayout(s, params: params())
        let id = try XCTUnwrap((h12).json["id"] as? String)
        let doc = try await draft(s)
        var sessions: [Role: TestSession] = [.owner: s.w.alice]
        for role in Role.allCases where role != .owner { sessions[role] = try await addUser(role.rawValue, handle: "u_" + role.rawValue, tenant: s.w.tenantA, by: s.w.alice) }
        let declared = InvoiceModule().permissions
        func allowed(_ role: Role, _ p: String) -> Bool { declared.contains { $0.name == p && (role == .owner || $0.roles.contains(role)) } }
        let h13 = try await preview(s, doc)
        let ownerPreview = try XCTUnwrap((h13).json["id"] as? String)
        for role in Role.allCases {
            let token = sessions[role]!.token
            let read = allowed(role, "invoice.master.read"), manage = allowed(role, "invoice.master.manage")
            let h14 = try await call(app1, .GET, layoutsPath(s), token: token)
            XCTAssertEqual((h14).status, read ? .ok : .forbidden, "list \(role)")
            let h15 = try await call(app2, .GET, layoutsPath(s) + "/\(id)", token: token)
            XCTAssertEqual((h15).status, read ? .ok : .forbidden, "get \(role)")
            let h16 = try await call(app1, .GET, base(s.w.tenantA) + "/layout-assignments", token: token)
            XCTAssertEqual((h16).status, read ? .ok : .forbidden, "assignments \(role)")
            let h17 = try await createLayout(s, name: "r_" + role.rawValue, params: params(), token: token)
            XCTAssertEqual((h17).status, manage ? .created : .forbidden, "create \(role)")
            let h18 = try await call(app1, .POST, layoutsPath(s) + "/\(id)/versions", json: ["params": params()], token: token)
            XCTAssertEqual((h18).status, manage ? .created : .forbidden, "version \(role)")
            let h19 = try await assign(s, [["layout_id": id]], token: token)
            XCTAssertEqual((h19).status, manage ? .ok : .forbidden, "assign \(role)")
            let h20 = try await upload(s, TestImages.png(), type: "image/png", token: token)
            XCTAssertEqual((h20).status, manage ? .created : .forbidden, "logo \(role)")
            let h21 = try await preview(s, doc, token: token)
            XCTAssertEqual((h21).status, allowed(role, "invoice.document.update") ? .accepted : .forbidden, "preview \(role)")
            let got = try await previewPDF(s, ownerPreview, token: token)
            XCTAssertEqual(got.status == .forbidden, !allowed(role, "invoice.document.read"), "preview get \(role): \(got.status)")
        }
        XCTAssertFalse(allowed(.member, "invoice.master.manage")); XCTAssertTrue(allowed(.member, "invoice.document.update"))
        let h22 = try await raw(app1, .GET, layoutsPath(s))
        XCTAssertEqual((h22).status, .unauthorized)
        let h23 = try await raw(app1, .GET, base(s.w.tenantA) + "/previews/\(ownerPreview)")
        XCTAssertEqual((h23).status, .unauthorized)
    }
}

// MARK: AK-R6d-5 Vorschau über den Worker

final class InvoicePreviewTests: InvoiceLayoutTestBase {

    /// AK-R6d-5: Vorschau eines Entwurfs: API reiht `invoice.preview` ein (Instanz 1), der Worker rendert (Instanz 2), das PDF kommt über Instanz 1.
    /// Abgelegt in `invoice_previews` (Datenbank, kein Objektspeicher, keine `files`-Zeile), Ablauf nach 15 Minuten; der Beleg bleibt Entwurf.
    func testAKR6d_5_draftPreviewViaWorker() async throws {
        let s = try await setup()
        let h24 = try await createLayout(s, params: params(header: "Vorschau-Kopf"))
        let id = try XCTUnwrap((h24).json["id"] as? String)
        let h25 = try await assign(s, [["document_kind": "invoice", "layout_id": id]])
        XCTAssertEqual((h25).status, .ok)
        let doc = try await draft(s)
        let filesBefore = try await count("files"), chunksBefore = try await count("object_chunks")
        let r = try await preview(s, doc)
        XCTAssertEqual(r.status, .accepted, "\(r.json)")
        let pid = try XCTUnwrap(r.json["id"] as? String)
        XCTAssertEqual(r.json["status"] as? String, "pending")
        let ttl = try await value("SELECT extract(epoch FROM expires_at - created_at)::int AS v FROM invoice_previews WHERE id = '\(pid)'", as: Int.self)
        XCTAssertEqual(ttl, InvoicePreviewJob.ttlSeconds); XCTAssertEqual(InvoicePreviewJob.ttlSeconds, 900)
        let early = try await previewPDF(s, pid, via: app2)
        XCTAssertEqual(early.status, .conflict); XCTAssertEqual(early.problemCode, "render_pending")

        let renderer = FakeRenderer()
        try await withWorkers([makeWorkers(app2, renderer)]) { try await previewsDone() == 1 }
        let got = try await previewPDF(s, pid)
        XCTAssertEqual(got.status, .ok)
        XCTAssertEqual(got.headers.first(name: .contentType), "application/pdf")
        XCTAssertEqual(got.headers.first(name: .cacheControl), "private, no-store")
        let text = String(decoding: got.body, as: UTF8.self)
        XCTAssertTrue(text.contains("preview true") && text.contains("of ENTWURF") && text.contains("Vorschau-Kopf"), text)
        XCTAssertEqual(renderer.layouts.last?.key, id.lowercased())
        try await aEq(try await count("files"), filesBefore, "Vorschau legt keine Datei an")
        try await aEq(try await count("object_chunks"), chunksBefore, "Vorschau schreibt nicht in den Objektspeicher")
        try await aEq(try await count("invoice_render_states"), 0)
        try await aEq(try await value("SELECT status AS v FROM invoice_documents WHERE id = '\(doc)'", as: String.self), "draft")
        try await aEq(try await value("SELECT count(*)::bigint AS v FROM invoice_documents WHERE number IS NOT NULL", as: Int64.self), 0, "keine Nummer verbraucht")

        // Ausdrücklich gewähltes Layout statt der Zuordnung
        let h26 = try await createLayout(s, name: "Anderes", params: params(header: "Anderer Kopf"))
        let other = try XCTUnwrap((h26).json["id"] as? String)
        let explicit = try await preview(s, doc, body: ["layout_id": other])
        XCTAssertEqual(explicit.status, .accepted)
        try await withWorkers([makeWorkers(app1, renderer)]) { try await previewsDone() == 2 }
        let h27 = try await previewPDF(s, explicit.json["id"] as! String)
        XCTAssertTrue(String(decoding: (h27).body, as: UTF8.self).contains("Anderer Kopf"))

        // Ablauf: abgelaufen = 404; die nächste Anforderung räumt abgelaufene Vorschauen weg
        try await db.raw(SQLQueryString("UPDATE invoice_previews SET expires_at = now() - interval '1 second' WHERE id = '\(pid)'")).run()
        let h28 = try await previewPDF(s, pid)
        XCTAssertEqual((h28).status, .notFound)
        _ = try await preview(s, doc)
        try await aEq(try await count("invoice_previews", where: "id = '\(pid)'"), 0, "abgelaufene Vorschau gelöscht")
    }

    /// AK-R6d-5: Nur Entwürfe; ein Worker schreibt nach Ablauf nichts mehr; Fehler im Renderer → `render_failed`; Obergrenze je Mandant.
    func testAKR6d_5_previewRulesAndFailures() async throws {
        let s = try await setup()
        let final = try await finalDocument(s)
        let r = try await preview(s, final)
        XCTAssertEqual(r.status, .conflict); XCTAssertEqual(r.json["code"] as? String, "document_not_draft")
        let doc = try await draft(s)
        // Renderer scheitert endgültig
        let failing = FakeRenderer(failFirst: 1)
        let h29 = try await preview(s, doc)
        let p1 = try XCTUnwrap((h29).json["id"] as? String)
        try await withWorkers([makeWorkers(app1, failing)]) { try await count("jobs", where: "kind = 'invoice.preview' AND state = 'failed_permanent'") == 1 }
        let failed = try await previewPDF(s, p1)
        XCTAssertEqual(failed.status, .conflict); XCTAssertEqual(failed.problemCode, "render_failed")
        // Abgelaufen, bevor der Worker fertig ist: der Worker schreibt nichts
        let h30 = try await preview(s, doc)
        let p2 = try XCTUnwrap((h30).json["id"] as? String)
        try await db.raw(SQLQueryString("UPDATE invoice_previews SET expires_at = now() - interval '1 second' WHERE id = '\(p2)'")).run()
        try await withWorkers([makeWorkers(app1, FakeRenderer())]) { try await previewsDone() == 1 }
        try await aEq(try await count("invoice_previews", where: "id = '\(p2)' AND pdf IS NOT NULL"), 0)
        // Obergrenze offener Vorschauen je Mandant
        try await db.raw("DELETE FROM invoice_previews").run()
        for _ in 0..<InvoicePreviewJob.maxActivePerTenant {
            let created = try await preview(s, doc)
            XCTAssertEqual(created.status, .accepted)
        }
        let over = try await preview(s, doc)
        XCTAssertEqual(over.status, .tooManyRequests, "\(over.json)")
    }
}

// MARK: Echter Renderer (Typst)

final class InvoiceLayoutRenderTests: XCTestCase {
    /// AK-R6d-1 mit Typst: Schrift, Logo, Farben und Texte erscheinen im PDF; Typst-Syntax im Fußtext bleibt Text; die Vorschau trägt den Entwurfshinweis.
    /// Ergebnis geht mit `LH_RENDER_OUT` an veraPDF (PDF/A-3b mit Logo).
    func testAKR6d_1_layoutParametersAppearInRealPDF() async throws {
        try await RenderFixtures.requireTools(qpdf: true)
        let p = try InvoiceLayoutParams.parse(InvoiceLayoutParamsFixture.full(logo: RenderFixtures.sha256(TestImages.png(width: 40, height: 20))))
        let layout = InvoiceRenderLayout(key: "test", version: 1, params: p, logo: TestImages.png(width: 40, height: 20), logoType: "image/png")
        let renderer = InvoiceRenderer(tools: RenderFixtures.tools)
        let pdf = try await renderer.render(RenderFixtures.document("invoice"), layout: layout)
        try RenderFixtures.keep(pdf, as: "layout-invoice")
        let text = try await RenderFixtures.extract(pdf)
        XCTAssertTrue(text.contains("Kopftext RE-2026-0001"), text)
        XCTAssertTrue(text.contains("#read(\"/etc/hosts\")"), text)
        let raw = String(decoding: pdf, as: UTF8.self)
        XCTAssertTrue(raw.contains("LibertinusSerif"), "gewählte Schrift eingebettet")
        XCTAssertTrue(raw.contains("/Image"), "Logo eingebettet")
        let again = try await renderer.render(RenderFixtures.document("invoice"), layout: layout)
        XCTAssertEqual(again, pdf, "gleiche Eingabe, gleiche Bytes")

        let previewJSON = try RenderFixtures.document("invoice") { $0["status"] = "preview"; $0["number"] = "ENTWURF" }
        let preview = try await renderer.render(previewJSON, layout: layout)
        try RenderFixtures.keep(preview, as: "layout-preview")
        let previewText = try await RenderFixtures.extract(preview)
        XCTAssertTrue(previewText.contains("ENTWURF – Vorschau, kein gültiger Beleg"), previewText)
    }
}

enum InvoiceLayoutParamsFixture {
    static func full(logo: String) -> [String: Any] {
        ["schema": 1, "base": "standard", "font": "Libertinus Serif", "colors": ["accent": "#1F4E79", "text": "#202020"],
         "logo": ["sha256": logo, "width_mm": 30, "align": "left"],
         "texts": ["header": "Kopftext {{number}}", "footer": "Fußtext #read(\"/etc/hosts\") {{sender}}"]]
    }
}
