import Vapor
import Fluent
import SQLKit

// WP-D2: Dokumente (Anlegen aus Upload, Lesen, Ändern, ASN-Vergabe, Papierkorb). Alles mandantengefiltert, jede Änderung in einer Transaktion mit Audit.
// Korrespondent = Kern-`links` (from dms.document, to contact, kind correspondent): Kontakt-Merge (K5) schreibt Verweise automatisch um.

/// Transaktion, die sowohl Fluent-`Database` (für Kerndienste) als auch SQL-Zugriff bereitstellt. Verschachtelte Transaktionen laufen in derselben Verbindung.
func dmsTransaction<T: Sendable>(_ db: any Database, _ body: @escaping @Sendable (any Database, any SQLDatabase) async throws -> T) async throws -> T {
    try await db.transaction { tx in try await body(tx, try sql(tx)) }
}

enum DMSDocuments {
    static let asnKey = CounterKey(space: "dms", name: "asn")
    static let correspondentKind = "correspondent"

    private static let columns = """
        d.id, d.title, d.doc_date::text AS doc_date, d.received_at, d.document_type_id, d.storage_path_id,
        (SELECT l.to_id FROM links l WHERE l.tenant_id = d.tenant_id AND l.from_type = 'dms.document' AND l.from_id = d.id AND l.to_type = 'contact'
           AND l.kind = 'correspondent' AND l.removed_at IS NULL ORDER BY l.created_at, l.id LIMIT 1) AS correspondent_id,
        d.asn, d.status, d.trashed_at, d.trash_reason, d.created_by, d.created_at, d.updated_at, d.rev
        """

    private static func summary(_ r: any SQLRow) throws -> DMSDocumentOut {
        DMSDocumentOut(
            id: try r.decode(column: "id", as: UUID.self), title: try r.decode(column: "title", as: String.self),
            doc_date: try r.decode(column: "doc_date", as: String?.self), received_at: iso(try r.decode(column: "received_at", as: Date.self)),
            document_type_id: try r.decode(column: "document_type_id", as: UUID?.self), storage_path_id: try r.decode(column: "storage_path_id", as: UUID?.self),
            correspondent_id: try r.decode(column: "correspondent_id", as: UUID?.self), asn: try r.decode(column: "asn", as: Int64?.self),
            status: try r.decode(column: "status", as: String.self), trashed_at: try r.decode(column: "trashed_at", as: Date?.self).map(iso),
            trash_reason: try r.decode(column: "trash_reason", as: String?.self), created_by: try r.decode(column: "created_by", as: UUID?.self),
            created_at: iso(try r.decode(column: "created_at", as: Date.self)), updated_at: iso(try r.decode(column: "updated_at", as: Date.self)),
            rev: Int(try r.decode(column: "rev", as: Int32.self)))
    }

    // MARK: Lesen

    /// Einzelansicht mit Tags, Feldern und Dateien. Fremde oder unbekannte ID: nil (Aufrufer antwortet 404).
    static func load(_ id: UUID, tenant: UUID, on s: any SQLDatabase) async throws -> DMSDocumentOut? {
        guard let row = try await s.raw("SELECT \(unsafeRaw: columns) FROM dms_documents d WHERE d.tenant_id = \(bind: tenant) AND d.id = \(bind: id)").first() else { return nil }
        var out = try summary(row)
        out.tag_ids = try await s.raw("SELECT tag_id FROM dms_document_tags WHERE tenant_id = \(bind: tenant) AND document_id = \(bind: id) ORDER BY tag_id").all()
            .map { try $0.decode(column: "tag_id", as: UUID.self) }
        var fields: [String: DMSFieldValue] = [:]
        for r in try await s.raw("""
            SELECT f.code, f.data_type, v.value_text, v.value_numeric::text AS value_numeric, v.value_date::text AS value_date, v.value_bool
            FROM dms_document_fields v JOIN dms_custom_fields f ON f.id = v.field_id AND f.tenant_id = v.tenant_id
            WHERE v.tenant_id = \(bind: tenant) AND v.document_id = \(bind: id)
            """).all() {
            let code = try r.decode(column: "code", as: String.self)
            switch try r.decode(column: "data_type", as: String.self) {
            case "int": fields[code] = .int(Int64(try r.decode(column: "value_numeric", as: String?.self) ?? "0") ?? 0)
            case "decimal": fields[code] = .string(try r.decode(column: "value_numeric", as: String?.self) ?? "")
            case "date": fields[code] = .string(try r.decode(column: "value_date", as: String?.self) ?? "")
            case "bool": fields[code] = .bool(try r.decode(column: "value_bool", as: Bool?.self) ?? false)
            default: fields[code] = .string(try r.decode(column: "value_text", as: String?.self) ?? "")
            }
        }
        out.fields = fields
        out.files = try await s.raw("""
            SELECT role, mime, size_bytes, sha256, page_count, original_name FROM dms_document_files
            WHERE tenant_id = \(bind: tenant) AND document_id = \(bind: id) ORDER BY created_at, id
            """).all().map {
            DMSFileOut(role: try $0.decode(column: "role", as: String.self), mime: try $0.decode(column: "mime", as: String.self),
                       size_bytes: try $0.decode(column: "size_bytes", as: Int64.self), sha256: try $0.decode(column: "sha256", as: String.self),
                       page_count: try $0.decode(column: "page_count", as: Int32?.self).map(Int.init), original_name: try $0.decode(column: "original_name", as: String?.self))
        }
        return out
    }

    struct Filter: Sendable {
        var trashed = false
        var status: String?
        var typeID: UUID?
        var tagID: UUID?
        var correspondentID: UUID?
        var asn: Int64?
        var q: String?
    }

    static func list(tenant: UUID, page: HubPageRequest, filter f: Filter, on db: any Database) async throws -> HubPage<DMSDocumentOut> {
        let s = try sql(db)
        let pattern = f.q.flatMap { $0.isEmpty ? nil : "%" + $0.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_") + "%" }
        let cur = page.cursor
        let rows = try await s.raw("""
            SELECT \(unsafeRaw: columns), d.created_at::text AS created_text FROM dms_documents d
            WHERE d.tenant_id = \(bind: tenant) AND (d.trashed_at IS NOT NULL) = \(bind: f.trashed)
              AND (\(bind: f.status)::text IS NULL OR d.status = \(bind: f.status)::text)
              AND (\(bind: f.typeID)::uuid IS NULL OR d.document_type_id = \(bind: f.typeID)::uuid)
              AND (\(bind: f.asn)::bigint IS NULL OR d.asn = \(bind: f.asn)::bigint)
              AND (\(bind: f.tagID)::uuid IS NULL OR EXISTS (SELECT 1 FROM dms_document_tags t WHERE t.document_id = d.id AND t.tag_id = \(bind: f.tagID)::uuid))
              AND (\(bind: f.correspondentID)::uuid IS NULL OR EXISTS (SELECT 1 FROM links l WHERE l.tenant_id = d.tenant_id AND l.from_type = 'dms.document'
                    AND l.from_id = d.id AND l.to_type = 'contact' AND l.kind = 'correspondent' AND l.removed_at IS NULL AND l.to_id = \(bind: f.correspondentID)::uuid))
              AND (\(bind: pattern)::text IS NULL OR d.title ILIKE \(bind: pattern)::text)
              AND (\(bind: cur?.createdAt)::text IS NULL OR (d.created_at, d.id) > (\(bind: cur?.createdAt)::timestamptz, \(bind: cur?.id)::uuid))
            ORDER BY d.created_at, d.id LIMIT \(bind: page.limit + 1)
            """).all()
        let items = try rows.map { (try summary($0), try $0.decode(column: "created_text", as: String.self)) }
        var total: Int?
        if page.wantsCount {
            total = Int(try await s.raw("SELECT count(*)::bigint AS n FROM dms_documents WHERE tenant_id = \(bind: tenant) AND (trashed_at IS NOT NULL) = \(bind: f.trashed)")
                .first()?.decode(column: "n", as: Int64.self) ?? 0)
        }
        let created = Dictionary(uniqueKeysWithValues: items.map { ($0.0.id, $0.1) })
        return HubPage(fetched: items.map(\.0), limit: page.limit, cursorOf: { PageCursor(createdAt: created[$0.id] ?? "", id: $0.id) }, total: total)
    }

    // MARK: Anlegen aus Upload

    struct NewDocument: Sendable {
        let title: String
        let docDate: String?
        let typeID: UUID?
        let originalName: String?
        let archive: Bool
        let kind: DMSFileKind
        let stored: StoredObject
        let fileID: UUID
        /// WP-O2: Priorität des OCR-Jobs; nil = kein OCR-Job (Modul ohne Worker-Anbindung, z. B. in Tests).
        var ocrPriority: Int? = nil
    }

    /// Dokument mit Original in einer Transaktion. Gleiches Original im Mandanten: Hinweis `duplicates`, kein Abbruch.
    /// Mit `archive` wird die ASN in derselben Transaktion vergeben (Rollback gibt die Nummer zurück).
    static func create(tenant: UUID, actor: UUID, requestID: String, doc n: NewDocument, on db: any Database) async throws -> DMSDocumentOut {
        try await dmsTransaction(db) { _, s in
            if let typeID = n.typeID { try await requireRef("dms_document_types", typeID, tenant: tenant, field: "document_type_id", on: s) }
            let duplicates = try await s.raw("""
                SELECT document_id FROM dms_document_files WHERE tenant_id = \(bind: tenant) AND sha256 = \(bind: n.stored.key.sha256) AND role = 'original'
                ORDER BY created_at, id LIMIT 20
                """).all().map { try $0.decode(column: "document_id", as: UUID.self) }
            guard let row = try await s.raw("""
                INSERT INTO dms_documents (tenant_id, title, doc_date, document_type_id, created_by)
                VALUES (\(bind: tenant), \(bind: n.title), \(bind: n.docDate)::text::date, \(bind: n.typeID), \(bind: actor)) RETURNING id
                """).first() else { throw Abort(.internalServerError) }
            let id = try row.decode(column: "id", as: UUID.self)
            try await s.raw("""
                INSERT INTO dms_document_files (tenant_id, document_id, role, file_id, mime, size_bytes, sha256, original_name)
                VALUES (\(bind: tenant), \(bind: id), 'original', \(bind: n.fileID), \(bind: n.kind.mime), \(bind: n.stored.size), \(bind: n.stored.key.sha256), \(bind: n.originalName))
                """).run()
            var asn: Int64?
            // WP-O1: Eingangsvorgang; Upload hat Speichern und Hash synchron erledigt, weitere Schritte (OCR usw.) führen Worker aus.
            let ingestID = try await DMSIngest.create(tenant: tenant, document: id, source: .upload, actor: actor, upTo: .hashed, on: s)
            try await AuditLog.record(AuditEvent(action: "dms.ingest.received", actor: actor, tenant: tenant, subjectType: "dms.ingest_item", subjectID: ingestID.uuidString,
                                                 meta: ["source": .safe("upload")], requestID: requestID), on: s)
            if let priority = n.ocrPriority { try await DMSOCR.enqueue(item: ingestID, tenant: tenant, priority: priority, on: s) }
            if n.archive { asn = try await assignASN(id, tenant: tenant, actor: actor, requestID: requestID, on: s) }
            try await AuditLog.record(AuditEvent(action: "dms.document.created", actor: actor, tenant: tenant, subjectType: "dms.document", subjectID: id.uuidString,
                                                 meta: ["kind": .safe(n.kind.rawValue), "size": .number(n.stored.size), "duplicates": .number(Int64(duplicates.count)),
                                                        "archived": .number(asn == nil ? 0 : 1)], requestID: requestID), on: s)
            guard var out = try await load(id, tenant: tenant, on: s) else { throw Abort(.internalServerError) }
            out.duplicates = duplicates
            out.ingest_item_id = ingestID
            return out
        }
    }

    /// Verweis auf eine Stammdatenzeile des Mandanten; fremd oder unbekannt: 422 (keine Auskunft über andere Mandanten).
    static func requireRef(_ table: String, _ id: UUID, tenant: UUID, field: String, on s: any SQLDatabase) async throws {
        guard try await s.raw("SELECT 1 AS x FROM \(unsafeRaw: table) WHERE tenant_id = \(bind: tenant) AND id = \(bind: id)").first() != nil
        else { throw DMSError.invalid(field, "unknown") }
    }

    // MARK: ASN (AK-D7)

    /// Vergibt die Archivnummer atomar: Zeilensperre auf dem Dokument, dann Zähler `dms:asn` in derselben Transaktion (Rollback macht die Nummer wieder frei).
    /// Idempotent: eine vorhandene ASN bleibt. Reihenfolge der Sperren immer Dokument, dann Zähler.
    @discardableResult
    static func assignASN(_ id: UUID, tenant: UUID, actor: UUID, requestID: String, on s: any SQLDatabase) async throws -> Int64 {
        guard let row = try await s.raw("SELECT asn, trashed_at FROM dms_documents WHERE tenant_id = \(bind: tenant) AND id = \(bind: id) FOR UPDATE").first()
        else { throw DMSError.notFound }
        if try row.decode(column: "trashed_at", as: Date?.self) != nil { throw DMSError.trashed }
        if let existing = try row.decode(column: "asn", as: Int64?.self) { return existing }
        let asn = try await CounterService(s).next(tenant: tenant, key: asnKey, on: s)
        try await s.raw("""
            UPDATE dms_documents SET asn = \(bind: asn), status = 'archived', rev = rev + 1, updated_at = now() WHERE tenant_id = \(bind: tenant) AND id = \(bind: id)
            """).run()
        try await AuditLog.record(AuditEvent(action: "dms.document.archived", actor: actor, tenant: tenant, subjectType: "dms.document", subjectID: id.uuidString,
                                             meta: ["asn": .number(asn)], requestID: requestID), on: s)
        return asn
    }

    static func archive(_ id: UUID, tenant: UUID, actor: UUID, requestID: String, on db: any Database) async throws -> DMSDocumentOut {
        try await dmsTransaction(db) { _, s in
            try await assignASN(id, tenant: tenant, actor: actor, requestID: requestID, on: s)
            guard let out = try await load(id, tenant: tenant, on: s) else { throw DMSError.notFound }
            return out
        }
    }

    // MARK: Ändern

    static func patch(_ id: UUID, tenant: UUID, actor: UUID, requestID: String, body: DMSDocumentPatch, ifMatch: Int?, on db: any Database) async throws -> DMSDocumentOut {
        // Eingaben vor der Transaktion prüfen, die nur ohne Datenbank prüfbar sind
        let present = body.present
        let title: String? = present.contains("title") ? try DMSError.title(body.title) : nil
        let docDate: String? = present.contains("doc_date") ? try body.doc_date.map { try DMSError.date($0, "doc_date") } : nil
        return try await dmsTransaction(db) { tx, s in
            guard let row = try await s.raw("SELECT rev, trashed_at FROM dms_documents WHERE tenant_id = \(bind: tenant) AND id = \(bind: id) FOR UPDATE").first()
            else { throw DMSError.notFound }
            if try row.decode(column: "trashed_at", as: Date?.self) != nil { throw DMSError.trashed }
            if let ifMatch, ifMatch != Int(try row.decode(column: "rev", as: Int32.self)) { throw HubError(.preconditionFailed, "precondition_failed") }

            if present.contains("document_type_id"), let t = body.document_type_id { try await requireRef("dms_document_types", t, tenant: tenant, field: "document_type_id", on: s) }
            if present.contains("storage_path_id"), let p = body.storage_path_id { try await requireRef("dms_storage_paths", p, tenant: tenant, field: "storage_path_id", on: s) }
            try await s.raw("""
                UPDATE dms_documents SET
                  title = CASE WHEN \(bind: title != nil) THEN \(bind: title)::text ELSE title END,
                  doc_date = CASE WHEN \(bind: present.contains("doc_date")) THEN \(bind: docDate)::text::date ELSE doc_date END,
                  document_type_id = CASE WHEN \(bind: present.contains("document_type_id")) THEN \(bind: body.document_type_id)::uuid ELSE document_type_id END,
                  storage_path_id = CASE WHEN \(bind: present.contains("storage_path_id")) THEN \(bind: body.storage_path_id)::uuid ELSE storage_path_id END,
                  rev = rev + 1, updated_at = now()
                WHERE tenant_id = \(bind: tenant) AND id = \(bind: id)
                """).run()
            if present.contains("correspondent_id") { try await setCorrespondent(id, to: body.correspondent_id, tenant: tenant, actor: actor, requestID: requestID, db: tx, s: s) }
            if present.contains("tag_ids") { try await setTags(id, to: body.tag_ids ?? [], tenant: tenant, actor: actor, on: s) }
            if let fields = body.fields { try await setFields(id, fields, tenant: tenant, on: s) }

            var meta: [String: AuditValue] = [:]
            for key in present.sorted() { meta[key] = .number(1) }
            try await AuditLog.record(AuditEvent(action: "dms.document.updated", actor: actor, tenant: tenant, subjectType: "dms.document", subjectID: id.uuidString,
                                                 meta: meta, requestID: requestID), on: s)
            guard let out = try await load(id, tenant: tenant, on: s) else { throw DMSError.notFound }
            return out
        }
    }

    private static func setCorrespondent(_ id: UUID, to contact: UUID?, tenant: UUID, actor: UUID, requestID: String, db: any Database, s: any SQLDatabase) async throws {
        if let contact, !(try await ContactService.exists(contact, tenant: tenant, on: s)) { throw DMSError.invalid("correspondent_id", "unknown") }
        let current = try await LinkService.list(tenant: tenant, type: "dms.document", id: id, includeRemoved: false, on: db)
            .filter { $0.from_type == "dms.document" && $0.to_type == "contact" && $0.kind == correspondentKind }
        if let contact, current.count == 1, current[0].to_id == contact { return }
        for link in current { try await LinkService.remove(link.id, tenant: tenant, actor: actor, requestID: requestID, on: db) }
        if let contact {
            _ = try await LinkService.create(tenant: tenant, actor: actor, body: LinkBody(from_type: "dms.document", from_id: id, to_type: "contact", to_id: contact,
                                                                                          kind: correspondentKind, source: "manual"), requestID: requestID, on: db)
        }
    }

    /// Ersetzt die Tag-Zuordnung. Alle Tags müssen zum Mandanten gehören; in einer exklusiven Gruppe höchstens eines.
    private static func setTags(_ id: UUID, to tags: [UUID], tenant: UUID, actor: UUID, on s: any SQLDatabase) async throws {
        let unique = Array(Set(tags))
        var perGroup: [UUID: Int] = [:]
        for t in unique {
            guard let r = try await s.raw("""
                SELECT t.group_id, g.exclusive FROM dms_tags t LEFT JOIN dms_tag_groups g ON g.id = t.group_id AND g.tenant_id = t.tenant_id
                WHERE t.tenant_id = \(bind: tenant) AND t.id = \(bind: t)
                """).first() else { throw DMSError.invalid("tag_ids", "unknown") }
            if let group = try r.decode(column: "group_id", as: UUID?.self), try r.decode(column: "exclusive", as: Bool?.self) == true {
                perGroup[group, default: 0] += 1
                if perGroup[group]! > 1 { throw DMSError.invalid("tag_ids", "exclusive_group") }
            }
        }
        try await s.raw("DELETE FROM dms_document_tags WHERE tenant_id = \(bind: tenant) AND document_id = \(bind: id) AND NOT (tag_id = ANY(\(bind: unique)::uuid[]))").run()
        for t in unique {
            try await s.raw("""
                INSERT INTO dms_document_tags (tenant_id, document_id, tag_id, assigned_by) VALUES (\(bind: tenant), \(bind: id), \(bind: t), \(bind: actor)) ON CONFLICT DO NOTHING
                """).run()
        }
    }

    private static func setFields(_ id: UUID, _ fields: [String: DMSFieldValue?], tenant: UUID, on s: any SQLDatabase) async throws {
        for (code, value) in fields.sorted(by: { $0.key < $1.key }) {
            let path = "fields.\(code)"
            guard let def = try await s.raw("SELECT id, data_type, options::text AS options FROM dms_custom_fields WHERE tenant_id = \(bind: tenant) AND code = \(bind: code)").first()
            else { throw DMSError.invalid(path, "unknown") }
            let fieldID = try def.decode(column: "id", as: UUID.self)
            guard let value else {
                try await s.raw("DELETE FROM dms_document_fields WHERE tenant_id = \(bind: tenant) AND document_id = \(bind: id) AND field_id = \(bind: fieldID)").run()
                continue
            }
            var text: String?, numeric: String?, date: String?, bool: Bool?
            switch (try def.decode(column: "data_type", as: String.self), value) {
            case ("string", .string(let v)) where v.count <= 1000 && !v.isEmpty: text = v
            case ("int", .int(let v)): numeric = String(v)
            case ("decimal", .int(let v)): numeric = String(v)
            case ("decimal", .string(let v)) where v.range(of: "^-?[0-9]{1,15}(\\.[0-9]{1,4})?$", options: .regularExpression) != nil: numeric = v
            case ("date", .string(let v)): date = try DMSError.date(v, path)
            case ("bool", .bool(let v)): bool = v
            case ("select", .string(let v)):
                let options = (try def.decode(column: "options", as: String?.self)).flatMap { $0.data(using: .utf8) }.flatMap { try? JSONDecoder().decode([String].self, from: $0) } ?? []
                guard options.contains(v) else { throw DMSError.invalid(path, "not_an_option") }
                text = v
            case ("contact", .string(let v)):
                guard let c = UUID(uuidString: v), try await ContactService.exists(c, tenant: tenant, on: s) else { throw DMSError.invalid(path, "unknown") }
                text = c.uuidString.lowercased()
            default: throw DMSError.invalid(path, "wrong_type")
            }
            try await s.raw("""
                INSERT INTO dms_document_fields (tenant_id, document_id, field_id, value_text, value_numeric, value_date, value_bool)
                VALUES (\(bind: tenant), \(bind: id), \(bind: fieldID), \(bind: text)::text, \(bind: numeric)::text::numeric, \(bind: date)::text::date, \(bind: bool)::boolean)
                ON CONFLICT (document_id, field_id) DO UPDATE SET value_text = EXCLUDED.value_text, value_numeric = EXCLUDED.value_numeric,
                  value_date = EXCLUDED.value_date, value_bool = EXCLUDED.value_bool
                """).run()
        }
    }

    // MARK: Papierkorb

    static func trash(_ id: UUID, reason: String?, tenant: UUID, actor: UUID, requestID: String, on db: any Database) async throws -> DMSDocumentOut {
        guard let reason = reason?.trimmingCharacters(in: .whitespacesAndNewlines), !reason.isEmpty else { throw DMSError.invalid("reason", "required") }
        guard reason.count <= 500 else { throw DMSError.invalid("reason", "too_long") }
        return try await dmsTransaction(db) { _, s in
            guard let row = try await s.raw("SELECT trashed_at FROM dms_documents WHERE tenant_id = \(bind: tenant) AND id = \(bind: id) FOR UPDATE").first() else { throw DMSError.notFound }
            if try row.decode(column: "trashed_at", as: Date?.self) != nil { throw DMSError.trashed }
            try await s.raw("""
                UPDATE dms_documents SET trashed_at = now(), trashed_by = \(bind: actor), trash_reason = \(bind: reason), rev = rev + 1, updated_at = now()
                WHERE tenant_id = \(bind: tenant) AND id = \(bind: id)
                """).run()
            try await AuditLog.record(AuditEvent(action: "dms.document.trashed", actor: actor, tenant: tenant, subjectType: "dms.document", subjectID: id.uuidString, requestID: requestID), on: s)
            guard let out = try await load(id, tenant: tenant, on: s) else { throw DMSError.notFound }
            return out
        }
    }

    static func restore(_ id: UUID, tenant: UUID, actor: UUID, requestID: String, on db: any Database) async throws -> DMSDocumentOut {
        try await dmsTransaction(db) { _, s in
            guard let row = try await s.raw("SELECT trashed_at FROM dms_documents WHERE tenant_id = \(bind: tenant) AND id = \(bind: id) FOR UPDATE").first() else { throw DMSError.notFound }
            if try row.decode(column: "trashed_at", as: Date?.self) == nil { throw HubError(.conflict, "conflict", detail: "Das Dokument liegt nicht im Papierkorb.") }
            try await s.raw("""
                UPDATE dms_documents SET trashed_at = NULL, trashed_by = NULL, trash_reason = NULL, rev = rev + 1, updated_at = now()
                WHERE tenant_id = \(bind: tenant) AND id = \(bind: id)
                """).run()
            try await AuditLog.record(AuditEvent(action: "dms.document.restored", actor: actor, tenant: tenant, subjectType: "dms.document", subjectID: id.uuidString, requestID: requestID), on: s)
            guard let out = try await load(id, tenant: tenant, on: s) else { throw DMSError.notFound }
            return out
        }
    }

    // MARK: Datei

    struct StoredFile: Sendable { let sha256: String; let size: Int64; let mime: String; let originalName: String?; let title: String }

    static func file(of id: UUID, role: String, tenant: UUID, on s: any SQLDatabase) async throws -> StoredFile? {
        guard let r = try await s.raw("""
            SELECT f.sha256, f.size_bytes, f.mime, f.original_name, d.title FROM dms_document_files f
            JOIN dms_documents d ON d.id = f.document_id AND d.tenant_id = f.tenant_id
            WHERE f.tenant_id = \(bind: tenant) AND f.document_id = \(bind: id) AND f.role = \(bind: role) ORDER BY f.created_at, f.id LIMIT 1
            """).first() else { return nil }
        return StoredFile(sha256: try r.decode(column: "sha256", as: String.self), size: try r.decode(column: "size_bytes", as: Int64.self),
                          mime: try r.decode(column: "mime", as: String.self), originalName: try r.decode(column: "original_name", as: String?.self),
                          title: try r.decode(column: "title", as: String.self))
    }
}
