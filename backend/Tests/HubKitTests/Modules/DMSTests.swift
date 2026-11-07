import XCTVapor
import Fluent
import SQLKit
import Crypto
@testable import HubKit

/// WP-D2: DMS-Kern. Nur synthetische Dateien (selbst erzeugte Minimal-PDFs/-PNGs, Texte aus dem Test), Domains example.org.
class DMSTestBase: AuthTestCase {
    static let uploadLimit: Int64 = 1_000_000
    override var testModules: [any HubModule] { [DMSModule(objectStore: ObjectStoreConfig(kind: .db), maxUploadBytes: Self.uploadLimit)] }

    struct World {
        let alice: TestSession   // Owner Mandant A
        let tenantA: String
    }

    func world(enable: Bool = true) async throws -> World {
        let alice = try await bootstrap(app1, VirtualAuthenticator())
        let tenant = try await scalar("SELECT tenant_id::text AS v FROM memberships WHERE user_id = '\(alice.userID)'", as: String.self)
        if enable { try await setModule(tenant, true, by: alice) }
        return World(alice: alice, tenantA: tenant)
    }

    func setModule(_ tenant: String, _ enabled: Bool, by s: TestSession, via: Application? = nil) async throws {
        let r = try await call(via ?? app1, .PUT, "api/v1/tenants/\(tenant)/modules/dms", json: ["enabled": enabled], token: s.token)
        XCTAssertEqual(r.status, .ok, "\(r.json)")
    }

    func addUser(_ role: String, handle: String, tenant: String, by: TestSession) async throws -> TestSession {
        let token = try await invite(app1, by: by, tenant: tenant, role: role)
        let r = try await register(app1, VirtualAuthenticator(), invite: token, handle: handle)
        XCTAssertEqual(r.status, .created, "\(r.json)")
        return session(r, handle: handle)
    }

    func base(_ tenant: String) -> String { "api/v1/tenants/\(tenant)/dms" }

    // MARK: Synthetische Dateien

    func pdf(_ seed: String, padding: Int = 0) -> Data {
        Data(("%PDF-1.4\n% synthetic \(seed)\n1 0 obj\n<< /Type /Catalog >>\nendobj\ntrailer\n<< /Root 1 0 R >>\n%%EOF\n" + String(repeating: "x", count: padding)).utf8)
    }
    func png(_ seed: String) -> Data { Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] + Array("synthetic \(seed)".utf8)) }
    func hex(_ d: Data) -> String { SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined() }

    // MARK: HTTP

    struct Raw: @unchecked Sendable {
        let status: HTTPStatus
        let headers: HTTPHeaders
        let body: Data
        var json: [String: Any] { (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:] }
        var problemCode: String? { json["code"] as? String }
    }

    func raw(_ app: Application, _ method: HTTPMethod, _ path: String, body: Data? = nil, token: String, headers extra: [String: String] = [:]) async throws -> Raw {
        var headers = HTTPHeaders()
        headers.bearerAuthorization = BearerAuthorization(token: token)
        for (k, v) in extra { headers.replaceOrAdd(name: k, value: v) }
        let box = UnsafeSendableBox<Raw?>(nil)
        try await app.test(method, path, headers: headers, body: body.map { ByteBuffer(data: $0) }) { res async throws in
            box.value = Raw(status: res.status, headers: res.headers, body: Data(buffer: res.body))
        }
        return box.value!
    }

    @discardableResult
    func upload(_ s: TestSession, _ tenant: String, _ data: Data, key: String = UUID().uuidString, query: String = "", via: Application? = nil) async throws -> Raw {
        try await raw(via ?? app1, .POST, base(tenant) + "/uploads" + (query.isEmpty ? "" : "?" + query), body: data, token: s.token,
                      headers: ["Content-Type": "application/octet-stream", "Idempotency-Key": key])
    }

    func newDoc(_ s: TestSession, _ tenant: String, seed: String, query: String = "") async throws -> [String: Any] {
        let r = try await upload(s, tenant, pdf(seed), query: query)
        XCTAssertEqual(r.status, .created, "\(r.json)")
        return r.json
    }

    func items(_ r: Resp) -> [[String: Any]] { r.json["items"] as? [[String: Any]] ?? [] }

    func count(_ table: String, where clause: String = "TRUE") async throws -> Int64 {
        try await scalar("SELECT count(*)::bigint AS v FROM \(table) WHERE \(clause)", as: Int64.self)
    }

    func auditCount(_ action: String, tenant: String) async throws -> Int64 {
        try await count("audit_log", where: "action = '\(action)' AND tenant_id = '\(tenant)'")
    }


    // Assertions mit asynchronem Ausdruck (XCTAssert* erlaubt kein await im Autoclosure)
    func aEq<T: Equatable>(_ a: @autoclosure () async throws -> T, _ b: @autoclosure () throws -> T, _ m: @autoclosure () -> String = "",
                           file: StaticString = #filePath, line: UInt = #line) async throws {
        let v = try await a(); let e = try b(); XCTAssertEqual(v, e, m(), file: file, line: line)
    }
    func aNil<T>(_ a: @autoclosure () async throws -> T?, _ m: @autoclosure () -> String = "", file: StaticString = #filePath, line: UInt = #line) async throws {
        let v = try await a(); XCTAssertNil(v, m(), file: file, line: line)
    }
    func aGE<T: Comparable>(_ a: @autoclosure () async throws -> T, _ b: @autoclosure () throws -> T, _ m: @autoclosure () -> String = "",
                            file: StaticString = #filePath, line: UInt = #line) async throws {
        let v = try await a(); let e = try b(); XCTAssertGreaterThanOrEqual(v, e, m(), file: file, line: line)
    }
    func aTrue(_ a: @autoclosure () async throws -> Bool, _ m: @autoclosure () -> String = "", file: StaticString = #filePath, line: UInt = #line) async throws {
        let v = try await a(); XCTAssertTrue(v, m(), file: file, line: line)
    }

    func parallel(_ n: Int, _ body: @escaping @Sendable (Int) async throws -> Raw) async throws -> [Raw] {
        try await withThrowingTaskGroup(of: Raw.self) { group in
            for i in 0..<n { group.addTask { try await body(i) } }
            var out: [Raw] = []
            for try await r in group { out.append(r) }
            return out
        }
    }
}

final class DMSTests: DMSTestBase {

    // MARK: AK-D1 Upload

    /// AK-D1: Upload erzeugt Original (Hash stimmt), Dokument und Audit-Eintrag; Download liefert dieselben Bytes (auch über die zweite Instanz);
    /// gleicher Idempotency-Key erzeugt nichts Neues (Wiederholung auf der anderen Instanz), anderer Inhalt mit gleichem Key ist 422.
    /// (Event: das Ereignissystem entsteht erst mit WP-K7; siehe Handoff.)
    func testAKD1_UploadCreatesOriginalDocumentAuditAndIsIdempotent() async throws {
        let w = try await world()
        let data = pdf("eingang-1", padding: 3000)
        let key = "key-" + UUID().uuidString
        let r = try await upload(w.alice, w.tenantA, data, key: key, query: "filename=Rechnung%20Mai.pdf&doc_date=2026-05-31")
        XCTAssertEqual(r.status, .created, "\(r.json)")
        let id = r.json["id"] as! String
        XCTAssertEqual(r.json["title"] as? String, "Rechnung Mai")
        XCTAssertEqual(r.json["doc_date"] as? String, "2026-05-31")
        XCTAssertEqual(r.json["status"] as? String, "needs_review")
        XCTAssertNil(r.json["asn"])
        let files = r.json["files"] as? [[String: Any]] ?? []
        XCTAssertEqual(files.count, 1)
        XCTAssertEqual(files.first?["role"] as? String, "original")
        XCTAssertEqual(files.first?["sha256"] as? String, hex(data))
        XCTAssertEqual(files.first?["mime"] as? String, "application/pdf")
        XCTAssertEqual(files.first?["size_bytes"] as? Int, data.count)
        try await aEq(try await count("dms_documents"), 1)
        try await aEq(try await scalar("SELECT sha256 AS v FROM files", as: String.self), hex(data))
        try await aEq(try await auditCount("dms.document.created", tenant: w.tenantA), 1)

        // Download über die andere Instanz: dieselben Bytes, sichere Header, Name aus dem Titel
        let d = try await raw(app2, .GET, base(w.tenantA) + "/documents/\(id)/file", token: w.alice.token)
        XCTAssertEqual(d.status, .ok)
        XCTAssertEqual(d.body, data)
        XCTAssertEqual(d.headers.first(name: .contentType), "application/pdf")
        XCTAssertEqual(d.headers.first(name: "X-Content-Type-Options"), "nosniff")
        XCTAssertTrue(d.headers.first(name: .contentDisposition)?.hasPrefix("attachment; filename=\"Rechnung Mai.pdf\"") == true, d.headers.first(name: .contentDisposition) ?? "")
        let inline = try await raw(app1, .GET, base(w.tenantA) + "/documents/\(id)/file?disposition=inline", token: w.alice.token)
        XCTAssertTrue(inline.headers.first(name: .contentDisposition)?.hasPrefix("inline;") == true)
        try await aEq(try await auditCount("dms.document.downloaded", tenant: w.tenantA), 2)

        // Wiederholung mit demselben Key (andere Instanz): gleiche Antwort, nichts Neues
        let again = try await upload(w.alice, w.tenantA, data, key: key, query: "filename=Rechnung%20Mai.pdf&doc_date=2026-05-31", via: app2)
        XCTAssertEqual(again.status, .created)
        XCTAssertEqual(again.json["id"] as? String, id)
        try await aEq(try await count("dms_documents"), 1)
        try await aEq(try await count("dms_document_files"), 1)
        try await aEq(try await auditCount("dms.document.created", tenant: w.tenantA), 1)

        // Gleicher Key, anderer Inhalt: 422; ohne Key: 400
        let other = try await upload(w.alice, w.tenantA, pdf("anderer-inhalt"), key: key, query: "filename=Rechnung%20Mai.pdf&doc_date=2026-05-31")
        XCTAssertEqual(other.status, .unprocessableEntity)
        XCTAssertEqual(other.problemCode, "idempotency_key_reused")
        let none = try await raw(app1, .POST, base(w.tenantA) + "/uploads", body: data, token: w.alice.token)
        XCTAssertEqual(none.status, .badRequest)
        XCTAssertEqual(none.problemCode, "idempotency_key_required")
        try await aEq(try await count("dms_documents"), 1)
    }

    /// AK-D1: Typ nur nach Magic Bytes (Endung und Content-Type zählen nicht), Größenlimit im Stream; abgelehnte Uploads hinterlassen nichts.
    func testAKD1_MagicBytesAndSizeLimit() async throws {
        let w = try await world()
        let text = try await upload(w.alice, w.tenantA, Data("Das ist nur Text, kein PDF.".utf8), query: "filename=falsch.pdf")
        XCTAssertEqual(text.status, .unsupportedMediaType)
        XCTAssertEqual(text.problemCode, "unsupported_media_type")
        XCTAssertEqual(text.headers.contentType?.serialize(), "application/problem+json")
        let exe = try await upload(w.alice, w.tenantA, Data([0x4D, 0x5A, 0x90, 0x00] + Array(repeating: 0, count: 64)), query: "filename=x.png")
        XCTAssertEqual(exe.status, .unsupportedMediaType)
        let empty = try await upload(w.alice, w.tenantA, Data())
        XCTAssertEqual(empty.status, .unsupportedMediaType)
        let tooBig = try await upload(w.alice, w.tenantA, pdf("gross", padding: Int(Self.uploadLimit)))
        XCTAssertEqual(tooBig.status, .payloadTooLarge)
        XCTAssertEqual(tooBig.problemCode, "payload_too_large")
        try await aEq(try await count("dms_documents"), 0)
        try await aEq(try await count("files"), 0)
        try await aEq(try await count("object_chunks"), 0, "abgelehnte Uploads dürfen keine Bytes zurücklassen")
        try await aEq(try await count("idempotency_keys"), 0)

        // Typen am Inhalt erkannt: PNG, JPEG, TIFF, WebP, PDF
        let ok: [(Data, String)] = [(png("a"), "image/png"), (Data([0xFF, 0xD8, 0xFF, 0xE0] + Array("synthetic jpeg".utf8)), "image/jpeg"),
                                    (Data([0x49, 0x49, 0x2A, 0x00] + Array("synthetic tiff".utf8)), "image/tiff"),
                                    (Data(Array("RIFF".utf8) + [0x10, 0, 0, 0] + Array("WEBPsynthetic".utf8)), "image/webp"), (pdf("b"), "application/pdf")]
        for (bytes, mime) in ok {
            let r = try await upload(w.alice, w.tenantA, bytes, query: "filename=egal.bin")
            XCTAssertEqual(r.status, .created, mime)
            XCTAssertEqual((r.json["files"] as? [[String: Any]])?.first?["mime"] as? String, mime)
        }
        // Eingaben werden vor dem Speichern geprüft
        for q in ["doc_date=2026-02-30", "document_type_id=kein-uuid", "archive=vielleicht", "filename=" + String(repeating: "a", count: 300)] {
            let r = try await upload(w.alice, w.tenantA, pdf("param"), query: q)
            XCTAssertEqual(r.status, .unprocessableEntity, q)
            XCTAssertEqual(r.problemCode, "validation_failed")
        }
        let unknownType = try await upload(w.alice, w.tenantA, pdf("param2"), query: "document_type_id=\(UUID().uuidString)")
        XCTAssertEqual(unknownType.status, .unprocessableEntity)
        try await aEq(try await count("dms_documents"), 5)
    }

    /// AK-D1: Dedup-Hinweis. Gleiche Bytes im Mandanten ergeben ein weiteres Dokument mit `duplicates`; die Bytes werden nur einmal gespeichert.
    func testAKD1_DuplicateHintAndByteDeduplication() async throws {
        let w = try await world()
        let data = pdf("doppelt", padding: 500)
        let first = try await newDoc(w.alice, w.tenantA, seed: "doppelt")
        _ = first
        let a = try await upload(w.alice, w.tenantA, data)
        XCTAssertEqual(a.status, .created)
        XCTAssertEqual((a.json["duplicates"] as? [String])?.count ?? 0, 0)
        let b = try await upload(w.alice, w.tenantA, data, via: app2)
        XCTAssertEqual(b.status, .created)
        XCTAssertEqual(b.json["duplicates"] as? [String], [a.json["id"] as! String])
        XCTAssertNotEqual(a.json["id"] as? String, b.json["id"] as? String)
        try await aEq(try await count("dms_documents"), 3)
        try await aEq(try await scalar("SELECT count(*)::bigint AS v FROM files WHERE sha256 = '\(hex(data))'", as: Int64.self), 1)
        try await aEq(try await scalar("SELECT count(*)::bigint AS v FROM object_chunks WHERE sha256 = '\(hex(data))'", as: Int64.self), 1)
    }

    // MARK: AK-D7 ASN

    /// AK-D7: ASN fortlaufend ab 1 je Mandant, idempotent, unveränderlich (auch per SQL); ein fehlgeschlagener Versuch hinterlässt keine Lücke.
    func testAKD7_AsnSequentialIdempotentImmutableAndGapFree() async throws {
        let w = try await world()
        let a = try await newDoc(w.alice, w.tenantA, seed: "a", query: "archive=true")
        let b = try await newDoc(w.alice, w.tenantA, seed: "b")
        let c = try await newDoc(w.alice, w.tenantA, seed: "c")
        XCTAssertEqual(a["asn"] as? Int, 1)
        XCTAssertEqual(a["status"] as? String, "archived")
        XCTAssertNil(b["asn"])
        let arch = try await call(app2, .POST, base(w.tenantA) + "/documents/\(b["id"] as! String)/archive", token: w.alice.token)
        XCTAssertEqual(arch.status, .ok, "\(arch.json)")
        XCTAssertEqual(arch.json["asn"] as? Int, 2)
        XCTAssertEqual(arch.json["status"] as? String, "archived")
        let again = try await call(app1, .POST, base(w.tenantA) + "/documents/\(b["id"] as! String)/archive", token: w.alice.token)
        XCTAssertEqual(again.json["asn"] as? Int, 2, "idempotent: vorhandene ASN bleibt")
        try await aEq(try await auditCount("dms.document.archived", tenant: w.tenantA), 2)

        // Fehlschlag (Papierkorb) vergibt nichts; die nächste Nummer ist lückenlos 3
        let cid = c["id"] as! String
        try await aEq((try await call(app1, .POST, base(w.tenantA) + "/documents/\(cid)/trash", json: ["reason": "Test"], token: w.alice.token)).status, .ok)
        let blocked = try await call(app1, .POST, base(w.tenantA) + "/documents/\(cid)/archive", token: w.alice.token)
        XCTAssertEqual(blocked.status, .conflict)
        XCTAssertEqual(blocked.problemCode, "document_trashed")
        let d = try await newDoc(w.alice, w.tenantA, seed: "d", query: "archive=true")
        XCTAssertEqual(d["asn"] as? Int, 3)
        try await aEq(try await scalar("SELECT value AS v FROM counters WHERE key = 'dms:asn'", as: Int64.self), 3)

        // Filter nach ASN
        let byAsn = try await call(app1, .GET, base(w.tenantA) + "/documents?asn=2", token: w.alice.token)
        XCTAssertEqual(items(byAsn).map { $0["id"] as? String }, [b["id"] as? String])

        // Unveränderlich auf Datenbankebene, eindeutig je Mandant
        let docID = a["id"] as! String
        do { try await db.raw("UPDATE dms_documents SET asn = 99 WHERE id = '\(docID)'").run(); XCTFail("ASN-Änderung muss scheitern") } catch {}
        do { try await db.raw("UPDATE dms_documents SET asn = 1 WHERE id = '\(b["id"] as! String)'").run(); XCTFail("doppelte ASN muss scheitern") } catch {}
        try await aEq(try await scalar("SELECT asn AS v FROM dms_documents WHERE id = '\(docID)'", as: Int64.self), 1)
    }

    /// AK-D7 und Zwei-Instanzen-Upload: dieselbe Datei parallel über beide Instanzen mit sofortiger ASN: jede Nummer genau einmal, lückenlos, Bytes einmal gespeichert.
    /// Derselbe Idempotency-Key parallel auf beiden Instanzen erzeugt genau ein Dokument.
    func testAKD7_ParallelUploadsOfSameFileOnTwoInstancesGetUniqueGaplessAsn() async throws {
        let w = try await world()
        let data = pdf("parallel", padding: 20_000)
        let token = w.alice.token, tenant = w.tenantA
        let a1 = app1!, a2 = app2!
        let results = try await parallel(16) { i in
            try await self.upload(TestSession(token: token, userID: "", csrf: "", handle: ""), tenant, data, key: "par-\(i)", query: "archive=true", via: i % 2 == 0 ? a1 : a2)
        }
        XCTAssertEqual(results.map(\.status), Array(repeating: .created, count: 16), "\(results.map { $0.json })")
        let asns = results.compactMap { $0.json["asn"] as? Int }.sorted()
        XCTAssertEqual(asns, Array(1...16), "ASN genau einmal, lückenlos")
        try await aEq(try await count("dms_documents"), 16)
        try await aEq(try await scalar("SELECT count(DISTINCT asn)::bigint AS v FROM dms_documents", as: Int64.self), 16)
        try await aEq(try await count("files"), 1, "gleiche Bytes: eine Dateizeile")
        try await aEq(try await count("object_chunks"), 1)
        try await aEq(try await scalar("SELECT value AS v FROM counters WHERE key = 'dms:asn'", as: Int64.self), 16)
        try await aEq(try await count("dms_document_files", where: "role = 'original'"), 16)

        // gleicher Key, gleicher Inhalt, parallel auf beiden Instanzen
        let sameKey = try await parallel(8) { i in
            try await self.upload(TestSession(token: token, userID: "", csrf: "", handle: ""), tenant, data, key: "einmalig", query: "archive=true", via: i % 2 == 0 ? a1 : a2)
        }
        XCTAssertTrue(sameKey.allSatisfy { $0.status == .created || $0.status == .conflict }, "\(sameKey.map { $0.status })")
        XCTAssertTrue(sameKey.contains { $0.status == .created })
        for r in sameKey where r.status == .conflict { XCTAssertEqual(r.problemCode, "idempotency_in_progress") }
        let retry = try await upload(w.alice, w.tenantA, data, key: "einmalig", query: "archive=true", via: app2)
        XCTAssertEqual(retry.status, .created)
        let ids = Set((sameKey.filter { $0.status == .created } + [retry]).compactMap { $0.json["id"] as? String })
        XCTAssertEqual(ids.count, 1, "ein Key, ein Dokument")
        try await aEq(try await count("dms_documents"), 17)
        try await aEq(try await scalar("SELECT max(asn)::bigint AS v FROM dms_documents", as: Int64.self), 17)

        // paralleles Archivieren verschiedener Dokumente beider Instanzen
        var docIDs: [String] = []
        for i in 0..<10 { docIDs.append(try await newDoc(w.alice, w.tenantA, seed: "arch-\(i)")["id"] as! String) }
        let ids2 = docIDs
        let archived = try await parallel(10) { i in
            let box = UnsafeSendableBox<Raw?>(nil)
            var headers = HTTPHeaders(); headers.bearerAuthorization = BearerAuthorization(token: token)
            try await (i % 2 == 0 ? a1 : a2).test(.POST, "api/v1/tenants/\(tenant)/dms/documents/\(ids2[i])/archive", headers: headers) { res async throws in
                box.value = Raw(status: res.status, headers: res.headers, body: Data(buffer: res.body))
            }
            return box.value!
        }
        XCTAssertEqual(archived.map(\.status), Array(repeating: .ok, count: 10))
        XCTAssertEqual(archived.compactMap { $0.json["asn"] as? Int }.sorted(), Array(18...27))
    }

    // MARK: AK-D-REV-1 Original unveränderlich

    /// AK-D-REV-1: Versuche, das Original zu ändern oder zu löschen, scheitern auf Datenbankebene (direktes SQL); abgeleitete Dateien bleiben änderbar.
    func testAKDREV1_OriginalIsImmutableInTheDatabase() async throws {
        let w = try await world()
        let doc = try await newDoc(w.alice, w.tenantA, seed: "revision", query: "archive=true")
        let id = doc["id"] as! String
        let before = try await scalar("SELECT concat_ws('|', file_id, sha256, mime, size_bytes, role) AS v FROM dms_document_files WHERE document_id = '\(id)'", as: String.self)
        let fileID = try await scalar("SELECT file_id::text AS v FROM dms_document_files WHERE document_id = '\(id)'", as: String.self)

        func expectImmutable(_ sqlText: String, _ what: String, file: StaticString = #filePath, line: UInt = #line) async {
            do {
                try await db.raw(SQLQueryString(sqlText)).run()
                XCTFail("\(what) muss scheitern", file: file, line: line)
            } catch {
                XCTAssertTrue(String(reflecting: error).contains("dms_original_immutable") || String(reflecting: error).contains("23000"), "\(what): \(error)", file: file, line: line)
            }
        }
        await expectImmutable("UPDATE dms_document_files SET mime = 'text/plain' WHERE document_id = '\(id)'", "mime ändern")
        await expectImmutable("UPDATE dms_document_files SET sha256 = '\(String(repeating: "0", count: 64))' WHERE document_id = '\(id)'", "Hash ändern")
        await expectImmutable("UPDATE dms_document_files SET role = 'derivative' WHERE document_id = '\(id)'", "Rolle ändern")
        await expectImmutable("UPDATE dms_document_files SET file_id = gen_random_uuid() WHERE document_id = '\(id)'", "Datei tauschen")
        await expectImmutable("DELETE FROM dms_document_files WHERE document_id = '\(id)'", "Original löschen")
        await expectImmutable("TRUNCATE dms_document_files", "Leeren")
        await expectImmutable("UPDATE files SET sha256 = '\(String(repeating: "1", count: 64))' WHERE id = '\(fileID)'", "Hash der Dateizeile ändern")
        await expectImmutable("DELETE FROM files WHERE id = '\(fileID)'", "Dateizeile löschen")
        // zweites Original je Dokument ist ausgeschlossen
        do {
            try await db.raw("""
                INSERT INTO dms_document_files (tenant_id, document_id, role, file_id, mime, size_bytes, sha256)
                SELECT tenant_id, document_id, 'original', file_id, mime, size_bytes, sha256 FROM dms_document_files WHERE document_id = '\(id)'
                """).run()
            XCTFail("zweites Original muss scheitern")
        } catch {}
        try await aEq(try await scalar("SELECT concat_ws('|', file_id, sha256, mime, size_bytes, role) AS v FROM dms_document_files WHERE document_id = '\(id)'", as: String.self), before)

        // Download liefert weiter die Originalbytes; das Original eines Papierkorb-Dokuments ist genauso geschützt
        try await aEq((try await raw(app1, .GET, base(w.tenantA) + "/documents/\(id)/file", token: w.alice.token)).status, .ok)
        try await aEq((try await call(app1, .POST, base(w.tenantA) + "/documents/\(id)/trash", json: ["reason": "weg"], token: w.alice.token)).status, .ok)
        await expectImmutable("DELETE FROM dms_document_files WHERE document_id = '\(id)'", "Original im Papierkorb löschen")

        // Abgeleitete Dateien (Archivversion) bleiben änderbar und löschbar
        try await db.raw("""
            INSERT INTO dms_document_files (tenant_id, document_id, role, file_id, mime, size_bytes, sha256)
            SELECT tenant_id, document_id, 'archive', file_id, mime, size_bytes, sha256 FROM dms_document_files WHERE document_id = '\(id)' AND role = 'original'
            """).run()
        try await db.raw("UPDATE dms_document_files SET page_count = 3 WHERE document_id = '\(id)' AND role = 'archive'").run()
        try await db.raw("DELETE FROM dms_document_files WHERE document_id = '\(id)' AND role = 'archive'").run()
        try await aEq(try await count("dms_document_files", where: "document_id = '\(id)'"), 1)
        // Dedup-Upsert der Dateizeile (ON CONFLICT … SET sha256 = sha256) bleibt möglich
        let dup = try await upload(w.alice, w.tenantA, pdf("revision"))
        XCTAssertEqual(dup.status, .created)
    }

    // MARK: Papierkorb

    /// Papierkorb/Restore: Grund Pflicht, Rolle `dms.document.trash`, Dokument verschwindet aus der Liste und erscheint im Papierkorb, Bearbeiten gesperrt, Restore stellt alles her.
    func testTrashAndRestore() async throws {
        let w = try await world()
        let member = try await addUser("member", handle: "mia", tenant: w.tenantA, by: w.alice)
        let doc = try await newDoc(member, w.tenantA, seed: "weg", query: "archive=true&filename=weg.pdf")
        let id = doc["id"] as! String
        let keep = try await newDoc(member, w.tenantA, seed: "bleibt")
        let a = base(w.tenantA)

        let denied = try await call(app1, .POST, a + "/documents/\(id)/trash", json: ["reason": "Test"], token: member.token)
        XCTAssertEqual(denied.status, .forbidden)
        let noReason = try await call(app1, .POST, a + "/documents/\(id)/trash", json: ["reason": "  "], token: w.alice.token)
        XCTAssertEqual(noReason.status, .unprocessableEntity)
        let noBody = try await call(app1, .POST, a + "/documents/\(id)/trash", token: w.alice.token)
        XCTAssertEqual(noBody.status, .unprocessableEntity)
        try await aEq(try await count("dms_documents", where: "trashed_at IS NOT NULL"), 0)

        let trashed = try await call(app2, .POST, a + "/documents/\(id)/trash", json: ["reason": "Falsch eingescannt"], token: w.alice.token)
        XCTAssertEqual(trashed.status, .ok, "\(trashed.json)")
        XCTAssertNotNil(trashed.json["trashed_at"] as? String)
        XCTAssertEqual(trashed.json["trash_reason"] as? String, "Falsch eingescannt")
        XCTAssertEqual(trashed.json["asn"] as? Int, 1, "ASN bleibt reserviert")
        try await aEq(items(try await call(app1, .GET, a + "/documents", token: w.alice.token)).map { $0["id"] as? String }, [keep["id"] as? String])
        try await aEq(items(try await call(app1, .GET, a + "/documents?trashed=true", token: w.alice.token)).map { $0["id"] as? String }, [id])

        // gesperrt: ändern, archivieren, erneut löschen
        for (m, p, body) in [(HTTPMethod.PATCH, "/documents/\(id)", ["title": "Neu"]), (.POST, "/documents/\(id)/archive", nil), (.POST, "/documents/\(id)/trash", ["reason": "nochmal"])] as [(HTTPMethod, String, [String: Any]?)] {
            let r = try await call(app1, m, a + p, json: body, token: w.alice.token)
            XCTAssertEqual(r.status, .conflict, p)
            XCTAssertEqual(r.problemCode, "document_trashed", p)
        }
        // Original bleibt abrufbar und unverändert
        let file = try await raw(app1, .GET, base(w.tenantA) + "/documents/\(id)/file", token: w.alice.token)
        XCTAssertEqual(file.body, pdf("weg"))

        let notTrashed = try await call(app1, .POST, a + "/documents/\(keep["id"] as! String)/restore", token: w.alice.token)
        XCTAssertEqual(notTrashed.status, .conflict)
        let restored = try await call(app2, .POST, a + "/documents/\(id)/restore", token: w.alice.token)
        XCTAssertEqual(restored.status, .ok, "\(restored.json)")
        XCTAssertNil(restored.json["trashed_at"])
        XCTAssertEqual(restored.json["status"] as? String, "archived")
        XCTAssertEqual(restored.json["asn"] as? Int, 1)
        try await aEq(items(try await call(app1, .GET, a + "/documents", token: w.alice.token)).count, 2)
        try await aEq(items(try await call(app1, .GET, a + "/documents?trashed=true", token: w.alice.token)).count, 0)
        let patched = try await call(app1, .PATCH, a + "/documents/\(id)", json: ["title": "Wieder da"], token: w.alice.token)
        XCTAssertEqual(patched.status, .ok)
        try await aEq(try await auditCount("dms.document.trashed", tenant: w.tenantA), 1)
        try await aEq(try await auditCount("dms.document.restored", tenant: w.tenantA), 1)
        try await aEq(try await count("dms_documents"), 2, "nichts wurde physisch gelöscht")
        // Audit ohne Nutzdaten: der Grund steht nicht im Audit
        try await aEq(try await count("audit_log", where: "meta::text ILIKE '%Falsch%'"), 0)
    }

    // MARK: Mandantentrennung

    /// Mandantentrennung: fremde IDs liefern 404 (Dokumente, Stammdaten, Dateien), Listen zeigen nur den eigenen Mandanten, Verweise über Mandantengrenzen scheitern (auch per SQL).
    func testTenantIsolationForeignIDsAre404() async throws {
        let w = try await world()
        let tenantB = (try await call(app1, .POST, "api/v1/tenants", json: ["name": "Zweiter Mandant"], token: w.alice.token)).json["id"] as! String
        let carol = try await addUser("owner", handle: "carol", tenant: tenantB, by: w.alice)
        try await setModule(tenantB, true, by: carol)
        let a = base(w.tenantA), b = base(tenantB)

        let docA = try await newDoc(w.alice, w.tenantA, seed: "nur-in-a", query: "archive=true&title=nur-in-a")
        let idA = docA["id"] as! String
        let typeA = (try await call(app1, .POST, a + "/types", json: ["name": "Rechnung"], token: w.alice.token)).json["id"] as! String
        let tagA = (try await call(app1, .POST, a + "/tags", json: ["name": "Steuer"], token: w.alice.token)).json["id"] as! String
        XCTAssertFalse(typeA.isEmpty); XCTAssertFalse(tagA.isEmpty)

        // Carol (Mandant B) greift mit A-IDs auf B-Pfade zu
        let probes: [(HTTPMethod, String, [String: Any]?)] = [
            (.GET, "/documents/\(idA)", nil), (.PATCH, "/documents/\(idA)", ["title": "Hack"]), (.POST, "/documents/\(idA)/archive", nil),
            (.POST, "/documents/\(idA)/trash", ["reason": "x"]), (.POST, "/documents/\(idA)/restore", nil), (.GET, "/documents/\(idA)/file", nil),
            (.PATCH, "/types/\(typeA)", ["name": "Hack"]), (.DELETE, "/types/\(typeA)", nil), (.PATCH, "/tags/\(tagA)", ["name": "Hack"]), (.DELETE, "/tags/\(tagA)", nil)]
        for (m, p, body) in probes {
            let r = try await call(app2, m, b + p, json: body, token: carol.token)
            XCTAssertEqual(r.status, .notFound, "\(m) \(p)")
        }
        // Carol auf dem Pfad von Mandant A: kein Mitglied = 404 auf allen DMS-Routen
        for route in app1.moduleRoutes where route.module == "dms" {
            let path = String(route.path.dropFirst()).replacingOccurrences(of: "{tenant}", with: w.tenantA).replacingOccurrences(of: "{document}", with: idA)
                .replacingOccurrences(of: "{id}", with: typeA)
            let r = try await call(app1, HTTPMethod(rawValue: route.method), path, json: route.method == "GET" ? nil : ["title": "x"], token: carol.token)
            XCTAssertEqual(r.status, .notFound, "\(route.method) \(route.path)")
        }
        // Daten unverändert
        try await aEq(try await scalar("SELECT title AS v FROM dms_documents WHERE id = '\(idA)'", as: String.self), "nur-in-a")
        try await aEq(try await scalar("SELECT name AS v FROM dms_tags WHERE id = '\(tagA)'", as: String.self), "Steuer")

        // Listen getrennt; gleiche Datei in B: kein Hinweis auf A (keine Auskunft), eigene Dateizeile
        try await aEq(items(try await call(app1, .GET, b + "/documents", token: carol.token)).count, 0)
        try await aEq(items(try await call(app1, .GET, b + "/types", token: carol.token)).count, 0)
        let inB = try await upload(carol, tenantB, pdf("nur-in-a"))
        XCTAssertEqual(inB.status, .created)
        XCTAssertEqual((inB.json["duplicates"] as? [String])?.count ?? 0, 0)
        XCTAssertNil(inB.json["asn"] as? Int)
        try await aEq(try await count("files", where: "sha256 = '\(hex(pdf("nur-in-a")))'"), 2)
        try await aEq((try await call(app1, .POST, b + "/documents/\(inB.json["id"] as! String)/archive", token: carol.token)).json["asn"] as? Int, 1, "ASN-Zähler je Mandant")

        // Verweise auf fremde Stammdaten: 422 über die API, Fehler auch per SQL (zusammengesetzter Fremdschlüssel)
        let ref = try await call(app1, .PATCH, b + "/documents/\(inB.json["id"] as! String)", json: ["document_type_id": typeA], token: carol.token)
        XCTAssertEqual(ref.status, .unprocessableEntity)
        let tagRef = try await call(app1, .PATCH, b + "/documents/\(inB.json["id"] as! String)", json: ["tag_ids": [tagA]], token: carol.token)
        XCTAssertEqual(tagRef.status, .unprocessableEntity)
        do {
            try await db.raw("UPDATE dms_documents SET document_type_id = '\(typeA)' WHERE id = '\(inB.json["id"] as! String)'").run()
            XCTFail("Verweis über Mandantengrenzen muss am Fremdschlüssel scheitern")
        } catch {}
        let upType = try await upload(carol, tenantB, pdf("typ"), query: "document_type_id=\(typeA)")
        XCTAssertEqual(upType.status, .unprocessableEntity)
        // Download eines Mandanten-A-Dokuments mit A-Hash über B nicht möglich (404)
        try await aEq((try await raw(app1, .GET, b + "/documents/\(idA)/file", token: carol.token)).status, .notFound)
    }

    // MARK: AK-D8 Modul deaktiviert

    /// AK-D8: Modul nicht aktiviert oder deaktiviert = 404 `module_disabled` auf jeder DMS-Route, Daten bleiben erhalten; Navigation nur bei Aktivierung und passender Berechtigung.
    func testAKD8_ModuleDisabledIs404AndDataIsKept() async throws {
        let w = try await world(enable: false)
        let routes = app1.moduleRoutes.filter { $0.module == "dms" }
        XCTAssertGreaterThanOrEqual(routes.count, 28)
        func probe(_ expected: String?) async throws {
            for (i, route) in routes.enumerated() {
                let path = String(route.path.dropFirst()).replacingOccurrences(of: "{tenant}", with: w.tenantA)
                    .replacingOccurrences(of: "{document}", with: UUID().uuidString).replacingOccurrences(of: "{id}", with: UUID().uuidString)
                let r = try await raw(i % 2 == 0 ? app1 : app2, HTTPMethod(rawValue: route.method), path, body: route.method == "POST" && route.path.hasSuffix("uploads") ? pdf("x") : nil,
                                      token: w.alice.token, headers: ["Idempotency-Key": UUID().uuidString])
                if let expected { XCTAssertEqual(r.status, .notFound, "\(route.method) \(route.path)"); XCTAssertEqual(r.problemCode, expected, "\(route.method) \(route.path)") }
            }
        }
        try await probe("module_disabled")
        try await aEq(try await count("dms_documents"), 0)

        try await setModule(w.tenantA, true, by: w.alice)
        let nav = try await call(app1, .GET, "api/v1/tenants/\(w.tenantA)/modules", token: w.alice.token)
        XCTAssertEqual((nav.json["navigation"] as? [[String: Any]])?.contains { $0["module"] as? String == "dms" && $0["path"] as? String == "/dms" }, true)
        let viewer = try await addUser("customer_viewer", handle: "vera", tenant: w.tenantA, by: w.alice)
        let viewerNav = try await call(app1, .GET, "api/v1/tenants/\(w.tenantA)/modules", token: viewer.token)
        XCTAssertEqual((viewerNav.json["navigation"] as? [[String: Any]])?.contains { $0["module"] as? String == "dms" }, false)

        let doc = try await newDoc(w.alice, w.tenantA, seed: "bleibt", query: "archive=true")
        let type = try await call(app1, .POST, base(w.tenantA) + "/types", json: ["name": "Vertrag"], token: w.alice.token)
        XCTAssertEqual(type.status, .created)
        try await setModule(w.tenantA, false, by: w.alice, via: app2)
        try await probe("module_disabled")
        try await aEq(try await count("dms_documents"), 1, "Daten bleiben bei Deaktivierung erhalten")
        try await aEq(try await count("dms_document_types"), 1)
        try await aEq(try await count("dms_document_files"), 1)
        try await setModule(w.tenantA, true, by: w.alice)
        let back = try await call(app1, .GET, base(w.tenantA) + "/documents/\(doc["id"] as! String)", token: w.alice.token)
        XCTAssertEqual(back.status, .ok)
        XCTAssertEqual(back.json["asn"] as? Int, 1)
        _ = type
    }

    // MARK: Berechtigungen

    /// Rechte erlaubt/verboten je Route: Matrix Rolle x Route aus der Routentabelle des Moduls. Verboten = 403 ohne Nebenwirkung, erlaubt = Erfolgsstatus.
    func testPermissionMatrixPerRoute() async throws {
        let w = try await world()
        var sessions: [Role: TestSession] = [.owner: w.alice]
        for role in Role.allCases where role != .owner {
            sessions[role] = try await addUser(role.rawValue, handle: "u_" + role.rawValue, tenant: w.tenantA, by: w.alice)
        }
        // Sollzuordnung (unabhängig vom Code, MODUL-DMS.md Abschnitt 3)
        let granted: [Role: Set<String>] = [
            .owner: ["read", "create", "update", "trash", "download_original", "tag.manage", "master.manage"],
            .accountant: ["read", "create", "update", "trash", "download_original", "tag.manage", "master.manage"],
            .member: ["read", "create", "update", "download_original"],
            .taxAdvisor: ["read", "download_original"],
            .customerViewer: []]
        for (role, perms) in granted {
            let actual = Set(DMSModule().permissions.filter { role == .owner || $0.roles.contains(role) }.map { $0.name.replacingOccurrences(of: "dms.document.", with: "").replacingOccurrences(of: "dms.", with: "")
                .replacingOccurrences(of: "tag.manage", with: "tag.manage") })
            XCTAssertEqual(actual, perms, role.rawValue)
        }
        func allowed(_ role: Role, _ permission: String) -> Bool {
            granted[role]!.contains(permission.replacingOccurrences(of: "dms.document.", with: "").replacingOccurrences(of: "dms.", with: ""))
        }
        let expected: [String: HTTPStatus] = [
            "POST uploads": .created, "GET documents": .ok, "GET documents/{document}": .ok, "PATCH documents/{document}": .ok,
            "POST documents/{document}/archive": .ok, "POST documents/{document}/trash": .ok, "POST documents/{document}/restore": .ok, "GET documents/{document}/file": .ok,
            "GET search": .ok, "GET documents/{document}/processing": .ok,
            "POST documents/{document}/processing/retry": .conflict]   // WP-H6: Probe-Dokument ohne Quarantäne-Vorgang -> 409 ingest_not_failed
        let masters = ["types", "tag-groups", "tags", "storage-paths", "custom-fields"]
        var expectedAll = expected
        for m in masters { expectedAll["GET \(m)"] = .ok; expectedAll["POST \(m)"] = .created; expectedAll["PATCH \(m)/{id}"] = .ok; expectedAll["DELETE \(m)/{id}"] = .noContent }
        let routes = app1.moduleRoutes.filter { $0.module == "dms" }
        let prefix = "/api/v1/tenants/{tenant}/dms/"
        XCTAssertEqual(Set(routes.map { "\($0.method) \($0.path.replacingOccurrences(of: prefix, with: ""))" }), Set(expectedAll.keys), "jede Route braucht eine Probe")

        let base0 = try await newDoc(w.alice, w.tenantA, seed: "matrix")
        let fileDoc = base0["id"] as! String
        func fingerprint() async throws -> String {
            try await scalar("""
                SELECT concat_ws('|', (SELECT count(*) FROM dms_documents), (SELECT count(*) FROM dms_documents WHERE trashed_at IS NOT NULL), (SELECT count(*) FROM dms_documents WHERE asn IS NOT NULL),
                  (SELECT coalesce(sum(rev), 0) FROM dms_documents), (SELECT count(*) FROM dms_document_types), (SELECT count(*) FROM dms_tags), (SELECT count(*) FROM dms_tag_groups),
                  (SELECT count(*) FROM dms_storage_paths), (SELECT count(*) FROM dms_custom_fields), (SELECT count(*) FROM files), (SELECT count(*) FROM audit_log WHERE action LIKE 'dms.%')) AS v
                """, as: String.self)
        }
        let tenant = UUID(uuidString: w.tenantA)!
        var cells = 0, ok = 0, denied = 0
        for route in routes {
            let key = "\(route.method) \(route.path.replacingOccurrences(of: prefix, with: ""))"
            for role in Role.allCases {
                // frische Objekte je Zelle
                let docID = UUID(), trashedID = UUID(), typeID = UUID()
                try await db.raw("INSERT INTO dms_documents (id, tenant_id, title) VALUES (\(bind: docID), \(bind: tenant), 'Probe')").run()
                try await db.raw("INSERT INTO dms_documents (id, tenant_id, title, trashed_at, trash_reason) VALUES (\(bind: trashedID), \(bind: tenant), 'Papierkorb', now(), 'Probe')").run()
                let segment = route.path.split(separator: "/").dropFirst(5).first.map(String.init) ?? ""
                if masters.contains(segment) {
                    let table = ["types": "dms_document_types", "tag-groups": "dms_tag_groups", "tags": "dms_tags", "storage-paths": "dms_storage_paths", "custom-fields": "dms_custom_fields"][segment]!
                    let extra = segment == "storage-paths" ? ", template" : segment == "custom-fields" ? ", code, data_type" : ""
                    let vals = segment == "storage-paths" ? ", '{title}'" : segment == "custom-fields" ? ", 'probe_\(cells)', 'string'" : ""
                    let insert = "INSERT INTO \(table) (id, tenant_id, name\(extra)) VALUES ('\(typeID)', '\(w.tenantA)', 'Probe \(cells)'\(vals))"
                    try await db.raw(SQLQueryString(insert)).run()
                }
                let isTrash = route.path.hasSuffix("/restore")
                let target = route.path.hasSuffix("/file") ? fileDoc : (isTrash ? trashedID : docID).uuidString
                var path = String(route.path.dropFirst()).replacingOccurrences(of: "{tenant}", with: w.tenantA).replacingOccurrences(of: "{document}", with: target)
                    .replacingOccurrences(of: "{id}", with: typeID.uuidString)
                var body: Data?
                var headers: [String: String] = [:]
                switch key {
                case "POST uploads": body = pdf("probe-\(cells)"); headers["Idempotency-Key"] = UUID().uuidString
                case "PATCH documents/{document}": body = Data(#"{"title":"Geändert"}"#.utf8); headers["Content-Type"] = "application/json"
                case "POST documents/{document}/trash": body = Data(#"{"reason":"Probe"}"#.utf8); headers["Content-Type"] = "application/json"
                case "POST types": body = Data(#"{"name":"Neu \#(cells)"}"#.utf8); headers["Content-Type"] = "application/json"
                case "POST tag-groups": body = Data(#"{"name":"Neu \#(cells)"}"#.utf8); headers["Content-Type"] = "application/json"
                case "POST tags": body = Data(#"{"name":"Neu \#(cells)"}"#.utf8); headers["Content-Type"] = "application/json"
                case "POST storage-paths": body = Data(#"{"name":"Neu \#(cells)","template":"{doc_date:yyyy}/{title}"}"#.utf8); headers["Content-Type"] = "application/json"
                case "POST custom-fields": body = Data(#"{"name":"Neu \#(cells)","code":"neu_\#(cells)","data_type":"bool"}"#.utf8); headers["Content-Type"] = "application/json"
                case _ where route.method == "PATCH": body = Data(#"{"name":"Umbenannt \#(cells)"}"#.utf8); headers["Content-Type"] = "application/json"
                default: break
                }
                if route.path.hasSuffix("/file") { path += "?disposition=inline" }
                if route.path.hasSuffix("/search") { path += "?q=probe" }
                let before = try await fingerprint()
                let r = try await raw(cells % 2 == 0 ? app1 : app2, HTTPMethod(rawValue: route.method), path, body: body, token: sessions[role]!.token, headers: headers)
                cells += 1
                if allowed(role, route.permission) {
                    ok += 1
                    XCTAssertEqual(r.status, expectedAll[key], "\(role.rawValue) \(key): \(r.json)")
                } else {
                    denied += 1
                    XCTAssertEqual(r.status, .forbidden, "\(role.rawValue) \(key)")
                    XCTAssertEqual(r.problemCode, "forbidden")
                    XCTAssertEqual(r.headers.contentType?.serialize(), "application/problem+json")
                    try await aEq(try await fingerprint(), before, "\(role.rawValue) \(key): Nebenwirkung")
                }
            }
        }
        XCTAssertEqual(cells, routes.count * Role.allCases.count)
        XCTAssertGreaterThan(ok, 0); XCTAssertGreaterThan(denied, 0)
        // Anonym: 401
        let anon = try await call(app1, .GET, base(w.tenantA) + "/documents")
        XCTAssertEqual(anon.status, .unauthorized)
        // Ohne download_original (Rolle müsste es nicht haben): Vorschaurollen archive/thumbnail brauchen nur read
        try await aEq((try await raw(app1, .GET, base(w.tenantA) + "/documents/\(fileDoc)/file?role=archive", token: sessions[.taxAdvisor]!.token)).status, .notFound, "kein Archiv vorhanden: 404, nicht 403")
    }

    // MARK: Dokumentmetadaten und Stammdaten

    /// Stammdaten-CRUD (Typen, Tag-Gruppen, Tags, Ablagepfade, Felder) mit Validierung, Eindeutigkeit und Löschschutz.
    func testMasterDataCrud() async throws {
        let w = try await world()
        let a = base(w.tenantA)
        let t = w.alice.token

        let type = try await call(app1, .POST, a + "/types", json: ["name": "Eingangsrechnung", "code": "eingangsrechnung", "default_retention_years": 8, "description": "Lieferantenrechnungen"], token: t)
        XCTAssertEqual(type.status, .created, "\(type.json)")
        XCTAssertNil(type.json["tenant_id"])
        let typeID = type.json["id"] as! String
        let dupName = try await call(app2, .POST, a + "/types", json: ["name": "EINGANGSRECHNUNG"], token: t)
        XCTAssertEqual(dupName.status, .conflict)
        let dupCode = try await call(app1, .POST, a + "/types", json: ["name": "Andere", "code": "eingangsrechnung"], token: t)
        XCTAssertEqual(dupCode.status, .conflict)
        for (body, field) in [(["name": ""], "name"), (["name": "X", "code": "Gross Schreibung"], "code"), (["name": "X", "default_retention_years": 500], "default_retention_years"),
                              (["name": "X", "unbekannt": 1], "unbekannt"), (["name": String(repeating: "n", count: 101)], "name")] as [([String: Any], String)] {
            let r = try await call(app1, .POST, a + "/types", json: body, token: t)
            XCTAssertEqual(r.status, .unprocessableEntity, field)
            XCTAssertTrue((r.json["errors"] as? [[String: Any]] ?? []).contains { $0["field"] as? String == field }, "\(field): \(r.json)")
        }
        let renamed = try await call(app1, .PATCH, a + "/types/\(typeID)", json: ["description": NSNull(), "default_retention_years": 10], token: t)
        XCTAssertEqual(renamed.status, .ok, "\(renamed.json)")
        XCTAssertNil(renamed.json["description"] as? String)
        XCTAssertEqual(renamed.json["default_retention_years"] as? Int, 10)
        try await aEq(items(try await call(app2, .GET, a + "/types", token: t)).count, 1)

        let group = try await call(app1, .POST, a + "/tag-groups", json: ["name": "Status", "exclusive": true], token: t)
        XCTAssertEqual(group.status, .created)
        let groupID = group.json["id"] as! String
        let tagOpen = try await call(app1, .POST, a + "/tags", json: ["name": "offen", "group_id": groupID, "color": "#aa00ff"], token: t)
        let tagDone = try await call(app1, .POST, a + "/tags", json: ["name": "erledigt", "group_id": groupID], token: t)
        let tagFree = try await call(app1, .POST, a + "/tags", json: ["name": "wichtig"], token: t)
        XCTAssertEqual([tagOpen, tagDone, tagFree].map(\.status), [.created, .created, .created])
        let badColor = try await call(app1, .POST, a + "/tags", json: ["name": "bunt", "color": "rot"], token: t)
        XCTAssertEqual(badColor.status, .unprocessableEntity)
        let badGroup = try await call(app1, .POST, a + "/tags", json: ["name": "waise", "group_id": UUID().uuidString], token: t)
        XCTAssertEqual(badGroup.status, .unprocessableEntity)
        let groupInUse = try await call(app1, .DELETE, a + "/tag-groups/\(groupID)", token: t)
        XCTAssertEqual(groupInUse.status, .conflict, "Gruppe mit Tags kann nicht gelöscht werden")

        let path = try await call(app1, .POST, a + "/storage-paths", json: ["name": "Nach Jahr", "template": "{doc_date:yyyy}/{type}/{correspondent}/{title}-{asn}"], token: t)
        XCTAssertEqual(path.status, .created, "\(path.json)")
        for template in ["{unbekannt}/x", "{title", "title}"] {
            let r = try await call(app1, .POST, a + "/storage-paths", json: ["name": "Falsch \(template)", "template": template], token: t)
            XCTAssertEqual(r.status, .unprocessableEntity, template)
        }

        let select = try await call(app1, .POST, a + "/custom-fields", json: ["name": "Priorität", "code": "prio", "data_type": "select", "options": ["hoch", "niedrig"]], token: t)
        XCTAssertEqual(select.status, .created, "\(select.json)")
        let selectNoOptions = try await call(app1, .POST, a + "/custom-fields", json: ["name": "Ohne", "code": "ohne", "data_type": "select"], token: t)
        XCTAssertEqual(selectNoOptions.status, .unprocessableEntity)
        let textWithOptions = try await call(app1, .POST, a + "/custom-fields", json: ["name": "Mit", "code": "mit", "data_type": "string", "options": ["a"]], token: t)
        XCTAssertEqual(textWithOptions.status, .unprocessableEntity)
        let immutable = try await call(app1, .PATCH, a + "/custom-fields/\(select.json["id"] as! String)", json: ["data_type": "string"], token: t)
        XCTAssertEqual(immutable.status, .unprocessableEntity)
        for (code, type, extra) in [("betrag", "decimal", [:]), ("seiten", "int", [:]), ("faellig", "date", [:]), ("bezahlt", "bool", [:]), ("notiz", "string", [:]), ("kontakt", "contact", [:])] as [(String, String, [String: Any])] {
            let r = try await call(app1, .POST, a + "/custom-fields", json: ["name": "Feld \(code)", "code": code, "data_type": type], token: t)
            XCTAssertEqual(r.status, .created, code)
        }

        // Dokument: Typ, Pfad, Tags (exklusive Gruppe), Felder, If-Match
        let doc = try await newDoc(w.alice, w.tenantA, seed: "meta")
        let id = doc["id"] as! String
        let rev0 = doc["rev"] as! Int
        let bothExclusive = try await call(app1, .PATCH, a + "/documents/\(id)", json: ["tag_ids": [tagOpen.json["id"], tagDone.json["id"]]], token: t)
        XCTAssertEqual(bothExclusive.status, .unprocessableEntity)
        let set = try await call(app2, .PATCH, a + "/documents/\(id)", json: [
            "title": "Rechnung 4711", "doc_date": "2026-03-15", "document_type_id": typeID, "storage_path_id": path.json["id"]!,
            "tag_ids": [tagOpen.json["id"]!, tagFree.json["id"]!],
            "fields": ["betrag": "1190.50", "seiten": 3, "faellig": "2026-04-14", "bezahlt": false, "prio": "hoch", "notiz": "Skonto 2%"]], token: t)
        XCTAssertEqual(set.status, .ok, "\(set.json)")
        XCTAssertEqual(set.json["title"] as? String, "Rechnung 4711")
        XCTAssertEqual(set.json["document_type_id"] as? String, typeID)
        XCTAssertEqual((set.json["tag_ids"] as? [String])?.count, 2)
        let fields = set.json["fields"] as? [String: Any] ?? [:]
        XCTAssertEqual(fields["betrag"] as? String, "1190.50")
        XCTAssertEqual(fields["seiten"] as? Int, 3)
        XCTAssertEqual(fields["faellig"] as? String, "2026-04-14")
        XCTAssertEqual(fields["bezahlt"] as? Bool, false)
        XCTAssertEqual(fields["prio"] as? String, "hoch")
        XCTAssertGreaterThan(set.json["rev"] as! Int, rev0)
        for (fieldsBody, field) in [(["betrag": "12,5"], "fields.betrag"), (["seiten": "drei"], "fields.seiten"), (["faellig": "2026-13-01"], "fields.faellig"),
                                   (["prio": "mittel"], "fields.prio"), (["gibtsnicht": "x"], "fields.gibtsnicht"), (["kontakt": UUID().uuidString], "fields.kontakt")] as [([String: Any], String)] {
            let r = try await call(app1, .PATCH, a + "/documents/\(id)", json: ["fields": fieldsBody], token: t)
            XCTAssertEqual(r.status, .unprocessableEntity, field)
            XCTAssertTrue((r.json["errors"] as? [[String: Any]] ?? []).contains { $0["field"] as? String == field }, "\(field): \(r.json)")
        }
        let badDate = try await call(app1, .PATCH, a + "/documents/\(id)", json: ["doc_date": "morgen"], token: t)
        XCTAssertEqual(badDate.status, .unprocessableEntity)
        let noTitle = try await call(app1, .PATCH, a + "/documents/\(id)", json: ["title": " "], token: t)
        XCTAssertEqual(noTitle.status, .unprocessableEntity)

        let stale = try await call(app1, .PATCH, a + "/documents/\(id)", json: ["title": "Veraltet"], token: t, headers: ["If-Match": "\"\(rev0)\""])
        XCTAssertEqual(stale.status, .preconditionFailed)
        XCTAssertEqual(stale.problemCode, "precondition_failed")
        let current = set.json["rev"] as! Int
        let fresh = try await call(app1, .PATCH, a + "/documents/\(id)", json: ["fields": ["bezahlt": NSNull()], "doc_date": NSNull()], token: t, headers: ["If-Match": "\"\(current)\""])
        XCTAssertEqual(fresh.status, .ok, "\(fresh.json)")
        XCTAssertNil((fresh.json["fields"] as? [String: Any])?["bezahlt"])
        XCTAssertNil(fresh.json["doc_date"] as? String)
        try await aEq(try await count("dms_documents", where: "title = 'Rechnung 4711'"), 1)

        // Filter der Liste
        try await aEq(items(try await call(app1, .GET, a + "/documents?document_type_id=\(typeID)", token: t)).count, 1)
        try await aEq(items(try await call(app1, .GET, a + "/documents?tag_id=\(tagFree.json["id"] as! String)", token: t)).count, 1)
        try await aEq(items(try await call(app1, .GET, a + "/documents?tag_id=\(tagDone.json["id"] as! String)", token: t)).count, 0)
        try await aEq(items(try await call(app1, .GET, a + "/documents?q=4711", token: t)).count, 1)
        try await aEq(items(try await call(app1, .GET, a + "/documents?q=9999", token: t)).count, 0)
        try await aEq((try await call(app1, .GET, a + "/documents?status=kaputt", token: t)).status, .unprocessableEntity)

        // Löschschutz: Verwendete Einträge bleiben, unbenutzte lassen sich löschen
        try await aEq((try await call(app1, .DELETE, a + "/types/\(typeID)", token: t)).status, .conflict)
        try await aEq((try await call(app1, .DELETE, a + "/tags/\(tagFree.json["id"] as! String)", token: t)).status, .conflict)
        try await aEq((try await call(app1, .DELETE, a + "/storage-paths/\(path.json["id"] as! String)", token: t)).status, .conflict)
        try await aEq((try await call(app1, .DELETE, a + "/custom-fields/\(select.json["id"] as! String)", token: t)).status, .conflict)
        let cleared = try await call(app1, .PATCH, a + "/documents/\(id)", json: ["document_type_id": NSNull(), "tag_ids": [], "storage_path_id": NSNull(), "fields": ["prio": NSNull(), "betrag": NSNull(), "seiten": NSNull(), "faellig": NSNull(), "notiz": NSNull()]], token: t)
        XCTAssertEqual(cleared.status, .ok, "\(cleared.json)")
        for p in ["/types/\(typeID)", "/tags/\(tagFree.json["id"] as! String)", "/storage-paths/\(path.json["id"] as! String)", "/custom-fields/\(select.json["id"] as! String)"] {
            try await aEq((try await call(app2, .DELETE, a + p, token: t)).status, .noContent, p)
            try await aEq((try await call(app1, .DELETE, a + p, token: t)).status, .notFound, p)
        }
        try await aGE(try await auditCount("dms.type.created", tenant: w.tenantA), 1)
        try await aEq(try await auditCount("dms.type.deleted", tenant: w.tenantA), 1)
        try await aEq(try await auditCount("dms.document.updated", tenant: w.tenantA), 3)
    }

    // MARK: Korrespondent = Kontakt

    /// Korrespondent ist ein Kern-Kontakt (links kind `correspondent`): setzen, wechseln (alter Link bleibt mit removed_at), entfernen, Filter, fremder Kontakt 422,
    /// und ein Kontakt-Merge (K5) zieht den Korrespondenten der Dokumente mit.
    func testCorrespondentIsContactAndFollowsMerge() async throws {
        let w = try await world()
        let a = base(w.tenantA), core = "api/v1/tenants/\(w.tenantA)"
        let c1 = (try await call(app1, .POST, core + "/contacts", json: ["kind": "organization", "display_name": "Lieferant Eins", "is_correspondent": true], token: w.alice.token)).json["id"] as! String
        let c2 = (try await call(app1, .POST, core + "/contacts", json: ["kind": "organization", "display_name": "Lieferant Zwei"], token: w.alice.token)).json["id"] as! String
        let doc = try await newDoc(w.alice, w.tenantA, seed: "korrespondent")
        let id = doc["id"] as! String

        let set = try await call(app1, .PATCH, a + "/documents/\(id)", json: ["correspondent_id": c1], token: w.alice.token)
        XCTAssertEqual(set.status, .ok, "\(set.json)")
        XCTAssertEqual(set.json["correspondent_id"] as? String, c1)
        try await aEq(try await count("links", where: "from_type = 'dms.document' AND from_id = '\(id)' AND kind = 'correspondent' AND removed_at IS NULL"), 1)
        try await aEq(items(try await call(app2, .GET, a + "/documents?correspondent_id=\(c1)", token: w.alice.token)).count, 1)

        // gleicher Wert: nichts ändert sich; Wechsel: alter Link wird entfernt (bleibt als Historie)
        _ = try await call(app1, .PATCH, a + "/documents/\(id)", json: ["correspondent_id": c1], token: w.alice.token)
        try await aEq(try await count("links", where: "from_id = '\(id)'"), 1)
        let moved = try await call(app2, .PATCH, a + "/documents/\(id)", json: ["correspondent_id": c2], token: w.alice.token)
        XCTAssertEqual(moved.json["correspondent_id"] as? String, c2)
        try await aEq(try await count("links", where: "from_id = '\(id)' AND removed_at IS NOT NULL"), 1)
        try await aEq(try await count("links", where: "from_id = '\(id)' AND removed_at IS NULL"), 1)

        // Merge c2 -> c1 (K5): Dokument zeigt auf den Zielkontakt
        let merge = try await call(app1, .POST, core + "/contacts/\(c1)/merge", json: ["source_id": c2], token: w.alice.token)
        XCTAssertEqual(merge.status, .ok, "\(merge.json)")
        let after = try await call(app1, .GET, a + "/documents/\(id)", token: w.alice.token)
        XCTAssertEqual(after.json["correspondent_id"] as? String, c1)

        let cleared = try await call(app1, .PATCH, a + "/documents/\(id)", json: ["correspondent_id": NSNull()], token: w.alice.token)
        XCTAssertNil(cleared.json["correspondent_id"] as? String)
        try await aEq(try await count("links", where: "from_id = '\(id)' AND removed_at IS NULL"), 0)

        // Kontakt eines anderen Mandanten: 422, nichts verknüpft
        let tenantB = (try await call(app1, .POST, "api/v1/tenants", json: ["name": "Fremd"], token: w.alice.token)).json["id"] as! String
        let foreign = (try await call(app1, .POST, "api/v1/tenants/\(tenantB)/contacts", json: ["kind": "person", "display_name": "Fremd"], token: w.alice.token)).json["id"] as! String
        let r = try await call(app1, .PATCH, a + "/documents/\(id)", json: ["correspondent_id": foreign], token: w.alice.token)
        XCTAssertEqual(r.status, .unprocessableEntity)
        try await aEq(try await count("links", where: "from_id = '\(id)' AND removed_at IS NULL"), 0)
        let unknown = try await call(app1, .PATCH, a + "/documents/\(id)", json: ["correspondent_id": UUID().uuidString], token: w.alice.token)
        XCTAssertEqual(unknown.status, .unprocessableEntity)
    }

    // MARK: Migration

    /// Migration: Modul-Migration ist eingetragen, Version des Kerns unverändert, Revert und erneutes Anwenden funktionieren, Bereitschaft prüft sie mit.
    func testMigrationRevertAndReapply() async throws {
        _ = try await world(enable: false)
        try await aEq(try await count("_fluent_migrations", where: "name = 'dms_016_core'"), 1)
        try await aEq(try await scalar("SELECT max(version)::bigint AS v FROM schema_version", as: Int64.self), 17)  // WP-O1: 017 (Jobs-Priorität); das Modul selbst ändert die Version nicht
        try await app1.test(.GET, "ready") { res async throws in XCTAssertEqual(res.status, .ok) }
        try await aEq(try await count("pg_trigger", where: "tgname IN ('dms_document_files_protect', 'dms_files_protect', 'dms_documents_protect_asn')"), 3)

        let migration = CreateDMSCore()
        try await CreateDMSOCR().revert(on: app1.db(.psql))      // WP-O2: Spalte an dms_ingest_items
        try await CreateDMSSearch().revert(on: app1.db(.psql))   // WP-S1 baut auf dem Kern auf und wird zuerst zurückgenommen
        try await CreateDMSIngest().revert(on: app1.db(.psql))  // WP-O1: Ingest-Tabellen verweisen auf dms_documents
        try await migration.revert(on: app1.db(.psql))
        try await aEq(try await count("information_schema.tables", where: "table_name LIKE 'dms\\_%'"), 0)
        try await aEq(try await count("pg_trigger", where: "tgname IN ('dms_document_files_protect', 'dms_files_protect')"), 0)
        try await migration.prepare(on: app1.db(.psql))
        try await aEq(try await count("information_schema.tables", where: "table_name LIKE 'dms\\_%'"), 9)
        try await aEq(try await count("pg_trigger", where: "tgname IN ('dms_document_files_protect', 'dms_files_protect', 'dms_documents_protect_asn')"), 3)
        try await CreateDMSIngest().prepare(on: app1.db(.psql))
        try await CreateDMSSearch().prepare(on: app1.db(.psql))
        try await CreateDMSOCR().prepare(on: app1.db(.psql))
    }
}

/// Dateisystem-Objektspeicher hinter dem DMS (OBJECT_STORE=fs): Upload und Download über zwei Instanzen mit gemeinsamem Volume.
final class DMSFilesystemStoreTests: DMSTestBase {
    static let root = FileManager.default.temporaryDirectory.appendingPathComponent("labhub-d2-\(UUID().uuidString)").path
    override var testModules: [any HubModule] { [DMSModule(objectStore: ObjectStoreConfig(kind: .fs, fsPath: Self.root), maxUploadBytes: Self.uploadLimit)] }

    override func tearDown() async throws {
        try await super.tearDown()
        try? FileManager.default.removeItem(atPath: Self.root)
    }

    /// AK-D1 mit Dateisystem-Backend: Bytes im Volume, Download über die andere Instanz identisch.
    func testAKD1_UploadAndDownloadWithFilesystemBackend() async throws {
        let w = try await world()
        let data = pdf("fs-backend", padding: 70_000)
        let r = try await upload(w.alice, w.tenantA, data, query: "filename=fs.pdf")
        XCTAssertEqual(r.status, .created, "\(r.json)")
        try await aEq(try await scalar("SELECT backend AS v FROM files", as: String.self), "fs")
        try await aEq(try await count("object_chunks"), 0)
        let d = try await raw(app2, .GET, base(w.tenantA) + "/documents/\(r.json["id"] as! String)/file", token: w.alice.token)
        XCTAssertEqual(d.status, .ok)
        XCTAssertEqual(d.body, data)
        let tooBig = try await upload(w.alice, w.tenantA, pdf("gross", padding: Int(Self.uploadLimit)))
        XCTAssertEqual(tooBig.status, .payloadTooLarge)
        let leftovers = (try? FileManager.default.subpathsOfDirectory(atPath: Self.root)) ?? []
        XCTAssertFalse(leftovers.contains { $0.hasPrefix(".staging/") }, "Staging-Dateien müssen aufgeräumt sein: \(leftovers)")
    }
}
