import XCTVapor
import Fluent
import SQLKit
@testable import HubKit

// WP-D3: Regeln, Vorschläge, Duplikate (MODUL-DMS 5.4, AK-D5). Alle Dokumente und Texte sind synthetisch.
// AK-IDs dieses WP (Akzeptanz D3 in der ROADMAP, Modul-AK-D5):
//  AK-D3-1 deterministische Vorschläge, AK-D3-2 Regex-Zeit-/Längenlimit, AK-D3-3 Regeln CRUD/Prüfung/Audit, AK-D3-4 suggest ändert nichts + Annahme/Ablehnung,
//  AK-D3-5 auto-Modus nur ausdrücklich, AK-D3-6 Trockenlauf ändert nichts, AK-D3-7 Duplikat Stufe 1, AK-D3-8 Duplikat Stufe 2, AK-D3-9 Kontakt-Matching,
//  AK-D3-10 zwei Instanzen (Vorschläge genau einmal), AK-D3-11 Mandantentrennung, AK-D3-12 Rechte, AK-D3-13 Migration.

/// Testengine: Text je Seed aus dem synthetischen PDF (`% synthetic <seed>`).
final class ScriptedOCREngine: OCRExtracting, @unchecked Sendable {
    private let lock = NSLock()
    private var scripted: [String: String] = [:]
    func set(_ seed: String, _ text: String) { lock.withLock { scripted[seed] = text } }

    func extract(input: URL, mime: String, workDir: URL) async throws -> OCRExtraction {
        let content = String(decoding: try Data(contentsOf: input), as: UTF8.self)
        let seed = content.components(separatedBy: "% synthetic ").dropFirst().first?.components(separatedBy: "\n").first ?? ""
        let archive = workDir.appendingPathComponent("archive.pdf")
        try Data("%PDF-1.7\n% synthetic archive \(UUID())\n%%EOF\n".utf8).write(to: archive)
        let text = lock.withLock { scripted[seed] ?? "" }
        return OCRExtraction(text: text, lang: "de", engine: "fake", archive: archive, pages: 1, usedOCR: true, pdfa: true)
    }
}

class DMSRulesTestBase: DMSOCRTestBase {
    static let iban = "DE89370400440532013000"

    func api(_ w: World) -> String { base(w.tenantA) }

    func makeType(_ w: World, _ name: String) async throws -> String {
        let r = try await call(app1, .POST, api(w) + "/types", json: ["name": name], token: w.alice.token)
        XCTAssertEqual(r.status, .created, "\(r.json)")
        return r.json["id"] as! String
    }
    func makeTag(_ w: World, _ name: String) async throws -> String {
        let r = try await call(app1, .POST, api(w) + "/tags", json: ["name": name], token: w.alice.token)
        XCTAssertEqual(r.status, .created, "\(r.json)")
        return r.json["id"] as! String
    }
    func makeContact(_ w: World, _ body: [String: Any]) async throws -> String {
        let r = try await call(app1, .POST, "api/v1/tenants/\(w.tenantA)/contacts", json: body, token: w.alice.token)
        XCTAssertEqual(r.status, .created, "\(r.json)")
        return r.json["id"] as! String
    }
    @discardableResult
    func makeRule(_ w: World, name: String, conditions: [[String: Any]], actions: [String: Any], mode: String = "suggest", priority: Int = 0,
                  match: String? = nil, confidence: Double? = nil) async throws -> String {
        var cond: [String: Any] = ["conditions": conditions]
        if let match { cond["match"] = match }
        var body: [String: Any] = ["name": name, "conditions": cond, "actions": actions, "mode": mode, "priority": priority]
        if let confidence { body["confidence"] = confidence }
        let r = try await call(app1, .POST, api(w) + "/rules", json: body, token: w.alice.token)
        XCTAssertEqual(r.status, .created, "\(r.json)")
        return r.json["id"] as! String
    }

    /// Lädt ein Dokument hoch, dessen Text die Testengine liefert.
    func uploadText(_ w: World, _ engine: ScriptedOCREngine, seed: String, text: String, query: String = "") async throws -> String {
        engine.set(seed, text)
        let r = try await upload(w.alice, w.tenantA, pdf(seed), query: query)
        XCTAssertEqual(r.status, .created, "\(r.json)")
        return r.json["id"] as! String
    }

    /// Lässt einen oder zwei Worker alle offenen OCR-Aufträge abarbeiten.
    func drain(_ engine: ScriptedOCREngine, workers: Int = 1) async throws {
        let list = (0..<workers).map { makeWorker(engine, on: $0 % 2 == 0 ? app1 : app2) }
        let tasks = list.map { w in Task { await w.run() } }
        try await waitFor("alle Eingänge verarbeitet") { try await count("dms_ingest_items", where: "state NOT IN ('done', 'failed_permanent')") == 0 }
        list.forEach { $0.requestShutdown() }
        for t in tasks { await t.value }
    }

    func suggestions(_ w: World, doc: String, state: String = "all") async throws -> [[String: Any]] {
        let r = try await call(app1, .GET, api(w) + "/documents/\(doc)/suggestions?state=\(state)&limit=200", token: w.alice.token)
        XCTAssertEqual(r.status, .ok, "\(r.json)")
        return items(r)
    }

    func docJSON(_ w: World, _ id: String) async throws -> [String: Any] {
        try await call(app1, .GET, api(w) + "/documents/\(id)", token: w.alice.token).json
    }

    /// Wörter `wort0 wort1 …` (reproduzierbar, jede Dreiergruppe eindeutig).
    func words(_ n: Int, prefix: String = "wort", changeEvery: Int? = nil, changePrefix: String = "anders") -> String {
        (0..<n).map { i in
            if let every = changeEvery, i % every == every - 1 { return "\(changePrefix)\(i)" }
            return "\(prefix)\(i)"
        }.joined(separator: " ")
    }
}

// MARK: - Reine Funktionen (ohne Datenbank)

final class DMSRuleEngineTests: XCTestCase {
    private func rule(_ conditions: [RuleCondition], match: String? = nil, actions: RuleActions, mode: String = "suggest", priority: Int = 0, name: String = "Test", version: Int = 1) -> RuleDefinition {
        RuleDefinition(id: UUID(uuidString: "00000000-0000-0000-0000-00000000000\(abs(name.hashValue % 9))")!, name: name, priority: priority, mode: mode, confidence: 0.8, version: version,
                       conditions: RuleConditions(version: 1, match: match, conditions: conditions), actions: actions)
    }
    private func context(_ text: String, filename: String? = "scan.pdf", source: String = "upload", sender: String? = nil) -> RuleContext {
        RuleContext(text: text, filename: filename, source: source, sender: sender, current: DocumentState(title: "scan"))
    }

    /// AK-D3-1: gleiche Eingabe und gleiche Regelversion ergeben dieselben Vorschläge in derselben Reihenfolge (auch bei 100 Wiederholungen).
    func testAKD3_1_SameInputSameSuggestions() {
        let typeID = UUID(), tagA = UUID(), tagB = UUID()
        let r = rule([RuleCondition(type: "text_contains", value: "Rechnung"), RuleCondition(type: "text_regex", pattern: "Nr\\.\\s*\\d+")],
                     actions: RuleActions(document_type_id: typeID, tag_ids: [tagB, tagA], doc_date: "extracted", title_template: "Rechnung {match} vom {date}"))
        let ctx = context("Rechnung Nr. 4711 vom 03.05.2026, zahlbar bis 31.05.2026")
        func run() -> [SuggestionCandidate] {
            guard case .matched(let hits) = DMSRuleEngine.evaluate(r, context: ctx) else { XCTFail("kein Treffer"); return [] }
            return DMSRuleEngine.candidates(for: r, hits: hits, context: ctx)
        }
        let first = run()
        XCTAssertEqual(first.map(\.kind), ["type", "tag", "tag", "date", "title"])
        XCTAssertEqual(first.first(where: { $0.kind == "date" })?.value["doc_date"], "2026-05-03", "erstes gültiges Datum im Text")
        XCTAssertTrue(first[0].reason.contains("Regel „Test“") && first[0].reason.contains("Treffer „Rechnung“"), first[0].reason)
        for _ in 0..<100 { XCTAssertEqual(run(), first) }
        // andere Regelversion/anderer Text -> anderes Ergebnis (der Test ist nicht trivial)
        XCTAssertNotEqual(DMSRuleEngine.candidates(for: rule(r.conditions.conditions, actions: r.actions, version: 2), hits: [], context: ctx).first?.ruleVersion, first.first?.ruleVersion)
    }

    /// AK-D3-1: Bedingungen all/any, Absender, Dateiname, Quelle, Groß-/Kleinschreibung.
    func testAKD3_1_ConditionSemantics() {
        let a = RuleActions(document_type_id: UUID())
        let conds = [RuleCondition(type: "text_contains", value: "stadtwerke"), RuleCondition(type: "filename_contains", value: "jahresabrechnung"),
                     RuleCondition(type: "sender_contains", value: "@example.org"), RuleCondition(type: "source_is", value: "mail")]
        let ctx = context("Stadtwerke Beispielstadt", filename: "Jahresabrechnung-2026.pdf", source: "mail", sender: "billing@example.org")
        XCTAssertEqual(DMSRuleEngine.evaluate(rule(conds, actions: a), context: ctx), DMSRuleEngine.evaluate(rule(conds, actions: a), context: ctx))
        if case .matched(let hits) = DMSRuleEngine.evaluate(rule(conds, actions: a), context: ctx) { XCTAssertEqual(hits.count, 4) } else { XCTFail("all: alle vier erfüllt") }
        XCTAssertEqual(DMSRuleEngine.evaluate(rule(conds, actions: a), context: context("Stadtwerke", filename: "x.pdf", source: "upload", sender: nil)), .noMatch, "all: eine verfehlte genügt")
        if case .matched(let hits) = DMSRuleEngine.evaluate(rule(conds, match: "any", actions: a), context: context("nichts", filename: "x.pdf", source: "mail")) { XCTAssertEqual(hits.map(\.type), ["source_is"]) } else { XCTFail("any") }
        XCTAssertEqual(DMSRuleEngine.evaluate(rule([RuleCondition(type: "text_contains", value: "STADT", case_sensitive: true)], actions: a), context: ctx), .noMatch)
    }

    /// AK-D3-2: katastrophales Backtracking wird nach dem Zeitlimit abgebrochen (Bedingung nicht erfüllt, Verdikt `timedOut`), der Aufruf kehrt rechtzeitig zurück.
    func testAKD3_2_CatastrophicBacktrackingIsAborted() {
        let evil = String(repeating: "a", count: 48) + "b"
        let re = SafeRegex.compile("(a+)+$", caseSensitive: false)!
        let start = Date()
        XCTAssertEqual(SafeRegex.firstMatch(re, in: evil, timeout: 0.2), .timedOut)
        XCTAssertLessThan(Date().timeIntervalSince(start), 3, "Abbruch nach dem Zeitlimit statt Minuten/Stunden")
        // über die Regel-Engine: kein Treffer, Verdikt timedOut; eine zweite, harmlose Regel läuft danach normal weiter
        let r = rule([RuleCondition(type: "text_regex", pattern: "(a+)+$")], actions: RuleActions(document_type_id: UUID()))
        let t0 = Date()
        XCTAssertEqual(DMSRuleEngine.evaluate(r, context: context(evil), regexTimeout: 0.2), .timedOut)
        XCTAssertLessThan(Date().timeIntervalSince(t0), 3)
        let ok = rule([RuleCondition(type: "text_regex", pattern: "b$")], actions: RuleActions(document_type_id: UUID()))
        XCTAssertNotEqual(DMSRuleEngine.evaluate(ok, context: context(evil), regexTimeout: 0.2), .timedOut)
        // gutartiges Muster trifft
        if case .match(let loc, let len) = SafeRegex.firstMatch(SafeRegex.compile("b$", caseSensitive: false)!, in: evil, timeout: 0.2) { XCTAssertEqual(loc, 48); XCTAssertEqual(len, 1) } else { XCTFail() }
    }

    /// AK-D3-2: Längenlimit des Musters und Prüfung beim Anlegen.
    func testAKD3_2_PatternLengthLimitAndValidation() {
        XCTAssertNil(SafeRegex.compile(String(repeating: "a", count: SafeRegex.maxPatternLength + 1), caseSensitive: false))
        XCTAssertNil(SafeRegex.compile("(", caseSensitive: false), "ungültiges Muster")
        XCTAssertNotNil(SafeRegex.compile(String(repeating: "a", count: SafeRegex.maxPatternLength), caseSensitive: false))
        func code(_ c: RuleCondition) -> String? {
            do { try RuleValidation.validate(RuleConditions(version: nil, match: nil, conditions: [c])); return nil } catch let e as HubError { return e.errors.first?.code }
            catch { return "other" }
        }
        XCTAssertEqual(code(RuleCondition(type: "text_regex", pattern: String(repeating: "a", count: 201))), "too_long")
        XCTAssertEqual(code(RuleCondition(type: "text_regex", pattern: "(")), "regex_invalid")
        XCTAssertEqual(code(RuleCondition(type: "text_regex")), "required")
        XCTAssertEqual(code(RuleCondition(type: "text_contains", value: " ")), "required")
        XCTAssertEqual(code(RuleCondition(type: "unbekannt", value: "x")), "unknown")
        XCTAssertEqual(code(RuleCondition(type: "source_is", value: "fax")), "unknown")
        XCTAssertNil(code(RuleCondition(type: "text_regex", pattern: "Rechnung\\s+\\d+")))
        // sehr langer Text wird gekürzt geprüft (Eingabelimit), das Muster am Ende sieht ihn nicht
        let huge = String(repeating: "x", count: SafeRegex.maxInputLength + 10) + "ENDE"
        XCTAssertEqual(SafeRegex.firstMatch(SafeRegex.compile("ENDE", caseSensitive: true)!, in: huge, timeout: 1), .noMatch)
    }

    /// AK-D3-9: Kontakt-Matching nach Signalstärke, feste Konfidenzen, deterministische Reihenfolge, Wortgrenzen, kein Treffer ohne Anlass.
    func testAKD3_9_ContactMatchingSignalsAndOrder() {
        let byIban = UUID(), byVat = UUID(), byAlias = UUID(), byName = UUID(), partial = UUID()
        let keys = [ContactMatchKey(contactID: byIban, signal: .iban, key: "DE89370400440532013000"), ContactMatchKey(contactID: byIban, signal: .name, key: "Nordlicht Energie GmbH"),
                    ContactMatchKey(contactID: byVat, signal: .vat, key: "DE123456789"), ContactMatchKey(contactID: byAlias, signal: .alias, key: "Stadtwerke Muster"),
                    ContactMatchKey(contactID: byName, signal: .name, key: "Beispiel Handels GmbH"), ContactMatchKey(contactID: partial, signal: .name, key: "Musters")]
        let text = "Beispiel Handels GmbH\nBankverbindung: DE89 3704 0044 0532 0130 00\nUSt-IdNr. DE 123 456 789 / Stadtwerke Muster / Musterstadt"
        let out = DMSContactMatch.suggestions(keys: keys, text: text, currentCorrespondent: nil)
        XCTAssertEqual(out.map(\.valueKey), [byIban, byVat, byAlias, byName].map { $0.uuidString.lowercased() }, "IBAN vor USt-ID vor Alias vor Name; 'Musters' ist nur ein Wortteil von 'Musterstadt' und trifft nicht")
        XCTAssertEqual(out.map(\.confidence), [0.99, 0.97, 0.85, 0.80])
        XCTAssertTrue(out[0].reason.contains("IBAN …3000"), out[0].reason)
        XCTAssertEqual(DMSContactMatch.suggestions(keys: keys, text: text, currentCorrespondent: nil), out, "deterministisch")
        // USt-ID als Präfix einer längeren Ziffernfolge zählt nicht
        XCTAssertTrue(DMSContactMatch.suggestions(keys: [ContactMatchKey(contactID: byVat, signal: .vat, key: "DE123456789")], text: "Referenz DE1234567891", currentCorrespondent: nil).isEmpty)
        XCTAssertTrue(DMSContactMatch.suggestions(keys: keys, text: text, currentCorrespondent: byIban).allSatisfy { $0.valueKey != byIban.uuidString.lowercased() })
    }

    /// AK-D3-8: Fingerabdruck, Ähnlichkeitsschätzung (identisch 1, leicht verändert hoch, fremd 0), zu kurzer Text ohne Fingerabdruck.
    func testAKD3_8_FingerprintAndSimilarity() {
        func w(_ n: Int, every: Int? = nil) -> String { (0..<n).map { i in every.map { i % $0 == $0 - 1 } == true ? "anders\(i)" : "wort\(i)" }.joined(separator: " ") }
        let a = DMSDuplicates.fingerprint(of: w(200))!
        XCTAssertNil(DMSDuplicates.fingerprint(of: "zu kurz"))
        XCTAssertEqual(DMSDuplicates.fingerprint(of: "  " + w(200).uppercased() + " .,;"), a, "Normalisierung: Groß-/Kleinschreibung und Satzzeichen egal")
        XCTAssertEqual(DMSDuplicates.similarity(a.sketch, a.sketch), 1)
        let near = DMSDuplicates.fingerprint(of: w(200, every: 40))!
        XCTAssertGreaterThanOrEqual(DMSDuplicates.similarity(a.sketch, near.sketch), 0.8)
        XCTAssertNotEqual(a.textHash, near.textHash)
        let foreign = DMSDuplicates.fingerprint(of: (0..<200).map { "fremd\($0)" }.joined(separator: " "))!
        XCTAssertEqual(DMSDuplicates.similarity(a.sketch, foreign.sketch), 0)
    }

    /// Datum: erstes gültiges Datum, ungültige Tage werden übersprungen.
    func testDateExtraction() {
        XCTAssertEqual(DMSRuleEngine.firstDate(in: "Datum 31.02.2026 und 1.3.2026")?.iso, "2026-03-01")
        XCTAssertEqual(DMSRuleEngine.firstDate(in: "vom 2026-05-31.")?.iso, "2026-05-31")
        XCTAssertNil(DMSRuleEngine.firstDate(in: "Nr. 12345678 99.99.9999"))
    }
}

// MARK: - Regeln (CRUD, Prüfung, Audit)

final class DMSRulesCrudTests: DMSRulesTestBase {

    /// AK-D3-3: Anlegen, Lesen, Ändern (Version steigt nur bei fachlicher Änderung), Löschen (weich), Audit ohne Regelinhalt, Eingabeprüfung.
    func testAKD3_3_CrudValidationVersionAndAudit() async throws {
        let w = try await world()
        let type = try await makeType(w, "Rechnung"), tag = try await makeTag(w, "Steuer")
        let rule = try await makeRule(w, name: "Stadtwerke-Rechnung", conditions: [["type": "text_contains", "value": "Stadtwerke"]],
                                      actions: ["document_type_id": type, "tag_ids": [tag, tag]], priority: 5)
        let got = try await call(app2, .GET, api(w) + "/rules/\(rule)", token: w.alice.token)
        XCTAssertEqual(got.status, .ok)
        XCTAssertEqual(got.json["mode"] as? String, "suggest", "Standard ist suggest (F-25)")
        XCTAssertEqual(got.json["version"] as? Int, 1)
        XCTAssertEqual((got.json["actions"] as? [String: Any])?["tag_ids"] as? [String], [tag], "doppelte Tags entfallen")
        XCTAssertEqual((got.json["conditions"] as? [String: Any])?["match"] as? String, "all")
        XCTAssertNil(got.json["tenant_id"])

        // Umbenennen/Aktivieren: Version bleibt; fachliche Änderung: Version +1
        let rename = try await call(app1, .PATCH, api(w) + "/rules/\(rule)", json: ["name": "Stadtwerke", "enabled": false], token: w.alice.token)
        XCTAssertEqual(rename.status, .ok, "\(rename.json)"); XCTAssertEqual(rename.json["version"] as? Int, 1); XCTAssertEqual(rename.json["enabled"] as? Bool, false)
        let semantic = try await call(app2, .PATCH, api(w) + "/rules/\(rule)", json: ["mode": "auto"], token: w.alice.token)
        XCTAssertEqual(semantic.json["version"] as? Int, 2); XCTAssertEqual(semantic.json["mode"] as? String, "auto")
        let same = try await call(app1, .PATCH, api(w) + "/rules/\(rule)", json: ["mode": "auto"], token: w.alice.token)
        XCTAssertEqual(same.json["version"] as? Int, 2, "unveränderter Wert erhöht die Version nicht")

        // Prüfung
        let bad: [([String: Any], String)] = [
            (["name": "", "conditions": ["conditions": [["type": "text_contains", "value": "x"]]], "actions": ["document_type_id": type]], "name"),
            (["name": "A", "mode": "magic", "conditions": ["conditions": [["type": "text_contains", "value": "x"]]], "actions": ["document_type_id": type]], "mode"),
            (["name": "B", "conditions": ["conditions": []], "actions": ["document_type_id": type]], "conditions.conditions"),
            (["name": "C", "conditions": ["conditions": [["type": "text_regex", "pattern": "("]]], "actions": ["document_type_id": type]], "conditions.conditions[0].pattern"),
            (["name": "D", "conditions": ["conditions": [["type": "text_contains", "value": "x"]]], "actions": [String: Any]()], "actions"),
            (["name": "E", "conditions": ["conditions": [["type": "text_contains", "value": "x"]]], "actions": ["document_type_id": UUID().uuidString]], "actions.document_type_id"),
            (["name": "F", "conditions": ["conditions": [["type": "text_contains", "value": "x"]]], "actions": ["tag_ids": [UUID().uuidString]]], "actions.tag_ids"),
            (["name": "G", "conditions": ["conditions": [["type": "text_contains", "value": "x"]]], "actions": ["correspondent_id": UUID().uuidString]], "actions.correspondent_id"),
            (["name": "H", "conditions": ["conditions": [["type": "text_contains", "value": "x"]]], "actions": ["title_template": "{unbekannt}"]], "actions.title_template"),
            (["name": "I", "conditions": ["conditions": [["type": "text_contains", "value": "x"]]], "actions": ["doc_date": "31.12.2026"]], "actions.doc_date"),
            (["name": "J", "confidence": 1.5, "conditions": ["conditions": [["type": "text_contains", "value": "x"]]], "actions": ["document_type_id": type]], "confidence"),
            (["name": "K", "priority": 5000, "conditions": ["conditions": [["type": "text_contains", "value": "x"]]], "actions": ["document_type_id": type]], "priority")]
        for (body, field) in bad {
            let r = try await call(app1, .POST, api(w) + "/rules", json: body, token: w.alice.token)
            XCTAssertEqual(r.status, .unprocessableEntity, field)
            XCTAssertTrue((r.json["errors"] as? [[String: Any]] ?? []).contains { $0["field"] as? String == field }, "\(field): \(r.json)")
        }
        // unbekannte Schlüssel (Tippfehler) werden nicht still ignoriert
        let typo = try await call(app1, .POST, api(w) + "/rules", json: ["name": "T", "conditions": ["conditions": [["type": "text_contains", "value": "x", "wert": "y"]]], "actions": ["document_type_id": type]], token: w.alice.token)
        XCTAssertEqual(typo.status, .unprocessableEntity)
        let dup = try await call(app1, .POST, api(w) + "/rules", json: ["name": "STADTWERKE", "conditions": ["conditions": [["type": "text_contains", "value": "x"]]], "actions": ["document_type_id": type]], token: w.alice.token)
        XCTAssertEqual(dup.status, .conflict)

        // Liste, Löschen (weich), Audit
        let list = try await call(app1, .GET, api(w) + "/rules?count=true", token: w.alice.token)
        XCTAssertEqual(items(list).count, 1); XCTAssertEqual(list.json["total"] as? Int, 1)
        let del = try await call(app2, .DELETE, api(w) + "/rules/\(rule)", token: w.alice.token)
        XCTAssertEqual(del.status, .noContent)
        let gone = try await call(app1, .GET, api(w) + "/rules/\(rule)", token: w.alice.token)
        XCTAssertEqual(gone.status, .notFound)
        try await aEq(try await count("dms_rules", where: "id = '\(rule)' AND deleted_at IS NOT NULL"), 1, "Zeile bleibt")
        try await aEq(try await auditCount("dms.rule.created", tenant: w.tenantA), 1)
        try await aEq(try await auditCount("dms.rule.updated", tenant: w.tenantA), 3)
        try await aEq(try await auditCount("dms.rule.deleted", tenant: w.tenantA), 1)
        try await aEq(try await count("audit_log", where: "action LIKE 'dms.rule.%' AND meta::text ILIKE '%Stadtwerke%'"), 0, "keine Regelinhalte im Audit")
        // Name wieder frei nach dem Löschen
        _ = try await makeRule(w, name: "Stadtwerke", conditions: [["type": "text_contains", "value": "x"]], actions: ["document_type_id": type])
    }
}

// MARK: - Pipeline: Vorschläge, Annahme, auto

final class DMSRulesPipelineTests: DMSRulesTestBase {

    /// AK-D3-4 (AK-D5): Regel im suggest-Modus erzeugt Vorschläge mit Begründung und Konfidenz, ändert aber nie Metadaten; Annahme schreibt Audit und wendet an;
    /// Ablehnung ändert nichts und fließt in die Regelstatistik.
    func testAKD3_4_SuggestModeNeverChangesMetadataAndAcceptWritesAudit() async throws {
        let w = try await world()
        let type = try await makeType(w, "Rechnung"), tag = try await makeTag(w, "Strom"), path = try await makeContact(w, ["kind": "organization", "display_name": "Beispiel Stadtwerke GmbH"])
        let rule = try await makeRule(w, name: "Stadtwerke", conditions: [["type": "text_contains", "value": "Stadtwerke"]],
                                      actions: ["document_type_id": type, "tag_ids": [tag], "doc_date": "extracted", "title_template": "Rechnung {match} {date}"], confidence: 0.9)
        let engine = ScriptedOCREngine()
        let doc = try await uploadText(w, engine, seed: "d3-suggest", text: "Beispiel Stadtwerke GmbH\nRechnung vom 03.05.2026\nBetrag 120,00 EUR", query: "filename=scan001.pdf")
        let before = try await docJSON(w, doc)
        try await drain(engine)

        // Vorschläge: Typ, Tag, Datum, Titel (Regel) + Korrespondent (Kontakt-Abgleich über den Namen)
        let all = try await suggestions(w, doc: doc)
        XCTAssertEqual(Set(all.compactMap { $0["kind"] as? String }), ["type", "tag", "date", "title", "correspondent"])
        for s in all {
            XCTAssertEqual(s["state"] as? String, "open")
            XCTAssertFalse((s["reason"] as? String ?? "").isEmpty)
            XCTAssertNotNil(s["confidence"] as? Double)
        }
        let typeS = all.first { $0["kind"] as? String == "type" }!
        XCTAssertEqual(typeS["reason"] as? String, "Regel „Stadtwerke“, Treffer „Stadtwerke“")
        XCTAssertEqual(typeS["confidence"] as? Double, 0.9); XCTAssertEqual((typeS["rule_id"] as? String)?.lowercased(), rule.lowercased())
        XCTAssertEqual((typeS["value"] as? [String: String])?["document_type_id"]?.lowercased(), type.lowercased())
        let corr = all.first { $0["kind"] as? String == "correspondent" }!
        XCTAssertEqual(corr["source"] as? String, "contact_match"); XCTAssertEqual((corr["value"] as? [String: String])?["contact_id"]?.lowercased(), path.lowercased())
        XCTAssertEqual(all.first { $0["kind"] as? String == "date" }.flatMap { ($0["value"] as? [String: String])?["doc_date"] }, "2026-05-03")
        XCTAssertEqual(all.first { $0["kind"] as? String == "title" }.flatMap { ($0["value"] as? [String: String])?["title"] }, "Rechnung Stadtwerke 2026-05-03")

        // nichts angewendet: Metadaten, Revision und Tags unverändert
        let after = try await docJSON(w, doc)
        for key in ["title", "doc_date", "document_type_id", "correspondent_id", "rev", "tag_ids"] { XCTAssertEqual("\(after[key] ?? "nil")", "\(before[key] ?? "nil")", key) }
        try await aEq(try await auditCount("dms.suggestion.accepted", tenant: w.tenantA), 0)
        try await aEq(try await auditCount("dms.suggestion.auto_applied", tenant: w.tenantA), 0)
        try await aEq(try await count("dms_suggestions", where: "state = 'open'"), 5)
        // Verarbeitungsstatus ist abgeschlossen; Klassifikationsschritt im Audit
        try await aEq(try await itemState(doc), "done")
        try await aEq(try await auditCount("dms.ingest.classified", tenant: w.tenantA), 1)

        // Annahme (zweite Instanz): Audit, Wirkung am Dokument
        let id = typeS["id"] as! String
        let accepted = try await call(app2, .POST, api(w) + "/suggestions/\(id)/accept", token: w.alice.token)
        XCTAssertEqual(accepted.status, .ok, "\(accepted.json)")
        XCTAssertEqual(accepted.json["state"] as? String, "accepted"); XCTAssertNotNil(accepted.json["decided_by"] as? String)
        let tagS = all.first { $0["kind"] as? String == "tag" }!["id"] as! String, corrS = corr["id"] as! String
        for s in [tagS, corrS] { try await aEq((try await call(app1, .POST, api(w) + "/suggestions/\(s)/accept", token: w.alice.token)).status, .ok) }
        let applied = try await docJSON(w, doc)
        XCTAssertEqual((applied["document_type_id"] as? String)?.lowercased(), type.lowercased()); XCTAssertEqual((applied["tag_ids"] as? [String])?.map { $0.lowercased() }, [tag.lowercased()]); XCTAssertEqual((applied["correspondent_id"] as? String)?.lowercased(), path.lowercased())
        XCTAssertEqual(applied["title"] as? String, before["title"] as? String, "nicht angenommene Vorschläge ändern nichts")
        try await aEq(try await auditCount("dms.suggestion.accepted", tenant: w.tenantA), 3)
        try await aEq(try await count("links", where: "from_id = '\(doc)' AND kind = 'correspondent' AND removed_at IS NULL AND source = 'manual'"), 1)
        // erneut entscheiden: 409
        let again = try await call(app1, .POST, api(w) + "/suggestions/\(id)/accept", token: w.alice.token)
        XCTAssertEqual(again.status, .conflict); XCTAssertEqual(again.problemCode, "suggestion_decided")
        try await aEq((try await call(app1, .POST, api(w) + "/suggestions/\(id)/reject", token: w.alice.token)).status, .conflict)

        // Ablehnung: ändert nichts, Statistik
        let titleS = all.first { $0["kind"] as? String == "title" }!["id"] as! String
        let rejected = try await call(app2, .POST, api(w) + "/suggestions/\(titleS)/reject", token: w.alice.token)
        XCTAssertEqual(rejected.json["state"] as? String, "rejected")
        try await aEq(try await docJSON(w, doc)["title"] as? String, before["title"] as? String)
        try await aEq(try await auditCount("dms.suggestion.rejected", tenant: w.tenantA), 1)
        let stats = try await call(app1, .GET, api(w) + "/rules/\(rule)", token: w.alice.token).json["stats"] as? [String: Int]
        XCTAssertEqual(stats?["suggested"], 4); XCTAssertEqual(stats?["accepted"], 2); XCTAssertEqual(stats?["rejected"], 1); XCTAssertEqual(stats?["open"], 1)
        // Liste nach Zustand
        try await aEq(items(try await call(app1, .GET, api(w) + "/suggestions", token: w.alice.token)).count, 1, "Standard: nur offene (das Datum)")
        try await aEq(items(try await call(app1, .GET, api(w) + "/suggestions?state=rejected&kind=title", token: w.alice.token)).count, 1)
        try await aEq((try await call(app1, .GET, api(w) + "/suggestions?state=bogus", token: w.alice.token)).status, .unprocessableEntity)
    }

    /// AK-D3-4: Annahme eines Vorschlags, dessen Ziel inzwischen fehlt oder der nicht mehr passt: 409 `suggestion_stale`, nichts geändert; Papierkorb: 409.
    func testAKD3_4_StaleAndTrashedSuggestions() async throws {
        let w = try await world()
        let type = try await makeType(w, "Vertrag")
        try await makeRule(w, name: "Vertrag", conditions: [["type": "text_contains", "value": "Vertrag"]], actions: ["document_type_id": type])
        let engine = ScriptedOCREngine()
        let d1 = try await uploadText(w, engine, seed: "stale-1", text: "Mietvertrag Nr. 1")
        let d2 = try await uploadText(w, engine, seed: "stale-2", text: "Liefervertrag Nr. 2")
        try await drain(engine)
        let s1 = try await suggestions(w, doc: d1)[0]["id"] as! String, s2 = try await suggestions(w, doc: d2)[0]["id"] as! String
        // Typ verschwindet (Löschen ist blockiert, solange ein Dokument ihn nutzt; hier ist es noch keines): Löschen, dann Annahme
        try await aEq((try await call(app1, .DELETE, api(w) + "/types/\(type)", token: w.alice.token)).status, .noContent)
        let stale = try await call(app1, .POST, api(w) + "/suggestions/\(s1)/accept", token: w.alice.token)
        XCTAssertEqual(stale.status, .conflict); XCTAssertEqual(stale.problemCode, "suggestion_stale")
        try await aEq(try await scalar("SELECT state AS v FROM dms_suggestions WHERE id = '\(s1)'", as: String.self), "open", "bleibt offen, nichts halb angewendet")
        // Papierkorb
        try await aEq((try await call(app1, .POST, api(w) + "/documents/\(d2)/trash", json: ["reason": "Test"], token: w.alice.token)).status, .ok)
        let trashed = try await call(app1, .POST, api(w) + "/suggestions/\(s2)/accept", token: w.alice.token)
        XCTAssertEqual(trashed.status, .conflict); XCTAssertEqual(trashed.problemCode, "document_trashed")
        try await aEq(items(try await call(app1, .GET, api(w) + "/suggestions?state=open", token: w.alice.token)).count, 1, "Papierkorb-Dokumente erscheinen nicht in der Liste")
    }

    /// AK-D3-5 (F-25): Modus `auto` nur ausdrücklich je Regel; wendet nur auf leere Einzelwerte an, die höchste Priorität gewinnt, jede Anwendung steht im Audit;
    /// bestehende Werte werden nie überschrieben (dann bleibt es ein offener Vorschlag).
    func testAKD3_5_AutoModeIsExplicitAndNeverOverwrites() async throws {
        let w = try await world()
        let hi = try await makeType(w, "Ausgangsrechnung"), lo = try await makeType(w, "Sonstiges"), existing = try await makeType(w, "Bereits gesetzt"), tag = try await makeTag(w, "Eigen")
        // gleiche Bedingung, zwei auto-Regeln mit verschiedener Priorität, dazu eine suggest-Regel für Tags
        try await makeRule(w, name: "Eigene Rechnung hoch", conditions: [["type": "text_contains", "value": "Musterfirma Ausgangsrechnung"]], actions: ["document_type_id": hi], mode: "auto", priority: 10)
        try await makeRule(w, name: "Eigene Rechnung niedrig", conditions: [["type": "text_contains", "value": "Musterfirma Ausgangsrechnung"]], actions: ["document_type_id": lo], mode: "auto", priority: 1)
        try await makeRule(w, name: "Tag nur Vorschlag", conditions: [["type": "text_contains", "value": "Musterfirma Ausgangsrechnung"]], actions: ["tag_ids": [tag]])
        let engine = ScriptedOCREngine()
        let fresh = try await uploadText(w, engine, seed: "auto-fresh", text: "Musterfirma Ausgangsrechnung 2026-001")
        let set = try await uploadText(w, engine, seed: "auto-set", text: "Musterfirma Ausgangsrechnung 2026-002", query: "document_type_id=\(existing)")
        try await drain(engine)

        let f = try await docJSON(w, fresh)
        XCTAssertEqual(f["document_type_id"] as? String, hi, "höchste Priorität gewinnt")
        XCTAssertEqual((f["tag_ids"] as? [String] ?? []).count, 0, "suggest-Regel wendet nichts an")
        let fs = try await suggestions(w, doc: fresh)
        XCTAssertEqual(fs.filter { $0["applied_automatically"] as? Bool == true }.count, 1)
        XCTAssertEqual(fs.first { $0["applied_automatically"] as? Bool == true }?["state"] as? String, "accepted")
        XCTAssertEqual(fs.filter { $0["state"] as? String == "open" }.count, 2, "niedrigere auto-Regel + Tag bleiben offen")
        try await aEq(try await auditCount("dms.suggestion.auto_applied", tenant: w.tenantA), 1, "nur für das frische Dokument")

        let s = try await docJSON(w, set)
        XCTAssertEqual(s["document_type_id"] as? String, existing, "vorhandener Wert wird nie überschrieben")
        try await aEq(try await suggestions(w, doc: set, state: "open").filter { $0["kind"] as? String == "type" }.count, 2)
        // Standard bleibt suggest
        let d = try await call(app1, .POST, api(w) + "/rules", json: ["name": "Ohne Modus", "conditions": ["conditions": [["type": "text_contains", "value": "x"]]], "actions": ["document_type_id": hi]], token: w.alice.token)
        XCTAssertEqual(d.json["mode"] as? String, "suggest")
    }

    /// AK-D3-2 (Pipeline): Eine Regel mit katastrophalem Muster bricht das Dokument nicht, sondern wird nach dem Limit übersprungen; die Verarbeitung endet, andere Regeln wirken.
    func testAKD3_2_PipelineSurvivesCatastrophicRegex() async throws {
        let w = try await world()
        let type = try await makeType(w, "Notiz"), tag = try await makeTag(w, "Ok")
        try await makeRule(w, name: "Böse", conditions: [["type": "text_regex", "pattern": "(a+)+$"]], actions: ["document_type_id": type], priority: 10)
        try await makeRule(w, name: "Gut", conditions: [["type": "text_contains", "value": "aaaa"]], actions: ["tag_ids": [tag]], priority: 1)
        let engine = ScriptedOCREngine()
        let doc = try await uploadText(w, engine, seed: "evil", text: String(repeating: "a", count: 48) + "b")
        let start = Date()
        try await drain(engine)
        XCTAssertLessThan(Date().timeIntervalSince(start), 20)
        try await aEq(try await itemState(doc), "done")
        let kinds = try await suggestions(w, doc: doc).compactMap { $0["kind"] as? String }
        XCTAssertEqual(kinds, ["tag"], "böse Regel liefert nichts, gute wirkt")
        try await aEq(try await count("audit_log", where: "action = 'dms.ingest.classified' AND (meta->>'regex_timeouts')::int = 1"), 1)
    }

    /// AK-D3-1 (Pipeline): zwei Dokumente mit gleichem Text und gleichen Regeln erhalten gleiche Vorschläge; Wiederholung des Klassifizierens legt nichts doppelt an.
    func testAKD3_1_SameTextSameSuggestionsAndRerunIsIdempotent() async throws {
        let w = try await world()
        let type = try await makeType(w, "Rechnung"), tag = try await makeTag(w, "Offen")
        try await makeRule(w, name: "A", conditions: [["type": "text_contains", "value": "Rechnung"]], actions: ["document_type_id": type, "tag_ids": [tag]], priority: 2)
        try await makeRule(w, name: "B", conditions: [["type": "text_regex", "pattern": "Nr\\.\\s*\\d+"]], actions: ["title_template": "Beleg {match}"], priority: 1)
        let engine = ScriptedOCREngine()
        let text = "Rechnung Nr. 4711 vom 03.05.2026 " + words(30)
        let d1 = try await uploadText(w, engine, seed: "same-1", text: text, query: "filename=eins.pdf"), d2 = try await uploadText(w, engine, seed: "same-2", text: text, query: "filename=zwei.pdf")
        try await drain(engine)
        func shape(_ doc: String) async throws -> [String] {
            try await suggestions(w, doc: doc).map { "\($0["kind"] ?? "")|\($0["reason"] ?? "")|\($0["confidence"] ?? "")|\(($0["value"] as? [String: String])?.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ",") ?? "")" }.sorted()
        }
        let s1 = try await shape(d1), s2 = try await shape(d2)
        XCTAssertEqual(s1.count, 3); XCTAssertEqual(s1, s2)
        // Klassifikation erneut ausführen (Wiederholung, zweite Verbindung): keine neuen Zeilen, kein Audit-Doppel für Auto
        let tenant = UUID(uuidString: w.tenantA)!, item = UUID(uuidString: try await scalar("SELECT id::text AS v FROM dms_ingest_items WHERE document_id = '\(d1)'", as: String.self))!
        let before = try await count("dms_suggestions")
        let outcome = try await DMSClassify.run(item: item, document: UUID(uuidString: d1)!, tenant: tenant, text: text, on: app2.db(.psql))
        XCTAssertEqual(outcome.suggestions, 0)
        try await aEq(try await count("dms_suggestions"), before)
    }
}

// MARK: - Trockenlauf

final class DMSRulesPreviewTests: DMSRulesTestBase {

    /// AK-D3-6: Trockenlauf listet Treffer mit Begründung und ändert nichts (keine Zeile, kein Audit, keine Revision, kein Job), für gespeicherte Regeln und Entwürfe.
    func testAKD3_6_PreviewListsMatchesAndChangesNothing() async throws {
        let w = try await world()
        let type = try await makeType(w, "Rechnung")
        let engine = ScriptedOCREngine()
        let hit1 = try await uploadText(w, engine, seed: "pv-1", text: "Rechnung der Stadtwerke Nummer 1")
        let hit2 = try await uploadText(w, engine, seed: "pv-2", text: "Zweite Rechnung der Stadtwerke")
        _ = try await uploadText(w, engine, seed: "pv-3", text: "Ein Brief ohne Bezug")
        let trashed = try await uploadText(w, engine, seed: "pv-4", text: "Rechnung im Papierkorb")
        try await drain(engine)
        try await aEq((try await call(app1, .POST, api(w) + "/documents/\(trashed)/trash", json: ["reason": "x"], token: w.alice.token)).status, .ok)
        let rule = try await makeRule(w, name: "Preview", conditions: [["type": "text_contains", "value": "Rechnung"]], actions: ["document_type_id": type, "title_template": "R {match}"], mode: "auto")

        func fingerprint() async throws -> String {
            try await scalar("""
                SELECT concat_ws('|', (SELECT count(*) FROM dms_suggestions), (SELECT count(*) FROM audit_log), (SELECT coalesce(sum(rev), 0) FROM dms_documents),
                  (SELECT count(*) FROM jobs), (SELECT count(*) FROM dms_rules), (SELECT coalesce(sum(version), 0) FROM dms_rules), (SELECT count(*) FROM dms_duplicates),
                  (SELECT count(*) FROM dms_document_tags), (SELECT count(*) FROM links), (SELECT count(*) FROM dms_documents WHERE document_type_id IS NOT NULL)) AS v
                """, as: String.self)
        }
        let before = try await fingerprint()
        let stored = try await call(app2, .POST, api(w) + "/rules/\(rule)/preview", token: w.alice.token)
        XCTAssertEqual(stored.status, .ok, "\(stored.json)")
        XCTAssertEqual(stored.json["checked"] as? Int, 3, "Papierkorb nicht geprüft"); XCTAssertEqual(stored.json["matched"] as? Int, 2)
        XCTAssertEqual(stored.json["timed_out"] as? Int, 0); XCTAssertEqual(stored.json["truncated"] as? Bool, false)
        XCTAssertEqual(Set(items(stored).compactMap { $0["document_id"] as? String }), [hit1, hit2])
        let first = items(stored)[0]
        XCTAssertEqual((first["matches"] as? [[String: Any]])?.first?["matched"] as? String, "Rechnung")
        let kinds = (first["suggestions"] as? [[String: Any]])?.compactMap { $0["kind"] as? String }
        XCTAssertEqual(kinds, ["type", "title"])
        XCTAssertTrue(((first["suggestions"] as? [[String: Any]])?.first?["reason"] as? String ?? "").contains("Regel „Preview“"))

        // Entwurf (nicht gespeichert), mit Limit
        let draft = try await call(app1, .POST, api(w) + "/rules/preview", json: ["conditions": ["conditions": [["type": "text_contains", "value": "stadtwerke"]]], "actions": ["document_type_id": type], "limit": 2], token: w.alice.token)
        XCTAssertEqual(draft.status, .ok, "\(draft.json)")
        XCTAssertEqual(draft.json["checked"] as? Int, 2); XCTAssertNil(draft.json["rule_id"] as? String)
        // fehlerhafte Entwürfe
        let invalid = try await call(app1, .POST, api(w) + "/rules/preview", json: ["conditions": ["conditions": [["type": "text_regex", "pattern": "("]]], "actions": ["document_type_id": type]], token: w.alice.token)
        XCTAssertEqual(invalid.status, .unprocessableEntity)
        let foreignType = try await call(app1, .POST, api(w) + "/rules/preview", json: ["conditions": ["conditions": [["type": "text_contains", "value": "x"]]], "actions": ["document_type_id": UUID().uuidString]], token: w.alice.token)
        XCTAssertEqual(foreignType.status, .unprocessableEntity)
        try await aEq(try await fingerprint(), before, "Trockenlauf ändert nichts")
    }

    /// AK-D3-6 + AK-D3-2: Trockenlauf mit katastrophalem Muster meldet `timed_out` und kehrt zurück.
    func testAKD3_6_PreviewReportsRegexTimeouts() async throws {
        let w = try await world()
        let engine = ScriptedOCREngine()
        _ = try await uploadText(w, engine, seed: "pv-evil", text: String(repeating: "a", count: 48) + "b")
        try await drain(engine)
        let start = Date()
        let r = try await call(app1, .POST, api(w) + "/rules/preview", json: ["conditions": ["conditions": [["type": "text_regex", "pattern": "(a+)+$"]]], "actions": ["title_template": "{match}"]], token: w.alice.token)
        XCTAssertEqual(r.status, .ok, "\(r.json)")
        XCTAssertEqual(r.json["timed_out"] as? Int, 1); XCTAssertEqual(r.json["matched"] as? Int, 0)
        XCTAssertLessThan(Date().timeIntervalSince(start), 10)
    }
}

// MARK: - Duplikate

final class DMSDuplicatesTests: DMSRulesTestBase {

    /// AK-D3-7: Stufe 1 (identischer Hash): Treffer als Hinweis mit Gegenüberstellung, kein stilles Verwerfen; entscheiden schreibt Audit.
    func testAKD3_7_Stage1IdenticalHash() async throws {
        let w = try await world()
        let a = try await newDoc(w.alice, w.tenantA, seed: "dup-hash", query: "title=Erstes")
        let b = try await newDoc(w.alice, w.tenantA, seed: "dup-hash", query: "title=Zweites")
        _ = try await newDoc(w.alice, w.tenantA, seed: "other-hash", query: "title=Anderes")
        XCTAssertNotEqual(a["id"] as? String, b["id"] as? String, "kein stilles Verwerfen: beide Dokumente existieren")
        let list = try await call(app2, .GET, api(w) + "/duplicates", token: w.alice.token)
        XCTAssertEqual(items(list).count, 1)
        let d = items(list)[0]
        XCTAssertEqual(d["method"] as? String, "sha256"); XCTAssertEqual(d["score"] as? Double, 1)
        XCTAssertEqual(d["document_id"] as? String, b["id"] as? String); XCTAssertEqual(d["duplicate_of"] as? String, a["id"] as? String)
        XCTAssertEqual(d["document_title"] as? String, "Zweites"); XCTAssertEqual(d["duplicate_of_title"] as? String, "Erstes")
        XCTAssertEqual(d["state"] as? String, "open")
        try await aEq(items(try await call(app1, .GET, api(w) + "/duplicates?document_id=\(a["id"] as! String)", token: w.alice.token)).count, 1, "auch vom älteren Dokument aus sichtbar")
        try await aEq(items(try await call(app1, .GET, api(w) + "/duplicates?method=similarity", token: w.alice.token)).count, 0)
        // Entscheiden
        let id = d["id"] as! String
        let bad = try await call(app1, .POST, api(w) + "/duplicates/\(id)/resolve", json: ["state": "open"], token: w.alice.token)
        XCTAssertEqual(bad.status, .unprocessableEntity)
        let ok = try await call(app1, .POST, api(w) + "/duplicates/\(id)/resolve", json: ["state": "confirmed"], token: w.alice.token)
        XCTAssertEqual(ok.status, .ok); XCTAssertEqual(ok.json["state"] as? String, "confirmed")
        try await aEq((try await call(app2, .POST, api(w) + "/duplicates/\(id)/resolve", json: ["state": "dismissed"], token: w.alice.token)).status, .conflict)
        try await aEq(try await auditCount("dms.duplicate.resolved", tenant: w.tenantA), 1)
        try await aEq(items(try await call(app1, .GET, api(w) + "/duplicates", token: w.alice.token)).count, 0, "Standard: nur offene")
        try await aEq(items(try await call(app1, .GET, api(w) + "/duplicates?state=all", token: w.alice.token)).count, 1)
        // beide Dokumente unverändert vorhanden
        try await aEq(try await count("dms_documents", where: "trashed_at IS NULL"), 3)
    }

    /// AK-D3-8: Stufe 2 nach OCR: gleicher normalisierter Text (anderes Original) -> `text_hash`; leicht verändert -> `similarity`; fremder Text und zu kurzer Text -> nichts;
    /// mittlere Ähnlichkeit zählt nur bei gleichem Belegdatum und ähnlichem Titel (Metadaten, pg_trgm).
    func testAKD3_8_Stage2TextSimilarity() async throws {
        let w = try await world()
        let engine = ScriptedOCREngine()
        let base = words(200)
        let a = try await uploadText(w, engine, seed: "t-a", text: base)
        try await drain(engine)
        let same = try await uploadText(w, engine, seed: "t-same", text: base.uppercased() + " .")      // anderes Original, gleicher normalisierter Text
        let near = try await uploadText(w, engine, seed: "t-near", text: words(200, changeEvery: 40))     // 5 Wörter verändert
        let foreign = try await uploadText(w, engine, seed: "t-foreign", text: words(200, prefix: "fremd"))
        let short = try await uploadText(w, engine, seed: "t-short", text: "nur ein kurzer Text")
        try await drain(engine)
        func pairs(_ doc: String) async throws -> [String] {
            let r = try await call(app1, .GET, api(w) + "/duplicates?document_id=\(doc)&limit=200", token: w.alice.token)
            return items(r).filter { $0["document_id"] as? String == doc }.map { "\($0["method"] ?? "")" }.sorted()
        }
        try await aTrue(try await pairs(same).contains("text_hash"))
        try await aTrue(try await pairs(near).contains("similarity"))
        try await aEq(try await pairs(foreign), [])
        try await aEq(try await pairs(short), [])
        let nearRow = try await scalar("SELECT score::float8 AS v FROM dms_duplicates WHERE document_id = '\(near)' AND duplicate_of = '\(a)' AND method = 'similarity'", as: Double.self)
        XCTAssertGreaterThanOrEqual(nearRow, 0.8); XCTAssertLessThan(nearRow, 1)
        let exact = try await scalar("SELECT score::float8 AS v FROM dms_duplicates WHERE document_id = '\(same)' AND duplicate_of = '\(a)' AND method = 'text_hash'", as: Double.self)
        XCTAssertEqual(exact, 1)
        // keine Selbstpaare, höchstens ein Paar je Methode
        try await aEq(try await count("dms_duplicates", where: "document_id = duplicate_of"), 0)
        // Metadaten: mittlere Ähnlichkeit (jedes 12. Wort verändert) nur mit gleichem Datum und ähnlichem Titel
        let m0 = try await uploadText(w, engine, seed: "m-0", text: words(200, prefix: "mitte"), query: "title=Vertrag%20Alpha&doc_date=2026-03-01")
        try await drain(engine)
        let m1 = try await uploadText(w, engine, seed: "m-1", text: words(200, prefix: "mitte", changeEvery: 12, changePrefix: "neu"), query: "title=Vertrag%20Alpha&doc_date=2026-03-01")
        let m2 = try await uploadText(w, engine, seed: "m-2", text: words(200, prefix: "mitte", changeEvery: 12, changePrefix: "neu"), query: "title=Etwas%20ganz%20Anderes&doc_date=2025-01-01")
        try await drain(engine)
        try await aEq(try await pairs(m1).filter { $0 == "similarity" }.count, 1, "gleiche Metadaten + mittlere Textähnlichkeit")
        let midScore = try await scalar("SELECT score::float8 AS v FROM dms_duplicates WHERE document_id = '\(m1)' AND duplicate_of = '\(m0)'", as: Double.self)
        XCTAssertGreaterThanOrEqual(midScore, 0.5); XCTAssertLessThan(midScore, 0.8)
        try await aEq(try await count("dms_duplicates", where: "document_id = '\(m2)' AND duplicate_of = '\(m0)'"), 0, "andere Metadaten: kein Treffer bei mittlerer Ähnlichkeit")
    }
}

// MARK: - Zwei Instanzen

final class DMSRulesTwoInstanceTests: DMSRulesTestBase {

    /// AK-D3-10: 16 Dokumente, zwei Worker auf zwei Verbindungen: je Dokument genau ein Satz Vorschläge, ein Klassifikations-Audit, ein Übergang.
    func testAKD3_10_TwoWorkersSuggestionsExactlyOnce() async throws {
        let w = try await world()
        let type = try await makeType(w, "Rechnung"), tag = try await makeTag(w, "Neu")
        try await makeRule(w, name: "R", conditions: [["type": "text_contains", "value": "Rechnung"]], actions: ["document_type_id": type, "tag_ids": [tag], "title_template": "Beleg {filename}"])
        let engine = ScriptedOCREngine()
        var docs: [String] = []
        for i in 0..<16 { docs.append(try await uploadText(w, engine, seed: "two-\(i)", text: "Rechnung Nummer \(i) " + words(20, prefix: "w\(i)x"), query: "filename=beleg\(i).pdf")) }
        try await drain(engine, workers: 2)
        for d in docs { try await aEq(try await count("dms_suggestions", where: "document_id = '\(d)'"), 3, d) }
        try await aEq(try await count("dms_suggestions"), 48)
        try await aEq(try await auditCount("dms.ingest.classified", tenant: w.tenantA), 16)
        try await aEq(try await count("dms_ingest_items", where: "state = 'done'"), 16)
        try await aEq(try await count("jobs", where: "kind = 'dms.ocr' AND state = 'done'"), 16)
    }

    /// AK-D3-10: Klassifizierung desselben Dokuments gleichzeitig auf zwei Verbindungen: Vorschläge genau einmal; auto-Anwendung genau einmal (ein Audit).
    func testAKD3_10_ConcurrentClassifyOfSameDocumentIsIdempotent() async throws {
        let w = try await world()
        let type = try await makeType(w, "Auto-Typ"), tag = try await makeTag(w, "T")
        try await makeRule(w, name: "Auto", conditions: [["type": "text_contains", "value": "Parallel"]], actions: ["document_type_id": type], mode: "auto")
        try await makeRule(w, name: "Vorschlag", conditions: [["type": "text_contains", "value": "Parallel"]], actions: ["tag_ids": [tag]])
        let engine = ScriptedOCREngine()
        let doc = try await uploadText(w, engine, seed: "par-1", text: "Parallel verarbeitet " + words(20))
        try await drain(engine)
        let tenant = UUID(uuidString: w.tenantA)!, document = UUID(uuidString: doc)!
        let item = UUID(uuidString: try await scalar("SELECT id::text AS v FROM dms_ingest_items WHERE document_id = '\(doc)'", as: String.self))!
        try await db.raw("DELETE FROM dms_suggestions WHERE document_id = \(bind: document)").run()
        try await db.raw("UPDATE dms_documents SET document_type_id = NULL WHERE id = \(bind: document)").run()
        let auditBefore = try await auditCount("dms.suggestion.auto_applied", tenant: w.tenantA)
        let text = "Parallel verarbeitet " + words(20)
        let results = try await withThrowingTaskGroup(of: DMSClassify.Outcome.self) { group in
            for i in 0..<6 { let app = i % 2 == 0 ? app1! : app2!; group.addTask { try await DMSClassify.run(item: item, document: document, tenant: tenant, text: text, on: app.db(.psql)) } }
            var out: [DMSClassify.Outcome] = []
            for try await r in group { out.append(r) }
            return out
        }
        XCTAssertEqual(results.map(\.suggestions).reduce(0, +), 2, "genau einmal angelegt: \(results)")
        XCTAssertEqual(results.map(\.automatic).reduce(0, +), 1)
        try await aEq(try await count("dms_suggestions", where: "document_id = '\(doc)'"), 2)
        try await aEq(try await auditCount("dms.suggestion.auto_applied", tenant: w.tenantA), auditBefore + 1)
        try await aEq((try await docJSON(w, doc)["document_type_id"] as? String)?.lowercased(), type.lowercased())
    }

    /// AK-D3-10: gleichzeitig verarbeitete Kopien (gleicher Text, zwei Worker) ergeben genau ein Duplikatpaar (die spätere sieht die frühere).
    func testAKD3_10_ConcurrentCopiesYieldExactlyOnePair() async throws {
        let w = try await world()
        let engine = ScriptedOCREngine()
        let text = words(150)
        _ = try await uploadText(w, engine, seed: "copy-1", text: text)
        _ = try await uploadText(w, engine, seed: "copy-2", text: text)
        try await drain(engine, workers: 2)
        try await aEq(try await count("dms_duplicates", where: "method = 'text_hash'"), 1)
        try await aEq(try await count("dms_duplicates"), 1)
    }
}

// MARK: - Mandantentrennung und Rechte

final class DMSRulesTenancyTests: DMSRulesTestBase {

    /// AK-D3-11: Mandant B sieht nichts von A, fremde IDs sind 404 auf jeder neuen Route; Verweise über Mandanten scheitern (API 422, SQL Fehler); Kontakt-Matching nur im eigenen Mandanten.
    func testAKD3_11_TenantIsolation() async throws {
        let w = try await world()
        let tenantB = (try await call(app1, .POST, "api/v1/tenants", json: ["name": "Zweiter Mandant"], token: w.alice.token)).json["id"] as! String
        let carol = try await addUser("owner", handle: "carol", tenant: tenantB, by: w.alice)
        try await setModule(tenantB, true, by: carol)
        let b = base(tenantB)

        let typeA = try await makeType(w, "Nur A")
        _ = try await makeContact(w, ["kind": "organization", "display_name": "Geheime Gesellschaft mbH", "vat_id": "DE999888777"])
        let ruleA = try await makeRule(w, name: "Regel A", conditions: [["type": "text_contains", "value": "Geheim"]], actions: ["document_type_id": typeA])
        let engine = ScriptedOCREngine()
        let docA = try await uploadText(w, engine, seed: "iso-a", text: "Geheime Gesellschaft mbH " + words(20))
        let dupA = try await uploadText(w, engine, seed: "iso-a2", text: "Geheime Gesellschaft mbH " + words(20))
        try await drain(engine)
        let suggestionA = try await suggestions(w, doc: docA)[0]["id"] as! String
        let dupID = items(try await call(app1, .GET, api(w) + "/duplicates", token: w.alice.token)).first?["id"] as? String
        XCTAssertNotNil(dupID); XCTAssertFalse(dupA.isEmpty)

        // B-Dokument mit gleichem Text und gleicher Datei: kein Duplikat/keine Vorschläge über Mandantengrenzen
        let bEngine = ScriptedOCREngine()
        bEngine.set("iso-a", "Geheime Gesellschaft mbH " + words(20))
        let upB = try await upload(carol, tenantB, pdf("iso-a"))
        XCTAssertEqual(upB.status, .created, "\(upB.json)")
        let ws = makeWorker(bEngine)
        let task = Task { await ws.run() }
        try await waitFor("B verarbeitet") { try await count("dms_ingest_items", where: "tenant_id = '\(tenantB)' AND state = 'done'") == 1 }
        ws.requestShutdown(); await task.value
        try await aEq(try await count("dms_suggestions", where: "tenant_id = '\(tenantB)'"), 0, "Regeln und Kontakte von A wirken nicht in B")
        try await aEq(try await count("dms_duplicates", where: "tenant_id = '\(tenantB)'"), 0, "Hash und Text von A sind kein Duplikat in B")
        try await aEq(items(try await call(app2, .GET, b + "/rules", token: carol.token)).count, 0)
        try await aEq(items(try await call(app2, .GET, b + "/suggestions?state=all", token: carol.token)).count, 0)
        try await aEq(items(try await call(app2, .GET, b + "/duplicates?state=all", token: carol.token)).count, 0)

        let probes: [(HTTPMethod, String, [String: Any]?)] = [
            (.GET, "/rules/\(ruleA)", nil), (.PATCH, "/rules/\(ruleA)", ["name": "Hack"]), (.DELETE, "/rules/\(ruleA)", nil), (.POST, "/rules/\(ruleA)/preview", nil),
            (.POST, "/suggestions/\(suggestionA)/accept", nil), (.POST, "/suggestions/\(suggestionA)/reject", nil),
            (.GET, "/documents/\(docA)/suggestions", nil), (.POST, "/duplicates/\(dupID ?? UUID().uuidString)/resolve", ["state": "dismissed"])]
        for (m, p, body) in probes {
            let r = try await call(app2, m, b + p, json: body, token: carol.token)
            XCTAssertEqual(r.status, .notFound, "\(m) \(p)")
        }
        // Regel in B mit Typ aus A
        let cross = try await call(app1, .POST, b + "/rules", json: ["name": "Fremd", "conditions": ["conditions": [["type": "text_contains", "value": "x"]]], "actions": ["document_type_id": typeA]], token: carol.token)
        XCTAssertEqual(cross.status, .unprocessableEntity)
        // Datenbank: Vorschlag/Duplikat über Mandantengrenzen scheitert
        let tenantBID = UUID(uuidString: tenantB)!, docAID = UUID(uuidString: docA)!
        do {
            try await db.raw("INSERT INTO dms_suggestions (tenant_id, document_id, kind, value, value_key, source, confidence, reason) VALUES (\(bind: tenantBID), \(bind: docAID), 'title', '{}'::jsonb, 'x', 'contact_match', 0.5, 'x')").run()
            XCTFail("Fremdschlüssel (tenant_id, document_id) erwartet")
        } catch {}
        // A unverändert
        try await aNil(try await docJSON(w, docA)["document_type_id"] as? String)
        try await aEq(try await suggestions(w, doc: docA, state: "open").count > 0, true)
    }

    /// AK-D3-12: Rechte erlaubt/verboten je Rolle. (Die Rolle×Route-Matrix mit Zustandsabdruck steht in `DMSTests.testPermissionMatrixPerRoute`.)
    func testAKD3_12_RolesAllowedAndForbidden() async throws {
        let w = try await world()
        let member = try await addUser("member", handle: "mia", tenant: w.tenantA, by: w.alice)
        let tax = try await addUser("tax_advisor", handle: "tom", tenant: w.tenantA, by: w.alice)
        let viewer = try await addUser("customer_viewer", handle: "vera", tenant: w.tenantA, by: w.alice)
        let type = try await makeType(w, "Typ")
        let rule = try await makeRule(w, name: "R", conditions: [["type": "text_contains", "value": "Rechnung"]], actions: ["document_type_id": type])
        let engine = ScriptedOCREngine()
        let doc = try await uploadText(w, engine, seed: "perm", text: "Rechnung")
        try await drain(engine)
        let s = try await suggestions(w, doc: doc)[0]["id"] as! String
        let body: [String: Any] = ["name": "Neu", "conditions": ["conditions": [["type": "text_contains", "value": "x"]]], "actions": ["document_type_id": type]]

        // Mitglied: Regeln lesen, Vorschläge sehen und entscheiden; Regeln ändern/Trockenlauf verboten
        try await aEq((try await call(app1, .GET, api(w) + "/rules", token: member.token)).status, .ok)
        try await aEq((try await call(app1, .POST, api(w) + "/rules", json: body, token: member.token)).status, .forbidden)
        try await aEq((try await call(app1, .PATCH, api(w) + "/rules/\(rule)", json: ["enabled": false], token: member.token)).status, .forbidden)
        try await aEq((try await call(app1, .DELETE, api(w) + "/rules/\(rule)", token: member.token)).status, .forbidden)
        try await aEq((try await call(app1, .POST, api(w) + "/rules/\(rule)/preview", token: member.token)).status, .forbidden)
        try await aEq((try await call(app1, .GET, api(w) + "/suggestions", token: member.token)).status, .ok)
        // Steuerberater: Vorschläge lesen, nicht entscheiden, keine Regeln
        try await aEq((try await call(app2, .GET, api(w) + "/suggestions", token: tax.token)).status, .ok)
        try await aEq((try await call(app2, .GET, api(w) + "/rules", token: tax.token)).status, .forbidden)
        try await aEq((try await call(app2, .POST, api(w) + "/suggestions/\(s)/accept", token: tax.token)).status, .forbidden)
        try await aEq((try await call(app2, .POST, api(w) + "/suggestions/\(s)/reject", token: tax.token)).status, .forbidden)
        // Kundensicht und anonym
        for path in ["/rules", "/suggestions", "/duplicates"] {
            try await aEq((try await call(app1, .GET, api(w) + path, token: viewer.token)).status, .forbidden, path)
            try await aEq((try await call(app1, .GET, api(w) + path)).status, .unauthorized, path)
        }
        try await aEq(try await scalar("SELECT state AS v FROM dms_suggestions WHERE id = '\(s)'", as: String.self), "open", "verbotene Entscheidung ändert nichts")
        // Mitglied darf entscheiden
        try await aEq((try await call(app1, .POST, api(w) + "/suggestions/\(s)/accept", token: member.token)).status, .ok)
        // Moduleschalter aus: 404
        try await setModule(w.tenantA, false, by: w.alice)
        try await aEq((try await call(app1, .GET, api(w) + "/rules", token: w.alice.token)).status, .notFound)
    }

    /// AK-D3-13: Migration `dms_020_rules`: eingetragen, `schema_version` unverändert, Revert und erneutes Anwenden.
    func testAKD3_13_MigrationRevertAndReapply() async throws {
        _ = try await world(enable: false)
        try await aEq(try await count("_fluent_migrations", where: "name = 'dms_020_rules'"), 1)
        try await aEq(try await scalar("SELECT max(version)::bigint AS v FROM schema_version", as: Int64.self), 17)
        try await aEq(try await count("information_schema.tables", where: "table_name IN ('dms_rules', 'dms_suggestions', 'dms_duplicates', 'dms_document_fingerprints', 'dms_text_shingles')"), 5)
        try await CreateDMSRules().revert(on: app1.db(.psql))
        try await aEq(try await count("information_schema.tables", where: "table_name IN ('dms_rules', 'dms_suggestions', 'dms_duplicates', 'dms_document_fingerprints', 'dms_text_shingles')"), 0)
        try await aEq(try await count("information_schema.columns", where: "table_name = 'dms_ingest_items' AND column_name = 'sender'"), 0)
        try await CreateDMSRules().prepare(on: app1.db(.psql))
        try await aEq(try await count("information_schema.columns", where: "table_name = 'dms_ingest_items' AND column_name = 'sender'"), 1)
    }
}
