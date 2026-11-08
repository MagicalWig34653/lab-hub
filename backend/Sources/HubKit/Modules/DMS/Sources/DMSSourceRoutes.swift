import Vapor
import Fluent
import SQLKit

// WP-D4: Routen der Quellen-Verwaltung und der Share-/Scan-API. Vertrag: contracts/openapi.yaml.

private func jsonBody(_ req: Request) throws -> [String: Any] {
    guard let buffer = req.body.data, let object = StrictJSON.object(Data(buffer: buffer)) else { throw DMSError.invalid("body") }
    return object
}

private func sourceID(_ req: Request) throws -> UUID {
    guard let id = req.parameters.get("source", as: UUID.self) else { throw DMSError.notFound }
    return id
}

private func json(_ body: some Encodable, status: HTTPStatus = .ok) throws -> Response {
    var headers = HTTPHeaders()
    headers.contentType = .json
    return Response(status: status, headers: headers, body: .init(data: try JSONEncoder().encode(body)))
}

extension DMSModule {
    func registerSourceRoutes(_ routes: ModuleRoutes, module: DMSModule) {
        let box = module.secretBox
        routes.on(.GET, "sources", permission: "dms.source.read") { req in
            try json(["items": try await DMSSources.list(tenant: try req.requireTenant().tenantID, on: try sql(req.db))])
        }
        routes.on(.POST, "sources", permission: "dms.source.manage") { req in
            try json(try await DMSSources.create(try jsonBody(req), tenant: try req.requireTenant().tenantID, actor: try req.requireAuth().user.id, requestID: req.requestId, box: box, on: req.db), status: .created)
        }
        routes.on(.GET, "sources", ":source", permission: "dms.source.read") { req in
            guard let out = try await DMSSources.load(try sourceID(req), tenant: try req.requireTenant().tenantID, on: try sql(req.db)) else { throw DMSError.notFound }
            return try json(out)
        }
        routes.on(.PATCH, "sources", ":source", permission: "dms.source.manage") { req in
            try json(try await DMSSources.update(try sourceID(req), body: try jsonBody(req), tenant: try req.requireTenant().tenantID, actor: try req.requireAuth().user.id,
                                                 requestID: req.requestId, box: box, on: req.db))
        }
        routes.on(.DELETE, "sources", ":source", permission: "dms.source.manage") { req in
            try await DMSSources.delete(try sourceID(req), tenant: try req.requireTenant().tenantID, actor: try req.requireAuth().user.id, requestID: req.requestId, on: req.db)
            return Response(status: .noContent)
        }
        routes.on(.POST, "sources", ":source", "run", permission: "dms.source.manage") { req in
            try json(try await DMSSources.runNow(try sourceID(req), tenant: try req.requireTenant().tenantID, actor: try req.requireAuth().user.id, requestID: req.requestId, on: req.db), status: .accepted)
        }
        // Verbindungstest (nur Mail): Anmeldung und Postfach, keine Verarbeitung. Antwort nur mit Fehlercode, nie mit Servertext.
        routes.on(.POST, "sources", ":source", "test", permission: "dms.source.manage") { req in
            let tenant = try req.requireTenant().tenantID
            let s = try sql(req.db)
            guard let source = try await DMSSources.row(try sourceID(req), tenant: tenant, on: s) else { throw DMSError.notFound }
            guard source.kind == .mail else { throw HubError(.conflict, "conflict", detail: "test_not_supported") }
            let config = try source.decode(MailSourceConfig.self)
            var imap = IMAPOptions.fromEnvironment()
            imap.sessionTimeout = .seconds(30)
            var result: [String: DMSFieldValue] = [:]
            do {
                guard let box else { throw IMAPError(code: "secret_key_missing") }
                guard let sealed = source.secretEnc else { throw IMAPError(code: "secret_missing") }
                let password: String
                do { password = try box.open(sealed, tenant: tenant, source: source.id) } catch { throw IMAPError(code: "secret_unreadable") }
                let unseen: Int = try await IMAPClient.withSession(host: config.host, port: config.port, user: config.username, password: password, options: imap) { session in
                    try await session.select(config.mailbox)
                    return try await session.searchUnseen(from: config.sender_contains, subject: config.subject_contains).count
                }
                result = ["ok": .bool(true), "unseen": .int(Int64(unseen))]
            } catch let e as IMAPError {
                result = ["ok": .bool(false), "error": .string(e.code)]
            } catch {
                result = ["ok": .bool(false), "error": .string("test_failed")]
            }
            try await AuditLog.record(AuditEvent(action: "dms.source.tested", actor: try req.requireAuth().user.id, tenant: tenant, subjectType: "dms.source", subjectID: source.id.uuidString,
                                                 meta: ["ok": .number(result["ok"] == .bool(true) ? 1 : 0)], requestID: req.requestId), on: s)
            return try json(result)
        }

        // Share-/Scan-API: wie der Upload, aber mit persönlichem API-Token (Scope dms.upload) statt Sitzung; Idempotency-Key optional.
        routes.onToken(.POST, "share", scope: "dms.upload", permission: "dms.document.create", body: .stream) { req in
            guard let tokenID = req.storage[ApiTokenIDKey.self] else { throw HubError(.unauthorized, "unauthorized") }
            return try await DMSUpload.handle(req, module: module, shareToken: tokenID)
        }
    }
}
