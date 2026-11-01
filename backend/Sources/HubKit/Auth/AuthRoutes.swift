import Vapor
import Foundation

// Routen der Anmeldung (WP-K1). Vertrag: contracts/openapi.yaml. Fehler: Problem Details (WP-K4).
// Zugriff: öffentliche Routen sind rate-limitiert (DB); alle anderen verlangen eine Sitzung (Default-Deny für Notfall-Sitzungen).

private struct BootstrapOptionsBody: Content { let setup_token: String; let handle: String; let display_name: String }
private struct RegisterOptionsBody: Content { let invite_token: String; let handle: String; let display_name: String }
private struct RecoveryLoginBody: Content { let handle: String; let code: String }
private struct InvitationBody: Content { let expires_in_hours: Int? }

private struct VerifyBody {
    let challengeID: UUID
    let credential: Data
    let name: String?
}

private func parseVerify(_ req: Request) throws -> VerifyBody {
    guard let buffer = req.body.data, let object = try? JSONSerialization.jsonObject(with: Data(buffer: buffer)) as? [String: Any],
          let challengeID = (object["challenge_id"] as? String).flatMap(UUID.init(uuidString:)),
          let credential = object["credential"] as? [String: Any], let data = try? JSONSerialization.data(withJSONObject: credential)
    else { throw HubError(.unprocessableEntity, "validation_failed", errors: [FieldError(field: "credential", code: "invalid")]) }
    return VerifyBody(challengeID: challengeID, credential: data, name: object["name"] as? String)
}

private func jsonResponse(_ object: Any, status: HTTPStatus = .ok) throws -> Response {
    var headers = HTTPHeaders()
    headers.contentType = .json
    return Response(status: status, headers: headers, body: .init(data: try JSONSerialization.data(withJSONObject: object)))
}

private func iso(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }

private func optionsResponse(_ o: AuthService.Options) throws -> Response {
    try jsonResponse(["challenge_id": o.challengeID.uuidString, "public_key": try JSONSerialization.jsonObject(with: o.options.publicKey)])
}

/// Sitzungsantwort. Bei neu ausgestellter Sitzung: Cookie (HttpOnly, SameSite=Lax) oder, mit `X-Auth-Transport: bearer`, Token im Body (Apps).
private func sessionResponse(_ c: AuthContext, req: Request, issued: Bool, status: HTTPStatus = .ok) throws -> Response {
    let settings = try req.application.authService().settings
    var body: [String: Any] = [
        "user": ["id": c.user.id.uuidString, "handle": c.user.handle, "display_name": c.user.displayName, "is_admin": c.user.isAdmin],
        "kind": c.kind.rawValue, "expires_at": iso(c.expiresAt), "csrf_token": AuthSecrets.csrf(c.token)]
    let bearer = req.headers.first(name: "X-Auth-Transport") == "bearer"
    if issued, bearer { body["token"] = c.token }
    let response = try jsonResponse(body, status: status)
    if issued, !bearer {
        response.cookies[sessionCookieName] = .init(string: c.token, expires: c.expiresAt, path: "/", isSecure: settings.secureCookies, isHTTPOnly: true, sameSite: .lax)
    }
    return response
}

private func clearedSessionCookie(_ response: Response, _ req: Request) throws {
    let settings = try req.application.authService().settings
    response.cookies[sessionCookieName] = .init(string: "", expires: Date(timeIntervalSince1970: 0), path: "/", isSecure: settings.secureCookies, isHTTPOnly: true, sameSite: .lax)
}

func registerAuthRoutes(_ app: Application) {
    let api = app.grouped("api", "v1").grouped(SessionMiddleware())

    // Öffentlich, rate-limitiert
    let open = api.grouped("auth").grouped(AuthRateLimitMiddleware())
    open.post("bootstrap", "options") { req async throws -> Response in
        let b = try req.content.decode(BootstrapOptionsBody.self)
        return try optionsResponse(try await req.application.authService().beginBootstrap(setupToken: b.setup_token, handle: b.handle, displayName: b.display_name, on: req.db))
    }
    open.post("bootstrap", "verify") { req async throws -> Response in
        let v = try parseVerify(req)
        return try sessionResponse(try await req.application.authService().finishBootstrap(challengeID: v.challengeID, credential: v.credential, requestID: req.requestId, on: req.db),
                                   req: req, issued: true, status: .created)
    }
    open.post("register", "options") { req async throws -> Response in
        let b = try req.content.decode(RegisterOptionsBody.self)
        return try optionsResponse(try await req.application.authService().beginRegistration(inviteToken: b.invite_token, handle: b.handle, displayName: b.display_name, on: req.db))
    }
    open.post("register", "verify") { req async throws -> Response in
        let v = try parseVerify(req)
        return try sessionResponse(try await req.application.authService().finishRegistration(challengeID: v.challengeID, credential: v.credential, requestID: req.requestId, on: req.db),
                                   req: req, issued: true, status: .created)
    }
    open.post("login", "options") { req async throws -> Response in
        try optionsResponse(try await req.application.authService().beginLogin(on: req.db))
    }
    open.post("login", "verify") { req async throws -> Response in
        let v = try parseVerify(req)
        return try sessionResponse(try await req.application.authService().finishLogin(challengeID: v.challengeID, credential: v.credential, requestID: req.requestId, on: req.db),
                                   req: req, issued: true)
    }
    open.post("recovery", "login") { req async throws -> Response in
        let b = try req.content.decode(RecoveryLoginBody.self)
        return try sessionResponse(try await req.application.authService().recoveryLogin(handle: b.handle, code: b.code, requestID: req.requestId, on: req.db),
                                   req: req, issued: true)
    }

    // Jede gültige Sitzung (auch Notfall-Sitzung)
    let anySession = api.grouped(RequireSession(allowRecovery: true))
    anySession.get("auth", "session") { req async throws -> Response in
        try sessionResponse(try req.requireAuth(), req: req, issued: false)
    }
    anySession.post("auth", "logout") { req async throws -> Response in
        try await req.application.authService().logout(try req.requireAuth(), requestID: req.requestId, on: req.db)
        let response = Response(status: .noContent)
        try clearedSessionCookie(response, req)
        return response
    }
    anySession.post("auth", "logout-all") { req async throws -> Response in
        let count = try await req.application.authService().logoutAll(try req.requireAuth(), requestID: req.requestId, on: req.db)
        let response = try jsonResponse(["revoked": count])
        try clearedSessionCookie(response, req)
        return response
    }
    anySession.post("me", "passkeys", "options") { req async throws -> Response in
        try optionsResponse(try await req.application.authService().beginAddPasskey(try req.requireAuth(), on: req.db))
    }
    anySession.post("me", "passkeys", "verify") { req async throws -> Response in
        let v = try parseVerify(req)
        let p = try await req.application.authService().finishAddPasskey(try req.requireAuth(), challengeID: v.challengeID, credential: v.credential,
                                                                         name: v.name, requestID: req.requestId, on: req.db)
        return try jsonResponse(passkeyJSON(p), status: .created)
    }

    // Nur normale Sitzungen
    let normal = api.grouped(RequireSession())
    normal.get("auth", "sessions") { req async throws -> Response in
        let list = try await req.application.authService().sessions(try req.requireAuth(), on: req.db)
        return try jsonResponse(["items": list.map { ["id": $0.id.uuidString, "kind": $0.kind, "created_at": iso($0.createdAt),
                                                       "last_seen_at": iso($0.lastSeenAt), "expires_at": iso($0.expiresAt), "current": $0.current] as [String: Any] }])
    }
    normal.delete("auth", "sessions", ":id") { req async throws -> HTTPStatus in
        guard let id = req.parameters.get("id", as: UUID.self) else { throw HubError(.notFound, "not_found") }
        try await req.application.authService().revokeSession(id, try req.requireAuth(), requestID: req.requestId, on: req.db)
        return .noContent
    }
    normal.get("me", "passkeys") { req async throws -> Response in
        let list = try await req.application.authService().passkeyList(try req.requireAuth(), on: req.db)
        return try jsonResponse(["items": list.map(passkeyJSON)])
    }
    normal.delete("me", "passkeys", ":id") { req async throws -> HTTPStatus in
        guard let id = req.parameters.get("id", as: UUID.self) else { throw HubError(.notFound, "not_found") }
        try await req.application.authService().revokePasskey(id, try req.requireAuth(), requestID: req.requestId, on: req.db)
        return .noContent
    }
    normal.get("me", "recovery-codes") { req async throws -> Response in
        try jsonResponse(["remaining": try await req.application.authService().recoveryCodesRemaining(try req.requireAuth(), on: req.db)])
    }
    normal.post("me", "recovery-codes") { req async throws -> Response in
        let codes = try await req.application.authService().generateRecoveryCodes(try req.requireAuth(), requestID: req.requestId, on: req.db)
        return try jsonResponse(["codes": codes], status: .created)
    }

    // Nur Administratoren (Übergang bis zu den Rollen aus WP-K2)
    let admin = api.grouped(RequireSession(admin: true))
    admin.post("invitations") { req async throws -> Response in
        let hours = (try? req.content.decode(InvitationBody.self))?.expires_in_hours
        if let hours, !(1...720).contains(hours) {
            throw HubError(.unprocessableEntity, "validation_failed", errors: [FieldError(field: "expires_in_hours", code: "invalid")])
        }
        let service = try req.application.authService()
        let inv = try await service.createInvitation(by: try req.requireAuth(), ttlSeconds: hours.map { $0 * 3600 }, requestID: req.requestId, on: req.db)
        var body: [String: Any] = ["id": inv.id.uuidString, "token": inv.token, "expires_at": iso(inv.expiresAt)]
        if !service.settings.origin.isEmpty { body["link"] = "\(service.settings.origin)/invite/\(inv.token)" }
        return try jsonResponse(body, status: .created)
    }
}

private func passkeyJSON(_ p: AuthService.PasskeyInfo) -> [String: Any] {
    var o: [String: Any] = ["id": p.id.uuidString, "name": p.name, "created_at": iso(p.createdAt), "backed_up": p.backedUp]
    o["last_used_at"] = p.lastUsedAt.map(iso) ?? NSNull()
    return o
}
