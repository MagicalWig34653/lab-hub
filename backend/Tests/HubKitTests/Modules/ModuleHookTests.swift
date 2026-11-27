import XCTVapor
import Fluent
import SQLKit
@testable import HubKit

/// Testmodul für WP-ST2: liefert Job-Handler, einen Token-Scope und Link-Schutz über die Haken von `HubModule` (ohne eigene Tabelle).
struct HookModule: HubModule {
    let key = "hook"
    static let lockedID = UUID(uuidString: "00000000-0000-4000-8000-00000000beef")!
    final class Calls: @unchecked Sendable {
        private let lock = NSLock(); private var n = 0
        func inc() { lock.lock(); n += 1; lock.unlock() }
        var value: Int { lock.lock(); defer { lock.unlock() }; return n }
    }
    let calls: Calls
    init(calls: Calls = Calls()) { self.calls = calls }

    var permissions: [PermissionDefinition] {
        [PermissionDefinition("hook.item.read", roles: [.accountant]), PermissionDefinition("hook.item.upload", roles: [.accountant, .member])]
    }
    var tokenScopes: [String] { ["hook.upload"] }

    func registerRoutes(_ routes: ModuleRoutes) throws {
        routes.onToken(.POST, "drop", scope: "hook.upload", permission: "hook.item.upload") { _ in try jsonResponse(["ok": true], status: .created) }
    }

    func jobHandlers(environment: [String: String]) -> [String: JobHandler] {
        let calls = calls
        return ["hook.job": { _, _ in calls.inc() }]
    }

    func workerPreflight(kinds: Set<String>, environment: [String: String]) async -> String? {
        kinds.contains("hook.job") && environment["HOOK_PREFLIGHT_FAIL"] == "1" ? "hook: Werkzeug fehlt" : nil
    }

    func linkVisibility(tenant: UUID, permissions: Set<String>, on db: any SQLDatabase) async throws -> LinkVisibility {
        permissions.contains("hook.item.read") ? .visible : .hidden(HubError(.forbidden, "forbidden"))
    }

    func guardLinkEnds(_ ends: [LinkEnd], creating: Bool, permissions: Set<String>, tenant: UUID, on db: any SQLDatabase) async throws {
        guard permissions.contains("hook.item.read") else { throw HubError(.forbidden, "forbidden") }
        if creating, ends.contains(where: { $0.id == Self.lockedID }) { throw HubError(.conflict, "hook_locked") }
    }
}

/// Modul mit fremdem Scope bzw. fremder Job-Art (Registrierungsfehler).
struct BadScopeModule: HubModule { let key = "bad"; var tokenScopes: [String] { ["dms.upload"] } }
struct BadJobModule: HubModule {
    let key = "badjob"
    func jobHandlers(environment: [String: String]) -> [String: JobHandler] { ["other.job": { _, _ in }] }
}
struct TwinJobModule: HubModule {
    let key = "hook2"
    func jobHandlers(environment: [String: String]) -> [String: JobHandler] { ["hook.job": { _, _ in }] }
}

/// WP-ST2: Der Kern bedient Module nur über `HubModule` (Job-Handler, Token-Scopes, Link-Schutz). Alle Daten synthetisch.
final class ModuleHookTests: JobTestBase {
    let calls = HookModule.Calls()
    /// Bewusst ohne DMS: Kernfunktionen (Tokens, Verknüpfungen, Worker) dürfen von keinem bestimmten Modul abhängen.
    override var testModules: [any HubModule] { [HookModule(calls: calls)] }

    func tenantOf(_ s: TestSession) async throws -> String {
        try await scalar("SELECT tenant_id::text AS v FROM memberships WHERE user_id = '\(s.userID)' ORDER BY created_at LIMIT 1", as: String.self)
    }

    func addUser(_ role: Role, handle: String, tenant: String, by: TestSession) async throws -> TestSession {
        let r = try await register(app1, VirtualAuthenticator(), invite: try await invite(app1, by: by, tenant: tenant, role: role.rawValue), handle: handle)
        XCTAssertEqual(r.status, .created, "\(r.json)")
        return session(r, handle: handle)
    }

    func enableHook(_ tenant: String, by s: TestSession) async throws {
        let r = try await call(app1, .PUT, "api/v1/tenants/\(tenant)/modules/hook", json: ["enabled": true], token: s.token)
        XCTAssertEqual(r.status, .ok, "\(r.json)")
    }

    /// AK-ST2-1: Job-Handler kommen aus den Modulen; der Worker führt einen Modul-Job aus. Fremde oder doppelte Job-Arten sind ein Registrierungsfehler.
    func testAKST2_1_jobHandlersComeFromModules() async throws {
        let handlers = try WorkerHandlers.registry(environment: [:], modules: app1.hubModules.modules)
        XCTAssertEqual(Set(handlers.keys), ["hook.job"])
        let withSelftest = try WorkerHandlers.registry(environment: ["WORKER_ENABLE_SELFTEST": "1"], modules: app1.hubModules.modules)
        XCTAssertEqual(Set(withSelftest.keys), ["hook.job", "worker.selftest"])
        // Die DMS-Arten liefert jetzt das DMS-Modul selbst
        let dms = try WorkerHandlers.registry(environment: [:], modules: InstalledModules.all)
        XCTAssertEqual(Set(dms.keys), ["dms.export", "dms.folder.scan", "dms.import.paperless", "dms.mail.poll", "dms.ocr", "dms.verify"])
        XCTAssertThrowsError(try WorkerHandlers.registry(environment: [:], modules: [BadJobModule()]))
        XCTAssertThrowsError(try WorkerHandlers.registry(environment: [:], modules: [HookModule(), TwinJobModule()]))
        // Vorabprüfung des Moduls für die gewählten Arten
        let ok = await WorkerHandlers.preflight(kinds: ["hook.job"], environment: [:], modules: app1.hubModules.modules)
        XCTAssertNil(ok)
        let failing = await WorkerHandlers.preflight(kinds: ["hook.job"], environment: ["HOOK_PREFLIGHT_FAIL": "1"], modules: app1.hubModules.modules)
        XCTAssertEqual(failing, "hook: Werkzeug fehlt")
        let other = await WorkerHandlers.preflight(kinds: ["worker.selftest"], environment: ["HOOK_PREFLIGHT_FAIL": "1"], modules: app1.hubModules.modules)
        XCTAssertNil(other)

        // E2E im Prozess: Job einreihen, Worker mit den Modul-Handlern laufen lassen
        let id = try await jobs.enqueue(kind: "hook.job")
        let worker = JobWorker(db: db, kinds: ["hook.job"], handlers: handlers, leaseSeconds: 30, pollInterval: .milliseconds(100), logger: Logger(label: "st2.w"))
        let run = Task { await worker.run() }
        try await waitFor("hook job done") { try await jobRow(id).state == "done" }
        worker.requestShutdown(); await run.value
        XCTAssertEqual(calls.value, 1)
    }

    /// AK-ST2-2: Token-Scopes deklarieren die Module; nur deklarierte Scopes lassen sich vergeben, das Token öffnet die Token-Route des Moduls.
    func testAKST2_2_tokenScopesAreDeclaredByModules() async throws {
        XCTAssertEqual(app1.hubModules.tokenScopes, ["hook.upload"])
        XCTAssertThrowsError(try ModuleRegistry([BadScopeModule()]), "Scope muss mit dem Modulschlüssel beginnen")
        let owner = try await bootstrap(app1, VirtualAuthenticator())
        let tenant = try await tenantOf(owner)
        // Die Mandantenbindung der Tokens ist Kernschema (ohne DMS vorhanden); der gespeicherte Migrationsname bleibt für Bestandsdatenbanken
        XCTAssertEqual(CreateApiTokenTenant().name, "dms_026_api_token_tenant")
        // DMS ist hier nicht installiert: sein Scope ist unbekannt
        let unknown = try await call(app1, .POST, "api/v1/auth/api-tokens", json: ["name": "Alt", "scopes": ["dms.upload"]], token: owner.token)
        XCTAssertEqual(unknown.status, .unprocessableEntity)
        XCTAssertEqual((unknown.json["errors"] as? [[String: Any]])?.first?["code"] as? String, "unknown_scope")
        let created = try await call(app2, .POST, "api/v1/auth/api-tokens", json: ["name": "Haken", "scopes": ["hook.upload"]], token: owner.token)
        XCTAssertEqual(created.status, .created, "\(created.json)")
        guard let token = created.json["token"] as? String else { return XCTFail("kein Token: \(created.json)") }
        let disabled = try await call(app1, .POST, "api/v1/tenants/\(tenant)/hook/drop", json: [:], token: token)
        XCTAssertEqual(disabled.problemCode, "module_disabled")
        try await enableHook(tenant, by: owner)
        let dropped = try await call(app2, .POST, "api/v1/tenants/\(tenant)/hook/drop", json: [:], token: token)
        XCTAssertEqual(dropped.status, .created, "\(dropped.json)")
        // Fehlerform des Kerns (ohne Modul-Fehlertyp): Feldfehler am unbekannten Schlüssel
        let bad = try await call(app1, .POST, "api/v1/auth/api-tokens", json: ["name": "X", "scopes": ["hook.upload"], "extra": 1], token: owner.token)
        XCTAssertEqual(bad.status, .unprocessableEntity)
        XCTAssertEqual((bad.json["errors"] as? [[String: Any]])?.first?["field"] as? String, "extra")
    }

    /// AK-ST2-3: Der Link-Schutz für `hook.*`-Seiten kommt vom Modul (Sichtbarkeit und Prüfung beim Anlegen/Entfernen), der Kern kennt das Modul nicht.
    func testAKST2_3_linkProtectionIsModuleHook() async throws {
        let owner = try await bootstrap(app1, VirtualAuthenticator())
        let tenant = try await tenantOf(owner)
        try await enableHook(tenant, by: owner)
        let member = try await addUser(.member, handle: "mia", tenant: tenant, by: owner)
        let accountant = try await addUser(.accountant, handle: "anna", tenant: tenant, by: owner)
        let base = "api/v1/tenants/\(tenant)"
        let contact = try await call(app1, .POST, base + "/contacts", json: ["kind": "organization", "display_name": "Haken GmbH"], token: owner.token).json["id"] as! String
        let thing = UUID().uuidString
        func link(_ id: String, by s: TestSession) async throws -> Resp {
            try await call(app2, .POST, base + "/links", json: ["from_type": "hook.thing", "from_id": id, "to_type": "contact", "to_id": contact, "kind": "related"], token: s.token)
        }
        let created = try await link(thing, by: accountant)
        XCTAssertEqual(created.status, .created, "\(created.json)")
        let locked = try await link(HookModule.lockedID.uuidString, by: owner)
        XCTAssertEqual(locked.status, .conflict); XCTAssertEqual(locked.problemCode, "hook_locked")
        let forbidden = try await link(UUID().uuidString, by: member)
        XCTAssertEqual(forbidden.status, .forbidden)
        // Sichtbarkeit: ohne `hook.item.read` fehlen die `hook.*`-Seiten in der Liste, eine direkte Abfrage gibt den Fehler des Moduls
        let hidden = try await call(app1, .GET, base + "/links?type=contact&id=\(contact)", token: member.token)
        XCTAssertEqual(hidden.status, .ok); XCTAssertEqual((hidden.json["items"] as? [Any])?.count, 0)
        let direct = try await call(app1, .GET, base + "/links?type=hook.thing&id=\(thing)", token: member.token)
        XCTAssertEqual(direct.status, .forbidden)
        let visible = try await call(app2, .GET, base + "/links?type=contact&id=\(contact)", token: accountant.token)
        XCTAssertEqual((visible.json["items"] as? [Any])?.count, 1)
        // Entfernen läuft ebenfalls über den Haken
        let linkID = created.json["id"] as! String
        let removeDenied = try await call(app1, .DELETE, base + "/links/\(linkID)", token: member.token)
        XCTAssertEqual(removeDenied.status, .forbidden)
        let removed = try await call(app1, .DELETE, base + "/links/\(linkID)", token: accountant.token)
        XCTAssertEqual(removed.status, .noContent)
    }
}
