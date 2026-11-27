import Vapor
import Fluent
import SQLKit
import HubCore

// WP-R6c: Platzhalter (rot), siehe Umsetzung.
struct CreateInvoiceRender: AsyncMigration {
    let name = "invoice_030_render"
    func prepare(on db: any Database) async throws {}
    func revert(on db: any Database) async throws {}
}
