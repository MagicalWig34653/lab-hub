import Vapor
import SQLKit
import HubCore

// WP-BR1: Routen unter /api/v1/tenants/{tenant}/dms/scan. Vertrag: contracts/openapi.yaml, Entwurf: docs/SCAN-BRIDGE.md Abschnitt 3.
// Bridge (API-Token mit Scope `dms.scan.bridge`, Recht `dms.source.manage` der Rolle des Token-Inhabers): PUT bridge, POST bridge/claim, PUT bridge/jobs/{job}.
// Nutzer (Sitzung, Recht `dms.scan.use`): GET devices, POST jobs, GET jobs/{job}, POST jobs/{job}/next-page|finish|cancel.

private func scanJSON(_ body: some Encodable, status: HTTPStatus = .ok) throws -> Response {
    var headers = HTTPHeaders()
    headers.contentType = .json
    return Response(status: status, headers: headers, body: .init(data: try JSONEncoder().encode(body)))
}

private func jobID(_ req: Request) throws -> UUID {
    guard let id = req.parameters.get("job", as: UUID.self) else { throw DMSError.notFound }
    return id
}

private func bridgeToken(_ req: Request) throws -> UUID {
    guard let id = req.storage[ApiTokenIDKey.self] else { throw HubError(.unauthorized, "unauthorized") }
    return id
}

extension DMSModule {
    func registerScanRoutes(_ routes: ModuleRoutes) {
        // Bridge
        routes.onToken(.PUT, "scan", "bridge", scope: "dms.scan.bridge", permission: "dms.source.manage") { req in
            let reg = try ScanRegistration.parse(try ScanInput.object(req))
            return try scanJSON(try await DMSScanBridge.register(reg, token: try bridgeToken(req), tenant: try req.requireTenant().tenantID, actor: try req.requireAuth().user.id,
                                                                requestID: req.requestId, db: req.db))
        }
        routes.onToken(.POST, "scan", "bridge", "claim", scope: "dms.scan.bridge", permission: "dms.source.manage") { req in
            guard let claimed = try await DMSScanBridge.claim(token: try bridgeToken(req), tenant: try req.requireTenant().tenantID, db: req.db) else { return Response(status: .noContent) }
            return try scanJSON(claimed)
        }
        routes.onToken(.PUT, "scan", "bridge", "jobs", ":job", scope: "dms.scan.bridge", permission: "dms.source.manage") { req in
            let input = try ScanReport.parse(try ScanInput.object(req, allowEmpty: true))
            return try scanJSON(try await DMSScanBridge.report(input, job: try jobID(req), token: try bridgeToken(req), tenant: try req.requireTenant().tenantID,
                                                              actor: try req.requireAuth().user.id, requestID: req.requestId, db: req.db))
        }

        // Nutzer
        routes.on(.GET, "scan", "devices", permission: "dms.scan.use") { req in
            try scanJSON(["items": try await DMSScanJobs.devices(tenant: try req.requireTenant().tenantID, db: req.db)])
        }
        routes.on(.POST, "scan", "jobs", permission: "dms.scan.use") { req in
            let input = try ScanCreate.parse(try ScanInput.object(req))
            return try scanJSON(try await DMSScanJobs.create(input, tenant: try req.requireTenant().tenantID, actor: try req.requireAuth().user.id, requestID: req.requestId, db: req.db), status: .created)
        }
        routes.on(.GET, "scan", "jobs", ":job", permission: "dms.scan.use") { req in
            try scanJSON(try await DMSScanJobs.get(try jobID(req), tenant: try req.requireTenant().tenantID, db: req.db))
        }
        for (segment, command) in [("next-page", "next_page"), ("finish", "finish"), ("cancel", "cancel")] {
            routes.on(.POST, "scan", "jobs", ":job", PathComponent(stringLiteral: segment), permission: "dms.scan.use") { req in
                try scanJSON(try await DMSScanJobs.command(command, job: try jobID(req), tenant: try req.requireTenant().tenantID, actor: try req.requireAuth().user.id,
                                                          requestID: req.requestId, db: req.db))
            }
        }
    }
}
