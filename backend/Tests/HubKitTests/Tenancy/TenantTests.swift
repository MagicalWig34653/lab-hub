import XCTVapor
import Fluent
import SQLKit
@testable import HubKit

/// WP-K2: Mandanten, Mitgliedschaften, Rollen, Berechtigungen. Alle Daten synthetisch.
final class TenantTests: AuthTestCase {
    override var testModules: [any HubModule] { [PingModule()] }  // WP-K3: die Moduleschalter-Routen brauchen ein registriertes Modul

    // MARK: Hilfen

    func addUser(_ role: String, handle: String, tenant: String, by: TestSession, via: Application? = nil) async throws -> TestSession {
        let app = via ?? app1!
        let token = try await invite(app, by: by, tenant: tenant, role: role)
        let r = try await register(app, VirtualAuthenticator(), invite: token, handle: handle)
        XCTAssertEqual(r.status, .created, "\(r.json)")
        return session(r, handle: handle)
    }

    func tenantOf(_ s: TestSession) async throws -> String {
        try await scalar("SELECT tenant_id::text AS v FROM memberships WHERE user_id = '\(s.userID)' ORDER BY created_at LIMIT 1", as: String.self)
    }

    func createTenant(_ name: String, by s: TestSession) async throws -> String {
        let r = try await call(app1, .POST, "api/v1/tenants", json: ["name": name], token: s.token)
        XCTAssertEqual(r.status, .created, "\(r.json)")
        return r.json["id"] as! String
    }

    func roleOf(_ user: String, in tenant: String) async throws -> String? {
        try await db.raw("SELECT role FROM memberships WHERE tenant_id = \(bind: UUID(uuidString: tenant)!) AND user_id = \(bind: UUID(uuidString: user)!)")
            .first()?.decode(column: "role", as: String.self)
    }

    /// Mitglied ohne Anmeldung, nur für Matrixzeilen, die ein Löschziel brauchen.
    func throwawayMember(_ tenant: String) async throws -> String {
        let id = UUID()
        let handle = "tmp-" + id.uuidString.prefix(8).lowercased()
        try await db.raw("INSERT INTO users (id, handle, display_name) VALUES (\(bind: id), \(bind: handle), 'Temp')").run()
        try await db.raw("INSERT INTO memberships (tenant_id, user_id, role) VALUES (\(bind: UUID(uuidString: tenant)!), \(bind: id), 'member')").run()
        return id.uuidString
    }

    func send(_ app: Application, _ method: String, _ template: String, tenant: String, user: String = UUID().uuidString,
              body: [String: Any]? = nil, token: String?) async throws -> Resp {
        let path = String(template.dropFirst()).replacingOccurrences(of: "{tenant}", with: tenant).replacingOccurrences(of: "{user}", with: user)
            .replacingOccurrences(of: "{module}", with: "ping")
        return try await call(app, HTTPMethod(rawValue: method), path, json: body ?? (method == "GET" || method == "DELETE" ? nil : [:]), token: token)
    }

    // MARK: Berechtigungskatalog

    /// AK-K2-1: Standardrollen und Katalog sind im Code fest (F-12); der Besitzer hat alles, niemand hat unbekannte Berechtigungen.
    func testAKK2_1_RoleCatalogIsConsistent() {
        XCTAssertEqual(Set(Role.allCases.map(\.rawValue)), ["owner", "accountant", "member", "tax_advisor", "customer_viewer"])
        XCTAssertEqual(Permissions.of(.owner), Set(Permissions.catalog))
        for role in Role.allCases {
            XCTAssertTrue(Permissions.of(role).isSubset(of: Set(Permissions.catalog)), role.rawValue)
            XCTAssertTrue(Permissions.of(role).contains("tenant.tenant.read"), role.rawValue)
        }
        XCTAssertTrue(Permissions.catalog.allSatisfy { AuditValue.isSafeToken($0) && $0.split(separator: ".").count == 3 })
        XCTAssertFalse(Permissions.of(.customerViewer).contains("dms.document.read"))  // nur über Objekt-Freigaben (später)
        XCTAssertFalse(Permissions.of(.taxAdvisor).contains("invoice.document.finalize"))
        for role in Role.allCases where role != .owner { XCTAssertFalse(Permissions.of(role).contains("tenant.member.manage"), role.rawValue) }
    }

    // MARK: AK-K2-1 Matrix

    /// AK-K2-1: generierte Matrix Rolle x Berechtigung x Route. Erlaubt liefert den Erfolgsstatus, verboten 403 `forbidden`.
    func testAKK2_1_MatrixRoleByPermissionByRoute() async throws {
        let alice = try await bootstrap(app1, VirtualAuthenticator())
        let tenant = try await tenantOf(alice)
        var sessions: [Role: TestSession] = [.owner: alice]
        for role in Role.allCases where role != .owner {
            sessions[role] = try await addUser(role.rawValue, handle: "u_" + role.rawValue, tenant: tenant, by: alice)
        }
        let viewer = sessions[.customerViewer]!
        let routes = app1.tenantRoutes
        XCTAssertFalse(routes.isEmpty)
        // Eine Route ohne Probe lässt den Test scheitern (Abdeckung wie in AuthPermissionTests).
        let expectedSuccess: [String: HTTPStatus] = [
            "GET /api/v1/tenants/{tenant}": .ok, "GET /api/v1/tenants/{tenant}/members": .ok,
            "POST /api/v1/tenants/{tenant}/invitations": .created,
            "PATCH /api/v1/tenants/{tenant}/members/{user}": .ok, "DELETE /api/v1/tenants/{tenant}/members/{user}": .noContent,
            "GET /api/v1/tenants/{tenant}/modules": .ok, "PUT /api/v1/tenants/{tenant}/modules/{module}": .ok]
        XCTAssertEqual(Set(routes.map { "\($0.method) \($0.path)" }), Set(expectedSuccess.keys))
        XCTAssertTrue(routes.allSatisfy { Permissions.catalog.contains($0.permission) })

        var cells = 0
        for route in routes {
            for role in Role.allCases {
                let user = route.method == "DELETE" ? try await throwawayMember(tenant) : viewer.userID
                var body: [String: Any]?
                if route.method == "PATCH" { body = ["role": "customer_viewer"] }
                if route.path.hasSuffix("/invitations") { body = ["role": "member"] }
                if route.method == "PUT" { body = ["enabled": true] }
                let app = cells % 2 == 0 ? app1! : app2!  // abwechselnd beide Instanzen
                let r = try await send(app, route.method, route.path, tenant: tenant, user: user, body: body, token: sessions[role]!.token)
                cells += 1
                if Permissions.of(role).contains(route.permission) {
                    XCTAssertEqual(r.status, expectedSuccess["\(route.method) \(route.path)"], "\(role.rawValue) \(route.method) \(route.path): \(r.json)")
                } else {
                    XCTAssertEqual(r.status, .forbidden, "\(role.rawValue) \(route.method) \(route.path)")
                    XCTAssertEqual(r.problemCode, "forbidden")
                    XCTAssertEqual(r.headers.contentType?.serialize(), "application/problem+json")
                }
            }
        }
        XCTAssertEqual(cells, routes.count * Role.allCases.count)
    }

    // MARK: AK-K2-2 Mandantentrennung

    /// AK-K2-2: Nutzer ohne Mitgliedschaft erhält 404 auf alle Routen und Objekte des Mandanten, ohne Nebenwirkung.
    func testAKK2_2_NonMemberGets404OnEverything() async throws {
        let alice = try await bootstrap(app1, VirtualAuthenticator())
        let tenantA = try await tenantOf(alice)
        let bob = try await addUser("member", handle: "bobby", tenant: tenantA, by: alice)
        let tenantB = try await createTenant("Zweiter Mandant", by: alice)
        let carol = try await addUser("owner", handle: "carol", tenant: tenantB, by: alice)
        let invitationsBefore = try await scalar("SELECT count(*)::bigint AS v FROM invitations", as: Int64.self)

        for route in app1.tenantRoutes {
            let plain = route.method == "GET" || route.method == "DELETE"
            // Carol kennt Mandant A nicht; die fremde Nutzer-ID (Bob) ändert daran nichts.
            let r1 = try await send(app1, route.method, route.path, tenant: tenantA, user: bob.userID, body: plain ? nil : ["role": "owner"], token: carol.token)
            XCTAssertEqual(r1.status, .notFound, "\(route.method) \(route.path)")
            XCTAssertEqual(r1.problemCode, "not_found")
            // Bob (Mitglied in A) kennt Mandant B nicht.
            let r2 = try await send(app2, route.method, route.path, tenant: tenantB, user: carol.userID, body: plain ? nil : ["role": "member"], token: bob.token)
            XCTAssertEqual(r2.status, .notFound, "\(route.method) \(route.path)")
        }
        // keine Nebenwirkung
        let bobRole = try await roleOf(bob.userID, in: tenantA)
        XCTAssertEqual(bobRole, "member")
        let carolRole = try await roleOf(carol.userID, in: tenantB)
        XCTAssertEqual(carolRole, "owner")
        let invitationsAfter = try await scalar("SELECT count(*)::bigint AS v FROM invitations", as: Int64.self)
        XCTAssertEqual(invitationsAfter, invitationsBefore)

        // Fremde Objekt-ID im eigenen Mandanten: Carol ist nicht Mitglied von A, also 404 statt Erfolg.
        for method in ["PATCH", "DELETE"] {
            let r = try await send(app1, method, "/api/v1/tenants/{tenant}/members/{user}", tenant: tenantA, user: carol.userID,
                                   body: method == "PATCH" ? ["role": "member"] : nil, token: alice.token)
            XCTAssertEqual(r.status, .notFound, method)
        }
        let carolStill = try await roleOf(carol.userID, in: tenantB)
        XCTAssertEqual(carolStill, "owner")
        // Listen zeigen nur eigene Mandanten
        let carolList = (try await call(app1, .GET, "api/v1/tenants", token: carol.token)).json["items"] as? [[String: Any]] ?? []
        XCTAssertEqual(carolList.map { $0["id"] as? String }, [tenantB])
        let aliceList = (try await call(app1, .GET, "api/v1/tenants", token: alice.token)).json["items"] as? [[String: Any]] ?? []
        XCTAssertEqual(Set(aliceList.compactMap { ($0["id"] as? String)?.lowercased() }), [tenantA.lowercased(), tenantB.lowercased()])
        // Mitgliederliste nennt nur Mitglieder des Mandanten
        let members = (try await call(app1, .GET, "api/v1/tenants/\(tenantB)/members", token: carol.token)).json["items"] as? [[String: Any]] ?? []
        XCTAssertEqual(Set(members.compactMap { $0["user_id"] as? String }), [alice.userID, carol.userID])
    }

    /// AK-K2-2: Unbekannte, ungültige und deaktivierte Mandanten sind für jeden 404 (keine Existenzauskunft).
    func testAKK2_2_UnknownMalformedAndDisabledTenantsAre404() async throws {
        let alice = try await bootstrap(app1, VirtualAuthenticator())
        let tenant = try await tenantOf(alice)
        for id in [UUID().uuidString, "not-a-uuid", "0"] {
            let r = try await call(app1, .GET, "api/v1/tenants/\(id)", token: alice.token)
            XCTAssertEqual(r.status, .notFound, id); XCTAssertEqual(r.problemCode, "not_found")
        }
        let ok = try await call(app1, .GET, "api/v1/tenants/\(tenant)", token: alice.token)
        XCTAssertEqual(ok.status, .ok)
        XCTAssertEqual(ok.json["role"] as? String, "owner")
        XCTAssertEqual(Set(ok.json["permissions"] as? [String] ?? []), Permissions.of(.owner))
        try await db.raw("UPDATE tenants SET disabled_at = now() WHERE id = \(bind: UUID(uuidString: tenant)!)").run()
        let off = try await call(app2, .GET, "api/v1/tenants/\(tenant)", token: alice.token)
        XCTAssertEqual(off.status, .notFound)
        let anonymous = try await call(app1, .GET, "api/v1/tenants/\(tenant)")
        XCTAssertEqual(anonymous.status, .unauthorized)
    }

    // MARK: Bootstrap, Einladung, Betreiber

    /// Ersatz für `users.is_admin`: Bootstrap-Nutzer ist Betreiber und Owner des ersten Mandanten, eingeladene Nutzer erhalten die Rolle der Einladung.
    func testAKK2_BootstrapUserIsOperatorAndOwnerOfFirstTenant() async throws {
        let alice = try await bootstrap(app1, VirtualAuthenticator())
        let me = try await call(app2, .GET, "api/v1/auth/session", token: alice.token)
        let user = me.json["user"] as? [String: Any]
        XCTAssertEqual(user?["is_operator"] as? Bool, true)
        XCTAssertNil(user?["is_admin"])
        let ms = me.json["memberships"] as? [[String: Any]] ?? []
        XCTAssertEqual(ms.count, 1)
        XCTAssertEqual(ms.first?["role"] as? String, "owner")
        let tenants = try await scalar("SELECT count(*)::bigint AS v FROM tenants", as: Int64.self)
        XCTAssertEqual(tenants, 1)

        let tenant = ms.first?["tenant_id"] as! String
        let bob = try await addUser("accountant", handle: "bobby", tenant: tenant, by: alice, via: app2)
        let bobMe = try await call(app1, .GET, "api/v1/auth/session", token: bob.token)
        XCTAssertEqual((bobMe.json["user"] as? [String: Any])?["is_operator"] as? Bool, false)
        XCTAssertEqual((bobMe.json["memberships"] as? [[String: Any]])?.first?["role"] as? String, "accountant")
        // Nicht-Betreiber dürfen keine Mandanten anlegen, auch nicht als Owner.
        let denied = try await call(app1, .POST, "api/v1/tenants", json: ["name": "X"], token: bob.token)
        XCTAssertEqual(denied.status, .forbidden); XCTAssertEqual(denied.problemCode, "forbidden")
        let bad = try await call(app1, .POST, "api/v1/tenants", json: ["name": ""], token: alice.token)
        XCTAssertEqual(bad.status, .unprocessableEntity)
        let audit = try await scalar("SELECT count(*)::bigint AS v FROM audit_log WHERE action = 'tenant.created'", as: Int64.self)
        XCTAssertEqual(audit, 1)
    }

    func testAKK2_InvitationRoleValidationAndBinding() async throws {
        let alice = try await bootstrap(app1, VirtualAuthenticator())
        let tenant = try await tenantOf(alice)
        let bad = try await call(app1, .POST, "api/v1/tenants/\(tenant)/invitations", json: ["role": "root"], token: alice.token)
        XCTAssertEqual(bad.status, .unprocessableEntity)
        XCTAssertEqual((bad.json["errors"] as? [[String: Any]])?.first?["field"] as? String, "role")
        let tooLong = try await call(app1, .POST, "api/v1/tenants/\(tenant)/invitations", json: ["expires_in_hours": 100_000], token: alice.token)
        XCTAssertEqual(tooLong.status, .unprocessableEntity)
        let defaultRole = try await call(app1, .POST, "api/v1/tenants/\(tenant)/invitations", json: [:], token: alice.token)
        XCTAssertEqual(defaultRole.status, .created)
        let stored = try await scalar("SELECT role AS v FROM invitations WHERE id = '\(defaultRole.json["id"] as! String)'", as: String.self)
        XCTAssertEqual(stored, "member")
        // Eine Einladung bindet Mandant und Rolle.
        let token = try await invite(app1, by: alice, tenant: tenant, role: "tax_advisor")
        let reg = try await register(app2, VirtualAuthenticator(), invite: token, handle: "advisor")
        XCTAssertEqual(reg.status, .created)
        let role = try await roleOf(session(reg, handle: "advisor").userID, in: tenant)
        XCTAssertEqual(role, "tax_advisor")
    }

    // MARK: Mitgliedschaftsänderungen

    /// Zwei Instanzen: Rollen- und Mitgliedschaftsänderungen wirken sofort auf der jeweils anderen Instanz (kein Cache).
    func testAKK2_TwoInstancesSeeMembershipChangesImmediately() async throws {
        let alice = try await bootstrap(app1, VirtualAuthenticator())
        let tenant = try await tenantOf(alice)
        let bob = try await addUser("member", handle: "bobby", tenant: tenant, by: alice)
        let list = "api/v1/tenants/\(tenant)/members"
        var r = try await call(app2, .GET, list, token: bob.token); XCTAssertEqual(r.status, .ok)
        // Instanz 1 stuft herab, Instanz 2 verweigert sofort.
        r = try await call(app1, .PATCH, "\(list)/\(bob.userID)", json: ["role": "customer_viewer"], token: alice.token)
        XCTAssertEqual(r.status, .ok); XCTAssertEqual(r.json["role"] as? String, "customer_viewer")
        r = try await call(app2, .GET, list, token: bob.token); XCTAssertEqual(r.status, .forbidden)
        // Instanz 2 stuft hoch, Instanz 1 erlaubt wieder.
        r = try await call(app2, .PATCH, "\(list)/\(bob.userID)", json: ["role": "accountant"], token: alice.token); XCTAssertEqual(r.status, .ok)
        r = try await call(app1, .GET, list, token: bob.token); XCTAssertEqual(r.status, .ok)
        // Entfernen über Instanz 1, Instanz 2 antwortet 404 (kein Mitglied), die Sitzung selbst bleibt gültig.
        r = try await call(app1, .DELETE, "\(list)/\(bob.userID)", token: alice.token); XCTAssertEqual(r.status, .noContent)
        r = try await call(app2, .GET, list, token: bob.token); XCTAssertEqual(r.status, .notFound)
        r = try await call(app2, .GET, "api/v1/auth/session", token: bob.token); XCTAssertEqual(r.status, .ok)
        XCTAssertEqual((r.json["memberships"] as? [[String: Any]])?.count, 0)
        let gone = try await roleOf(bob.userID, in: tenant)
        XCTAssertNil(gone)
        let audit = try await scalar("SELECT count(*)::bigint AS v FROM audit_log WHERE action IN ('tenant.member_role_changed','tenant.member_removed')", as: Int64.self)
        XCTAssertEqual(audit, 3)
    }

    /// Der letzte Owner bleibt: Herabstufen oder Entfernen scheitert mit 409; parallele gegenseitige Herabstufung lässt genau einen Owner übrig.
    func testAKK2_LastOwnerCannotBeRemovedEvenConcurrently() async throws {
        let alice = try await bootstrap(app1, VirtualAuthenticator())
        let tenant = try await tenantOf(alice)
        let list = "api/v1/tenants/\(tenant)/members"
        var r = try await call(app1, .PATCH, "\(list)/\(alice.userID)", json: ["role": "member"], token: alice.token)
        XCTAssertEqual(r.status, .conflict); XCTAssertEqual(r.problemCode, "last_owner")
        r = try await call(app2, .DELETE, "\(list)/\(alice.userID)", token: alice.token)
        XCTAssertEqual(r.status, .conflict); XCTAssertEqual(r.problemCode, "last_owner")
        let dave = try await addUser("owner", handle: "dave", tenant: tenant, by: alice)
        async let a = call(app1, .PATCH, "\(list)/\(dave.userID)", json: ["role": "member"], token: alice.token)
        async let b = call(app2, .PATCH, "\(list)/\(alice.userID)", json: ["role": "member"], token: dave.token)
        let results = try await [a, b]
        XCTAssertTrue(results.allSatisfy { [.ok, .conflict, .forbidden].contains($0.status) }, "\(results.map(\.status))")
        let owners = try await scalar("SELECT count(*)::bigint AS v FROM memberships WHERE tenant_id = '\(tenant)' AND role = 'owner'", as: Int64.self)
        XCTAssertEqual(owners, 1)
    }

    func testAKK2_RoleChangeValidation() async throws {
        let alice = try await bootstrap(app1, VirtualAuthenticator())
        let tenant = try await tenantOf(alice)
        let bob = try await addUser("member", handle: "bobby", tenant: tenant, by: alice)
        let r = try await call(app1, .PATCH, "api/v1/tenants/\(tenant)/members/\(bob.userID)", json: ["role": "root"], token: alice.token)
        XCTAssertEqual(r.status, .unprocessableEntity)
        let nonUUID = try await call(app1, .PATCH, "api/v1/tenants/\(tenant)/members/xyz", json: ["role": "member"], token: alice.token)
        XCTAssertEqual(nonUUID.status, .notFound)
        let still = try await roleOf(bob.userID, in: tenant)
        XCTAssertEqual(still, "member")
    }

    /// Notfall-Sitzungen (Recovery) bleiben von allen Mandantenrouten ausgeschlossen (Default-Deny aus K1).
    func testAKK2_RecoverySessionIsDeniedOnTenantRoutes() async throws {
        let alice = try await bootstrap(app1, VirtualAuthenticator())
        let tenant = try await tenantOf(alice)
        let codes = (try await call(app1, .POST, "api/v1/me/recovery-codes", token: alice.token)).json["codes"] as! [String]
        let rec = try await call(app1, .POST, "api/v1/auth/recovery/login", json: ["handle": "alice", "code": codes[0]], headers: ["X-Auth-Transport": "bearer"])
        let token = rec.json["token"] as! String
        for route in app1.tenantRoutes {
            let r = try await send(app1, route.method, route.path, tenant: tenant, body: nil, token: token)
            XCTAssertEqual(r.status, .forbidden, "\(route.method) \(route.path)"); XCTAssertEqual(r.problemCode, "recovery_session_restricted")
        }
    }

    // MARK: Migration

    /// Expand/Contract: Version 13, Revert stellt Version 12 wieder her, Bestandsnutzer werden übernommen (is_admin -> Rolle/Betreiber).
    func testAKK2_MigrationBackfillsAndReverts() async throws {
        let v = try await scalar("SELECT max(version)::bigint AS v FROM schema_version", as: Int64.self)
        XCTAssertEqual(v, 17)  // WP-O1 (017)
        let database = app1.db(.psql)
        try await CreateApiTokens().revert(on: database)  // WP-D4 (019) zuerst: verweist auf users
        try await CreateJobsPriority().revert(on: database)  // WP-O1 (017) zuerst
        try await CreateContacts().revert(on: database)  // WP-K5 (015) zuerst
        try await db.raw("DROP TABLE ping_items").run()  // WP-K3: Modul- und Schalter-Tabellen hängen an tenants
        try await CreateModules().revert(on: database)
        try await CreateTenants().revert(on: database)
        let reverted = try await scalar("SELECT max(version)::bigint AS v FROM schema_version", as: Int64.self)
        XCTAssertEqual(reverted, 12)
        let leftovers = try await scalar("""
            SELECT ((SELECT count(*) FROM information_schema.tables WHERE table_schema = current_schema() AND table_name IN ('tenants','memberships'))
                 + (SELECT count(*) FROM information_schema.columns WHERE table_schema = current_schema()
                    AND ((table_name = 'users' AND column_name = 'is_operator') OR (table_name = 'invitations' AND column_name IN ('tenant_id','role')))))::bigint AS v
            """, as: Int64.self)
        XCTAssertEqual(leftovers, 0)

        // Bestand aus WP-K1: ein Admin, ein normaler Nutzer, eine offene Einladung.
        let admin = UUID(), normal = UUID()
        try await db.raw("INSERT INTO users (id, handle, display_name, is_admin) VALUES (\(bind: admin), 'old-admin', 'A', true), (\(bind: normal), 'old-user', 'U', false)").run()
        try await db.raw("INSERT INTO invitations (token_hash, created_by, expires_at) VALUES ('h1', \(bind: admin), now() + interval '1 day')").run()
        try await CreateTenants().prepare(on: database)
        let version = try await scalar("SELECT max(version)::bigint AS v FROM schema_version", as: Int64.self)
        XCTAssertEqual(version, 13)  // WP-K5 (015) ist hier noch zurückgenommen
        let tenant = try await scalar("SELECT id::text AS v FROM tenants", as: String.self)
        let adminRole = try await roleOf(admin.uuidString, in: tenant), userRole = try await roleOf(normal.uuidString, in: tenant)
        XCTAssertEqual(adminRole, "owner"); XCTAssertEqual(userRole, "member")
        let ops = try await scalar("SELECT count(*)::bigint AS v FROM users WHERE is_operator", as: Int64.self)
        XCTAssertEqual(ops, 1)
        let inv = try await scalar("SELECT (tenant_id = '\(tenant)' AND role = 'member') AS v FROM invitations", as: Bool.self)
        XCTAssertTrue(inv)
        // Contract-Phase folgt erst später: die alte Spalte bleibt erhalten, wird aber nicht mehr geschrieben.
        let legacy = try await scalar("SELECT count(*)::bigint AS v FROM information_schema.columns WHERE table_name = 'users' AND column_name = 'is_admin'", as: Int64.self)
        XCTAssertEqual(legacy, 1)
        // Revert mit Daten stellt is_admin aus is_operator wieder her.
        try await CreateTenants().revert(on: database)
        let admins = try await scalar("SELECT count(*)::bigint AS v FROM users WHERE is_admin", as: Int64.self)
        XCTAssertEqual(admins, 1)
        try await CreateTenants().prepare(on: database)
        try await CreateModules().prepare(on: database)
        try await CreatePingItems().prepare(on: database)
        try await CreateContacts().prepare(on: database)
        try await CreateJobsPriority().prepare(on: database)
        try await CreateApiTokens().prepare(on: database)
    }

    /// Eine Mitgliedschaft existiert höchstens einmal je (Mandant, Nutzer); ungültige Rollen lehnt die Datenbank ab.
    func testAKK2_DatabaseConstraints() async throws {
        let alice = try await bootstrap(app1, VirtualAuthenticator())
        let tenant = UUID(uuidString: try await tenantOf(alice))!
        let user = UUID(uuidString: alice.userID)!
        do { try await db.raw("INSERT INTO memberships (tenant_id, user_id, role) VALUES (\(bind: tenant), \(bind: user), 'owner')").run(); XCTFail("Duplikat") } catch {}
        let other = try await throwawayMember(tenant.uuidString)
        do { try await db.raw("UPDATE memberships SET role = 'root' WHERE user_id = \(bind: UUID(uuidString: other)!)").run(); XCTFail("Rolle") } catch {}
    }
}
