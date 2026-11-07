import Vapor
import SQLKit

/// Eine Modulroute samt geforderter Berechtigung (Quelle des generischen Guard-Tests, AK-K3-1).
public struct ModuleRouteInfo: Sendable, Equatable {
    public let module: ModuleKey
    public let method: String
    /// Vertragsschreibweise, z. B. `/api/v1/tenants/{tenant}/ping/items`.
    public let path: String
    public let permission: String
}

extension Application {
    private struct ModuleRoutesKey: StorageKey { typealias Value = [ModuleRouteInfo] }
    /// Beim Start gefüllt (Routentabelle, kein Laufzeitzustand).
    public var moduleRoutes: [ModuleRouteInfo] {
        get { storage[ModuleRoutesKey.self] ?? [] }
        set { storage[ModuleRoutesKey.self] = newValue }
    }
}

/// Guard jeder Modulroute. Reihenfolge: kein Mitglied (oder unbekannter/deaktivierter Mandant) = 404 `not_found`;
/// Modul nicht wirksam (Betreiber aus, Mandant aus oder `requires` fehlt) = 404 `module_disabled`; Mitglied ohne Berechtigung = 403.
struct ModuleGuard: AsyncMiddleware {
    let module: ModuleKey
    let permission: String
    func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        let auth = try request.requireAuth()
        guard let tenant = request.parameters.get("tenant", as: UUID.self),
              let role = try await TenancyService.role(of: auth.user.id, in: tenant, on: request.db)
        else { throw HubError(.notFound, "not_found") }
        let registry = request.application.hubModules
        let statuses = try await ModuleService.statuses(registry, tenant: tenant, on: try sql(request.db))
        guard statuses.first(where: { $0.key == module })?.effective == true else { throw HubError(.notFound, "module_disabled") }
        let modulePermissions = registry.permissions(of: role, module: module)
        guard modulePermissions.contains(permission) else { throw HubError(.forbidden, "forbidden") }
        request.storage[TenantContextKey.self] = TenantContext(tenantID: tenant, role: role, permissions: Permissions.of(role).union(modulePermissions))
        return try await next.respond(to: request)
    }
}

/// Routen eines Moduls unter `/api/v1/tenants/:tenant/<key>/...`. Einziger Weg, Modulrouten zu registrieren.
public struct ModuleRoutes {
    public let key: ModuleKey
    let app: Application
    private let group: any RoutesBuilder

    init(_ app: Application, api: any RoutesBuilder, module: any HubModule) {
        self.app = app
        self.key = module.key
        self.group = api.grouped(RequireSession()).grouped("tenants", ":tenant", PathComponent(stringLiteral: module.key))
    }

    /// `permission` muss vom Modul deklariert sein; ohne Deklaration entsteht keine Route.
    /// `body: .stream` (WP-D2, Uploads) liefert den Body gestreamt statt gepuffert; die Größe begrenzt dann der Handler selbst.
    public func on(_ method: HTTPMethod, _ path: PathComponent..., permission: String, body: HTTPBodyStreamStrategy = .collect,
                   use handler: @escaping @Sendable (Request) async throws -> Response) {
        precondition(app.hubModules.module(key)?.permissions.contains { $0.name == permission } == true, "Berechtigung \(permission) nicht von Modul \(key) deklariert")
        group.grouped(ModuleGuard(module: key, permission: permission)).on(method, path, body: body, use: handler)
        let rest = path.map { "\($0)" }.map { $0.hasPrefix(":") ? "{\($0.dropFirst())}" : $0 }
        let template = (["api", "v1", "tenants", "{tenant}", key] + rest).joined(separator: "/")
        app.moduleRoutes.append(ModuleRouteInfo(module: key, method: method.rawValue, path: "/" + template, permission: permission))
    }
}
