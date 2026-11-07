import Vapor
import Fluent
import SQLKit

// WP-D3 Regeln: CRUD (Mandant, Audit, Versionszähler), Trockenlauf gegen vorhandene Dokumente. Der Trockenlauf liest nur (keine Zeile, kein Audit, kein Job).

struct DMSRuleOut: Content, Sendable {
    struct Stats: Content, Sendable { let suggested: Int; let open: Int; let accepted: Int; let rejected: Int; let automatic: Int }
    let id: UUID
    let name: String
    let priority: Int
    let enabled: Bool
    let mode: String
    let confidence: Double
    let conditions: RuleConditions
    let actions: RuleActions
    let version: Int
    let created_by: UUID?
    let created_at: String
    let updated_at: String
    let stats: Stats
}

struct DMSRulePreviewOut: Content, Sendable {
    struct Match: Content, Sendable { let type: String; let matched: String; let offset: Int?; let length: Int? }
    struct Suggestion: Content, Sendable { let kind: String; let value: [String: String]; let confidence: Double; let reason: String }
    struct Item: Content, Sendable {
        let document_id: UUID
        let title: String
        let matches: [Match]
        let suggestions: [Suggestion]
    }
    let rule_id: UUID?
    let mode: String
    let checked: Int
    let matched: Int
    let timed_out: Int
    /// `true`, wenn das Zeitbudget des Trockenlaufs vor dem Ende der Dokumente aufgebraucht war.
    let truncated: Bool
    let items: [Item]
}

enum DMSRules {
    static let selectColumns = """
        r.id, r.name, r.priority, r.enabled, r.mode, r.confidence::float8 AS confidence, r.conditions::text AS conditions, r.actions::text AS actions, r.version,
        r.created_by, r.created_at, r.updated_at,
        (SELECT count(*) FROM dms_suggestions s WHERE s.tenant_id = r.tenant_id AND s.rule_id = r.id) AS n_suggested,
        (SELECT count(*) FROM dms_suggestions s WHERE s.tenant_id = r.tenant_id AND s.rule_id = r.id AND s.state = 'open') AS n_open,
        (SELECT count(*) FROM dms_suggestions s WHERE s.tenant_id = r.tenant_id AND s.rule_id = r.id AND s.state = 'accepted') AS n_accepted,
        (SELECT count(*) FROM dms_suggestions s WHERE s.tenant_id = r.tenant_id AND s.rule_id = r.id AND s.state = 'rejected') AS n_rejected,
        (SELECT count(*) FROM dms_suggestions s WHERE s.tenant_id = r.tenant_id AND s.rule_id = r.id AND s.applied_automatically) AS n_auto
        """

    private static func decode<T: Decodable>(_ type: T.Type, _ text: String) throws -> T {
        try JSONDecoder().decode(type, from: Data(text.utf8))
    }

    private static func out(_ r: any SQLRow) throws -> DMSRuleOut {
        func n(_ c: String) throws -> Int { Int(try r.decode(column: c, as: Int64.self)) }
        return DMSRuleOut(
            id: try r.decode(column: "id", as: UUID.self), name: try r.decode(column: "name", as: String.self), priority: Int(try r.decode(column: "priority", as: Int32.self)),
            enabled: try r.decode(column: "enabled", as: Bool.self), mode: try r.decode(column: "mode", as: String.self), confidence: try r.decode(column: "confidence", as: Double.self),
            conditions: try decode(RuleConditions.self, try r.decode(column: "conditions", as: String.self)), actions: try decode(RuleActions.self, try r.decode(column: "actions", as: String.self)),
            version: Int(try r.decode(column: "version", as: Int32.self)), created_by: try r.decode(column: "created_by", as: UUID?.self),
            created_at: iso(try r.decode(column: "created_at", as: Date.self)), updated_at: iso(try r.decode(column: "updated_at", as: Date.self)),
            stats: .init(suggested: try n("n_suggested"), open: try n("n_open"), accepted: try n("n_accepted"), rejected: try n("n_rejected"), automatic: try n("n_auto")))
    }

    private static func json<T: Encodable>(_ v: T) throws -> String { String(decoding: try JSONEncoder().encode(v), as: UTF8.self) }

    // MARK: Lesen

    static func load(_ id: UUID, tenant: UUID, on s: any SQLDatabase) async throws -> DMSRuleOut? {
        guard let row = try await s.raw("SELECT \(unsafeRaw: selectColumns) FROM dms_rules r WHERE r.tenant_id = \(bind: tenant) AND r.id = \(bind: id) AND r.deleted_at IS NULL").first() else { return nil }
        return try out(row)
    }

    static func list(tenant: UUID, page: HubPageRequest, on db: any Database) async throws -> HubPage<DMSRuleOut> {
        let s = try sql(db)
        let cur = page.cursor
        let rows = try await s.raw("""
            SELECT \(unsafeRaw: selectColumns), r.created_at::text AS created_text FROM dms_rules r
            WHERE r.tenant_id = \(bind: tenant) AND r.deleted_at IS NULL
              AND (\(bind: cur?.createdAt)::text IS NULL OR (r.created_at, r.id) > (\(bind: cur?.createdAt)::timestamptz, \(bind: cur?.id)::uuid))
            ORDER BY r.created_at, r.id LIMIT \(bind: page.limit + 1)
            """).all()
        let items = try rows.map { (try out($0), try $0.decode(column: "created_text", as: String.self)) }
        var total: Int?
        if page.wantsCount {
            total = Int(try await s.raw("SELECT count(*)::bigint AS n FROM dms_rules WHERE tenant_id = \(bind: tenant) AND deleted_at IS NULL").first()?.decode(column: "n", as: Int64.self) ?? 0)
        }
        let created = Dictionary(uniqueKeysWithValues: items.map { ($0.0.id, $0.1) })
        return HubPage(fetched: items.map(\.0), limit: page.limit, cursorOf: { PageCursor(createdAt: created[$0.id] ?? "", id: $0.id) }, total: total)
    }

    /// Aktive Regeln in Auswertungsreihenfolge: Priorität absteigend, dann Anlage, dann ID (deterministisch).
    static func active(tenant: UUID, limit: Int, on s: any SQLDatabase) async throws -> [RuleDefinition] {
        try await s.raw("""
            SELECT id, name, priority, mode, confidence::float8 AS confidence, version, conditions::text AS conditions, actions::text AS actions FROM dms_rules
            WHERE tenant_id = \(bind: tenant) AND deleted_at IS NULL AND enabled ORDER BY priority DESC, created_at, id LIMIT \(bind: limit)
            """).all().map { try definition($0) }
    }

    private static func definition(_ r: any SQLRow) throws -> RuleDefinition {
        RuleDefinition(id: try r.decode(column: "id", as: UUID.self), name: try r.decode(column: "name", as: String.self), priority: Int(try r.decode(column: "priority", as: Int32.self)),
                       mode: try r.decode(column: "mode", as: String.self), confidence: try r.decode(column: "confidence", as: Double.self),
                       version: Int(try r.decode(column: "version", as: Int32.self)), conditions: try decode(RuleConditions.self, try r.decode(column: "conditions", as: String.self)),
                       actions: try decode(RuleActions.self, try r.decode(column: "actions", as: String.self)))
    }

    // MARK: Prüfung der Verweise

    /// Verweise der Aktionen müssen zum Mandanten gehören (fremd oder unbekannt: 422, keine Auskunft über andere Mandanten).
    static func requireRefs(_ a: RuleActions, tenant: UUID, on s: any SQLDatabase) async throws {
        if let id = a.document_type_id { try await DMSDocuments.requireRef("dms_document_types", id, tenant: tenant, field: "actions.document_type_id", on: s) }
        if let id = a.storage_path_id { try await DMSDocuments.requireRef("dms_storage_paths", id, tenant: tenant, field: "actions.storage_path_id", on: s) }
        for id in a.tag_ids ?? [] { try await DMSDocuments.requireRef("dms_tags", id, tenant: tenant, field: "actions.tag_ids", on: s) }
        if let id = a.correspondent_id, !(try await ContactService.exists(id, tenant: tenant, on: s)) { throw DMSError.invalid("actions.correspondent_id", "unknown") }
    }

    private static func normalized(_ c: RuleConditions) -> RuleConditions {
        RuleConditions(version: RuleConditions.currentVersion, match: c.isAny ? "any" : "all", conditions: c.conditions.map {
            RuleCondition(type: $0.type, value: $0.value?.trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCanonicalMapping, pattern: $0.pattern, case_sensitive: $0.case_sensitive)
        })
    }

    private static func normalized(_ a: RuleActions) -> RuleActions {
        var a = a
        if let tags = a.tag_ids { a.tag_ids = tags.isEmpty ? nil : Array(Set(tags)).sorted { $0.uuidString < $1.uuidString } }
        return a
    }

    // MARK: Anlegen, Ändern, Löschen

    static func create(tenant: UUID, actor: UUID, requestID: String, body: RuleInput, on db: any Database) async throws -> DMSRuleOut {
        let name = try RuleValidation.validate(name: body.name)
        let mode = try RuleValidation.validate(mode: body.mode), priority = try RuleValidation.validate(priority: body.priority), confidence = try RuleValidation.validate(confidence: body.confidence)
        guard let c = body.conditions else { throw DMSError.invalid("conditions", "required") }
        guard let a = body.actions else { throw DMSError.invalid("actions", "required") }
        try RuleValidation.validate(c); try RuleValidation.validate(a)
        let conditions = normalized(c), actions = normalized(a)
        let enabled = body.enabled ?? true
        return try await dmsTransaction(db) { _, s in
            try await requireRefs(actions, tenant: tenant, on: s)
            try await requireFreeName(name, tenant: tenant, except: nil, on: s)
            guard let row = try await s.raw("""
                INSERT INTO dms_rules (tenant_id, name, priority, enabled, mode, confidence, conditions, actions, created_by)
                VALUES (\(bind: tenant), \(bind: name), \(bind: priority), \(bind: enabled), \(bind: mode), \(bind: confidence), \(bind: try json(conditions))::text::jsonb,
                        \(bind: try json(actions))::text::jsonb, \(bind: actor)) RETURNING id
                """).first() else { throw Abort(.internalServerError) }
            let id = try row.decode(column: "id", as: UUID.self)
            try await AuditLog.record(AuditEvent(action: "dms.rule.created", actor: actor, tenant: tenant, subjectType: "dms.rule", subjectID: id.uuidString,
                                                 meta: ["mode": .safe(mode), "priority": .number(Int64(priority)), "enabled": .number(enabled ? 1 : 0)], requestID: requestID), on: s)
            guard let out = try await load(id, tenant: tenant, on: s) else { throw Abort(.internalServerError) }
            return out
        }
    }

    private static func requireFreeName(_ name: String, tenant: UUID, except: UUID?, on s: any SQLDatabase) async throws {
        if try await s.raw("""
            SELECT 1 AS x FROM dms_rules WHERE tenant_id = \(bind: tenant) AND lower(name) = lower(\(bind: name)) AND deleted_at IS NULL AND (\(bind: except)::uuid IS NULL OR id <> \(bind: except)::uuid)
            """).first() != nil { throw HubError(.conflict, "conflict", detail: "Eine Regel mit diesem Namen existiert bereits.") }
    }

    /// Ändert nur gesetzte Felder. Die Regelversion steigt, wenn sich Bedingungen, Aktionen, Modus oder Konfidenz ändern (Vorschläge nennen die Version).
    static func update(_ id: UUID, tenant: UUID, actor: UUID, requestID: String, body: RuleInput, on db: any Database) async throws -> DMSRuleOut {
        let name = try body.name.map { try RuleValidation.validate(name: $0) }
        let mode = try body.mode.map { try RuleValidation.validate(mode: $0) }
        let priority = try body.priority.map { try RuleValidation.validate(priority: $0) }
        let confidence = try body.confidence.map { try RuleValidation.validate(confidence: $0) }
        if let c = body.conditions { try RuleValidation.validate(c) }
        if let a = body.actions { try RuleValidation.validate(a) }
        let conditions = body.conditions.map(normalized), actions = body.actions.map(normalized)
        return try await dmsTransaction(db) { _, s in
            guard let cur = try await s.raw("SELECT mode, confidence::float8 AS confidence, conditions::text AS conditions, actions::text AS actions FROM dms_rules WHERE tenant_id = \(bind: tenant) AND id = \(bind: id) AND deleted_at IS NULL FOR UPDATE").first()
            else { throw DMSError.notFound }
            if let actions { try await requireRefs(actions, tenant: tenant, on: s) }
            if let name { try await requireFreeName(name, tenant: tenant, except: id, on: s) }
            let curConditions = try decode(RuleConditions.self, try cur.decode(column: "conditions", as: String.self))
            let curActions = try decode(RuleActions.self, try cur.decode(column: "actions", as: String.self))
            let curMode = try cur.decode(column: "mode", as: String.self), curConfidence = try cur.decode(column: "confidence", as: Double.self)
            let semantic = (conditions != nil && conditions != curConditions) || (actions != nil && actions != curActions)
                || (mode != nil && mode != curMode) || (confidence != nil && confidence != curConfidence)
            try await s.raw("""
                UPDATE dms_rules SET
                  name = COALESCE(\(bind: name)::text, name), priority = COALESCE(\(bind: priority)::integer, priority), enabled = COALESCE(\(bind: body.enabled)::boolean, enabled),
                  mode = COALESCE(\(bind: mode)::text, mode), confidence = COALESCE(\(bind: confidence)::numeric, confidence),
                  conditions = COALESCE(\(bind: try conditions.map(json))::text::jsonb, conditions), actions = COALESCE(\(bind: try actions.map(json))::text::jsonb, actions),
                  version = version + \(bind: semantic ? 1 : 0), updated_at = now()
                WHERE tenant_id = \(bind: tenant) AND id = \(bind: id)
                """).run()
            var meta: [String: AuditValue] = [:]
            for (key, set) in [("name", name != nil), ("priority", priority != nil), ("enabled", body.enabled != nil), ("mode", mode != nil), ("confidence", confidence != nil),
                               ("conditions", conditions != nil), ("actions", actions != nil)] where set { meta[key] = .number(1) }
            if let mode { meta["to_mode"] = .safe(mode) }
            try await AuditLog.record(AuditEvent(action: "dms.rule.updated", actor: actor, tenant: tenant, subjectType: "dms.rule", subjectID: id.uuidString, meta: meta, requestID: requestID), on: s)
            guard let out = try await load(id, tenant: tenant, on: s) else { throw DMSError.notFound }
            return out
        }
    }

    /// Weiches Löschen: die Zeile bleibt (Vorschläge verweisen auf sie), die Regel wird nicht mehr ausgewertet.
    static func delete(_ id: UUID, tenant: UUID, actor: UUID, requestID: String, on db: any Database) async throws {
        try await dmsTransaction(db) { _, s in
            guard try await s.raw("SELECT 1 AS x FROM dms_rules WHERE tenant_id = \(bind: tenant) AND id = \(bind: id) AND deleted_at IS NULL FOR UPDATE").first() != nil else { throw DMSError.notFound }
            try await s.raw("UPDATE dms_rules SET deleted_at = now(), enabled = false, updated_at = now() WHERE tenant_id = \(bind: tenant) AND id = \(bind: id)").run()
            try await AuditLog.record(AuditEvent(action: "dms.rule.deleted", actor: actor, tenant: tenant, subjectType: "dms.rule", subjectID: id.uuidString, requestID: requestID), on: s)
        }
    }

    // MARK: Trockenlauf

    static let previewDefaultLimit = 100, previewMaxLimit = 500, previewShown = 100
    static let previewBudget: TimeInterval = 20

    /// Prüft eine gespeicherte Regel (`id`) oder einen Entwurf (`draft`) gegen die jüngsten Dokumente des Mandanten (ohne Papierkorb). Liest nur.
    static func preview(rule id: UUID?, draft: RuleInput?, limit: Int?, tenant: UUID, on db: any Database) async throws -> DMSRulePreviewOut {
        let s = try sql(db)
        let rule: RuleDefinition
        if let id {
            guard let row = try await s.raw("""
                SELECT id, name, priority, mode, confidence::float8 AS confidence, version, conditions::text AS conditions, actions::text AS actions FROM dms_rules
                WHERE tenant_id = \(bind: tenant) AND id = \(bind: id) AND deleted_at IS NULL
                """).first() else { throw DMSError.notFound }
            rule = try definition(row)
        } else {
            guard let draft else { throw DMSError.invalid("conditions", "required") }
            guard let c = draft.conditions else { throw DMSError.invalid("conditions", "required") }
            guard let a = draft.actions else { throw DMSError.invalid("actions", "required") }
            try RuleValidation.validate(c); try RuleValidation.validate(a)
            try await requireRefs(a, tenant: tenant, on: s)
            rule = RuleDefinition(id: UUID(), name: draft.name ?? "Entwurf", priority: 0, mode: try RuleValidation.validate(mode: draft.mode), confidence: try RuleValidation.validate(confidence: draft.confidence),
                                  version: 1, conditions: normalized(c), actions: normalized(a))
        }
        let n = limit ?? previewDefaultLimit
        guard (1...previewMaxLimit).contains(n) else { throw DMSError.invalid("limit") }
        let rows = try await s.raw("""
            SELECT d.id, d.title, d.doc_date::text AS doc_date, d.document_type_id, d.storage_path_id,
              (SELECT l.to_id FROM links l WHERE l.tenant_id = d.tenant_id AND l.from_type = 'dms.document' AND l.from_id = d.id AND l.to_type = 'contact'
                 AND l.kind = 'correspondent' AND l.removed_at IS NULL ORDER BY l.created_at, l.id LIMIT 1) AS correspondent_id,
              COALESCE((SELECT array_agg(t.tag_id) FROM dms_document_tags t WHERE t.document_id = d.id), ARRAY[]::uuid[]) AS tag_ids,
              (SELECT left(x.text, 100000) FROM dms_document_texts x WHERE x.document_id = d.id ORDER BY x.version DESC LIMIT 1) AS text,
              (SELECT f.original_name FROM dms_document_files f WHERE f.document_id = d.id AND f.role = 'original') AS filename,
              COALESCE((SELECT i.source FROM dms_ingest_items i WHERE i.document_id = d.id ORDER BY i.created_at, i.id LIMIT 1), 'upload') AS source,
              (SELECT i.sender FROM dms_ingest_items i WHERE i.document_id = d.id ORDER BY i.created_at, i.id LIMIT 1) AS sender
            FROM dms_documents d WHERE d.tenant_id = \(bind: tenant) AND d.trashed_at IS NULL ORDER BY d.created_at DESC, d.id DESC LIMIT \(bind: n)
            """).all()
        let deadline = Date().addingTimeInterval(previewBudget)
        var items: [DMSRulePreviewOut.Item] = []
        var checked = 0, matched = 0, timedOut = 0
        var truncated = false
        for row in rows {
            if Date() > deadline { truncated = true; break }
            checked += 1
            let state = DocumentState(title: try row.decode(column: "title", as: String.self), docDate: try row.decode(column: "doc_date", as: String?.self),
                                      typeID: try row.decode(column: "document_type_id", as: UUID?.self), pathID: try row.decode(column: "storage_path_id", as: UUID?.self),
                                      correspondentID: try row.decode(column: "correspondent_id", as: UUID?.self), tagIDs: Set(try row.decode(column: "tag_ids", as: [UUID].self)))
            let context = RuleContext(text: try row.decode(column: "text", as: String?.self) ?? "", filename: try row.decode(column: "filename", as: String?.self),
                                      source: try row.decode(column: "source", as: String.self), sender: try row.decode(column: "sender", as: String?.self), current: state)
            switch DMSRuleEngine.evaluate(rule, context: context) {
            case .timedOut: timedOut += 1
            case .noMatch: break
            case .matched(let hits):
                matched += 1
                if items.count < previewShown {
                    let suggestions = DMSRuleEngine.candidates(for: rule, hits: hits, context: context)
                    items.append(.init(document_id: try row.decode(column: "id", as: UUID.self), title: state.title,
                                       matches: hits.map { .init(type: $0.type, matched: $0.matched, offset: $0.offset, length: $0.length) },
                                       suggestions: suggestions.map { .init(kind: $0.kind, value: $0.value, confidence: $0.confidence, reason: $0.reason) }))
                }
            }
        }
        return DMSRulePreviewOut(rule_id: id, mode: rule.mode, checked: checked, matched: matched, timed_out: timedOut, truncated: truncated, items: items)
    }
}
