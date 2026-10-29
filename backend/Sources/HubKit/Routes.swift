import Vapor

/// Module registrieren ihre Routen über den Kern; der Kern kennt keine Fachlogik.
/// `/health`: Prozess lebt. `/ready`: Instanz darf Anfragen bekommen (später: Schema aktuell, Datenbank erreichbar).
public func routes(_ app: Application) throws {
    app.get("health") { _ in ["status": "ok"] }
    app.get("ready") { _ async throws -> HTTPStatus in
        guard await app.hubReadiness.isReady() else { throw Abort(.serviceUnavailable) }
        return .ok
    }
}

public struct Readiness: Sendable {
    var check: @Sendable () async -> Bool = { true }
    func isReady() async -> Bool { await check() }
    public init(check: @escaping @Sendable () async -> Bool = { true }) { self.check = check }
}

extension Application {
    private struct ReadinessKey: StorageKey { typealias Value = Readiness }
    public var hubReadiness: Readiness {
        get { storage[ReadinessKey.self] ?? Readiness() }
        set { storage[ReadinessKey.self] = newValue }
    }
}

public func configure(_ app: Application) throws {
    try routes(app)
}
