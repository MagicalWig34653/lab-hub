import Vapor
import Foundation

// Routen des Modul-Systems (WP-K3). Vertrag: contracts/openapi.yaml.
// GET /modules (Katalog der Installation), PUT /modules/{module} (Betreiber), GET|PUT /tenants/{tenant}/modules[/{module}] (Mandant).

private struct EnabledBody: Content { let enabled: Bool? }

private func parseEnabled(_ req: Request) throws -> Bool {
    guard let enabled = (try? req.content.decode(EnabledBody.self))?.enabled else {
        throw HubError(.unprocessableEntity, "validation_failed", errors: [FieldError(field: "enabled", code: "required")])
    }
    return enabled
}

private func describe(_ m: any HubModule) -> [String: Any] {
    ["key": m.key, "requires": m.requires, "enhances": m.enhances]
}

func registerModuleRoutes(_ app: Application) throws {
    let api = app.grouped("api", "v1").grouped(SessionMiddleware())

    // Katalog der installierten Module (ohne Mandantenbezug)
    api.grouped(RequireSession()).get("modules") { req async throws -> Response in
        let off = try await ModuleService.uninstalled(on: try sql(req.db))
        return try jsonResponse(["items": req.application.hubModules.modules.map { describe($0).merging(["installed": !off.contains($0.key)]) { a, _ in a } }])
    }
    // Betreiber schaltet ein Modul für die ganze Installation
    api.grouped(RequireSession(operator: true)).put("modules", ":module") { req async throws -> Response in
        guard let key = req.parameters.get("module") else { throw HubError(.notFound, "not_found") }
        let installed = try parseEnabled(req)
        try await ModuleService.setInstalled(key, installed: installed, actor: try req.requireAuth().user.id, requestID: req.requestId,
                                             registry: req.application.hubModules, on: req.db)
        return try jsonResponse(["key": key, "installed": installed])
    }

    // Mandant: Status und Navigation, Schalter
    let tenant = TenantRouteBuilder(app, api: api)
    tenant.on(.GET, "modules", permission: "tenant.module.read") { req async throws -> Response in
        let c = try req.requireTenant()
        let registry = req.application.hubModules
        let statuses = try await ModuleService.statuses(registry, tenant: c.tenantID, on: try sql(req.db))
        var items: [[String: Any]] = [], navigation: [[String: Any]] = []
        for st in statuses {
            guard let m = registry.module(st.key) else { continue }
            items.append(describe(m).merging(["installed": st.installed, "enabled": st.enabled, "effective": st.effective]) { a, _ in a })
            guard st.effective else { continue }  // deaktivierte Module fehlen in der Navigation (AK-K3-2)
            let allowed = registry.permissions(of: c.role, module: st.key)
            for n in m.navigation where n.permission.map(allowed.contains) ?? true {
                navigation.append(["module": st.key, "key": n.key, "label_key": n.labelKey, "path": n.path])
            }
        }
        return try jsonResponse(["items": items, "navigation": navigation])
    }
    tenant.on(.PUT, "modules", ":module", permission: "tenant.module.manage") { req async throws -> Response in
        guard let key = req.parameters.get("module") else { throw HubError(.notFound, "not_found") }
        let enabled = try parseEnabled(req)
        let c = try req.requireTenant()
        let registry = req.application.hubModules
        try await ModuleService.setTenant(key, enabled: enabled, tenant: c.tenantID, actor: try req.requireAuth().user.id, requestID: req.requestId,
                                          registry: registry, on: req.db)
        let st = try await ModuleService.statuses(registry, tenant: c.tenantID, on: try sql(req.db)).first { $0.key == key }
        return try jsonResponse(["key": key, "enabled": enabled, "installed": st?.installed ?? false, "effective": st?.effective ?? false])
    }

    // Eigene Routen der Module
    for module in app.hubModules.modules {
        try module.registerRoutes(ModuleRoutes(app, api: api, module: module))
    }
}
