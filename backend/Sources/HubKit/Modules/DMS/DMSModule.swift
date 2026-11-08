import Vapor
import Fluent
import SQLKit

// WP-D2 DMS-Kern als HubModule `dms` (ADR 0004, MODUL-DMS.md). Routen unter /api/v1/tenants/{tenant}/dms/…, Berechtigungen `dms.*`.
// F-14 (Entscheidung, siehe docs/handoff/WP-D2.md): vorerst kein eigenes SwiftPM-Target; das Modul liegt im Verzeichnis Modules/DMS/ von HubKit
// und nutzt den Kern nur über dessen Dienste (CounterService, AuditLog, FileRecordService, IdempotencyService, ObjectStore, ContactService/LinkService).

public struct DMSModule: HubModule {
    public let key = "dms"
    let objectStore: Result<ObjectStoreConfig, ConfigError>
    let maxUploadBytes: Int64
    /// WP-H6: Speicherquota je Mandant in Bytes (`DMS_TENANT_QUOTA_BYTES`, Standard 1 TiB); Summe aller Dateien des Mandanten (Dedup zählt einmal).
    let tenantQuotaBytes: Int64
    /// WP-O2: Upload reiht einen OCR-Job ein (`dms.ocr`). Produktiv an (`DMS_OCR_ENABLED`, Standard true); der Initialisierer ohne Angabe lässt es aus,
    /// damit Tests und Entwicklung ohne Worker das bisherige Verhalten (Zustand `hashed` nach dem Upload) behalten.
    let enqueueOCR: Bool
    /// WP-D5: Standard-Aufbewahrungsjahre für Dokumente ohne Typfrist (`DMS_DEFAULT_RETENTION_YEARS`, Standard 10, 0 = keine Frist). Konfiguration, keine rechtliche Zusage.
    let defaultRetentionYears: Int
    /// WP-D4: Schlüssel für die Zugangsdaten der Quellen (`SECRET_KEY(_FILE)`); ohne ihn lassen sich Mail-Quellen weder anlegen noch abfragen (422, Feld `password`, Code `secret_key_missing`; 5xx-Details würden nicht ausgegeben).
    let secretBox: SecretBox?
    /// WP-D6: Richtlinie für die REST-Quelle des Paperless-Imports (https, Host-Allowlist `DMS_IMPORT_HOST_ALLOWLIST`, Entwicklungsschalter `DMS_IMPORT_INSECURE_DEV`).
    let importPolicy: PaperlessEndpoint.Policy

    /// Standard: Objektspeicher aus der Umgebung (`OBJECT_STORE*`), Upload-Limit `DMS_MAX_UPLOAD_BYTES` (Standard 100 MiB).
    public init(objectStore: ObjectStoreConfig? = nil, maxUploadBytes: Int64? = nil, tenantQuotaBytes: Int64? = nil, enqueueOCR: Bool = false, defaultRetentionYears: Int? = nil, secretKey: String? = nil, environment: [String: String] = ProcessInfo.processInfo.environment) {
        if let objectStore { self.objectStore = .success(objectStore) } else {
            do { self.objectStore = .success(try ObjectStoreConfig.fromEnvironment(environment)) }
            catch let e as ConfigError { self.objectStore = .failure(e) }
            catch { self.objectStore = .failure(ConfigError(description: "OBJECT_STORE ungültig")) }
        }
        self.enqueueOCR = enqueueOCR
        self.importPolicy = PaperlessEndpoint.Policy.fromEnvironment(environment)
        self.secretBox = secretKey.flatMap { SecretBox(secretKey: $0) } ?? SecretBox.fromEnvironment(environment)
        self.defaultRetentionYears = defaultRetentionYears ?? DMSRetention.defaultYears(environment)
        self.tenantQuotaBytes = tenantQuotaBytes ?? environment["DMS_TENANT_QUOTA_BYTES"].flatMap(Int64.init).flatMap { $0 > 0 ? $0 : nil } ?? 1024 * 1024 * 1024 * 1024
        self.maxUploadBytes = maxUploadBytes ?? environment["DMS_MAX_UPLOAD_BYTES"].flatMap(Int64.init).flatMap { $0 > 0 ? $0 : nil } ?? 100 * 1024 * 1024
    }

    /// Rollen laut MODUL-DMS.md Abschnitt 3 (Owner hat immer alle). `purge`, `rule.manage`, `source.manage` usw. kommen mit den jeweiligen WPs.
    public var permissions: [PermissionDefinition] {
        [PermissionDefinition("dms.document.read", roles: [.accountant, .member, .taxAdvisor]),
         PermissionDefinition("dms.document.create", roles: [.accountant, .member]),
         PermissionDefinition("dms.document.update", roles: [.accountant, .member]),
         PermissionDefinition("dms.document.trash", roles: [.accountant]),
         PermissionDefinition("dms.document.download_original", roles: [.accountant, .member, .taxAdvisor]),
         PermissionDefinition("dms.tag.manage", roles: [.accountant]),
         PermissionDefinition("dms.master.manage", roles: [.accountant]),
         // WP-D5: endgültiges Löschen nur Owner (Standardrollen MODUL-DMS 3); Frist/Sperre und Prüfung: Buchhaltung; Export auch Steuerberater (Prüfzugriff)
         PermissionDefinition("dms.document.purge"),
         PermissionDefinition("dms.document.retention", roles: [.accountant]),
         PermissionDefinition("dms.integrity.run", roles: [.accountant]),
         PermissionDefinition("dms.export.run", roles: [.accountant, .taxAdvisor]),
         // WP-D4: Quellen (Mail, Konsumordner) enthalten Zugangsdaten und lösen Fremdzugriffe aus: Buchhaltung
         PermissionDefinition("dms.source.read", roles: [.accountant]),
         PermissionDefinition("dms.source.manage", roles: [.accountant]),
         // WP-D6: Paperless-Import (legt Kontakte, Stammdaten und Dokumente an): Buchhaltung und Owner
         PermissionDefinition("dms.import.read", roles: [.accountant]),
         PermissionDefinition("dms.import.manage", roles: [.accountant])] + Self.rulePermissions   // WP-D3: dms.rule.*, dms.suggestion.*
    }

    public var migrations: [any Migration] { [CreateDMSCore(), CreateDMSIngest(), CreateDMSSearch(), CreateDMSOCR(), CreateDMSRules(), CreateDMSRevision(), CreateDMSSources(), CreateDMSImport(), CreateDMSExtraction()] }
    public var navigation: [NavigationItem] { [NavigationItem(key: "dms", labelKey: "nav.dms", path: "/dms", permission: "dms.document.read")] }

    func makeStore(_ req: Request) throws -> any ObjectStore {
        try objectStore.get().makeStore(db: try sql(req.db))
    }

    public func registerRoutes(_ routes: ModuleRoutes) throws {
        let module = self
        // Upload (Streaming, Idempotency-Key Pflicht)
        routes.on(.POST, "uploads", permission: "dms.document.create", body: .stream) { req in try await DMSUpload.handle(req, module: module) }

        // Dokumente
        routes.on(.GET, "documents", permission: "dms.document.read") { req in
            var filter = DMSDocuments.Filter()
            filter.trashed = (req.query["trashed"] as String?) == "true"
            if let status: String = req.query["status"] {
                guard ["processing", "needs_review", "archived"].contains(status) else { throw DMSError.invalid("status") }
                filter.status = status
            }
            for (name, keyPath) in [("document_type_id", \DMSDocuments.Filter.typeID), ("tag_id", \.tagID), ("correspondent_id", \.correspondentID)] {
                if let raw: String = req.query[name] {
                    guard let id = UUID(uuidString: raw) else { throw DMSError.invalid(name) }
                    filter[keyPath: keyPath] = id
                }
            }
            if let raw: String = req.query["asn"] {
                guard let asn = Int64(raw), asn > 0 else { throw DMSError.invalid("asn") }
                filter.asn = asn
            }
            filter.q = req.query["q"]
            try DMSExtractionQuery.apply(req, to: &filter)
            return try dmsJSON(try await DMSDocuments.list(tenant: try req.requireTenant().tenantID, page: try HubPageRequest(req), filter: filter, on: req.db))
        }
        routes.on(.GET, "documents", ":document", permission: "dms.document.read") { req in
            guard let doc = try await DMSDocuments.load(try dmsDocumentID(req), tenant: try req.requireTenant().tenantID, on: try sql(req.db)) else { throw DMSError.notFound }
            return try dmsJSON(doc)
        }
        routes.on(.PATCH, "documents", ":document", permission: "dms.document.update") { req in
            let ifMatch: Int?
            if let raw = req.headers.first(name: .ifMatch) {
                guard let rev = Int(raw.trimmingCharacters(in: CharacterSet(charactersIn: "\" "))) else { throw DMSError.invalid("If-Match") }
                ifMatch = rev
            } else { ifMatch = nil }
            let body = try req.content.decode(DMSDocumentPatch.self)
            return try dmsJSON(try await DMSDocuments.patch(try dmsDocumentID(req), tenant: try req.requireTenant().tenantID, actor: try req.requireAuth().user.id,
                                                         requestID: req.requestId, body: body, ifMatch: ifMatch, on: req.db))
        }
        routes.on(.POST, "documents", ":document", "processing", "retry", permission: "dms.document.update") { req in
            let tenant = try req.requireTenant().tenantID
            let id = try dmsDocumentID(req)
            return try dmsJSON(try await DMSOCR.retryPermanent(document: id, tenant: tenant, actor: try req.requireAuth().user.id, requestID: req.requestId,
                                                               priority: DMSOCR.priorityManual, on: req.db))
        }
        routes.on(.POST, "documents", ":document", "archive", permission: "dms.document.update") { req in
            try dmsJSON(try await DMSDocuments.archive(try dmsDocumentID(req), tenant: try req.requireTenant().tenantID, actor: try req.requireAuth().user.id,
                                                    requestID: req.requestId, on: req.db))
        }
        routes.on(.POST, "documents", ":document", "trash", permission: "dms.document.trash") { req in
            let body = try? req.content.decode(DMSTrashBody.self)
            return try dmsJSON(try await DMSDocuments.trash(try dmsDocumentID(req), reason: body?.reason, tenant: try req.requireTenant().tenantID,
                                                         actor: try req.requireAuth().user.id, requestID: req.requestId, on: req.db))
        }
        routes.on(.POST, "documents", ":document", "restore", permission: "dms.document.trash") { req in
            try dmsJSON(try await DMSDocuments.restore(try dmsDocumentID(req), tenant: try req.requireTenant().tenantID, actor: try req.requireAuth().user.id,
                                                    requestID: req.requestId, on: req.db))
        }
        routes.on(.GET, "documents", ":document", "file", permission: "dms.document.read") { req in
            let context = try req.requireTenant()
            let role: String = req.query["role"] ?? "original"
            guard DMSDownload.roles.contains(role) else { throw DMSError.invalid("role") }
            // Das Original braucht das eigene Recht `download_original` (Steuerberater/Mitglieder ja, später per Freigabe auch andere)
            if role == "original" { try req.require("dms.document.download_original") }
            let disposition: String = req.query["disposition"] ?? "attachment"
            guard ["attachment", "inline"].contains(disposition) else { throw DMSError.invalid("disposition") }
            let id = try dmsDocumentID(req)
            let s = try sql(req.db)
            guard let file = try await DMSDocuments.file(of: id, role: role, tenant: context.tenantID, on: s) else { throw DMSError.notFound }
            if role == "original" {
                try await AuditLog.record(AuditEvent(action: "dms.document.downloaded", actor: try req.requireAuth().user.id, tenant: context.tenantID,
                                                     subjectType: "dms.document", subjectID: id.uuidString, meta: ["role": .token(role)], requestID: req.requestId), on: s)
            }
            return try await DMSDownload.response(file: file, tenant: context.tenantID, store: try module.makeStore(req), inline: disposition == "inline")
        }

        // Extraktion (WP-D7): Dokumentart und Fakten lesen, Neu-Lauf
        routes.on(.GET, "documents", ":document", "extraction", permission: "dms.document.read") { req in
            let tenant = try req.requireTenant().tenantID
            guard let f = try await DMSExtraction.loadFacts(document: try dmsDocumentID(req), tenant: tenant, on: try sql(req.db)) else { throw DMSError.notFound }
            return try dmsJSON(DMSExtraction.out(f, detail: true))
        }
        routes.on(.POST, "documents", ":document", "extraction", "run", permission: "dms.document.update") { req in
            try dmsJSON(try await DMSExtraction.rerun(document: try dmsDocumentID(req), tenant: try req.requireTenant().tenantID, actor: try req.requireAuth().user.id, requestID: req.requestId, on: req.db))
        }

        // Verarbeitungsstatus (WP-O2): Fortschritt der Ingest-Kette für die PWA
        routes.on(.GET, "documents", ":document", "processing", permission: "dms.document.read") { req in
            guard let out = try await DMSOCR.status(document: try dmsDocumentID(req), tenant: try req.requireTenant().tenantID, on: try sql(req.db)) else { throw DMSError.notFound }
            return try dmsJSON(out)
        }

        // Suche (WP-S1, ADR 0005)
        routes.on(.GET, "search", permission: "dms.document.read") { req in
            try dmsJSON(try await DMSSearch.run(try DMSSearch.parse(req, tenant: try req.requireTenant().tenantID), on: req.db))
        }

        // Regeln, Vorschläge, Duplikate (WP-D3)
        registerRuleRoutes(routes)

        // Quellen (WP-D4) und Share-/Scan-API
        registerSourceRoutes(routes, module: module)

        // Paperless-Import (WP-D6) und Notizen
        registerImportRoutes(routes, module: module)

        // Revisionssicherheit (WP-D5): Aufbewahrung, Löschsperre, endgültiges Löschen, Prüfläufe, Export
        let years = defaultRetentionYears
        routes.on(.GET, "documents", ":document", "retention", permission: "dms.document.read") { req in
            try dmsJSON(try await DMSRetention.get(try dmsDocumentID(req), tenant: try req.requireTenant().tenantID, defaultYears: years, on: try sql(req.db)))
        }
        routes.on(.PATCH, "documents", ":document", "retention", permission: "dms.document.retention") { req in
            let body = try req.content.decode(DMSRetentionBody.self)
            return try dmsJSON(try await DMSRetention.update(try dmsDocumentID(req), body: body, tenant: try req.requireTenant().tenantID, actor: try req.requireAuth().user.id,
                                                          requestID: req.requestId, defaultYears: years, on: req.db))
        }
        routes.on(.POST, "documents", ":document", "purge", permission: "dms.document.purge") { req in
            try dmsJSON(try await DMSPurge.purge(try dmsDocumentID(req), tenant: try req.requireTenant().tenantID, actor: try req.requireAuth().user.id, requestID: req.requestId,
                                              defaultYears: years, config: try module.objectStore.get(), db: req.db, logger: req.logger))
        }
        routes.on(.GET, "deletion-log", permission: "dms.document.trash") { req in
            try dmsJSON(["items": try await DMSRetention.log(tenant: try req.requireTenant().tenantID, on: try sql(req.db))])
        }
        routes.on(.POST, "integrity-runs", permission: "dms.integrity.run") { req in
            try dmsJSON(try await DMSIntegrity.enqueue(tenant: try req.requireTenant().tenantID, actor: try req.requireAuth().user.id, requestID: req.requestId, on: req.db), status: .accepted)
        }
        routes.on(.GET, "integrity-runs", permission: "dms.integrity.run") { req in
            try dmsJSON(["items": try await DMSIntegrity.list(tenant: try req.requireTenant().tenantID, on: try sql(req.db))])
        }
        routes.on(.GET, "integrity-runs", ":run", permission: "dms.integrity.run") { req in
            guard let id = req.parameters.get("run", as: UUID.self), let out = try await DMSIntegrity.load(id, tenant: try req.requireTenant().tenantID, on: try sql(req.db)) else { throw DMSError.notFound }
            return try dmsJSON(out)
        }
        routes.on(.POST, "exports", permission: "dms.export.run") { req in
            let body = (try? req.content.decode(DMSExportParams.self)) ?? DMSExportParams()
            return try dmsJSON(try await DMSExport.enqueue(body, tenant: try req.requireTenant().tenantID, actor: try req.requireAuth().user.id, requestID: req.requestId, on: req.db), status: .accepted)
        }
        routes.on(.GET, "exports", permission: "dms.export.run") { req in
            try dmsJSON(["items": try await DMSExport.list(tenant: try req.requireTenant().tenantID, on: try sql(req.db))])
        }
        routes.on(.GET, "exports", ":export", permission: "dms.export.run") { req in
            guard let id = req.parameters.get("export", as: UUID.self), let out = try await DMSExport.load(id, tenant: try req.requireTenant().tenantID, on: try sql(req.db)) else { throw DMSError.notFound }
            return try dmsJSON(out)
        }
        routes.on(.GET, "exports", ":export", "file", permission: "dms.export.run") { req in
            let context = try req.requireTenant()
            let s = try sql(req.db)
            guard let id = req.parameters.get("export", as: UUID.self), let result = try await DMSExport.result(id, tenant: context.tenantID, on: s) else { throw DMSError.notFound }
            try await AuditLog.record(AuditEvent(action: "dms.export.downloaded", actor: try req.requireAuth().user.id, tenant: context.tenantID, subjectType: "dms.export",
                                                 subjectID: id.uuidString, requestID: req.requestId), on: s)
            let file = DMSDocuments.StoredFile(sha256: result.sha256, size: result.size, mime: "application/zip", originalName: nil, title: "dms-export-\(id.uuidString.lowercased().prefix(8))")
            return try await DMSDownload.response(file: file, tenant: context.tenantID, store: try module.makeStore(req), inline: false)
        }

        // Stammdaten: Lesen mit dms.document.read, Ändern mit dms.tag.manage bzw. dms.master.manage
        for spec in DMSMasterSpec.all {
            routes.on(.GET, PathComponent(stringLiteral: spec.segment), permission: "dms.document.read") { req in
                try await spec.list(tenant: try req.requireTenant().tenantID, on: try sql(req.db))
            }
            routes.on(.POST, PathComponent(stringLiteral: spec.segment), permission: spec.permission) { req in try await spec.create(req) }
            routes.on(.PATCH, PathComponent(stringLiteral: spec.segment), ":id", permission: spec.permission) { req in
                guard let id = req.parameters.get("id", as: UUID.self) else { throw DMSError.notFound }
                return try await spec.update(req, id: id)
            }
            routes.on(.DELETE, PathComponent(stringLiteral: spec.segment), ":id", permission: spec.permission) { req in
                guard let id = req.parameters.get("id", as: UUID.self) else { throw DMSError.notFound }
                return try await spec.delete(req, id: id)
            }
        }
    }
}

private func dmsDocumentID(_ req: Request) throws -> UUID {
    guard let id = req.parameters.get("document", as: UUID.self) else { throw DMSError.notFound }
    return id
}

private func dmsJSON(_ body: some Encodable, status: HTTPStatus = .ok) throws -> Response {
    var headers = HTTPHeaders()
    headers.contentType = .json
    return Response(status: status, headers: headers, body: .init(data: try JSONEncoder().encode(body)))
}
