import Foundation

/// Feste Standardrollen (F-12, V1: im Code, nicht konfigurierbar). Rollenname = Wert in `memberships.role`.
public enum Role: String, CaseIterable, Sendable {
    case owner
    case accountant
    case member
    case taxAdvisor = "tax_advisor"
    case customerViewer = "customer_viewer"
}

/// Berechtigungskatalog `<modul>.<ressource>.<aktion>` und Zuordnung Rolle -> Berechtigungen.
/// Der Kern deklariert hier die eigenen und die absehbaren Modul-Berechtigungen; mit dem Modul-System (WP-K3) deklarieren Module ihre Einträge selbst.
/// `customer_viewer` hat bewusst nur den Mandanten-Lesezugriff; Zugriff auf einzelne Objekte kommt später über Freigaben (`grants`).
public enum Permissions {
    public static let catalog: [String] = [
        "tenant.tenant.read", "tenant.member.read", "tenant.member.invite", "tenant.member.manage",
        "tenant.module.read", "tenant.module.manage",
        "dms.document.read", "dms.document.create", "dms.document.update", "dms.document.delete",
        "invoice.document.read", "invoice.document.create", "invoice.document.update", "invoice.document.finalize",
        "contact.contact.read", "contact.contact.create", "contact.contact.update", "contact.contact.delete", "contact.contact.merge",
        "contact.link.read", "contact.link.write"
    ]

    private static let table: [Role: Set<String>] = [
        .owner: Set(catalog),
        .accountant: [
            "tenant.tenant.read", "tenant.member.read", "tenant.module.read",
            "dms.document.read", "dms.document.create", "dms.document.update", "dms.document.delete",
            "invoice.document.read", "invoice.document.create", "invoice.document.update", "invoice.document.finalize",
            "contact.contact.read", "contact.contact.create", "contact.contact.update", "contact.contact.delete", "contact.contact.merge",
            "contact.link.read", "contact.link.write"],
        .member: [
            "tenant.tenant.read", "tenant.member.read", "tenant.module.read",
            "dms.document.read", "dms.document.create", "dms.document.update",
            "invoice.document.read", "invoice.document.create", "invoice.document.update",
            "contact.contact.read", "contact.contact.create", "contact.contact.update", "contact.link.read", "contact.link.write"],
        .taxAdvisor: ["tenant.tenant.read", "tenant.module.read", "dms.document.read", "invoice.document.read", "contact.contact.read", "contact.link.read"],
        .customerViewer: ["tenant.tenant.read", "tenant.module.read"]
    ]

    public static func of(_ role: Role) -> Set<String> { table[role] ?? [] }
}
