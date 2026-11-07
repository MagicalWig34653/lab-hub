import Vapor
import Fluent
import SQLKit

/// Generische Verknüpfungen `links(from, to, kind, source)` (WP-K5). Entfernen setzt `removed_at` (nie still, Eintrag und Audit bleiben) und ist umkehrbar.
/// Der Kern kennt nur den Typ `contact`; für ihn wird die Existenz im Mandanten geprüft. Andere Typen gehören den Modulen.
enum LinkService {
    private static func out(_ r: any SQLRow) throws -> LinkOut {
        LinkOut(id: try r.decode(column: "id", as: UUID.self), from_type: try r.decode(column: "from_type", as: String.self),
                from_id: try r.decode(column: "from_id", as: UUID.self), to_type: try r.decode(column: "to_type", as: String.self),
                to_id: try r.decode(column: "to_id", as: UUID.self), kind: try r.decode(column: "kind", as: String.self),
                source: try r.decode(column: "source", as: String.self), created_by: try r.decode(column: "created_by", as: UUID?.self),
                created_at: iso(try r.decode(column: "created_at", as: Date.self)),
                removed_at: try r.decode(column: "removed_at", as: Date?.self).map(iso), removed_by: try r.decode(column: "removed_by", as: UUID?.self))
    }

    private static let columns = "id, from_type, from_id, to_type, to_id, kind, source, created_by, created_at, removed_at, removed_by"
    private static let tokenPattern = "^[a-z][a-z0-9_.]{0,63}$"

    private static func token(_ v: String?, _ field: String) throws -> String {
        guard let v else { throw ContactValidation.fail(field, "required") }
        guard v.range(of: tokenPattern, options: .regularExpression) != nil else { throw ContactValidation.fail(field) }
        return v
    }

    /// Verknüpfungen, an denen das Objekt (Typ, ID) beteiligt ist, auf beiden Seiten. Standard: nur aktive; `includeRemoved` zeigt auch entfernte.
    static func list(tenant: UUID, type: String, id: UUID, includeRemoved: Bool, on db: any Database) async throws -> [LinkOut] {
        try await sql(db).raw("""
            SELECT \(unsafeRaw: columns) FROM links WHERE tenant_id = \(bind: tenant)
              AND ((from_type = \(bind: type) AND from_id = \(bind: id)) OR (to_type = \(bind: type) AND to_id = \(bind: id)))
              AND (\(bind: includeRemoved) OR removed_at IS NULL)
            ORDER BY created_at, id LIMIT 500
            """).all().map(out)
    }

    static func create(tenant: UUID, actor: UUID, body: LinkBody, requestID: String, on db: any Database) async throws -> LinkOut {
        let fromType = try token(body.from_type, "from_type"), toType = try token(body.to_type, "to_type"), kind = try token(body.kind, "kind")
        guard let fromID = body.from_id else { throw ContactValidation.fail("from_id", "required") }
        guard let toID = body.to_id else { throw ContactValidation.fail("to_id", "required") }
        let source = body.source ?? "manual"
        guard ["manual", "rule", "import", "system"].contains(source) else { throw ContactValidation.fail("source") }
        return try await inTransaction(db) { s in
            for (type, id) in [(fromType, fromID), (toType, toID)] where type == "contact" {
                guard try await ContactService.exists(id, tenant: tenant, on: s) else { throw HubError(.notFound, "not_found") }
            }
            guard let row = try await s.raw("""
                INSERT INTO links (tenant_id, from_type, from_id, to_type, to_id, kind, source, created_by)
                VALUES (\(bind: tenant), \(bind: fromType), \(bind: fromID), \(bind: toType), \(bind: toID), \(bind: kind), \(bind: source), \(bind: actor))
                ON CONFLICT DO NOTHING RETURNING \(unsafeRaw: columns)
                """).first() else { throw HubError(.conflict, "conflict") }
            let link = try out(row)
            try await AuditLog.record(AuditEvent(action: "link.created", actor: actor, tenant: tenant, subjectType: "link", subjectID: link.id.uuidString,
                                                 meta: ["kind": .safe(kind), "source": .safe(source)], requestID: requestID), on: s)
            return link
        }
    }

    /// Entfernt eine aktive Verknüpfung (`removed_at`). Unbekannt, fremd oder schon entfernt: 404.
    static func remove(_ id: UUID, tenant: UUID, actor: UUID, requestID: String, on db: any Database) async throws {
        try await inTransaction(db) { s in
            guard let row = try await s.raw("""
                UPDATE links SET removed_at = now(), removed_by = \(bind: actor) WHERE tenant_id = \(bind: tenant) AND id = \(bind: id) AND removed_at IS NULL RETURNING kind
                """).first() else { throw HubError(.notFound, "not_found") }
            try await AuditLog.record(AuditEvent(action: "link.removed", actor: actor, tenant: tenant, subjectType: "link", subjectID: id.uuidString,
                                                 meta: ["kind": .safe(try row.decode(column: "kind", as: String.self))], requestID: requestID), on: s)
        }
    }

    /// Macht eine entfernte Verknüpfung rückgängig. Existiert inzwischen eine gleiche aktive: 409.
    static func restore(_ id: UUID, tenant: UUID, actor: UUID, requestID: String, on db: any Database) async throws -> LinkOut {
        try await inTransaction(db) { s in
            guard try await s.raw("SELECT 1 AS x FROM links WHERE tenant_id = \(bind: tenant) AND id = \(bind: id) AND removed_at IS NOT NULL FOR UPDATE").first() != nil
            else { throw HubError(.notFound, "not_found") }
            let row: (any SQLRow)?
            do {
                row = try await s.raw("""
                    UPDATE links SET removed_at = NULL, removed_by = NULL WHERE tenant_id = \(bind: tenant) AND id = \(bind: id) RETURNING \(unsafeRaw: columns)
                    """).first()
            } catch let e as any DatabaseError where e.isConstraintFailure { throw HubError(.conflict, "conflict") }
            guard let row else { throw HubError(.notFound, "not_found") }
            let link = try out(row)
            try await AuditLog.record(AuditEvent(action: "link.restored", actor: actor, tenant: tenant, subjectType: "link", subjectID: id.uuidString,
                                                 meta: ["kind": .safe(link.kind)], requestID: requestID), on: s)
            return link
        }
    }
}
