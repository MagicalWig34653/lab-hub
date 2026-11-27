import Vapor
import Fluent
import SQLKit
import HubCore

// WP-R3: Zahlungen, ausdrückliche Zuordnung („nie still“) und Skonto. Eine Zahlung entsteht immer ohne Zuordnung; Vorschläge sind reine Abfragen.
// Gebucht wird ausschließlich mit `POST payments/{id}/allocations` und `confirmed: true`, mit Betrag und (falls gewährt) Skontobetrag aus der Anfrage:
// der Server leitet weder Beleg noch Betrag noch Skonto selbst ab. Sperrreihenfolge: Zahlung, dann Beleg. Beträge nur als Dezimal-Strings.

enum InvoicePayments {
    static let spec = InvoiceMasterSpec(segment: "payments", audit: "payment", table: "invoice_payments", fields: [
        .init(name: "amount", kind: .decimal(intDigits: 14, min: Decimal(string: "0.01"), max: nil), required: true), .init(name: "paid_on", kind: .date, required: true),
        .init(name: "currency", kind: .currency, defaultValue: .text("EUR")),
        .init(name: "method", kind: .oneOf(["bank_transfer", "cash", "card", "direct_debit", "other"]), defaultValue: .text("bank_transfer")),
        .init(name: "reference", kind: .text(max: 500)), .init(name: "note", kind: .text(max: 5000)), .init(name: "contact_id", kind: .ref(table: "contacts"))], order: "")

    // MARK: Salden (in der Datenbank gerechnet)

    /// Je finaler Rechnung: bezahlt, Skonto, Gutschriften (positiv), Restbetrag und höchstens zulässiges Skonto. Referenz: `balances.json`.
    static let balances = """
        SELECT d.*, p.paid, p.skonto, c.credited, d.gross_total - p.paid - p.skonto - c.credited AS remaining,
               round((d.gross_total - c.credited) * d.skonto_percent / 100, 2) AS skonto_max, d.issue_date + d.skonto_days AS skonto_deadline
        FROM invoice_documents d
        CROSS JOIN LATERAL (SELECT coalesce(sum(a.amount), 0) AS paid, coalesce(sum(a.skonto_amount), 0) AS skonto
                            FROM invoice_payment_allocations a WHERE a.document_id = d.id AND a.revoked_at IS NULL) p
        CROSS JOIN LATERAL (SELECT coalesce(-sum(n.gross_total), 0) AS credited FROM invoice_document_links l JOIN invoice_documents n ON n.id = l.to_document_id
                            WHERE l.from_document_id = d.id AND l.kind = 'credit_note' AND n.status = 'final') c
        """

    // MARK: Antwort-JSON

    private static let paymentJSON = """
        jsonb_build_object('id', upper(r.id::text), 'contact_id', upper(r.contact_id::text), 'paid_on', r.paid_on::text, 'amount', round(r.amount, 2)::text, 'currency', r.currency,
          'method', r.method, 'reference', r.reference, 'note', r.note, 'created_at', r.created_at, 'created_by', upper(r.created_by::text),
          'voided_at', r.voided_at, 'voided_by', upper(r.voided_by::text), 'void_reason', r.void_reason,
          'allocated', round(x.allocated, 2)::text, 'unallocated', round(CASE WHEN r.voided_at IS NULL THEN r.amount - x.allocated ELSE 0 END, 2)::text,
          'allocations', coalesce((SELECT jsonb_agg(jsonb_build_object('id', upper(a.id::text), 'document_id', upper(a.document_id::text), 'document_number', d.number,
              'amount', round(a.amount, 2)::text, 'skonto_amount', round(a.skonto_amount, 2)::text, 'overpayment', a.overpayment,
              'confirmed_at', a.confirmed_at, 'confirmed_by', upper(a.confirmed_by::text), 'revoked_at', a.revoked_at, 'revoked_by', upper(a.revoked_by::text))
              ORDER BY a.confirmed_at, a.id) FROM invoice_payment_allocations a JOIN invoice_documents d ON d.id = a.document_id WHERE a.payment_id = r.id), '[]'::jsonb))::text
        """
    private static let paymentFrom = """
        invoice_payments r CROSS JOIN LATERAL (SELECT coalesce(sum(amount), 0) AS allocated FROM invoice_payment_allocations WHERE payment_id = r.id AND revoked_at IS NULL) x
        """

    private static func fetch(_ id: UUID, tenant: UUID, on s: any SQLDatabase) async throws -> String {
        guard let row = try await s.raw("SELECT \(unsafeRaw: paymentJSON) AS j FROM \(unsafeRaw: paymentFrom) WHERE r.tenant_id = \(bind: tenant) AND r.id = \(bind: id)").first()
        else { throw InvoiceError.notFound }
        return try row.decode(column: "j", as: String.self)
    }

    /// Sperrt die Zahlung; Rückgabe: storniert?
    private static func lock(_ id: UUID, tenant: UUID, on s: any SQLDatabase) async throws -> Bool {
        guard let row = try await s.raw("SELECT voided_at IS NOT NULL AS voided FROM invoice_payments WHERE tenant_id = \(bind: tenant) AND id = \(bind: id) FOR UPDATE").first()
        else { throw InvoiceError.notFound }
        return try row.decode(column: "voided", as: Bool.self)
    }

    private static func onlyKeys(_ body: [String: InvoiceJSON], _ allowed: Set<String>) throws {
        if let first = Set(body.keys).subtracting(allowed).sorted().first { throw InvoiceError.invalid(first, "unknown_field") }
    }

    /// Geldbetrag der Anfrage: Dezimal-String mit höchstens 2 Nachkommastellen.
    private static func money(_ body: [String: InvoiceJSON], _ field: String, min: Decimal) throws -> Decimal? {
        guard let raw = body[field], raw != .null else { return nil }
        guard case .string(let t) = raw, InvoiceValidation.decimal(t, intDigits: 14, min: min, max: nil) != nil, let d = InvoiceDecimal.parse(t),
              InvoiceRounding.default.apply(d) == d else { throw InvoiceError.invalid(field) }
        return d
    }

    // MARK: Routen

    static func list(_ req: Request) async throws -> Response {
        let tenant = try req.requireTenant().tenantID
        var q: SQLQueryString = "SELECT \(unsafeRaw: paymentJSON) AS j FROM \(unsafeRaw: paymentFrom) WHERE r.tenant_id = \(bind: tenant)"
        if let raw: String = req.query["unassigned"] {
            guard raw == "true" || raw == "false" else { throw InvoiceError.invalid("unassigned") }
            q += raw == "true" ? " AND r.voided_at IS NULL AND r.amount > x.allocated" : " AND (r.voided_at IS NOT NULL OR r.amount <= x.allocated)"
        }
        if let contact: String = req.query["contact_id"] {
            guard let id = UUID(uuidString: contact) else { throw InvoiceError.invalid("contact_id") }
            q += " AND r.contact_id = \(bind: id)"
        }
        q += " ORDER BY r.created_at DESC, r.id LIMIT 1000"
        let rows = try await sql(req.db).raw(q).all().map { try $0.decode(column: "j", as: String.self) }
        return invoiceJSONResponse("{\"items\":[" + rows.joined(separator: ",") + "]}", status: .ok)
    }

    static func get(_ req: Request) async throws -> Response {
        let tenant = try req.requireTenant().tenantID, id = try InvoiceValidation.id(req)
        return invoiceJSONResponse(try await fetch(id, tenant: tenant, on: try sql(req.db)), status: .ok)
    }

    static func create(_ req: Request) async throws -> Response {
        let tenant = try req.requireTenant().tenantID, actor = try req.requireAuth().user.id, requestID = req.requestId
        let body = try InvoiceValidation.body(req)
        return try await InvoiceIdempotency.run(req, tenant: tenant) { s in
            let v = try await spec.checked(body, requireAll: true, tenant: tenant, on: s)
            _ = try money(body, "amount", min: 0)
            if case .uuid(let contact)? = v["contact_id"] {
                guard try await s.raw("SELECT 1 AS x FROM contacts WHERE tenant_id = \(bind: tenant) AND id = \(bind: contact) AND deleted_at IS NULL AND merged_into IS NULL").first() != nil
                else { throw InvoiceError.invalid("contact_id", "not_found") }
            }
            var columns = ["tenant_id", "created_by", "currency"]
            var values: [SQLQueryString] = ["\(bind: tenant)", "\(bind: actor)",
                v["currency"].map { $0.sql } ?? "COALESCE((SELECT currency FROM invoice_settings WHERE tenant_id = \(bind: tenant)), 'EUR')"]
            for f in spec.fields where f.name != "currency" { if let value = v[f.name], value != .null { columns.append(f.name); values.append(value.sql) } }
            var q: SQLQueryString = "INSERT INTO invoice_payments (\(unsafeRaw: columns.joined(separator: ", "))) VALUES ("
            for (i, value) in values.enumerated() { if i > 0 { q += ", " }; q += value }
            q += ") RETURNING id"
            guard let row = try await s.raw(q).first() else { throw Abort(.internalServerError) }
            let id = try row.decode(column: "id", as: UUID.self)
            try await AuditLog.record(AuditEvent(action: "invoice.payment.created", actor: actor, tenant: tenant, subjectType: "invoice.payment", subjectID: id.uuidString, requestID: requestID), on: s)
            return try await fetch(id, tenant: tenant, on: s)
        }
    }

    /// Vorschläge zur Zuordnung: nur Lesen, jeder mit Begründung. Ohne Begründung kein Vorschlag.
    static func suggestions(_ req: Request) async throws -> Response {
        let tenant = try req.requireTenant().tenantID, id = try InvoiceValidation.id(req), s = try sql(req.db)
        guard try await s.raw("SELECT 1 AS x FROM invoice_payments WHERE tenant_id = \(bind: tenant) AND id = \(bind: id)").first() != nil else { throw InvoiceError.notFound }
        let rows = try await s.raw("""
            WITH p AS (SELECT r.*, r.amount - x.allocated AS free FROM \(unsafeRaw: paymentFrom) WHERE r.tenant_id = \(bind: tenant) AND r.id = \(bind: id) AND r.voided_at IS NULL),
            c AS (SELECT b.id, b.number, b.issue_date, b.contact_id, b.remaining, b.skonto_max, p.free,
                    coalesce(p.reference ~* ('(^|[^[:alnum:]])' || regexp_replace(b.number, '([^[:alnum:]])', '\\\\\\1', 'g') || '($|[^[:alnum:]])'), false) AS by_number,
                    p.free = b.remaining AS by_amount,
                    coalesce(p.paid_on <= b.skonto_deadline AND b.skonto_max > 0 AND p.free = b.remaining - b.skonto_max, false) AS by_skonto,
                    coalesce(p.contact_id = b.contact_id, false) AS by_contact
                  FROM p JOIN (\(unsafeRaw: balances)) b ON b.tenant_id = p.tenant_id AND b.currency = p.currency AND b.status = 'final' AND b.kind = 'invoice'
                  WHERE p.free > 0 AND b.remaining > 0 AND NOT EXISTS (SELECT 1 FROM invoice_payment_allocations a WHERE a.payment_id = p.id AND a.document_id = b.id AND a.revoked_at IS NULL))
            SELECT jsonb_build_object('document_id', upper(c.id::text), 'document_number', c.number, 'open_amount', round(c.remaining, 2)::text,
                'amount', round(CASE WHEN c.by_skonto THEN c.free ELSE LEAST(c.free, c.remaining) END, 2)::text,
                'skonto_amount', round(CASE WHEN c.by_skonto THEN c.skonto_max ELSE 0 END, 2)::text,
                'reasons', to_jsonb(array_remove(ARRAY[CASE WHEN c.by_number THEN 'number_in_reference' END, CASE WHEN c.by_amount THEN 'amount_matches_open' END,
                    CASE WHEN c.by_skonto THEN 'amount_matches_skonto' END, CASE WHEN c.by_contact THEN 'same_contact' END], NULL)))::text AS j
            FROM c WHERE c.by_number OR c.by_amount OR c.by_skonto OR c.by_contact
            ORDER BY c.by_number::int * 4 + (c.by_amount OR c.by_skonto)::int * 2 + c.by_contact::int DESC, c.issue_date, c.number, c.id LIMIT 20
            """).all().map { try $0.decode(column: "j", as: String.self) }
        return invoiceJSONResponse("{\"items\":[" + rows.joined(separator: ",") + "]}", status: .ok)
    }

    static func allocate(_ req: Request) async throws -> Response {
        let tenant = try req.requireTenant().tenantID, actor = try req.requireAuth().user.id, requestID = req.requestId
        let id = try InvoiceValidation.id(req)
        let body = try InvoiceValidation.body(req)
        return try await InvoiceIdempotency.run(req, tenant: tenant) { s in
            let voided = try await lock(id, tenant: tenant, on: s)
            try onlyKeys(body, ["document_id", "amount", "skonto_amount", "overpayment", "confirmed"])
            guard body["confirmed"] == .bool(true) else { throw InvoiceError.invalid("confirmed", "required") }
            guard case .string(let rawDocument)? = body["document_id"] else { throw InvoiceError.invalid("document_id", "required") }
            guard let document = UUID(uuidString: rawDocument) else { throw InvoiceError.invalid("document_id") }
            guard let amount = try money(body, "amount", min: Decimal(string: "0.01")!) else { throw InvoiceError.invalid("amount", "required") }
            let skonto = try money(body, "skonto_amount", min: 0) ?? 0
            var overpayment = false
            if let raw = body["overpayment"], raw != .null { guard case .bool(let flag) = raw else { throw InvoiceError.invalid("overpayment") }; overpayment = flag }
            if voided { throw HubError(.conflict, "payment_voided") }

            guard let doc = try await s.raw("SELECT kind, status, currency FROM invoice_documents WHERE tenant_id = \(bind: tenant) AND id = \(bind: document) FOR UPDATE").first()
            else { throw InvoiceError.invalid("document_id", "not_found") }
            guard try doc.decode(column: "kind", as: String.self) == "invoice" else { throw InvoiceError.invalid("document_id", "not_an_invoice") }
            guard try doc.decode(column: "status", as: String.self) == "final" else { throw HubError(.conflict, "document_not_final") }

            let a = InvoiceValue.decimal(InvoiceDecimal.string(amount, scale: 2)).sql, k = InvoiceValue.decimal(InvoiceDecimal.string(skonto, scale: 2)).sql
            var q: SQLQueryString = "SELECT p.currency = b.currency AS same_currency, "
            q += "EXISTS (SELECT 1 FROM invoice_payment_allocations x WHERE x.payment_id = p.id AND x.document_id = b.id AND x.revoked_at IS NULL) AS duplicate, "
            q += "(SELECT coalesce(sum(amount), 0) FROM invoice_payment_allocations x WHERE x.payment_id = p.id AND x.revoked_at IS NULL) + "; q += a
            q += " > p.amount AS over_payment, b.skonto_percent IS NOT NULL AS has_terms, coalesce(p.paid_on <= b.skonto_deadline, false) AS in_time, "
            q += "coalesce("; q += k; q += " <= b.skonto_max, false) AS within_terms, "; q += a; q += " + "; q += k; q += " = b.remaining AS settles, "
            q += a; q += " + "; q += k; q += " > b.remaining AS over_invoice FROM invoice_payments p, (\(unsafeRaw: balances)) b "
            q += "WHERE p.id = \(bind: id) AND b.id = \(bind: document)"
            guard let c = try await s.raw(q).first() else { throw Abort(.internalServerError) }
            func flag(_ column: String) throws -> Bool { try c.decode(column: column, as: Bool.self) }
            guard try flag("same_currency") else { throw InvoiceError.invalid("document_id", "currency_mismatch") }
            if try flag("duplicate") { throw InvoiceError.duplicate }
            if try flag("over_payment") { throw InvoiceError.invalid("amount", "exceeds_payment") }
            if skonto > 0 {
                guard try flag("has_terms") else { throw InvoiceError.invalid("skonto_amount", "skonto_not_allowed") }
                guard try flag("in_time") else { throw InvoiceError.invalid("skonto_amount", "skonto_period_expired") }
                guard try flag("within_terms") else { throw InvoiceError.invalid("skonto_amount", "skonto_exceeds_terms") }
                guard try flag("settles") else { throw InvoiceError.invalid("skonto_amount", "skonto_must_settle") }
            }
            let exceeds = try flag("over_invoice")
            if exceeds, !overpayment { throw InvoiceError.invalid("amount", "exceeds_open_amount") }

            var i: SQLQueryString = "INSERT INTO invoice_payment_allocations (tenant_id, payment_id, document_id, amount, skonto_amount, overpayment, confirmed_by) VALUES (\(bind: tenant), \(bind: id), \(bind: document), "
            i += a; i += ", "; i += k; i += ", \(bind: exceeds), \(bind: actor)) RETURNING id"
            guard let row = try await s.raw(i).first() else { throw Abort(.internalServerError) }
            try await AuditLog.record(AuditEvent(action: "invoice.payment.allocated", actor: actor, tenant: tenant, subjectType: "invoice.payment_allocation",
                                                 subjectID: try row.decode(column: "id", as: UUID.self).uuidString, requestID: requestID), on: s)
            return try await fetch(id, tenant: tenant, on: s)
        }
    }

    /// Zuordnung zurücknehmen (bleibt in der Historie).
    static func revoke(_ req: Request) async throws -> Response {
        let tenant = try req.requireTenant().tenantID, actor = try req.requireAuth().user.id, requestID = req.requestId
        let id = try InvoiceValidation.id(req)
        guard let allocation = req.parameters.get("allocation", as: UUID.self) else { throw InvoiceError.notFound }
        let out: String = try await invoiceTransaction(req.db) { s in
            _ = try await lock(id, tenant: tenant, on: s)
            guard try await s.raw("""
                UPDATE invoice_payment_allocations SET revoked_at = now(), revoked_by = \(bind: actor)
                WHERE tenant_id = \(bind: tenant) AND payment_id = \(bind: id) AND id = \(bind: allocation) AND revoked_at IS NULL RETURNING id
                """).first() != nil else { throw InvoiceError.notFound }
            try await AuditLog.record(AuditEvent(action: "invoice.payment.allocation_revoked", actor: actor, tenant: tenant, subjectType: "invoice.payment_allocation", subjectID: allocation.uuidString, requestID: requestID), on: s)
            return try await fetch(id, tenant: tenant, on: s)
        }
        return invoiceJSONResponse(out, status: .ok)
    }

    /// Fehlbuchung stornieren; erst nachdem alle Zuordnungen ausdrücklich zurückgenommen wurden.
    static func void(_ req: Request) async throws -> Response {
        let tenant = try req.requireTenant().tenantID, actor = try req.requireAuth().user.id, requestID = req.requestId
        let id = try InvoiceValidation.id(req)
        let body = try InvoiceValidation.body(req)
        let out: String = try await invoiceTransaction(req.db) { s in
            let voided = try await lock(id, tenant: tenant, on: s)
            try onlyKeys(body, ["reason"])
            guard case .string(let raw)? = body["reason"], !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw InvoiceError.invalid("reason", "required") }
            let reason = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard reason.unicodeScalars.count <= 500 else { throw InvoiceError.invalid("reason", "too_long") }
            if voided { throw HubError(.conflict, "payment_voided") }
            guard try await s.raw("SELECT 1 AS x FROM invoice_payment_allocations WHERE payment_id = \(bind: id) AND revoked_at IS NULL LIMIT 1").first() == nil
            else { throw HubError(.conflict, "payment_allocated") }
            try await s.raw("UPDATE invoice_payments SET voided_at = now(), voided_by = \(bind: actor), void_reason = \(bind: reason) WHERE tenant_id = \(bind: tenant) AND id = \(bind: id)").run()
            try await AuditLog.record(AuditEvent(action: "invoice.payment.voided", actor: actor, tenant: tenant, subjectType: "invoice.payment", subjectID: id.uuidString, requestID: requestID), on: s)
            return try await fetch(id, tenant: tenant, on: s)
        }
        return invoiceJSONResponse(out, status: .ok)
    }

    /// Saldo einer finalen Rechnung.
    static func balance(_ req: Request) async throws -> Response {
        let tenant = try req.requireTenant().tenantID, id = try InvoiceValidation.id(req), s = try sql(req.db)
        guard let doc = try await s.raw("SELECT kind, status FROM invoice_documents WHERE tenant_id = \(bind: tenant) AND id = \(bind: id)").first() else { throw InvoiceError.notFound }
        guard try doc.decode(column: "status", as: String.self) == "final" else { throw HubError(.conflict, "document_not_final") }
        guard try doc.decode(column: "kind", as: String.self) == "invoice" else { throw InvoiceError.invalid("id", "not_an_invoice") }
        guard let row = try await s.raw("""
            SELECT jsonb_build_object('document_id', upper(b.id::text), 'currency', b.currency, 'gross_total', round(b.gross_total, 2)::text, 'paid', round(b.paid, 2)::text,
              'skonto', round(b.skonto, 2)::text, 'credited', round(b.credited, 2)::text, 'open_balance', round(b.gross_total - b.paid - b.skonto, 2)::text,
              'total_balance', round(b.remaining, 2)::text,
              'payment_status', CASE WHEN b.remaining < 0 THEN 'overpaid' WHEN b.remaining = 0 THEN 'settled' WHEN b.paid + b.skonto + b.credited > 0 THEN 'partial' ELSE 'open' END,
              'skonto_terms', CASE WHEN b.skonto_percent IS NULL THEN NULL ELSE jsonb_build_object('percent', b.skonto_percent::text, 'days', b.skonto_days,
                  'deadline', b.skonto_deadline::text, 'amount', b.skonto_max::numeric(18,2)::text) END,
              'allocations', coalesce((SELECT jsonb_agg(jsonb_build_object('id', upper(a.id::text), 'payment_id', upper(a.payment_id::text), 'paid_on', p.paid_on::text,
                  'amount', round(a.amount, 2)::text, 'skonto_amount', round(a.skonto_amount, 2)::text, 'overpayment', a.overpayment, 'confirmed_at', a.confirmed_at,
                  'confirmed_by', upper(a.confirmed_by::text)) ORDER BY p.paid_on, a.confirmed_at, a.id)
                  FROM invoice_payment_allocations a JOIN invoice_payments p ON p.id = a.payment_id WHERE a.document_id = b.id AND a.revoked_at IS NULL), '[]'::jsonb),
              'credit_notes', coalesce((SELECT jsonb_agg(jsonb_build_object('id', upper(n.id::text), 'number', n.number, 'gross_total', round(n.gross_total, 2)::text) ORDER BY n.number)
                  FROM invoice_document_links l JOIN invoice_documents n ON n.id = l.to_document_id
                  WHERE l.from_document_id = b.id AND l.kind = 'credit_note' AND n.status = 'final'), '[]'::jsonb))::text AS j
            FROM (\(unsafeRaw: balances)) b WHERE b.tenant_id = \(bind: tenant) AND b.id = \(bind: id)
            """).first() else { throw InvoiceError.notFound }
        return invoiceJSONResponse(try row.decode(column: "j", as: String.self), status: .ok)
    }
}
