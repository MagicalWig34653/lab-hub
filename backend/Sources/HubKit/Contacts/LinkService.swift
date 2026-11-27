import Vapor
import Fluent
import SQLKit

/// Ende einer Verknüpfung, wie es der Link-Schutz eines Moduls sieht (WP-ST2). `field` ist das Feld für Feldfehler (`from_type`/`to_type`).
public struct LinkEnd: Sendable, Equatable {
    public let type: String
    public let id: UUID
    public let field: String
    public init(type: String, id: UUID, field: String) { self.type = type; self.id = id; self.field = field }
}

/// Sichtbarkeit der Objekte eines Moduls über die generische Verknüpfungsroute (WP-ST2, `HubModule.linkVisibility`).
public enum LinkVisibility: Sendable {
    case visible
    /// Seiten des Moduls fehlen in Listen; eine direkte Abfrage eines Modultyps wirft diesen Fehler.
    case hidden(HubError)
}

/// Generische Verknüpfungen `links(from, to, kind, source)` (WP-K5). Entfernen setzt `removed_at` (nie still, Eintrag und Audit bleiben) und ist umkehrbar.
/// Der Kern kennt nur den Typ `contact`; für ihn wird die Existenz im Mandanten geprüft. Andere Typen `<modulkey>.…` gehören den Modulen, deren Schutzregeln
/// über die Haken `linkVisibility`/`guardLinkEnds` greifen (WP-ST2, vorher fest im Kern, WP-H14).
enum LinkService {
    /// Woher der Aufruf kommt. `external` = generische Route (Nutzeranfrage): für Objekte der Module gelten deren Schutzregeln, mit den Modulrechten der Rolle.
    /// `internal` = Kern, Import und Vorschläge, die ihre Prüfungen selbst vornehmen.
    enum Origin { case `internal`; case external(modules: ModuleRegistry, role: Role) }

    /// Reicht die Enden je Modul (Präfix `<key>.`) an dessen Link-Schutz weiter; nur bei externen Aufrufen.
    private static func guardEnds(_ ends: [LinkEnd], origin: Origin, tenant: UUID, creating: Bool, on s: any SQLDatabase) async throws {
        guard case .external(let registry, let role) = origin else { return }
        for module in registry.modules {
            let own = ends.filter { $0.type.hasPrefix(module.key + ".") }
            if own.isEmpty { continue }
            try await module.guardLinkEnds(own, creating: creating, permissions: registry.permissions(of: role, module: module.key), tenant: tenant, on: s)
        }
    }

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
    /// Extern (generische Route) entscheidet je Modul `linkVisibility`: verborgene Module lassen ihre Seiten aus der Liste fallen, eine Abfrage ihres Typs wirft.
    static func list(tenant: UUID, type: String, id: UUID, includeRemoved: Bool, origin: Origin = .internal, on db: any Database) async throws -> [LinkOut] {
        let s = try sql(db)
        var hidden: [String] = []   // LIKE-Muster `<key>.%`; Modulschlüssel enthalten weder `%` noch `_`
        if case .external(let registry, let role) = origin {
            for module in registry.modules {
                guard case .hidden(let error) = try await module.linkVisibility(tenant: tenant, permissions: registry.permissions(of: role, module: module.key), on: s)
                else { continue }
                if type.hasPrefix(module.key + ".") { throw error }
                hidden.append(module.key + ".%")
            }
        }
        return try await s.raw("""
            SELECT \(unsafeRaw: columns) FROM links WHERE tenant_id = \(bind: tenant)
              AND ((from_type = \(bind: type) AND from_id = \(bind: id)) OR (to_type = \(bind: type) AND to_id = \(bind: id)))
              AND (\(bind: includeRemoved) OR removed_at IS NULL)
              AND NOT (from_type LIKE ANY (\(bind: hidden)::text[]) OR to_type LIKE ANY (\(bind: hidden)::text[]))
            ORDER BY created_at, id LIMIT 500
            """).all().map(out)
    }

    static func create(tenant: UUID, actor: UUID, body: LinkBody, requestID: String, origin: Origin = .internal, on db: any Database) async throws -> LinkOut {
        let fromType = try token(body.from_type, "from_type"), toType = try token(body.to_type, "to_type"), kind = try token(body.kind, "kind")
        guard let fromID = body.from_id else { throw ContactValidation.fail("from_id", "required") }
        guard let toID = body.to_id else { throw ContactValidation.fail("to_id", "required") }
        let source = body.source ?? "manual"
        guard ["manual", "rule", "import", "system"].contains(source) else { throw ContactValidation.fail("source") }
        return try await inTransaction(db) { s in
            for (type, id) in [(fromType, fromID), (toType, toID)] where type == "contact" {
                guard try await ContactService.exists(id, tenant: tenant, on: s) else { throw HubError(.notFound, "not_found") }
            }
            try await guardEnds([LinkEnd(type: fromType, id: fromID, field: "from_type"), LinkEnd(type: toType, id: toID, field: "to_type")],
                                origin: origin, tenant: tenant, creating: true, on: s)
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

    /// Schutz für Entfernen (`active`) und Rückgängig (`!active`) bestehender Verknüpfungen mit Modulseite. Unbekannte Links lässt er durch (404 folgt danach).
    private static func guardLinkEnds(_ id: UUID, tenant: UUID, active: Bool, origin: Origin, on s: any SQLDatabase) async throws {
        guard case .external = origin else { return }
        guard let row = try await s.raw("""
            SELECT from_type, from_id, to_type, to_id FROM links WHERE tenant_id = \(bind: tenant) AND id = \(bind: id) AND (removed_at IS NULL) = \(bind: active)
            """).first() else { return }
        try await guardEnds([LinkEnd(type: try row.decode(column: "from_type", as: String.self), id: try row.decode(column: "from_id", as: UUID.self), field: "from_type"),
                             LinkEnd(type: try row.decode(column: "to_type", as: String.self), id: try row.decode(column: "to_id", as: UUID.self), field: "to_type")],
                            origin: origin, tenant: tenant, creating: false, on: s)
    }

    /// Entfernt eine aktive Verknüpfung (`removed_at`). Unbekannt, fremd oder schon entfernt: 404.
    static func remove(_ id: UUID, tenant: UUID, actor: UUID, requestID: String, origin: Origin = .internal, on db: any Database) async throws {
        try await inTransaction(db) { s in
            try await guardLinkEnds(id, tenant: tenant, active: true, origin: origin, on: s)
            guard let row = try await s.raw("""
                UPDATE links SET removed_at = now(), removed_by = \(bind: actor) WHERE tenant_id = \(bind: tenant) AND id = \(bind: id) AND removed_at IS NULL RETURNING kind
                """).first() else { throw HubError(.notFound, "not_found") }
            try await AuditLog.record(AuditEvent(action: "link.removed", actor: actor, tenant: tenant, subjectType: "link", subjectID: id.uuidString,
                                                 meta: ["kind": .safe(try row.decode(column: "kind", as: String.self))], requestID: requestID), on: s)
        }
    }

    /// Macht eine entfernte Verknüpfung rückgängig. Existiert inzwischen eine gleiche aktive: 409.
    static func restore(_ id: UUID, tenant: UUID, actor: UUID, requestID: String, origin: Origin = .internal, on db: any Database) async throws -> LinkOut {
        try await inTransaction(db) { s in
            try await guardLinkEnds(id, tenant: tenant, active: false, origin: origin, on: s)
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
