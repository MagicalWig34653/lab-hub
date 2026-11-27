import Foundation
// Red-Stub (WP-R6b), wird durch die Umsetzung ersetzt.
struct InvoiceRenderAttachment: Sendable { let xml: Data }
enum InvoiceRenderError: Error, Equatable { case notFinal, invalidDocument(String), toolMissing(String), timeout, failed(tool: String, exitCode: Int32, diagnostics: String) }
struct InvoiceRenderTools: Sendable { var typst = ""; var qpdf = ""; var fontDirectory = ""; var tempRoot = "/tmp"; var timeout: TimeInterval = 0 }
struct InvoiceRenderer: Sendable { static let requiredFonts: [String] = []; var tools: InvoiceRenderTools
    func render(_ documentJSON: Data, attachment: InvoiceRenderAttachment? = nil) async throws -> Data { throw InvoiceRenderError.invalidDocument("stub") } }
struct InvoiceRenderData: Codable { struct Column: Codable { var key = "", label = "" }; struct Row: Codable { var cells: [String] = []; var detail: String? }; struct Total: Codable { var label = "", value = "" }
    var title = ""; var rows: [Row] = []; var totals: [Total] = []; var notes: [String] = []; var columns: [Column] = []; var recipientLines: [String] = []
    static let smallBusinessNote = "stub"
    struct Prepared { var data = InvoiceRenderData(); var createdAt = 0 }
    static func prepare(_ documentJSON: Data, attach: Bool) throws -> Prepared { Prepared() } }
enum InvoiceRenderFormat { static func money(_ s: String, currency: String) -> String { "" }; static func number(_ s: String) -> String { "" }; static func date(_ s: String) -> String { "" } }
enum InvoiceStandardLayout { static let template = "" }
enum FacturXMetadata { enum Level: String { case en16931 = "EN 16931" }; static func insert(into xmp: String, conformanceLevel: Level) -> String? { nil } }
