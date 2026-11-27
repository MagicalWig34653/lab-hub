import Vapor
import Foundation
import HubCore

// WP-BR1: Konstanten, Eingabeprüfung und Ausgabeformate der Scan-Bridge. Alle Eingaben der Bridge und der Nutzer sind unvertrauenswürdig:
// nur Positivlisten, feste Grenzen, keine unbekannten Schlüssel. IDs werden klein geschrieben ausgegeben.

enum DMSScan {
    /// Lease eines übernommenen Auftrags (Datenbankzeit); die Bridge meldet sich alle 3 bis 15 s.
    static let leaseSeconds = 60
    /// Nicht abgeholte Aufträge verfallen, damit kein Scan überraschend startet.
    static let queueExpirySeconds = 300
    /// Eine Bridge gilt als online, wenn ihr letzter Aufruf höchstens so lange her ist.
    static let bridgeOnlineSeconds = 60
    static let maxPages = 500
    static let maxDevices = 16
    static let listLimit = 8

    static let sources = ["flatbed", "adf", "adf_duplex"]
    static let colorModes = ["color", "gray", "bw"]
    static let formats = ["a4", "letter"]
    static let resolutions = 50...1200

    /// Zustände mit Lease (die Bridge arbeitet daran) und alle offenen Zustände (belegen das Gerät); feste Texte für SQL.
    static let activeStates = "'claimed', 'scanning', 'waiting_for_page', 'uploading'"
    static let openStates = "'queued', 'claimed', 'scanning', 'waiting_for_page', 'uploading'"

    static func idempotencyKeys(job: UUID) -> [String] { ["scan-\(job.uuidString.lowercased())", "scan-\(job.uuidString)"] }
}

extension UUID { var lower: String { uuidString.lowercased() } }

// MARK: Eingabe

enum ScanInput {
    /// Body als JSON-Objekt; ohne Body `[:]`, wenn `allowEmpty`.
    static func object(_ req: Request, allowEmpty: Bool = false) throws -> [String: Any] {
        guard let buffer = req.body.data, buffer.readableBytes > 0 else {
            if allowEmpty { return [:] }
            throw HubError.invalid("body")
        }
        guard let object = StrictJSON.object(Data(buffer: buffer)) else { throw HubError.invalid("body") }
        return object
    }

    static func rejectUnknown(_ raw: [String: Any], allowed: Set<String>, prefix: String = "") throws {
        for key in raw.keys.sorted() where !allowed.contains(key) { throw HubError.invalid(prefix + key, "unknown") }
    }

    /// Zeichen, die in Namen und Titeln nichts verloren haben: Steuer-, Format- (Nullbreite, Schreibrichtung), Trenner-, Ersatz- und private Zeichen.
    static func forbidden(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .control, .format, .lineSeparator, .paragraphSeparator, .surrogate, .privateUse, .unassigned: true
        default: false
        }
    }

    /// Einzeiliger Text, 1 bis `max` Unicode-Codepunkte (wie `char_length` der Datenbank, nicht Grapheme), ohne unsichtbare oder trennende Zeichen.
    static func text(_ v: Any?, _ field: String, max: Int) throws -> String {
        guard let s = v as? String, !s.isEmpty, s.unicodeScalars.count <= max, !s.unicodeScalars.contains(where: forbidden) else { throw HubError.invalid(field) }
        return s
    }

    /// Nur Zeichen aus `allowed` (ohne regulären Ausdruck: `$` passt dort auch vor einem angehängten Zeilenumbruch, die CHECK-Bedingung der Datenbank nicht).
    static func token(_ v: Any?, allowed: (Unicode.Scalar) -> Bool, length: ClosedRange<Int>) -> String? {
        guard let s = v as? String, length.contains(s.unicodeScalars.count), s.unicodeScalars.allSatisfy(allowed) else { return nil }
        return s
    }
    static func lowerHex(_ u: Unicode.Scalar) -> Bool { (u.value >= 48 && u.value <= 57) || (u.value >= 97 && u.value <= 102) }
    static func codeChar(_ u: Unicode.Scalar) -> Bool { (u.value >= 48 && u.value <= 57) || (u.value >= 97 && u.value <= 122) || u.value == 95 }

    static func integer(_ v: Any?, _ field: String, range: ClosedRange<Int>) throws -> Int {
        guard let n = v as? Int, !(v is Bool), range.contains(n) else { throw HubError.invalid(field) }
        return n
    }

    static func uuid(_ v: Any?, _ field: String) throws -> UUID {
        guard let s = v as? String, let id = UUID(uuidString: s) else { throw HubError.invalid(field) }
        return id
    }

    static func enumList(_ v: Any?, _ field: String, allowed: [String]) throws -> [String] {
        guard let array = v as? [Any], (1...DMSScan.listLimit).contains(array.count) else { throw HubError.invalid(field) }
        var out: [String] = []
        for item in array {
            guard let s = item as? String, allowed.contains(s), !out.contains(s) else { throw HubError.invalid(field) }
            out.append(s)
        }
        return out
    }

    static func resolutionList(_ v: Any?, _ field: String) throws -> [Int] {
        guard let array = v as? [Any], (1...DMSScan.listLimit).contains(array.count) else { throw HubError.invalid(field) }
        var out: [Int] = []
        for item in array {
            guard let n = item as? Int, !(item is Bool), DMSScan.resolutions.contains(n), !out.contains(n) else { throw HubError.invalid(field) }
            out.append(n)
        }
        return out
    }
}

// MARK: Fähigkeiten und Registrierung

struct ScanCapabilities: Codable, Sendable, Equatable {
    let sources: [String]
    let resolutions: [Int]
    let color_modes: [String]
    let formats: [String]

    static func parse(_ v: Any?, _ field: String) throws -> ScanCapabilities {
        guard let raw = v as? [String: Any] else { throw HubError.invalid(field) }
        try ScanInput.rejectUnknown(raw, allowed: ["sources", "resolutions", "color_modes", "formats"], prefix: field + ".")
        return ScanCapabilities(sources: try ScanInput.enumList(raw["sources"], field + ".sources", allowed: DMSScan.sources),
                                resolutions: try ScanInput.resolutionList(raw["resolutions"], field + ".resolutions"),
                                color_modes: try ScanInput.enumList(raw["color_modes"], field + ".color_modes", allowed: DMSScan.colorModes),
                                formats: try ScanInput.enumList(raw["formats"], field + ".formats", allowed: DMSScan.formats))
    }
}

struct ScanRegistration: Sendable {
    struct Device: Sendable { let key: String; let name: String; let capabilities: ScanCapabilities }
    let name: String
    let version: String
    let devices: [Device]

    static func parse(_ raw: [String: Any]) throws -> ScanRegistration {
        try ScanInput.rejectUnknown(raw, allowed: ["name", "version", "devices"])
        let name = try ScanInput.text(raw["name"], "name", max: 100), version = try ScanInput.text(raw["version"], "version", max: 40)
        guard let list = raw["devices"] as? [Any], list.count <= DMSScan.maxDevices else { throw HubError.invalid("devices") }
        var devices: [Device] = []
        for (i, item) in list.enumerated() {
            let field = "devices[\(i)]"
            guard let d = item as? [String: Any] else { throw HubError.invalid(field) }
            try ScanInput.rejectUnknown(d, allowed: ["key", "name", "capabilities"], prefix: field + ".")
            // nur ein Hash: eine IP oder URL kommt nicht in den Hub
            guard let key = ScanInput.token(d["key"], allowed: ScanInput.lowerHex, length: 64...64), !devices.contains(where: { $0.key == key }) else { throw HubError.invalid(field + ".key") }
            devices.append(Device(key: key, name: try ScanInput.text(d["name"], field + ".name", max: 100), capabilities: try ScanCapabilities.parse(d["capabilities"], field + ".capabilities")))
        }
        return ScanRegistration(name: name, version: version, devices: devices)
    }
}

// MARK: Auftrag

struct ScanParams: Codable, Sendable, Equatable {
    var source: String
    var resolution: Int
    var color: String
    var format: String
    var title: String?
    var document_type_id: String?
    var archive: Bool
}

struct ScanCreate: Sendable {
    let deviceID: UUID
    let source: String?
    let resolution: Int?
    let color: String?
    let format: String?
    let title: String?
    let documentTypeID: UUID?
    let archive: Bool

    static func parse(_ raw: [String: Any]) throws -> ScanCreate {
        try ScanInput.rejectUnknown(raw, allowed: ["device_id", "source", "resolution", "color", "format", "title", "document_type_id", "archive"])
        guard raw["device_id"] != nil else { throw HubError.invalid("device_id", "required") }
        func present(_ key: String) -> Any? { raw[key].flatMap { $0 is NSNull ? nil : $0 } }
        var archive = false
        if let a = present("archive") {
            guard let flag = a as? Bool else { throw HubError.invalid("archive") }
            archive = flag
        }
        return ScanCreate(
            deviceID: try ScanInput.uuid(raw["device_id"], "device_id"),
            source: try present("source").map { guard let s = $0 as? String else { throw HubError.invalid("source") }; return s },
            resolution: try present("resolution").map { guard let n = $0 as? Int, !($0 is Bool) else { throw HubError.invalid("resolution") }; return n },
            color: try present("color").map { guard let s = $0 as? String else { throw HubError.invalid("color") }; return s },
            format: try present("format").map { guard let s = $0 as? String else { throw HubError.invalid("format") }; return s },
            title: try present("title").map { try ScanInput.text($0, "title", max: 300) },
            documentTypeID: try present("document_type_id").map { try ScanInput.uuid($0, "document_type_id") },
            archive: archive)
    }

    /// Parameter gegen die Fähigkeiten des Geräts prüfen; fehlende Werte werden aus den Fähigkeiten abgeleitet.
    func params(for caps: ScanCapabilities) throws -> ScanParams {
        func pick<T: Equatable>(_ value: T?, _ offered: [T], preferred: T?, _ field: String) throws -> T {
            if let value {
                guard offered.contains(value) else { throw HubError.invalid(field, "not_supported") }
                return value
            }
            if let preferred, offered.contains(preferred) { return preferred }
            guard let first = offered.first else { throw HubError.invalid(field, "not_supported") }
            return first
        }
        return ScanParams(source: try pick(source, caps.sources, preferred: "flatbed", "source"),
                          resolution: try pick(resolution, caps.resolutions, preferred: 300, "resolution"),
                          color: try pick(color, caps.color_modes, preferred: "color", "color"),
                          format: try pick(format, caps.formats, preferred: "a4", "format"),
                          title: title, document_type_id: documentTypeID?.lower, archive: archive)
    }
}

struct ScanReport: Sendable {
    let state: String?
    let pages: Int?
    let errorCode: String?
    let documentID: UUID?

    static let reportable = ["claimed", "scanning", "waiting_for_page", "uploading", "done", "failed", "cancelled"]

    static func parse(_ raw: [String: Any]) throws -> ScanReport {
        try ScanInput.rejectUnknown(raw, allowed: ["state", "pages", "error_code", "document_id"])
        var state: String?
        if let s = raw["state"] {
            guard let text = s as? String, reportable.contains(text) else { throw HubError.invalid("state") }
            state = text
        }
        let pages = try raw["pages"].map { try ScanInput.integer($0, "pages", range: 0...DMSScan.maxPages) }
        var code: String?
        if let c = raw["error_code"] {
            guard let text = ScanInput.token(c, allowed: ScanInput.codeChar, length: 1...64) else { throw HubError.invalid("error_code") }
            code = text
        }
        let document = try raw["document_id"].map { try ScanInput.uuid($0, "document_id") }
        if state == "failed", code == nil { throw HubError.invalid("error_code", "required") }
        if state != "failed", code != nil { throw HubError.invalid("error_code") }
        if state == "done", document == nil { throw HubError.invalid("document_id", "required") }
        if state != "done", document != nil { throw HubError.invalid("document_id") }
        return ScanReport(state: state, pages: pages, errorCode: code, documentID: document)
    }
}

// MARK: Ausgabe

struct ScanJobOut: Codable, Sendable {
    let id: String
    let device_id: String
    let state: String
    let params: ScanParams
    let pages: Int
    let command: String?
    let error_code: String?
    let document_id: String?
    let created_at: String
    let updated_at: String
    let finished_at: String?
}

struct ScanDeviceOut: Codable, Sendable {
    let id: String
    let name: String
    let bridge_name: String
    let online: Bool
    let busy: Bool
    let capabilities: ScanCapabilities
}

struct ScanClaimOut: Codable, Sendable {
    let id: String
    let device_key: String
    let state: String
    let params: ScanParams
    let lease_seconds: Int
}

struct ScanReportOut: Codable, Sendable {
    let id: String
    let state: String
    let pages: Int
    let commands: [String]
    let lease_seconds: Int
}

struct ScanRegisterOut: Codable, Sendable {
    struct Device: Codable, Sendable { let id: String; let key: String }
    let id: String
    let lease_seconds: Int
    let devices: [Device]
}
