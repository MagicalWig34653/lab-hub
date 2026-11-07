import Vapor
import Foundation

// WP-D2: Ein- und Ausgabeformate des DMS. Felder in snake_case wie im Vertrag (contracts/openapi.yaml).

enum DMSError {
    static func invalid(_ field: String, _ code: String = "invalid") -> HubError {
        HubError(.unprocessableEntity, "validation_failed", errors: [FieldError(field: field, code: code)])
    }
    static let notFound = HubError(.notFound, "not_found")
    static let trashed = HubError(.conflict, "document_trashed")
}

struct DMSFileOut: Content, Sendable, Equatable {
    let role: String
    let mime: String
    let size_bytes: Int64
    let sha256: String
    let page_count: Int?
    let original_name: String?
}

struct DMSDocumentOut: Content, Sendable {
    let id: UUID
    let title: String
    let doc_date: String?
    let received_at: String
    let document_type_id: UUID?
    let storage_path_id: UUID?
    let correspondent_id: UUID?
    let asn: Int64?
    let status: String
    let trashed_at: String?
    let trash_reason: String?
    let created_by: UUID?
    let created_at: String
    let updated_at: String
    let rev: Int
    var tag_ids: [UUID]?
    var fields: [String: DMSFieldValue]?
    var files: [DMSFileOut]?
    /// Nur bei Upload: andere Dokumente des Mandanten mit demselben Original (Hinweis, nie Ablehnung).
    var duplicates: [UUID]?
    /// Nur bei Upload (WP-O2): Eingangsvorgang; Fortschritt über `GET documents/{id}/processing`.
    var ingest_item_id: UUID?
}

/// Wert eines benutzerdefinierten Feldes (JSON-Skalar).
enum DMSFieldValue: Codable, Sendable, Equatable {
    case string(String), int(Int64), bool(Bool)

    init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let i = try? c.decode(Int64.self) { self = .int(i) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else { throw DecodingError.dataCorruptedError(in: c, debugDescription: "unsupported field value") }
    }
    func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self { case .string(let s): try c.encode(s); case .int(let i): try c.encode(i); case .bool(let b): try c.encode(b) }
    }
}

/// Metadaten ändern (nur gesetzte Felder). `null` löscht `doc_date`, Typ, Pfad und Korrespondent; `tag_ids` ersetzt die Zuordnung vollständig.
/// `fields` setzt Werte je Feldcode (`null` entfernt den Wert).
struct DMSDocumentPatch: Decodable, Sendable {
    var title: String?
    var doc_date: String?
    var document_type_id: UUID?
    var storage_path_id: UUID?
    var correspondent_id: UUID?
    var tag_ids: [UUID]?
    var fields: [String: DMSFieldValue?]?
    private(set) var present: Set<String> = []

    private enum Keys: String, CodingKey { case title, doc_date, document_type_id, storage_path_id, correspondent_id, tag_ids, fields }
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        for key in c.allKeys { present.insert(key.rawValue) }
        title = try c.decodeIfPresent(String.self, forKey: .title)
        doc_date = try c.decodeIfPresent(String.self, forKey: .doc_date)
        document_type_id = try c.decodeIfPresent(UUID.self, forKey: .document_type_id)
        storage_path_id = try c.decodeIfPresent(UUID.self, forKey: .storage_path_id)
        correspondent_id = try c.decodeIfPresent(UUID.self, forKey: .correspondent_id)
        tag_ids = try c.decodeIfPresent([UUID].self, forKey: .tag_ids)
        fields = try c.decodeIfPresent([String: DMSFieldValue?].self, forKey: .fields)
    }
}

struct DMSTrashBody: Content, Sendable { var reason: String? }

extension DMSError {
    /// `yyyy-MM-dd`, ein gültiger Kalendertag.
    static func date(_ s: String, _ field: String) throws -> String {
        guard s.range(of: "^[0-9]{4}-[0-9]{2}-[0-9]{2}$", options: .regularExpression) != nil else { throw invalid(field) }
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        let p = s.split(separator: "-").compactMap { Int($0) }
        guard p.count == 3, let d = cal.date(from: DateComponents(year: p[0], month: p[1], day: p[2])),
              cal.dateComponents([.year, .month, .day], from: d) == DateComponents(year: p[0], month: p[1], day: p[2]) else { throw invalid(field) }
        return s
    }

    static func title(_ s: String?, _ field: String = "title") throws -> String {
        guard let t = s?.trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCanonicalMapping, !t.isEmpty else { throw invalid(field, "required") }
        guard t.count <= 300 else { throw invalid(field, "too_long") }
        return t
    }
}
