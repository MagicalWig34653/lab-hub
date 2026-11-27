import Vapor
import Fluent
import SQLKit
import HubCore

// WP-R6d: Layouts (versioniert), Logos, Zuordnung je Belegart/Serie, Vorschau eines Entwurfs. Rechte: Layouts lesen `invoice.master.read`, ändern
// `invoice.master.manage` (Layouts sind Stammdaten); Vorschau anfordern `invoice.document.update`, abrufen `invoice.document.read`.
// Jede Abfrage ist mandantengefiltert; fremde oder unbekannte Ids sind 404, fremde Verweise in Eingaben 422 `not_found`.

enum InvoiceLayouts {
    static let kinds = ["quote", "order_confirmation", "delivery_note", "invoice", "credit_note"]

    // MARK: Laden für den Renderer

    /// Eingefrorene Layoutversion eines Belegs (Render-Job); ohne Version das Standardlayout.
    static func frozenLayout(document: UUID, tenant: UUID, store: any ObjectStore, on s: any SQLDatabase) async throws -> InvoiceRenderLayout {
        guard let row = try await s.raw("SELECT layout_version_id FROM invoice_documents WHERE tenant_id = \(bind: tenant) AND id = \(bind: document)").first(),
              let version = try row.decode(column: "layout_version_id", as: UUID?.self) else { return .standard }
        return try await layout(version: version, tenant: tenant, store: store, on: s)
    }

    /// Layout einer Version mit Logo-Bytes aus dem Objektspeicher.
    static func layout(version: UUID, tenant: UUID, store: any ObjectStore, on s: any SQLDatabase) async throws -> InvoiceRenderLayout {
        guard let row = try await s.raw("""
            SELECT layout_id, version, params::text AS params FROM invoice_layout_versions WHERE tenant_id = \(bind: tenant) AND id = \(bind: version)
            """).first() else { throw PermanentJobError(code: "layout_missing") }
        let params: InvoiceLayoutParams
        do { params = try InvoiceLayoutParams.fromStored(try row.decode(column: "params", as: String.self)) } catch { throw PermanentJobError(code: "layout_invalid") }
        let key = try row.decode(column: "layout_id", as: UUID.self).uuidString.lowercased(), number = try row.decode(column: "version", as: Int.self)
        guard let logo = params.logo else { return InvoiceRenderLayout(key: key, version: number, params: params) }
        guard let asset = try await s.raw("SELECT content_type FROM invoice_layout_assets WHERE tenant_id = \(bind: tenant) AND sha256 = \(bind: logo.sha256)").first()
        else { throw PermanentJobError(code: "layout_logo_missing") }
        var bytes = Data()
        for try await chunk in try await store.get(try ObjectKey(tenantID: tenant, sha256: logo.sha256)) { bytes.append(contentsOf: chunk.readableBytesView) }
        return InvoiceRenderLayout(key: key, version: number, params: params, logo: bytes, logoType: try asset.decode(column: "content_type", as: String.self))
    }

    /// Version für einen Beleg nach Zuordnung: Belegart und Serie > nur Serie > nur Belegart > Vorgabe; jeweils die neueste Version. Nil = Standardlayout.
    static func resolve(kind: String, series: UUID?, tenant: UUID, on s: any SQLDatabase) async throws -> UUID? {
        try await s.raw("""
            SELECT v.id FROM invoice_layout_assignments a
            JOIN LATERAL (SELECT id FROM invoice_layout_versions v WHERE v.tenant_id = a.tenant_id AND v.layout_id = a.layout_id ORDER BY v.version DESC LIMIT 1) v ON true
            WHERE a.tenant_id = \(bind: tenant) AND (a.document_kind IS NULL OR a.document_kind = \(bind: kind)) AND (a.series_id IS NULL OR a.series_id = \(bind: series))
            ORDER BY (a.document_kind IS NOT NULL AND a.series_id IS NOT NULL) DESC, (a.series_id IS NOT NULL) DESC, (a.document_kind IS NOT NULL) DESC LIMIT 1
            """).first()?.decode(column: "id", as: UUID.self)
    }

    static func latestVersion(layout: UUID, tenant: UUID, on s: any SQLDatabase) async throws -> UUID? {
        try await s.raw("SELECT id FROM invoice_layout_versions WHERE tenant_id = \(bind: tenant) AND layout_id = \(bind: layout) ORDER BY version DESC LIMIT 1")
            .first()?.decode(column: "id", as: UUID.self)
    }

    // MARK: Eingabe

    private static func body(_ req: Request) throws -> [String: LayoutJSON] {
        guard let buffer = req.body.data, let value = try? JSONDecoder().decode([String: LayoutJSON].self, from: Data(buffer: buffer)) else { throw InvoiceError.invalid("body", "invalid") }
        return value
    }

    private static func uuid(_ v: LayoutJSON?) -> UUID? { if case .string(let s)? = v { return UUID(uuidString: s) }; return nil }

    /// Parameter prüfen, Logo-Verweis gegen die Logos des Mandanten.
    private static func checkedParams(_ value: LayoutJSON?, tenant: UUID, on s: any SQLDatabase) async throws -> InvoiceLayoutParams {
        guard let value else { throw InvoiceError.invalid("params", "required") }
        let p = try InvoiceLayoutParams.parse(value)
        if let logo = p.logo, try await s.raw("SELECT 1 AS x FROM invoice_layout_assets WHERE tenant_id = \(bind: tenant) AND sha256 = \(bind: logo.sha256)").first() == nil {
            throw InvoiceError.invalid("params.logo.sha256", "not_found")
        }
        return p
    }

    // MARK: Ausgabe

    private static let layoutSelect = """
        SELECT l.id, l.name, l.created_at, l.updated_at, v.id AS version_id, v.version, v.params::text AS params, v.created_at AS version_created_at
        FROM invoice_layouts l JOIN invoice_layout_versions v ON v.layout_id = l.id AND v.tenant_id = l.tenant_id
        """

    private static func iso(_ d: Date) -> String { ISO8601DateFormatter().string(from: d) }

    private static func object(_ r: any SQLRow) throws -> [String: Any] {
        let params = try JSONSerialization.jsonObject(with: Data(try r.decode(column: "params", as: String.self).utf8))
        return ["id": try r.decode(column: "id", as: UUID.self).uuidString, "name": try r.decode(column: "name", as: String.self),
                "version": try r.decode(column: "version", as: Int.self), "version_id": try r.decode(column: "version_id", as: UUID.self).uuidString,
                "params": params, "created_at": iso(try r.decode(column: "created_at", as: Date.self)), "updated_at": iso(try r.decode(column: "updated_at", as: Date.self)),
                "version_created_at": iso(try r.decode(column: "version_created_at", as: Date.self))]
    }

    private static func json(_ o: Any) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: o, options: [.sortedKeys, .withoutEscapingSlashes]), as: UTF8.self)
    }

    /// Layout mit neuester (oder bestimmter) Version; 404 für fremde oder unbekannte Ids.
    private static func fetch(_ id: UUID, version: Int? = nil, tenant: UUID, on s: any SQLDatabase) async throws -> String {
        let row: (any SQLRow)?
        if let version {
            row = try await s.raw("\(unsafeRaw: layoutSelect) WHERE l.tenant_id = \(bind: tenant) AND l.id = \(bind: id) AND v.version = \(bind: version)").first()
        } else {
            row = try await s.raw("\(unsafeRaw: layoutSelect) WHERE l.tenant_id = \(bind: tenant) AND l.id = \(bind: id) ORDER BY v.version DESC LIMIT 1").first()
        }
        guard let row else { throw InvoiceError.notFound }
        return try json(try object(row))
    }

    // MARK: Routen Layouts

    static func list(_ req: Request) async throws -> Response {
        let tenant = try req.requireTenant().tenantID
        let rows = try await sql(req.db).raw("""
            SELECT DISTINCT ON (lower(l.name), l.id) l.id, l.name, l.created_at, l.updated_at, v.id AS version_id, v.version, v.params::text AS params, v.created_at AS version_created_at
            FROM invoice_layouts l JOIN invoice_layout_versions v ON v.layout_id = l.id AND v.tenant_id = l.tenant_id
            WHERE l.tenant_id = \(bind: tenant) ORDER BY lower(l.name), l.id, v.version DESC
            """).all()
        return invoiceJSONResponse(try json(["items": try rows.map(object)]), status: .ok)
    }

    static func get(_ req: Request) async throws -> Response {
        let tenant = try req.requireTenant().tenantID
        return invoiceJSONResponse(try await fetch(try InvoiceValidation.id(req), tenant: tenant, on: try sql(req.db)), status: .ok)
    }

    static func getVersion(_ req: Request) async throws -> Response {
        let tenant = try req.requireTenant().tenantID
        guard let version = req.parameters.get("version", as: Int.self), version >= 1 else { throw InvoiceError.notFound }
        return invoiceJSONResponse(try await fetch(try InvoiceValidation.id(req), version: version, tenant: tenant, on: try sql(req.db)), status: .ok)
    }

    static func create(_ req: Request) async throws -> Response {
        let tenant = try req.requireTenant().tenantID, actor = try req.requireAuth().user.id, requestID = req.requestId
        let b = try body(req)
        guard case .string(let raw)? = b["name"], case let name = raw.trimmingCharacters(in: .whitespacesAndNewlines), (1...100).contains(name.count) else {
            throw InvoiceError.invalid("name", b["name"] == nil ? "required" : "invalid")
        }
        for key in b.keys where !["name", "params"].contains(key) { throw InvoiceError.invalid(key, "unknown") }
        let out = try await invoiceTransaction(req.db) { s -> String in
            let params = try await checkedParams(b["params"], tenant: tenant, on: s)
            guard let row = try await s.raw("INSERT INTO invoice_layouts (tenant_id, name) VALUES (\(bind: tenant), \(bind: name)) RETURNING id").first() else { throw InvoiceError.notFound }
            let id = try row.decode(column: "id", as: UUID.self)
            try await s.raw("""
                INSERT INTO invoice_layout_versions (tenant_id, layout_id, version, params, created_by) VALUES (\(bind: tenant), \(bind: id), 1, \(bind: params.canonicalJSON)::jsonb, \(bind: actor))
                """).run()
            try await AuditLog.record(AuditEvent(action: "invoice.layout.created", actor: actor, tenant: tenant, subjectType: "invoice.layout", subjectID: id.uuidString,
                                                 meta: ["version": .number(1)], requestID: requestID), on: s)
            return try await fetch(id, tenant: tenant, on: s)
        }
        return invoiceJSONResponse(out, status: .created)
    }

    /// Neue Version (Nummer = höchste + 1, unter Zeilensperre des Layouts); ältere Versionen bleiben unverändert.
    static func createVersion(_ req: Request) async throws -> Response {
        let tenant = try req.requireTenant().tenantID, actor = try req.requireAuth().user.id, requestID = req.requestId
        let id = try InvoiceValidation.id(req)
        let b = try body(req)
        for key in b.keys where key != "params" { throw InvoiceError.invalid(key, "unknown") }
        let out = try await invoiceTransaction(req.db) { s -> String in
            guard try await s.raw("SELECT 1 AS x FROM invoice_layouts WHERE tenant_id = \(bind: tenant) AND id = \(bind: id) FOR UPDATE").first() != nil else { throw InvoiceError.notFound }
            let params = try await checkedParams(b["params"], tenant: tenant, on: s)
            guard let row = try await s.raw("""
                INSERT INTO invoice_layout_versions (tenant_id, layout_id, version, params, created_by)
                SELECT \(bind: tenant), \(bind: id), coalesce(max(version), 0) + 1, \(bind: params.canonicalJSON)::jsonb, \(bind: actor) FROM invoice_layout_versions WHERE layout_id = \(bind: id)
                RETURNING version
                """).first() else { throw InvoiceError.notFound }
            let version = try row.decode(column: "version", as: Int.self)
            try await s.raw("UPDATE invoice_layouts SET updated_at = now() WHERE tenant_id = \(bind: tenant) AND id = \(bind: id)").run()
            try await AuditLog.record(AuditEvent(action: "invoice.layout.versioned", actor: actor, tenant: tenant, subjectType: "invoice.layout", subjectID: id.uuidString,
                                                 meta: ["version": .number(Int64(version))], requestID: requestID), on: s)
            return try await fetch(id, tenant: tenant, on: s)
        }
        return invoiceJSONResponse(out, status: .created)
    }

    // MARK: Logo

    /// Rohe Bildbytes mit `Content-Type: image/png|image/jpeg`. Geprüft (Format, Größe, Maße) wird vor dem Speichern: Abgelehntes erreicht nie den Objektspeicher.
    static func uploadLogo(_ req: Request, store: @escaping @Sendable (any SQLDatabase) throws -> any ObjectStore) async throws -> Response {
        let tenant = try req.requireTenant().tenantID, actor = try req.requireAuth().user.id, requestID = req.requestId
        let type = req.headers.contentType.map { "\($0.type)/\($0.subType)".lowercased() }
        guard let type, InvoiceLogo.types.contains(type) else { throw HubError(.unsupportedMediaType, "unsupported_media_type") }
        let data = req.body.data.map { Data(buffer: $0) } ?? Data()
        guard data.count <= InvoiceLogo.maxBytes else { throw HubError(.payloadTooLarge, "payload_too_large") }
        let info = try InvoiceLogo.inspect(data, contentType: type)
        let s0 = try sql(req.db)
        let stored = try await store(s0).put(tenant: tenant, stream: InvoiceRenderJob.byteStream(data), expectedSHA256: nil)
        let out = try await invoiceTransaction(req.db) { s -> String in
            try await FileRecordService.lockBlob(tenant: tenant, sha256: stored.key.sha256, on: s)
            let txStore = try store(s)
            guard try await txStore.exists(stored.key) else { throw HubError(.internalServerError, "internal") }
            let file = try await FileRecordService(s).register(stored, backend: txStore.kind, contentType: type)
            if try await s.raw("""
                INSERT INTO invoice_layout_assets (tenant_id, sha256, file_id, content_type, width, height, size_bytes)
                VALUES (\(bind: tenant), \(bind: stored.key.sha256), \(bind: file), \(bind: type), \(bind: info.width), \(bind: info.height), \(bind: Int64(data.count)))
                ON CONFLICT (tenant_id, sha256) DO NOTHING RETURNING id
                """).first() != nil {
                try await AuditLog.record(AuditEvent(action: "invoice.layout.logo_uploaded", actor: actor, tenant: tenant, subjectType: "invoice.layout_asset",
                                                     subjectID: stored.key.sha256, meta: ["bytes": .number(Int64(data.count))], requestID: requestID), on: s)
            }
            return try json(["sha256": stored.key.sha256, "content_type": type, "width": info.width, "height": info.height, "size": data.count])
        }
        return invoiceJSONResponse(out, status: .created)
    }

    // MARK: Zuordnung

    private static func assignments(tenant: UUID, on s: any SQLDatabase) async throws -> String {
        let rows = try await s.raw("""
            SELECT document_kind, series_id, layout_id FROM invoice_layout_assignments WHERE tenant_id = \(bind: tenant)
            ORDER BY document_kind NULLS FIRST, series_id NULLS FIRST, id
            """).all()
        return try json(["items": try rows.map { r -> [String: Any] in
            ["document_kind": try r.decode(column: "document_kind", as: String?.self) ?? NSNull(),
             "series_id": try r.decode(column: "series_id", as: UUID?.self)?.uuidString ?? NSNull(),
             "layout_id": try r.decode(column: "layout_id", as: UUID.self).uuidString]
        }])
    }

    static func getAssignments(_ req: Request) async throws -> Response {
        invoiceJSONResponse(try await assignments(tenant: try req.requireTenant().tenantID, on: try sql(req.db)), status: .ok)
    }

    /// Ersetzt alle Zuordnungen des Mandanten (`items`: `document_kind`, `series_id`, `layout_id`). Jede Kombination höchstens einmal.
    static func putAssignments(_ req: Request) async throws -> Response {
        let tenant = try req.requireTenant().tenantID, actor = try req.requireAuth().user.id, requestID = req.requestId
        let b = try body(req)
        guard case .array(let items)? = b["items"], items.count <= 200 else { throw InvoiceError.invalid("items", "invalid") }
        let out = try await invoiceTransaction(req.db) { s -> String in
            var seen = Set<String>(), rows: [(String?, UUID?, UUID)] = []
            for (i, item) in items.enumerated() {
                guard case .object(let o) = item else { throw InvoiceError.invalid("items[\(i)]", "invalid") }
                for key in o.keys where !["document_kind", "series_id", "layout_id"].contains(key) { throw InvoiceError.invalid("items[\(i)].\(key)", "unknown") }
                var kind: String?
                switch o["document_kind"] {
                case nil, .null?: kind = nil
                case .string(let k)? where kinds.contains(k): kind = k
                default: throw InvoiceError.invalid("items[\(i)].document_kind", "invalid")
                }
                var series: UUID?
                if let raw = o["series_id"], raw != .null {
                    guard let id = uuid(raw), try await s.raw("SELECT 1 AS x FROM invoice_series WHERE tenant_id = \(bind: tenant) AND id = \(bind: id)").first() != nil
                    else { throw InvoiceError.invalid("items[\(i)].series_id", "not_found") }
                    series = id
                }
                guard let layout = uuid(o["layout_id"]), try await s.raw("SELECT 1 AS x FROM invoice_layouts WHERE tenant_id = \(bind: tenant) AND id = \(bind: layout)").first() != nil
                else { throw InvoiceError.invalid("items[\(i)].layout_id", "not_found") }
                guard seen.insert("\(kind ?? "")|\(series?.uuidString ?? "")").inserted else { throw InvoiceError.invalid("items[\(i)]", "duplicate") }
                rows.append((kind, series, layout))
            }
            try await s.raw("DELETE FROM invoice_layout_assignments WHERE tenant_id = \(bind: tenant)").run()
            for (kind, series, layout) in rows {
                try await s.raw("""
                    INSERT INTO invoice_layout_assignments (tenant_id, document_kind, series_id, layout_id) VALUES (\(bind: tenant), \(bind: kind), \(bind: series), \(bind: layout))
                    """).run()
            }
            try await AuditLog.record(AuditEvent(action: "invoice.layout.assigned", actor: actor, tenant: tenant, subjectType: "invoice.layout_assignments", subjectID: tenant.uuidString,
                                                 meta: ["count": .number(Int64(rows.count))], requestID: requestID), on: s)
            return try await assignments(tenant: tenant, on: s)
        }
        return invoiceJSONResponse(out, status: .ok)
    }
}
