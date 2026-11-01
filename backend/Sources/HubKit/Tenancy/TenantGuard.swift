import Vapor
import SQLKit

/// Mandant und Rolle der aktuellen Anfrage (aus `memberships`, bei jeder Anfrage frisch aus der Datenbank: kein Cache, Änderungen wirken sofort auf allen Instanzen).
struct TenantContext: Sendable {
    let tenantID: UUID
    let role: Role
    var permissions: Set<String> { Permissions.of(role) }
}

struct TenantContextKey: StorageKey { typealias Value = TenantContext }

extension Request {
    var tenantContext: TenantContext? { storage[TenantContextKey.self] }
    func requireTenant() throws -> TenantContext {
        guard let c = tenantContext else { throw HubError(.notFound, "not_found") }
        return c
    }
    /// Zentrale Prüfung für Handler, die mehr als die Routen-Berechtigung brauchen: `try req.require("dms.document.read")`.
    func require(_ permission: String) throws {
        guard try requireTenant().permissions.contains(permission) else { throw HubError(.forbidden, "forbidden") }
    }
}

/// Guard für Routen unter `/api/v1/tenants/:tenant/...`.
/// Reihenfolge: kein Mitglied (oder unbekannter, ungültiger, deaktivierter Mandant) = 404 ohne Existenzauskunft; Mitglied ohne Berechtigung = 403.
struct TenantGuard: AsyncMiddleware {
    let permission: String
    func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        let auth = try request.requireAuth()
        guard let tenant = request.parameters.get("tenant", as: UUID.self),
              let role = try await TenancyService.role(of: auth.user.id, in: tenant, on: request.db)
        else { throw HubError(.notFound, "not_found") }
        guard Permissions.of(role).contains(permission) else { throw HubError(.forbidden, "forbidden") }
        request.storage[TenantContextKey.self] = TenantContext(tenantID: tenant, role: role)
        return try await next.respond(to: request)
    }
}

/// Eine mandantengefilterte Route samt geforderter Berechtigung (Quelle der generierten Matrix, AK-K2-1).
public struct TenantRouteInfo: Sendable, Equatable {
    public let method: String
    /// Vertragsschreibweise, z. B. `/api/v1/tenants/{tenant}/members/{user}`.
    public let path: String
    public let permission: String
}

extension Application {
    private struct TenantRoutesKey: StorageKey { typealias Value = [TenantRouteInfo] }
    /// Beim Start gefüllt (Routentabelle, kein Laufzeitzustand).
    public var tenantRoutes: [TenantRouteInfo] {
        get { storage[TenantRoutesKey.self] ?? [] }
        set { storage[TenantRoutesKey.self] = newValue }
    }
}

/// Registriert Routen unter `/api/v1/tenants/:tenant` nur zusammen mit ihrer Berechtigung. So kann keine Mandantenroute ohne Guard und ohne Matrixeintrag entstehen.
struct TenantRouteBuilder {
    let app: Application
    private let group: any RoutesBuilder

    init(_ app: Application, api: any RoutesBuilder) {
        self.app = app
        self.group = api.grouped(RequireSession()).grouped("tenants", ":tenant")
    }

    func on(_ method: HTTPMethod, _ path: PathComponent..., permission: String, use handler: @escaping @Sendable (Request) async throws -> Response) {
        precondition(Permissions.catalog.contains(permission), "unbekannte Berechtigung \(permission)")
        group.grouped(TenantGuard(permission: permission)).on(method, path, use: handler)
        let template = (["api", "v1", "tenants", "{tenant}"] + path.map { "\($0)" }.map { $0.hasPrefix(":") ? "{\($0.dropFirst())}" : $0 }).joined(separator: "/")
        app.tenantRoutes.append(TenantRouteInfo(method: method.rawValue, path: "/" + template, permission: permission))
    }
}
