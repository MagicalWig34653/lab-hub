import Vapor
import Foundation

// Routen der Mandanten (WP-K2). Vertrag: contracts/openapi.yaml. Zugriff: Mandantenrouten nur über `TenantRouteBuilder` (Guard + Berechtigung).

private struct CreateTenantBody: Content { let name: String? }
private struct RoleBody: Content { let role: String? }
private struct InvitationBody: Content { let role: String?; let expires_in_hours: Int? }

private func parseRole(_ raw: String?, default fallback: Role? = nil) throws -> Role {
    if let raw {
        guard let role = Role(rawValue: raw) else { throw HubError(.unprocessableEntity, "validation_failed", errors: [FieldError(field: "role", code: "invalid")]) }
        return role
    }
    guard let fallback else { throw HubError(.unprocessableEntity, "validation_failed", errors: [FieldError(field: "role", code: "required")]) }
    return fallback
}

func registerTenancyRoutes(_ app: Application) {
    let api = app.grouped("api", "v1").grouped(SessionMiddleware())

    // Ohne Mandant in der URL: nur normale Sitzungen
    let normal = api.grouped(RequireSession())
    normal.get("tenants") { req async throws -> Response in
        let list = try await TenancyService.memberships(of: try req.requireAuth().user.id, on: req.db)
        return try jsonResponse(["items": list.map { ["id": $0.tenantID.uuidString, "name": $0.name, "role": $0.role.rawValue] }])
    }
    // Betreiber legen Mandanten an und werden deren Owner
    api.grouped(RequireSession(operator: true)).post("tenants") { req async throws -> Response in
        let name = (try? req.content.decode(CreateTenantBody.self))?.name ?? ""
        let id = try await TenancyService.createTenant(name: name, owner: try req.requireAuth().user.id, requestID: req.requestId, on: req.db)
        return try jsonResponse(["id": id.uuidString, "name": name, "role": Role.owner.rawValue], status: .created)
    }

    // Mit Mandant in der URL: Guard + Berechtigung
    let tenant = TenantRouteBuilder(app, api: api)
    tenant.on(.GET, permission: "tenant.tenant.read") { req async throws -> Response in
        let c = try req.requireTenant()
        guard let name = try await TenancyService.tenantName(c.tenantID, on: req.db) else { throw HubError(.notFound, "not_found") }
        return try jsonResponse(["id": c.tenantID.uuidString, "name": name, "role": c.role.rawValue, "permissions": c.permissions.sorted()])
    }
    tenant.on(.GET, "members", permission: "tenant.member.read") { req async throws -> Response in
        let list = try await TenancyService.members(of: try req.requireTenant().tenantID, on: req.db)
        return try jsonResponse(["items": list.map { ["user_id": $0.userID.uuidString, "handle": $0.handle, "display_name": $0.displayName,
                                                       "role": $0.role.rawValue, "created_at": iso($0.createdAt)] }])
    }
    tenant.on(.PATCH, "members", ":user", permission: "tenant.member.manage") { req async throws -> Response in
        guard let target = req.parameters.get("user", as: UUID.self) else { throw HubError(.notFound, "not_found") }
        let role = try parseRole((try? req.content.decode(RoleBody.self))?.role)
        try await TenancyService.setRole(tenant: try req.requireTenant().tenantID, target: target, to: role, actor: try req.requireAuth().user.id,
                                         requestID: req.requestId, on: req.db)
        return try jsonResponse(["user_id": target.uuidString, "role": role.rawValue])
    }
    tenant.on(.DELETE, "members", ":user", permission: "tenant.member.manage") { req async throws -> Response in
        guard let target = req.parameters.get("user", as: UUID.self) else { throw HubError(.notFound, "not_found") }
        try await TenancyService.removeMember(tenant: try req.requireTenant().tenantID, target: target, actor: try req.requireAuth().user.id,
                                              requestID: req.requestId, on: req.db)
        return Response(status: .noContent)
    }
    tenant.on(.POST, "invitations", permission: "tenant.member.invite") { req async throws -> Response in
        let body = try? req.content.decode(InvitationBody.self)
        let role = try parseRole(body?.role, default: .member)
        if let hours = body?.expires_in_hours, !(1...720).contains(hours) {
            throw HubError(.unprocessableEntity, "validation_failed", errors: [FieldError(field: "expires_in_hours", code: "invalid")])
        }
        let service = try req.application.authService()
        let inv = try await service.createInvitation(by: try req.requireAuth(), tenant: try req.requireTenant().tenantID, role: role,
                                                     ttlSeconds: body?.expires_in_hours.map { $0 * 3600 }, requestID: req.requestId, on: req.db)
        var out: [String: Any] = ["id": inv.id.uuidString, "token": inv.token, "expires_at": iso(inv.expiresAt), "role": role.rawValue]
        if !service.settings.origin.isEmpty { out["link"] = "\(service.settings.origin)/invite/\(inv.token)" }
        return try jsonResponse(out, status: .created)
    }
}
