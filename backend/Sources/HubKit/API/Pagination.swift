import Vapor
import Foundation

/// Cursor-Pagination (WP-K4): `?limit=50&cursor=<opaque>`, Sortierung `(created_at, id)` aufsteigend.
/// Der Cursor ist base64url(JSON) der letzten Zeile; Aufrufer nutzen Keyset-Bedingung `(created_at, id) > (cursor.createdAt, cursor.id)`.
public struct PageCursor: Codable, Equatable, Sendable {
    /// `created_at` als Text mit voller Datenbank-Genauigkeit (`created_at::text`), wird mit `::timestamptz` zurückgebunden.
    public let createdAt: String
    public let id: UUID
    public init(createdAt: String, id: UUID) { self.createdAt = createdAt; self.id = id }

    public func encoded() -> String {
        let data = (try? JSONEncoder().encode(self)) ?? Data()
        return data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    public static func decode(_ s: String) throws -> PageCursor {
        var b = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b.count % 4 != 0 { b += "=" }
        guard let data = Data(base64Encoded: b), let c = try? JSONDecoder().decode(PageCursor.self, from: data)
        else { throw HubError(.badRequest, "invalid_cursor") }
        return c
    }
}

public struct HubPageRequest: Sendable {
    public static let defaultLimit = 50, maxLimit = 200
    public let limit: Int
    public let cursor: PageCursor?
    public let wantsCount: Bool
    public init(limit: Int = HubPageRequest.defaultLimit, cursor: PageCursor? = nil, wantsCount: Bool = false) {
        self.limit = limit; self.cursor = cursor; self.wantsCount = wantsCount
    }

    /// Liest `limit` (1...200, Standard 50), `cursor`, `count`. Ungültige Werte: 400 `invalid_limit` bzw. `invalid_cursor`.
    public init(_ req: Request) throws {
        var limit = Self.defaultLimit
        if let raw: String = req.query["limit"] {
            guard let l = Int(raw), (1...Self.maxLimit).contains(l) else { throw HubError(.badRequest, "invalid_limit") }
            limit = l
        }
        self.limit = limit
        if let raw: String = req.query["cursor"] { cursor = try PageCursor.decode(raw) } else { cursor = nil }
        wantsCount = (req.query["count"] as String?) == "true"
    }
}

public struct HubPage<Item: Content>: Content {
    public let items: [Item]
    public let next_cursor: String?
    public let total: Int?
    /// `fetched` sind die mit `limit + 1` geladenen Zeilen; die Überzahl wird verworfen und liefert den Folge-Cursor.
    public init(fetched: [Item], limit: Int, cursorOf: (Item) -> PageCursor, total: Int? = nil) {
        let hasMore = fetched.count > limit
        let items = Array(fetched.prefix(limit))
        self.items = items
        self.next_cursor = hasMore ? items.last.map { cursorOf($0).encoded() } : nil
        self.total = total
    }
}
