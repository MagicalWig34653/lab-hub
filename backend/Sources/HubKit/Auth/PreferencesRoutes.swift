import Vapor
import Fluent
import SQLKit

/// WP-ST7: Akzentfarbe je Benutzer (Darstellung der PWA). Expand-only: neue, leere Spalte; alter Code ignoriert sie.
/// `schema_version` bleibt unverändert (wie 020/021).
struct CreateUserAccent: AsyncMigration {
    let name = "022_user_accent"
    func prepare(on db: any Database) async throws {
        try await run(db, ["ALTER TABLE users ADD COLUMN accent text CHECK (accent ~ '^#[0-9a-f]{6}$')"])
    }
    func revert(on db: any Database) async throws { try await run(db, ["ALTER TABLE users DROP COLUMN accent"]) }
}

/// `#rgb` oder `#rrggbb`, Ergebnis immer kleingeschriebenes `#rrggbb`; sonst nil.
func normalizedAccent(_ raw: String) -> String? {
    let hex = Set("0123456789abcdef")
    let s = raw.lowercased()
    guard s.first == "#", s.dropFirst().allSatisfy(hex.contains) else { return nil }
    let digits = Array(s.dropFirst())
    switch digits.count {
    case 6: return s
    case 3: return "#" + String(digits.flatMap { [$0, $0] })
    default: return nil
    }
}

/// `GET`/`PUT /api/v1/me/preferences` (nur normale Sitzung): Darstellungseinstellungen des eigenen Kontos.
func registerPreferenceRoutes(_ normal: any RoutesBuilder) {
    normal.get("me", "preferences") { req async throws -> Response in
        let c = try req.requireAuth()
        guard let sql = req.db as? any SQLDatabase else { throw Abort(.internalServerError) }
        let row = try await sql.raw("SELECT accent FROM users WHERE id = \(bind: c.user.id)").first()
        let accent: String? = try row?.decode(column: "accent", as: String?.self) ?? nil
        return try jsonResponse(["accent": accent.map { $0 as Any } ?? NSNull()])
    }
    normal.put("me", "preferences") { req async throws -> Response in
        let c = try req.requireAuth()
        guard let sql = req.db as? any SQLDatabase else { throw Abort(.internalServerError) }
        let invalid = HubError(.unprocessableEntity, "validation_failed", errors: [FieldError(field: "accent", code: "invalid")])
        guard let data = req.body.data.map({ Data(buffer: $0) }),
              let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let raw = body["accent"] else { throw invalid }
        let accent: String?
        if raw is NSNull { accent = nil } else if let s = raw as? String, let n = normalizedAccent(s) { accent = n } else { throw invalid }
        try await sql.raw("UPDATE users SET accent = \(bind: accent) WHERE id = \(bind: c.user.id)").run()
        return try jsonResponse(["accent": accent.map { $0 as Any } ?? NSNull()])
    }
}
