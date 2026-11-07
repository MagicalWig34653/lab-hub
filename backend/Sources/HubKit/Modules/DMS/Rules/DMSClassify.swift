import Vapor
import Fluent
import SQLKit

// WP-D3 Ingest-Schritt „Klassifikation“ (zwischen ocr_done und classified, MODUL-DMS 4 und 5.4). Läuft in der Transaktion des OCR-Handlers unter der Zeilensperre des
// Ingest-Items: ein Ergebnis je Item, auch mit zwei Workern. Zusätzlich verhindert der Unique-Index auf `dms_suggestions` jede Doppelanlage (ON CONFLICT DO NOTHING).
// Deterministisch: Regeln nach (Priorität absteigend, Anlage, ID), Kandidaten in fester Reihenfolge, keine Uhr, kein Zufall.
// Nichts wird still angewendet: Vorschläge sind `open`. Ausnahme: Regel im Modus `auto` (F-25), nur für leere Einzelwerte (Korrespondent, Typ, Pfad, Datum, Titel = Standardtitel)
// und für zusätzliche Tags; die höchste Priorität gewinnt, jede Anwendung steht im Audit (`dms.suggestion.auto_applied`).

enum DMSClassify {
    static let maxRules = 200

    struct Outcome: Sendable, Equatable {
        var rulesMatched = 0
        var suggestions = 0
        var automatic = 0
        var timeouts = 0
        var duplicates = 0
    }

    private struct Row {
        var state: DocumentState
        var trashed: Bool
        var createdBy: UUID?
        var filename: String?
        var source: String
        var sender: String?
    }

    private static func load(item: UUID, document: UUID, tenant: UUID, on s: any SQLDatabase) async throws -> Row? {
        guard let d = try await s.raw("""
            SELECT d.title, d.doc_date::text AS doc_date, d.document_type_id, d.storage_path_id, d.trashed_at, d.created_by,
              (SELECT l.to_id FROM links l WHERE l.tenant_id = d.tenant_id AND l.from_type = 'dms.document' AND l.from_id = d.id AND l.to_type = 'contact'
                 AND l.kind = 'correspondent' AND l.removed_at IS NULL ORDER BY l.created_at, l.id LIMIT 1) AS correspondent_id,
              COALESCE((SELECT array_agg(t.tag_id) FROM dms_document_tags t WHERE t.document_id = d.id), ARRAY[]::uuid[]) AS tag_ids,
              (SELECT f.original_name FROM dms_document_files f WHERE f.document_id = d.id AND f.role = 'original') AS filename
            FROM dms_documents d WHERE d.tenant_id = \(bind: tenant) AND d.id = \(bind: document) FOR UPDATE
            """).first() else { return nil }
        let i = try await s.raw("SELECT source, sender FROM dms_ingest_items WHERE tenant_id = \(bind: tenant) AND id = \(bind: item)").first()
        return Row(state: DocumentState(title: try d.decode(column: "title", as: String.self), docDate: try d.decode(column: "doc_date", as: String?.self),
                                        typeID: try d.decode(column: "document_type_id", as: UUID?.self), pathID: try d.decode(column: "storage_path_id", as: UUID?.self),
                                        correspondentID: try d.decode(column: "correspondent_id", as: UUID?.self), tagIDs: Set(try d.decode(column: "tag_ids", as: [UUID].self))),
                   trashed: try d.decode(column: "trashed_at", as: Date?.self) != nil, createdBy: try d.decode(column: "created_by", as: UUID?.self),
                   filename: try d.decode(column: "filename", as: String?.self), source: try i?.decode(column: "source", as: String.self) ?? "upload",
                   sender: try i?.decode(column: "sender", as: String?.self))
    }

    /// Ziele, die es im Mandanten noch gibt (Regeln können auf inzwischen gelöschte Typen/Tags/Pfade zeigen): solche Kandidaten entfallen.
    private static func stillValid(_ candidates: [SuggestionCandidate], tenant: UUID, on s: any SQLDatabase) async throws -> [SuggestionCandidate] {
        var out: [SuggestionCandidate] = []
        var cache: [String: Bool] = [:]
        for c in candidates {
            let table: String?, key: String
            switch c.kind {
            case "type": table = "dms_document_types"; key = "document_type_id"
            case "path": table = "dms_storage_paths"; key = "storage_path_id"
            case "tag": table = "dms_tags"; key = "tag_id"
            case "correspondent": table = nil; key = "contact_id"
            default: out.append(c); continue
            }
            guard let raw = c.value[key], let id = UUID(uuidString: raw) else { continue }
            let cacheKey = c.kind + ":" + raw
            if cache[cacheKey] == nil {
                if let table { cache[cacheKey] = try await s.raw("SELECT 1 AS x FROM \(unsafeRaw: table) WHERE tenant_id = \(bind: tenant) AND id = \(bind: id)").first() != nil }
                else { cache[cacheKey] = try await ContactService.exists(id, tenant: tenant, on: s) }
            }
            if cache[cacheKey] == true { out.append(c) }
        }
        return out
    }

    /// Titel gilt als „leer“ (nur dann überschreibt `auto`), wenn er dem Standardtitel aus dem Upload entspricht.
    private static func titleIsDefault(_ title: String, filename: String?) -> Bool {
        title == "Dokument" || title == DMSRuleEngine.stem(filename).map { String($0.prefix(300)) }
    }

    /// Führt Regeln und Kontakt-Matching aus, speichert die Vorschläge, wendet `auto`-Regeln an, sucht Duplikate (Stufe 2). In der Transaktion des Aufrufers.
    @discardableResult
    static func run(item: UUID, document: UUID, tenant: UUID, text: String, requestID: String? = nil, on db: any Database) async throws -> Outcome {
        let s = try sql(db)
        var outcome = Outcome()
        guard let row = try await load(item: item, document: document, tenant: tenant, on: s) else { throw DMSError.notFound }
        let context = RuleContext(text: text, filename: row.filename, source: row.source, sender: row.sender, current: row.state)

        // 1. Regeln (deterministisch)
        var candidates: [SuggestionCandidate] = []
        for rule in try await DMSRules.active(tenant: tenant, limit: maxRules, on: s) {
            switch DMSRuleEngine.evaluate(rule, context: context) {
            case .noMatch: continue
            case .timedOut: outcome.timeouts += 1
            case .matched(let hits):
                outcome.rulesMatched += 1
                candidates += DMSRuleEngine.candidates(for: rule, hits: hits, context: context)
            }
        }
        // 2. Kontakt-Matching (nur wenn noch kein Korrespondent gesetzt ist)
        if row.state.correspondentID == nil {
            let keys = try await ContactService.matchKeys(tenant: tenant, on: s)
            candidates += DMSContactMatch.suggestions(keys: keys, text: text, currentCorrespondent: row.state.correspondentID)
        }
        candidates = try await stillValid(candidates, tenant: tenant, on: s)

        // 3. Speichern (und `auto` anwenden). `state` wird mitgeführt, damit die zweite auto-Regel nichts Gewonnenes überschreibt.
        var state = row.state
        for c in candidates {
            var apply = false
            if c.automatic, !row.trashed, row.createdBy != nil {
                switch c.kind {
                case "correspondent": apply = state.correspondentID == nil
                case "type": apply = state.typeID == nil
                case "path": apply = state.pathID == nil
                case "date": apply = state.docDate == nil
                case "title": apply = titleIsDefault(state.title, filename: row.filename)
                case "tag":
                    if let t = UUID(uuidString: c.value["tag_id"] ?? "") { apply = !(try await DMSSuggestions.tagConflicts(t, document: document, tenant: tenant, on: s)) }
                default: apply = false
                }
            }
            guard let inserted = try await s.raw("""
                INSERT INTO dms_suggestions (tenant_id, document_id, ingest_item_id, kind, value, value_key, source, rule_id, rule_version, confidence, reason, evidence,
                                             state, applied_automatically, decided_at)
                VALUES (\(bind: tenant), \(bind: document), \(bind: item), \(bind: c.kind), \(bind: c.valueJSON)::text::jsonb, \(bind: c.valueKey), \(bind: c.source), \(bind: c.ruleID),
                        \(bind: c.ruleVersion), \(bind: c.confidence), \(bind: c.reason), \(bind: c.evidenceJSON)::text::jsonb,
                        CASE WHEN \(bind: apply) THEN 'accepted' ELSE 'open' END, \(bind: apply), CASE WHEN \(bind: apply) THEN now() ELSE NULL END)
                ON CONFLICT DO NOTHING RETURNING id
                """).first() else { continue }   // gibt es schon (Wiederholung, zweiter Lauf): nichts doppelt, nichts erneut angewendet
            outcome.suggestions += 1
            guard apply, let actor = row.createdBy else { continue }
            // Alles, was scheitern könnte (Ziel gelöscht, exklusive Tag-Gruppe), ist oben geprüft: ein Fehler hier würde die Transaktion abbrechen.
            try await DMSSuggestions.apply(kind: c.kind, value: c.value, document: document, tenant: tenant, actor: actor, linkSource: "rule", tagSource: "rule",
                                           requestID: requestID ?? "ingest", db: db, s: s)
            let id = try inserted.decode(column: "id", as: UUID.self)
            outcome.automatic += 1
            switch c.kind {
            case "correspondent": state.correspondentID = UUID(uuidString: c.value["contact_id"] ?? "")
            case "type": state.typeID = UUID(uuidString: c.value["document_type_id"] ?? "")
            case "path": state.pathID = UUID(uuidString: c.value["storage_path_id"] ?? "")
            case "date": state.docDate = c.value["doc_date"]
            case "title": state.title = c.value["title"] ?? state.title
            case "tag": if let t = UUID(uuidString: c.value["tag_id"] ?? "") { state.tagIDs.insert(t) }
            default: break
            }
            try await AuditLog.record(AuditEvent(action: "dms.suggestion.auto_applied", actor: nil, tenant: tenant, subjectType: "dms.suggestion", subjectID: id.uuidString,
                                                 meta: ["kind": .safe(c.kind), "rule_version": .number(Int64(c.ruleVersion ?? 0))], requestID: requestID), on: s)
        }

        // 4. Duplikate Stufe 2 (Text)
        outcome.duplicates = try await DMSDuplicates.detectText(document: document, tenant: tenant, text: text, on: s)

        try await AuditLog.record(AuditEvent(action: "dms.ingest.classified", actor: nil, tenant: tenant, subjectType: "dms.ingest_item", subjectID: item.uuidString,
                                             meta: ["rules_matched": .number(Int64(outcome.rulesMatched)), "suggestions": .number(Int64(outcome.suggestions)),
                                                    "auto": .number(Int64(outcome.automatic)), "regex_timeouts": .number(Int64(outcome.timeouts)),
                                                    "duplicates": .number(Int64(outcome.duplicates))], requestID: requestID), on: s)
        return outcome
    }
}
