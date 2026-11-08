import Vapor
import Fluent
import SQLKit

// WP-D6: Routen des Paperless-Imports und die Notizen-Leseroute. Vertrag: contracts/openapi.yaml. Rechte `dms.import.read|manage` nur Buchhaltung und Owner
// (der Import legt Kontakte, Stammdaten und Dokumente an und löst bei der REST-Quelle Fremdzugriffe aus).

private func importID(_ req: Request) throws -> UUID {
    guard let id = req.parameters.get("import", as: UUID.self) else { throw DMSError.notFound }
    return id
}

private func importJSON(_ body: some Encodable, status: HTTPStatus = .ok) throws -> Response {
    var headers = HTTPHeaders()
    headers.contentType = .json
    return Response(status: status, headers: headers, body: .init(data: try JSONEncoder().encode(body)))
}

struct DMSNoteOut: Content, Sendable {
    let id: UUID
    let body: String
    let noted_at: String?
    let origin: String?
    let created_at: String
}

extension DMSModule {
    func registerImportRoutes(_ routes: ModuleRoutes, module: DMSModule) {
        let box = module.secretBox, policy = module.importPolicy
        routes.on(.POST, "imports", permission: "dms.import.manage") { req in
            guard let buffer = req.body.data, let object = StrictJSON.object(Data(buffer: buffer)) else { throw DMSError.invalid("body") }
            return try importJSON(try await DMSImport.enqueue(object, tenant: try req.requireTenant().tenantID, actor: try req.requireAuth().user.id, requestID: req.requestId,
                                                              box: box, policy: policy, on: req.db), status: .accepted)
        }
        routes.on(.GET, "imports", permission: "dms.import.read") { req in
            try importJSON(["items": try await DMSImport.list(tenant: try req.requireTenant().tenantID, on: try sql(req.db))])
        }
        routes.on(.GET, "imports", ":import", permission: "dms.import.read") { req in
            guard let out = try await DMSImport.load(try importID(req), tenant: try req.requireTenant().tenantID, on: try sql(req.db)) else { throw DMSError.notFound }
            return try importJSON(out)
        }
        // Bericht (JSON-Datei): erst nach Ende des Laufs vorhanden (404 davor)
        routes.on(.GET, "imports", ":import", "report", permission: "dms.import.read") { req in
            let id = try importID(req)
            guard let report = try await DMSImport.report(id, tenant: try req.requireTenant().tenantID, on: try sql(req.db)) else { throw DMSError.notFound }
            var headers = HTTPHeaders()
            headers.contentType = .json
            headers.replaceOrAdd(name: .contentDisposition, value: "attachment; filename=\"paperless-import-report-\(id.uuidString.lowercased().prefix(8)).json\"")
            headers.replaceOrAdd(name: .cacheControl, value: "no-store")
            headers.replaceOrAdd(name: "X-Content-Type-Options", value: "nosniff")
            return Response(status: .ok, headers: headers, body: .init(string: report))
        }
        routes.on(.POST, "imports", ":import", "cancel", permission: "dms.import.manage") { req in
            try importJSON(try await DMSImport.cancel(try importID(req), tenant: try req.requireTenant().tenantID, actor: try req.requireAuth().user.id, requestID: req.requestId, on: req.db))
        }
        // Notizen eines Dokuments (aus dem Import; es gibt noch keine Schreibroute)
        routes.on(.GET, "documents", ":document", "notes", permission: "dms.document.read") { req in
            let tenant = try req.requireTenant().tenantID
            guard let doc = req.parameters.get("document", as: UUID.self) else { throw DMSError.notFound }
            let s = try sql(req.db)
            guard try await s.raw("SELECT 1 AS x FROM dms_documents WHERE tenant_id = \(bind: tenant) AND id = \(bind: doc)").first() != nil else { throw DMSError.notFound }
            let items = try await s.raw("""
                SELECT id, body, noted_at, origin, created_at FROM dms_document_notes WHERE tenant_id = \(bind: tenant) AND document_id = \(bind: doc) ORDER BY noted_at NULLS LAST, created_at, id LIMIT 500
                """).all().map {
                DMSNoteOut(id: try $0.decode(column: "id", as: UUID.self), body: try $0.decode(column: "body", as: String.self), noted_at: try $0.decode(column: "noted_at", as: Date?.self).map(iso),
                           origin: try $0.decode(column: "origin", as: String?.self), created_at: iso(try $0.decode(column: "created_at", as: Date.self)))
            }
            return try importJSON(["items": items])
        }
    }
}
