import XCTVapor
import Fluent
import SQLKit
@testable import HubKit

// WP-H6: Sicherheitsbefunde und Lücken aus K1, K4, K5, D2, F4, O2. Nur synthetische Daten.

/// Befund 1 (D2): Blob-Aufräumen nach Fehlern, Dedup bleibt unberührt.
final class DMSUploadCleanupTests: DMSTestBase {

    func chunkHashes() async throws -> Int64 { try await scalar("SELECT count(DISTINCT sha256)::bigint AS v FROM object_chunks", as: Int64.self) }

    /// Fehler nach dem Speichern (unbekannter Dokumenttyp -> 422): der neue Blob verschwindet, keine `files`-Zeile bleibt.
    func testH6_1_failedUploadLeavesNoBlob() async throws {
        let w = try await world()
        let r = try await upload(w.alice, w.tenantA, pdf("fail-1", padding: 2000), query: "document_type_id=\(UUID().uuidString)")
        XCTAssertEqual(r.status, .unprocessableEntity, "\(r.json)")
        try await aEq(try await chunkHashes(), 0)
        try await aEq(try await count("files"), 0)
        try await aEq(try await count("dms_documents"), 0)
        try await aEq(try await count("idempotency_keys"), 0, "Key wieder frei")
    }

    /// Gleicher Key mit anderem Inhalt (422 idempotency_key_reused): nur der Blob des ersten Uploads bleibt.
    func testH6_1_keyConflictDiscardsSecondBlob() async throws {
        let w = try await world()
        let key = "k-" + UUID().uuidString
        let first = try await upload(w.alice, w.tenantA, pdf("first", padding: 100), key: key)
        XCTAssertEqual(first.status, .created)
        let second = try await upload(w.alice, w.tenantA, pdf("second", padding: 100), key: key, via: app2)
        XCTAssertEqual(second.status, .unprocessableEntity)
        XCTAssertEqual(second.problemCode, "idempotency_key_reused")
        try await aEq(try await chunkHashes(), 1)
        try await aEq(try await count("files"), 1)
        // Wiederholung des ersten Uploads liefert weiter dieselbe Antwort und der Blob ist da
        let replay = try await upload(w.alice, w.tenantA, pdf("first", padding: 100), key: key, via: app2)
        XCTAssertEqual(replay.status, .created); XCTAssertEqual(replay.json["id"] as? String, first.json["id"] as? String)
        try await aEq(try await chunkHashes(), 1)
    }

    /// Dedup: ein fehlgeschlagener Upload derselben Bytes darf den Blob des bestehenden Dokuments nicht löschen.
    func testH6_1_failedDuplicateKeepsReferencedBlob() async throws {
        let w = try await world()
        let data = pdf("dedup", padding: 500)
        let doc = try await upload(w.alice, w.tenantA, data)
        XCTAssertEqual(doc.status, .created)
        let bad = try await upload(w.alice, w.tenantA, data, query: "document_type_id=\(UUID().uuidString)")
        XCTAssertEqual(bad.status, .unprocessableEntity)
        try await aEq(try await chunkHashes(), 1)
        let dl = try await raw(app2, .GET, base(w.tenantA) + "/documents/\(doc.json["id"] as! String)/file", token: w.alice.token)
        XCTAssertEqual(dl.status, .ok); XCTAssertEqual(dl.body, data)
    }

    /// Gleichzeitig: gleiche Bytes, Hälfte scheitert (422), Hälfte gelingt. Jedes entstandene Dokument bleibt herunterladbar (kein Blob unter dem Dokument weg);
    /// ein Erfolg-Versuch darf höchstens mit 409 `upload_interrupted` (Wiederholung) enden, nie mit kaputtem Dokument.
    func testH6_1_parallelFailuresNeverBreakSuccessfulUploads() async throws {
        let w = try await world()
        let data = pdf("race", padding: 800)
        let token = w.alice.token, tenant = w.tenantA, a1 = app1!, a2 = app2!
        let results = try await parallel(16) { [self] i in
            try await raw(i % 2 == 0 ? a1 : a2, .POST, base(tenant) + "/uploads" + (i % 4 < 2 ? "?document_type_id=\(UUID().uuidString)" : ""), body: data, token: token,
                          headers: ["Content-Type": "application/octet-stream", "Idempotency-Key": UUID().uuidString])
        }
        for r in results { XCTAssertTrue([.created, .unprocessableEntity, .conflict].contains(r.status), "\(r.status) \(r.json)") }
        let docs = try await scalar("SELECT count(*)::bigint AS v FROM dms_documents", as: Int64.self)
        let ids = try await db.raw("SELECT id::text AS id FROM dms_documents").all().map { try $0.decode(column: "id", as: String.self) }
        XCTAssertEqual(Int64(ids.count), docs)
        for id in ids {
            let dl = try await raw(app1, .GET, base(tenant) + "/documents/\(id)/file", token: token)
            XCTAssertEqual(dl.status, .ok); XCTAssertEqual(dl.body, data)
        }
        // genau eine files-Zeile, falls irgendein Upload gelang; sonst kein Blob
        try await aEq(try await chunkHashes(), docs > 0 ? 1 : 0)
        try await aEq(try await count("files"), docs > 0 ? 1 : 0)
    }
}

/// Befund 1 (D2): Speicherquota je Mandant.
final class DMSQuotaTests: DMSTestBase {
    static let quota: Int64 = 5000
    override var testModules: [any HubModule] {
        [DMSModule(objectStore: ObjectStoreConfig(kind: .db), maxUploadBytes: Self.uploadLimit, tenantQuotaBytes: Self.quota)]
    }

    func testH6_1_quotaRejectsWithGermanMessageAndDiscardsBlob() async throws {
        let w = try await world()
        let one = try await upload(w.alice, w.tenantA, pdf("q1", padding: 2500))
        XCTAssertEqual(one.status, .created, "\(one.json)")
        let two = try await upload(w.alice, w.tenantA, pdf("q2", padding: 2500))
        XCTAssertEqual(two.status, .payloadTooLarge, "\(two.json)")
        XCTAssertEqual(two.problemCode, "storage_quota_exceeded")
        XCTAssertEqual(two.json["title"] as? String, "Der Speicherplatz dieses Mandanten ist ausgeschöpft.")
        try await aEq(try await count("dms_documents"), 1)
        try await aEq(try await scalar("SELECT count(DISTINCT sha256)::bigint AS v FROM object_chunks", as: Int64.self), 1)
        try await aEq(try await count("files"), 1)
        let used = try await scalar("SELECT sum(size_bytes)::bigint AS v FROM files", as: Int64.self)
        XCTAssertLessThanOrEqual(used, Self.quota)
    }

    /// Ohne Content-Length (nicht prüfbar vor dem Lesen) greift die Endprüfung nach dem Speichern: dieselbe Ablehnung, Blob verworfen.
    func testH6_1_quotaFinalCheckAfterStore() async throws {
        let w = try await world()
        // Vorbelegung ohne Datei: Zeile in `files` (nur Zahlen, keine Nutzdaten)
        try await db.raw("INSERT INTO files (tenant_id, sha256, size_bytes, backend, storage_key) VALUES (\(bind: UUID(uuidString: w.tenantA)!), \(bind: String(repeating: "a", count: 64)), 4000, 'db', 'x')").run()
        let r = try await upload(w.alice, w.tenantA, pdf("q3", padding: 2500))
        XCTAssertEqual(r.status, .payloadTooLarge); XCTAssertEqual(r.problemCode, "storage_quota_exceeded")
        try await aEq(try await scalar("SELECT count(DISTINCT sha256)::bigint AS v FROM object_chunks", as: Int64.self), 0)
        // eine kleine Datei passt noch (4000 + ~150 <= 5000)
        let small = try await upload(w.alice, w.tenantA, pdf("q4"))
        XCTAssertEqual(small.status, .created, "\(small.json)")
    }

    /// Fremde Mandanten zählen nicht mit.
    func testH6_1_quotaIsPerTenant() async throws {
        let w = try await world()
        try await db.raw("INSERT INTO files (tenant_id, sha256, size_bytes, backend, storage_key) VALUES (\(bind: UUID()), \(bind: String(repeating: "b", count: 64)), 9000000, 'db', 'x')").run()
        let r = try await upload(w.alice, w.tenantA, pdf("q5", padding: 2500))
        XCTAssertEqual(r.status, .created, "\(r.json)")
    }

    /// Gleichzeitige Uploads überschreiten das Limit nie (Sperre je Mandant): 6 x ~1,9 KB bei 5 KB Limit -> genau 2 gelingen.
    func testH6_1_parallelUploadsNeverExceedQuota() async throws {
        let w = try await world()
        let token = w.alice.token, tenant = w.tenantA, a1 = app1!, a2 = app2!
        let results = try await parallel(6) { [self] i in
            try await raw(i % 2 == 0 ? a1 : a2, .POST, base(tenant) + "/uploads", body: pdf("par-\(i)", padding: 1800), token: token,
                          headers: ["Content-Type": "application/octet-stream", "Idempotency-Key": UUID().uuidString])
        }
        XCTAssertEqual(results.filter { $0.status == .created }.count, 2, "\(results.map(\.status))")
        XCTAssertEqual(results.filter { $0.status == .payloadTooLarge }.count, 4)
        let used = try await scalar("SELECT sum(size_bytes)::bigint AS v FROM files", as: Int64.self)
        XCTAssertLessThanOrEqual(used, Self.quota)
        try await aEq(try await scalar("SELECT count(DISTINCT sha256)::bigint AS v FROM object_chunks", as: Int64.self), 2)
    }

    func testH6_1_quotaConfigFromEnvironment() {
        XCTAssertEqual(DMSModule(environment: ["DMS_TENANT_QUOTA_BYTES": "12345"]).tenantQuotaBytes, 12345)
        XCTAssertEqual(DMSModule(environment: ["DMS_TENANT_QUOTA_BYTES": "nonsense"]).tenantQuotaBytes, 1024 * 1024 * 1024 * 1024)
        XCTAssertEqual(DMSModule(environment: [:]).tenantQuotaBytes, 1024 * 1024 * 1024 * 1024)
    }
}

/// Befund 2 (K5/D2): nach einem Merge keine neuen Verweise auf den Quellkontakt.
final class ContactMergedReferenceTests: DMSTestBase {
    func testH6_2_noNewLinksOrCorrespondentOnMergedSource() async throws {
        let w = try await world()
        let core = "api/v1/tenants/\(w.tenantA)", a = base(w.tenantA)
        let target = (try await call(app1, .POST, core + "/contacts", json: ["kind": "organization", "display_name": "Ziel GmbH"], token: w.alice.token)).json["id"] as! String
        let source = (try await call(app1, .POST, core + "/contacts", json: ["kind": "organization", "display_name": "Quelle GmbH"], token: w.alice.token)).json["id"] as! String
        let doc = try await newDoc(w.alice, w.tenantA, seed: "merged-ref")["id"] as! String
        let merge = try await call(app1, .POST, core + "/contacts/\(target)/merge", json: ["source_id": source], token: w.alice.token)
        XCTAssertEqual(merge.status, .ok, "\(merge.json)")

        // Korrespondent auf den Quellkontakt: abgelehnt, nichts verknüpft; auf das Ziel: geht
        let viaSource = try await call(app2, .PATCH, a + "/documents/\(doc)", json: ["correspondent_id": source], token: w.alice.token)
        XCTAssertEqual(viaSource.status, .unprocessableEntity, "\(viaSource.json)")
        try await aEq(try await count("links", where: "from_id = '\(doc)' AND removed_at IS NULL"), 0)
        let viaTarget = try await call(app1, .PATCH, a + "/documents/\(doc)", json: ["correspondent_id": target], token: w.alice.token)
        XCTAssertEqual(viaTarget.status, .ok, "\(viaTarget.json)")

        // Kern-Links: in beide Richtungen auf den Quellkontakt abgelehnt (404 wie bei gelöschten Kontakten)
        let before = try await count("links")
        for body in [["from_type": "contact", "from_id": source, "to_type": "dms.document", "to_id": doc, "kind": "related"],
                     ["from_type": "dms.document", "from_id": doc, "to_type": "contact", "to_id": source, "kind": "related"]] {
            let r = try await call(app1, .POST, core + "/links", json: body, token: w.alice.token)
            XCTAssertEqual(r.status, .notFound, "\(r.json)")
        }
        try await aEq(try await count("links"), before)
        let ok = try await call(app1, .POST, core + "/links", json: ["from_type": "dms.document", "from_id": doc, "to_type": "contact", "to_id": target, "kind": "related"], token: w.alice.token)
        XCTAssertEqual(ok.status, .created, "\(ok.json)")
    }
}

/// Befund 3 (K4): Idempotency-Middleware an einer Stream-Route.
final class IdempotencyStreamTests: AuthTestCase {
    func testH6_3_streamRoutesAreRejectedAndStoreNothing() async throws {
        let tenant = UUID()
        for app in [app1!, app2!] {
            app.on(.POST, "api", "v1", "tenants", ":tenant", "streamed", body: .stream) { _ in "ok" }   // ohne Middleware: Basis zum Vergleich
            app.grouped(IdempotencyMiddleware()).on(.POST, "api", "v1", "tenants", ":tenant", "guarded", body: .stream) { _ in "ok" }
            app.grouped(IdempotencyMiddleware()).on(.POST, "api", "v1", "tenants", ":tenant", "buffered") { _ -> Response in
                let r = Response(status: .created, body: .init(string: "{}")); r.headers.contentType = .json; return r
            }
        }
        var h = HTTPHeaders(); h.replaceOrAdd(name: "Idempotency-Key", value: "s-\(UUID())")
        // Stream-Routen gibt es nur mit echtem Listener (der In-Memory-Tester puffert den Body immer)
        let live = try app1.testable(method: .running(hostname: "127.0.0.1", port: 0))
        for content in [String(repeating: "x", count: 4_000_000) + "A", String(repeating: "x", count: 4_000_000) + "B"] {  // groß genug, damit Vapor den Body nicht vorab sammelt
            try await live.test(.POST, "api/v1/tenants/\(tenant)/guarded", headers: h, beforeRequest: { $0.body = ByteBuffer(string: content) }) { res async throws in
                XCTAssertEqual(res.status, .internalServerError, "unterschiedliche Inhalte unter demselben Key dürfen nie als Wiederholung durchgehen")
            }
        }
        let n = try await scalar("SELECT count(*)::bigint AS v FROM idempotency_keys WHERE tenant_id = '\(tenant)'", as: Int64.self)
        XCTAssertEqual(n, 0, "abgewiesen vor der Reservierung")
        // gepufferte Routen bleiben unverändert; die Query gehört jetzt zum Hash
        h.replaceOrAdd(name: "Idempotency-Key", value: "b-\(UUID())")
        try await app1.test(.POST, "api/v1/tenants/\(tenant)/buffered?x=1", headers: h, beforeRequest: { $0.body = ByteBuffer(string: "a") }) { res async throws in XCTAssertEqual(res.status, .created) }
        try await app2.test(.POST, "api/v1/tenants/\(tenant)/buffered?x=1", headers: h, beforeRequest: { $0.body = ByteBuffer(string: "a") }) { res async throws in XCTAssertEqual(res.status, .created) }
        try await app2.test(.POST, "api/v1/tenants/\(tenant)/buffered?x=2", headers: h, beforeRequest: { $0.body = ByteBuffer(string: "a") }) { res async throws in
            XCTAssertEqual(res.status, .unprocessableEntity)
        }
        try await db.raw("DELETE FROM idempotency_keys WHERE tenant_id = \(bind: tenant)").run()
    }
}

/// Befund 4 (K1): Trusted Proxies für das Rate-Limit.
final class TrustedProxiesTests: XCTestCase {
    func testH6_4_defaultTrustsNobody() throws {
        let t = try TrustedProxies.parse(nil)
        XCTAssertTrue(t.isEmpty)
        XCTAssertEqual(t.client(peer: "203.0.113.5", forwardedFor: ["198.51.100.9"]), "203.0.113.5")
        XCTAssertEqual(t.client(peer: nil, forwardedFor: ["198.51.100.9"]), "unknown")
    }

    func testH6_4_headerOnlyFromTrustedPeersAndReadFromTheRight() throws {
        let t = try TrustedProxies.parse("10.0.0.0/8, 192.0.2.7, fd00::/8")
        // Verbindung nicht vertraut: Header ignoriert
        XCTAssertEqual(t.client(peer: "203.0.113.5", forwardedFor: ["198.51.100.9"]), "203.0.113.5")
        // vertraut: letzter nicht vertrauter Eintrag von rechts; links angehängte Fälschung zählt nicht
        XCTAssertEqual(t.client(peer: "10.1.2.3", forwardedFor: ["198.51.100.9"]), "198.51.100.9")
        XCTAssertEqual(t.client(peer: "10.1.2.3", forwardedFor: ["1.2.3.4, 198.51.100.9, 10.9.9.9"]), "198.51.100.9")
        XCTAssertEqual(t.client(peer: "192.0.2.7", forwardedFor: ["1.2.3.4", "198.51.100.9"]), "198.51.100.9")
        XCTAssertEqual(t.client(peer: "fd00::1", forwardedFor: ["2001:db8::5"]), "2001:db8::5")
        // alles vertraut: ganz links; kein Header oder Müll: Verbindungsadresse
        XCTAssertEqual(t.client(peer: "10.1.2.3", forwardedFor: ["10.4.4.4, 10.5.5.5"]), "10.4.4.4")
        XCTAssertEqual(t.client(peer: "10.1.2.3", forwardedFor: []), "10.1.2.3")
        XCTAssertEqual(t.client(peer: "10.1.2.3", forwardedFor: ["not-an-ip"]), "10.1.2.3")
        XCTAssertEqual(t.client(peer: "10.1.2.3", forwardedFor: ["unknown, 198.51.100.9"]), "198.51.100.9")
        XCTAssertEqual(t.client(peer: "10.1.2.3", forwardedFor: ["198.51.100.9, garbage"]), "10.1.2.3")
        // IPv4-mapped IPv6 gilt als IPv4
        XCTAssertEqual(t.client(peer: "::ffff:10.1.2.3", forwardedFor: ["198.51.100.9"]), "198.51.100.9")
        XCTAssertFalse(t.contains("11.0.0.1")); XCTAssertTrue(t.contains("10.255.255.255"))
    }

    func testH6_4_parseRejectsGarbageAndConfigReadsEnvironment() throws {
        for bad in ["nonsense", "10.0.0.0/33", "10.0.0.0/x", "10.0.0.1/8/8", "::1/129"] {
            XCTAssertThrowsError(try TrustedProxies.parse(bad), bad)
        }
        let env = ["DB_HOST": "db.example.org", "DB_PASSWORD": "synthetic", "TRUSTED_PROXIES": "10.0.0.0/8,192.0.2.1"]
        let c = try XCTUnwrap(HubConfig.fromEnvironment(env))
        XCTAssertTrue(c.trustedProxies.contains("10.2.3.4")); XCTAssertTrue(c.trustedProxies.contains("192.0.2.1"))
        XCTAssertTrue(try XCTUnwrap(HubConfig.fromEnvironment(["DB_HOST": "db.example.org", "DB_PASSWORD": "synthetic"])).trustedProxies.isEmpty)
        XCTAssertThrowsError(try HubConfig.fromEnvironment(env.merging(["TRUSTED_PROXIES": "oops"]) { $1 }))
    }
}

/// Befund 4 (K1) Ende-zu-Ende gegen einen echten Listener (die Verbindungsadresse ist 127.0.0.1).
final class RateLimitProxyTests: AuthTestCase {
    func run(trusted: Bool) async throws -> [HTTPStatus] {
        let app = try await makeApp()
        app.authSettings?.rateLimitMax = 2
        if trusted { app.authSettings?.trustedProxies = try TrustedProxies.parse("127.0.0.1") }
        let tester = try app.testable(method: .running(hostname: "127.0.0.1", port: 0))
        let box = UnsafeSendableBox<[HTTPStatus]>([])
        // gleicher Client (A) dreimal, danach ein anderer Client (B)
        for xff in ["198.51.100.1", "198.51.100.1", "198.51.100.1", "198.51.100.2"] {
            try await tester.test(.POST, "api/v1/auth/login/options", headers: ["X-Forwarded-For": xff]) { res async throws in box.value.append(res.status) }
        }
        try await app.asyncShutdown()
        return box.value
    }

    func testH6_4_forwardedHeaderIgnoredWithoutTrust() async throws {
        let s = try await run(trusted: false)
        // alle Anfragen zählen auf 127.0.0.1: der Wechsel des Headers umgeht das Limit nicht
        XCTAssertEqual(s, [.ok, .ok, .tooManyRequests, .tooManyRequests])
    }

    func testH6_4_forwardedHeaderUsedFromTrustedProxy() async throws {
        let s = try await run(trusted: true)
        // Client A wird begrenzt, Client B hat eigenen Zähler
        XCTAssertEqual(s, [.ok, .ok, .tooManyRequests, .ok])
    }
}

/// Befund 5 (K1): Rechte auf audit_log.
final class AuditHardeningTests: AuthTestCase {
    func testH6_5_ownerAndPublicLoseUpdateDeleteTruncateTrigger() async throws {
        let owner = try await scalar("SELECT current_user AS v", as: String.self)
        let acl = try await scalar("SELECT coalesce(relacl::text, '') AS v FROM pg_class WHERE relname = 'audit_log'", as: String.self)
        // nur INSERT (a) und SELECT (r) für den Eigentümer; kein Eintrag für PUBLIC; kein w (UPDATE), d (DELETE), D (TRUNCATE), t (TRIGGER)
        XCTAssertEqual(acl, "{\(owner)=ar/\(owner)}")
        // Trigger bleiben als zweite Schicht; INSERT und SELECT gehen weiter
        let triggers = try await scalar("SELECT count(*)::bigint AS v FROM pg_trigger WHERE tgrelid = 'audit_log'::regclass AND NOT tgisinternal", as: Int64.self)
        XCTAssertEqual(triggers, 2)
        try await db.raw("INSERT INTO audit_log (action) VALUES ('h6.test')").run()
        let n = try await scalar("SELECT count(*)::bigint AS v FROM audit_log WHERE action = 'h6.test'", as: Int64.self)
        XCTAssertEqual(n, 1)
        do { try await db.raw("UPDATE audit_log SET action = 'x'").run(); XCTFail("UPDATE hätte scheitern müssen") }
        catch { XCTAssertTrue(String(reflecting: error).lowercased().contains("append-only") || String(reflecting: error).contains("permission denied")) }
    }

    func testH6_5_revertRestoresPrivilegesAndReapplies() async throws {
        let database = app1.db(.psql)
        let owner = try await scalar("SELECT current_user AS v", as: String.self)
        try await HardenAuditLog().revert(on: database)
        let acl = try await scalar("SELECT coalesce(relacl::text, '') AS v FROM pg_class WHERE relname = 'audit_log'", as: String.self)
        XCTAssertTrue(acl.contains("\(owner)=arwdDxt"), acl)
        try await HardenAuditLog().prepare(on: database)
        let again = try await scalar("SELECT coalesce(relacl::text, '') AS v FROM pg_class WHERE relname = 'audit_log'", as: String.self)
        XCTAssertEqual(again, "{\(owner)=ar/\(owner)}")
    }
}

/// Lücke F4: leeres q durchsucht nach Filtern; Datum, Facetten, mehrere Tags.
final class DMSBrowseTests: DMSTestBase {
    func testH6_6_emptyQueryBrowsesWithDateFacetsAndTags() async throws {
        let w = try await world()
        let a = base(w.tenantA)
        func make(_ title: String, date: String?) async throws -> String {
            try await scalar("INSERT INTO dms_documents (tenant_id, title, doc_date) VALUES ('\(w.tenantA)', '\(title)', \(date.map { "'\($0)'" } ?? "NULL")) RETURNING id::text AS v", as: String.self).uppercased()
        }
        let d1 = try await make("Alpha", date: "2026-01-10"), d2 = try await make("Beta", date: "2026-03-05"), d3 = try await make("Gamma", date: "2025-12-31")
        let t1 = ((try await call(app1, .POST, a + "/tags", json: ["name": "eins"], token: w.alice.token)).json["id"] as! String)
        let t2 = ((try await call(app1, .POST, a + "/tags", json: ["name": "zwei"], token: w.alice.token)).json["id"] as! String)
        for (d, tags) in [(d1, [t1, t2]), (d2, [t1]), (d3, [t2])] {
            let r = try await call(app1, .PATCH, a + "/documents/\(d)", json: ["tag_ids": tags], token: w.alice.token)
            XCTAssertEqual(r.status, .ok, "\(r.json)")
        }
        func ids(_ r: Resp) -> [String] { items(r).compactMap { $0["id"] as? String } }

        // ohne q und ohne Filter: alle Dokumente, neueste Eingänge zuerst (Eingangszeit absteigend)
        var r = try await call(app1, .GET, a + "/search?facets=true&count=true", token: w.alice.token)
        XCTAssertEqual(r.status, .ok, "\(r.json)")
        XCTAssertEqual(Set(ids(r)), [d1, d2, d3]); XCTAssertEqual(r.json["total"] as? Int, 3)
        let facets = r.json["facets"] as? [String: Any] ?? [:]
        XCTAssertEqual((facets["tag"] as? [[String: Any]])?.count, 2)
        XCTAssertEqual((facets["year"] as? [[String: Any]])?.count, 2)
        XCTAssertTrue(items(r).allSatisfy { $0["snippet"] == nil || $0["snippet"] is NSNull })

        // Datum
        r = try await call(app2, .GET, a + "/search?date_from=2026-01-01&date_to=2026-02-28", token: w.alice.token)
        XCTAssertEqual(ids(r), [d1])
        r = try await call(app2, .GET, a + "/search?q=&date_from=2026-01-01", token: w.alice.token)
        XCTAssertEqual(Set(ids(r)), [d1, d2])
        // mehrere Tags (alle müssen zutreffen)
        r = try await call(app1, .GET, a + "/search?tag_id=\(t1),\(t2)", token: w.alice.token)
        XCTAssertEqual(ids(r), [d1])
        r = try await call(app1, .GET, a + "/search?tag_id=\(t1)&date_to=2026-02-01&facets=true", token: w.alice.token)
        XCTAssertEqual(ids(r), [d1])

        // Paging mit Cursor, vollständig und ohne Doppelte, über beide Instanzen
        var seen: [String] = [], cursor: String?
        repeat {
            r = try await call(seen.count % 2 == 0 ? app1 : app2, .GET, a + "/search?limit=1" + (cursor.map { "&cursor=\($0)" } ?? ""), token: w.alice.token)
            seen += ids(r); cursor = r.json["next_cursor"] as? String
        } while cursor != nil
        XCTAssertEqual(seen.count, 3); XCTAssertEqual(Set(seen), [d1, d2, d3])
        // neueste zuerst: d3 wurde zuletzt angelegt
        XCTAssertEqual(seen, [d3, d2, d1])

        // Papierkorb und Mandantentrennung
        _ = try await call(app1, .POST, a + "/documents/\(d2)/trash", json: ["reason": "test"], token: w.alice.token)
        r = try await call(app1, .GET, a + "/search", token: w.alice.token)
        XCTAssertEqual(Set(ids(r)), [d1, d3])
        let bob = try await call(app1, .POST, "api/v1/tenants", json: ["name": "Fremd"], token: w.alice.token)
        let other = bob.json["id"] as! String
        try await setModule(other, true, by: w.alice)
        r = try await call(app1, .GET, base(other) + "/search", token: w.alice.token)
        XCTAssertEqual(ids(r), [], "fremder Mandant sieht nichts")
        // ungültige Filter bleiben 422, Länge von q weiter begrenzt
        r = try await call(app1, .GET, a + "/search?date_from=morgen", token: w.alice.token)
        XCTAssertEqual(r.status, .unprocessableEntity)
        r = try await call(app1, .GET, a + "/search?q=" + String(repeating: "x", count: 201), token: w.alice.token)
        XCTAssertEqual(r.status, .unprocessableEntity)
    }
}

/// Lücke O2: manuelles Wiederholen eines failed_permanent-Eingangsvorgangs.
final class DMSIngestRetryRouteTests: DMSOCRTestBase {
    func quarantine(_ w: World, seed: String) async throws -> String {
        let docID = try await newDoc(w.alice, w.tenantA, seed: seed)["id"] as! String
        let engine = FakeOCREngine(); engine.behavior = { _ in throw OCRFailure(code: "pdf_encrypted", permanent: true) }
        let worker = makeWorker(engine)
        let run = Task { await worker.run() }
        try await waitFor("quarantine") { try await itemState(docID) == "failed_permanent" }
        worker.requestShutdown(); await run.value
        return docID
    }

    func retryURL(_ w: World, _ doc: String, tenant: String? = nil) -> String { base(tenant ?? w.tenantA) + "/documents/\(doc)/processing/retry" }

    func testH6_7_retryRequeuesAndWorkerCompletes() async throws {
        let w = try await world()
        let doc = try await quarantine(w, seed: "retry-1")
        try await aEq(try await count("jobs", where: "kind = 'dms.ocr'"), 1)

        let r = try await raw(app2, .POST, retryURL(w, doc), token: w.alice.token)
        XCTAssertEqual(r.status, .ok, "\(r.json)")
        XCTAssertEqual(r.json["state"] as? String, "ocr_queued")
        XCTAssertEqual(r.json["phase"] as? String, "queued")
        XCTAssertNil(r.json["error_code"] as? String)
        try await aEq(try await count("jobs", where: "kind = 'dms.ocr'"), 2)
        try await aEq(try await count("jobs", where: "kind = 'dms.ocr' AND state = 'queued' AND priority = \(DMSOCR.priorityManual)"), 1)
        try await aEq(try await auditCount("dms.ingest.retried", tenant: w.tenantA), 1)

        let engine = FakeOCREngine()
        let worker = makeWorker(engine)
        let run = Task { await worker.run() }
        try await waitFor("done after retry") { try await itemState(doc) == "done" }
        worker.requestShutdown(); await run.value
        XCTAssertEqual(engine.calls, 1)
        let st = try await processing(w, doc)
        XCTAssertEqual(st.json["phase"] as? String, "done")
        try await aEq(try await count("dms_document_texts", where: "document_id = '\(doc)'"), 1)

        // nichts mehr zu wiederholen: 409
        let again = try await raw(app1, .POST, retryURL(w, doc), token: w.alice.token)
        XCTAssertEqual(again.status, .conflict); XCTAssertEqual(again.problemCode, "ingest_not_failed")
    }

    func testH6_7_parallelRetriesHaveExactlyOneEffect() async throws {
        let w = try await world()
        let doc = try await quarantine(w, seed: "retry-par")
        let token = w.alice.token, url = retryURL(w, doc), a1 = app1!, a2 = app2!
        let results = try await parallel(8) { [self] i in try await raw(i % 2 == 0 ? a1 : a2, .POST, url, token: token) }
        XCTAssertEqual(results.filter { $0.status == .ok }.count, 1, "\(results.map(\.status))")
        XCTAssertTrue(results.filter { $0.status != .ok }.allSatisfy { $0.status == .conflict })
        try await aEq(try await count("jobs", where: "kind = 'dms.ocr'"), 2)
        try await aEq(try await auditCount("dms.ingest.retried", tenant: w.tenantA), 1)
    }

    func testH6_7_permissionsIsolationAndStates() async throws {
        let w = try await world()
        let doc = try await quarantine(w, seed: "retry-perm")
        let advisor = try await addUser("tax_advisor", handle: "berater", tenant: w.tenantA, by: w.alice)
        let denied = try await raw(app1, .POST, retryURL(w, doc), token: advisor.token)
        XCTAssertEqual(denied.status, .forbidden)
        try await aEq(try await itemState(doc), "failed_permanent")
        try await aEq(try await count("jobs", where: "kind = 'dms.ocr'"), 1)
        let anon = try await call(app1, .POST, retryURL(w, doc))
        XCTAssertEqual(anon.status, .unauthorized)

        // fremder Mandant: 404, unbekanntes Dokument: 404
        let other = (try await call(app1, .POST, "api/v1/tenants", json: ["name": "Fremd"], token: w.alice.token)).json["id"] as! String
        try await setModule(other, true, by: w.alice)
        let foreign = try await raw(app1, .POST, retryURL(w, doc, tenant: other), token: w.alice.token)
        XCTAssertEqual(foreign.status, .notFound)
        let unknown = try await raw(app1, .POST, retryURL(w, UUID().uuidString), token: w.alice.token)
        XCTAssertEqual(unknown.status, .notFound)

        // Papierkorb: 409 document_trashed, nichts geändert
        _ = try await call(app1, .POST, base(w.tenantA) + "/documents/\(doc)/trash", json: ["reason": "test"], token: w.alice.token)
        let trashed = try await raw(app1, .POST, retryURL(w, doc), token: w.alice.token)
        XCTAssertEqual(trashed.status, .conflict); XCTAssertEqual(trashed.problemCode, "document_trashed")
        try await aEq(try await itemState(doc), "failed_permanent")

        // Dokument ohne Fehlerzustand (frisch, wartet auf OCR): 409
        let fresh = try await newDoc(w.alice, w.tenantA, seed: "retry-fresh")["id"] as! String
        let notFailed = try await raw(app1, .POST, retryURL(w, fresh), token: w.alice.token)
        XCTAssertEqual(notFailed.status, .conflict); XCTAssertEqual(notFailed.problemCode, "ingest_not_failed")
    }
}
