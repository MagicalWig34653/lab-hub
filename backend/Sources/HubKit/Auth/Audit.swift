import Vapor
import SQLKit

/// Wert in `audit_log.meta`: nur Zahlen oder kurze Kennzeichen (`[A-Za-z0-9_.:-]`, höchstens 64 Zeichen). Freitext, Namen,
/// Adressen oder Tokens sind absichtlich nicht darstellbar (AK-K1-8: Audit ohne Nutzdaten).
public enum AuditValue: Sendable, Equatable {
    case number(Int64)
    case token(String)

    static let tokenPattern = "^[A-Za-z0-9_.:-]{1,64}$"
    public static func isSafeToken(_ s: String) -> Bool { s.range(of: tokenPattern, options: .regularExpression) != nil }

    /// Ungültige Tokens werden zu `invalid` statt Nutzdaten zu übernehmen.
    public static func safe(_ s: String) -> AuditValue { .token(isSafeToken(s) ? s : "invalid") }

    var json: String {
        switch self {
        case .number(let n): String(n)
        case .token(let s): "\"\(s)\""  // durch tokenPattern ohne Anführungszeichen/Backslash
        }
    }
}

public struct AuditEvent: Sendable {
    public var action: String
    public var actor: UUID?
    public var tenant: UUID?
    public var subjectType: String?
    public var subjectID: String?
    public var meta: [String: AuditValue]
    public var requestID: String?

    public init(action: String, actor: UUID? = nil, tenant: UUID? = nil, subjectType: String? = nil, subjectID: String? = nil,
                meta: [String: AuditValue] = [:], requestID: String? = nil) {
        self.action = action; self.actor = actor; self.tenant = tenant; self.subjectType = subjectType
        self.subjectID = subjectID; self.meta = meta; self.requestID = requestID
    }
}

/// Schreibt in `audit_log` (append-only per Trigger). Läuft auf der übergebenen Verbindung/Transaktion, so dass Fachänderung
/// und Audit-Eintrag gemeinsam committen oder zurückrollen.
public enum AuditLog {
    public static func record(_ e: AuditEvent, on db: any SQLDatabase) async throws {
        precondition(AuditValue.isSafeToken(e.action), "unsafe audit action")
        let keys = e.meta.keys.sorted()
        precondition(keys.allSatisfy(AuditValue.isSafeToken), "unsafe audit meta key")
        let meta = "{" + keys.map { "\"\($0)\":\(e.meta[$0]!.json)" }.joined(separator: ",") + "}"
        let subjectType = e.subjectType.map { AuditValue.safe($0).stringValue }
        let subjectID = e.subjectID.map { AuditValue.safe($0).stringValue }
        try await db.raw("""
            INSERT INTO audit_log (action, actor_user_id, tenant_id, subject_type, subject_id, meta, request_id)
            VALUES (\(bind: e.action), \(bind: e.actor), \(bind: e.tenant), \(bind: subjectType), \(bind: subjectID),
                    \(bind: meta)::text::jsonb, \(bind: e.requestID.map { AuditValue.safe($0).stringValue }))
            """).run()
    }
}

extension AuditValue {
    var stringValue: String {
        switch self { case .number(let n): String(n); case .token(let s): s }
    }
}

/// Implementierung des Hooks aus WP-K6 gegen `audit_log`: Zähleranhebungen (`ensureAtLeast`) werden in derselben Transaktion protokolliert.
public struct AuditLogCounterHook: CounterAuditHook {
    public init() {}
    public func counterRaised(_ event: CounterAuditEvent, on db: any SQLDatabase) async throws {
        var meta: [String: AuditValue] = ["new": .number(event.new), "reason": .safe(event.reason)]
        if let p = event.previous { meta["previous"] = .number(p) }
        try await AuditLog.record(AuditEvent(action: "counter.raised", tenant: event.tenant, subjectType: "counter",
                                             subjectID: event.key, meta: meta), on: db)
    }
}
