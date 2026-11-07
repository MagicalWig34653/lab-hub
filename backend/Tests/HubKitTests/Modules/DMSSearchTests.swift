import XCTVapor
import Fluent
import SQLKit
@testable import HubKit

/// WP-S1: DMS-Suche (ADR 0005). Nur synthetische Texte, Domains example.org.
final class DMSSearchTests: DMSTestBase {

    // MARK: Hilfen

    /// Dokument direkt per SQL anlegen (das Original ist für die Suche unerheblich); Text als Revision (OCR füllt das später, O2).
    @discardableResult
    func makeDoc(_ w: World, title: String, text: String? = nil, lang: String = "de", docDate: String? = nil, tenant: String? = nil) async throws -> String {
        let t = tenant ?? w.tenantA
        let id = try await scalar("""
            INSERT INTO dms_documents (tenant_id, title, doc_date) VALUES ('\(t)', '\(title.replacingOccurrences(of: "'", with: "''"))', \(docDate.map { "'\($0)'" } ?? "NULL"))
            RETURNING id::text AS v
            """, as: String.self).uppercased()   // wie in JSON-Antworten
        if let text { try await addText(id, tenant: t, text: text, lang: lang) }
        return id
    }

    func addText(_ doc: String, tenant: String, text: String, lang: String = "de") async throws {
        try await DMSTexts.add(document: UUID(uuidString: doc)!, tenant: UUID(uuidString: tenant)!, engine: "synthetic", lang: lang, text: text, on: app1.db(.psql))
    }

    func search(_ w: World, _ q: String, _ extra: String = "", app: Application? = nil, tenant: String? = nil, token: String? = nil) async throws -> Resp {
        let enc = q.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? q
        return try await call(app ?? app1, .GET, base(tenant ?? w.tenantA) + "/search?q=\(enc)" + (extra.isEmpty ? "" : "&" + extra), token: token ?? w.alice.token)
    }

    func ids(_ r: Resp) -> [String] { items(r).compactMap { $0["id"] as? String } }

    // MARK: AK-S1-1 Wortstamm

    /// AK-S1-1: „Rechnung“ findet „Rechnungen“ (Text und Titel) und umgekehrt; Umlaute und Groß-/Kleinschreibung spielen keine Rolle.
    /// Bekannte Grenze (ADR 0005): Komposita („Rechnungsnummer“) trägt der Wortstamm nicht, nur der Trigram-Fallback (`fuzzy=false` zeigt die Grenze).
    func testAKS1_1_StemmingGermanAndEnglish() async throws {
        let w = try await world()
        let plural = try await makeDoc(w, title: "Scan 1", text: "Im Anhang finden Sie alle offenen Rechnungen des Quartals.")
        let singular = try await makeDoc(w, title: "Rechnung Mai", text: nil)
        let compound = try await makeDoc(w, title: "Rechnungsnummer 4711", text: nil)
        let umlaut = try await makeDoc(w, title: "Scan 2", text: "Herr Müller hat den Käsekuchen bestellt.")
        let english = try await makeDoc(w, title: "Scan 3", text: "The invoices and payments were running late.", lang: "en")

        var r = try await search(w, "Rechnung", "fuzzy=false")
        XCTAssertEqual(r.status, .ok, "\(r.json)")
        XCTAssertEqual(Set(ids(r)), [plural, singular], "Wortstamm Rechnung/Rechnungen")
        XCTAssertFalse(ids(r).contains(compound), "Grenze: Kompositum nicht per Wortstamm")
        r = try await search(w, "Rechnungen", "fuzzy=false", app: app2)
        XCTAssertEqual(Set(ids(r)), [plural, singular])
        r = try await search(w, "RECHNUNG")
        XCTAssertTrue(Set(ids(r)).isSuperset(of: [plural, singular]), "Großschreibung egal")
        XCTAssertTrue(ids(r).contains(compound), "Trigram-Fallback findet das Kompositum")

        r = try await search(w, "Muller", "fuzzy=false")
        XCTAssertEqual(ids(r), [umlaut], "ohne Umlaut gesucht")
        r = try await search(w, "Müller", "fuzzy=false")
        XCTAssertEqual(ids(r), [umlaut])
        r = try await search(w, "invoice", "fuzzy=false")
        XCTAssertEqual(ids(r), [english], "englische Konfiguration für lang=en")
        r = try await search(w, "payment", "fuzzy=false")
        XCTAssertEqual(ids(r), [english])
    }

    // MARK: AK-S1-2 Tippfehler

    /// AK-S1-2: Tippfehler in Titel/Metadaten (Korrespondent, Typ, Tag, Dateiname) per `pg_trgm`; ohne Fallback kein Treffer; Metadaten werden bei Änderung nachgeführt.
    func testAKS1_2_TyposViaTrigramOnTitleAndMetadata() async throws {
        let w = try await world()
        let a = base(w.tenantA), core = "api/v1/tenants/\(w.tenantA)"
        let doc = try await makeDoc(w, title: "Telekom Rechnung Januar")
        let other = try await makeDoc(w, title: "Mietvertrag Wohnung")
        var r = try await search(w, "Rechnnug", "fuzzy=false")
        XCTAssertEqual(ids(r), [])
        r = try await search(w, "Rechnnug")
        XCTAssertEqual(ids(r), [doc], "Buchstabendreher")
        r = try await search(w, "Telekomm")
        XCTAssertEqual(ids(r), [doc])
        r = try await search(w, "Mietvertarg", app: app2)
        XCTAssertEqual(ids(r), [other])
        // Tippfehler-Treffer ranken hinter exakten Treffern
        let exact = try await makeDoc(w, title: "Rechnnug exakt so geschrieben")
        r = try await search(w, "Rechnnug")
        XCTAssertEqual(ids(r).first, exact)
        XCTAssertEqual(Set(ids(r)), [exact, doc])

        // Metadaten: Korrespondent, Tag, Typ
        let c = (try await call(app1, .POST, core + "/contacts", json: ["kind": "organization", "display_name": "Stadtwerke Beispielhausen", "is_correspondent": true], token: w.alice.token)).json["id"] as! String
        let tag = (try await call(app1, .POST, a + "/tags", json: ["name": "Nebenkosten"], token: w.alice.token)).json["id"] as! String
        let type = (try await call(app1, .POST, a + "/types", json: ["name": "Kontoauszug"], token: w.alice.token)).json["id"] as! String
        let patch = try await call(app1, .PATCH, a + "/documents/\(other)", json: ["correspondent_id": c, "tag_ids": [tag], "document_type_id": type], token: w.alice.token)
        XCTAssertEqual(patch.status, .ok, "\(patch.json)")
        for q in ["Stadtwerke", "Nebenkosten", "Kontoauszug"] {
            r = try await search(w, q, "fuzzy=false", app: app2)
            XCTAssertEqual(ids(r), [other], q)
        }
        r = try await search(w, "Stadtwerk Beispielhausn", "fuzzy=false")
        XCTAssertEqual(ids(r), [], "Tippfehler ohne Fallback")
        r = try await search(w, "Stadtwerk Beispielhausn")
        XCTAssertEqual(ids(r), [other], "Tippfehler im Korrespondentennamen")
        // Umbenennen des Kontakts und Entfernen des Tags wird nachgeführt (Trigger, kein Zustand in der Instanz)
        let rename = try await call(app1, .PATCH, core + "/contacts/\(c)", json: ["display_name": "Energieversorger Neustadt"], token: w.alice.token)
        XCTAssertEqual(rename.status, .ok, "\(rename.json)")
        r = try await search(w, "Stadtwerke", "fuzzy=false")
        XCTAssertEqual(ids(r), [])
        r = try await search(w, "Energieversorger", "fuzzy=false", app: app2)
        XCTAssertEqual(ids(r), [other])
        _ = try await call(app1, .PATCH, a + "/documents/\(other)", json: ["tag_ids": [String]()], token: w.alice.token)
        r = try await search(w, "Nebenkosten", "fuzzy=false")
        XCTAssertEqual(ids(r), [])
        // Titeländerung
        _ = try await call(app1, .PATCH, a + "/documents/\(other)", json: ["title": "Garantieschein Waschmaschine"], token: w.alice.token)
        r = try await search(w, "Mietvertrag", "fuzzy=false")
        XCTAssertEqual(ids(r), [])
        r = try await search(w, "Garantieschein", "fuzzy=false", app: app2)
        XCTAssertEqual(ids(r), [other])
    }

    /// AK-S1-2: der Dateiname des Originals gehört zu den durchsuchbaren Metadaten.
    func testAKS1_2_OriginalFilenameIsSearchable() async throws {
        let w = try await world()
        let up = try await upload(w.alice, w.tenantA, pdf("dateiname"), query: "filename=Heizkostenabrechnung_2025.pdf&title=Brief")
        XCTAssertEqual(up.status, .created, "\(up.json)")
        let id = up.json["id"] as! String
        let r = try await search(w, "Heizkostenabrechnung", "fuzzy=false", app: app2)
        XCTAssertEqual(ids(r), [id])
        let typo = try await search(w, "Heizkostenabrechnnug")
        XCTAssertEqual(ids(typo), [id])
    }

    // MARK: AK-S1-3 Phrase und Operatoren

    /// AK-S1-3: websearch_to_tsquery: Phrase in Anführungszeichen, `or`, `-` (Ausschluss) wirken über Titel, Metadaten und Text zugleich.
    func testAKS1_3_PhraseAndOperators() async throws {
        let w = try await world()
        let a = try await makeDoc(w, title: "Scan A", text: "Kuendigung Mietvertrag Stuttgart Wohnung")
        let b = try await makeDoc(w, title: "Scan B", text: "Wohnung Stuttgart Mietvertrag Kuendigung")
        let c = try await makeDoc(w, title: "Scan C", text: "Mietvertrag Berlin Wohnung")
        let d = try await makeDoc(w, title: "Scan D", text: "Kaufvertrag Hamburg")

        var r = try await search(w, "Mietvertrag Stuttgart")
        XCTAssertEqual(Set(ids(r)), [a, b], "Leerzeichen = und")
        r = try await search(w, "\"Mietvertrag Stuttgart\"")
        XCTAssertEqual(ids(r), [a], "Phrase: Reihenfolge und Nachbarschaft")
        r = try await search(w, "\"Stuttgart Mietvertrag\"", app: app2)
        XCTAssertEqual(ids(r), [b])
        r = try await search(w, "Mietvertrag or Kaufvertrag")
        XCTAssertEqual(Set(ids(r)), [a, b, c, d])
        r = try await search(w, "Mietvertrag -Stuttgart")
        XCTAssertEqual(ids(r), [c], "Ausschluss gilt über den Text")
        r = try await search(w, "Vertrag -Mietvertrag", "fuzzy=false")
        XCTAssertEqual(ids(r), [], "kein Wortteil-Treffer")
        r = try await search(w, "\"Stuttgart Berlin\"")
        XCTAssertEqual(ids(r), [])
        // Ausschluss gegen einen Titel
        try await makeDoc(w, title: "Stuttgart Brief", text: "Mietvertrag")
        r = try await search(w, "Mietvertrag -Stuttgart")
        XCTAssertEqual(ids(r), [c], "Titel mit Stuttgart ist ausgeschlossen")
        // Operatoren schalten den Tippfehler-Fallback ab (nur exakt)
        r = try await search(w, "Mietvertrg -Berlin")
        XCTAssertEqual(ids(r), [])
        r = try await search(w, "Mietvertrg")
        XCTAssertEqual(ids(r), [], "der Text wird nicht per Trigram durchsucht (nur Titel/Metadaten)")
    }

    // MARK: AK-S1-4 Filter und Facetten

    func testAKS1_4_FiltersAndFacets() async throws {
        let w = try await world()
        let a = base(w.tenantA), core = "api/v1/tenants/\(w.tenantA)"
        func create(_ path: String, _ json: [String: Any]) async throws -> String {
            let r = try await call(app1, .POST, path, json: json, token: w.alice.token); XCTAssertEqual(r.status, .created, "\(r.json)"); return r.json["id"] as! String
        }
        let typeInv = try await create(a + "/types", ["name": "Rechnung"]), typeContract = try await create(a + "/types", ["name": "Vertrag"])
        let tagA = try await create(a + "/tags", ["name": "steuerlich"]), tagB = try await create(a + "/tags", ["name": "offen"])
        let path1 = try await create(a + "/storage-paths", ["name": "Jahr", "template": "{doc_date:yyyy}/{title}"])
        let path2 = try await create(a + "/storage-paths", ["name": "Typ", "template": "{type}/{title}"])
        let c1 = try await create(core + "/contacts", ["kind": "organization", "display_name": "Lieferant Eins"])
        let c2 = try await create(core + "/contacts", ["kind": "organization", "display_name": "Lieferant Zwei"])

        func doc(_ title: String, date: String, type: String, tags: [String], corr: String, path: String) async throws -> String {
            let id = try await makeDoc(w, title: title, text: "Zahlungsziel dreissig Tage netto", docDate: date)
            let r = try await call(app1, .PATCH, a + "/documents/\(id)", json: ["document_type_id": type, "tag_ids": tags, "correspondent_id": corr, "storage_path_id": path], token: w.alice.token)
            XCTAssertEqual(r.status, .ok, "\(r.json)")
            return id
        }
        let d1 = try await doc("Beleg 1", date: "2025-03-01", type: typeInv, tags: [tagA, tagB], corr: c1, path: path1)
        let d2 = try await doc("Beleg 2", date: "2025-11-15", type: typeInv, tags: [tagA], corr: c2, path: path1)
        let d3 = try await doc("Beleg 3", date: "2026-02-10", type: typeContract, tags: [tagB], corr: c1, path: path2)
        let d4 = try await doc("Beleg 4", date: "2026-06-30", type: typeContract, tags: [], corr: c2, path: path2)
        let d5 = try await makeDoc(w, title: "Beleg 5 ohne Metadaten", text: "Zahlungsziel vierzehn Tage")

        func found(_ extra: String) async throws -> Set<String> {
            let r = try await search(w, "Zahlungsziel", extra, app: Bool.random() ? app1 : app2)
            XCTAssertEqual(r.status, .ok, "\(extra): \(r.json)")
            return Set(ids(r))
        }
        let all = try await found("")
        XCTAssertEqual(all, [d1, d2, d3, d4, d5])
        var f = try await found("document_type_id=\(typeInv)"); XCTAssertEqual(f, [d1, d2])
        f = try await found("correspondent_id=\(c1)"); XCTAssertEqual(f, [d1, d3])
        f = try await found("tag_id=\(tagA)"); XCTAssertEqual(f, [d1, d2])
        f = try await found("tag_id=\(tagA),\(tagB)"); XCTAssertEqual(f, [d1], "mehrere Tags = und")
        f = try await found("storage_path_id=\(path2)"); XCTAssertEqual(f, [d3, d4])
        f = try await found("date_from=2025-11-15"); XCTAssertEqual(f, [d2, d3, d4])
        f = try await found("date_to=2025-12-31"); XCTAssertEqual(f, [d1, d2])
        f = try await found("date_from=2025-06-01&date_to=2026-03-01"); XCTAssertEqual(f, [d2, d3])
        f = try await found("document_type_id=\(typeContract)&tag_id=\(tagB)&correspondent_id=\(c1)&date_from=2026-01-01"); XCTAssertEqual(f, [d3])
        f = try await found("document_type_id=\(typeInv)&storage_path_id=\(path2)"); XCTAssertEqual(f, [])

        // Ungültige Filter
        for bad in ["document_type_id=x", "tag_id=a,b", "date_from=morgen", "date_to=2026-13-40", "storage_path_id=1", "limit=0", "cursor=zzz"] {
            let r = try await search(w, "Zahlungsziel", bad)
            XCTAssertTrue([.unprocessableEntity, .badRequest].contains(r.status), "\(bad): \(r.status)")
        }

        // Facetten (nur auf Wunsch), Zahlen über die gesamte Trefferzahl, nicht über die Seite
        let plain = try await search(w, "Zahlungsziel")
        XCTAssertNil(plain.json["facets"])
        let page = try await search(w, "Zahlungsziel", "facets=true&limit=1&count=true&tag_id=\(tagB)")
        XCTAssertEqual(ids(page).count, 1)
        XCTAssertNotNil(page.json["next_cursor"] as? String)
        func facet(_ r: Resp, _ name: String) -> [String: Int] {
            let facets = r.json["facets"] as? [String: Any] ?? [:]
            return Dictionary(uniqueKeysWithValues: (facets[name] as? [[String: Any]] ?? []).map { ($0["value"] as! String, $0["count"] as! Int) })
        }
        XCTAssertEqual(page.json["total"] as? Int, 2)
        XCTAssertEqual(facet(page, "document_type"), [typeInv: 1, typeContract: 1])
        XCTAssertEqual(facet(page, "tag"), [tagA: 1, tagB: 2])
        XCTAssertEqual(facet(page, "correspondent"), [c1: 2])
        XCTAssertEqual(facet(page, "storage_path"), [path1: 1, path2: 1])
        XCTAssertEqual(facet(page, "year"), ["2025": 1, "2026": 1])
        let wide = try await search(w, "Zahlungsziel", "facets=true", app: app2)
        XCTAssertEqual(facet(wide, "document_type"), [typeInv: 2, typeContract: 2])
        XCTAssertEqual(facet(wide, "year"), ["2025": 2, "2026": 2])
    }

    // MARK: AK-S1-5 Mandant und Berechtigung

    func testAKS1_5_TenantIsolationPermissionsAndTrash() async throws {
        let w = try await world()
        let tenantB = (try await call(app1, .POST, "api/v1/tenants", json: ["name": "Fremd"], token: w.alice.token)).json["id"] as! String
        let carol = try await addUser("owner", handle: "carol", tenant: tenantB, by: w.alice)
        try await setModule(tenantB, true, by: carol)
        let mine = try await makeDoc(w, title: "Geheimzahl Alpha", text: "Zugangsdaten Projekt Alpha")
        let theirs = try await makeDoc(w, title: "Fremdnummer Beta", text: "Zugangsdaten Projekt Beta", tenant: tenantB)

        var r = try await search(w, "Zugangsdaten")
        XCTAssertEqual(ids(r), [mine])
        r = try await search(w, "Zugangsdaten", tenant: tenantB, token: carol.token)
        XCTAssertEqual(ids(r), [theirs], "jeder Mandant sieht nur das Eigene")
        r = try await search(w, "Geheimzahl", tenant: tenantB, token: carol.token)
        XCTAssertEqual(ids(r), [], "auch nicht per Titel oder Trigram")
        r = try await search(w, "Geheimzhal", "facets=true&count=true", tenant: tenantB, token: carol.token)
        XCTAssertEqual(ids(r), [])
        XCTAssertEqual(r.json["total"] as? Int, 0)
        // Carol auf dem Pfad von Mandant A: kein Mitglied
        r = try await search(w, "Zugangsdaten", tenant: w.tenantA, token: carol.token)
        XCTAssertEqual(r.status, .notFound)
        // Filter mit fremden IDs liefern nichts
        let foreignType = (try await call(app1, .POST, base(tenantB) + "/types", json: ["name": "Fremdtyp"], token: carol.token)).json["id"] as! String
        r = try await search(w, "Zugangsdaten", "document_type_id=\(foreignType)")
        XCTAssertEqual(ids(r), [])

        // Rollen: tax_advisor/member lesen, customer_viewer nicht; ohne Anmeldung 401
        let member = try await addUser("member", handle: "mia", tenant: w.tenantA, by: w.alice)
        let advisor = try await addUser("tax_advisor", handle: "tom", tenant: w.tenantA, by: w.alice)
        let viewer = try await addUser("customer_viewer", handle: "vera", tenant: w.tenantA, by: w.alice)
        for s in [member, advisor] {
            let ok = try await search(w, "Zugangsdaten", token: s.token)
            XCTAssertEqual(ids(ok), [mine])
        }
        let denied = try await search(w, "Zugangsdaten", token: viewer.token)
        XCTAssertEqual(denied.status, .forbidden); XCTAssertEqual(denied.problemCode, "forbidden")
        let anon = try await call(app1, .GET, base(w.tenantA) + "/search?q=Zugangsdaten")
        XCTAssertEqual(anon.status, .unauthorized)
        // Pflichtparameter
        for q in ["", "   "] {
            let bad = try await search(w, q); XCTAssertEqual(bad.status, .unprocessableEntity, "\(bad.json)")
        }
        let long = try await search(w, String(repeating: "a", count: 201)); XCTAssertEqual(long.status, .unprocessableEntity)

        // Papierkorb: Dokument verschwindet aus der Suche (Titel, Text, Fallback, Facetten), nach Restore ist es wieder da
        let trash = try await call(app1, .POST, base(w.tenantA) + "/documents/\(mine)/trash", json: ["reason": "Test"], token: w.alice.token)
        XCTAssertEqual(trash.status, .ok, "\(trash.json)")
        for (q, extra) in [("Zugangsdaten", ""), ("Geheimzahl", ""), ("Geheimzhal", ""), ("Geheimzahl", "facets=true&count=true")] {
            r = try await search(w, q, extra, app: app2)
            XCTAssertEqual(ids(r), [], q)
            if extra.contains("facets") { XCTAssertEqual(r.json["total"] as? Int, 0) }
        }
        _ = try await call(app1, .POST, base(w.tenantA) + "/documents/\(mine)/restore", token: w.alice.token)
        r = try await search(w, "Zugangsdaten")
        XCTAssertEqual(ids(r), [mine])
        // Modul deaktiviert: 404 module_disabled (die Route hängt am Modul)
        try await setModule(w.tenantA, false, by: w.alice)
        r = try await search(w, "Zugangsdaten")
        XCTAssertEqual(r.status, .notFound); XCTAssertEqual(r.problemCode, "module_disabled")
    }

    // MARK: Trefferform, Ranking, Snippet, Pagination

    func testHitShapeRankingSnippetAndCursorPagination() async throws {
        let w = try await world()
        // Titeltreffer vor Texttreffer; viele Treffer für die Seitenfolge
        let textHit = try await makeDoc(w, title: "Scan 1", text: String(repeating: "Füllwort ", count: 40) + "Wartungsvertrag " + String(repeating: "Endwort ", count: 40))
        let titleHit = try await makeDoc(w, title: "Wartungsvertrag Aufzug", text: "Nichts Besonderes")
        var r = try await search(w, "Wartungsverträge")
        XCTAssertEqual(ids(r), [titleHit, textHit], "Titel wiegt schwerer als Text")
        let first = items(r)[0], second = items(r)[1]
        XCTAssertGreaterThan(first["score"] as! Double, second["score"] as! Double)
        XCTAssertEqual(first["title"] as? String, "Wartungsvertrag Aufzug")
        let snippet = second["snippet"] as? String ?? ""
        XCTAssertTrue(snippet.contains("\u{E000}Wartungsvertrag\u{E001}"), "Treffer im Snippet markiert (private Markierungen, kein HTML): \(snippet)")
        XCTAssertLessThan(snippet.count, 400)
        XCTAssertFalse(snippet.contains("<"))

        for i in 0..<23 { try await makeDoc(w, title: "Sammelakte \(i)", text: "Sammelordner Nummer \(i) Heizkosten") }
        var seen: [String] = []
        var cursor: String?
        var pages = 0
        repeat {
            r = try await search(w, "Heizkosten", "limit=10&count=true" + (cursor.map { "&cursor=\($0)" } ?? ""), app: pages % 2 == 0 ? app1 : app2)
            XCTAssertEqual(r.status, .ok, "\(r.json)")
            XCTAssertEqual(r.json["total"] as? Int, 23)
            seen += ids(r); pages += 1
            cursor = r.json["next_cursor"] as? String
        } while cursor != nil && pages < 10
        XCTAssertEqual(pages, 3)
        XCTAssertEqual(seen.count, 23)
        XCTAssertEqual(Set(seen).count, 23, "keine Doppelten über Seiten")
        // Wiederholung der ersten Seite ist stabil
        let again = try await search(w, "Heizkosten", "limit=10")
        XCTAssertEqual(ids(again), Array(seen.prefix(10)))
    }

    // MARK: Zwei Instanzen / Index ohne Zustand

    /// Der Index lebt in der Datenbank: Text-Revisionen (höchste Version gilt), Löschen der Revision, direkte SQL-Änderungen und die zweite Instanz sehen sofort denselben Stand.
    func testIndexMaintainedInDatabaseAcrossInstancesAndTextVersions() async throws {
        let w = try await world()
        let doc = try await makeDoc(w, title: "Scan X", text: "Altstand Heizung")
        var r = try await search(w, "Altstand", "fuzzy=false", app: app2)
        XCTAssertEqual(ids(r), [doc])
        try await addText(doc, tenant: w.tenantA, text: "Neustand Kühlung")
        r = try await search(w, "Altstand", "fuzzy=false", app: app1)
        XCTAssertEqual(ids(r), [], "neuere Version ersetzt für die Suche")
        r = try await search(w, "Neustand", "fuzzy=false", app: app2)
        XCTAssertEqual(ids(r), [doc])
        // ältere Version bleibt in der Tabelle (Revisionen), englisch als neue Version
        try await aEq(try await count("dms_document_texts", where: "document_id = '\(doc)'"), 2)
        try await addText(doc, tenant: w.tenantA, text: "Invoices from the warehouse", lang: "en")
        r = try await search(w, "invoice", "fuzzy=false", app: app2)
        XCTAssertEqual(ids(r), [doc])
        try await db.raw("DELETE FROM dms_document_texts WHERE document_id = \(bind: UUID(uuidString: doc)!) AND version = 3").run()
        r = try await search(w, "invoice", "fuzzy=false")
        XCTAssertEqual(ids(r), [])
        r = try await search(w, "Neustand", "fuzzy=false", app: app2)
        XCTAssertEqual(ids(r), [doc], "nach dem Löschen gilt wieder die höchste verbleibende Version")
        // Titel per SQL
        try await db.raw("UPDATE dms_documents SET title = 'Direkt geändert' WHERE id = \(bind: UUID(uuidString: doc)!)").run()
        r = try await search(w, "Direkt", "fuzzy=false", app: app2)
        XCTAssertEqual(ids(r), [doc])
        // Ein Text mit fremder Mandanten-ID scheitert (zusammengesetzter Fremdschlüssel)
        do {
            try await db.raw("INSERT INTO dms_document_texts (tenant_id, document_id, version, engine, lang, text) VALUES (\(bind: UUID()), \(bind: UUID(uuidString: doc)!), 9, 'x', 'de', 'x')").run()
            XCTFail("Fremdschlüssel über Mandantengrenzen muss scheitern")
        } catch {}
        // Sprache und Version sind geprüft
        do {
            try await db.raw("INSERT INTO dms_document_texts (tenant_id, document_id, version, engine, lang, text) VALUES (\(bind: UUID(uuidString: w.tenantA)!), \(bind: UUID(uuidString: doc)!), 0, 'x', 'fr', 'x')").run()
            XCTFail("lang/version CHECK")
        } catch {}
    }

    /// Migration: pg_trgm/unaccent vorhanden, Revert und erneutes Anwenden funktionieren.
    func testSearchMigrationRevertAndReapply() async throws {
        _ = try await world()
        try await aEq(try await count("pg_extension", where: "extname IN ('pg_trgm', 'unaccent')"), 2)
        try await aEq(try await count("_fluent_migrations", where: "name = 'dms_018_search'"), 1)
        let m = CreateDMSSearch()
        try await m.revert(on: app1.db(.psql))
        try await aEq(try await count("information_schema.tables", where: "table_name = 'dms_document_texts'"), 0)
        try await aEq(try await count("information_schema.columns", where: "table_name = 'dms_documents' AND column_name IN ('search_tsv', 'trgm_src', 'meta_text', 'body_tsv')"), 0)
        try await aEq(try await count("pg_ts_config", where: "cfgname IN ('dms_german', 'dms_english')"), 0)
        try await m.prepare(on: app1.db(.psql))
        try await aEq(try await count("information_schema.tables", where: "table_name = 'dms_document_texts'"), 1)
    }

    // MARK: AK-S1-6 Qualitätskorpus

    /// Schwellen (ADR 0005 / Handoff): Recall@10 >= 0,9 für Wortstamm-Anfragen über den Text (Wert aus MODUL-DMS.md Abschnitt 6),
    /// Recall@10 >= 0,8 für Anfragen mit einem Buchstabendreher gegen den Titel (Trigram). Recall@10 = |Top10 ∩ relevant| / min(10, |relevant|).
    static let stemRecallThreshold = 0.9, typoRecallThreshold = 0.8

    struct Corpus {
        struct Doc { let title: String; let text: String; let topics: Set<Int>; let titleTopic: Int? }
        static let topics: [(base: String, forms: [String])] = [
            ("Rechnung", ["Rechnung", "Rechnungen"]), ("Mahnung", ["Mahnung", "Mahnungen"]), ("Vertrag", ["Vertrag", "Verträge", "Vertrages"]),
            ("Kündigung", ["Kündigung", "Kündigungen"]), ("Versicherung", ["Versicherung", "Versicherungen"]),
            ("Steuerbescheid", ["Steuerbescheid", "Steuerbescheide", "Steuerbescheides"]), ("Lieferschein", ["Lieferschein", "Lieferscheine", "Lieferscheinen"]),
            ("Gutschrift", ["Gutschrift", "Gutschriften"]), ("Angebot", ["Angebot", "Angebote", "Angebots"]), ("Kontoauszug", ["Kontoauszug", "Kontoauszüge", "Kontoauszügen"]),
            ("Bestellung", ["Bestellung", "Bestellungen"]), ("Quittung", ["Quittung", "Quittungen"])]
        static let filler = ["Hiermit", "bestätigen", "wir", "den", "Eingang", "Ihres", "Schreibens", "vom", "Montag", "bezüglich", "der", "Lieferung", "nach", "Hamburg",
                             "Bitte", "überweisen", "Betrag", "innerhalb", "von", "vierzehn", "Tagen", "auf", "das", "angegebene", "Konto", "Mit", "freundlichen", "Grüßen",
                             "Beispiel", "GmbH", "Seite", "Referenz", "Kundennummer", "Zeitraum", "Quartal", "Projekt", "Wartung", "Standort"]

        /// Deterministisch (LCG). Rauschen: Trennstriche, ca. 6 % beschädigte Schlüsselwörter (das Dokument bleibt laut Soll relevant), Zahlen.
        static func make(count: Int = 200) -> [Doc] {
            var state: UInt64 = 0x9E3779B97F4A7C15
            func next(_ n: Int) -> Int { state = state &* 6364136223846793005 &+ 1442695040888963407; return Int((state >> 33) % UInt64(n)) }
            func noisy(_ word: String) -> String {
                switch next(33) {
                case 0, 1:
                    var c = Array(word)
                    if c.count > 5 { c[2 + next(c.count - 4)] = "§" }
                    return String(c)
                case 2:
                    let i = word.index(word.startIndex, offsetBy: word.count / 2)
                    return word[..<i] + "-\n" + word[i...]
                default: return word
                }
            }
            return (0..<count).map { i in
                var topicSet: Set<Int> = [i % topics.count]
                if next(6) == 0 { topicSet.insert(next(topics.count)) }
                var words: [String] = []
                for _ in 0..<(20 + next(25)) { words.append(filler[next(filler.count)]) }
                words.append("Nr."); words.append(String(10000 + next(89999)))
                for t in topicSet.sorted() {
                    let form = topics[t].forms[next(topics[t].forms.count)]
                    words.insert(noisy(form), at: next(words.count + 1))
                }
                let titleTopic: Int? = next(3) == 0 ? (i % topics.count) : nil
                let title = titleTopic.map { "\(topics[$0].base) \(["Telekom", "Stadtwerke", "Müller", "Beispiel"][next(4)]) \(2020 + next(7))" } ?? "Scan \(i) \(filler[next(filler.count)])"
                return Doc(title: title, text: words.joined(separator: " "), topics: topicSet, titleTopic: titleTopic)
            }
        }
    }

    func testAKS1_6_QualityCorpusRecallAtTen() async throws {
        let w = try await world()
        let corpus = Corpus.make()
        XCTAssertEqual(corpus.count, 200)
        var idByIndex: [String] = []
        for d in corpus { idByIndex.append(try await makeDoc(w, title: d.title, text: d.text)) }

        // Wortstamm-Anfragen über den Text (Grundform), Soll = alle Dokumente, die das Thema im Text haben
        var stemRecalls: [Double] = [], precisions: [Double] = []
        for (t, topic) in Corpus.topics.enumerated() {
            let relevant = Set(corpus.indices.filter { corpus[$0].topics.contains(t) }.map { idByIndex[$0] })
            let r = try await search(w, topic.base, "fuzzy=false&limit=10", app: t % 2 == 0 ? app1 : app2)
            XCTAssertEqual(r.status, .ok, "\(r.json)")
            let top = ids(r)
            stemRecalls.append(Double(Set(top).intersection(relevant).count) / Double(min(10, relevant.count)))
            precisions.append(top.isEmpty ? 0 : Double(top.filter(relevant.contains).count) / Double(top.count))
        }
        // Tippfehler-Anfragen (Buchstabendreher) gegen den Titel; Soll = Dokumente, deren Titel das Thema trägt
        var typoRecalls: [Double] = []
        for (t, topic) in Corpus.topics.enumerated() {
            var c = Array(topic.base); c.swapAt(3, 4)
            let relevant = Set(corpus.indices.filter { corpus[$0].titleTopic == t }.map { idByIndex[$0] })
            guard !relevant.isEmpty else { continue }
            let r = try await search(w, String(c), "limit=10")
            typoRecalls.append(Double(Set(ids(r)).intersection(relevant).count) / Double(min(10, relevant.count)))
        }
        let stem = stemRecalls.reduce(0, +) / Double(stemRecalls.count), typo = typoRecalls.reduce(0, +) / Double(typoRecalls.count)
        let prec = precisions.reduce(0, +) / Double(precisions.count)
        print("AK-S1-6 Korpus 200: Recall@10 Wortstamm = \(stem) (min \(stemRecalls.min()!)), Precision@10 = \(prec), Recall@10 Tippfehler/Titel = \(typo) (min \(typoRecalls.min()!), n = \(typoRecalls.count))")
        XCTAssertGreaterThanOrEqual(stem, Self.stemRecallThreshold)
        XCTAssertGreaterThanOrEqual(typo, Self.typoRecallThreshold)
        XCTAssertGreaterThanOrEqual(prec, 0.9, "Treffer sind relevant (Precision@10)")
    }

    // MARK: AK-S1-7 Antwortzeit (Messlauf, standardmäßig übersprungen)

    /// AK-S1-7: Messlauf mit synthetischen Dokumenten. Nur mit `LH_SEARCH_PERF=1` (Anzahl `LH_SEARCH_PERF_DOCS`, Standard 100000); sonst übersprungen.
    /// Kein hartes Ziel: der Test gibt Median/p95 aus und prüft nur, dass jede Antwort 200 ist. Messwerte stehen in ADR 0005.
    func testAKS1_7_ResponseTimeWithManySyntheticDocuments() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["LH_SEARCH_PERF"] == "1" else { throw XCTSkip("AK-S1-7 Messlauf übersprungen (LH_SEARCH_PERF=1 setzt ihn ein)") }
        let n = env["LH_SEARCH_PERF_DOCS"].flatMap(Int.init) ?? 100_000
        let w = try await world()
        let a = base(w.tenantA)
        let type = (try await call(app1, .POST, a + "/types", json: ["name": "Rechnung"], token: w.alice.token)).json["id"] as! String
        let tag = (try await call(app1, .POST, a + "/tags", json: ["name": "perf"], token: w.alice.token)).json["id"] as! String
        let t0 = Date()
        try await db.raw("SELECT setseed(0.42)").run()
        // Dokumente: Titel aus Themenwörtern, Datum über ~7 Jahre, Typ für ein Viertel
        try await db.raw("""
            INSERT INTO dms_documents (tenant_id, title, doc_date, document_type_id)
            SELECT \(bind: UUID(uuidString: w.tenantA)!), 'Dokument ' || g || ' ' || (ARRAY['Rechnung','Vertrag','Mahnung','Angebot','Kontoauszug','Bescheid','Quittung','Lieferschein'])[1 + (g % 8)] || ' ' || (ARRAY['Telekom','Stadtwerke','Beispiel','Muster'])[1 + (g % 4)],
                   date '2020-01-01' + (g % 2500)::int, CASE WHEN g % 4 = 0 THEN \(bind: UUID(uuidString: type)!) END
            FROM generate_series(1, \(bind: n)::int) g
            """).run()
        // Texte: 120 Wörter, halb Grundvokabular (Wortstämme), halb seltene Wörter (große Lexikongröße), 2 % englisch
        try await db.raw("""
            INSERT INTO dms_document_texts (tenant_id, document_id, version, engine, lang, text)
            SELECT d.tenant_id, d.id, 1, 'synthetic', CASE WHEN random() < 0.02 THEN 'en' ELSE 'de' END,
              (SELECT string_agg(CASE WHEN random() < 0.5 THEN (ARRAY['Rechnung','Rechnungen','Zahlung','Vertrag','Verträge','Kündigung','Versicherung','Betrag','Konto','Lieferung','Mahnung','Frist','Steuer','Beleg','Projekt','Wartung','Quartal','Kunde','Angebot','Bestellung'])[1 + floor(random() * 20)::int]
                                           ELSE 'wort' || floor(random() * 30000)::int END, ' ')
               FROM generate_series(1, 120) x WHERE d.id IS NOT NULL)
            FROM dms_documents d
            """).run()
        try await db.raw("INSERT INTO dms_document_tags (tenant_id, document_id, tag_id) SELECT tenant_id, id, \(bind: UUID(uuidString: tag)!) FROM dms_documents WHERE doc_date < date '2021-01-01'").run()
        try await db.raw("ANALYZE dms_documents").run()
        try await db.raw("ANALYZE dms_document_texts").run()
        let fill = Date().timeIntervalSince(t0)
        let size = try await scalar("SELECT pg_size_pretty(pg_total_relation_size('dms_documents') + pg_total_relation_size('dms_document_texts')) AS v", as: String.self)
        let idx = try await scalar("SELECT pg_size_pretty(pg_relation_size('dms_documents_search_gin') + pg_relation_size('dms_documents_trgm')) AS v", as: String.self)
        print("AK-S1-7 Befüllung \(n) Dokumente: \(String(format: "%.1f", fill)) s, Tabellen gesamt \(size), Suchindizes \(idx)")

        let cases: [(String, String, String)] = [
            ("häufiger Wortstamm (Rechnung)", "Rechnung", ""), ("seltenes Wort", "wort12345", ""), ("zwei Wörter", "Kündigung Versicherung", ""),
            ("Phrase", "\"Zahlung Vertrag\"", ""), ("Ausschluss", "Mahnung -Frist", ""), ("Tippfehler (Titel, Trigram)", "Kontoauszg", ""),
            ("Wortstamm + Filter Typ/Datum", "Rechnung", "document_type_id=\(type)&date_from=2022-01-01&date_to=2023-12-31"),
            ("Wortstamm + Facetten + Zähler", "Rechnung", "facets=true&count=true"), ("Wortstamm + Tag-Filter", "Zahlung", "tag_id=\(tag)")]
        for (label, q, extra) in cases {
            var ms: [Double] = []
            var hits = 0
            for i in 0..<15 {
                let start = Date()
                let r = try await search(w, q, extra, app: i % 2 == 0 ? app1 : app2)
                ms.append(Date().timeIntervalSince(start) * 1000)
                XCTAssertEqual(r.status, .ok, "\(label): \(r.json)")
                hits = items(r).count
            }
            ms.sort()
            print("AK-S1-7 \(label): Median \(String(format: "%.0f", ms[ms.count / 2])) ms, p95 \(String(format: "%.0f", ms[Int(Double(ms.count - 1) * 0.95)])) ms, max \(String(format: "%.0f", ms.last!)) ms, erste Seite \(hits) Treffer")
        }
        try await aEq(try await count("dms_documents"), Int64(n))
    }
}
