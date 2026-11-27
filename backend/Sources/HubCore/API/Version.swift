import Vapor
import SQLKit

public enum HubVersion {
    public static let server = "0.1.0"
    public static let api = "1"
}

public struct VersionInfo: Content, Equatable {
    public let server: String
    public let api: String
    /// `schema_version.version` oder `null` ohne Datenbank/Schema.
    public let schema: Int?
}

/// `GET /api/version`. Dient dem Client-Abgleich (`X-Client-Api`, ARCHITEKTUR Abschnitt 5).
public func registerVersionRoute(_ app: Application) {
    app.get("api", "version") { req async throws -> VersionInfo in
        var schema: Int?
        if req.application.hubConfig != nil, let db = req.application.db(.psql) as? any SQLDatabase,
           let row = try? await db.raw("SELECT max(version) AS v FROM schema_version").first() {
            schema = try? row.decode(column: "v", as: Int?.self)
        }
        return VersionInfo(server: HubVersion.server, api: HubVersion.api, schema: schema)
    }
}
