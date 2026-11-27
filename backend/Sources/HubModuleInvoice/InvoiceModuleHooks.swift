import Vapor
import SQLKit
import HubCore

// WP-R6c: Was der Kern früher beim Namen kannte, liefert das Rechnungsmodul über die Haken von `HubModule` (wie `DMSModuleHooks.swift`):
// Job-Handler `invoice.render` und die Vorabprüfung der Render-Werkzeuge beim Start eines Workers.
extension InvoiceModule {
    public func jobHandlers(environment: [String: String]) -> [String: JobHandler] {
        let renderer = InvoiceToolRenderer(InvoiceRenderConfig.fromEnvironment(environment))
        return [InvoiceRenderJob.kind: InvoiceRenderJob.handler(renderer: renderer) { s in try ObjectStoreConfig.fromEnvironment(environment).makeStore(db: s) }]
    }

    /// Typst, qpdf, Schriften und Arbeitsverzeichnis prüfen, bevor ein Worker `invoice.render` übernimmt (sonst liefen alle Aufträge in die Quarantäne).
    public func workerPreflight(kinds: Set<String>, environment: [String: String]) async -> String? {
        guard kinds.contains(InvoiceRenderJob.kind) else { return nil }
        return await InvoiceToolRenderer.preflight(InvoiceRenderConfig.fromEnvironment(environment))
    }
}
