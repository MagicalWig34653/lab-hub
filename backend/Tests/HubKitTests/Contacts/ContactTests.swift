import XCTVapor
import Fluent
import SQLKit
@testable import HubKit

/// WP-K5: Kontakte und links. Alle Daten synthetisch (Beispiel-IBAN aus der öffentlichen ISO-Dokumentation, Domains example.org).
final class ContactTests: AuthTestCase {
    static let ibanA = "DE89370400440532013000"
    static let ibanB = "GB82WEST12345698765432"

    // MARK: Hilfen

    struct World {
        let alice: TestSession   // Owner Mandant A
        let tenantA: String
    }

    func world() async throws -> World {
        let alice = try await bootstrap(app1, VirtualAuthenticator())
        let tenant = try await scalar("SELECT tenant_id::text AS v FROM memberships WHERE user_id = '\(alice.userID)'", as: String.self)
        return World(alice: alice, tenantA: tenant)
    }

    func addUser(_ role: String, handle: String, tenant: String, by: TestSession) async throws -> TestSession {
        let token = try await invite(app1, by: by, tenant: tenant, role: role)
        let r = try await register(app1, VirtualAuthenticator(), invite: token, handle: handle)
        XCTAssertEqual(r.status, .created, "\(r.json)")
        return session(r, handle: handle)
    }

    func base(_ tenant: String) -> String { "api/v1/tenants/\(tenant)" }

    @discardableResult
    func createContact(_ s: TestSession, _ tenant: String, _ body: [String: Any], via: Application? = nil) async throws -> Resp {
        try await call(via ?? app1, .POST, base(tenant) + "/contacts", json: body, token: s.token)
    }

    func newContact(_ s: TestSession, _ tenant: String, name: String, extra: [String: Any] = [:]) async throws -> String {
        var body: [String: Any] = ["kind": "organization", "display_name": name]
        for (k, v) in extra { body[k] = v }
        let r = try await createContact(s, tenant, body)
        XCTAssertEqual(r.status, .created, "\(r.json)")
        return r.json["id"] as! String
    }

    func items(_ r: Resp) -> [[String: Any]] { r.json["items"] as? [[String: Any]] ?? [] }

    func insertContact(_ tenant: String, name: String) async throws -> UUID {
        let id = UUID()
        try await db.raw("INSERT INTO contacts (id, tenant_id, kind, display_name) VALUES (\(bind: id), \(bind: UUID(uuidString: tenant)!), 'person', \(bind: name))").run()
        return id
    }

    func insertLink(_ tenant: String, from: (String, UUID), to: (String, UUID), kind: String = "related", removed: Bool = false) async throws -> UUID {
        let id = UUID()
        try await db.raw("""
            INSERT INTO links (id, tenant_id, from_type, from_id, to_type, to_id, kind, source, removed_at)
            VALUES (\(bind: id), \(bind: UUID(uuidString: tenant)!), \(bind: from.0), \(bind: from.1), \(bind: to.0), \(bind: to.1), \(bind: kind), 'manual',
                    \(unsafeRaw: removed ? "now()" : "NULL"))
            """).run()
        return id
    }

    /// Zustandsabdruck für "keine Nebenwirkung" bei verbotenen Aufrufen.
    func fingerprint() async throws -> String {
        try await scalar("""
            SELECT concat_ws('|', (SELECT count(*) FROM contacts), (SELECT count(*) FROM contacts WHERE deleted_at IS NOT NULL),
              (SELECT count(*) FROM contacts WHERE merged_into IS NOT NULL), (SELECT coalesce(max(updated_at)::text, '') FROM contacts),
              (SELECT count(*) FROM links), (SELECT count(*) FROM links WHERE removed_at IS NOT NULL), (SELECT count(*) FROM contact_aliases)) AS v
            """, as: String.self)
    }

    func auditCount(_ action: String, tenant: String) async throws -> Int64 {
        try await scalar("SELECT count(*)::bigint AS v FROM audit_log WHERE action = '\(action)' AND tenant_id = '\(tenant)'", as: Int64.self)
    }

    // MARK: AK-K5-1 CRUD

    /// AK-K5-1: Anlegen, Lesen, Ändern, Suchen, Seiten, Löschen; Person und Organisation, mehrere Adressen/E-Mails/IBANs, Aliase; Fehler als Problem-Details.
    func testAKK5_1_CrudWithChildrenSearchAndPaging() async throws {
        let w = try await world()
        let created = try await createContact(w.alice, w.tenantA, [
            "kind": "organization", "display_name": "Beispiel Handels GmbH", "company_name": "Beispiel Handels GmbH", "vat_id": "de 123.456.789",
            "is_supplier": true, "is_correspondent": true,
            "addresses": [["label": "Sitz", "street": "Musterweg 1", "postal_code": "12345", "city": "Beispielstadt", "country": "de"],
                          ["label": "Lager", "street": "Lagerstr. 2", "postal_code": "54321", "city": "Anderswo", "country": "AT"]],
            "emails": [["email": "info@example.org", "label": "Zentrale"], ["email": "INFO@example.org"], ["email": "buchhaltung@example.org"]],
            "bank_accounts": [["iban": "de89 3704 0044 0532 0130 00", "bic": "cobadeff", "holder": "Beispiel Handels GmbH"], ["iban": Self.ibanB]],
            "aliases": ["Beispiel Handel", "BH GmbH", "beispiel handel"]])
        XCTAssertEqual(created.status, .created, "\(created.json)")
        let id = created.json["id"] as! String
        XCTAssertEqual(created.json["vat_id"] as? String, "DE123456789")
        XCTAssertEqual(created.json["kind"] as? String, "organization")
        XCTAssertEqual(created.json["is_supplier"] as? Bool, true)
        XCTAssertEqual(created.json["is_customer"] as? Bool, false)

        let got = try await call(app2, .GET, base(w.tenantA) + "/contacts/\(id)", token: w.alice.token)
        XCTAssertEqual(got.status, .ok)
        let addresses = got.json["addresses"] as? [[String: Any]] ?? []
        XCTAssertEqual(addresses.map { $0["label"] as? String }, ["Sitz", "Lager"])
        XCTAssertEqual(addresses.first?["country"] as? String, "DE")
        XCTAssertEqual((got.json["emails"] as? [[String: Any]])?.count, 2, "E-Mail-Dublette (Groß-/Kleinschreibung) entfällt")
        XCTAssertEqual((got.json["bank_accounts"] as? [[String: Any]])?.map { $0["iban"] as? String }, [Self.ibanA, Self.ibanB])
        XCTAssertEqual((got.json["bank_accounts"] as? [[String: Any]])?.first?["bic"] as? String, "COBADEFF")
        XCTAssertEqual((got.json["aliases"] as? [String])?.count, 2)

        // Ändern: nur gesetzte Felder; Liste ersetzt; leerer Text löscht
        let patched = try await call(app1, .PATCH, base(w.tenantA) + "/contacts/\(id)",
                                     json: ["display_name": "Beispiel Handels AG", "company_name": "", "is_customer": true,
                                            "aliases": ["Beispiel AG"], "emails": [["email": "neu@example.org"]]], token: w.alice.token)
        XCTAssertEqual(patched.status, .ok, "\(patched.json)")
        XCTAssertEqual(patched.json["display_name"] as? String, "Beispiel Handels AG")
        XCTAssertTrue(patched.json["company_name"] == nil || patched.json["company_name"] is NSNull)
        XCTAssertEqual(patched.json["vat_id"] as? String, "DE123456789")
        XCTAssertEqual(patched.json["is_customer"] as? Bool, true)
        XCTAssertEqual(patched.json["is_supplier"] as? Bool, true)
        XCTAssertEqual(patched.json["aliases"] as? [String], ["Beispiel AG"])
        XCTAssertEqual((patched.json["emails"] as? [[String: Any]])?.count, 1)
        XCTAssertEqual((patched.json["addresses"] as? [[String: Any]])?.count, 2, "nicht genannte Listen bleiben")
        XCTAssertEqual((patched.json["bank_accounts"] as? [[String: Any]])?.count, 2)

        // Suche über Name, Alias, E-Mail, USt-ID; Rollenfilter
        let person = try await createContact(w.alice, w.tenantA, ["kind": "person", "display_name": "Erika Mustermann", "first_name": "Erika", "last_name": "Mustermann", "is_customer": true])
        XCTAssertEqual(person.status, .created)
        for (q, expected) in [("Handels", 1), ("beispiel ag", 1), ("neu@example", 1), ("DE1234", 1), ("muster", 1), ("nichts-davon", 0), ("%", 0), ("_", 0)] {
            let r = try await call(app1, .GET, base(w.tenantA) + "/contacts?q=" + q.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!, token: w.alice.token)
            XCTAssertEqual(items(r).count, expected, q)
        }
        let customers = try await call(app1, .GET, base(w.tenantA) + "/contacts?role=customer", token: w.alice.token)
        XCTAssertEqual(items(customers).count, 2)
        let people = try await call(app1, .GET, base(w.tenantA) + "/contacts?kind=person&role=customer", token: w.alice.token)
        XCTAssertEqual(items(people).map { $0["display_name"] as? String }, ["Erika Mustermann"])

        // Seiten
        for i in 0..<4 { _ = try await newContact(w.alice, w.tenantA, name: "Seite \(i)") }
        var seen: [String] = [], cursor: String?
        repeat {
            let r = try await call(app2, .GET, base(w.tenantA) + "/contacts?limit=2&count=true" + (cursor.map { "&cursor=\($0)" } ?? ""), token: w.alice.token)
            XCTAssertEqual(r.status, .ok)
            XCTAssertEqual(r.json["total"] as? Int, 6)
            seen += items(r).compactMap { $0["id"] as? String }
            cursor = r.json["next_cursor"] as? String
        } while cursor != nil
        XCTAssertEqual(seen.count, 6); XCTAssertEqual(Set(seen).count, 6)
        let badLimit = try await call(app1, .GET, base(w.tenantA) + "/contacts?limit=0", token: w.alice.token)
        XCTAssertEqual(badLimit.problemCode, "invalid_limit")

        // Löschen
        let del = try await call(app1, .DELETE, base(w.tenantA) + "/contacts/\(id)", token: w.alice.token)
        XCTAssertEqual(del.status, .noContent)
        for method in [HTTPMethod.GET, .PATCH, .DELETE] {
            let r = try await call(app2, method, base(w.tenantA) + "/contacts/\(id)", json: method == .PATCH ? ["display_name": "X"] : nil, token: w.alice.token)
            XCTAssertEqual(r.status, .notFound, "\(method)")
        }
        let remaining = try await call(app1, .GET, base(w.tenantA) + "/contacts?q=Handels", token: w.alice.token)
        XCTAssertEqual(items(remaining).count, 0)
        let kept = try await scalar("SELECT count(*)::bigint AS v FROM contacts WHERE id = '\(id)' AND deleted_at IS NOT NULL", as: Int64.self)
        XCTAssertEqual(kept, 1, "Löschen setzt deleted_at, die Zeile bleibt")
        for action in ["contact.created", "contact.updated", "contact.deleted"] {
            let n = try await auditCount(action, tenant: w.tenantA)
            XCTAssertGreaterThanOrEqual(n, 1, action)
        }
    }

    /// AK-K5-1: Eingabefehler liefern 422 `validation_failed` mit Feldfehlern im Problem-Format.
    func testAKK5_1_ValidationErrorsAreProblemDetails() async throws {
        let w = try await world()
        let cases: [([String: Any], String)] = [
            (["kind": "organization"], "display_name"), (["display_name": "X"], "kind"), (["kind": "robot", "display_name": "X"], "kind"),
            (["kind": "person", "display_name": String(repeating: "x", count: 201)], "display_name"),
            (["kind": "person", "display_name": "X", "vat_id": "123"], "vat_id"),
            (["kind": "person", "display_name": "X", "bank_accounts": [["iban": "DE89370400440532013001"]]], "bank_accounts[0].iban"),
            (["kind": "person", "display_name": "X", "emails": [["email": "kein-at"]]], "emails[0].email"),
            (["kind": "person", "display_name": "X", "addresses": [["country": "Deutschland"]]], "addresses[0].country")]
        for (body, field) in cases {
            let r = try await createContact(w.alice, w.tenantA, body)
            XCTAssertEqual(r.status, .unprocessableEntity, field)
            XCTAssertEqual(r.problemCode, "validation_failed")
            XCTAssertEqual(r.headers.contentType?.serialize(), "application/problem+json")
            XCTAssertTrue((r.json["errors"] as? [[String: Any]] ?? []).contains { $0["field"] as? String == field }, "\(field): \(r.json)")
        }
        let none = try await scalar("SELECT count(*)::bigint AS v FROM contacts", as: Int64.self)
        XCTAssertEqual(none, 0)
        XCTAssertTrue(ContactValidation.mod97(Self.ibanA) == 1 && ContactValidation.mod97(Self.ibanB) == 1)
    }

    // MARK: AK-K5-2 Mandantentrennung

    /// AK-K5-2: Fremde Kontakt-IDs liefern 404 auf jeder Kontaktroute (eigener und fremder Mandant), ohne Nebenwirkung; Listen zeigen nur den eigenen Mandanten.
    func testAKK5_2_ForeignContactIDsAre404() async throws {
        let w = try await world()
        let bobA = try await addUser("owner", handle: "bobby", tenant: w.tenantA, by: w.alice)
        let tenantB = (try await call(app1, .POST, "api/v1/tenants", json: ["name": "Zweiter Mandant"], token: w.alice.token)).json["id"] as! String
        let carol = try await addUser("owner", handle: "carol", tenant: tenantB, by: w.alice)
        let inA = try await newContact(w.alice, w.tenantA, name: "Nur in A", extra: ["vat_id": "DE111111111"])
        let inB = try await newContact(carol, tenantB, name: "Nur in B")
        let linkA = try await insertLink(w.tenantA, from: ("dms.document", UUID()), to: ("contact", UUID(uuidString: inA)!))

        // Carol (nur Mandant B) auf Mandant A: 404 auf allen Kontakt- und Linkrouten
        XCTAssertFalse(app1.contactRoutes.isEmpty)
        for route in app1.contactRoutes {
            let path = String(route.path.dropFirst()).replacingOccurrences(of: "{tenant}", with: w.tenantA).replacingOccurrences(of: "{contact}", with: inA)
                .replacingOccurrences(of: "{link}", with: linkA.uuidString)
            let body: Any? = ["GET", "DELETE"].contains(route.method) ? nil : ["display_name": "x", "source_id": inB]
            let r = try await call(app1, HTTPMethod(rawValue: route.method), path, json: body, token: carol.token)
            XCTAssertEqual(r.status, .notFound, "\(route.method) \(route.path)")
        }
        // Alice (Mitglied beider Mandanten) mit der ID aus dem anderen Mandanten: 404, keine Nebenwirkung
        let a = base(w.tenantA)
        for (method, suffix, body) in [(HTTPMethod.GET, "", nil), (.PATCH, "", ["display_name": "gekapert"]), (.DELETE, "", nil),
                                       (.GET, "/duplicates", nil), (.POST, "/merge", ["source_id": inA])] as [(HTTPMethod, String, [String: Any]?)] {
            let r = try await call(app1, method, a + "/contacts/\(inB)" + suffix, json: body, token: w.alice.token)
            XCTAssertEqual(r.status, .notFound, "\(method) \(suffix)")
            XCTAssertEqual(r.problemCode, "not_found")
        }
        // Merge mit fremder Quelle (und umgekehrt): 404, beide unverändert
        let eigener = try await newContact(w.alice, w.tenantA, name: "Eigener")
        let mergeForeignSource = try await call(app2, .POST, a + "/contacts/\(eigener)/merge", json: ["source_id": inB], token: w.alice.token)
        XCTAssertEqual(mergeForeignSource.status, .notFound)
        let stillBoth = try await scalar("SELECT count(*)::bigint AS v FROM contacts WHERE merged_into IS NULL AND deleted_at IS NULL", as: Int64.self)
        XCTAssertEqual(stillBoth, 3)
        // Link auf fremden Kontakt: 404 und kein Eintrag
        let before = try await scalar("SELECT count(*)::bigint AS v FROM links", as: Int64.self)
        let foreignLink = try await call(app1, .POST, a + "/links", json: ["from_type": "dms.document", "from_id": UUID().uuidString, "to_type": "contact", "to_id": inB, "kind": "correspondent"], token: w.alice.token)
        XCTAssertEqual(foreignLink.status, .notFound)
        let after = try await scalar("SELECT count(*)::bigint AS v FROM links", as: Int64.self)
        XCTAssertEqual(before, after)
        // Links eines fremden Objekts erscheinen nicht über den anderen Mandanten
        let leak = try await call(app1, .GET, base(tenantB) + "/links?type=contact&id=\(inA)", token: carol.token)
        XCTAssertEqual(leak.status, .ok); XCTAssertTrue(items(leak).isEmpty)
        let leakDelete = try await call(app1, .DELETE, base(tenantB) + "/links/\(linkA)", token: carol.token)
        XCTAssertEqual(leakDelete.status, .notFound)
        // Dubletten über Mandantengrenzen werden nicht gemeldet
        let dupB = try await createContact(carol, tenantB, ["kind": "organization", "display_name": "Gleiche USt", "vat_id": "DE111111111"])
        XCTAssertEqual((dupB.json["duplicates"] as? [Any])?.count, 0)
        // Listen
        let listA = try await call(app1, .GET, a + "/contacts", token: bobA.token)
        XCTAssertFalse(items(listA).contains { $0["id"] as? String == inB })
        let listB = try await call(app2, .GET, base(tenantB) + "/contacts", token: carol.token)
        XCTAssertEqual(Set(items(listB).compactMap { $0["display_name"] as? String }), ["Nur in B", "Gleiche USt"])
        let untouched = try await scalar("SELECT display_name AS v FROM contacts WHERE id = '\(inB)'", as: String.self)
        XCTAssertEqual(untouched, "Nur in B")
        // Ohne Anmeldung
        let anon = try await call(app1, .GET, a + "/contacts")
        XCTAssertEqual(anon.status, .unauthorized)
    }

    // MARK: AK-K5-3 Dubletten

    /// AK-K5-3: Gleiche USt-ID oder IBAN liefert einen Hinweis, legt aber trotzdem an; nichts wird still zusammengeführt.
    func testAKK5_3_DuplicateHintByVatIDAndIBAN() async throws {
        let w = try await world()
        let first = try await newContact(w.alice, w.tenantA, name: "Erste GmbH", extra: ["vat_id": "DE123456789", "bank_accounts": [["iban": Self.ibanA]]])
        let second = try await createContact(w.alice, w.tenantA, ["kind": "organization", "display_name": "Zweite GmbH", "vat_id": "DE 123456789"])
        XCTAssertEqual(second.status, .created)
        var hints = (second.json["duplicates"] as? [[String: Any]]) ?? []
        XCTAssertEqual(hints.count, 1)
        XCTAssertEqual(hints.first?["id"] as? String, first)
        XCTAssertEqual(hints.first?["reasons"] as? [String], ["vat_id"])
        let third = try await createContact(w.alice, w.tenantA, ["kind": "person", "display_name": "Dritte Person", "bank_accounts": [["iban": "de89 3704 0044 0532 0130 00"]]], via: app2)
        XCTAssertEqual(third.status, .created)
        hints = (third.json["duplicates"] as? [[String: Any]]) ?? []
        XCTAssertEqual(hints.map { $0["id"] as? String }, [first]); XCTAssertEqual(hints.first?["reasons"] as? [String], ["iban"])
        // Beides gleichzeitig
        let fourth = try await createContact(w.alice, w.tenantA, ["kind": "organization", "display_name": "Vierte GmbH", "vat_id": "DE123456789", "bank_accounts": [["iban": Self.ibanA]]])
        let both = (fourth.json["duplicates"] as? [[String: Any]]) ?? []
        XCTAssertEqual(both.count, 3)
        XCTAssertEqual(both.first { $0["id"] as? String == first }?["reasons"] as? [String], ["iban", "vat_id"])
        // Eigene Route; keine Dublette ohne Gemeinsamkeit; Änderung erzeugt neuen Hinweis
        let unrelated = try await newContact(w.alice, w.tenantA, name: "Einzelstück", extra: ["vat_id": "DE999999999"])
        let none = try await call(app1, .GET, base(w.tenantA) + "/contacts/\(unrelated)/duplicates", token: w.alice.token)
        XCTAssertEqual(none.status, .ok); XCTAssertTrue(items(none).isEmpty)
        let changed = try await call(app1, .PATCH, base(w.tenantA) + "/contacts/\(unrelated)", json: ["vat_id": "DE123456789"], token: w.alice.token)
        XCTAssertEqual((changed.json["duplicates"] as? [Any])?.count, 3)
        let total = try await scalar("SELECT count(*)::bigint AS v FROM contacts WHERE merged_into IS NULL", as: Int64.self)
        XCTAssertEqual(total, 5, "nichts wurde zusammengeführt oder abgelehnt")
        // Gelöschte Kontakte zählen nicht
        _ = try await call(app1, .DELETE, base(w.tenantA) + "/contacts/\(first)", token: w.alice.token)
        let afterDelete = try await call(app1, .GET, base(w.tenantA) + "/contacts/\(unrelated)/duplicates", token: w.alice.token)
        XCTAssertEqual(items(afterDelete).count, 2)
    }

    // MARK: AK-K5-4 Merge

    /// AK-K5-4: Zusammenführen ergänzt Stammdaten, schreibt links beider Richtungen auf den Zielkontakt, entfernt Kollisionen mit `removed_at` und schreibt Audit ohne Nutzdaten.
    func testAKK5_4_MergeRewritesLinksAndWritesAudit() async throws {
        let w = try await world()
        let a = base(w.tenantA)
        let target = try await newContact(w.alice, w.tenantA, name: "Muster GmbH", extra: ["vat_id": "DE123456789", "is_supplier": true,
                                          "emails": [["email": "info@example.org"]], "bank_accounts": [["iban": Self.ibanA]], "aliases": ["Muster"]])
        let source = try await newContact(w.alice, w.tenantA, name: "Muster Gesellschaft mbH", extra: [
            "is_correspondent": true, "emails": [["email": "INFO@example.org"], ["email": "alt@example.org"]],
            "bank_accounts": [["iban": Self.ibanA], ["iban": Self.ibanB, "holder": "Alt"]], "aliases": ["MG", "muster"],
            "addresses": [["street": "Altweg 3", "postal_code": "11111", "city": "Altstadt", "country": "DE"]]])
        let other = try await newContact(w.alice, w.tenantA, name: "Dritter")
        let (t, s, o) = (UUID(uuidString: target)!, UUID(uuidString: source)!, UUID(uuidString: other)!)
        let (doc1, doc2) = (UUID(), UUID())
        let toSource = try await insertLink(w.tenantA, from: ("dms.document", doc1), to: ("contact", s), kind: "correspondent")
        let collideDoc = try await insertLink(w.tenantA, from: ("dms.document", doc2), to: ("contact", s), kind: "correspondent")
        let keepDoc = try await insertLink(w.tenantA, from: ("dms.document", doc2), to: ("contact", t), kind: "correspondent")
        let fromSource = try await insertLink(w.tenantA, from: ("contact", s), to: ("contact", o), kind: "related")
        let fromSourceFree = try await insertLink(w.tenantA, from: ("contact", s), to: ("contact", o), kind: "free")
        let collideFrom = try await insertLink(w.tenantA, from: ("contact", t), to: ("contact", o), kind: "related")
        let between = try await insertLink(w.tenantA, from: ("contact", s), to: ("contact", t), kind: "related")
        let history = try await insertLink(w.tenantA, from: ("dms.document", doc1), to: ("contact", s), kind: "old", removed: true)
        let foreignTenantLink = try await insertLink(UUID().uuidString, from: ("dms.document", doc1), to: ("contact", s), kind: "correspondent")

        let before = try await auditCount("contact.merged", tenant: w.tenantA)
        let r = try await call(app2, .POST, a + "/contacts/\(target)/merge", json: ["source_id": source], token: w.alice.token)
        XCTAssertEqual(r.status, .ok, "\(r.json)")
        XCTAssertEqual(r.json["links_rewritten"] as? Int, 2)   // toSource (an die Quelle), fromSourceFree (von der Quelle)
        XCTAssertEqual(r.json["links_removed"] as? Int, 3)     // collideDoc und fromSource (Ziel hat schon einen gleichen), between (Quelle <-> Ziel)
        let merged = r.json["contact"] as! [String: Any]
        XCTAssertEqual(merged["id"] as? String, target)
        XCTAssertEqual(merged["vat_id"] as? String, "DE123456789")
        XCTAssertEqual(merged["is_supplier"] as? Bool, true); XCTAssertEqual(merged["is_correspondent"] as? Bool, true)
        XCTAssertEqual((merged["emails"] as? [[String: Any]])?.compactMap { $0["email"] as? String }, ["info@example.org", "alt@example.org"])
        XCTAssertEqual((merged["bank_accounts"] as? [[String: Any]])?.compactMap { $0["iban"] as? String }, [Self.ibanA, Self.ibanB])
        XCTAssertEqual(Set(merged["aliases"] as? [String] ?? []), ["Muster", "MG", "Muster Gesellschaft mbH"])
        XCTAssertEqual((merged["addresses"] as? [[String: Any]])?.count, 1)

        // Quelle bleibt als zusammengeführt erhalten, ist aus der Liste verschwunden und nicht mehr änderbar
        let src = try await call(app1, .GET, a + "/contacts/\(source)", token: w.alice.token)
        XCTAssertEqual(src.status, .ok); XCTAssertEqual(src.json["merged_into"] as? String, target)
        let list = try await call(app1, .GET, a + "/contacts", token: w.alice.token)
        XCTAssertEqual(Set(items(list).compactMap { $0["id"] as? String }), [target, other])
        let patch = try await call(app1, .PATCH, a + "/contacts/\(source)", json: ["display_name": "neu"], token: w.alice.token)
        XCTAssertEqual(patch.status, .conflict); XCTAssertEqual(patch.problemCode, "contact_merged")
        let again = try await call(app1, .POST, a + "/contacts/\(target)/merge", json: ["source_id": source], token: w.alice.token)
        XCTAssertEqual(again.status, .conflict); XCTAssertEqual(again.problemCode, "contact_merged")
        let self_ = try await call(app1, .POST, a + "/contacts/\(target)/merge", json: ["source_id": target], token: w.alice.token)
        XCTAssertEqual(self_.status, .unprocessableEntity)

        // links: nichts verweist mehr aktiv auf die Quelle; Kollisionen sind mit removed_at/removed_by entfernt, nichts wurde gelöscht
        let activeOnSource = try await scalar("""
            SELECT count(*)::bigint AS v FROM links WHERE tenant_id = '\(w.tenantA)' AND removed_at IS NULL
              AND ((from_type = 'contact' AND from_id = '\(source)') OR (to_type = 'contact' AND to_id = '\(source)'))
            """, as: Int64.self)
        XCTAssertEqual(activeOnSource, 0)
        func state(_ id: UUID) async throws -> (to: String, from: String, removed: Bool, by: Bool) {
            let row = try await db.raw("SELECT from_id::text AS f, to_id::text AS t, removed_at IS NOT NULL AS r, removed_by IS NOT NULL AS b FROM links WHERE id = \(bind: id)").first()!
            return (try row.decode(column: "t", as: String.self), try row.decode(column: "f", as: String.self), try row.decode(column: "r", as: Bool.self), try row.decode(column: "b", as: Bool.self))
        }
        let l1 = try await state(toSource); XCTAssertEqual(l1.to, target.lowercased()); XCTAssertFalse(l1.removed)
        let l2 = try await state(collideDoc); XCTAssertTrue(l2.removed); XCTAssertTrue(l2.by)
        let l3 = try await state(keepDoc); XCTAssertFalse(l3.removed); XCTAssertEqual(l3.to, target.lowercased())
        let l4 = try await state(fromSource); XCTAssertTrue(l4.removed); XCTAssertTrue(l4.by)
        let l4b = try await state(fromSourceFree); XCTAssertFalse(l4b.removed); XCTAssertEqual(l4b.from, target.lowercased()); XCTAssertEqual(l4b.to, other.lowercased())
        let l5 = try await state(collideFrom); XCTAssertFalse(l5.removed)
        let l6 = try await state(between); XCTAssertTrue(l6.removed); XCTAssertTrue(l6.by)
        let l7 = try await state(history); XCTAssertTrue(l7.removed); XCTAssertEqual(l7.to, target.lowercased(), "auch die Historie zeigt auf das Ziel")
        let other7 = try await state(foreignTenantLink); XCTAssertEqual(other7.to, source.lowercased(), "fremder Mandant bleibt unberührt")
        let total = try await scalar("SELECT count(*)::bigint AS v FROM links", as: Int64.self)
        XCTAssertEqual(total, 9, "kein links-Eintrag wurde gelöscht")
        let viaApi = try await call(app1, .GET, a + "/links?type=contact&id=\(target)", token: w.alice.token)
        XCTAssertEqual(Set(items(viaApi).compactMap { ($0["id"] as? String)?.lowercased() }),
                       Set([toSource, keepDoc, collideFrom, fromSourceFree].map { $0.uuidString.lowercased() }))

        // Audit: genau ein Eintrag, mit Zählern und IDs, ohne Namen oder IBANs
        let after = try await auditCount("contact.merged", tenant: w.tenantA)
        XCTAssertEqual(after - before, 1)
        let audit = try await db.raw("SELECT subject_id, meta::text AS meta, actor_user_id::text AS actor FROM audit_log WHERE action = 'contact.merged' AND tenant_id = \(bind: UUID(uuidString: w.tenantA)!)").first()!
        XCTAssertEqual(try audit.decode(column: "subject_id", as: String.self).lowercased(), target.lowercased())
        XCTAssertEqual(try audit.decode(column: "actor", as: String.self), w.alice.userID.lowercased())
        let meta = try audit.decode(column: "meta", as: String.self)
        XCTAssertTrue(meta.lowercased().contains(source.lowercased()), meta)
        XCTAssertTrue(meta.contains("\"links_rewritten\": 2") && meta.contains("\"links_removed\": 3"), meta)
        for secret in ["Muster", Self.ibanA, "example.org"] { XCTAssertFalse(meta.contains(secret), secret) }
    }

    // MARK: AK-K5-5 links

    /// AK-K5-5: links mit Quelle; Entfernen setzt `removed_at` (Eintrag bleibt, nicht still, mit Audit) und ist umkehrbar; Duplikate aktiver Einträge sind verboten.
    func testAKK5_5_LinksHaveSourceAndRemovalIsReversible() async throws {
        let w = try await world()
        let a = base(w.tenantA)
        let contact = try await newContact(w.alice, w.tenantA, name: "Korrespondent")
        let doc = UUID().uuidString
        let body: [String: Any] = ["from_type": "dms.document", "from_id": doc, "to_type": "contact", "to_id": contact, "kind": "correspondent", "source": "rule"]
        let created = try await call(app1, .POST, a + "/links", json: body, token: w.alice.token)
        XCTAssertEqual(created.status, .created, "\(created.json)")
        XCTAssertEqual(created.json["source"] as? String, "rule")
        XCTAssertEqual((created.json["created_by"] as? String)?.lowercased(), w.alice.userID.lowercased())
        XCTAssertTrue(created.json["removed_at"] == nil || created.json["removed_at"] is NSNull)
        let id = created.json["id"] as! String
        let manual = try await call(app2, .POST, a + "/links", json: ["from_type": "dms.document", "from_id": UUID().uuidString, "to_type": "contact", "to_id": contact, "kind": "correspondent"], token: w.alice.token)
        XCTAssertEqual(manual.json["source"] as? String, "manual")
        let dup = try await call(app2, .POST, a + "/links", json: body, token: w.alice.token)
        XCTAssertEqual(dup.status, .conflict)
        for (patch, field) in [(["source": "merge"], "source"), (["kind": "Bad Kind"], "kind"), (["from_type": ""], "from_type")] as [([String: String], String)] {
            var b = body; for (k, v) in patch { b[k] = v }
            let r = try await call(app1, .POST, a + "/links", json: b, token: w.alice.token)
            XCTAssertEqual(r.status, .unprocessableEntity, field)
        }

        // Lesen von beiden Seiten
        let fromContact = try await call(app1, .GET, a + "/links?type=contact&id=\(contact)", token: w.alice.token)
        XCTAssertEqual(items(fromContact).count, 2)
        let fromDoc = try await call(app1, .GET, a + "/links?type=dms.document&id=\(doc)", token: w.alice.token)
        XCTAssertEqual(items(fromDoc).count, 1)

        // Entfernen: Eintrag bleibt mit removed_at/removed_by, taucht standardmäßig nicht mehr auf, Audit vorhanden
        let removed = try await call(app2, .DELETE, a + "/links/\(id)", token: w.alice.token)
        XCTAssertEqual(removed.status, .noContent)
        let row = try await db.raw("SELECT removed_at IS NOT NULL AS r, removed_by::text AS b, source FROM links WHERE id = \(bind: UUID(uuidString: id)!)").first()!
        XCTAssertTrue(try row.decode(column: "r", as: Bool.self)); XCTAssertEqual(try row.decode(column: "b", as: String.self), w.alice.userID.lowercased())
        XCTAssertEqual(try row.decode(column: "source", as: String.self), "rule")
        let active = try await call(app1, .GET, a + "/links?type=dms.document&id=\(doc)", token: w.alice.token)
        XCTAssertTrue(items(active).isEmpty)
        let withRemoved = try await call(app1, .GET, a + "/links?type=dms.document&id=\(doc)&include_removed=true", token: w.alice.token)
        XCTAssertEqual(items(withRemoved).count, 1); XCTAssertNotNil(items(withRemoved)[0]["removed_at"]); XCTAssertFalse(items(withRemoved)[0]["removed_at"] is NSNull)
        let removedAgain = try await call(app1, .DELETE, a + "/links/\(id)", token: w.alice.token)
        XCTAssertEqual(removedAgain.status, .notFound)
        let n1 = try await auditCount("link.removed", tenant: w.tenantA); XCTAssertEqual(n1, 1)

        // Neu anlegen ist erlaubt, solange nichts Gleiches aktiv ist; Wiederherstellen kollidiert dann mit 409
        let recreated = try await call(app1, .POST, a + "/links", json: body, token: w.alice.token)
        XCTAssertEqual(recreated.status, .created)
        let restoreConflict = try await call(app2, .POST, a + "/links/\(id)/restore", token: w.alice.token)
        XCTAssertEqual(restoreConflict.status, .conflict)
        _ = try await call(app1, .DELETE, a + "/links/\(recreated.json["id"] as! String)", token: w.alice.token)
        let restored = try await call(app2, .POST, a + "/links/\(id)/restore", token: w.alice.token)
        XCTAssertEqual(restored.status, .ok); XCTAssertTrue(restored.json["removed_at"] == nil || restored.json["removed_at"] is NSNull)
        let restoreActive = try await call(app1, .POST, a + "/links/\(id)/restore", token: w.alice.token)
        XCTAssertEqual(restoreActive.status, .notFound)
        let again = try await call(app1, .GET, a + "/links?type=dms.document&id=\(doc)", token: w.alice.token)
        XCTAssertEqual(items(again).count, 1)
        let created2 = try await auditCount("link.created", tenant: w.tenantA); XCTAssertEqual(created2, 3)
        let restoredAudit = try await auditCount("link.restored", tenant: w.tenantA); XCTAssertEqual(restoredAudit, 1)
        // Datenbank: aktiver Eintrag höchstens einmal
        do {
            try await db.raw("""
                INSERT INTO links (tenant_id, from_type, from_id, to_type, to_id, kind, source) VALUES
                (\(bind: UUID(uuidString: w.tenantA)!), 'dms.document', \(bind: UUID(uuidString: doc)!), 'contact', \(bind: UUID(uuidString: contact)!), 'correspondent', 'manual')
                """).run()
            XCTFail("doppelter aktiver Eintrag muss an der Datenbank scheitern")
        } catch {}
        do {
            try await db.raw("INSERT INTO links (tenant_id, from_type, from_id, to_type, to_id, kind, source) VALUES (\(bind: UUID()), 'a', \(bind: UUID()), 'b', \(bind: UUID()), 'k', 'erfunden')").run()
            XCTFail("unbekannte Quelle muss scheitern")
        } catch {}
    }

    // MARK: AK-K5-6 Berechtigungen

    /// AK-K5-6: Matrix Rolle x Route aus der Routentabelle; erlaubt liefert den Erfolgsstatus, verboten 403 `forbidden` ohne Nebenwirkung.
    func testAKK5_6_PermissionMatrixPerRoute() async throws {
        let w = try await world()
        var sessions: [Role: TestSession] = [.owner: w.alice]
        for role in Role.allCases where role != .owner {
            sessions[role] = try await addUser(role.rawValue, handle: "u_" + role.rawValue, tenant: w.tenantA, by: w.alice)
        }
        let expected: [String: HTTPStatus] = [
            "GET /api/v1/tenants/{tenant}/contacts": .ok, "POST /api/v1/tenants/{tenant}/contacts": .created,
            "GET /api/v1/tenants/{tenant}/contacts/{contact}": .ok, "PATCH /api/v1/tenants/{tenant}/contacts/{contact}": .ok,
            "DELETE /api/v1/tenants/{tenant}/contacts/{contact}": .noContent, "GET /api/v1/tenants/{tenant}/contacts/{contact}/duplicates": .ok,
            "POST /api/v1/tenants/{tenant}/contacts/{contact}/merge": .ok, "GET /api/v1/tenants/{tenant}/links": .ok,
            "POST /api/v1/tenants/{tenant}/links": .created, "DELETE /api/v1/tenants/{tenant}/links/{link}": .noContent,
            "POST /api/v1/tenants/{tenant}/links/{link}/restore": .ok]
        let routes = app1.contactRoutes
        XCTAssertEqual(Set(routes.map { "\($0.method) \($0.path)" }), Set(expected.keys), "jede Route braucht eine Probe")
        XCTAssertTrue(routes.allSatisfy { Permissions.catalog.contains($0.permission) })
        // Rollenkonsistenz
        XCTAssertTrue(Permissions.of(.member).contains("contact.contact.update")); XCTAssertFalse(Permissions.of(.member).contains("contact.contact.merge"))
        XCTAssertFalse(Permissions.of(.member).contains("contact.contact.delete")); XCTAssertEqual(Permissions.of(.taxAdvisor).filter { $0.hasPrefix("contact.") }, ["contact.contact.read", "contact.link.read"] as Set<String>)
        XCTAssertTrue(Permissions.of(.customerViewer).filter { $0.hasPrefix("contact.") }.isEmpty)

        var cells = 0, allowed = 0, denied = 0
        for route in routes {
            for role in Role.allCases {
                let c1 = try await insertContact(w.tenantA, name: "Probe \(cells)"), c2 = try await insertContact(w.tenantA, name: "Quelle \(cells)")
                let link = try await insertLink(w.tenantA, from: ("dms.document", UUID()), to: ("contact", c1), kind: "k\(cells % 7)", removed: route.path.hasSuffix("/restore"))
                var path = String(route.path.dropFirst()).replacingOccurrences(of: "{tenant}", with: w.tenantA)
                    .replacingOccurrences(of: "{contact}", with: c1.uuidString).replacingOccurrences(of: "{link}", with: link.uuidString)
                var body: [String: Any]?
                switch (route.method, route.path.split(separator: "/").last.map(String.init) ?? "") {
                case ("POST", "contacts"): body = ["kind": "person", "display_name": "Neu"]
                case ("PATCH", _): body = ["display_name": "Geändert"]
                case ("POST", "merge"): body = ["source_id": c2.uuidString]
                case ("POST", "links"): body = ["from_type": "dms.document", "from_id": UUID().uuidString, "to_type": "contact", "to_id": c1.uuidString, "kind": "probe"]
                default: break
                }
                if route.method == "GET", route.path.hasSuffix("/links") { path += "?type=contact&id=\(c1)" }
                let app = cells % 2 == 0 ? app1! : app2!
                let before = try await fingerprint()
                let r = try await call(app, HTTPMethod(rawValue: route.method), path, json: body, token: sessions[role]!.token)
                cells += 1
                if Permissions.of(role).contains(route.permission) {
                    allowed += 1
                    XCTAssertEqual(r.status, expected["\(route.method) \(route.path)"], "\(role.rawValue) \(route.method) \(route.path): \(r.json)")
                } else {
                    denied += 1
                    XCTAssertEqual(r.status, .forbidden, "\(role.rawValue) \(route.method) \(route.path)")
                    XCTAssertEqual(r.problemCode, "forbidden")
                    XCTAssertEqual(r.headers.contentType?.serialize(), "application/problem+json")
                    // keine Nebenwirkung
                    let after = try await fingerprint()
                    XCTAssertEqual(after, before, "\(role.rawValue) \(route.method) \(route.path)")
                }
            }
        }
        XCTAssertEqual(cells, routes.count * Role.allCases.count)
        XCTAssertGreaterThan(allowed, 0); XCTAssertGreaterThan(denied, 0)
    }

    // MARK: AK-K5-7 Zwei Instanzen

    /// AK-K5-7: Paralleles Zusammenführen auf zwei Instanzen läuft seriell. Gegenläufig (B in A, A in B): genau ein Gewinner, der Verlierer erhält 409 `contact_merged`.
    func testAKK5_7_ParallelOpposingMergesOnTwoInstances() async throws {
        let w = try await world()
        let a = base(w.tenantA)
        for _ in 0..<5 {
            let x = try await insertContact(w.tenantA, name: "Rund"), y = try await insertContact(w.tenantA, name: "Gegenrund")
            async let r1 = call(app1, .POST, a + "/contacts/\(x)/merge", json: ["source_id": y.uuidString], token: w.alice.token)
            async let r2 = call(app2, .POST, a + "/contacts/\(y)/merge", json: ["source_id": x.uuidString], token: w.alice.token)
            let (p, q) = try await (r1, r2)
            XCTAssertEqual(Set([p.status, q.status]), [.ok, .conflict], "\(p.json) \(q.json)")
            XCTAssertEqual([p, q].first { $0.status == .conflict }?.problemCode, "contact_merged")
            let merged = try await scalar("SELECT count(*)::bigint AS v FROM contacts WHERE id IN ('\(x)', '\(y)') AND merged_into IS NOT NULL", as: Int64.self)
            XCTAssertEqual(merged, 1)
        }
        let audits = try await auditCount("contact.merged", tenant: w.tenantA); XCTAssertEqual(audits, 5)
    }

    /// AK-K5-7: Dieselbe Zusammenführung viermal parallel auf zwei Instanzen: genau eine gelingt, links werden genau einmal umgeschrieben, ein Audit-Eintrag.
    func testAKK5_7_ParallelIdenticalMergesRewriteLinksOnce() async throws {
        let w = try await world()
        let a = base(w.tenantA)
        let target = try await insertContact(w.tenantA, name: "Ziel"), source = try await insertContact(w.tenantA, name: "Quelle")
        let docs = (0..<10).map { _ in UUID() }
        for d in docs { _ = try await insertLink(w.tenantA, from: ("dms.document", d), to: ("contact", source), kind: "correspondent") }
        async let r1 = call(app1, .POST, a + "/contacts/\(target)/merge", json: ["source_id": source.uuidString], token: w.alice.token)
        async let r2 = call(app2, .POST, a + "/contacts/\(target)/merge", json: ["source_id": source.uuidString], token: w.alice.token)
        async let r3 = call(app1, .POST, a + "/contacts/\(target)/merge", json: ["source_id": source.uuidString], token: w.alice.token)
        async let r4 = call(app2, .POST, a + "/contacts/\(target)/merge", json: ["source_id": source.uuidString], token: w.alice.token)
        let all = try await [r1, r2, r3, r4]
        XCTAssertEqual(all.filter { $0.status == .ok }.count, 1, "\(all.map { $0.status })")
        XCTAssertEqual(all.filter { $0.status == .conflict && $0.problemCode == "contact_merged" }.count, 3)
        XCTAssertEqual(all.first { $0.status == .ok }?.json["links_rewritten"] as? Int, 10)
        let onTarget = try await scalar("SELECT count(*)::bigint AS v FROM links WHERE to_id = '\(target)' AND removed_at IS NULL", as: Int64.self)
        XCTAssertEqual(onTarget, 10)
        let onSource = try await scalar("SELECT count(*)::bigint AS v FROM links WHERE to_id = '\(source)'", as: Int64.self)
        XCTAssertEqual(onSource, 0)
        let audits = try await auditCount("contact.merged", tenant: w.tenantA); XCTAssertEqual(audits, 1)
    }

    /// AK-K5-7: Änderung und Zusammenführung zugleich: der Zustand bleibt konsistent (Änderung nach dem Merge scheitert mit 409, davor wird sie übernommen).
    func testAKK5_7_UpdateRacingWithMergeStaysConsistent() async throws {
        let w = try await world()
        let a = base(w.tenantA)
        for i in 0..<5 {
            let target = try await insertContact(w.tenantA, name: "Ziel \(i)"), source = try await insertContact(w.tenantA, name: "Quelle \(i)")
            async let m = call(app1, .POST, a + "/contacts/\(target)/merge", json: ["source_id": source.uuidString], token: w.alice.token)
            async let u = call(app2, .PATCH, a + "/contacts/\(source)", json: ["display_name": "Neu \(i)", "aliases": ["Alias \(i)"]], token: w.alice.token)
            let (merge, update) = try await (m, u)
            XCTAssertEqual(merge.status, .ok, "\(merge.json)")
            XCTAssertTrue(update.status == .ok || (update.status == .conflict && update.problemCode == "contact_merged"), "\(update.status) \(update.json)")
            if update.status == .ok {
                let aliases = try await call(app1, .GET, a + "/contacts/\(target)", token: w.alice.token).json["aliases"] as? [String] ?? []
                XCTAssertTrue(aliases.contains("Alias \(i)"), "übernommene Änderung wurde mit zusammengeführt")
            }
        }
    }

    // MARK: Migration

    /// AK-K5-8: Expand/Contract: Version 15, Revert entfernt alle Tabellen und stellt die Vorversion wieder her, erneutes Anwenden funktioniert.
    func testAKK5_8_MigrationVersionAndRevert() async throws {
        let v = try await scalar("SELECT max(version)::bigint AS v FROM schema_version", as: Int64.self)
        XCTAssertEqual(v, 17)  // WP-O1 (017) liegt über 015
        let database = app1.db(.psql)
        try await CreateJobsPriority().revert(on: database)
        try await CreateContacts().revert(on: database)
        let reverted = try await scalar("SELECT max(version)::bigint AS v FROM schema_version", as: Int64.self)
        XCTAssertEqual(reverted, 14)  // Vorgänger ist 014 (WP-K3)
        let left = try await scalar("""
            SELECT count(*)::bigint AS v FROM information_schema.tables WHERE table_schema = current_schema()
              AND table_name IN ('contacts','contact_addresses','contact_emails','contact_bank_accounts','contact_aliases','links')
            """, as: Int64.self)
        XCTAssertEqual(left, 0)
        try await CreateContacts().prepare(on: database)
        let again = try await scalar("SELECT max(version)::bigint AS v FROM schema_version", as: Int64.self)
        XCTAssertEqual(again, 15)
        try await CreateJobsPriority().prepare(on: database)
        // Datenbankregeln: Zusammenführen in sich selbst und ungültige Arten scheitern
        let id = try await insertContact(UUID().uuidString, name: "X")
        do { try await db.raw("UPDATE contacts SET merged_into = id, merged_at = now() WHERE id = \(bind: id)").run(); XCTFail() } catch {}
        do { try await db.raw("INSERT INTO contacts (tenant_id, kind, display_name) VALUES (\(bind: UUID()), 'robot', 'x')").run(); XCTFail() } catch {}
    }
}
