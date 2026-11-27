import Foundation
import HubCore
import HubModuleDMS
import HubModuleInvoice

/// Feste, zur Build-Zeit bekannte Modulliste (ADR 0004). Hier trägt ein neues Modul sich ein; außerhalb von `Modules/<Name>/` ist das die einzige Stelle
/// im Kern, die Module beim Namen kennt (WP-ST2, AK-ST2-4, Architekturtest `ArchitectureTests`).
public enum InstalledModules {
    public static let all: [any HubModule] = [DMSModule(enqueueOCR: ProcessInfo.processInfo.environment["DMS_OCR_ENABLED"] != "false"), InvoiceModule()]
}
