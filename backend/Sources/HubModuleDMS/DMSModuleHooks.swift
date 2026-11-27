import Vapor
import SQLKit
import HubCore

// WP-ST2: Was der Kern früher beim Namen kannte, liefert das DMS-Modul über die Haken von `HubModule`: Job-Handler (vorher `WorkerHandlers`),
// OCR-Vorabprüfung (vorher `WorkerCommand`), den Token-Scope `dms.upload` (vorher `ApiTokens.scopes`) und den Link-Schutz (vorher `LinkService`, WP-H14).
extension DMSModule {
    public var tokenScopes: [String] { ["dms.upload", "dms.scan.bridge"] }

    public func jobHandlers(environment: [String: String]) -> [String: JobHandler] {
        var map: [String: JobHandler] = [:]
        // WP-O2: OCR; Objektspeicher aus der Umgebung (wie das Backend), Arbeitsverzeichnis auf tmpfs (OCR_TMPDIR, Standard TMPDIR)
        let ocr = OCRConfig.fromEnvironment(environment)
        map[DMSOCR.kind] = DMSOCR.handler(engine: OCRToolEngine(config: ocr), tempRoot: ocr.tempRoot) { s in
            try ObjectStoreConfig.fromEnvironment(environment).makeStore(db: s)
        }
        // WP-D5: Prüf-Job und Export-Job
        map[DMSIntegrity.kind] = DMSIntegrity.handler { s in try ObjectStoreConfig.fromEnvironment(environment).makeStore(db: s) }
        map[DMSExport.kind] = DMSExport.handler(tempRoot: ocr.tempRoot) { s in try ObjectStoreConfig.fromEnvironment(environment).makeStore(db: s) }
        // WP-D4: Quellen. Mail-Passwort nur über SECRET_KEY(_FILE) entschlüsselbar; Konsumordner nur als eingebundenes Volume `DMS_FOLDER_ROOT` im Worker.
        let limits = DMSSourceLimits.fromEnvironment(environment)
        let storeConfig: @Sendable () throws -> ObjectStoreConfig = { try ObjectStoreConfig.fromEnvironment(environment) }
        map[DMSMailPoll.kind] = DMSMailPoll.handler(storeConfig: storeConfig, box: SecretBox.fromEnvironment(environment), imap: IMAPOptions.fromEnvironment(environment), limits: limits)
        map[DMSFolderScan.kind] = DMSFolderScan.handler(storeConfig: storeConfig, root: environment["DMS_FOLDER_ROOT"], limits: limits)
        // WP-D6: Paperless-Import. Export-Verzeichnisse nur als Volume `DMS_IMPORT_ROOT` im Worker; das Token der REST-Quelle nur über SECRET_KEY(_FILE) lesbar.
        map[DMSImport.kind] = DMSImport.handler(storeConfig: storeConfig, box: SecretBox.fromEnvironment(environment), root: environment["DMS_IMPORT_ROOT"], tempRoot: ocr.tempRoot,
                                                policy: PaperlessEndpoint.Policy.fromEnvironment(environment), limits: limits)
        return map
    }

    /// OCR-Werkzeuge und Arbeitsverzeichnis prüfen, bevor ein Worker `dms.ocr` übernimmt.
    public func workerPreflight(kinds: Set<String>, environment: [String: String]) async -> String? {
        guard kinds.contains(DMSOCR.kind) else { return nil }
        let config = OCRConfig.fromEnvironment(environment)
        return await OCRToolEngine.preflight(config: config, workDir: URL(fileURLWithPath: config.tempRoot, isDirectory: true))
    }

    /// WP-H14: `dms.*`-Seiten sieht man über die generische Route nur bei aktivem Modul und Recht `dms.document.read`; sonst fehlen sie in Listen,
    /// eine direkte `dms.*`-Abfrage gibt 404 `module_disabled` bzw. 403 (Existenz und Korrespondent eines Dokuments bleiben so verborgen).
    public func linkVisibility(tenant: UUID, permissions: Set<String>, on db: any SQLDatabase) async throws -> LinkVisibility {
        let active = try await DMSSources.dmsActive(tenant: tenant, on: db)
        if active && permissions.contains("dms.document.read") { return .visible }
        return .hidden(active ? HubError(.forbidden, "forbidden") : HubError(.notFound, "module_disabled"))
    }

    /// WP-H14: Schutz für `dms.document`-Seiten: Modul aktiv (sonst 404 `module_disabled`), Berechtigung `dms.document.update` (403), Dokument im Mandanten (404),
    /// nicht im Papierkorb (409 `document_trashed`), Zeilensperre wie beim Ändern und `rev + 1`. Andere `dms.*`-Typen sind über die generische Route nicht verknüpfbar.
    public func guardLinkEnds(_ ends: [LinkEnd], creating: Bool, permissions: Set<String>, tenant: UUID, on s: any SQLDatabase) async throws {
        for end in ends where end.type != "dms.document" && creating { throw ContactValidation.fail(end.field) }
        let documents = Array(Set(ends.filter { $0.type == "dms.document" }.map(\.id))).sorted { $0.uuidString < $1.uuidString }
        if documents.isEmpty { return }
        guard try await DMSSources.dmsActive(tenant: tenant, on: s) else { throw HubError(.notFound, "module_disabled") }
        guard permissions.contains("dms.document.update") else { throw HubError(.forbidden, "forbidden") }
        for id in documents {
            guard let row = try await s.raw("SELECT trashed_at FROM dms_documents WHERE tenant_id = \(bind: tenant) AND id = \(bind: id) FOR UPDATE").first()
            else { throw HubError(.notFound, "not_found") }
            if try row.decode(column: "trashed_at", as: Date?.self) != nil { throw DMSError.trashed }
            try await s.raw("UPDATE dms_documents SET rev = rev + 1, updated_at = now() WHERE tenant_id = \(bind: tenant) AND id = \(bind: id)").run()
        }
    }
}
