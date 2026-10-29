import Vapor
import Fluent
import SQLKit

/// `migrate [--yes]`: wendet ausstehende Migrationen an; Exit-Code 0 bei Erfolg, 1 bei Fehler.
/// Ein Advisory Lock (Session-Lock auf eigener Verbindung) serialisiert parallele Läufe.
public struct MigrateCommand: AsyncCommand {
    public struct Signature: CommandSignature {
        @Flag(name: "yes", short: "y", help: "Ohne Nachfrage (Kompatibilität; es wird nie gefragt)")
        var yes: Bool
        public init() {}
    }
    public var help: String { "Wendet Datenbankmigrationen unter Advisory Lock an." }
    public init() {}

    static let lockKey: Int64 = 0x4C41_4248_5542  // "LABHUB"

    public func run(using context: CommandContext, signature: Signature) async throws {
        do {
            try await migrateWithLock(context.application)
            context.console.print("Migration abgeschlossen")
        } catch {
            context.console.error("Migration fehlgeschlagen: \(error)")
            exit(1)
        }
    }
}

public func migrateWithLock(_ app: Application) async throws {
    guard app.hubConfig != nil else { throw ConfigError(description: "Datenbank nicht konfiguriert (DB_HOST)") }
    try await (app.db(.psql) as! any SQLDatabase).withSession { lockConn in
        try await lockConn.raw("SELECT pg_advisory_lock(\(literal: MigrateCommand.lockKey))").run()
        do {
            try await app.autoMigrate()
            try await lockConn.raw("SELECT pg_advisory_unlock(\(literal: MigrateCommand.lockKey))").run()
        } catch {
            try? await lockConn.raw("SELECT pg_advisory_unlock(\(literal: MigrateCommand.lockKey))").run()
            throw error
        }
    }
}
