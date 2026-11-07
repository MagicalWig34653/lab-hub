import Vapor
import Fluent
import SQLKit

/// Kontakte (WP-K5). Jede Abfrage ist mandantengefiltert; Änderungen laufen in einer Transaktion mit Audit-Eintrag.
/// Audit enthält nie Namen, Adressen oder IBANs, nur IDs und Zähler (AK-K1-8).
enum ContactService {
    private static let columns = """
        c.id, c.kind, c.display_name, c.first_name, c.last_name, c.company_name, c.vat_id, c.is_customer, c.is_supplier, c.is_correspondent,
        c.note, c.merged_into, c.created_at, c.updated_at
        """

    private static func summary(_ row: any SQLRow) throws -> ContactOut {
        ContactOut(id: try row.decode(column: "id", as: UUID.self), kind: try row.decode(column: "kind", as: String.self),
                   display_name: try row.decode(column: "display_name", as: String.self),
                   first_name: try row.decode(column: "first_name", as: String?.self), last_name: try row.decode(column: "last_name", as: String?.self),
                   company_name: try row.decode(column: "company_name", as: String?.self), vat_id: try row.decode(column: "vat_id", as: String?.self),
                   is_customer: try row.decode(column: "is_customer", as: Bool.self), is_supplier: try row.decode(column: "is_supplier", as: Bool.self),
                   is_correspondent: try row.decode(column: "is_correspondent", as: Bool.self), note: try row.decode(column: "note", as: String?.self),
                   merged_into: try row.decode(column: "merged_into", as: UUID?.self),
                   created_at: iso(try row.decode(column: "created_at", as: Date.self)), updated_at: iso(try row.decode(column: "updated_at", as: Date.self)))
    }

    /// Kontakt mit allen Unterlisten; `nil`, wenn er im Mandanten nicht existiert oder gelöscht ist (zusammengeführte Kontakte bleiben lesbar, `merged_into` zeigt das Ziel).
    static func load(_ id: UUID, tenant: UUID, on s: any SQLDatabase) async throws -> ContactOut? {
        guard let row = try await s.raw("SELECT \(unsafeRaw: columns) FROM contacts c WHERE c.tenant_id = \(bind: tenant) AND c.id = \(bind: id) AND c.deleted_at IS NULL").first()
        else { return nil }
        var out = try summary(row)
        out.addresses = try await s.raw("""
            SELECT label, street, postal_code, city, country FROM contact_addresses WHERE tenant_id = \(bind: tenant) AND contact_id = \(bind: id) ORDER BY position, id
            """).all().map {
            AddressDTO(label: try $0.decode(column: "label", as: String?.self), street: try $0.decode(column: "street", as: String?.self),
                       postal_code: try $0.decode(column: "postal_code", as: String?.self), city: try $0.decode(column: "city", as: String?.self),
                       country: try $0.decode(column: "country", as: String?.self))
        }
        out.emails = try await s.raw("SELECT email, label FROM contact_emails WHERE tenant_id = \(bind: tenant) AND contact_id = \(bind: id) ORDER BY position, id").all().map {
            EmailDTO(email: try $0.decode(column: "email", as: String.self), label: try $0.decode(column: "label", as: String?.self))
        }
        out.bank_accounts = try await s.raw("SELECT iban, bic, holder FROM contact_bank_accounts WHERE tenant_id = \(bind: tenant) AND contact_id = \(bind: id) ORDER BY position, id").all().map {
            BankAccountDTO(iban: try $0.decode(column: "iban", as: String.self), bic: try $0.decode(column: "bic", as: String?.self), holder: try $0.decode(column: "holder", as: String?.self))
        }
        out.aliases = try await s.raw("SELECT alias FROM contact_aliases WHERE tenant_id = \(bind: tenant) AND contact_id = \(bind: id) ORDER BY alias, id").all()
            .map { try $0.decode(column: "alias", as: String.self) }
        return out
    }

    // MARK: Liste

    /// Seite von Kontakten (ohne gelöschte und zusammengeführte), sortiert nach `(created_at, id)`. `q` sucht in Name, Aliasen, USt-ID und E-Mail.
    static func list(tenant: UUID, page: HubPageRequest, q: String?, role: String?, kind: String?, on db: any Database) async throws -> HubPage<ContactOut> {
        let s = try sql(db)
        let pattern = q.flatMap { $0.isEmpty ? nil : "%" + $0.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_") + "%" }
        let cur = page.cursor
        let rows = try await s.raw("""
            SELECT \(unsafeRaw: columns), c.created_at::text AS created_text FROM contacts c
            WHERE c.tenant_id = \(bind: tenant) AND c.deleted_at IS NULL AND c.merged_into IS NULL
              AND (\(bind: kind)::text IS NULL OR c.kind = \(bind: kind)::text)
              AND (\(bind: role)::text IS NULL OR (\(bind: role)::text = 'customer' AND c.is_customer) OR (\(bind: role)::text = 'supplier' AND c.is_supplier)
                   OR (\(bind: role)::text = 'correspondent' AND c.is_correspondent))
              AND (\(bind: pattern)::text IS NULL OR c.display_name ILIKE \(bind: pattern)::text OR c.vat_id ILIKE \(bind: pattern)::text
                   OR EXISTS (SELECT 1 FROM contact_aliases a WHERE a.contact_id = c.id AND a.alias ILIKE \(bind: pattern)::text)
                   OR EXISTS (SELECT 1 FROM contact_emails e WHERE e.contact_id = c.id AND e.email ILIKE \(bind: pattern)::text))
              AND (\(bind: cur?.createdAt)::text IS NULL OR (c.created_at, c.id) > (\(bind: cur?.createdAt)::timestamptz, \(bind: cur?.id)::uuid))
            ORDER BY c.created_at, c.id LIMIT \(bind: page.limit + 1)
            """).all()
        let items = try rows.map { (try summary($0), try $0.decode(column: "created_text", as: String.self)) }
        var total: Int?
        if page.wantsCount {
            total = Int(try await s.raw("SELECT count(*)::bigint AS n FROM contacts WHERE tenant_id = \(bind: tenant) AND deleted_at IS NULL AND merged_into IS NULL")
                .first()?.decode(column: "n", as: Int64.self) ?? 0)
        }
        let created = Dictionary(uniqueKeysWithValues: items.map { ($0.0.id, $0.1) })
        return HubPage(fetched: items.map(\.0), limit: page.limit, cursorOf: { PageCursor(createdAt: created[$0.id] ?? "", id: $0.id) }, total: total)
    }

    // MARK: Anlegen, Ändern, Löschen

    static func create(tenant: UUID, actor: UUID, fields f: ContactFields, requestID: String, on db: any Database) async throws -> ContactOut {
        try await inTransaction(db) { s in
            guard let row = try await s.raw("""
                INSERT INTO contacts (tenant_id, kind, display_name, first_name, last_name, company_name, vat_id, is_customer, is_supplier, is_correspondent, note)
                VALUES (\(bind: tenant), \(bind: f.kind), \(bind: f.displayName), \(bind: f.firstName ?? nil), \(bind: f.lastName ?? nil), \(bind: f.companyName ?? nil),
                        \(bind: f.vatID ?? nil), \(bind: f.isCustomer ?? false), \(bind: f.isSupplier ?? false), \(bind: f.isCorrespondent ?? false), \(bind: f.note ?? nil))
                RETURNING id
                """).first() else { throw Abort(.internalServerError) }
            let id = try row.decode(column: "id", as: UUID.self)
            try await replaceChildren(id, tenant: tenant, f, on: s)
            try await AuditLog.record(AuditEvent(action: "contact.created", actor: actor, tenant: tenant, subjectType: "contact", subjectID: id.uuidString, requestID: requestID), on: s)
            guard var out = try await load(id, tenant: tenant, on: s) else { throw Abort(.internalServerError) }
            out.duplicates = try await duplicates(of: id, tenant: tenant, on: s)
            return out
        }
    }

    static func update(_ id: UUID, tenant: UUID, actor: UUID, fields f: ContactFields, requestID: String, on db: any Database) async throws -> ContactOut {
        try await inTransaction(db) { s in
            try await lockActive(id, tenant: tenant, on: s)
            try await s.raw("""
                UPDATE contacts SET kind = COALESCE(\(bind: f.kind), kind), display_name = COALESCE(\(bind: f.displayName), display_name),
                  first_name = CASE WHEN \(bind: f.firstName != nil) THEN \(bind: f.firstName ?? nil) ELSE first_name END,
                  last_name = CASE WHEN \(bind: f.lastName != nil) THEN \(bind: f.lastName ?? nil) ELSE last_name END,
                  company_name = CASE WHEN \(bind: f.companyName != nil) THEN \(bind: f.companyName ?? nil) ELSE company_name END,
                  vat_id = CASE WHEN \(bind: f.vatID != nil) THEN \(bind: f.vatID ?? nil) ELSE vat_id END,
                  note = CASE WHEN \(bind: f.note != nil) THEN \(bind: f.note ?? nil) ELSE note END,
                  is_customer = COALESCE(\(bind: f.isCustomer), is_customer), is_supplier = COALESCE(\(bind: f.isSupplier), is_supplier),
                  is_correspondent = COALESCE(\(bind: f.isCorrespondent), is_correspondent), updated_at = now()
                WHERE tenant_id = \(bind: tenant) AND id = \(bind: id)
                """).run()
            try await replaceChildren(id, tenant: tenant, f, on: s)
            try await AuditLog.record(AuditEvent(action: "contact.updated", actor: actor, tenant: tenant, subjectType: "contact", subjectID: id.uuidString, requestID: requestID), on: s)
            guard var out = try await load(id, tenant: tenant, on: s) else { throw Abort(.internalServerError) }
            out.duplicates = try await duplicates(of: id, tenant: tenant, on: s)
            return out
        }
    }

    /// Löschen = `deleted_at` setzen (Zeile und `links` bleiben für Nachvollziehbarkeit). Zusammengeführte Kontakte lassen sich nicht löschen.
    static func delete(_ id: UUID, tenant: UUID, actor: UUID, requestID: String, on db: any Database) async throws {
        try await inTransaction(db) { s in
            try await lockActive(id, tenant: tenant, on: s)
            try await s.raw("UPDATE contacts SET deleted_at = now(), updated_at = now() WHERE tenant_id = \(bind: tenant) AND id = \(bind: id)").run()
            try await AuditLog.record(AuditEvent(action: "contact.deleted", actor: actor, tenant: tenant, subjectType: "contact", subjectID: id.uuidString, requestID: requestID), on: s)
        }
    }

    /// Sperrt die Kontaktzeile. Fremd/gelöscht: 404. Bereits zusammengeführt: 409 `contact_merged`.
    private static func lockActive(_ id: UUID, tenant: UUID, on s: any SQLDatabase) async throws {
        guard let row = try await s.raw("SELECT merged_into FROM contacts WHERE tenant_id = \(bind: tenant) AND id = \(bind: id) AND deleted_at IS NULL FOR UPDATE").first()
        else { throw HubError(.notFound, "not_found") }
        if try row.decode(column: "merged_into", as: UUID?.self) != nil { throw HubError(.conflict, "contact_merged") }
    }

    private static func replaceChildren(_ id: UUID, tenant: UUID, _ f: ContactFields, on s: any SQLDatabase) async throws {
        if let list = f.addresses {
            try await s.raw("DELETE FROM contact_addresses WHERE tenant_id = \(bind: tenant) AND contact_id = \(bind: id)").run()
            for (i, a) in list.enumerated() {
                try await s.raw("""
                    INSERT INTO contact_addresses (tenant_id, contact_id, position, label, street, postal_code, city, country)
                    VALUES (\(bind: tenant), \(bind: id), \(bind: i), \(bind: a.label), \(bind: a.street), \(bind: a.postal_code), \(bind: a.city), \(bind: a.country))
                    """).run()
            }
        }
        if let list = f.emails {
            try await s.raw("DELETE FROM contact_emails WHERE tenant_id = \(bind: tenant) AND contact_id = \(bind: id)").run()
            for (i, e) in list.enumerated() {
                try await s.raw("INSERT INTO contact_emails (tenant_id, contact_id, position, email, label) VALUES (\(bind: tenant), \(bind: id), \(bind: i), \(bind: e.email), \(bind: e.label))").run()
            }
        }
        if let list = f.banks {
            try await s.raw("DELETE FROM contact_bank_accounts WHERE tenant_id = \(bind: tenant) AND contact_id = \(bind: id)").run()
            for (i, b) in list.enumerated() {
                try await s.raw("INSERT INTO contact_bank_accounts (tenant_id, contact_id, position, iban, bic, holder) VALUES (\(bind: tenant), \(bind: id), \(bind: i), \(bind: b.iban), \(bind: b.bic), \(bind: b.holder))").run()
            }
        }
        if let list = f.aliases {
            try await s.raw("DELETE FROM contact_aliases WHERE tenant_id = \(bind: tenant) AND contact_id = \(bind: id)").run()
            for a in list {
                try await s.raw("INSERT INTO contact_aliases (tenant_id, contact_id, alias) VALUES (\(bind: tenant), \(bind: id), \(bind: a))").run()
            }
        }
    }

    // MARK: Dubletten

    /// Andere aktive Kontakte des Mandanten mit gleicher USt-ID oder gemeinsamer IBAN. Nur ein Hinweis; nichts wird zusammengeführt.
    static func duplicates(of id: UUID, tenant: UUID, on s: any SQLDatabase) async throws -> [DuplicateHint] {
        let rows = try await s.raw("""
            SELECT c.id, c.display_name, 'vat_id' AS reason FROM contacts c
            WHERE c.tenant_id = \(bind: tenant) AND c.id <> \(bind: id) AND c.deleted_at IS NULL AND c.merged_into IS NULL AND c.vat_id IS NOT NULL
              AND c.vat_id = (SELECT vat_id FROM contacts WHERE tenant_id = \(bind: tenant) AND id = \(bind: id))
            UNION ALL
            SELECT DISTINCT c.id, c.display_name, 'iban' AS reason FROM contacts c
            JOIN contact_bank_accounts b ON b.contact_id = c.id AND b.tenant_id = c.tenant_id
            JOIN contact_bank_accounts mine ON mine.iban = b.iban AND mine.contact_id = \(bind: id) AND mine.tenant_id = c.tenant_id
            WHERE c.tenant_id = \(bind: tenant) AND c.id <> \(bind: id) AND c.deleted_at IS NULL AND c.merged_into IS NULL
            """).all()
        var byID: [UUID: (name: String, reasons: [String])] = [:]
        for r in rows {
            let cid = try r.decode(column: "id", as: UUID.self)
            let name = try r.decode(column: "display_name", as: String.self)
            var entry = byID[cid] ?? (name: name, reasons: [])
            entry.reasons.append(try r.decode(column: "reason", as: String.self))
            byID[cid] = entry
        }
        return byID.map { DuplicateHint(id: $0.key, display_name: $0.value.name, reasons: $0.value.reasons.sorted()) }
            .sorted { ($0.display_name, $0.id.uuidString) < ($1.display_name, $1.id.uuidString) }
    }

    /// Hinweise für einen vorhandenen Kontakt (Route `GET …/duplicates`); `nil` bei unbekannter oder fremder ID.
    static func duplicateHints(of id: UUID, tenant: UUID, on db: any Database) async throws -> [DuplicateHint]? {
        let s = try sql(db)
        guard try await s.raw("SELECT 1 AS x FROM contacts WHERE tenant_id = \(bind: tenant) AND id = \(bind: id) AND deleted_at IS NULL").first() != nil else { return nil }
        return try await duplicates(of: id, tenant: tenant, on: s)
    }

    // MARK: Zusammenführen

    /// Führt `source` in `target` zusammen. Beide Zeilen werden in fester Reihenfolge (nach ID) gesperrt, so dass parallele Zusammenführungen
    /// (auch gegenläufige, auch auf verschiedenen Instanzen) seriell laufen; der Verlierer erhält 409 `contact_merged`.
    /// `target` behält seine Werte; fehlende USt-ID und Rollenkennzeichen kommen von `source`, Unterlisten werden ergänzt (ohne Dubletten),
    /// der Anzeigename von `source` wird Alias. `links` beider Seiten zeigen danach auf `target`; Einträge, die dadurch doppelt oder zu Selbstverweisen würden,
    /// werden mit `removed_at` entfernt statt gelöscht. `source` bleibt mit `merged_into` erhalten.
    static func merge(source: UUID, into target: UUID, tenant: UUID, actor: UUID, requestID: String, on db: any Database) async throws -> MergeResult {
        guard source != target else { throw ContactValidation.fail("source_id", "same_contact") }
        return try await inTransaction(db) { s in
            let locked = try await s.raw("""
                SELECT id, merged_into FROM contacts WHERE tenant_id = \(bind: tenant) AND id IN (\(bind: source), \(bind: target)) AND deleted_at IS NULL
                ORDER BY id FOR UPDATE
                """).all()
            guard locked.count == 2 else { throw HubError(.notFound, "not_found") }
            for r in locked where try r.decode(column: "merged_into", as: UUID?.self) != nil { throw HubError(.conflict, "contact_merged") }

            // Felder und Unterlisten
            try await s.raw("""
                UPDATE contacts t SET vat_id = COALESCE(t.vat_id, x.vat_id), is_customer = t.is_customer OR x.is_customer,
                  is_supplier = t.is_supplier OR x.is_supplier, is_correspondent = t.is_correspondent OR x.is_correspondent, updated_at = now()
                FROM contacts x WHERE t.tenant_id = \(bind: tenant) AND t.id = \(bind: target) AND x.tenant_id = \(bind: tenant) AND x.id = \(bind: source)
                """).run()
            try await s.raw("""
                INSERT INTO contact_addresses (tenant_id, contact_id, position, label, street, postal_code, city, country)
                SELECT tenant_id, \(bind: target)::uuid, 1000 + position, label, street, postal_code, city, country FROM contact_addresses a
                WHERE a.tenant_id = \(bind: tenant) AND a.contact_id = \(bind: source) AND NOT EXISTS (
                  SELECT 1 FROM contact_addresses b WHERE b.contact_id = \(bind: target) AND b.street IS NOT DISTINCT FROM a.street
                    AND b.postal_code IS NOT DISTINCT FROM a.postal_code AND b.city IS NOT DISTINCT FROM a.city AND b.country IS NOT DISTINCT FROM a.country)
                """).run()
            try await s.raw("""
                INSERT INTO contact_emails (tenant_id, contact_id, position, email, label)
                SELECT tenant_id, \(bind: target)::uuid, 1000 + position, email, label FROM contact_emails a
                WHERE a.tenant_id = \(bind: tenant) AND a.contact_id = \(bind: source)
                  AND NOT EXISTS (SELECT 1 FROM contact_emails b WHERE b.contact_id = \(bind: target) AND lower(b.email) = lower(a.email))
                """).run()
            try await s.raw("""
                INSERT INTO contact_bank_accounts (tenant_id, contact_id, position, iban, bic, holder)
                SELECT tenant_id, \(bind: target)::uuid, 1000 + position, iban, bic, holder FROM contact_bank_accounts a
                WHERE a.tenant_id = \(bind: tenant) AND a.contact_id = \(bind: source)
                  AND NOT EXISTS (SELECT 1 FROM contact_bank_accounts b WHERE b.contact_id = \(bind: target) AND b.iban = a.iban)
                """).run()
            try await s.raw("""
                INSERT INTO contact_aliases (tenant_id, contact_id, alias)
                SELECT tenant_id, \(bind: target)::uuid, alias FROM contact_aliases a WHERE a.tenant_id = \(bind: tenant) AND a.contact_id = \(bind: source)
                  AND NOT EXISTS (SELECT 1 FROM contact_aliases b WHERE b.contact_id = \(bind: target) AND lower(b.alias) = lower(a.alias))
                """).run()
            try await s.raw("""
                INSERT INTO contact_aliases (tenant_id, contact_id, alias)
                SELECT x.tenant_id, \(bind: target)::uuid, x.display_name FROM contacts x WHERE x.tenant_id = \(bind: tenant) AND x.id = \(bind: source)
                  AND lower(x.display_name) <> (SELECT lower(display_name) FROM contacts WHERE id = \(bind: target))
                ON CONFLICT DO NOTHING
                """).run()

            // links: Verbindungen zwischen den beiden Kontakten entfallen, Kollisionen werden entfernt, der Rest wird umgeschrieben.
            var removed = 0, rewritten = 0
            removed += try await s.raw("""
                UPDATE links SET removed_at = now(), removed_by = \(bind: actor) WHERE tenant_id = \(bind: tenant) AND removed_at IS NULL
                  AND from_type = 'contact' AND to_type = 'contact' AND from_id IN (\(bind: source), \(bind: target)) AND to_id IN (\(bind: source), \(bind: target))
                RETURNING id
                """).all().count
            removed += try await s.raw("""
                UPDATE links l SET removed_at = now(), removed_by = \(bind: actor) WHERE l.tenant_id = \(bind: tenant) AND l.removed_at IS NULL
                  AND l.from_type = 'contact' AND l.from_id = \(bind: source) AND EXISTS (
                    SELECT 1 FROM links o WHERE o.tenant_id = l.tenant_id AND o.removed_at IS NULL AND o.from_type = 'contact' AND o.from_id = \(bind: target)
                      AND o.to_type = l.to_type AND o.to_id = l.to_id AND o.kind = l.kind)
                RETURNING id
                """).all().count
            removed += try await s.raw("""
                UPDATE links l SET removed_at = now(), removed_by = \(bind: actor) WHERE l.tenant_id = \(bind: tenant) AND l.removed_at IS NULL
                  AND l.to_type = 'contact' AND l.to_id = \(bind: source) AND EXISTS (
                    SELECT 1 FROM links o WHERE o.tenant_id = l.tenant_id AND o.removed_at IS NULL AND o.to_type = 'contact' AND o.to_id = \(bind: target)
                      AND o.from_type = l.from_type AND o.from_id = l.from_id AND o.kind = l.kind)
                RETURNING id
                """).all().count
            rewritten += try await s.raw("UPDATE links SET from_id = \(bind: target) WHERE tenant_id = \(bind: tenant) AND from_type = 'contact' AND from_id = \(bind: source) AND removed_at IS NULL RETURNING id").all().count
            rewritten += try await s.raw("UPDATE links SET to_id = \(bind: target) WHERE tenant_id = \(bind: tenant) AND to_type = 'contact' AND to_id = \(bind: source) AND removed_at IS NULL RETURNING id").all().count
            // Entfernte Einträge (Historie) zeigen ebenfalls auf den Zielkontakt.
            try await s.raw("UPDATE links SET from_id = \(bind: target) WHERE tenant_id = \(bind: tenant) AND from_type = 'contact' AND from_id = \(bind: source)").run()
            try await s.raw("UPDATE links SET to_id = \(bind: target) WHERE tenant_id = \(bind: tenant) AND to_type = 'contact' AND to_id = \(bind: source)").run()

            try await s.raw("UPDATE contacts SET merged_into = \(bind: target), merged_at = now(), updated_at = now() WHERE tenant_id = \(bind: tenant) AND id = \(bind: source)").run()
            try await AuditLog.record(AuditEvent(action: "contact.merged", actor: actor, tenant: tenant, subjectType: "contact", subjectID: target.uuidString,
                                                 meta: ["source": .safe(source.uuidString), "links_rewritten": .number(Int64(rewritten)), "links_removed": .number(Int64(removed))],
                                                 requestID: requestID), on: s)
            guard var out = try await load(target, tenant: tenant, on: s) else { throw Abort(.internalServerError) }
            out.duplicates = try await duplicates(of: target, tenant: tenant, on: s)
            return MergeResult(contact: out, merged_id: source, links_rewritten: rewritten, links_removed: removed)
        }
    }

    static func exists(_ id: UUID, tenant: UUID, on s: any SQLDatabase) async throws -> Bool {
        try await s.raw("SELECT 1 AS x FROM contacts WHERE tenant_id = \(bind: tenant) AND id = \(bind: id) AND deleted_at IS NULL").first() != nil
    }
}
