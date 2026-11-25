import Vapor
import Fluent
import SQLKit

// WP-R3: Umwandlung, Gutschrift und Verknüpfungen Beleg↔Beleg. Umwandlung und Gutschrift erzeugen immer einen ENTWURF (Kopie des finalen Ausgangsbelegs,
// Gutschrift mit negierten Mengen und Beträgen) samt Verknüpfung; wirksam wird er erst durch das Finalisieren. Der Ausgangsbeleg bleibt unverändert.
// Systemverknüpfungen (`conversion`, `credit_note`) entstehen nur so; von Hand gibt es nur `reference`.

enum InvoiceLinks {
    /// Erlaubte Umwandlungen (Ausgangsart → Zielarten). Gutschriften laufen über `credit-note`.
    static let conversions: [String: Set<String>] = [
        "quote": ["order_confirmation", "delivery_note", "invoice"], "order_confirmation": ["delivery_note", "invoice"], "delivery_note": ["invoice"]]

    private static let spec = InvoiceMasterSpec(segment: "documents", audit: "document", table: "invoice_documents", fields: [
        .init(name: "document_type_id", kind: .ref(table: "invoice_document_types"), required: true), .init(name: "issue_date", kind: .date)], order: "")

    // MARK: Erzeugen

    static func convert(_ req: Request) async throws -> Response { try await derive(req, creditNote: false) }
    static func creditNote(_ req: Request) async throws -> Response { try await derive(req, creditNote: true) }

    private static func derive(_ req: Request, creditNote: Bool) async throws -> Response {
        let tenant = try req.requireTenant().tenantID, actor = try req.requireAuth().user.id, requestID = req.requestId
        let source = try InvoiceValidation.id(req)
        let body = try InvoiceValidation.body(req)
        return try await InvoiceIdempotency.run(req, tenant: tenant) { s in
            guard let doc = try await s.raw("SELECT kind, status FROM invoice_documents WHERE tenant_id = \(bind: tenant) AND id = \(bind: source) FOR SHARE").first()
            else { throw InvoiceError.notFound }
            guard try doc.decode(column: "status", as: String.self) == "final" else { throw HubError(.conflict, "document_not_final") }
            let sourceKind = try doc.decode(column: "kind", as: String.self)
            if creditNote, sourceKind != "invoice" { throw InvoiceError.invalid("id", "not_an_invoice") }
            let v = try await spec.checked(body, requireAll: true, tenant: tenant, on: s)
            guard case .uuid(let typeID)? = v["document_type_id"],
                  let type = try await s.raw("SELECT kind, active FROM invoice_document_types WHERE tenant_id = \(bind: tenant) AND id = \(bind: typeID)").first()
            else { throw InvoiceError.invalid("document_type_id", "not_found") }
            guard try type.decode(column: "active", as: Bool.self) else { throw InvoiceError.invalid("document_type_id", "inactive") }
            let kind = try type.decode(column: "kind", as: String.self)
            if creditNote {
                guard kind == "credit_note" else { throw InvoiceError.invalid("document_type_id", "not_a_credit_note_type") }
            } else {
                guard conversions[sourceKind]?.contains(kind) == true else { throw InvoiceError.invalid("document_type_id", "conversion_not_allowed") }
            }
            let sign: SQLQueryString = creditNote ? "-1" : "1"
            let issue: SQLQueryString = v["issue_date"].flatMap { $0 == .null ? nil : $0.sql } ?? "(now() AT TIME ZONE 'UTC')::date"
            // Skontobedingungen wandern nur in eine Rechnung oder deren Vorstufen, nie in eine Gutschrift.
            let skonto: SQLQueryString = creditNote ? "NULL::numeric, NULL::integer" : "skonto_percent, skonto_days"
            var q: SQLQueryString = """
                INSERT INTO invoice_documents (tenant_id, document_type_id, kind, contact_id, issue_date, delivery_date, currency, price_mode, discount_percent, discount_amount,
                  rounding_mode, header_text, footer_text, note, skonto_percent, skonto_days)
                SELECT tenant_id, \(bind: typeID), \(bind: kind), contact_id,
                """
            q += issue; q += ", delivery_date, currency, price_mode, discount_percent, discount_amount * "; q += sign
            q += ", rounding_mode, header_text, footer_text, note, "; q += skonto
            q += " FROM invoice_documents WHERE tenant_id = \(bind: tenant) AND id = \(bind: source) RETURNING id"
            guard let row = try await s.raw(q).first() else { throw Abort(.internalServerError) }
            let id = try row.decode(column: "id", as: UUID.self)
            var lines: SQLQueryString = """
                INSERT INTO invoice_lines (tenant_id, document_id, position, kind, item_id, description, unit, quantity, second_quantity, unit_price, tax_rate, discount_kind, discount_value)
                SELECT tenant_id, \(bind: id), position, kind, item_id, description, unit, quantity *
                """
            lines += sign; lines += ", second_quantity, unit_price, tax_rate, discount_kind, CASE WHEN discount_kind = 'amount' THEN discount_value * "; lines += sign
            lines += " ELSE discount_value END FROM invoice_lines WHERE document_id = \(bind: source)"
            try await s.raw(lines).run()
            var charges: SQLQueryString = """
                INSERT INTO invoice_charges (tenant_id, document_id, position, description, tax_rate, amount) SELECT tenant_id, \(bind: id), position, description, tax_rate, amount *
                """
            charges += sign; charges += " FROM invoice_charges WHERE document_id = \(bind: source)"
            try await s.raw(charges).run()
            try await InvoiceDocuments.recalculate(id, tenant: tenant, on: s)
            try await s.raw("""
                INSERT INTO invoice_document_links (tenant_id, from_document_id, to_document_id, kind, created_by)
                VALUES (\(bind: tenant), \(bind: source), \(bind: id), \(bind: creditNote ? "credit_note" : "conversion"), \(bind: actor))
                """).run()
            try await AuditLog.record(AuditEvent(action: creditNote ? "invoice.document.credit_note_created" : "invoice.document.converted", actor: actor, tenant: tenant,
                                                 subjectType: "invoice.document", subjectID: id.uuidString, requestID: requestID), on: s)
            return try await InvoiceDocuments.fetch(id, tenant: tenant, on: s)
        }
    }

    // MARK: Prüfungen für Belege

    /// Die Art eines per Umwandlung oder Gutschrift erzeugten Entwurfs bleibt.
    static func checkKindChange(_ id: UUID, to kind: String, on s: any SQLDatabase) async throws {
        guard try await s.raw("""
            SELECT 1 AS x FROM invoice_documents d JOIN invoice_document_links l ON l.to_document_id = d.id AND l.kind <> 'reference'
            WHERE d.id = \(bind: id) AND d.kind <> \(bind: kind)
            """).first() == nil else { throw InvoiceError.invalid("document_type_id", "kind_locked") }
    }

    /// Beim Finalisieren einer verknüpften Gutschrift (vor der Nummernvergabe): negativ, gleiche Währung und gleicher Kontakt wie die Rechnung,
    /// zusammen mit früheren Gutschriften nie mehr als die Rechnung. Die Sperre der Rechnung serialisiert parallele Gutschriften und Zuordnungen.
    static func checkCreditNote(_ id: UUID, tenant: UUID, on s: any SQLDatabase) async throws {
        guard let link = try await s.raw("""
            SELECT from_document_id AS source FROM invoice_document_links WHERE tenant_id = \(bind: tenant) AND to_document_id = \(bind: id) AND kind = 'credit_note'
            """).first() else { return }
        let source = try link.decode(column: "source", as: UUID.self)
        _ = try await s.raw("SELECT 1 AS x FROM invoice_documents WHERE tenant_id = \(bind: tenant) AND id = \(bind: source) FOR UPDATE").first()
        guard let c = try await s.raw("""
            SELECT n.gross_total < 0 AS negative, n.currency = i.currency AS same_currency, n.contact_id = i.contact_id AS same_contact,
              i.gross_total + n.gross_total + (SELECT coalesce(sum(o.gross_total), 0) FROM invoice_document_links l JOIN invoice_documents o ON o.id = l.to_document_id
                 WHERE l.from_document_id = i.id AND l.kind = 'credit_note' AND o.status = 'final' AND o.id <> n.id) >= 0 AS within
            FROM invoice_documents n, invoice_documents i WHERE n.id = \(bind: id) AND i.id = \(bind: source)
            """).first() else { throw InvoiceError.notFound }
        guard try c.decode(column: "negative", as: Bool.self) else { throw InvoiceError.invalid("lines", "credit_must_be_negative") }
        guard try c.decode(column: "same_currency", as: Bool.self) else { throw InvoiceError.invalid("currency", "differs_from_invoice") }
        guard try c.decode(column: "same_contact", as: Bool.self) else { throw InvoiceError.invalid("contact_id", "differs_from_invoice") }
        guard try c.decode(column: "within", as: Bool.self) else { throw InvoiceError.invalid("lines", "credit_exceeds_invoice") }
    }

    // MARK: Verknüpfungen

    /// Verknüpfungen eines Belegs aus seiner Sicht (`direction`, Gegenbeleg).
    private static func rows(_ document: UUID, tenant: UUID, link: UUID? = nil, on s: any SQLDatabase) async throws -> [String] {
        var q: SQLQueryString = """
            SELECT jsonb_build_object('id', upper(l.id::text), 'kind', l.kind, 'direction', CASE WHEN l.from_document_id = \(bind: document) THEN 'outgoing' ELSE 'incoming' END,
              'created_at', l.created_at, 'document', jsonb_build_object('id', upper(d.id::text), 'kind', d.kind, 'status', d.status, 'number', d.number,
                'issue_date', d.issue_date::text, 'currency', d.currency, 'gross_total', round(d.gross_total, 2)::text))::text AS j
            FROM invoice_document_links l JOIN invoice_documents d ON d.id = CASE WHEN l.from_document_id = \(bind: document) THEN l.to_document_id ELSE l.from_document_id END
            WHERE l.tenant_id = \(bind: tenant) AND (l.from_document_id = \(bind: document) OR l.to_document_id = \(bind: document))
            """
        if let link { q += " AND l.id = \(bind: link)" }
        q += " ORDER BY l.created_at, l.id LIMIT 1000"
        return try await s.raw(q).all().map { try $0.decode(column: "j", as: String.self) }
    }

    private static func requireDocument(_ id: UUID, tenant: UUID, on s: any SQLDatabase) async throws {
        guard try await s.raw("SELECT 1 AS x FROM invoice_documents WHERE tenant_id = \(bind: tenant) AND id = \(bind: id)").first() != nil else { throw InvoiceError.notFound }
    }

    static func list(_ req: Request) async throws -> Response {
        let tenant = try req.requireTenant().tenantID, id = try InvoiceValidation.id(req), s = try sql(req.db)
        try await requireDocument(id, tenant: tenant, on: s)
        return invoiceJSONResponse("{\"items\":[" + (try await rows(id, tenant: tenant, on: s)).joined(separator: ",") + "]}", status: .ok)
    }

    static func create(_ req: Request) async throws -> Response {
        let tenant = try req.requireTenant().tenantID, actor = try req.requireAuth().user.id, requestID = req.requestId
        let id = try InvoiceValidation.id(req)
        let body = try InvoiceValidation.body(req)
        let out: String = try await invoiceTransaction(req.db) { s in
            try await requireDocument(id, tenant: tenant, on: s)
            if let first = Set(body.keys).subtracting(["target_id"]).sorted().first { throw InvoiceError.invalid(first, "unknown_field") }
            guard case .string(let raw)? = body["target_id"] else { throw InvoiceError.invalid("target_id", "required") }
            guard let target = UUID(uuidString: raw), target != id else { throw InvoiceError.invalid("target_id") }
            guard try await s.raw("SELECT 1 AS x FROM invoice_documents WHERE tenant_id = \(bind: tenant) AND id = \(bind: target)").first() != nil
            else { throw InvoiceError.invalid("target_id", "not_found") }
            guard let row = try await s.raw("""
                INSERT INTO invoice_document_links (tenant_id, from_document_id, to_document_id, kind, created_by)
                VALUES (\(bind: tenant), \(bind: id), \(bind: target), 'reference', \(bind: actor)) ON CONFLICT DO NOTHING RETURNING id
                """).first() else { throw InvoiceError.duplicate }
            let link = try row.decode(column: "id", as: UUID.self)
            try await AuditLog.record(AuditEvent(action: "invoice.link.created", actor: actor, tenant: tenant, subjectType: "invoice.link", subjectID: link.uuidString, requestID: requestID), on: s)
            guard let created = try await rows(id, tenant: tenant, link: link, on: s).first else { throw Abort(.internalServerError) }
            return created
        }
        return invoiceJSONResponse(out, status: .created)
    }

    static func delete(_ req: Request) async throws -> Response {
        let tenant = try req.requireTenant().tenantID, actor = try req.requireAuth().user.id, requestID = req.requestId
        let id = try InvoiceValidation.id(req)
        guard let link = req.parameters.get("link", as: UUID.self) else { throw InvoiceError.notFound }
        try await invoiceTransaction(req.db) { s in
            guard let row = try await s.raw("""
                SELECT kind FROM invoice_document_links WHERE tenant_id = \(bind: tenant) AND id = \(bind: link)
                  AND (from_document_id = \(bind: id) OR to_document_id = \(bind: id)) FOR UPDATE
                """).first() else { throw InvoiceError.notFound }
            guard try row.decode(column: "kind", as: String.self) == "reference" else { throw HubError(.conflict, "document_link_locked") }
            try await s.raw("DELETE FROM invoice_document_links WHERE tenant_id = \(bind: tenant) AND id = \(bind: link)").run()
            try await AuditLog.record(AuditEvent(action: "invoice.link.deleted", actor: actor, tenant: tenant, subjectType: "invoice.link", subjectID: link.uuidString, requestID: requestID), on: s)
        }
        return Response(status: .noContent)
    }
}
