import Vapor
import Fluent
import SQLKit
import HubCore

// WP-R1 Rechnungsmodul, Stammdaten (ADR 0004, MODUL-RECHNUNG.md). HubModule `invoice`, Routen unter /api/v1/tenants/{tenant}/invoice/…,
// Berechtigungen `invoice.master.read|manage`. Das Modul nutzt den Kern nur über dessen Dienste (CounterService, AuditLog, IdempotencyService).
// WP-R2: Belege, Berechnung und Finalisieren; die Berechtigungen `invoice.document.*` deklariert das Modul selbst (nicht mehr der Kernkatalog).
// WP-R6c: Render-Job und PDF-Download (`Render/`), Haken für Worker (`InvoiceModuleHooks.swift`).

public struct InvoiceModule: HubModule {
    public let key = "invoice"
    /// WP-R6c: Objektspeicher für die Auslieferung der Beleg-PDF (wie das DMS aus `OBJECT_STORE*`); ein ungültiger Wert wirkt erst beim Abruf (500), nicht beim Start.
    let objectStore: Result<ObjectStoreConfig, ConfigError>

    public init(objectStore: ObjectStoreConfig? = nil, environment: [String: String] = ProcessInfo.processInfo.environment) {
        if let objectStore { self.objectStore = .success(objectStore) } else {
            do { self.objectStore = .success(try ObjectStoreConfig.fromEnvironment(environment)) }
            catch let e as ConfigError { self.objectStore = .failure(e) }
            catch { self.objectStore = .failure(ConfigError(description: "OBJECT_STORE ungültig")) }
        }
    }

    /// Lesen: Buchhaltung, Mitglied, Steuerberater (MODUL-RECHNUNG nennt keine feinere Rollenmatrix; Annahme, siehe docs/handoff/WP-R1.md).
    /// Schreiben: Buchhaltung und Owner. `customer_viewer` hat keinen Zugriff auf Stammdaten (Bankdaten, Preise).
    public var permissions: [PermissionDefinition] {
        [PermissionDefinition("invoice.master.read", roles: [.accountant, .member, .taxAdvisor]),
         PermissionDefinition("invoice.master.manage", roles: [.accountant]),
         // WP-R2: Belege. Lesen wie Stammdaten; Anlegen/Ändern auch für Mitglieder; Finalisieren (vergibt die Nummer) nur Buchhaltung und Owner.
         PermissionDefinition("invoice.document.read", roles: [.accountant, .member, .taxAdvisor]),
         PermissionDefinition("invoice.document.create", roles: [.accountant, .member]),
         PermissionDefinition("invoice.document.update", roles: [.accountant, .member]),
         PermissionDefinition("invoice.document.finalize", roles: [.accountant]),
         // WP-R3: Zahlungen lesen wie Belege; erfassen, zuordnen und stornieren nur Buchhaltung und Owner.
         PermissionDefinition("invoice.payment.read", roles: [.accountant, .member, .taxAdvisor]),
         PermissionDefinition("invoice.payment.write", roles: [.accountant])]
    }

    public var migrations: [any Migration] { [CreateInvoiceMaster(), CreateInvoiceDocuments(), CreateInvoicePayments(), CreateInvoiceRender()] }

    public var navigation: [NavigationItem] { [NavigationItem(key: "invoice", labelKey: "nav.invoice", path: "/invoice", permission: "invoice.master.read")] }

    public func registerRoutes(_ routes: ModuleRoutes) throws {
        let module = self
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
        routes.on(.GET, "documents", permission: "invoice.document.read") { req in try await InvoiceDocuments.list(req) }
        routes.on(.POST, "documents", permission: "invoice.document.create") { req in try await InvoiceDocuments.create(req) }
        routes.on(.GET, "documents", ":id", permission: "invoice.document.read") { req in try await InvoiceDocuments.get(req) }
        routes.on(.PATCH, "documents", ":id", permission: "invoice.document.update") { req in try await InvoiceDocuments.update(req) }
        routes.on(.DELETE, "documents", ":id", permission: "invoice.document.update") { req in try await InvoiceDocuments.delete(req) }
        routes.on(.POST, "documents", ":id", "finalize", permission: "invoice.document.finalize") { req in try await InvoiceDocuments.finalize(req) }
        // WP-R6c: PDF des finalen Belegs (Render-Job `invoice.render`)
        routes.on(.GET, "documents", ":id", "pdf", permission: "invoice.document.read") { req in
            try await InvoiceRenderRoutes.pdf(req) { s in try module.objectStore.get().makeStore(db: s) }
        }
        routes.on(.POST, "documents", ":id", "render", permission: "invoice.document.finalize") { req in try await InvoiceRenderRoutes.render(req) }
        // WP-R3: Umwandlung, Gutschrift, Verknüpfungen, Zahlungen
        routes.on(.POST, "documents", ":id", "convert", permission: "invoice.document.create") { req in try await InvoiceLinks.convert(req) }
        routes.on(.POST, "documents", ":id", "credit-note", permission: "invoice.document.create") { req in try await InvoiceLinks.creditNote(req) }
        routes.on(.GET, "documents", ":id", "links", permission: "invoice.document.read") { req in try await InvoiceLinks.list(req) }
        routes.on(.POST, "documents", ":id", "links", permission: "invoice.document.update") { req in try await InvoiceLinks.create(req) }
        routes.on(.DELETE, "documents", ":id", "links", ":link", permission: "invoice.document.update") { req in try await InvoiceLinks.delete(req) }
        routes.on(.GET, "documents", ":id", "balance", permission: "invoice.payment.read") { req in try await InvoicePayments.balance(req) }
        routes.on(.GET, "payments", permission: "invoice.payment.read") { req in try await InvoicePayments.list(req) }
        routes.on(.POST, "payments", permission: "invoice.payment.write") { req in try await InvoicePayments.create(req) }
        routes.on(.GET, "payments", ":id", permission: "invoice.payment.read") { req in try await InvoicePayments.get(req) }
        routes.on(.GET, "payments", ":id", "suggestions", permission: "invoice.payment.read") { req in try await InvoicePayments.suggestions(req) }
        routes.on(.POST, "payments", ":id", "allocations", permission: "invoice.payment.write") { req in try await InvoicePayments.allocate(req) }
        routes.on(.DELETE, "payments", ":id", "allocations", ":allocation", permission: "invoice.payment.write") { req in try await InvoicePayments.revoke(req) }
        routes.on(.POST, "payments", ":id", "void", permission: "invoice.payment.write") { req in try await InvoicePayments.void(req) }
    }
}
