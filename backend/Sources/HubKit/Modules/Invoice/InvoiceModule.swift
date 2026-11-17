import Vapor
import Fluent
import SQLKit

// WP-R1 Rechnungsmodul, Stammdaten (ADR 0004, MODUL-RECHNUNG.md). HubModule `invoice`, Routen unter /api/v1/tenants/{tenant}/invoice/…,
// Berechtigungen `invoice.master.read|manage`. Das Modul nutzt den Kern nur über dessen Dienste (CounterService, AuditLog, IdempotencyService).
// Belege, Berechnung und Finalisieren kommen mit WP-R2; die Kernberechtigungen `invoice.document.*` (Tenancy/Roles.swift) werden dort verschoben.

public struct InvoiceModule: HubModule {
    public let key = "invoice"

    public init() {}

    /// Lesen: Buchhaltung, Mitglied, Steuerberater (MODUL-RECHNUNG nennt keine feinere Rollenmatrix; Annahme, siehe docs/handoff/WP-R1.md).
    /// Schreiben: Buchhaltung und Owner. `customer_viewer` hat keinen Zugriff auf Stammdaten (Bankdaten, Preise).
    public var permissions: [PermissionDefinition] {
        [PermissionDefinition("invoice.master.read", roles: [.accountant, .member, .taxAdvisor]),
         PermissionDefinition("invoice.master.manage", roles: [.accountant])]
    }

    public var migrations: [any Migration] { [CreateInvoiceMaster()] }

    public var navigation: [NavigationItem] { [NavigationItem(key: "invoice", labelKey: "nav.invoice", path: "/invoice", permission: "invoice.master.read")] }

    public func registerRoutes(_ routes: ModuleRoutes) throws {
        routes.on(.GET, "settings", permission: "invoice.master.read") { req in try await InvoiceSettings.read(req) }
        routes.on(.PUT, "settings", permission: "invoice.master.manage") { req in try await InvoiceSettings.replace(req) }
        for spec in InvoiceMasterSpec.all {
            let segment = PathComponent.constant(spec.segment)
            routes.on(.GET, segment, permission: "invoice.master.read") { req in try await spec.list(req) }
            routes.on(.POST, segment, permission: "invoice.master.manage") { req in try await spec.create(req) }
            routes.on(.GET, segment, ":id", permission: "invoice.master.read") { req in try await spec.get(req) }
            routes.on(.PATCH, segment, ":id", permission: "invoice.master.manage") { req in try await spec.update(req) }
            routes.on(.DELETE, segment, ":id", permission: "invoice.master.manage") { req in try await spec.delete(req) }
        }
    }
}
