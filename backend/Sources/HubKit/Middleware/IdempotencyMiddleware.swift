import Vapor
import SQLKit
import Crypto

/// Erzwingt `Idempotency-Key` auf der Gruppe (z. B. finalisierende POSTs) und delegiert an `IdempotencyService`.
/// Gleicher Key + gleicher Request-Hash (Methode, Pfad, Body) = gespeicherte Antwort; anderer Hash = 422 `idempotency_key_reused`.
/// Antworten >= 500 werden nicht gespeichert; Fehler geben den Key wieder frei (Verhalten des Service).
public struct IdempotencyMiddleware: AsyncMiddleware {
    public static let header = "Idempotency-Key"
    let tenant: @Sendable (Request) throws -> UUID

    /// Standard: Mandant aus dem Pfadparameter `:tenant` (ARCHITEKTUR Abschnitt 5, Pfad-Variante).
    public init(tenant: @escaping @Sendable (Request) throws -> UUID = IdempotencyMiddleware.tenantFromPath) { self.tenant = tenant }

    public static let tenantFromPath: @Sendable (Request) throws -> UUID = { req in
        guard let t = req.parameters.get("tenant", as: UUID.self) else { throw HubError(.badRequest, "tenant_required") }
        return t
    }

    public func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        guard let key = request.headers.first(name: Self.header), !key.isEmpty, key.count <= 255 else {
            throw HubError(.badRequest, "idempotency_key_required")
        }
        let tenantId = try tenant(request)
        guard let db = request.application.db(.psql) as? any SQLDatabase else { throw HubError(.serviceUnavailable, "service_unavailable") }
        var hasher = SHA256()
        hasher.update(data: Data("\(request.method.rawValue) \(request.url.path)\n".utf8))
        if let body = request.body.data { hasher.update(data: Data(buffer: body)) }
        let hash = hasher.finalize().map { String(format: "%02x", $0) }.joined()

        let stored = try await IdempotencyService(db).execute(tenant: tenantId, key: key, requestHash: hash) {
            let response = try await next.respond(to: request)
            if response.status.code >= 500 { throw Abort(response.status) }
            return StoredResponse(status: Int(response.status.code), body: response.body.string ?? "")
        }
        let response = Response(status: HTTPResponseStatus(statusCode: stored.status), body: .init(string: stored.body))
        response.headers.contentType = .json
        return response
    }
}
