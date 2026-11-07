import XCTVapor
import Fluent
import SQLKit
@testable import HubKit

/// WP-K3: Modul-System. Alle Daten synthetisch; Testmodule `ping` und `pong` (siehe PingModule.swift).
final class ModuleTests: AuthTestCase {
    override var testModules: [any HubModule] { [PingModule(), PongModule()] }

    // MARK: Hilfen

    func tenantOf(_ s: TestSession) async throws -> String {
        try await scalar("SELECT tenant_id::text AS v FROM memberships WHERE user_id = '\(s.userID)' ORDER BY created_at LIMIT 1", as: String.self)
    }

    func addUser(_ role: Role, handle: String, tenant: String, by: TestSession) async throws -> TestSession {
        let r = try await register(app1, VirtualAuthenticator(), invite: try await invite(app1, by: by, tenant: tenant, role: role.rawValue), handle: handle)
        XCTAssertEqual(r.status, .created, "\(r.json)")
        return session(r, handle: handle)
    }

    @discardableResult
    func setModule(_ app: Application, _ tenant: String, _ key: String, _ enabled: Bool, by s: TestSession) async throws -> Resp {
        try await call(app, .PUT, "api/v1/tenants/\(tenant)/modules/\(key)", json: ["enabled": enabled], token: s.token)
    }

    func path(_ template: String, tenant: String, item: String = UUID().uuidString) -> String {
        String(template.dropFirst()).replacingOccurrences(of: "{tenant}", with: tenant).replacingOccurrences(of: "{item}", with: item)
    }

    func send(_ app: Application, _ r: ModuleRouteInfo, tenant: String, token: String?) async throws -> Resp {
        try await call(app, HTTPMethod(rawValue: r.method), path(r.path, tenant: tenant), json: r.method == "GET" ? nil : ["label": "x"], token: token)
    }

    func navigationKeys(_ app: Application, _ tenant: String, _ s: TestSession) async throws -> [String] {
        let r = try await call(app, .GET, "api/v1/tenants/\(tenant)/modules", token: s.token)
        XCTAssertEqual(r.status, .ok, "\(r.json)")
        return (r.json["navigation"] as? [[String: Any]] ?? []).compactMap { $0["module"] as? String }
    }

    // MARK: AK-K3-1 Guard über alle Routen

    /// AK-K3-1: Ohne Aktivierung liefert jede Modulroute 404 `module_disabled` (generisch über die Routenliste der Registry).
    func testAKK3_1_DisabledModuleReturns404OnAllRoutes() async throws {
        let owner = try await bootstrap(app1, VirtualAuthenticator())
        let tenant = try await tenantOf(owner)
        let routes = app1.moduleRoutes
        XCTAssertEqual(Set(routes.map(\.module)), ["ping", "pong"])
        // Es gibt keine Modulroute am Guard vorbei: alle Server-Routen unter einem Modulpfad stehen in der Registry.
        let moduleOps = OpenAPIContract.serverOperations(app1).filter { $0.contains("/api/v1/tenants/{tenant}/ping") || $0.contains("/api/v1/tenants/{tenant}/pong") }
        XCTAssertEqual(moduleOps, Set(routes.map { "\($0.method) \($0.path)" }))

        var n = 0
        for route in routes {
            let app = n % 2 == 0 ? app1! : app2!; n += 1
            let r = try await send(app, route, tenant: tenant, token: owner.token)
            XCTAssertEqual(r.status, .notFound, "\(route.method) \(route.path)")
            XCTAssertEqual(r.problemCode, "module_disabled", "\(route.method) \(route.path)")
            XCTAssertEqual(r.headers.contentType?.serialize(), "application/problem+json")
            let anon = try await send(app, route, tenant: tenant, token: nil)
            XCTAssertEqual(anon.status, .unauthorized, "\(route.method) \(route.path)")
        }
        // Mandant ohne Modul-Aktivierung: auch der Mandant, in dem ein anderer das Modul aktiviert hat, bleibt getrennt
        let other = try await call(app1, .POST, "api/v1/tenants", json: ["name": "Zweiter"], token: owner.token).json["id"] as! String
        try await setModule(app1, other, "ping", true, by: owner)
        for route in routes where route.module == "ping" {
            let r = try await send(app1, route, tenant: tenant, token: owner.token)
            XCTAssertEqual(r.problemCode, "module_disabled", "Aktivierung in Mandant B darf Mandant A nicht öffnen: \(route.path)")
        }
    }

    /// AK-K3-1: Bei aktivem Modul gilt je Route die Modulberechtigung (Matrix Rolle x Route); Nichtmitglieder erhalten 404 `not_found`.
    func testAKK3_1_EnabledModulePermissionMatrixAndTenantSeparation() async throws {
        let owner = try await bootstrap(app1, VirtualAuthenticator())
        let tenant = try await tenantOf(owner)
        var sessions: [Role: TestSession] = [.owner: owner]
        for role in Role.allCases where role != .owner { sessions[role] = try await addUser(role, handle: "u_" + role.rawValue, tenant: tenant, by: owner) }
        let v1 = try await setModule(app1, tenant, "ping", true, by: owner).status
        XCTAssertEqual(v1, .ok)
        let v2 = try await setModule(app2, tenant, "pong", true, by: owner).status
        XCTAssertEqual(v2, .ok)

        var cells = 0
        for route in app1.moduleRoutes {
            let allowed = app1.hubModules.module(route.module)!.permissions.first { $0.name == route.permission }!.roles
            for role in Role.allCases {
                let app = cells % 2 == 0 ? app1! : app2!; cells += 1
                let r = try await send(app, route, tenant: tenant, token: sessions[role]!.token)
                if role == .owner || allowed.contains(role) {
                    XCTAssertNotEqual(r.problemCode, "forbidden", "\(role) \(route.method) \(route.path)")
                    XCTAssertNotEqual(r.problemCode, "module_disabled", "\(role) \(route.method) \(route.path)")
                    XCTAssertLessThan(r.status.code, 500)
                } else {
                    XCTAssertEqual(r.status, .forbidden, "\(role) \(route.method) \(route.path)")
                    XCTAssertEqual(r.problemCode, "forbidden")
                }
            }
        }
        XCTAssertEqual(cells, app1.moduleRoutes.count * Role.allCases.count)

        // Mandantentrennung: Carol im Mandanten B sieht Mandant A nicht (404), und Daten bleiben je Mandant getrennt.
        let tenantB = try await call(app1, .POST, "api/v1/tenants", json: ["name": "B"], token: owner.token).json["id"] as! String
        let carol = try await addUser(.owner, handle: "carol", tenant: tenantB, by: owner)
        try await setModule(app1, tenantB, "ping", true, by: carol)
        let create = try await call(app1, .POST, "api/v1/tenants/\(tenant)/ping/items", json: ["label": "geheim-A"], token: owner.token)
        XCTAssertEqual(create.status, .created)
        for route in app1.moduleRoutes {
            let r = try await send(app2, route, tenant: tenant, token: carol.token)
            XCTAssertEqual(r.status, .notFound, "\(route.path)"); XCTAssertEqual(r.problemCode, "not_found", "\(route.path)")
        }
        let listB = try await call(app1, .GET, "api/v1/tenants/\(tenantB)/ping/items", token: carol.token)
        XCTAssertEqual(listB.json["items"] as? [String], ["activated"])
        let listA = try await call(app1, .GET, "api/v1/tenants/\(tenant)/ping/items", token: owner.token)
        XCTAssertTrue((listA.json["items"] as? [String] ?? []).contains("geheim-A"))
        XCTAssertFalse((listB.json["items"] as? [String] ?? []).contains("geheim-A"))
    }

    // MARK: AK-K3-2 Status und Navigation

    func testAKK3_2_ListShowsStatusAndNavigationOnlyForEffectiveModules() async throws {
        let owner = try await bootstrap(app1, VirtualAuthenticator())
        let tenant = try await tenantOf(owner)
        let advisor = try await addUser(.taxAdvisor, handle: "advisor", tenant: tenant, by: owner)
        let viewer = try await addUser(.customerViewer, handle: "viewer", tenant: tenant, by: owner)

        var r = try await call(app1, .GET, "api/v1/tenants/\(tenant)/modules", token: owner.token)
        XCTAssertEqual(r.status, .ok)
        var items = r.json["items"] as? [[String: Any]] ?? []
        XCTAssertEqual(items.compactMap { $0["key"] as? String }, ["ping", "pong"])
        XCTAssertTrue(items.allSatisfy { $0["enabled"] as? Bool == false && $0["effective"] as? Bool == false && $0["installed"] as? Bool == true })
        XCTAssertEqual(items.last?["requires"] as? [String], ["ping"])
        var nav = try await navigationKeys(app1, tenant, owner)
        XCTAssertEqual(nav, [])

        try await setModule(app1, tenant, "ping", true, by: owner)
        try await setModule(app1, tenant, "pong", true, by: owner)
        r = try await call(app2, .GET, "api/v1/tenants/\(tenant)/modules", token: owner.token)
        items = r.json["items"] as? [[String: Any]] ?? []
        XCTAssertTrue(items.allSatisfy { $0["effective"] as? Bool == true })
        let navItems = r.json["navigation"] as? [[String: Any]] ?? []
        XCTAssertEqual(navItems.first?["label_key"] as? String, "nav.ping")
        XCTAssertEqual(navItems.first?["path"] as? String, "/ping")
        nav = try await navigationKeys(app1, tenant, owner)
        XCTAssertEqual(nav, ["ping", "pong"])
        // Menü je Rolle: der Steuerberater hat ping.item.read, die Kundenansicht nicht (der pong-Eintrag ist nicht an eine Berechtigung gebunden)
        let advisorNav = try await navigationKeys(app1, tenant, advisor)
        XCTAssertEqual(advisorNav, ["ping", "pong"])
        let viewerNav = try await navigationKeys(app1, tenant, viewer)
        XCTAssertEqual(viewerNav, ["pong"])

        try await setModule(app1, tenant, "pong", false, by: owner)
        nav = try await navigationKeys(app1, tenant, owner)
        XCTAssertEqual(nav, ["ping"])  // deaktivierte Module fehlen in navigation
        let status = (try await call(app1, .GET, "api/v1/tenants/\(tenant)/modules", token: owner.token)).json["items"] as? [[String: Any]] ?? []
        XCTAssertEqual(status.last?["enabled"] as? Bool, false)

        // Katalog der Installation (ohne Mandant)
        let catalog = try await call(app1, .GET, "api/v1/modules", token: viewer.token)
        XCTAssertEqual(catalog.status, .ok)
        XCTAssertEqual((catalog.json["items"] as? [[String: Any]])?.compactMap { $0["key"] as? String }, ["ping", "pong"])
    }

    // MARK: AK-K3-3 Abhängigkeiten

    func testAKK3_3_RequiresAndRequiredByAreRejectedWith409() async throws {
        let owner = try await bootstrap(app1, VirtualAuthenticator())
        let tenant = try await tenantOf(owner)

        var r = try await setModule(app1, tenant, "pong", true, by: owner)
        XCTAssertEqual(r.status, .conflict); XCTAssertEqual(r.problemCode, "module_requires")
        XCTAssertEqual((r.json["errors"] as? [[String: Any]])?.first?["code"] as? String, "ping")
        let none = try await scalar("SELECT count(*)::bigint AS v FROM tenant_modules", as: Int64.self)
        XCTAssertEqual(none, 0)

        let v3 = try await setModule(app1, tenant, "ping", true, by: owner).status
        XCTAssertEqual(v3, .ok)
        r = try await setModule(app2, tenant, "pong", true, by: owner)
        XCTAssertEqual(r.status, .ok); XCTAssertEqual(r.json["effective"] as? Bool, true)

        r = try await setModule(app1, tenant, "ping", false, by: owner)
        XCTAssertEqual(r.status, .conflict); XCTAssertEqual(r.problemCode, "module_required_by")
        XCTAssertEqual((r.json["errors"] as? [[String: Any]])?.first?["code"] as? String, "pong")
        let pingStill = try await call(app1, .GET, "api/v1/tenants/\(tenant)/ping/items", token: owner.token)
        XCTAssertEqual(pingStill.status, .ok)

        let v4 = try await setModule(app1, tenant, "pong", false, by: owner).status
        XCTAssertEqual(v4, .ok)
        let v5 = try await setModule(app1, tenant, "ping", false, by: owner).status
        XCTAssertEqual(v5, .ok)

        // Unbekanntes Modul: 404; fehlendes oder ungültiges enabled: 422
        r = try await setModule(app1, tenant, "nope", true, by: owner)
        XCTAssertEqual(r.status, .notFound); XCTAssertEqual(r.problemCode, "not_found")
        r = try await call(app1, .PUT, "api/v1/tenants/\(tenant)/modules/ping", json: ["enabled": "ja"], token: owner.token)
        XCTAssertEqual(r.status, .unprocessableEntity); XCTAssertEqual(r.problemCode, "validation_failed")
        r = try await call(app1, .PUT, "api/v1/tenants/\(tenant)/modules/ping", json: [:], token: owner.token)
        XCTAssertEqual(r.status, .unprocessableEntity)
    }

    /// AK-K3-3 + AK-K3-5: Paralleles Deaktivieren der Abhängigkeit und Aktivieren des Abhängigen über zwei Instanzen verletzt nie die Invariante.
    func testAKK3_3_ConcurrentToggleNeverBreaksRequires() async throws {
        let owner = try await bootstrap(app1, VirtualAuthenticator())
        let tenant = try await tenantOf(owner)
        for round in 0..<6 {
            try await setModule(app1, tenant, "ping", true, by: owner)
            async let a = setModule(app1, tenant, "ping", false, by: owner)
            async let b = setModule(app2, tenant, "pong", true, by: owner)
            let (ra, rb) = try await (a, b)
            XCTAssertTrue([200, 409].contains(ra.status.code) && [200, 409].contains(rb.status.code), "Runde \(round)")
            XCTAssertFalse(ra.status == .ok && rb.status == .ok, "beide Schalter gleichzeitig dürfen nicht gelingen (Runde \(round))")
            let broken = try await scalar("""
                SELECT count(*)::bigint AS v FROM tenant_modules p WHERE p.module_key = 'pong' AND p.enabled
                AND NOT EXISTS (SELECT 1 FROM tenant_modules q WHERE q.tenant_id = p.tenant_id AND q.module_key = 'ping' AND q.enabled)
                """, as: Int64.self)
            XCTAssertEqual(broken, 0, "pong aktiv ohne ping (Runde \(round))")
            try await setModule(app1, tenant, "pong", false, by: owner)
            try await setModule(app1, tenant, "ping", false, by: owner)
        }
    }

    // MARK: AK-K3-4 Daten bleiben

    func testAKK3_4_DeactivationKeepsDataAndReactivationRestoresView() async throws {
        let owner = try await bootstrap(app1, VirtualAuthenticator())
        let tenant = try await tenantOf(owner)
        try await setModule(app1, tenant, "ping", true, by: owner)
        let created = try await call(app1, .POST, "api/v1/tenants/\(tenant)/ping/items", json: ["label": "bleibt"], token: owner.token)
        XCTAssertEqual(created.status, .created)
        let before = try await scalar("SELECT count(*)::bigint AS v FROM ping_items", as: Int64.self)
        XCTAssertEqual(before, 2)  // "activated" aus onActivate + "bleibt"

        let v6 = try await setModule(app1, tenant, "ping", false, by: owner).status
        XCTAssertEqual(v6, .ok)
        let hidden = try await call(app2, .GET, "api/v1/tenants/\(tenant)/ping/items", token: owner.token)
        XCTAssertEqual(hidden.problemCode, "module_disabled")
        let during = try await scalar("SELECT count(*)::bigint AS v FROM ping_items", as: Int64.self)
        XCTAssertEqual(during, before)

        let v7 = try await setModule(app1, tenant, "ping", true, by: owner).status
        XCTAssertEqual(v7, .ok)
        let again = try await call(app1, .GET, "api/v1/tenants/\(tenant)/ping/items", token: owner.token)
        XCTAssertEqual(again.json["items"] as? [String], ["activated", "bleibt"])
        // onActivate ist idempotent und lief nur beim Übergang (auch beim zweiten Mal kein Duplikat)
        let marks = try await scalar("SELECT count(*)::bigint AS v FROM ping_items WHERE label = 'activated'", as: Int64.self)
        XCTAssertEqual(marks, 1)
        // erneutes Einschalten ohne Änderung: kein weiterer Audit-Eintrag
        let auditBefore = try await scalar("SELECT count(*)::bigint AS v FROM audit_log WHERE action LIKE 'module.%'", as: Int64.self)
        let v8 = try await setModule(app1, tenant, "ping", true, by: owner).status
        XCTAssertEqual(v8, .ok)
        let auditAfter = try await scalar("SELECT count(*)::bigint AS v FROM audit_log WHERE action LIKE 'module.%'", as: Int64.self)
        XCTAssertEqual(auditAfter, auditBefore)
        XCTAssertEqual(auditBefore, 3)  // enabled, disabled, enabled
    }

    // MARK: AK-K3-5 Zwei Instanzen

    func testAKK3_5_TwoInstancesSeeActivationImmediately() async throws {
        let owner = try await bootstrap(app1, VirtualAuthenticator())
        let tenant = try await tenantOf(owner)
        for i in 0..<4 {
            let writer = i % 2 == 0 ? app1! : app2!, reader = i % 2 == 0 ? app2! : app1!
            let v9 = try await setModule(writer, tenant, "ping", true, by: owner).status
            XCTAssertEqual(v9, .ok)
            let on = try await call(reader, .GET, "api/v1/tenants/\(tenant)/ping/items", token: owner.token)
            XCTAssertEqual(on.status, .ok, "Runde \(i)")
            let nav = try await navigationKeys(reader, tenant, owner)
            XCTAssertEqual(nav, ["ping"])
            let v10 = try await setModule(writer, tenant, "ping", false, by: owner).status
            XCTAssertEqual(v10, .ok)
            let off = try await call(reader, .GET, "api/v1/tenants/\(tenant)/ping/items", token: owner.token)
            XCTAssertEqual(off.problemCode, "module_disabled", "Runde \(i)")
        }
    }

    /// Betreiberebene: Abschalten wirkt sofort auf beiden Instanzen, überstimmt den Mandantenschalter und lässt Daten stehen.
    func testAKK3_OperatorInstallationSwitch() async throws {
        let operatorSession = try await bootstrap(app1, VirtualAuthenticator())
        let tenant = try await tenantOf(operatorSession)
        let bob = try await addUser(.owner, handle: "bobby", tenant: tenant, by: operatorSession)  // Owner, aber kein Betreiber
        try await setModule(app1, tenant, "ping", true, by: bob)
        try await setModule(app1, tenant, "pong", true, by: bob)

        var r = try await call(app1, .PUT, "api/v1/modules/ping", json: ["enabled": false], token: bob.token)
        XCTAssertEqual(r.status, .forbidden); XCTAssertEqual(r.problemCode, "forbidden")
        let stillOn = try await call(app1, .GET, "api/v1/tenants/\(tenant)/ping/items", token: bob.token)
        XCTAssertEqual(stillOn.status, .ok)

        r = try await call(app1, .PUT, "api/v1/modules/ping", json: ["enabled": false], token: operatorSession.token)
        XCTAssertEqual(r.status, .ok); XCTAssertEqual(r.json["installed"] as? Bool, false)
        for route in app2.moduleRoutes {
            let res = try await send(app2, route, tenant: tenant, token: bob.token)
            XCTAssertEqual(res.problemCode, "module_disabled", "\(route.module) \(route.path)")  // pong folgt, weil requires nicht mehr wirksam
        }
        let list = (try await call(app2, .GET, "api/v1/tenants/\(tenant)/modules", token: bob.token)).json["items"] as? [[String: Any]] ?? []
        XCTAssertEqual(list.first?["installed"] as? Bool, false)
        XCTAssertEqual(list.first?["enabled"] as? Bool, true)
        XCTAssertEqual(list.first?["effective"] as? Bool, false)
        XCTAssertEqual(list.last?["effective"] as? Bool, false)
        let navNone = try await navigationKeys(app2, tenant, bob)
        XCTAssertEqual(navNone, [])
        // Aktivieren im Mandanten scheitert, solange der Betreiber das Modul abgeschaltet hat
        try await setModule(app1, tenant, "pong", false, by: bob)
        try await setModule(app1, tenant, "ping", false, by: bob)
        r = try await setModule(app1, tenant, "ping", true, by: bob)
        XCTAssertEqual(r.status, .conflict); XCTAssertEqual(r.problemCode, "module_unavailable")

        r = try await call(app2, .PUT, "api/v1/modules/ping", json: ["enabled": true], token: operatorSession.token)
        XCTAssertEqual(r.status, .ok)
        let v11 = try await setModule(app1, tenant, "ping", true, by: bob).status
        XCTAssertEqual(v11, .ok)
        r = try await call(app1, .PUT, "api/v1/modules/nope", json: ["enabled": true], token: operatorSession.token)
        XCTAssertEqual(r.status, .notFound)
        r = try await call(app1, .PUT, "api/v1/modules/ping", json: [:], token: operatorSession.token)
        XCTAssertEqual(r.status, .unprocessableEntity)

        // Audit: Aktionen ohne Nutzdaten, mit Akteur
        let actions = try await db.raw("SELECT DISTINCT action FROM audit_log WHERE action LIKE 'module.%' ORDER BY action").all()
            .map { try $0.decode(column: "action", as: String.self) }
        XCTAssertEqual(actions, ["module.disabled", "module.enabled", "module.installation_disabled", "module.installation_enabled"])
        let noActor = try await scalar("SELECT count(*)::bigint AS v FROM audit_log WHERE action LIKE 'module.%' AND actor_user_id IS NULL", as: Int64.self)
        XCTAssertEqual(noActor, 0)
    }

    // MARK: Berechtigungen der Moduleschalter

    /// Lesen darf jede Rolle, schalten nur der Owner (K2-Rollen, F-13: Betreiber + Mandant).
    func testModuleSwitchPermissionsFollowK2Roles() async throws {
        let owner = try await bootstrap(app1, VirtualAuthenticator())
        let tenant = try await tenantOf(owner)
        for role in Role.allCases {
            let s = role == .owner ? owner : try await addUser(role, handle: "u_" + role.rawValue, tenant: tenant, by: owner)
            let read = try await call(app2, .GET, "api/v1/tenants/\(tenant)/modules", token: s.token)
            XCTAssertEqual(read.status, .ok, role.rawValue)
            let write = try await setModule(app1, tenant, "ping", true, by: s)
            if role == .owner { XCTAssertEqual(write.status, .ok) } else {
                XCTAssertEqual(write.status, .forbidden, role.rawValue); XCTAssertEqual(write.problemCode, "forbidden")
            }
        }
        XCTAssertTrue(Permissions.of(.owner).contains("tenant.module.manage"))
        XCTAssertEqual(Role.allCases.filter { Permissions.of($0).contains("tenant.module.manage") }, [.owner])
    }

    // MARK: AK-K3-6 Migrationen

    func testAKK3_6_MigrationsOfDisabledModulesRunAndReadyFailsWhenMissing() async throws {
        // Kein Modul aktiviert, trotzdem existiert die Tabelle des Moduls
        let exists = try await scalar("SELECT (to_regclass('ping_items') IS NOT NULL) AS v", as: Bool.self)
        XCTAssertTrue(exists)
        let enabledRows = try await scalar("SELECT count(*)::bigint AS v FROM tenant_modules", as: Int64.self)
        XCTAssertEqual(enabledRows, 0)
        let ready = try await call(app1, .GET, "ready")
        XCTAssertEqual(ready.status, .ok)
        // Fehlende Modul-Migration: /ready = 503 auf beiden Instanzen
        try await db.raw("DELETE FROM _fluent_migrations WHERE name = 'ping_001_items'").run()
        let v12 = try await call(app1, .GET, "ready").status
        XCTAssertEqual(v12, .serviceUnavailable)
        let v13 = try await call(app2, .GET, "ready").status
        XCTAssertEqual(v13, .serviceUnavailable)
    }

    func testAKK3_6_ModuleMigrationRecordedAndSchemaVersion() async throws {
        let v = try await scalar("SELECT max(version)::bigint AS v FROM schema_version", as: Int64.self)
        XCTAssertEqual(v, 15)  // WP-K5 (015) liegt über 014
        let recorded = try await scalar("SELECT count(*)::bigint AS v FROM _fluent_migrations WHERE name IN ('014_modules','ping_001_items')", as: Int64.self)
        XCTAssertEqual(recorded, 2)
        // Revert/Prepare der Kernmigration (Expand-only, Revert vorhanden)
        let database = app1.db(.psql)
        try await CreateContacts().revert(on: database)  // WP-K5 zuerst
        try await CreateModules().revert(on: database)
        let reverted = try await scalar("SELECT max(version)::bigint AS v FROM schema_version", as: Int64.self)
        XCTAssertEqual(reverted, 13)
        let gone = try await scalar("SELECT count(*)::bigint AS v FROM information_schema.tables WHERE table_schema = current_schema() AND table_name IN ('tenant_modules','installation_modules')", as: Int64.self)
        XCTAssertEqual(gone, 0)
        try await CreateModules().prepare(on: database)
        let again = try await scalar("SELECT max(version)::bigint AS v FROM schema_version", as: Int64.self)
        XCTAssertEqual(again, 14)
        try await CreateContacts().prepare(on: database)
    }
}

/// Registrierungsprüfung der Modulliste (ohne Datenbank).
final class ModuleRegistryTests: XCTestCase {
    struct Fake: HubModule {
        var key: ModuleKey
        var requires: [ModuleKey] = []
        var permissions: [PermissionDefinition] = []
    }

    func testAKK3_RegistryRejectsInvalidModuleLists() throws {
        XCTAssertNoThrow(try ModuleRegistry([Fake(key: "a"), Fake(key: "b", requires: ["a"])]))
        XCTAssertThrowsError(try ModuleRegistry([Fake(key: "a"), Fake(key: "a")]))                       // doppelter Schlüssel
        XCTAssertThrowsError(try ModuleRegistry([Fake(key: "Bad Key")]))                                  // ungültiger Schlüssel
        XCTAssertThrowsError(try ModuleRegistry([Fake(key: "members")]))                                  // reserviertes Pfadsegment
        XCTAssertThrowsError(try ModuleRegistry([Fake(key: "a", requires: ["zzz"])]))                     // unbekannte Abhängigkeit
        XCTAssertThrowsError(try ModuleRegistry([Fake(key: "a", requires: ["b"]), Fake(key: "b", requires: ["a"])]))  // Zyklus
        XCTAssertThrowsError(try ModuleRegistry([Fake(key: "a", permissions: [PermissionDefinition("b.x.read")])]))   // fremder Präfix
        // Kernkatalog (WP-D2: die dms.*-Rechte wanderten ins Modul, der Test prüft die Kollision daher mit einem Kernrecht)
        XCTAssertThrowsError(try ModuleRegistry([Fake(key: "contact", permissions: [PermissionDefinition("contact.contact.read")])]))
        XCTAssertNoThrow(try ModuleRegistry([DMSModule()]))
    }
}
