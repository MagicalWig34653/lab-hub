import Vapor
import Fluent
import SQLKit

/// Mandanten und Mitgliedschaften (WP-K2). Alle Zustände liegen in der Datenbank; Änderungen laufen in einer Transaktion mit Audit-Eintrag.
enum TenancyService {
    struct MembershipInfo: Sendable { let tenantID: UUID; let name: String; let role: Role }
    struct MemberInfo: Sendable { let userID: UUID; let handle: String; let displayName: String; let role: Role; let createdAt: Date }

    /// Rolle des Nutzers im Mandanten; `nil`, wenn kein Mitglied oder der Mandant deaktiviert ist.
    static func role(of user: UUID, in tenant: UUID, on db: any Database) async throws -> Role? {
        try await role(of: user, in: tenant, on: sql(db))
    }

    static func role(of user: UUID, in tenant: UUID, on s: any SQLDatabase) async throws -> Role? {
        guard let row = try await s.raw("""
            SELECT m.role FROM memberships m JOIN tenants t ON t.id = m.tenant_id
            WHERE m.tenant_id = \(bind: tenant) AND m.user_id = \(bind: user) AND t.disabled_at IS NULL
            """).first() else { return nil }
        return Role(rawValue: try row.decode(column: "role", as: String.self))
    }

    static func memberships(of user: UUID, on db: any Database) async throws -> [MembershipInfo] {
        try await sql(db).raw("""
            SELECT t.id, t.name, m.role FROM memberships m JOIN tenants t ON t.id = m.tenant_id
            WHERE m.user_id = \(bind: user) AND t.disabled_at IS NULL ORDER BY t.created_at, t.id
            """).all().compactMap { row in
            guard let role = Role(rawValue: (try? row.decode(column: "role", as: String.self)) ?? "") else { return nil }
            return MembershipInfo(tenantID: try row.decode(column: "id", as: UUID.self), name: try row.decode(column: "name", as: String.self), role: role)
        }
    }

    static func tenantName(_ tenant: UUID, on db: any Database) async throws -> String? {
        try await sql(db).raw("SELECT name FROM tenants WHERE id = \(bind: tenant) AND disabled_at IS NULL").first()?.decode(column: "name", as: String.self)
    }

    static func members(of tenant: UUID, on db: any Database) async throws -> [MemberInfo] {
        try await sql(db).raw("""
            SELECT u.id, u.handle, u.display_name, m.role, m.created_at FROM memberships m JOIN users u ON u.id = m.user_id
            WHERE m.tenant_id = \(bind: tenant) AND u.disabled_at IS NULL ORDER BY m.created_at, u.id
            """).all().compactMap { row in
            guard let role = Role(rawValue: (try? row.decode(column: "role", as: String.self)) ?? "") else { return nil }
            return MemberInfo(userID: try row.decode(column: "id", as: UUID.self), handle: try row.decode(column: "handle", as: String.self),
                              displayName: try row.decode(column: "display_name", as: String.self), role: role,
                              createdAt: try row.decode(column: "created_at", as: Date.self))
        }
    }

    /// Legt einen Mandanten an; der Aufrufer wird Owner. (Aufrufer prüft die Betreiberrolle.)
    static func createTenant(name: String, owner: UUID, requestID: String, on db: any Database) async throws -> UUID {
        guard (1...80).contains(name.count) else { throw HubError(.unprocessableEntity, "validation_failed", errors: [FieldError(field: "name", code: "invalid")]) }
        return try await inTransaction(db) { s in
            try await createTenant(name: name, owner: owner, requestID: requestID, on: s)
        }
    }

    /// Variante in fremder Transaktion (Bootstrap).
    static func createTenant(name: String, owner: UUID, requestID: String, on s: any SQLDatabase) async throws -> UUID {
        guard let row = try await s.raw("INSERT INTO tenants (name) VALUES (\(bind: name)) RETURNING id").first() else { throw Abort(.internalServerError) }
        let id = try row.decode(column: "id", as: UUID.self)
        try await s.raw("INSERT INTO memberships (tenant_id, user_id, role) VALUES (\(bind: id), \(bind: owner), 'owner')").run()
        try await AuditLog.record(AuditEvent(action: "tenant.created", actor: owner, tenant: id, subjectType: "tenant", subjectID: id.uuidString, requestID: requestID), on: s)
        return id
    }

    /// Sperrt den Mandanten (serialisiert Mitgliedschaftsänderungen), prüft die Berechtigung des Akteurs erneut und liefert die Zielrolle.
    private static func lockedTarget(tenant: UUID, target: UUID, actor: UUID, on s: any SQLDatabase) async throws -> Role {
        guard try await s.raw("SELECT id FROM tenants WHERE id = \(bind: tenant) AND disabled_at IS NULL FOR UPDATE").first() != nil else { throw HubError(.notFound, "not_found") }
        guard let actorRole = try await role(of: actor, in: tenant, on: s) else { throw HubError(.notFound, "not_found") }
        guard Permissions.of(actorRole).contains("tenant.member.manage") else { throw HubError(.forbidden, "forbidden") }
        guard let current = try await role(of: target, in: tenant, on: s) else { throw HubError(.notFound, "not_found") }
        return current
    }

    private static func ownerCount(_ tenant: UUID, on s: any SQLDatabase) async throws -> Int64 {
        try await s.raw("SELECT count(*)::bigint AS n FROM memberships WHERE tenant_id = \(bind: tenant) AND role = 'owner'").first()?.decode(column: "n", as: Int64.self) ?? 0
    }

    /// Ändert die Rolle eines Mitglieds. Der letzte Owner bleibt Owner (409 `last_owner`).
    static func setRole(tenant: UUID, target: UUID, to new: Role, actor: UUID, requestID: String, on db: any Database) async throws {
        try await inTransaction(db) { s in
            let current = try await lockedTarget(tenant: tenant, target: target, actor: actor, on: s)
            if current == .owner, new != .owner, try await ownerCount(tenant, on: s) <= 1 { throw HubError(.conflict, "last_owner") }
            try await s.raw("UPDATE memberships SET role = \(bind: new.rawValue) WHERE tenant_id = \(bind: tenant) AND user_id = \(bind: target)").run()
            try await AuditLog.record(AuditEvent(action: "tenant.member_role_changed", actor: actor, tenant: tenant, subjectType: "user", subjectID: target.uuidString,
                                                 meta: ["from": .safe(current.rawValue), "to": .safe(new.rawValue)], requestID: requestID), on: s)
        }
    }

    /// Entfernt ein Mitglied. Der letzte Owner kann nicht entfernt werden (409 `last_owner`).
    static func removeMember(tenant: UUID, target: UUID, actor: UUID, requestID: String, on db: any Database) async throws {
        try await inTransaction(db) { s in
            let current = try await lockedTarget(tenant: tenant, target: target, actor: actor, on: s)
            if current == .owner, try await ownerCount(tenant, on: s) <= 1 { throw HubError(.conflict, "last_owner") }
            try await s.raw("DELETE FROM memberships WHERE tenant_id = \(bind: tenant) AND user_id = \(bind: target)").run()
            try await AuditLog.record(AuditEvent(action: "tenant.member_removed", actor: actor, tenant: tenant, subjectType: "user", subjectID: target.uuidString,
                                                 meta: ["role": .safe(current.rawValue)], requestID: requestID), on: s)
        }
    }
}
