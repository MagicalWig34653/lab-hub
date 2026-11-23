import Vapor
import Fluent
import SQLKit
import Crypto

// WP-R1: gemeinsame Hilfen des Rechnungsmoduls (Eingabewerte, Prüfungen, Fehler, Transaktion, Idempotenz). Keine Fachlogik.

/// JSON-Wert einer Eingabe. Gleitkommazahlen sind absichtlich nicht darstellbar (`.other`): Beträge kommen nur als Dezimal-Strings (AGENTS.md Abschnitt 5).
enum InvoiceJSON: Decodable, Sendable, Equatable {
    case null, bool(Bool), int(Int), string(String), other
    init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Int.self) { self = .int(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else { self = .other }
    }
}

enum InvoiceError {
    static func invalid(_ field: String, _ code: String = "invalid") -> HubError {
        HubError(.unprocessableEntity, "validation_failed", errors: [FieldError(field: field, code: code)])
    }
    static let notFound = HubError(.notFound, "not_found")
    static let duplicate = HubError(.conflict, "conflict", detail: "duplicate")
    static let inUse = HubError(.conflict, "conflict", detail: "in_use")
}

/// Transaktion mit Fluent- und SQL-Zugriff (verschachtelt auf derselben Verbindung).
func invoiceTransaction<T: Sendable>(_ db: any Database, _ body: @escaping @Sendable (any SQLDatabase) async throws -> T) async throws -> T {
    try await db.transaction { tx in try await body(try sql(tx)) }
}

func invoiceJSONResponse(_ body: String, status: HTTPStatus) -> Response {
    var headers = HTTPHeaders()
    headers.contentType = .json
    return Response(status: status, headers: headers, body: .init(string: body))
}

enum InvoiceValidation {
    static func body(_ req: Request) throws -> [String: InvoiceJSON] {
        guard let body = try? req.content.decode([String: InvoiceJSON].self) else { throw InvoiceError.invalid("body", "invalid") }
        return body
    }

    static func id(_ req: Request) throws -> UUID {
        guard let id = req.parameters.get("id", as: UUID.self) else { throw InvoiceError.notFound }
        return id
    }

    /// Kalenderdatum `JJJJ-MM-TT` (gültig im gregorianischen Kalender).
    static func date(_ s: String) -> Bool {
        guard s.range(of: "^[0-9]{4}-[0-9]{2}-[0-9]{2}$", options: .regularExpression) != nil else { return false }
        let p = s.split(separator: "-").compactMap { Int($0) }
        guard p.count == 3, p[0] >= 1 else { return false }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let comps = DateComponents(year: p[0], month: p[1], day: p[2])
        guard let d = cal.date(from: comps) else { return false }
        let back = cal.dateComponents([.year, .month, .day], from: d)
        return back.year == p[0] && back.month == p[1] && back.day == p[2]
    }

    /// Dezimal-String mit höchstens `intDigits` Vor- und 4 Nachkommastellen (`numeric(n,4)`), Punkt als Trenner, kein Exponent. Nie runden: zu viele Stellen = ungültig.
    static func decimal(_ s: String, intDigits: Int, min: Decimal?, max: Decimal?) -> String? {
        guard s.range(of: "^-?[0-9]{1,\(intDigits)}(\\.[0-9]{1,4})?$", options: .regularExpression) != nil, let d = Decimal(string: s, locale: Locale(identifier: "en_US_POSIX")) else { return nil }
        if let min, d < min { return nil }
        if let max, d > max { return nil }
        return s
    }

    /// IBAN: Leerzeichen entfernt, Großbuchstaben, Prüfziffer (ISO 7064 mod 97-10).
    static func iban(_ raw: String) -> String? {
        let s = raw.filter { !$0.isWhitespace }.uppercased()
        guard s.range(of: "^[A-Z]{2}[0-9]{2}[A-Z0-9]{11,30}$", options: .regularExpression) != nil else { return nil }
        var remainder = 0
        for ch in String(s.dropFirst(4)) + String(s.prefix(4)) {
            let digits: String
            if let v = ch.wholeNumberValue, ch.isASCII { digits = String(v) } else if let a = ch.asciiValue, a >= 65, a <= 90 { digits = String(Int(a) - 55) } else { return nil }
            for d in digits { remainder = (remainder * 10 + Int(String(d))!) % 97 }
        }
        return remainder == 1 ? s : nil
    }

    static func sha256(_ parts: [Data]) -> String {
        var h = SHA256()
        for p in parts { h.update(data: p) }
        return h.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// Optionaler `Idempotency-Key` für Anlegen (POST). Ohne Header läuft die Arbeit einfach in einer Transaktion; mit Header wird sie atomar mit dem Key gespeichert
/// (Wiederholung liefert dieselbe Antwort, auch über eine andere Instanz; Fehler rollen den Key mit zurück).
enum InvoiceIdempotency {
    static func run(_ req: Request, tenant: UUID, status: HTTPStatus = .created, work: @escaping @Sendable (any SQLDatabase) async throws -> String) async throws -> Response {
        guard let key = req.headers.first(name: IdempotencyMiddleware.header) else {
            let body = try await invoiceTransaction(req.db, work)
            return invoiceJSONResponse(body, status: status)
        }
        guard !key.isEmpty, key.count <= 255 else { throw HubError(.badRequest, "idempotency_key_required") }
        let hash = InvoiceValidation.sha256([Data("\(req.method.rawValue) \(req.url.path)?\(req.url.query ?? "")\n".utf8), req.body.data.map { Data(buffer: $0) } ?? Data()])
        let stored = try await IdempotencyService(try sql(req.db)).executeAtomic(tenant: tenant, key: key, requestHash: hash) { s in
            StoredResponse(status: Int(status.code), body: try await work(s))
        }
        return invoiceJSONResponse(stored.body, status: HTTPStatus(statusCode: stored.status))
    }
}
