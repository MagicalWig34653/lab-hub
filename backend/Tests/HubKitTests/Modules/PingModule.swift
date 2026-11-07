import Vapor
import Fluent
import SQLKit
@testable import HubKit

/// Beispielmodul nur für Tests (WP-K3): eigene Tabelle, Berechtigungen, Navigation, Routen, Aktivierungs-Hook.
struct PingModule: HubModule {
    let key = "ping"
    var permissions: [PermissionDefinition] {
        [PermissionDefinition("ping.item.read", roles: [.accountant, .member, .taxAdvisor]),
         PermissionDefinition("ping.item.write", roles: [.accountant, .member])]
    }
    var migrations: [any Migration] { [CreatePingItems()] }
    var navigation: [NavigationItem] { [NavigationItem(key: "ping", labelKey: "nav.ping", path: "/ping", permission: "ping.item.read")] }

    func registerRoutes(_ routes: ModuleRoutes) throws {
        routes.on(.GET, "items", permission: "ping.item.read") { req async throws -> Response in
            let rows = try await sql(req.db).raw("SELECT label FROM ping_items WHERE tenant_id = \(bind: try req.requireTenant().tenantID) ORDER BY label").all()
            return try jsonResponse(["items": try rows.map { try $0.decode(column: "label", as: String.self) }])
        }
        routes.on(.POST, "items", permission: "ping.item.write") { req async throws -> Response in
            struct Body: Content { let label: String }
            let body = try req.content.decode(Body.self)
            try await sql(req.db).raw("INSERT INTO ping_items (tenant_id, label) VALUES (\(bind: try req.requireTenant().tenantID), \(bind: body.label))").run()
            return try jsonResponse(["label": body.label], status: .created)
        }
        routes.on(.GET, "items", ":item", permission: "ping.item.read") { req async throws -> Response in
            guard let id = req.parameters.get("item", as: UUID.self),
                  let row = try await sql(req.db).raw("SELECT label FROM ping_items WHERE id = \(bind: id) AND tenant_id = \(bind: try req.requireTenant().tenantID)").first()
            else { throw HubError(.notFound, "not_found") }
            return try jsonResponse(["label": try row.decode(column: "label", as: String.self)])
        }
    }

    func onActivate(tenant: UUID, on db: any SQLDatabase) async throws {
        try await db.raw("""
            INSERT INTO ping_items (tenant_id, label) SELECT \(bind: tenant), 'activated'
            WHERE NOT EXISTS (SELECT 1 FROM ping_items WHERE tenant_id = \(bind: tenant) AND label = 'activated')
            """).run()
    }
}

/// Zweites Testmodul mit harter Abhängigkeit.
struct PongModule: HubModule {
    let key = "pong"
    var requires: [ModuleKey] { ["ping"] }
    var permissions: [PermissionDefinition] { [PermissionDefinition("pong.thing.read", roles: [.member])] }
    var navigation: [NavigationItem] { [NavigationItem(key: "pong", labelKey: "nav.pong", path: "/pong")] }
    func registerRoutes(_ routes: ModuleRoutes) throws {
        routes.on(.GET, "thing", permission: "pong.thing.read") { _ async throws -> Response in try jsonResponse(["pong": true]) }
    }
}

struct CreatePingItems: AsyncMigration {
    let name = "ping_001_items"
    func prepare(on db: any Database) async throws {
        try await run(db, ["""
            CREATE TABLE ping_items (id uuid PRIMARY KEY DEFAULT gen_random_uuid(), tenant_id uuid NOT NULL REFERENCES tenants (id), label text NOT NULL)
            """])
    }
    func revert(on db: any Database) async throws { try await run(db, ["DROP TABLE ping_items"]) }
}
