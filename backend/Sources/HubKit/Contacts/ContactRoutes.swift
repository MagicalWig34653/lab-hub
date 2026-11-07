import Vapor

// Routen der Kontakte und Links (WP-K5). Vertrag: contracts/openapi.yaml. Jede Route entsteht nur zusammen mit ihrer Berechtigung (TenantGuard).
// Eigene Routentabelle `contactRoutes` (Quelle der Berechtigungsmatrix in den Kontakt-Tests), getrennt von `tenantRoutes` aus WP-K2.

extension Application {
    private struct ContactRoutesKey: StorageKey { typealias Value = [TenantRouteInfo] }
    public var contactRoutes: [TenantRouteInfo] {
        get { storage[ContactRoutesKey.self] ?? [] }
        set { storage[ContactRoutesKey.self] = newValue }
    }
}

private func uuidParam(_ req: Request, _ name: String) throws -> UUID {
    guard let id = req.parameters.get(name, as: UUID.self) else { throw HubError(.notFound, "not_found") }
    return id
}

private func contactResponse(_ out: some Content, _ req: Request, status: HTTPStatus = .ok) async throws -> Response {
    try await out.encodeResponse(status: status, for: req)
}

func registerContactRoutes(_ app: Application) {
    let api = app.grouped("api", "v1").grouped(SessionMiddleware()).grouped(RequireSession()).grouped("tenants", ":tenant")

    func on(_ method: HTTPMethod, _ path: PathComponent..., permission: String, use handler: @escaping @Sendable (Request) async throws -> Response) {
        precondition(Permissions.catalog.contains(permission), "unbekannte Berechtigung \(permission)")
        api.grouped(TenantGuard(permission: permission)).on(method, path, use: handler)
        let template = (["api", "v1", "tenants", "{tenant}"] + path.map { "\($0)" }.map { $0.hasPrefix(":") ? "{\($0.dropFirst())}" : $0 }).joined(separator: "/")
        app.contactRoutes.append(TenantRouteInfo(method: method.rawValue, path: "/" + template, permission: permission))
    }

    on(.GET, "contacts", permission: "contact.contact.read") { req in
        let tenant = try req.requireTenant().tenantID
        let role: String? = req.query["role"], kind: String? = req.query["kind"]
        if let role, !["customer", "supplier", "correspondent"].contains(role) { throw ContactValidation.fail("role") }
        if let kind, !["person", "organization"].contains(kind) { throw ContactValidation.fail("kind") }
        let page = try await ContactService.list(tenant: tenant, page: try HubPageRequest(req), q: req.query["q"], role: role, kind: kind, on: req.db)
        return try await contactResponse(page, req)
    }
    on(.POST, "contacts", permission: "contact.contact.create") { req in
        let fields = try ContactFields(try req.content.decode(ContactBody.self), creating: true)
        let out = try await ContactService.create(tenant: try req.requireTenant().tenantID, actor: try req.requireAuth().user.id, fields: fields, requestID: req.requestId, on: req.db)
        return try await contactResponse(out, req, status: .created)
    }
    on(.GET, "contacts", ":contact", permission: "contact.contact.read") { req in
        guard let out = try await ContactService.load(try uuidParam(req, "contact"), tenant: try req.requireTenant().tenantID, on: try sql(req.db))
        else { throw HubError(.notFound, "not_found") }
        return try await contactResponse(out, req)
    }
    on(.PATCH, "contacts", ":contact", permission: "contact.contact.update") { req in
        let id = try uuidParam(req, "contact")
        let fields = try ContactFields(try req.content.decode(ContactBody.self), creating: false)
        let out = try await ContactService.update(id, tenant: try req.requireTenant().tenantID, actor: try req.requireAuth().user.id, fields: fields, requestID: req.requestId, on: req.db)
        return try await contactResponse(out, req)
    }
    on(.DELETE, "contacts", ":contact", permission: "contact.contact.delete") { req in
        try await ContactService.delete(try uuidParam(req, "contact"), tenant: try req.requireTenant().tenantID, actor: try req.requireAuth().user.id, requestID: req.requestId, on: req.db)
        return Response(status: .noContent)
    }
    on(.GET, "contacts", ":contact", "duplicates", permission: "contact.contact.read") { req in
        guard let hints = try await ContactService.duplicateHints(of: try uuidParam(req, "contact"), tenant: try req.requireTenant().tenantID, on: req.db)
        else { throw HubError(.notFound, "not_found") }
        return try await contactResponse(["items": hints], req)
    }
    on(.POST, "contacts", ":contact", "merge", permission: "contact.contact.merge") { req in
        let target = try uuidParam(req, "contact")
        guard let source = (try? req.content.decode(MergeBody.self))?.source_id else { throw ContactValidation.fail("source_id", "required") }
        let out = try await ContactService.merge(source: source, into: target, tenant: try req.requireTenant().tenantID, actor: try req.requireAuth().user.id,
                                                 requestID: req.requestId, on: req.db)
        return try await contactResponse(out, req)
    }

    on(.GET, "links", permission: "contact.link.read") { req in
        guard let type: String = req.query["type"], let id: UUID = req.query["id"] else { throw ContactValidation.fail("type", "required") }
        let items = try await LinkService.list(tenant: try req.requireTenant().tenantID, type: type, id: id, includeRemoved: (req.query["include_removed"] as String?) == "true", on: req.db)
        return try await contactResponse(["items": items], req)
    }
    on(.POST, "links", permission: "contact.link.write") { req in
        let out = try await LinkService.create(tenant: try req.requireTenant().tenantID, actor: try req.requireAuth().user.id,
                                               body: try req.content.decode(LinkBody.self), requestID: req.requestId, on: req.db)
        return try await contactResponse(out, req, status: .created)
    }
    on(.DELETE, "links", ":link", permission: "contact.link.write") { req in
        try await LinkService.remove(try uuidParam(req, "link"), tenant: try req.requireTenant().tenantID, actor: try req.requireAuth().user.id, requestID: req.requestId, on: req.db)
        return Response(status: .noContent)
    }
    on(.POST, "links", ":link", "restore", permission: "contact.link.write") { req in
        let out = try await LinkService.restore(try uuidParam(req, "link"), tenant: try req.requireTenant().tenantID, actor: try req.requireAuth().user.id, requestID: req.requestId, on: req.db)
        return try await contactResponse(out, req)
    }
}
