import Vapor
import Fluent
import SQLKit

// WP-R1: Stammdaten (Steuerzeiträume, Belegtypen, Nummernserien, Artikel) als spezifikationsgesteuerter CRUD-Dienst (`InvoiceMasterSpec`) und die Einstellungen
// (`InvoiceSettings`, genau eine Zeile je Mandant). Alles mandantengefiltert (`tenant_id` in jeder Abfrage), jede Änderung in einer Transaktion mit Audit.
// Antworten entstehen in der Datenbank (`jsonb_build_object`): Beträge und Daten als Text (kein Gleitkomma auf dem Weg), IDs in der API-Schreibweise (Großbuchstaben).

/// Geprüfter Eingabewert, bindbar als SQL-Parameter.
enum InvoiceValue: Sendable, Equatable {
    case null, text(String), int(Int), bool(Bool), decimal(String), date(String), uuid(UUID)

    var sql: SQLQueryString {
        switch self {
        case .null: "NULL"
        case .text(let v): "\(bind: v)"
        case .int(let v): "\(bind: v)"
        case .bool(let v): "\(bind: v)"
        case .decimal(let v): "\(bind: v)::text::numeric"
        case .date(let v): "\(bind: v)::text::date"
        case .uuid(let v): "\(bind: v)"
        }
    }
    var string: String? {
        switch self {
        case .text(let v), .decimal(let v), .date(let v): v
        case .uuid(let v): v.uuidString
        default: nil
        }
    }
}

struct InvoiceMasterSpec: Sendable {
    enum Kind: Sendable {
        case text(max: Int), pattern(String, max: Int), email, bool, int(ClosedRange<Int>), oneOf([String])
        case decimal(intDigits: Int, min: Decimal?, max: Decimal?), date, ref(table: String), numberFormat, iban, bic, country, currency
    }
    struct Field: Sendable {
        let name: String
        let kind: Kind
        var required = false
        /// Wert beim Ersetzen (PUT) ohne Angabe; sonst `null` bzw. Datenbank-Standard beim Anlegen.
        var defaultValue: InvoiceValue?
    }

    /// Pfadsegment, Audit-Name (`invoice.<audit>.created`), Tabelle.
    let segment: String
    let audit: String
    let table: String
    let fields: [Field]
    let order: String

    static let all: [InvoiceMasterSpec] = [
        InvoiceMasterSpec(segment: "tax-periods", audit: "tax_period", table: "invoice_tax_periods", fields: [
            .init(name: "regime", kind: .oneOf(["standard", "small_business"]), required: true), .init(name: "valid_from", kind: .date, required: true),
            .init(name: "valid_to", kind: .date), .init(name: "note", kind: .text(max: 500))], order: "r.valid_from, r.id"),
        InvoiceMasterSpec(segment: "document-types", audit: "document_type", table: "invoice_document_types", fields: [
            .init(name: "code", kind: .pattern("^[a-z][a-z0-9_]{0,39}$", max: 40), required: true), .init(name: "name", kind: .text(max: 100), required: true),
            .init(name: "kind", kind: .oneOf(["quote", "order_confirmation", "delivery_note", "invoice", "credit_note"]), required: true),
            .init(name: "default_series_id", kind: .ref(table: "invoice_series")), .init(name: "active", kind: .bool)], order: "lower(r.name), r.id"),
        InvoiceMasterSpec(segment: "series", audit: "series", table: "invoice_series", fields: [
            .init(name: "code", kind: .pattern("^[a-z][a-z0-9_]{0,39}$", max: 40), required: true), .init(name: "name", kind: .text(max: 100), required: true),
            .init(name: "number_format", kind: .numberFormat, required: true), .init(name: "active", kind: .bool)], order: "lower(r.name), r.id"),
        InvoiceMasterSpec(segment: "items", audit: "item", table: "invoice_items", fields: [
            .init(name: "sku", kind: .text(max: 60)), .init(name: "name", kind: .text(max: 200), required: true), .init(name: "description", kind: .text(max: 2000)),
            .init(name: "unit", kind: .text(max: 20)),
            .init(name: "unit_price", kind: .decimal(intDigits: 14, min: nil, max: nil), required: true), .init(name: "price_includes_tax", kind: .bool),
            .init(name: "tax_rate", kind: .decimal(intDigits: 3, min: 0, max: 100), required: true),
            .init(name: "track_stock", kind: .bool), .init(name: "stock_quantity", kind: .decimal(intDigits: 14, min: nil, max: nil)), .init(name: "active", kind: .bool)],
            order: "lower(r.name), r.id")
    ]

    /// SQL-Ausdruck für ein Feld im JSON der Antwort.
    static func output(_ f: Field) -> String {
        switch f.kind {
        case .decimal, .date: "r.\(f.name)::text"
        case .ref: "upper(r.\(f.name)::text)"
        default: "r.\(f.name)"
        }
    }

    var json: String {
        let pairs = (["'id', upper(r.id::text)"] + fields.map { "'\($0.name)', \(Self.output($0))" } + extraColumns.map { "'\($0)', r.\($0)" }
                     + ["'created_at', r.created_at", "'updated_at', r.updated_at"]).joined(separator: ", ")
        return "jsonb_build_object(\(pairs))::text"
    }
    /// Von der API berechnete Spalten, die nicht eingegeben werden (Serie: Gültigkeitsbereich des Zählers).
    var extraColumns: [String] { segment == "series" ? ["counter_scope"] : [] }

    // MARK: Prüfung

    func validate(_ f: Field, _ v: InvoiceJSON, tenant: UUID, on s: any SQLDatabase) async throws -> InvoiceValue {
        let bad = InvoiceError.invalid(f.name)
        switch (f.kind, v) {
        case (_, .null): return .null
        case (.text(let max), .string(let t)):
            let x = t.trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCanonicalMapping
            if x.isEmpty { return .null }
            guard x.count <= max else { throw InvoiceError.invalid(f.name, "too_long") }
            return .text(x)
        case (.pattern(let p, let max), .string(let t)):
            guard t.count <= max, t.range(of: p, options: .regularExpression) != nil else { throw bad }
            return .text(t)
        case (.email, .string(let t)):
            let x = t.trimmingCharacters(in: .whitespacesAndNewlines)
            if x.isEmpty { return .null }
            guard x.count <= 200, x.range(of: "^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$", options: .regularExpression) != nil else { throw bad }
            return .text(x)
        case (.bool, .bool(let b)): return .bool(b)
        case (.int(let range), .int(let n)):
            guard range.contains(n) else { throw bad }
            return .int(n)
        case (.oneOf(let values), .string(let t)):
            guard values.contains(t) else { throw bad }
            return .text(t)
        case (.decimal(let digits, let min, let max), .string(let t)):
            guard let d = InvoiceValidation.decimal(t, intDigits: digits, min: min, max: max) else { throw bad }
            return .decimal(d)
        case (.date, .string(let t)):
            guard InvoiceValidation.date(t) else { throw bad }
            return .date(t)
        case (.ref(let table), .string(let t)):
            guard let id = UUID(uuidString: t) else { throw bad }
            guard try await s.raw("SELECT 1 AS x FROM \(unsafeRaw: table) WHERE tenant_id = \(bind: tenant) AND id = \(bind: id)").first() != nil else { throw InvoiceError.invalid(f.name, "not_found") }
            return .uuid(id)
        case (.numberFormat, .string(let t)):
            let x = t.trimmingCharacters(in: .whitespacesAndNewlines)
            if x.isEmpty { throw InvoiceError.invalid(f.name, "required") }
            guard x.count <= 100 else { throw InvoiceError.invalid(f.name, "too_long") }
            do { _ = try InvoiceNumberFormat.parse(x) } catch let e as InvoiceNumberFormat.Failure { throw InvoiceError.invalid(f.name, e.fieldCode) }
            return .text(x)
        case (.iban, .string(let t)):
            if t.trimmingCharacters(in: .whitespaces).isEmpty { return .null }
            guard let iban = InvoiceValidation.iban(t) else { throw bad }
            return .text(iban)
        case (.bic, .string(let t)):
            let x = t.filter { !$0.isWhitespace }.uppercased()
            if x.isEmpty { return .null }
            guard x.range(of: "^[A-Z0-9]{8}([A-Z0-9]{3})?$", options: .regularExpression) != nil else { throw bad }
            return .text(x)
        case (.country, .string(let t)):
            if t.isEmpty { return .null }
            guard t.range(of: "^[A-Z]{2}$", options: .regularExpression) != nil else { throw bad }
            return .text(t)
        case (.currency, .string(let t)):
            guard t.range(of: "^[A-Z]{3}$", options: .regularExpression) != nil else { throw bad }
            return .text(t)
        default: throw bad
        }
    }

    /// Prüft Feldnamen (unbekannte Felder = 422) und alle Werte; `requireAll`: Pflichtfelder müssen vorhanden und nicht leer sein.
    func checked(_ body: [String: InvoiceJSON], extra: Set<String> = [], requireAll: Bool, tenant: UUID, on s: any SQLDatabase) async throws -> [String: InvoiceValue] {
        let unknown = Set(body.keys).subtracting(fields.map(\.name)).subtracting(extra)
        if let first = unknown.sorted().first { throw InvoiceError.invalid(first, "unknown_field") }
        var out: [String: InvoiceValue] = [:]
        for f in fields {
            guard let raw = body[f.name] else {
                if f.required, requireAll { throw InvoiceError.invalid(f.name, "required") }
                continue
            }
            let v = try await validate(f, raw, tenant: tenant, on: s)
            if f.required, v == .null { throw InvoiceError.invalid(f.name, "required") }
            if v == .null, !isNullable(f) { throw InvoiceError.invalid(f.name, "required") }
            out[f.name] = v
        }
        return out
    }

    /// Spalten mit Datenbank-Standard und NOT NULL dürfen nicht auf `null` gesetzt werden.
    private func isNullable(_ f: Field) -> Bool { f.defaultValue == nil && !["active", "price_includes_tax", "track_stock"].contains(f.name) }

    // MARK: Lesen

    static func fetch(_ spec: InvoiceMasterSpec, tenant: UUID, id: UUID, on s: any SQLDatabase) async throws -> String? {
        try await s.raw("SELECT (\(unsafeRaw: spec.json)) AS j FROM \(unsafeRaw: spec.table) r WHERE r.tenant_id = \(bind: tenant) AND r.id = \(bind: id)").first()
            .map { try $0.decode(column: "j", as: String.self) }
    }

    func decorate(_ rows: [String], tenant: UUID, on s: any SQLDatabase) async throws -> [String] {
        guard segment == "series" else { return rows }
        return try await InvoiceSeries.enrich(rows, tenant: tenant, on: s)
    }

    func list(_ req: Request) async throws -> Response {
        let tenant = try req.requireTenant().tenantID
        var filters: SQLQueryString = "r.tenant_id = \(bind: tenant)"
        if fields.contains(where: { $0.name == "active" }), let raw: String = req.query["active"] {
            guard raw == "true" || raw == "false" else { throw InvoiceError.invalid("active") }
            filters += " AND r.active = \(bind: raw == "true")"
        }
        if fields.contains(where: { $0.name == "name" }), let q: String = req.query["q"], !q.isEmpty {
            let pattern = "%" + q.lowercased().replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_") + "%"
            filters += " AND (lower(r.name) LIKE \(bind: pattern)"
            if fields.contains(where: { $0.name == "sku" }) { filters += " OR lower(coalesce(r.sku, '')) LIKE \(bind: pattern)" }
            filters += ")"
        }
        let s = try sql(req.db)
        var q: SQLQueryString = "SELECT (\(unsafeRaw: json)) AS j FROM \(unsafeRaw: table) r WHERE "
        q += filters
        q += " ORDER BY \(unsafeRaw: order) LIMIT 1000"
        let rows = try await s.raw(q).all().map { try $0.decode(column: "j", as: String.self) }
        return invoiceJSONResponse("{\"items\":[" + (try await decorate(rows, tenant: tenant, on: s)).joined(separator: ",") + "]}", status: .ok)
    }

    func get(_ req: Request) async throws -> Response {
        let tenant = try req.requireTenant().tenantID, id = try InvoiceValidation.id(req), s = try sql(req.db)
        guard let row = try await Self.fetch(self, tenant: tenant, id: id, on: s) else { throw InvoiceError.notFound }
        return invoiceJSONResponse(try await decorate([row], tenant: tenant, on: s)[0], status: .ok)
    }

    // MARK: Schreiben

    func create(_ req: Request) async throws -> Response {
        let tenant = try req.requireTenant().tenantID, actor = try req.requireAuth().user.id, requestID = req.requestId
        let body = try InvoiceValidation.body(req)
        let spec = self
        return try await InvoiceIdempotency.run(req, tenant: tenant) { s in
            let values = try await spec.checked(body, extra: spec.segment == "series" ? ["start_number"] : [], requireAll: true, tenant: tenant, on: s)
            var start: Int64 = 1
            if spec.segment == "series", let raw = body["start_number"] {
                guard case .int(let n) = raw, (1...999_999_999_999).contains(n) else { throw InvoiceError.invalid("start_number") }
                start = Int64(n)
            }
            try await spec.beforeCreate(values, tenant: tenant, on: s)
            var columns: [String] = [], binds: [SQLQueryString] = []
            for f in spec.fields { if let v = values[f.name], v != .null { columns.append(f.name); binds.append(v.sql) } }
            if spec.segment == "series", case .text(let format)? = values["number_format"] {
                columns.append("counter_scope"); binds.append("\(bind: try InvoiceNumberFormat.parse(format).scope.rawValue)")
            }
            var q: SQLQueryString = "INSERT INTO \(unsafeRaw: spec.table) (tenant_id"
            for c in columns { q += ", \(unsafeRaw: c)" }
            q += ") VALUES (\(bind: tenant)"
            for b in binds { q += ", "; q += b }
            q += ") RETURNING id"
            let row: (any SQLRow)?
            do { row = try await s.raw(q).first() } catch let e as any DatabaseError where e.isConstraintFailure { throw InvoiceError.duplicate }
            guard let row else { throw Abort(.internalServerError) }
            let id = try row.decode(column: "id", as: UUID.self)
            if start > 1 {
                // Anfangsnummer: hebt den Kernzähler des laufenden Zeitraums an (Audit `counter.raised`); Zähler im Kern, nie hier
                let period = try await InvoiceNumbering.currentPeriod(on: s)
                guard case .text(let format)? = values["number_format"] else { throw Abort(.internalServerError) }
                let key = InvoiceNumbering.counterKey(series: id, scope: try InvoiceNumberFormat.parse(format).scope, year: period.year, month: period.month)
                try await CounterService(s, auditHook: AuditLogCounterHook()).ensureAtLeast(tenant: tenant, key: key, value: start - 1, reason: "series_start", on: s)
            }
            try await AuditLog.record(AuditEvent(action: "invoice.\(spec.audit).created", actor: actor, tenant: tenant, subjectType: "invoice.\(spec.audit)", subjectID: id.uuidString,
                                                 requestID: requestID), on: s)
            guard let out = try await Self.fetch(spec, tenant: tenant, id: id, on: s) else { throw Abort(.internalServerError) }
            return try await spec.decorate([out], tenant: tenant, on: s)[0]
        }
    }

    /// Fachliche Prüfung vor dem Einfügen (nach der Feldprüfung, innerhalb der Transaktion).
    func beforeCreate(_ v: [String: InvoiceValue], tenant: UUID, on s: any SQLDatabase) async throws {
        if segment == "tax-periods" {
            try await InvoiceTaxPeriods.check(from: v["valid_from"]?.string, to: v["valid_to"]?.string, excluding: nil, tenant: tenant, on: s)
        }
        if segment == "items" { try Self.checkStock(track: { if case .bool(let b)? = v["track_stock"] { return b } else { return false } }(), quantity: v["stock_quantity"] ?? .null) }
    }

    static func checkStock(track: Bool, quantity: InvoiceValue) throws {
        if quantity != .null, !track { throw InvoiceError.invalid("stock_quantity", "requires_track_stock") }
    }

    func update(_ req: Request) async throws -> Response {
        let tenant = try req.requireTenant().tenantID, actor = try req.requireAuth().user.id, requestID = req.requestId
        let id = try InvoiceValidation.id(req)
        let body = try InvoiceValidation.body(req)
        let spec = self
        let out: String = try await invoiceTransaction(req.db) { s in
            guard let current = try await s.raw("SELECT (\(unsafeRaw: spec.json)) AS j FROM \(unsafeRaw: spec.table) r WHERE r.tenant_id = \(bind: tenant) AND r.id = \(bind: id) FOR UPDATE").first()
            else { throw InvoiceError.notFound }
            let currentJSON = (try? JSONSerialization.jsonObject(with: Data(try current.decode(column: "j", as: String.self).utf8))) as? [String: Any] ?? [:]
            var values = try await spec.checked(body, requireAll: false, tenant: tenant, on: s)
            var extraAssignments: [SQLQueryString] = []
            switch spec.segment {
            case "tax-periods":
                let from = values["valid_from"]?.string ?? currentJSON["valid_from"] as? String
                let to = values["valid_to"] != nil ? values["valid_to"]!.string : currentJSON["valid_to"] as? String
                try await InvoiceTaxPeriods.check(from: from, to: to, excluding: id, tenant: tenant, on: s)
            case "items":
                let track: Bool = { if case .bool(let b)? = values["track_stock"] { return b } else { return currentJSON["track_stock"] as? Bool ?? false } }()
                let quantity: InvoiceValue = values["stock_quantity"] ?? ((currentJSON["stock_quantity"] as? String).map { .decimal($0) } ?? .null)
                try Self.checkStock(track: track, quantity: quantity)
            case "series":
                if case .text(let format)? = values["number_format"], format != currentJSON["number_format"] as? String {
                    if try await InvoiceSeries.isUsed(id, tenant: tenant, on: s) { throw HubError(.conflict, "series_in_use") }
                    extraAssignments.append("counter_scope = \(bind: try InvoiceNumberFormat.parse(format).scope.rawValue)")
                } else { values["number_format"] = nil }
            default: break
            }
            var assignments: [SQLQueryString] = extraAssignments
            for f in spec.fields { if let v = values[f.name] { var a: SQLQueryString = "\(unsafeRaw: f.name) = "; a += v.sql; assignments.append(a) } }
            if !assignments.isEmpty {
                var q: SQLQueryString = "UPDATE \(unsafeRaw: spec.table) SET updated_at = now()"
                for a in assignments { q += ", "; q += a }
                q += " WHERE tenant_id = \(bind: tenant) AND id = \(bind: id)"
                do { try await s.raw(q).run() } catch let e as any DatabaseError where e.isConstraintFailure { throw InvoiceError.duplicate }
                try await AuditLog.record(AuditEvent(action: "invoice.\(spec.audit).updated", actor: actor, tenant: tenant, subjectType: "invoice.\(spec.audit)", subjectID: id.uuidString,
                                                     requestID: requestID), on: s)
            }
            guard let row = try await Self.fetch(spec, tenant: tenant, id: id, on: s) else { throw InvoiceError.notFound }
            return try await spec.decorate([row], tenant: tenant, on: s)[0]
        }
        return invoiceJSONResponse(out, status: .ok)
    }

    func delete(_ req: Request) async throws -> Response {
        let tenant = try req.requireTenant().tenantID, actor = try req.requireAuth().user.id, requestID = req.requestId
        let id = try InvoiceValidation.id(req)
        let spec = self
        try await invoiceTransaction(req.db) { s in
            guard try await s.raw("SELECT 1 AS x FROM \(unsafeRaw: spec.table) WHERE tenant_id = \(bind: tenant) AND id = \(bind: id) FOR UPDATE").first() != nil else { throw InvoiceError.notFound }
            // Nummernserie mit vergebenen Nummern bleibt bestehen (lückenlose Nummernkreise); die Nummern selbst sind Sache der Belege (WP-R2)
            if spec.segment == "series", try await InvoiceSeries.isUsed(id, tenant: tenant, on: s) { throw HubError(.conflict, "series_in_use") }
            do { try await s.raw("DELETE FROM \(unsafeRaw: spec.table) WHERE tenant_id = \(bind: tenant) AND id = \(bind: id)").run() }
            catch let e as any DatabaseError where e.isConstraintFailure { throw InvoiceError.inUse }
            try await AuditLog.record(AuditEvent(action: "invoice.\(spec.audit).deleted", actor: actor, tenant: tenant, subjectType: "invoice.\(spec.audit)", subjectID: id.uuidString,
                                                 requestID: requestID), on: s)
        }
        return Response(status: .noContent)
    }
}

// MARK: Steuerzeiträume

enum InvoiceTaxPeriods {
    /// Zeitraum prüfen: Ende nicht vor Beginn (422), keine Überlappung mit anderen Zeiträumen des Mandanten (409 `tax_period_overlap`).
    /// Die Sperre je Mandant serialisiert gleichzeitige Anlage; der Trigger der Tabelle ist der Rückfall.
    static func check(from: String?, to: String?, excluding: UUID?, tenant: UUID, on s: any SQLDatabase) async throws {
        guard let from else { throw InvoiceError.invalid("valid_from", "required") }
        if let to, to < from { throw InvoiceError.invalid("valid_to", "before_valid_from") }
        try await s.raw("SELECT pg_advisory_xact_lock(hashtextextended('invoice_tax_periods:' || \(bind: tenant.uuidString.lowercased()), 0)) AS l").run()
        let overlap = try await s.raw("""
            SELECT 1 AS x FROM invoice_tax_periods o WHERE o.tenant_id = \(bind: tenant) AND (\(bind: excluding) IS NULL OR o.id <> \(bind: excluding))
              AND daterange(o.valid_from, o.valid_to, '[]') && daterange(\(bind: from)::text::date, \(bind: to)::text::date, '[]') LIMIT 1
            """).first()
        if overlap != nil { throw HubError(.conflict, "tax_period_overlap") }
    }
}

// MARK: Nummernserien

enum InvoiceSeries {
    /// Hat die Serie schon Nummern vergeben (Zähler im Kern vorhanden)? Dann sind Format und Löschen gesperrt.
    static func isUsed(_ id: UUID, tenant: UUID, on s: any SQLDatabase) async throws -> Bool {
        let prefix = InvoiceNumbering.space + ":" + id.uuidString.lowercased()
        return try await s.raw("SELECT 1 AS x FROM counters WHERE tenant_id = \(bind: tenant) AND (key = \(bind: prefix) OR key LIKE \(bind: prefix + "-%")) LIMIT 1").first() != nil
    }

    /// Ergänzt je Serie `in_use`, `next_number` (nächste Zählernummer im laufenden Zeitraum) und `next_number_preview` (formatiert; `null`, wenn Kunden-/Projektwerte nötig sind).
    static func enrich(_ rows: [String], tenant: UUID, on s: any SQLDatabase) async throws -> [String] {
        if rows.isEmpty { return rows }
        let counters = try await s.raw("SELECT key, value FROM counters WHERE tenant_id = \(bind: tenant) AND key LIKE 'invoice:%'").all()
        var values: [String: Int64] = [:]
        for c in counters { values[try c.decode(column: "key", as: String.self)] = try c.decode(column: "value", as: Int64.self) }
        let period = try await InvoiceNumbering.currentPeriod(on: s)
        let abbreviation = try await s.raw("SELECT abbreviation FROM invoice_settings WHERE tenant_id = \(bind: tenant)").first()
            .flatMap { try? $0.decode(column: "abbreviation", as: String?.self) } ?? nil
        return try rows.map { row in
            guard var object = (try? JSONSerialization.jsonObject(with: Data(row.utf8))) as? [String: Any],
                  let idText = object["id"] as? String, let id = UUID(uuidString: idText), let format = object["number_format"] as? String,
                  let parsed = try? InvoiceNumberFormat.parse(format) else { return row }
            let prefix = InvoiceNumbering.space + ":" + id.uuidString.lowercased()
            let key = InvoiceNumbering.counterKey(series: id, scope: parsed.scope, year: period.year, month: period.month).rawValue
            let next = (values[key] ?? 0) + 1
            object["in_use"] = values.keys.contains { $0 == prefix || $0.hasPrefix(prefix + "-") }
            object["next_number"] = next
            object["next_number_preview"] = (try? parsed.format(counter: next, year: period.year, month: period.month, abbreviation: abbreviation, clientNumber: nil, projectCode: nil)) as Any? ?? NSNull()
            return String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
        }
    }
}

// MARK: Einstellungen

enum InvoiceSettings {
    static let spec = InvoiceMasterSpec(segment: "settings", audit: "settings", table: "invoice_settings", fields: [
        .init(name: "sender_name", kind: .text(max: 200), required: true), .init(name: "street", kind: .text(max: 200)), .init(name: "postal_code", kind: .text(max: 20)),
        .init(name: "city", kind: .text(max: 100)), .init(name: "country", kind: .country), .init(name: "tax_number", kind: .text(max: 40)), .init(name: "vat_id", kind: .text(max: 20)),
        .init(name: "email", kind: .email), .init(name: "phone", kind: .text(max: 50)), .init(name: "website", kind: .text(max: 200)), .init(name: "bank_name", kind: .text(max: 100)),
        .init(name: "iban", kind: .iban), .init(name: "bic", kind: .bic), .init(name: "currency", kind: .currency, defaultValue: .text("EUR")),
        .init(name: "payment_term_days", kind: .int(0...365), defaultValue: .int(14)), .init(name: "abbreviation", kind: .pattern("^[A-Za-z0-9]{1,10}$", max: 10)),
        .init(name: "footer_text", kind: .text(max: 2000))], order: "r.tenant_id")

    private static var jsonSQL: String {
        let pairs = (spec.fields.map { "'\($0.name)', \(InvoiceMasterSpec.output($0))" } + ["'rev', r.rev", "'updated_at', r.updated_at"]).joined(separator: ", ")
        return "jsonb_build_object('configured', true, \(pairs))::text"
    }

    static func read(_ req: Request) async throws -> Response {
        let tenant = try req.requireTenant().tenantID
        let s = try sql(req.db)
        if let row = try await s.raw("SELECT (\(unsafeRaw: jsonSQL)) AS j FROM invoice_settings r WHERE r.tenant_id = \(bind: tenant)").first() {
            return invoiceJSONResponse(try row.decode(column: "j", as: String.self), status: .ok)
        }
        // noch nicht eingerichtet: Standardwerte, nichts wird angelegt
        var object: [String: Any] = ["configured": false, "rev": 0]
        for f in spec.fields {
            switch f.defaultValue {
            case .text(let v)?: object[f.name] = v
            case .int(let v)?: object[f.name] = v
            default: object[f.name] = NSNull()
            }
        }
        return invoiceJSONResponse(String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self), status: .ok)
    }

    /// Ersetzt die Einstellungen (nicht genannte Felder werden leer bzw. auf den Standard gesetzt). Gleichzeitige Aufrufe serialisieren auf der Zeile; `rev` zählt jede Änderung.
    static func replace(_ req: Request) async throws -> Response {
        let tenant = try req.requireTenant().tenantID, actor = try req.requireAuth().user.id, requestID = req.requestId
        let body = try InvoiceValidation.body(req)
        let out: String = try await invoiceTransaction(req.db) { s in
            let values = try await spec.checked(body, requireAll: true, tenant: tenant, on: s)
            var columns: [SQLQueryString] = [], binds: [SQLQueryString] = [], updates: [SQLQueryString] = []
            for f in spec.fields {
                let v = values[f.name] ?? f.defaultValue ?? .null
                columns.append("\(unsafeRaw: f.name)"); binds.append(v.sql); updates.append("\(unsafeRaw: f.name) = EXCLUDED.\(unsafeRaw: f.name)")
            }
            var q: SQLQueryString = "INSERT INTO invoice_settings (tenant_id"
            for c in columns { q += ", "; q += c }
            q += ") VALUES (\(bind: tenant)"
            for b in binds { q += ", "; q += b }
            q += ") ON CONFLICT (tenant_id) DO UPDATE SET rev = invoice_settings.rev + 1, updated_at = now()"
            for u in updates { q += ", "; q += u }
            _ = try await s.raw(q).run()
            try await AuditLog.record(AuditEvent(action: "invoice.settings.updated", actor: actor, tenant: tenant, subjectType: "invoice.settings", subjectID: tenant.uuidString,
                                                 requestID: requestID), on: s)
            guard let row = try await s.raw("SELECT (\(unsafeRaw: jsonSQL)) AS j FROM invoice_settings r WHERE r.tenant_id = \(bind: tenant)").first() else { throw Abort(.internalServerError) }
            return try row.decode(column: "j", as: String.self)
        }
        return invoiceJSONResponse(out, status: .ok)
    }
}
