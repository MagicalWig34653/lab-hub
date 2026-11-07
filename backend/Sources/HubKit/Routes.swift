import Vapor
import Foundation

/// Module registrieren ihre Routen über den Kern; der Kern kennt keine Fachlogik.
/// `/health`: Prozess lebt. `/ready`: Instanz darf Anfragen bekommen (später: Schema aktuell, Datenbank erreichbar).
public func routes(_ app: Application) throws {
    app.get("health") { _ in ["status": "ok"] }
    app.get("ready") { _ async throws -> HTTPStatus in
        guard await app.hubReadiness.isReady() else { throw Abort(.serviceUnavailable) }
        return .ok
    }
    registerVersionRoute(app)
    registerAuthRoutes(app)
    registerTenancyRoutes(app)
    try registerModuleRoutes(app)
    registerContactRoutes(app)
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

/// Liest die Konfiguration aus der Umgebung. Ohne `DB_HOST` läuft nur im Entwicklungs-/Testmodus ohne Datenbank.
public func configure(_ app: Application, environment: [String: String] = ProcessInfo.processInfo.environment,
                      modules: [any HubModule] = InstalledModules.all) throws {
    app.hubModules = try ModuleRegistry(modules)
    if let config = try HubConfig.fromEnvironment(environment) {
        try configureDatabase(app, config)
        app.hubReadiness = Readiness(check: { [unowned app] in await schemaIsCurrent(app) })
        app.authSettings = AuthSettings.from(config)
    } else if app.environment == .production {
        throw ConfigError(description: "DB_HOST fehlt")
    }
    app.asyncCommands.use(MigrateCommand(), as: "migrate")
    app.asyncCommands.use(WorkerCommand(), as: "worker")  // WP-O1
    // WP-K4: X-Request-Id außen, Problem-Details-Fehler statt Vapors Standard-ErrorMiddleware
    ContentConfiguration.global.use(decoder: JSONDecoder(), for: HTTPMediaType(type: "application", subType: "problem+json"))
    app.middleware = Middlewares()
    app.middleware.use(RequestIdMiddleware())
    app.middleware.use(ProblemMiddleware())
    try routes(app)
}
