import Vapor
import Fluent
import SQLKit

// WP-D3 Routen: Regeln (CRUD, Trockenlauf), Vorschläge (Liste, annehmen, ablehnen), Duplikate (Liste, entscheiden).
// Rechte: dms.rule.read|manage, dms.suggestion.read|decide; Duplikate über dms.document.read bzw. dms.document.update.

private func ruleJSON(_ body: some Encodable, status: HTTPStatus = .ok) throws -> Response {
    var headers = HTTPHeaders()
    headers.contentType = .json
    return Response(status: status, headers: headers, body: .init(data: try JSONEncoder().encode(body)))
}

/// Eingabefehler (auch unbekannte Schlüssel) sind 422 mit Feldhinweis, nicht 400.
private func decodeRule(_ req: Request) throws -> RuleInput {
    do { return try req.content.decode(RuleInput.self) }
    catch { throw DMSError.invalid("body", "invalid") }
}

private func uuidParam(_ req: Request, _ name: String) throws -> UUID {
    guard let id = req.parameters.get(name, as: UUID.self) else { throw DMSError.notFound }
    return id
}

private func optionalUUID(_ req: Request, _ name: String) throws -> UUID? {
    guard let raw: String = req.query[name] else { return nil }
    guard let id = UUID(uuidString: raw) else { throw DMSError.invalid(name) }
    return id
}

extension DMSModule {
    static let rulePermissions: [PermissionDefinition] = [
        PermissionDefinition("dms.rule.read", roles: [.accountant, .member]),
        PermissionDefinition("dms.rule.manage", roles: [.accountant]),
        PermissionDefinition("dms.suggestion.read", roles: [.accountant, .member, .taxAdvisor]),
        PermissionDefinition("dms.suggestion.decide", roles: [.accountant, .member])]

    func registerRuleRoutes(_ routes: ModuleRoutes) {
        // Regeln
        routes.on(.GET, "rules", permission: "dms.rule.read") { req in
            try ruleJSON(try await DMSRules.list(tenant: try req.requireTenant().tenantID, page: try HubPageRequest(req), on: req.db))
        }
        routes.on(.POST, "rules", permission: "dms.rule.manage") { req in
            let body = try decodeRule(req)
            return try ruleJSON(try await DMSRules.create(tenant: try req.requireTenant().tenantID, actor: try req.requireAuth().user.id, requestID: req.requestId, body: body, on: req.db),
                                status: .created)
        }
        // Trockenlauf eines Entwurfs (nichts wird gespeichert)
        routes.on(.POST, "rules", "preview", permission: "dms.rule.manage") { req in
            let body = try decodeRule(req)
            return try ruleJSON(try await DMSRules.preview(rule: nil, draft: body, limit: body.limit, tenant: try req.requireTenant().tenantID, on: req.db))
        }
        routes.on(.GET, "rules", ":rule", permission: "dms.rule.read") { req in
            guard let rule = try await DMSRules.load(try uuidParam(req, "rule"), tenant: try req.requireTenant().tenantID, on: try sql(req.db)) else { throw DMSError.notFound }
            return try ruleJSON(rule)
        }
        routes.on(.PATCH, "rules", ":rule", permission: "dms.rule.manage") { req in
            let body = try decodeRule(req)
            return try ruleJSON(try await DMSRules.update(try uuidParam(req, "rule"), tenant: try req.requireTenant().tenantID, actor: try req.requireAuth().user.id,
                                                          requestID: req.requestId, body: body, on: req.db))
        }
        routes.on(.DELETE, "rules", ":rule", permission: "dms.rule.manage") { req in
            try await DMSRules.delete(try uuidParam(req, "rule"), tenant: try req.requireTenant().tenantID, actor: try req.requireAuth().user.id, requestID: req.requestId, on: req.db)
            return Response(status: .noContent)
        }
        routes.on(.POST, "rules", ":rule", "preview", permission: "dms.rule.manage") { req in
            let limit = (try? decodeRule(req))?.limit
            return try ruleJSON(try await DMSRules.preview(rule: try uuidParam(req, "rule"), draft: nil, limit: limit, tenant: try req.requireTenant().tenantID, on: req.db))
        }

        // Vorschläge
        routes.on(.GET, "suggestions", permission: "dms.suggestion.read") { req in
            var filter = DMSSuggestions.Filter()
            if let state: String = req.query["state"] {
                guard state == "all" || ["open", "accepted", "rejected"].contains(state) else { throw DMSError.invalid("state") }
                filter.state = state == "all" ? nil : state
            }
            if let kind: String = req.query["kind"] {
                guard DMSSuggestions.kinds.contains(kind) else { throw DMSError.invalid("kind") }
                filter.kind = kind
            }
            filter.document = try optionalUUID(req, "document_id")
            filter.rule = try optionalUUID(req, "rule_id")
            return try ruleJSON(try await DMSSuggestions.list(tenant: try req.requireTenant().tenantID, page: try HubPageRequest(req), filter: filter, on: req.db))
        }
        routes.on(.GET, "documents", ":document", "suggestions", permission: "dms.suggestion.read") { req in
            let tenant = try req.requireTenant().tenantID, document = try uuidParam(req, "document")
            guard try await sql(req.db).raw("SELECT 1 AS x FROM dms_documents WHERE tenant_id = \(bind: tenant) AND id = \(bind: document)").first() != nil else { throw DMSError.notFound }
            var filter = DMSSuggestions.Filter()
            filter.document = document
            if let state: String = req.query["state"] {
                guard state == "all" || ["open", "accepted", "rejected"].contains(state) else { throw DMSError.invalid("state") }
                filter.state = state == "all" ? nil : state
            }
            return try ruleJSON(try await DMSSuggestions.list(tenant: tenant, page: try HubPageRequest(req), filter: filter, on: req.db))
        }
        routes.on(.POST, "suggestions", ":suggestion", "accept", permission: "dms.suggestion.decide") { req in
            try ruleJSON(try await DMSSuggestions.accept(try uuidParam(req, "suggestion"), tenant: try req.requireTenant().tenantID, actor: try req.requireAuth().user.id,
                                                         requestID: req.requestId, on: req.db))
        }
        routes.on(.POST, "suggestions", ":suggestion", "reject", permission: "dms.suggestion.decide") { req in
            try ruleJSON(try await DMSSuggestions.reject(try uuidParam(req, "suggestion"), tenant: try req.requireTenant().tenantID, actor: try req.requireAuth().user.id,
                                                         requestID: req.requestId, on: req.db))
        }

        // Duplikate
        routes.on(.GET, "duplicates", permission: "dms.document.read") { req in
            var state: String? = "open"
            if let raw: String = req.query["state"] {
                guard raw == "all" || ["open", "confirmed", "dismissed"].contains(raw) else { throw DMSError.invalid("state") }
                state = raw == "all" ? nil : raw
            }
            var method: String?
            if let raw: String = req.query["method"] {
                guard ["sha256", "text_hash", "similarity"].contains(raw) else { throw DMSError.invalid("method") }
                method = raw
            }
            return try ruleJSON(try await DMSDuplicates.list(tenant: try req.requireTenant().tenantID, page: try HubPageRequest(req), state: state,
                                                             document: try optionalUUID(req, "document_id"), method: method, on: req.db))
        }
        routes.on(.POST, "duplicates", ":duplicate", "resolve", permission: "dms.document.update") { req in
            struct Body: Content { var state: String? }
            let body = try req.content.decode(Body.self)
            return try ruleJSON(try await DMSDuplicates.resolve(try uuidParam(req, "duplicate"), to: body.state ?? "", tenant: try req.requireTenant().tenantID,
                                                                actor: try req.requireAuth().user.id, requestID: req.requestId, on: req.db))
        }
    }
}
