import Vapor
import HubKit

@main
enum Entrypoint {
    static func main() async throws {
        let app = try await Application.make(.detect())
        do {
            try configure(app)
            let isMigrate = CommandLine.arguments.dropFirst().first == "migrate"
            if app.hubConfig?.autoMigrate == true && !isMigrate { try await migrateWithLock(app) }
            try await app.execute()
        } catch {
            try? await app.asyncShutdown()
            app.logger.error("Start fehlgeschlagen: \(error)")
            exit(1)
        }
        try await app.asyncShutdown()
    }
}
