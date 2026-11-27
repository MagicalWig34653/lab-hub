import Vapor
import SQLKit
import HubCore

// WP-R6c: Platzhalter, damit die Tests übersetzen und rot laufen (werden durch die Umsetzung ersetzt).

protocol InvoiceRendering: Sendable {
    var layoutKey: String { get }
    var layoutVersion: Int { get }
    func rendererVersion() async throws -> String
    func render(_ documentJSON: Data) async throws -> Data
}

enum InvoiceRenderJob {
    static let kind = "invoice.render"
    static func enqueue(document: UUID, tenant: UUID, on s: any SQLDatabase) async throws -> UUID { throw HubError(.notImplemented, "not_implemented") }
    static func handler(renderer: any InvoiceRendering, storeFactory: @escaping @Sendable (any SQLDatabase) throws -> any ObjectStore) -> JobHandler {
        { _, _ in throw PermanentJobError(code: "not_implemented") }
    }
}
