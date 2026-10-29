import Vapor
import Fluent
import FluentPostgresDriver
import NIOSSL
import SQLKit

extension DatabaseID { static var hub: DatabaseID { .psql } }

extension Application {
    private struct ConfigKey: StorageKey { typealias Value = HubConfig }
    public var hubConfig: HubConfig? {
        get { storage[ConfigKey.self] }
        set { storage[ConfigKey.self] = newValue }
    }
}

public func configureDatabase(_ app: Application, _ config: HubConfig) throws {
    let tls: PostgresConnection.Configuration.TLS
    switch config.dbTLS {
    case .disable: tls = .disable
    case .require: tls = .require(try NIOSSLContext(configuration: .makeClientConfiguration()))
    }
    var pg = SQLPostgresConfiguration(hostname: config.dbHost, port: config.dbPort, username: config.dbUser,
                                      password: config.dbPassword, database: config.dbName, tls: tls)
    pg.coreConfiguration.options.connectTimeout = .seconds(5)
    app.databases.use(.postgres(configuration: pg, connectionPoolTimeout: .seconds(5)), as: .psql)
    app.migrations.add(HubMigrations.all, to: .psql)
    app.hubConfig = config
}

public func sql(_ db: any Database) throws -> any SQLDatabase {
    guard let s = db as? any SQLDatabase else { throw Abort(.internalServerError, reason: "SQL nicht verfügbar") }
    return s
}

/// Bereit = Datenbank erreichbar und jede bekannte Migration angewendet.
/// Schreibt nie (legt auch `_fluent_migrations` nicht an).
public func schemaIsCurrent(_ app: Application) async -> Bool {
    do {
        let db = try sql(app.db(.psql))
        let rows = try await db.raw("SELECT name FROM _fluent_migrations").all()
        let applied = Set(try rows.map { try $0.decode(column: "name", as: String.self) })
        return HubMigrations.all.allSatisfy { applied.contains($0.name) }
    } catch {
        return false
    }
}
