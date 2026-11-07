import Vapor
import Fluent
import SQLKit

/// Aktivierungszustand eines Moduls für einen Mandanten.
struct ModuleStatus: Sendable, Equatable {
    let key: ModuleKey
    let installed: Bool   // Betreiberebene
    let enabled: Bool     // Mandantenschalter
    let effective: Bool   // installiert, an und alle `requires` wirksam
}

enum ModuleService {
    private static func keys(_ rows: [any SQLRow]) throws -> Set<String> {
        Set(try rows.map { try $0.decode(column: "module_key", as: String.self) })
    }

    static func uninstalled(on s: any SQLDatabase) async throws -> Set<String> {
        try keys(try await s.raw("SELECT module_key FROM installation_modules WHERE NOT enabled").all())
    }

    static func tenantEnabled(_ tenant: UUID, on s: any SQLDatabase) async throws -> Set<String> {
        try keys(try await s.raw("SELECT module_key FROM tenant_modules WHERE tenant_id = \(bind: tenant) AND enabled").all())
    }

    /// Zustand aller registrierten Module, bei jedem Aufruf frisch aus der Datenbank (kein Cache, AK-K3-5).
    static func statuses(_ registry: ModuleRegistry, tenant: UUID, on s: any SQLDatabase) async throws -> [ModuleStatus] {
        let off = try await uninstalled(on: s), on = try await tenantEnabled(tenant, on: s)
        var effective = Set(registry.modules.map(\.key).filter { !off.contains($0) && on.contains($0) })
        var changed = true
        while changed {  // requires wirksam; die Registry garantiert Zyklenfreiheit
            changed = false
            for m in registry.modules where effective.contains(m.key) && !m.requires.allSatisfy(effective.contains) {
                effective.remove(m.key); changed = true
            }
        }
        return registry.modules.map { ModuleStatus(key: $0.key, installed: !off.contains($0.key), enabled: on.contains($0.key), effective: effective.contains($0.key)) }
    }

    static func setTenant(_ key: ModuleKey, enabled: Bool, tenant: UUID, actor: UUID, requestID: String, registry: ModuleRegistry,
                          on db: any Database) async throws {
        guard let module = registry.module(key) else { throw HubError(.notFound, "not_found") }
        try await inTransaction(db) { s in
            // Schalter eines Mandanten serialisieren (Abhängigkeitsprüfung und Schreiben sind sonst nicht atomar)
            guard try await s.raw("SELECT id FROM tenants WHERE id = \(bind: tenant) FOR UPDATE").first() != nil else { throw HubError(.notFound, "not_found") }
            let off = try await uninstalled(on: s), on = try await tenantEnabled(tenant, on: s)
            if on.contains(key) == enabled { return }  // idempotent: kein Audit, kein onActivate
            if enabled {
                if off.contains(key) { throw HubError(.conflict, "module_unavailable") }
                let missing = module.requires.filter { off.contains($0) || !on.contains($0) }
                if !missing.isEmpty {
                    throw HubError(.conflict, "module_requires", errors: missing.sorted().map { FieldError(field: "requires", code: $0) })
                }
            } else {
                let dependents = registry.modules.filter { $0.requires.contains(key) && on.contains($0.key) }.map(\.key)
                if !dependents.isEmpty {
                    throw HubError(.conflict, "module_required_by", errors: dependents.sorted().map { FieldError(field: "required_by", code: $0) })
                }
            }
            try await s.raw("""
                INSERT INTO tenant_modules (tenant_id, module_key, enabled, updated_by) VALUES (\(bind: tenant), \(bind: key), \(bind: enabled), \(bind: actor))
                ON CONFLICT (tenant_id, module_key) DO UPDATE SET enabled = EXCLUDED.enabled, updated_by = EXCLUDED.updated_by, updated_at = now()
                """).run()
            try await AuditLog.record(AuditEvent(action: enabled ? "module.enabled" : "module.disabled", actor: actor, tenant: tenant,
                                                 subjectType: "module", subjectID: key, requestID: requestID), on: s)
            if enabled { try await module.onActivate(tenant: tenant, on: s) }
        }
    }

    /// Betreiberebene: `installed == false` macht das Modul für alle Mandanten unwirksam (Daten bleiben).
    static func setInstalled(_ key: ModuleKey, installed: Bool, actor: UUID, requestID: String, registry: ModuleRegistry, on db: any Database) async throws {
        guard registry.module(key) != nil else { throw HubError(.notFound, "not_found") }
        try await inTransaction(db) { s in
            try await s.raw("""
                INSERT INTO installation_modules (module_key, enabled, updated_by) VALUES (\(bind: key), \(bind: installed), \(bind: actor))
                ON CONFLICT (module_key) DO UPDATE SET enabled = EXCLUDED.enabled, updated_by = EXCLUDED.updated_by, updated_at = now()
                """).run()
            try await AuditLog.record(AuditEvent(action: installed ? "module.installation_enabled" : "module.installation_disabled", actor: actor,
                                                 subjectType: "module", subjectID: key, requestID: requestID), on: s)
        }
    }
}
