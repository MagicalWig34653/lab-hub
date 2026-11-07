import Vapor
import Fluent
import SQLKit

// WP-K3 Modul-System (ADR 0004, ARCHITEKTUR 3). Bewusst schlank: Migrationen, Berechtigungen, Navigation, Routen, Aktivierungs-Hook.
// Events, Jobs und Suchindex-Hook kommen als weitere Protokollanforderungen mit Default-Implementierung, sobald deren WPs sie brauchen.

public typealias ModuleKey = String

/// Berechtigung eines Moduls, `<modulkey>.<ressource>.<aktion>`. Der Owner hat immer alle; `roles` nennt die übrigen Rollen.
public struct PermissionDefinition: Sendable, Equatable {
    public let name: String
    public let roles: Set<Role>
    public init(_ name: String, roles: Set<Role> = []) { self.name = name; self.roles = roles }
}

/// Menüeintrag. `labelKey` ist ein i18n-Schlüssel (kein Nutzertext im Backend). `permission` begrenzt die Sichtbarkeit auf Rollen mit diesem Recht.
public struct NavigationItem: Sendable, Equatable {
    public let key: String
    public let labelKey: String
    public let path: String
    public let permission: String?
    public init(key: String, labelKey: String, path: String, permission: String? = nil) {
        self.key = key; self.labelKey = labelKey; self.path = path; self.permission = permission
    }
}

public protocol HubModule: Sendable {
    /// Stabil, nie umbenennen. `^[a-z][a-z0-9]{0,31}$`; zugleich Tabellenpräfix und Pfadsegment unter `/api/v1/tenants/{tenant}/<key>`.
    var key: ModuleKey { get }
    /// Harte Abhängigkeit: Aktivierung scheitert ohne, Deaktivierung scheitert bei aktivem Abhängigem.
    var requires: [ModuleKey] { get }
    var enhances: [ModuleKey] { get }
    var permissions: [PermissionDefinition] { get }
    /// Laufen immer (auch bei deaktiviertem Modul), nur im Migrationsjob. Namen `<key>_<nnn>_<name>`.
    var migrations: [any Migration] { get }
    var navigation: [NavigationItem] { get }
    /// Routen nur über `ModuleRoutes.on(...)`: Mandant, Modulschalter und Berechtigung werden zentral geprüft.
    func registerRoutes(_ routes: ModuleRoutes) throws
    /// Beim Übergang aus -> an für einen Mandanten, in derselben Transaktion wie die Aktivierung. Muss idempotent sein.
    func onActivate(tenant: UUID, on db: any SQLDatabase) async throws
}

public extension HubModule {
    var requires: [ModuleKey] { [] }
    var enhances: [ModuleKey] { [] }
    var permissions: [PermissionDefinition] { [] }
    var migrations: [any Migration] { [] }
    var navigation: [NavigationItem] { [] }
    func registerRoutes(_ routes: ModuleRoutes) throws {}
    func onActivate(tenant: UUID, on db: any SQLDatabase) async throws {}
}

/// Feste, zur Build-Zeit bekannte Modulliste (ADR 0004). Hier trägt WP-D2 usw. ein Modul ein.
public enum InstalledModules {
    public static let all: [any HubModule] = [DMSModule(enqueueOCR: ProcessInfo.processInfo.environment["DMS_OCR_ENABLED"] != "false")]
}

/// Geprüfte Modulliste. Ein Registrierungsfehler ist ein Programmierfehler und bricht den Start ab.
public struct ModuleRegistry: Sendable {
    public let modules: [any HubModule]
    private let byKey: [ModuleKey: any HubModule]

    static let reservedKeys: Set<String> = ["members", "invitations", "modules"]  // Pfadsegmente des Kerns unter /tenants/{tenant}

    public init(_ modules: [any HubModule] = []) throws {
        var map: [ModuleKey: any HubModule] = [:]
        for m in modules {
            guard m.key.range(of: "^[a-z][a-z0-9]{0,31}$", options: .regularExpression) != nil, !Self.reservedKeys.contains(m.key) else {
                throw ConfigError(description: "Ungültiger Modulschlüssel \(m.key)")
            }
            guard map[m.key] == nil else { throw ConfigError(description: "Modulschlüssel doppelt: \(m.key)") }
            map[m.key] = m
            for p in m.permissions {
                let parts = p.name.split(separator: ".", omittingEmptySubsequences: false)
                guard parts.count == 3, parts[0] == m.key, AuditValue.isSafeToken(p.name) else {
                    throw ConfigError(description: "Berechtigung \(p.name) passt nicht zu Modul \(m.key)")
                }
                guard !Permissions.catalog.contains(p.name) else { throw ConfigError(description: "Berechtigung \(p.name) steht bereits im Kernkatalog") }
            }
        }
        for m in modules {
            for r in m.requires where map[r] == nil { throw ConfigError(description: "Modul \(m.key) benötigt unbekanntes Modul \(r)") }
        }
        // Zyklen: Abhängigkeiten schrittweise auflösen
        var resolved = Set<ModuleKey>()
        while resolved.count < modules.count {
            let ready = modules.filter { !resolved.contains($0.key) && $0.requires.allSatisfy(resolved.contains) }
            guard !ready.isEmpty else { throw ConfigError(description: "Zyklische Modulabhängigkeit") }
            resolved.formUnion(ready.map(\.key))
        }
        self.modules = modules
        self.byKey = map
    }

    public func module(_ key: ModuleKey) -> (any HubModule)? { byKey[key] }
    public var migrations: [any Migration] { modules.flatMap(\.migrations) }

    /// Berechtigungen des Moduls für eine Rolle (Owner: alle).
    func permissions(of role: Role, module key: ModuleKey) -> Set<String> {
        guard let m = byKey[key] else { return [] }
        return Set(m.permissions.filter { role == .owner || $0.roles.contains(role) }.map(\.name))
    }
}

extension Application {
    private struct ModuleRegistryKey: StorageKey { typealias Value = ModuleRegistry }
    public var hubModules: ModuleRegistry {
        get { storage[ModuleRegistryKey.self] ?? (try! ModuleRegistry()) }
        set { storage[ModuleRegistryKey.self] = newValue }
    }
}
