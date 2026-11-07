import Vapor
import Fluent
import SQLKit

// WP-D2: Stammdaten des DMS (Dokumenttypen, Tag-Gruppen, Tags, Ablagepfade, benutzerdefinierte Felder). Ein generischer CRUD-Dienst, gesteuert durch `DMSMasterSpec`.
// Antworten stammen direkt aus `to_jsonb(row)` ohne `tenant_id`. Löschen nur, wenn nichts mehr darauf verweist (sonst 409).

/// JSON-Wert einer Stammdaten-Eingabe.
enum DMSJSON: Codable, Sendable, Equatable {
    case null, bool(Bool), int(Int), string(String), array([DMSJSON]), object([String: DMSJSON])
    init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Int.self) { self = .int(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([DMSJSON].self) { self = .array(v) }
        else { self = .object(try c.decode([String: DMSJSON].self)) }
    }
    func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil(); case .bool(let v): try c.encode(v); case .int(let v): try c.encode(v)
        case .string(let v): try c.encode(v); case .array(let v): try c.encode(v); case .object(let v): try c.encode(v)
        }
    }
}

struct DMSMasterSpec: Sendable {
    enum Kind: Sendable {
        case text(max: Int)
        case pattern(String)
        case int(ClosedRange<Int>)
        case bool
        case ref(table: String)
        case oneOf([String])
        case template
        case options
    }
    struct Field: Sendable {
        let name: String
        let kind: Kind
        var required = false
        /// Nach dem Anlegen nicht änderbar.
        var immutable = false
    }

    /// Pfadsegment und Namensteil des Audit-Ereignisses (`dms.<audit>.created`).
    let segment: String
    let audit: String
    let table: String
    let permission: String
    let fields: [Field]
    /// Tabellen/Spalten, die auf die Zeile verweisen (Löschen bei Verwendung = 409).
    let usedBy: [(table: String, column: String)]

    static let templateTokens: Set<String> = ["doc_date:yyyy", "doc_date:MM", "type", "correspondent", "title", "asn"]

    static let all: [DMSMasterSpec] = [
        DMSMasterSpec(segment: "types", audit: "type", table: "dms_document_types", permission: "dms.master.manage", fields: [
            .init(name: "name", kind: .text(max: 100), required: true), .init(name: "code", kind: .pattern("^[a-z0-9_]{1,40}$")),
            .init(name: "description", kind: .text(max: 1000)), .init(name: "default_retention_years", kind: .int(0...100))],
            usedBy: [("dms_documents", "document_type_id")]),
        DMSMasterSpec(segment: "tag-groups", audit: "tag_group", table: "dms_tag_groups", permission: "dms.tag.manage", fields: [
            .init(name: "name", kind: .text(max: 100), required: true), .init(name: "exclusive", kind: .bool)],
            usedBy: [("dms_tags", "group_id")]),
        DMSMasterSpec(segment: "tags", audit: "tag", table: "dms_tags", permission: "dms.tag.manage", fields: [
            .init(name: "name", kind: .text(max: 100), required: true), .init(name: "group_id", kind: .ref(table: "dms_tag_groups")),
            .init(name: "color", kind: .pattern("^#[0-9a-fA-F]{6}$"))],
            usedBy: [("dms_document_tags", "tag_id")]),
        DMSMasterSpec(segment: "storage-paths", audit: "storage_path", table: "dms_storage_paths", permission: "dms.master.manage", fields: [
            .init(name: "name", kind: .text(max: 100), required: true), .init(name: "template", kind: .template, required: true)],
            usedBy: [("dms_documents", "storage_path_id")]),
        DMSMasterSpec(segment: "custom-fields", audit: "custom_field", table: "dms_custom_fields", permission: "dms.master.manage", fields: [
            .init(name: "name", kind: .text(max: 100), required: true), .init(name: "code", kind: .pattern("^[a-z][a-z0-9_]{0,39}$"), required: true, immutable: true),
            .init(name: "data_type", kind: .oneOf(["string", "int", "decimal", "date", "bool", "select", "contact"]), required: true, immutable: true),
            .init(name: "options", kind: .options)],
            usedBy: [("dms_document_fields", "field_id")])
    ]

    // MARK: Prüfung

    private func validate(_ f: Field, _ v: DMSJSON, tenant: UUID, on s: any SQLDatabase) async throws -> DMSJSON {
        let bad = DMSError.invalid(f.name)
        switch (f.kind, v) {
        case (_, .null): return .null
        case (.text(let max), .string(let t)):
            let x = t.trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCanonicalMapping
            if x.isEmpty { return .null }
            guard x.count <= max else { throw DMSError.invalid(f.name, "too_long") }
            return .string(x)
        case (.pattern(let p), .string(let t)):
            guard t.range(of: p, options: .regularExpression) != nil else { throw bad }
            return .string(t)
        case (.int(let range), .int(let n)):
            guard range.contains(n) else { throw bad }
            return v
        case (.bool, .bool): return v
        case (.oneOf(let values), .string(let t)):
            guard values.contains(t) else { throw bad }
            return v
        case (.ref(let table), .string(let t)):
            guard let id = UUID(uuidString: t) else { throw bad }
            try await DMSDocuments.requireRef(table, id, tenant: tenant, field: f.name, on: s)
            return .string(id.uuidString.lowercased())
        case (.template, .string(let t)):
            let x = t.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !x.isEmpty, x.count <= 300 else { throw bad }
            // nur bekannte Platzhalter: {doc_date:yyyy}, {doc_date:MM}, {type}, {correspondent}, {title}, {asn}, {field:<code>}, {tags:<gruppe>}
            var rest = Substring(x)
            while let open = rest.firstIndex(of: "{") {
                guard let close = rest[open...].firstIndex(of: "}") else { throw DMSError.invalid(f.name, "bad_placeholder") }
                let token = String(rest[rest.index(after: open)..<close])
                let known = Self.templateTokens.contains(token) || token.range(of: "^field:[a-z][a-z0-9_]{0,39}$", options: .regularExpression) != nil
                    || token.range(of: "^tags:[^{}]{1,100}$", options: .regularExpression) != nil
                guard known else { throw DMSError.invalid(f.name, "bad_placeholder") }
                rest = rest[rest.index(after: close)...]
            }
            guard !rest.contains("}") else { throw DMSError.invalid(f.name, "bad_placeholder") }
            return .string(x)
        case (.options, .array(let items)):
            guard (1...100).contains(items.count) else { throw bad }
            var seen = Set<String>()
            for case .string(let o) in items where !o.isEmpty && o.count <= 100 { seen.insert(o) }
            guard seen.count == items.count else { throw bad }
            return v
        default: throw bad
        }
    }

    private func bindValue(_ f: Field, _ v: DMSJSON) -> SQLQueryString {
        switch (f.kind, v) {
        case (.int, .int(let n)): return "\(bind: n)"
        case (.int, _): return "\(bind: Optional<Int>.none)"
        case (.bool, .bool(let b)): return "\(bind: b)"
        case (.bool, _): return "\(bind: Optional<Bool>.none)"
        case (.ref, .string(let t)): return "\(bind: UUID(uuidString: t))"
        case (.ref, _): return "\(bind: Optional<UUID>.none)"
        case (.options, .array): return "\(bind: String(decoding: (try? JSONEncoder().encode(v)) ?? Data(), as: UTF8.self))::text::jsonb"
        case (.options, _): return "\(bind: Optional<String>.none)::text::jsonb"
        case (_, .string(let t)): return "\(bind: t)"
        default: return "\(bind: Optional<String>.none)"
        }
    }

    private func customFieldCheck(dataType: String, options: DMSJSON?) throws {
        let hasOptions: Bool
        if case .array = options { hasOptions = true } else { hasOptions = false }
        if dataType == "select", !hasOptions { throw DMSError.invalid("options", "required") }
        if dataType != "select", hasOptions { throw DMSError.invalid("options", "not_allowed") }
    }

    // MARK: Lesen / Schreiben

    private static let json = "to_jsonb(r) - 'tenant_id'"

    func list(tenant: UUID, on s: any SQLDatabase) async throws -> Response {
        let rows = try await s.raw("""
            SELECT (\(unsafeRaw: Self.json))::text AS j FROM \(unsafeRaw: table) r WHERE r.tenant_id = \(bind: tenant) ORDER BY lower(r.name), r.id LIMIT 1000
            """).all().map { Self.canonical(try $0.decode(column: "j", as: String.self)) }
        return Self.jsonResponse("{\"items\":[" + rows.joined(separator: ",") + "]}", status: .ok)
    }

    /// IDs wie überall in der API in der Schreibweise von `UUID.uuidString` (Großbuchstaben); die Datenbank liefert Kleinbuchstaben.
    static func canonical(_ row: String) -> String {
        guard var object = (try? JSONSerialization.jsonObject(with: Data(row.utf8))) as? [String: Any] else { return row }
        for key in ["id", "group_id"] { if let v = object[key] as? String { object[key] = v.uppercased() } }
        return String(decoding: (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data(row.utf8), as: UTF8.self)
    }

    static func jsonResponse(_ body: String, status: HTTPStatus) -> Response {
        var headers = HTTPHeaders()
        headers.contentType = .json
        return Response(status: status, headers: headers, body: .init(string: body))
    }

    private func decodeBody(_ req: Request) throws -> [String: DMSJSON] {
        guard let body = try? req.content.decode([String: DMSJSON].self) else { throw DMSError.invalid("body", "invalid") }
        return body
    }

    func create(_ req: Request) async throws -> Response {
        let tenant = try req.requireTenant().tenantID, actor = try req.requireAuth().user.id, requestID = req.requestId
        let body = try decodeBody(req)
        let unknown = Set(body.keys).subtracting(fields.map(\.name))
        if let first = unknown.sorted().first { throw DMSError.invalid(first, "unknown_field") }
        let spec = self
        let out: String = try await dmsTransaction(req.db) { _, s in
            var columns: [String] = [], values: [SQLQueryString] = []
            var checked: [String: DMSJSON] = [:]
            for f in spec.fields {
                let v = try await spec.validate(f, body[f.name] ?? .null, tenant: tenant, on: s)
                if f.required, v == .null { throw DMSError.invalid(f.name, "required") }
                checked[f.name] = v
                if body[f.name] != nil, v != .null { columns.append(f.name); values.append(spec.bindValue(f, v)) }
            }
            if spec.segment == "custom-fields" {
                guard case .string(let dt)? = checked["data_type"] else { throw DMSError.invalid("data_type", "required") }
                try spec.customFieldCheck(dataType: dt, options: checked["options"])
            }
            var q: SQLQueryString = "INSERT INTO \(unsafeRaw: spec.table) (tenant_id"
            for c in columns { q += ", \(unsafeRaw: c)" }
            q += ") VALUES (\(bind: tenant)"
            for v in values { q += ", "; q += v }
            q += ") RETURNING (to_jsonb(\(unsafeRaw: spec.table)) - 'tenant_id')::text AS j, id"
            let row: (any SQLRow)?
            do { row = try await s.raw(q).first() } catch let e as any DatabaseError where e.isConstraintFailure { throw HubError(.conflict, "conflict") }
            guard let row else { throw Abort(.internalServerError) }
            let id = try row.decode(column: "id", as: UUID.self)
            try await AuditLog.record(AuditEvent(action: "dms.\(spec.audit).created", actor: actor, tenant: tenant, subjectType: "dms.\(spec.audit)", subjectID: id.uuidString,
                                                 requestID: requestID), on: s)
            return Self.canonical(try row.decode(column: "j", as: String.self))
        }
        return Self.jsonResponse(out, status: .created)
    }

    func update(_ req: Request, id: UUID) async throws -> Response {
        let tenant = try req.requireTenant().tenantID, actor = try req.requireAuth().user.id, requestID = req.requestId
        let body = try decodeBody(req)
        let unknown = Set(body.keys).subtracting(fields.map(\.name))
        if let first = unknown.sorted().first { throw DMSError.invalid(first, "unknown_field") }
        if let locked = fields.first(where: { $0.immutable && body[$0.name] != nil }) { throw DMSError.invalid(locked.name, "immutable") }
        let spec = self
        let out: String = try await dmsTransaction(req.db) { _, s in
            let probe = spec.segment == "custom-fields" ? "data_type" : "id::text"
            guard let current = try await s.raw("SELECT \(unsafeRaw: probe) AS dt FROM \(unsafeRaw: spec.table) WHERE tenant_id = \(bind: tenant) AND id = \(bind: id) FOR UPDATE").first()
            else { throw DMSError.notFound }
            var assignments: [SQLQueryString] = []
            var checked: [String: DMSJSON] = [:]
            for f in spec.fields where body[f.name] != nil {
                let v = try await spec.validate(f, body[f.name]!, tenant: tenant, on: s)
                if f.required, v == .null { throw DMSError.invalid(f.name, "required") }
                checked[f.name] = v
                var assignment: SQLQueryString = "\(unsafeRaw: f.name) = "
                assignment += spec.bindValue(f, v)
                assignments.append(assignment)
            }
            if spec.segment == "custom-fields", body["options"] != nil {
                try spec.customFieldCheck(dataType: try current.decode(column: "dt", as: String.self), options: checked["options"])
            }
            if !assignments.isEmpty {
                var q: SQLQueryString = "UPDATE \(unsafeRaw: spec.table) SET "
                for (i, a) in assignments.enumerated() { if i > 0 { q += ", " }; q += a }
                q += " WHERE tenant_id = \(bind: tenant) AND id = \(bind: id)"
                do { try await s.raw(q).run() } catch let e as any DatabaseError where e.isConstraintFailure { throw HubError(.conflict, "conflict") }
                try await AuditLog.record(AuditEvent(action: "dms.\(spec.audit).updated", actor: actor, tenant: tenant, subjectType: "dms.\(spec.audit)", subjectID: id.uuidString,
                                                     requestID: requestID), on: s)
            }
            guard let row = try await s.raw("SELECT (\(unsafeRaw: Self.json))::text AS j FROM \(unsafeRaw: spec.table) r WHERE r.tenant_id = \(bind: tenant) AND r.id = \(bind: id)").first()
            else { throw DMSError.notFound }
            return Self.canonical(try row.decode(column: "j", as: String.self))
        }
        return Self.jsonResponse(out, status: .ok)
    }

    func delete(_ req: Request, id: UUID) async throws -> Response {
        let tenant = try req.requireTenant().tenantID, actor = try req.requireAuth().user.id, requestID = req.requestId
        let spec = self
        try await dmsTransaction(req.db) { _, s in
            guard try await s.raw("SELECT 1 AS x FROM \(unsafeRaw: spec.table) WHERE tenant_id = \(bind: tenant) AND id = \(bind: id) FOR UPDATE").first() != nil
            else { throw DMSError.notFound }
            for u in spec.usedBy {
                if try await s.raw("SELECT 1 AS x FROM \(unsafeRaw: u.table) WHERE tenant_id = \(bind: tenant) AND \(unsafeRaw: u.column) = \(bind: id) LIMIT 1").first() != nil {
                    throw HubError(.conflict, "conflict", detail: "Der Eintrag wird noch verwendet.")
                }
            }
            do { try await s.raw("DELETE FROM \(unsafeRaw: spec.table) WHERE tenant_id = \(bind: tenant) AND id = \(bind: id)").run() }
            catch let e as any DatabaseError where e.isConstraintFailure { throw HubError(.conflict, "conflict", detail: "Der Eintrag wird noch verwendet.") }
            try await AuditLog.record(AuditEvent(action: "dms.\(spec.audit).deleted", actor: actor, tenant: tenant, subjectType: "dms.\(spec.audit)", subjectID: id.uuidString,
                                                 requestID: requestID), on: s)
        }
        return Response(status: .noContent)
    }
}
