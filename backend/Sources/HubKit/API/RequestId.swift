import Vapor

extension Request {
    private struct RequestIdKey: StorageKey { typealias Value = String }
    /// Korrelations-ID der Anfrage (von `RequestIdMiddleware` gesetzt; sonst leerer String).
    public var requestId: String {
        get { storage[RequestIdKey.self] ?? "" }
        set { storage[RequestIdKey.self] = newValue }
    }
}

/// Setzt `X-Request-Id` in jeder Antwort (auch Fehlern). Eine gültige eingehende ID (max. 64 Zeichen `[A-Za-z0-9._-]`) wird übernommen.
public struct RequestIdMiddleware: AsyncMiddleware {
    public static let header = "X-Request-Id"
    public init() {}

    static func isValid(_ s: String) -> Bool {
        !s.isEmpty && s.count <= 64 && s.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "._-".contains($0)) }
    }

    public func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        let incoming = request.headers.first(name: Self.header)
        request.requestId = incoming.flatMap { Self.isValid($0) ? $0 : nil } ?? UUID().uuidString.lowercased()
        let response: Response
        do { response = try await next.respond(to: request) } catch {
            response = ProblemMiddleware.response(for: error, request: request)
        }
        response.headers.replaceOrAdd(name: Self.header, value: request.requestId)
        return response
    }
}
