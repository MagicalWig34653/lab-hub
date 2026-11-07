import Vapor
import Fluent
import SQLKit

// WP-D3 Vorschläge: Lesen, Annehmen, Ablehnen und das gemeinsame Anwenden (Annahme durch Nutzer oder `auto`-Regel).
// Grundsatz (F-25, MODUL-DMS 5.4): ein Vorschlag ändert nichts. Nur die Annahme (Nutzer, Audit `dms.suggestion.accepted`) oder eine Regel im Modus `auto`
// (Audit `dms.suggestion.auto_applied`) schreibt Metadaten.

struct DMSSuggestionOut: Content, Sendable {
    let id: UUID
    let document_id: UUID
    let document_title: String
    let kind: String
    let value: [String: String]
    let source: String
    let rule_id: UUID?
    let rule_version: Int?
    let confidence: Double
    let reason: String
    let evidence: [String: String]
    let state: String
    let applied_automatically: Bool
    let decided_by: UUID?
    let decided_at: String?
    let created_at: String
}

enum DMSSuggestions {
    static let staleCode = "suggestion_stale"
    static let decidedCode = "suggestion_decided"

    private static let columns = """
        s.id, s.document_id, d.title AS document_title, s.kind, s.value::text AS value, s.source, s.rule_id, s.rule_version, s.confidence::float8 AS confidence, s.reason,
        s.evidence::text AS evidence, s.state, s.applied_automatically, s.decided_by, s.decided_at, s.created_at
        """

    private static func strings(_ text: String) -> [String: String] {
        (try? JSONDecoder().decode([String: String].self, from: Data(text.utf8))) ?? [:]
    }

    private static func out(_ r: any SQLRow) throws -> DMSSuggestionOut {
        DMSSuggestionOut(
            id: try r.decode(column: "id", as: UUID.self), document_id: try r.decode(column: "document_id", as: UUID.self), document_title: try r.decode(column: "document_title", as: String.self),
            kind: try r.decode(column: "kind", as: String.self), value: strings(try r.decode(column: "value", as: String.self)), source: try r.decode(column: "source", as: String.self),
            rule_id: try r.decode(column: "rule_id", as: UUID?.self), rule_version: try r.decode(column: "rule_version", as: Int32?.self).map(Int.init),
            confidence: try r.decode(column: "confidence", as: Double.self), reason: try r.decode(column: "reason", as: String.self),
            evidence: strings(try r.decode(column: "evidence", as: String.self)), state: try r.decode(column: "state", as: String.self),
            applied_automatically: try r.decode(column: "applied_automatically", as: Bool.self), decided_by: try r.decode(column: "decided_by", as: UUID?.self),
            decided_at: try r.decode(column: "decided_at", as: Date?.self).map(iso), created_at: iso(try r.decode(column: "created_at", as: Date.self)))
    }

    struct Filter: Sendable {
        var state: String? = "open"      // nil = alle
        var kind: String?
        var document: UUID?
        var rule: UUID?
    }

    static let kinds: Set<String> = ["correspondent", "type", "tag", "date", "title", "path"]

    /// Liste für den Mandanten oder ein Dokument. Papierkorb-Dokumente erscheinen nicht. Reihenfolge: Dokument-bezogene Anzeige zuerst nach Konfidenz wäre nicht cursorfähig,
    /// daher `(created_at, id)`; die Oberfläche sortiert die Seite nach `confidence`.
    static func list(tenant: UUID, page: HubPageRequest, filter f: Filter, on db: any Database) async throws -> HubPage<DMSSuggestionOut> {
        let s = try sql(db)
        let cur = page.cursor
        let rows = try await s.raw("""
            SELECT \(unsafeRaw: columns), s.created_at::text AS created_text FROM dms_suggestions s
            JOIN dms_documents d ON d.id = s.document_id AND d.tenant_id = s.tenant_id
            WHERE s.tenant_id = \(bind: tenant) AND d.trashed_at IS NULL
              AND (\(bind: f.state)::text IS NULL OR s.state = \(bind: f.state)::text)
              AND (\(bind: f.kind)::text IS NULL OR s.kind = \(bind: f.kind)::text)
              AND (\(bind: f.document)::uuid IS NULL OR s.document_id = \(bind: f.document)::uuid)
              AND (\(bind: f.rule)::uuid IS NULL OR s.rule_id = \(bind: f.rule)::uuid)
              AND (\(bind: cur?.createdAt)::text IS NULL OR (s.created_at, s.id) > (\(bind: cur?.createdAt)::timestamptz, \(bind: cur?.id)::uuid))
            ORDER BY s.created_at, s.id LIMIT \(bind: page.limit + 1)
            """).all()
        let items = try rows.map { (try out($0), try $0.decode(column: "created_text", as: String.self)) }
        var total: Int?
        if page.wantsCount {
            total = Int(try await s.raw("""
                SELECT count(*)::bigint AS n FROM dms_suggestions s JOIN dms_documents d ON d.id = s.document_id AND d.tenant_id = s.tenant_id
                WHERE s.tenant_id = \(bind: tenant) AND d.trashed_at IS NULL AND (\(bind: f.state)::text IS NULL OR s.state = \(bind: f.state)::text)
                  AND (\(bind: f.kind)::text IS NULL OR s.kind = \(bind: f.kind)::text) AND (\(bind: f.document)::uuid IS NULL OR s.document_id = \(bind: f.document)::uuid)
                  AND (\(bind: f.rule)::uuid IS NULL OR s.rule_id = \(bind: f.rule)::uuid)
                """).first()?.decode(column: "n", as: Int64.self) ?? 0)
        }
        let created = Dictionary(uniqueKeysWithValues: items.map { ($0.0.id, $0.1) })
        return HubPage(fetched: items.map(\.0), limit: page.limit, cursorOf: { PageCursor(createdAt: created[$0.id] ?? "", id: $0.id) }, total: total)
    }

    static func load(_ id: UUID, tenant: UUID, on s: any SQLDatabase) async throws -> DMSSuggestionOut? {
        guard let row = try await s.raw("""
            SELECT \(unsafeRaw: columns) FROM dms_suggestions s JOIN dms_documents d ON d.id = s.document_id AND d.tenant_id = s.tenant_id
            WHERE s.tenant_id = \(bind: tenant) AND s.id = \(bind: id)
            """).first() else { return nil }
        return try out(row)
    }

    // MARK: Entscheiden

    /// Nimmt einen offenen Vorschlag an und schreibt die Änderung am Dokument (eine Transaktion, Audit). Bereits entschieden: 409 `suggestion_decided`;
    /// der Vorschlag passt nicht mehr (Ziel gelöscht, exklusive Tag-Gruppe belegt): 409 `suggestion_stale`; Dokument im Papierkorb: 409 `document_trashed`.
    static func accept(_ id: UUID, tenant: UUID, actor: UUID, requestID: String, on db: any Database) async throws -> DMSSuggestionOut {
        try await dmsTransaction(db) { tx, s in
            // Sperrreihenfolge wie beim Klassifizieren: erst das Dokument, dann der Vorschlag
            guard let pre = try await s.raw("SELECT document_id FROM dms_suggestions WHERE tenant_id = \(bind: tenant) AND id = \(bind: id)").first() else { throw DMSError.notFound }
            let document = try pre.decode(column: "document_id", as: UUID.self)
            guard let doc = try await s.raw("SELECT trashed_at FROM dms_documents WHERE tenant_id = \(bind: tenant) AND id = \(bind: document) FOR UPDATE").first() else { throw DMSError.notFound }
            guard let row = try await s.raw("""
                SELECT kind, value::text AS value, state, source FROM dms_suggestions WHERE tenant_id = \(bind: tenant) AND id = \(bind: id) FOR UPDATE
                """).first() else { throw DMSError.notFound }
            guard try row.decode(column: "state", as: String.self) == "open" else { throw HubError(.conflict, decidedCode) }
            if try doc.decode(column: "trashed_at", as: Date?.self) != nil { throw DMSError.trashed }
            let kind = try row.decode(column: "kind", as: String.self)
            let value = strings(try row.decode(column: "value", as: String.self))
            try await apply(kind: kind, value: value, document: document, tenant: tenant, actor: actor, linkSource: "manual", tagSource: "suggestion", requestID: requestID, db: tx, s: s)
            try await s.raw("""
                UPDATE dms_suggestions SET state = 'accepted', decided_by = \(bind: actor), decided_at = now() WHERE tenant_id = \(bind: tenant) AND id = \(bind: id)
                """).run()
            try await AuditLog.record(AuditEvent(action: "dms.suggestion.accepted", actor: actor, tenant: tenant, subjectType: "dms.suggestion", subjectID: id.uuidString,
                                                 meta: ["kind": .safe(kind), "source": .safe(try row.decode(column: "source", as: String.self))], requestID: requestID), on: s)
            guard let out = try await load(id, tenant: tenant, on: s) else { throw DMSError.notFound }
            return out
        }
    }

    static func reject(_ id: UUID, tenant: UUID, actor: UUID, requestID: String, on db: any Database) async throws -> DMSSuggestionOut {
        try await dmsTransaction(db) { _, s in
            guard let row = try await s.raw("SELECT kind, state FROM dms_suggestions WHERE tenant_id = \(bind: tenant) AND id = \(bind: id) FOR UPDATE").first() else { throw DMSError.notFound }
            guard try row.decode(column: "state", as: String.self) == "open" else { throw HubError(.conflict, decidedCode) }
            try await s.raw("UPDATE dms_suggestions SET state = 'rejected', decided_by = \(bind: actor), decided_at = now() WHERE tenant_id = \(bind: tenant) AND id = \(bind: id)").run()
            try await AuditLog.record(AuditEvent(action: "dms.suggestion.rejected", actor: actor, tenant: tenant, subjectType: "dms.suggestion", subjectID: id.uuidString,
                                                 meta: ["kind": .safe(try row.decode(column: "kind", as: String.self))], requestID: requestID), on: s)
            guard let out = try await load(id, tenant: tenant, on: s) else { throw DMSError.notFound }
            return out
        }
    }

    // MARK: Anwenden

    /// `true`, wenn der Tag in einer exklusiven Gruppe liegt und das Dokument dort schon einen anderen Tag trägt.
    static func tagConflicts(_ tag: UUID, document: UUID, tenant: UUID, on s: any SQLDatabase) async throws -> Bool {
        try await s.raw("""
            SELECT 1 AS x FROM dms_tags t JOIN dms_tag_groups g ON g.id = t.group_id AND g.tenant_id = t.tenant_id AND g.exclusive
            JOIN dms_tags o ON o.group_id = t.group_id AND o.tenant_id = t.tenant_id AND o.id <> t.id
            JOIN dms_document_tags dt ON dt.tag_id = o.id AND dt.tenant_id = t.tenant_id AND dt.document_id = \(bind: document)
            WHERE t.tenant_id = \(bind: tenant) AND t.id = \(bind: tag) LIMIT 1
            """).first() != nil
    }

    /// Schreibt den Vorschlagswert ans Dokument (Aufrufer hält die Zeilensperre des Dokuments). Prüft die Ziele erneut gegen den Mandanten.
    static func apply(kind: String, value: [String: String], document: UUID, tenant: UUID, actor: UUID, linkSource: String, tagSource: String, requestID: String,
                      db: any Database, s: any SQLDatabase) async throws {
        let stale = HubError(.conflict, staleCode)
        func ref(_ key: String) throws -> UUID { guard let raw = value[key], let id = UUID(uuidString: raw) else { throw stale }; return id }
        func exists(_ table: String, _ id: UUID) async throws -> Bool {
            try await s.raw("SELECT 1 AS x FROM \(unsafeRaw: table) WHERE tenant_id = \(bind: tenant) AND id = \(bind: id)").first() != nil
        }
        switch kind {
        case "correspondent":
            let contact = try ref("contact_id")
            guard try await ContactService.exists(contact, tenant: tenant, on: s) else { throw stale }
            let current = try await LinkService.list(tenant: tenant, type: "dms.document", id: document, includeRemoved: false, on: db)
                .filter { $0.from_type == "dms.document" && $0.to_type == "contact" && $0.kind == DMSDocuments.correspondentKind }
            if !(current.count == 1 && current[0].to_id == contact) {
                for link in current { try await LinkService.remove(link.id, tenant: tenant, actor: actor, requestID: requestID, on: db) }
                _ = try await LinkService.create(tenant: tenant, actor: actor, body: LinkBody(from_type: "dms.document", from_id: document, to_type: "contact", to_id: contact,
                                                                                              kind: DMSDocuments.correspondentKind, source: linkSource), requestID: requestID, on: db)
            }
        case "type":
            let id = try ref("document_type_id")
            guard try await exists("dms_document_types", id) else { throw stale }
            try await s.raw("UPDATE dms_documents SET document_type_id = \(bind: id) WHERE tenant_id = \(bind: tenant) AND id = \(bind: document)").run()
        case "path":
            let id = try ref("storage_path_id")
            guard try await exists("dms_storage_paths", id) else { throw stale }
            try await s.raw("UPDATE dms_documents SET storage_path_id = \(bind: id) WHERE tenant_id = \(bind: tenant) AND id = \(bind: document)").run()
        case "date":
            guard let raw = value["doc_date"], let date = try? DMSError.date(raw, "doc_date") else { throw stale }
            try await s.raw("UPDATE dms_documents SET doc_date = \(bind: date)::text::date WHERE tenant_id = \(bind: tenant) AND id = \(bind: document)").run()
        case "title":
            guard let raw = value["title"], let title = try? DMSError.title(raw) else { throw stale }
            try await s.raw("UPDATE dms_documents SET title = \(bind: title) WHERE tenant_id = \(bind: tenant) AND id = \(bind: document)").run()
        case "tag":
            let id = try ref("tag_id")
            guard try await exists("dms_tags", id), !(try await tagConflicts(id, document: document, tenant: tenant, on: s)) else { throw stale }
            try await s.raw("""
                INSERT INTO dms_document_tags (tenant_id, document_id, tag_id, source, assigned_by) VALUES (\(bind: tenant), \(bind: document), \(bind: id), \(bind: tagSource), \(bind: actor))
                ON CONFLICT DO NOTHING
                """).run()
        default:
            throw stale
        }
        try await s.raw("UPDATE dms_documents SET rev = rev + 1, updated_at = now() WHERE tenant_id = \(bind: tenant) AND id = \(bind: document)").run()
    }
}
