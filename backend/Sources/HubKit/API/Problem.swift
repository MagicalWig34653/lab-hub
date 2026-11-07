import Vapor

/// Fachlicher Fehler mit stabilem Code (WP-K4, RFC 9457). Die deutsche Meldung kommt aus `ProblemCatalog`, `detail` ist optional.
public struct HubError: Error, Sendable {
    public let status: HTTPResponseStatus
    public let code: String
    public let detail: String?
    public let errors: [FieldError]
    public let headers: HTTPHeaders
    public init(_ status: HTTPResponseStatus, _ code: String, detail: String? = nil, errors: [FieldError] = [], headers: HTTPHeaders = [:]) {
        self.status = status; self.code = code; self.detail = detail; self.errors = errors; self.headers = headers
    }
}

public struct FieldError: Content, Equatable {
    public let field: String
    public let code: String
    public init(field: String, code: String) { self.field = field; self.code = code }
}

/// RFC 9457 Problem Details plus `code`, `request_id`, `errors`. Schema: `contracts/openapi.yaml` (`Problem`).
public struct ProblemDetails: Content, Equatable {
    public let type: String
    public let title: String
    public let status: Int
    public let code: String
    public let detail: String?
    public let request_id: String
    public let errors: [FieldError]?
}

/// Stabile Fehlercodes mit deutscher Meldung (Nutzertext). Unbekannte Codes fallen auf eine allgemeine Meldung zurück.
public enum ProblemCatalog {
    public static let typeBase = "https://hub.example.org/errors/"
    static let messages: [String: String] = [
        "bad_request": "Die Anfrage ist ungültig.",
        "unauthorized": "Anmeldung erforderlich.",
        "forbidden": "Dafür fehlt die Berechtigung.",
        "not_found": "Die angeforderte Ressource wurde nicht gefunden.",
        "method_not_allowed": "Diese Methode ist hier nicht erlaubt.",
        "conflict": "Die Anfrage steht im Konflikt mit dem aktuellen Stand.",
        "precondition_failed": "Das Objekt wurde zwischenzeitlich geändert.",
        "payload_too_large": "Die Anfrage ist zu groß.",
        "validation_failed": "Die Eingaben sind ungültig.",
        "invalid_cursor": "Der Seiten-Cursor ist ungültig.",
        "invalid_limit": "Der Wert für limit ist ungültig.",
        "idempotency_key_required": "Der Header Idempotency-Key ist erforderlich.",
        "idempotency_key_reused": "Der Idempotency-Key wurde bereits mit einer anderen Anfrage verwendet.",
        "idempotency_in_progress": "Eine Anfrage mit diesem Idempotency-Key wird noch verarbeitet.",
        "tenant_required": "Mandant fehlt oder ist ungültig.",
        "setup_token_invalid": "Das Einrichtungs-Token ist ungültig.",
        "invitation_invalid": "Die Einladung ist ungültig, abgelaufen oder bereits verwendet.",
        "passkey_invalid": "Der Passkey konnte nicht bestätigt werden.",
        "login_failed": "Die Anmeldung ist fehlgeschlagen.",
        "handle_taken": "Dieser Benutzername ist bereits vergeben.",
        "module_disabled": "Dieses Modul ist nicht aktiviert.",
        "module_requires": "Das Modul benötigt andere Module, die noch nicht aktiviert sind.",
        "module_required_by": "Das Modul wird von anderen aktivierten Modulen benötigt.",
        "module_unavailable": "Das Modul ist auf diesem Server nicht freigegeben.",
        "document_trashed": "Das Dokument liegt im Papierkorb.",
        "unsupported_media_type": "Dieser Dateityp wird nicht unterstützt.",
        "contact_merged": "Der Kontakt wurde bereits mit einem anderen zusammengeführt.",
        "last_owner": "Der letzte Owner eines Mandanten kann nicht herabgestuft oder entfernt werden.",
        "last_passkey": "Der letzte Passkey kann nicht entfernt werden.",
        "csrf_invalid": "Das CSRF-Token fehlt oder ist ungültig.",
        "recovery_session_restricted": "Diese Aktion ist in einer Notfall-Sitzung nicht erlaubt.",
        "too_many_requests": "Zu viele Anfragen. Bitte später erneut versuchen.",
        "service_unavailable": "Der Dienst ist vorübergehend nicht verfügbar.",
        "internal_error": "Interner Fehler. Bitte später erneut versuchen."
    ]
    public static func message(_ code: String) -> String { messages[code] ?? "Ein Fehler ist aufgetreten." }
    public static var codes: [String] { messages.keys.sorted() }

    static func code(for status: HTTPResponseStatus) -> String {
        switch status.code {
        case 400: "bad_request"
        case 401: "unauthorized"
        case 403: "forbidden"
        case 404: "not_found"
        case 405: "method_not_allowed"
        case 409: "conflict"
        case 412: "precondition_failed"
        case 413: "payload_too_large"
        case 415: "unsupported_media_type"
        case 422: "validation_failed"
        case 429: "too_many_requests"
        case 503: "service_unavailable"
        default: status.code >= 500 ? "internal_error" : "bad_request"
        }
    }
}

/// Wandelt jeden Fehler in `application/problem+json`. 5xx-Details werden nie nach außen gegeben (nur geloggt, ohne Nutzdaten).
public struct ProblemMiddleware: AsyncMiddleware {
    public init() {}

    public func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        do { return try await next.respond(to: request) } catch {
            return ProblemMiddleware.response(for: error, request: request)
        }
    }

    static func response(for error: any Error, request: Request) -> Response {
        let status: HTTPResponseStatus, code: String
        var detail: String?, fields: [FieldError] = []
        var headers = HTTPHeaders()
        switch error {
        case let e as HubError:
            status = e.status; code = e.code; detail = e.detail; fields = e.errors; headers = e.headers
        case let e as IdempotencyError:
            switch e {
            case .keyReusedWithDifferentRequest: status = .unprocessableEntity; code = "idempotency_key_reused"
            case .inProgress: status = .conflict; code = "idempotency_in_progress"
            }
        case let e as any AbortError:
            status = e.status; code = ProblemCatalog.code(for: e.status)
            headers = e.headers
        case is DecodingError:
            status = .unprocessableEntity; code = "validation_failed"
        default:
            status = .internalServerError; code = "internal_error"
        }
        if status.code >= 500 {
            request.logger.error("request failed", metadata: ["code": .string(code), "error": .string(String(describing: type(of: error)))])
        }
        let body = ProblemDetails(type: ProblemCatalog.typeBase + code, title: ProblemCatalog.message(code), status: Int(status.code),
                                  code: code, detail: status.code >= 500 ? nil : detail, request_id: request.requestId,
                                  errors: fields.isEmpty ? nil : fields)
        headers.remove(name: .contentLength)
        let response = Response(status: status, headers: headers)
        do { try response.content.encode(body, as: .json) } catch { response.body = .init(string: "{}") }
        response.headers.contentType = HTTPMediaType(type: "application", subType: "problem+json")
        return response
    }
}
