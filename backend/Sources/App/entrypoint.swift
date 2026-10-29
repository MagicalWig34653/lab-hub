import Vapor
import HubKit

@main
enum Entrypoint {
    static func main() async throws {
        let app = try await Application.make(.detect())
        defer { Task { try? await app.asyncShutdown() } }
        try configure(app)
        try await app.execute()
    }
}
