import Vapor
import Fluent
import SQLKit
import HubCore

// WP-R2: Belege des Rechnungsmoduls. Entwurf anlegen/ändern/löschen (Summen rechnet immer der Server mit `InvoiceCalculator`, nie der Client),
// Finalisieren in EINER Transaktion: Beleg sperren, Nummer aus dem Hub-Zähler (`CounterService`, Schlüssel der Serie), Absender und Empfänger einfrieren,
// Inhaltshash, Status `final`. Scheitert irgendein Schritt, rollt die Transaktion den Zähler mit zurück (keine Lücke). Danach ist der Beleg
// in der Datenbank unveränderlich (Trigger, `InvoiceDocumentMigrations.swift`). Beträge nur als Dezimal-Strings, Antworten entstehen in der Datenbank.

enum InvoiceDocuments {
    static let immutable = HubError(.conflict, "document_final_immutable")

    // MARK: Spezifikationen der Eingabe

    static let headerSpec = InvoiceMasterSpec(segment: "documents", audit: "document", table: "invoice_documents", fields: [
        .init(name: "document_type_id", kind: .ref(table: "invoice_document_types"), required: true),
        .init(name: "contact_id", kind: .ref(table: "contacts")), .init(name: "series_id", kind: .ref(table: "invoice_series")),
        .init(name: "issue_date", kind: .date), .init(name: "due_date", kind: .date), .init(name: "delivery_date", kind: .date),
        .init(name: "currency", kind: .currency, defaultValue: .text("EUR")),
        .init(name: "price_mode", kind: .oneOf(["net", "gross"]), defaultValue: .text("net")),
        .init(name: "discount_percent", kind: .decimal(intDigits: 3, min: 0, max: 100), defaultValue: .decimal("0")),
        .init(name: "discount_amount", kind: .decimal(intDigits: 14, min: nil, max: nil)),
        .init(name: "rounding_mode", kind: .oneOf(InvoiceRounding.Mode.allCases.map(\.rawValue)), defaultValue: .text("halfAwayFromZero")),
        .init(name: "header_text", kind: .text(max: 5000)), .init(name: "footer_text", kind: .text(max: 5000)), .init(name: "note", kind: .text(max: 5000)),
        // WP-R3: Skontobedingung, nur gemeinsam (Satz und Frist ab Belegdatum)
        .init(name: "skonto_percent", kind: .decimal(intDigits: 2, min: Decimal(string: "0.0001"), max: nil)), .init(name: "skonto_days", kind: .int(0...365))], order: "")

    static let lineSpec = InvoiceMasterSpec(segment: "lines", audit: "line", table: "invoice_lines", fields: [
        .init(name: "kind", kind: .oneOf(["item", "text"]), required: true), .init(name: "item_id", kind: .ref(table: "invoice_items")),
        .init(name: "description", kind: .text(max: 5000), required: true), .init(name: "unit", kind: .text(max: 20)),
        .init(name: "quantity", kind: .decimal(intDigits: 14, min: nil, max: nil)), .init(name: "second_quantity", kind: .decimal(intDigits: 14, min: nil, max: nil)),
        .init(name: "unit_price", kind: .decimal(intDigits: 14, min: nil, max: nil)), .init(name: "tax_rate", kind: .decimal(intDigits: 3, min: 0, max: 100)),
        .init(name: "discount_kind", kind: .oneOf(["percent", "amount"])), .init(name: "discount_value", kind: .decimal(intDigits: 14, min: nil, max: nil))], order: "")

    static let chargeSpec = InvoiceMasterSpec(segment: "charges", audit: "charge", table: "invoice_charges", fields: [
        .init(name: "description", kind: .text(max: 200), required: true), .init(name: "tax_rate", kind: .decimal(intDigits: 3, min: 0, max: 100), required: true),
        .init(name: "amount", kind: .decimal(intDigits: 14, min: nil, max: nil), required: true)], order: "")

    static let maxLines = 500, maxCharges = 50
    /// Obergrenze der Summen (numeric(18,4) mit Reserve): größere Beträge sind ungültig statt Datenbankfehler.
    static let amountLimit = Decimal(string: "100000000000000")!

    /// Positionen und Zusatzkosten (Arrays); fehlt der Schlüssel, bleiben die gespeicherten unverändert.
    struct Children: Decodable { let lines: [[String: InvoiceJSON]]?; let charges: [[String: InvoiceJSON]]? }

    // MARK: Antwort-JSON (entsteht in der Datenbank)

    private static let headPairs = """
        'id', upper(r.id::text), 'document_type_id', upper(r.document_type_id::text), 'kind', r.kind, 'contact_id', upper(r.contact_id::text),
        'issue_date', r.issue_date::text, 'due_date', r.due_date::text, 'delivery_date', r.delivery_date::text, 'currency', r.currency, 'price_mode', r.price_mode,
        'discount_percent', r.discount_percent::text, 'discount_amount', r.discount_amount::text, 'rounding_mode', r.rounding_mode,
        'header_text', r.header_text, 'footer_text', r.footer_text, 'note', r.note,
        'net_total', round(r.net_total, 2)::text, 'tax_total', round(r.tax_total, 2)::text, 'gross_total', round(r.gross_total, 2)::text, 'discount_total', round(r.discount_total, 2)::text
        """
    private static let childPairs = """
        'lines', coalesce((SELECT jsonb_agg(jsonb_build_object('id', upper(l.id::text), 'position', l.position, 'kind', l.kind, 'item_id', upper(l.item_id::text),
            'description', l.description, 'unit', l.unit, 'quantity', l.quantity::text, 'second_quantity', l.second_quantity::text, 'unit_price', l.unit_price::text,
            'tax_rate', l.tax_rate::text, 'discount_kind', l.discount_kind, 'discount_value', l.discount_value::text) ORDER BY l.position)
            FROM invoice_lines l WHERE l.document_id = r.id), '[]'::jsonb),
        'charges', coalesce((SELECT jsonb_agg(jsonb_build_object('id', upper(c.id::text), 'position', c.position, 'description', c.description,
            'tax_rate', c.tax_rate::text, 'amount', c.amount::text) ORDER BY c.position) FROM invoice_charges c WHERE c.document_id = r.id), '[]'::jsonb),
        'tax_totals', coalesce((SELECT jsonb_agg(jsonb_build_object('rate', t.rate::text, 'net', round(t.net, 2)::text, 'tax', round(t.tax, 2)::text, 'gross', round(t.gross, 2)::text)
            ORDER BY t.rate) FROM invoice_tax_totals t WHERE t.document_id = r.id), '[]'::jsonb)
        """
    private static let metaPairs = """
        'status', r.status, 'series_id', upper(r.series_id::text), 'number', r.number, 'counter_value', r.counter_value, 'tax_regime', r.tax_regime,
        'sender', r.sender, 'recipient', r.recipient, 'content_hash', r.content_hash, 'finalized_at', r.finalized_at, 'finalized_by', upper(r.finalized_by::text),
        'rev', r.rev, 'created_at', r.created_at, 'updated_at', r.updated_at, 'skonto_percent', r.skonto_percent::text, 'skonto_days', r.skonto_days
        """
    /// Inhalt des Belegs (Kopf, Positionen, Zusatzkosten, Steuersummen) ohne Metadaten: Grundlage des Inhaltshashs.
    /// Die Skontobedingung (WP-R3) steht nur dann im Inhalt, wenn sie gesetzt ist: Hashes älterer Belege bleiben nachrechenbar.
    static let contentJSON = "(jsonb_build_object(\(headPairs)) || jsonb_build_object(\(childPairs)) || jsonb_strip_nulls(jsonb_build_object('skonto_percent', r.skonto_percent::text, 'skonto_days', r.skonto_days)))"
    static let fullJSON = "(\(contentJSON) || jsonb_build_object(\(metaPairs)))::text"
    static let listJSON = "(jsonb_build_object(\(headPairs)) || jsonb_build_object(\(metaPairs)))::text"

    static func fetch(_ id: UUID, tenant: UUID, on s: any SQLDatabase) async throws -> String {
        guard let row = try await s.raw("SELECT \(unsafeRaw: fullJSON) AS j FROM invoice_documents r WHERE r.tenant_id = \(bind: tenant) AND r.id = \(bind: id)").first()
        else { throw InvoiceError.notFound }
        return try row.decode(column: "j", as: String.self)
    }

    // MARK: Prüfung der Eingabe

    private static func code(_ e: any Error) -> String { (e as? HubError)?.errors.first?.code ?? "invalid" }

    /// Eine Zeile (Position oder Zusatzkosten) prüfen; Feldnamen der Fehler als `lines.0.quantity`.
    private static func checkedRow(_ spec: InvoiceMasterSpec, _ raw: [String: InvoiceJSON], prefix: String, tenant: UUID, on s: any SQLDatabase) async throws -> [String: InvoiceValue] {
        if let first = Set(raw.keys).subtracting(spec.fields.map(\.name)).sorted().first { throw InvoiceError.invalid("\(prefix).\(first)", "unknown_field") }
        var out: [String: InvoiceValue] = [:]
        for f in spec.fields {
            guard let value = raw[f.name] else { continue }
            do { out[f.name] = try await spec.validate(f, value, tenant: tenant, on: s) } catch { throw InvoiceError.invalid("\(prefix).\(f.name)", code(error)) }
        }
        return out
    }

    private static func present(_ v: [String: InvoiceValue], _ key: String) -> Bool { (v[key] ?? .null) != .null }

    /// Skontosatz und -frist gibt es nur zusammen; `stored` sind die bisherigen Werte des Entwurfs.
    private static func checkSkonto(_ v: [String: InvoiceValue], stored: (percent: Bool, days: Bool) = (false, false)) throws {
        let percent = v["skonto_percent"].map { $0 != .null } ?? stored.percent, days = v["skonto_days"].map { $0 != .null } ?? stored.days
        if percent != days { throw InvoiceError.invalid(percent ? "skonto_days" : "skonto_percent", "required_together") }
    }

    static func checkedLines(_ rows: [[String: InvoiceJSON]], tenant: UUID, on s: any SQLDatabase) async throws -> [[String: InvoiceValue]] {
        guard rows.count <= maxLines else { throw InvoiceError.invalid("lines", "too_many") }
        var out: [[String: InvoiceValue]] = []
        for (i, raw) in rows.enumerated() {
            let p = "lines.\(i)"
            let v = try await checkedRow(lineSpec, raw, prefix: p, tenant: tenant, on: s)
            guard case .text(let kind)? = v["kind"] else { throw InvoiceError.invalid("\(p).kind", "required") }
            guard present(v, "description") else { throw InvoiceError.invalid("\(p).description", "required") }
            let itemOnly = ["quantity", "second_quantity", "unit_price", "tax_rate", "discount_kind", "discount_value"]
            if kind == "item" {
                for k in ["quantity", "unit_price", "tax_rate"] where !present(v, k) { throw InvoiceError.invalid("\(p).\(k)", "required") }
            } else {
                for k in itemOnly where present(v, k) { throw InvoiceError.invalid("\(p).\(k)", "not_allowed") }
            }
            if present(v, "discount_kind") != present(v, "discount_value") { throw InvoiceError.invalid("\(p).discount_value", "required_together") }
            if case .text("percent")? = v["discount_kind"], case .decimal(let d)? = v["discount_value"], let n = InvoiceDecimal.parse(d), n < 0 || n > 100 {
                throw InvoiceError.invalid("\(p).discount_value", "out_of_range")
            }
            out.append(v)
        }
        return out
    }

    static func checkedCharges(_ rows: [[String: InvoiceJSON]], tenant: UUID, on s: any SQLDatabase) async throws -> [[String: InvoiceValue]] {
        guard rows.count <= maxCharges else { throw InvoiceError.invalid("charges", "too_many") }
        var out: [[String: InvoiceValue]] = []
        for (i, raw) in rows.enumerated() {
            let v = try await checkedRow(chargeSpec, raw, prefix: "charges.\(i)", tenant: tenant, on: s)
            for f in chargeSpec.fields where !present(v, f.name) { throw InvoiceError.invalid("charges.\(i).\(f.name)", "required") }
            out.append(v)
        }
        return out
    }

    /// Kontakt muss lebendig sein (nicht gelöscht, nicht in einen anderen zusammengeführt); Mandant prüft die Referenz (`ref`) und die Datenbank.
    private static func checkContact(_ v: [String: InvoiceValue], tenant: UUID, on s: any SQLDatabase) async throws {
        guard case .uuid(let id)? = v["contact_id"] else { return }
        guard try await s.raw("SELECT 1 AS x FROM contacts WHERE tenant_id = \(bind: tenant) AND id = \(bind: id) AND deleted_at IS NULL AND merged_into IS NULL").first() != nil
        else { throw InvoiceError.invalid("contact_id", "not_found") }
    }

    private static func typeKind(_ v: [String: InvoiceValue], tenant: UUID, on s: any SQLDatabase) async throws -> String? {
        guard case .uuid(let id)? = v["document_type_id"] else { return nil }
        guard let row = try await s.raw("SELECT kind, active FROM invoice_document_types WHERE tenant_id = \(bind: tenant) AND id = \(bind: id)").first() else { throw InvoiceError.invalid("document_type_id", "not_found") }
        guard try row.decode(column: "active", as: Bool.self) else { throw InvoiceError.invalid("document_type_id", "inactive") }
        return try row.decode(column: "kind", as: String.self)
    }

    private static func children(_ req: Request, _ body: [String: InvoiceJSON]) throws -> Children {
        for key in ["lines", "charges"] where body[key] == .null { throw InvoiceError.invalid(key) }
        guard let c = try? req.content.decode(Children.self) else {
            throw InvoiceError.invalid(body["lines"] == .other || body["lines"] == nil ? "charges" : "lines")
        }
        return c
    }

    // MARK: Schreiben der Kinder und Berechnung

    private static func binds(_ v: [String: InvoiceValue], _ keys: [String]) -> [SQLQueryString] { keys.map { (v[$0] ?? .null).sql } }

    private static func replaceChildren(_ id: UUID, tenant: UUID, lines: [[String: InvoiceValue]]?, charges: [[String: InvoiceValue]]?, on s: any SQLDatabase) async throws {
        if let lines {
            try await s.raw("DELETE FROM invoice_lines WHERE document_id = \(bind: id)").run()
            for (i, v) in lines.enumerated() {
                var q: SQLQueryString = "INSERT INTO invoice_lines (tenant_id, document_id, position, kind, item_id, description, unit, quantity, second_quantity, unit_price, tax_rate, discount_kind, discount_value) VALUES (\(bind: tenant), \(bind: id), \(bind: i + 1)"
                for b in binds(v, ["kind", "item_id", "description", "unit", "quantity", "second_quantity", "unit_price", "tax_rate", "discount_kind", "discount_value"]) { q += ", "; q += b }
                q += ")"
                try await s.raw(q).run()
            }
        }
        if let charges {
            try await s.raw("DELETE FROM invoice_charges WHERE document_id = \(bind: id)").run()
            for (i, v) in charges.enumerated() {
                var q: SQLQueryString = "INSERT INTO invoice_charges (tenant_id, document_id, position, description, tax_rate, amount) VALUES (\(bind: tenant), \(bind: id), \(bind: i + 1)"
                for b in binds(v, ["description", "tax_rate", "amount"]) { q += ", "; q += b }
                q += ")"
                try await s.raw(q).run()
            }
        }
    }

    private static func dec(_ row: any SQLRow, _ column: String) throws -> Decimal? {
        guard let text = try row.decode(column: column, as: String?.self) else { return nil }
        guard let d = InvoiceDecimal.parse(text) else { throw Abort(.internalServerError) }
        return d
    }

    /// Rechnet den Entwurf aus den gespeicherten Zeilen neu (Server ist die einzige Quelle der Summen) und schreibt Summen und Steuersummen.
    static func recalculate(_ id: UUID, tenant: UUID, on s: any SQLDatabase) async throws {
        guard let head = try await s.raw("""
            SELECT price_mode, rounding_mode, discount_percent::text AS dp, discount_amount::text AS da FROM invoice_documents WHERE tenant_id = \(bind: tenant) AND id = \(bind: id)
            """).first() else { throw InvoiceError.notFound }
        let mode = InvoiceCalculator.PriceMode(rawValue: try head.decode(column: "price_mode", as: String.self)) ?? .net
        let rounding = InvoiceRounding(mode: InvoiceRounding.Mode(rawValue: try head.decode(column: "rounding_mode", as: String.self)) ?? .halfAwayFromZero, scale: 2)
        var lines: [InvoiceCalculator.Line] = []
        for r in try await s.raw("""
            SELECT tax_rate::text AS tr, unit_price::text AS up, quantity::text AS q, second_quantity::text AS q2, discount_kind AS dk, discount_value::text AS dv
            FROM invoice_lines WHERE document_id = \(bind: id) AND kind = 'item' ORDER BY position
            """).all() {
            var discount: InvoiceCalculator.Discount?
            if let kind = try r.decode(column: "dk", as: String?.self), let value = try dec(r, "dv") { discount = kind == "percent" ? .percent(value) : .amount(value) }
            lines.append(.init(taxRate: try dec(r, "tr") ?? 0, unitPrice: try dec(r, "up") ?? 0, quantity: try dec(r, "q") ?? 0, secondQuantity: try dec(r, "q2"), discount: discount))
        }
        var charges: [InvoiceCalculator.Charge] = []
        for r in try await s.raw("SELECT tax_rate::text AS tr, amount::text AS a FROM invoice_charges WHERE document_id = \(bind: id) ORDER BY position").all() {
            charges.append(.init(taxRate: try dec(r, "tr") ?? 0, amount: try dec(r, "a") ?? 0))
        }
        let result = InvoiceCalculator.calculate(.init(priceMode: mode, lines: lines, charges: charges, documentDiscountPercent: try dec(head, "dp") ?? 0,
                                                       documentDiscountAmount: try dec(head, "da"), rounding: rounding))
        let all = [result.net, result.tax, result.gross, result.documentDiscount] + result.byRate.flatMap { [$0.net, $0.tax, $0.gross] } + lines.map(\.value)
        if all.contains(where: { $0 >= amountLimit || $0 <= -amountLimit }) { throw InvoiceError.invalid("lines", "amount_too_large") }
        func s2(_ d: Decimal) -> InvoiceValue { .decimal(InvoiceDecimal.string(d, scale: 2)) }
        var q: SQLQueryString = "UPDATE invoice_documents SET net_total = "
        q += s2(result.net).sql; q += ", tax_total = "; q += s2(result.tax).sql; q += ", gross_total = "; q += s2(result.gross).sql
        q += ", discount_total = "; q += s2(result.documentDiscount).sql; q += " WHERE tenant_id = \(bind: tenant) AND id = \(bind: id)"
        try await s.raw(q).run()
        try await s.raw("DELETE FROM invoice_tax_totals WHERE document_id = \(bind: id)").run()
        for t in result.byRate {
            var i: SQLQueryString = "INSERT INTO invoice_tax_totals (tenant_id, document_id, rate, net, tax, gross) VALUES (\(bind: tenant), \(bind: id), "
            i += InvoiceValue.decimal(InvoiceDecimal.string(t.rate, scale: 4)).sql; i += ", "
            i += s2(t.net).sql; i += ", "; i += s2(t.tax).sql; i += ", "; i += s2(t.gross).sql; i += ")"
            try await s.raw(i).run()
        }
    }

    private static func lockDraft(_ id: UUID, tenant: UUID, on s: any SQLDatabase) async throws {
        guard let row = try await s.raw("SELECT status FROM invoice_documents WHERE tenant_id = \(bind: tenant) AND id = \(bind: id) FOR UPDATE").first() else { throw InvoiceError.notFound }
        if try row.decode(column: "status", as: String.self) != "draft" { throw immutable }
    }

    // MARK: Routen

    static func list(_ req: Request) async throws -> Response {
        let tenant = try req.requireTenant().tenantID
        var q: SQLQueryString = "SELECT \(unsafeRaw: listJSON) AS j FROM invoice_documents r WHERE r.tenant_id = \(bind: tenant)"
        if let status: String = req.query["status"] {
            guard ["draft", "final", "cancelled"].contains(status) else { throw InvoiceError.invalid("status") }
            q += " AND r.status = \(bind: status)"
        }
        if let kind: String = req.query["kind"] {
            guard ["quote", "order_confirmation", "delivery_note", "invoice", "credit_note"].contains(kind) else { throw InvoiceError.invalid("kind") }
            q += " AND r.kind = \(bind: kind)"
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
        let kids = try children(req, body)
        return try await InvoiceIdempotency.run(req, tenant: tenant) { s in
            let h = try await headerSpec.checked(body, extra: ["lines", "charges"], requireAll: true, tenant: tenant, on: s)
            guard let kind = try await typeKind(h, tenant: tenant, on: s) else { throw InvoiceError.invalid("document_type_id", "required") }
            try await checkContact(h, tenant: tenant, on: s)
            if h["issue_date"] == .null { throw InvoiceError.invalid("issue_date", "required") }
            try checkSkonto(h)
            let lines = try await checkedLines(kids.lines ?? [], tenant: tenant, on: s), charges = try await checkedCharges(kids.charges ?? [], tenant: tenant, on: s)
            var columns: [String] = ["document_type_id", "kind"], values: [SQLQueryString] = [(h["document_type_id"] ?? .null).sql, "\(bind: kind)"]
            for name in ["contact_id", "series_id", "due_date", "delivery_date", "discount_amount", "header_text", "footer_text", "note", "price_mode", "rounding_mode", "discount_percent", "skonto_percent", "skonto_days"] {
                if let v = h[name], v != .null { columns.append(name); values.append(v.sql) }
            }
            columns.append("issue_date"); values.append(h["issue_date"].map { $0.sql } ?? "(now() AT TIME ZONE 'UTC')::date")
            columns.append("currency"); values.append(h["currency"].map { $0.sql } ?? "COALESCE((SELECT currency FROM invoice_settings WHERE tenant_id = \(bind: tenant)), 'EUR')")
            var q: SQLQueryString = "INSERT INTO invoice_documents (tenant_id"
            for c in columns { q += ", \(unsafeRaw: c)" }
            q += ") VALUES (\(bind: tenant)"
            for v in values { q += ", "; q += v }
            q += ") RETURNING id"
            guard let row = try await s.raw(q).first() else { throw Abort(.internalServerError) }
            let id = try row.decode(column: "id", as: UUID.self)
            try await replaceChildren(id, tenant: tenant, lines: lines, charges: charges, on: s)
            try await recalculate(id, tenant: tenant, on: s)
            try await AuditLog.record(AuditEvent(action: "invoice.document.created", actor: actor, tenant: tenant, subjectType: "invoice.document", subjectID: id.uuidString, requestID: requestID), on: s)
            return try await fetch(id, tenant: tenant, on: s)
        }
    }

    static func update(_ req: Request) async throws -> Response {
        let tenant = try req.requireTenant().tenantID, actor = try req.requireAuth().user.id, requestID = req.requestId
        let id = try InvoiceValidation.id(req)
        let body = try InvoiceValidation.body(req)
        let kids = try children(req, body)
        let out: String = try await invoiceTransaction(req.db) { s in
            try await lockDraft(id, tenant: tenant, on: s)
            let h = try await headerSpec.checked(body, extra: ["lines", "charges"], requireAll: false, tenant: tenant, on: s)
            if h["issue_date"] == .null { throw InvoiceError.invalid("issue_date", "required") }
            try await checkContact(h, tenant: tenant, on: s)
            var assignments: [SQLQueryString] = []
            if let kind = try await typeKind(h, tenant: tenant, on: s) {
                try await InvoiceLinks.checkKindChange(id, to: kind, on: s)
                assignments.append("kind = \(bind: kind)")
            }
            if let stored = try await s.raw("SELECT skonto_percent IS NOT NULL AS p, skonto_days IS NOT NULL AS d FROM invoice_documents WHERE id = \(bind: id)").first() {
                try checkSkonto(h, stored: (try stored.decode(column: "p", as: Bool.self), try stored.decode(column: "d", as: Bool.self)))
            }
            for name in headerSpec.fields.map(\.name) { if let v = h[name] { var a: SQLQueryString = "\(unsafeRaw: name) = "; a += v.sql; assignments.append(a) } }
            var lines: [[String: InvoiceValue]]?, charges: [[String: InvoiceValue]]?
            if let raw = kids.lines { lines = try await checkedLines(raw, tenant: tenant, on: s) }
            if let raw = kids.charges { charges = try await checkedCharges(raw, tenant: tenant, on: s) }
            var q: SQLQueryString = "UPDATE invoice_documents SET updated_at = now(), rev = rev + 1"
            for a in assignments { q += ", "; q += a }
            q += " WHERE tenant_id = \(bind: tenant) AND id = \(bind: id)"
            try await s.raw(q).run()
            try await replaceChildren(id, tenant: tenant, lines: lines, charges: charges, on: s)
            try await recalculate(id, tenant: tenant, on: s)
            try await AuditLog.record(AuditEvent(action: "invoice.document.updated", actor: actor, tenant: tenant, subjectType: "invoice.document", subjectID: id.uuidString, requestID: requestID), on: s)
            return try await fetch(id, tenant: tenant, on: s)
        }
        return invoiceJSONResponse(out, status: .ok)
    }

    static func delete(_ req: Request) async throws -> Response {
        let tenant = try req.requireTenant().tenantID, actor = try req.requireAuth().user.id, requestID = req.requestId
        let id = try InvoiceValidation.id(req)
        try await invoiceTransaction(req.db) { s in
            try await lockDraft(id, tenant: tenant, on: s)
            try await s.raw("DELETE FROM invoice_documents WHERE tenant_id = \(bind: tenant) AND id = \(bind: id)").run()
            try await AuditLog.record(AuditEvent(action: "invoice.document.deleted", actor: actor, tenant: tenant, subjectType: "invoice.document", subjectID: id.uuidString, requestID: requestID), on: s)
        }
        return Response(status: .noContent)
    }

    // MARK: Finalisieren

    /// Absenderdaten aus den Einstellungen (wie beim Finalisieren eingefroren) und das Kürzel für die Nummer; nil ohne Einstellungen.
    static func senderJSON(tenant: UUID, on s: any SQLDatabase) async throws -> (abbreviation: String?, json: String)? {
        guard let settings = try await s.raw("""
            SELECT abbreviation, jsonb_build_object('sender_name', sender_name, 'street', street, 'postal_code', postal_code, 'city', city, 'country', country, 'tax_number', tax_number,
              'vat_id', vat_id, 'email', email, 'phone', phone, 'website', website, 'bank_name', bank_name, 'iban', iban, 'bic', bic)::text AS j
            FROM invoice_settings WHERE tenant_id = \(bind: tenant)
            """).first() else { return nil }
        return (try settings.decode(column: "abbreviation", as: String?.self), try settings.decode(column: "j", as: String.self))
    }

    /// Empfängerdaten eines Kontakts (erste Anschrift); nil für unbekannte, gelöschte oder zusammengeführte Kontakte.
    static func recipientJSON(contact: UUID, tenant: UUID, on s: any SQLDatabase) async throws -> String? {
        try await s.raw("""
            SELECT jsonb_build_object('contact_id', upper(c.id::text), 'kind', c.kind, 'display_name', c.display_name, 'first_name', c.first_name, 'last_name', c.last_name,
              'company_name', c.company_name, 'vat_id', c.vat_id,
              'address', (SELECT jsonb_build_object('street', a.street, 'postal_code', a.postal_code, 'city', a.city, 'country', a.country)
                          FROM contact_addresses a WHERE a.contact_id = c.id AND a.tenant_id = c.tenant_id ORDER BY a.position, a.id LIMIT 1))::text AS j
            FROM contacts c WHERE c.tenant_id = \(bind: tenant) AND c.id = \(bind: contact) AND c.deleted_at IS NULL AND c.merged_into IS NULL
            """).first()?.decode(column: "j", as: String.self)
    }

    /// Steuerregime am Belegdatum (Steuerzeiträume), sonst `standard`.
    static func taxRegime(issueDate: String, tenant: UUID, on s: any SQLDatabase) async throws -> String {
        try await s.raw("""
            SELECT regime FROM invoice_tax_periods WHERE tenant_id = \(bind: tenant) AND daterange(valid_from, valid_to, '[]') @> \(bind: issueDate)::text::date
            ORDER BY valid_from DESC LIMIT 1
            """).first().map { try $0.decode(column: "regime", as: String.self) } ?? "standard"
    }

    /// Finalisiert einen Entwurf: Vorbedingungen prüfen, Nummer aus dem Hub-Zähler, Absender/Empfänger einfrieren, Hash, Status. Alles in einer Transaktion
    /// (mit `Idempotency-Key` zusätzlich atomar mit dem Schlüssel). Jeder Fehler rollt auch den Zähler zurück.
    static func finalize(_ req: Request) async throws -> Response {
        let tenant = try req.requireTenant().tenantID, actor = try req.requireAuth().user.id, requestID = req.requestId
        let id = try InvoiceValidation.id(req)
        return try await InvoiceIdempotency.run(req, tenant: tenant, status: .ok) { s in
            guard let doc = try await s.raw("""
                SELECT status, kind, series_id, contact_id, issue_date::text AS issue, extract(year FROM issue_date)::int AS y, extract(month FROM issue_date)::int AS m,
                       (SELECT default_series_id FROM invoice_document_types t WHERE t.tenant_id = d.tenant_id AND t.id = d.document_type_id) AS default_series
                FROM invoice_documents d WHERE d.tenant_id = \(bind: tenant) AND d.id = \(bind: id) FOR UPDATE
                """).first() else { throw InvoiceError.notFound }
            if try doc.decode(column: "status", as: String.self) != "draft" { throw immutable }
            guard let contact = try doc.decode(column: "contact_id", as: UUID?.self) else { throw InvoiceError.invalid("contact_id", "required") }
            guard try await s.raw("SELECT 1 AS x FROM invoice_lines WHERE document_id = \(bind: id) AND kind = 'item' LIMIT 1").first() != nil else { throw InvoiceError.invalid("lines", "required") }
            guard let seriesID = try doc.decode(column: "series_id", as: UUID?.self) ?? doc.decode(column: "default_series", as: UUID?.self) else { throw InvoiceError.invalid("series_id", "required") }
            guard let series = try await s.raw("SELECT number_format, active FROM invoice_series WHERE tenant_id = \(bind: tenant) AND id = \(bind: seriesID)").first() else { throw InvoiceError.invalid("series_id", "not_found") }
            guard try series.decode(column: "active", as: Bool.self) else { throw InvoiceError.invalid("series_id", "inactive") }
            guard let settings = try await senderJSON(tenant: tenant, on: s) else { throw InvoiceError.invalid("settings", "required") }
            guard let recipientJSON = try await recipientJSON(contact: contact, tenant: tenant, on: s) else { throw InvoiceError.invalid("contact_id", "not_found") }
            let senderJSON = settings.json

            // WP-R3: verknüpfte Gutschrift gegen die Rechnung prüfen, bevor eine Nummer vergeben wird
            if try doc.decode(column: "kind", as: String.self) == "credit_note" { try await InvoiceLinks.checkCreditNote(id, tenant: tenant, on: s) }

            // Nummer: Format der Serie, Zähler im Kern (Schlüssel je Serie und Zeitraum nach Belegdatum), in dieser Transaktion
            let parsed: InvoiceNumberFormat
            do { parsed = try InvoiceNumberFormat.parse(try series.decode(column: "number_format", as: String.self)) } catch { throw InvoiceError.invalid("series_id", "invalid_format") }
            let year = try doc.decode(column: "y", as: Int.self), month = try doc.decode(column: "m", as: Int.self)
            let counter = try await CounterService(s).next(tenant: tenant, key: InvoiceNumbering.counterKey(series: seriesID, scope: parsed.scope, year: year, month: month), on: s)
            let number: String
            do { number = try parsed.format(counter: counter, year: year, month: month, abbreviation: settings.abbreviation, clientNumber: nil, projectCode: nil) }
            catch let e as InvoiceNumberFormat.Failure { throw InvoiceError.invalid("series_id", e.fieldCode) }

            let regime = try await taxRegime(issueDate: try doc.decode(column: "issue", as: String.self), tenant: tenant, on: s)
            guard let content = try await s.raw("SELECT \(unsafeRaw: contentJSON)::text AS j FROM invoice_documents r WHERE r.tenant_id = \(bind: tenant) AND r.id = \(bind: id)").first() else { throw InvoiceError.notFound }
            let hash = InvoiceValidation.sha256([try content.decode(column: "j", as: String.self), number, String(counter), seriesID.uuidString.lowercased(), regime, senderJSON, recipientJSON]
                .flatMap { [Data($0.utf8), Data([10])] })

            // WP-R6d: Layoutversion nach Zuordnung (Belegart, Serie) einfrieren; ohne Zuordnung bleibt das Standardlayout (NULL)
            let layoutVersion = try await InvoiceLayouts.resolve(kind: try doc.decode(column: "kind", as: String.self), series: seriesID, tenant: tenant, on: s)
            do {
                try await s.raw("""
                    UPDATE invoice_documents SET status = 'final', series_id = \(bind: seriesID), number = \(bind: number), counter_value = \(bind: counter), tax_regime = \(bind: regime),
                      sender = \(bind: senderJSON)::text::jsonb, recipient = \(bind: recipientJSON)::text::jsonb, content_hash = \(bind: hash),
                      finalized_at = now(), finalized_by = \(bind: actor), rev = rev + 1, updated_at = now(), layout_version_id = \(bind: layoutVersion)
                    WHERE tenant_id = \(bind: tenant) AND id = \(bind: id)
                    """).run()
            } catch let e as any DatabaseError where e.isConstraintFailure { throw HubError(.conflict, "number_conflict") }
            // WP-R6c: PDF-Erzeugung in derselben Transaktion einreihen: scheitert irgendein späterer Schritt, verschwindet der Job mit (kein Job ohne finalen Beleg)
            try await InvoiceRenderJob.enqueue(document: id, tenant: tenant, on: s)
            try await AuditLog.record(AuditEvent(action: "invoice.document.finalized", actor: actor, tenant: tenant, subjectType: "invoice.document", subjectID: id.uuidString, requestID: requestID), on: s)
            return try await fetch(id, tenant: tenant, on: s)
        }
    }
}
