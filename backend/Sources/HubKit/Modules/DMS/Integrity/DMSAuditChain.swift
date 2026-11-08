import Vapor
import SQLKit

// WP-D5 / F-16: Hash-Kette über die DMS-Einträge des `audit_log` (Tabelle `dms_audit_chain`, Migration dms_021).
// Jeder Eintrag mit Aktion `dms.*` und Mandant erhält beim Commit (deferred Trigger) die nächste Folgenummer des Mandanten und
// `hash = SHA-256(prev_hash | id | Zeit(UTC) | Aktion | Akteur | Mandant | Objekt | meta | request_id)`. Die Kette entsteht in der Datenbank, nicht im Anwendungsprozess.
// Grenze (ehrlich): wer zugleich `audit_log`, Kette UND Kopfzeile (`dms_audit_heads`) lückenlos neu schreibt, fällt innerhalb der Datenbank nicht auf.
// Schutz dagegen ist das Verankern des Kopf-Hashes außerhalb (er steht im Prüfbericht und im Export-Manifest) und der Zwei-Rollen-Betrieb (Handoff H6).

struct DMSChainReport: Sendable, Equatable {
    let entries: Int64
    let ok: Bool
    /// `hash_mismatch`, `prev_mismatch`, `missing_audit`, `sequence_gap`, `unchained_audit`, `head_mismatch` oder nil.
    let problem: String?
    let brokenAtSeq: Int64?
    /// Hash des letzten Kettenglieds (Anker); 64 Nullen bei leerer Kette.
    let head: String
}

enum DMSAuditChain {
    static let genesis = String(repeating: "0", count: 64)

    /// Prüft die Kette des Mandanten von vorn bis zum Kopf (in Stapeln). Der erste Fehler beendet die Prüfung.
    static func verify(tenant: UUID, on s: any SQLDatabase, batch: Int = 1000) async throws -> DMSChainReport {
        var after: Int64 = 0, expectedPrev = genesis, entries: Int64 = 0
        // Kopf zuerst lesen und nur bis dorthin prüfen: Kette und Kopf werden im selben Commit fortgeschrieben, spätere Lesevorgänge sehen also mindestens
        // alle Glieder bis zum Kopf. Ohne diese Grenze meldete eine Prüfung neben parallelen Audit-Commits (auch den eigenen Prüfläufen) fälschlich `head_mismatch`.
        func readHead() async throws -> (seq: Int64, hash: String)? {
            guard let h = try await s.raw("SELECT seq, hash FROM dms_audit_heads WHERE tenant_id = \(bind: tenant)").first() else { return nil }
            return (try h.decode(column: "seq", as: Int64.self), try h.decode(column: "hash", as: String.self))
        }
        let head = try await readHead()
        let limit = head?.seq ?? Int64.max
        func bad(_ problem: String, _ seq: Int64?) -> DMSChainReport { DMSChainReport(entries: entries, ok: false, problem: problem, brokenAtSeq: seq, head: expectedPrev) }
        while true {
            let rows = try await s.raw("""
                SELECT c.seq, c.prev_hash, c.hash, (a.id IS NULL) AS missing, CASE WHEN a.id IS NULL THEN NULL ELSE dms_audit_hash(c.prev_hash, a.id, a.at, a.action, a.actor_user_id, a.tenant_id, a.subject_type, a.subject_id, a.meta, a.request_id) END AS expect
                FROM dms_audit_chain c LEFT JOIN audit_log a ON a.id = c.audit_id AND a.tenant_id = c.tenant_id
                WHERE c.tenant_id = \(bind: tenant) AND c.seq > \(bind: after) AND c.seq <= \(bind: limit) ORDER BY c.seq LIMIT \(bind: batch)
                """).all()
            if rows.isEmpty { break }
            for r in rows {
                let seq = try r.decode(column: "seq", as: Int64.self), prev = try r.decode(column: "prev_hash", as: String.self), hash = try r.decode(column: "hash", as: String.self)
                if seq != after + 1 { return bad("sequence_gap", after + 1) }
                if prev != expectedPrev { return bad("prev_mismatch", seq) }
                if try r.decode(column: "missing", as: Bool.self) { return bad("missing_audit", seq) }
                if try r.decode(column: "expect", as: String?.self) != hash { return bad("hash_mismatch", seq) }
                after = seq; expectedPrev = hash; entries += 1
            }
        }
        if let head {
            if head.seq != after || head.hash != expectedPrev { return bad("head_mismatch", after + 1) }
        } else if after > 0 {
            // Kopf fehlte beim ersten Lesen, die Kette hat aber Glieder: nur dann ein Fehler, wenn er auch jetzt noch fehlt (erster Commit lief parallel).
            if try await readHead() == nil { return bad("head_mismatch", after + 1) }
        }
        // DMS-Einträge im Audit, die nie in die Kette gelangten (ab dem ersten Kettenglied)
        let unchained = try await s.raw("""
            SELECT count(*)::bigint AS n FROM audit_log a WHERE a.tenant_id = \(bind: tenant) AND a.action LIKE 'dms.%'
              AND a.id >= COALESCE((SELECT min(audit_id) FROM dms_audit_chain WHERE tenant_id = \(bind: tenant)), 9223372036854775807)
              AND NOT EXISTS (SELECT 1 FROM dms_audit_chain c WHERE c.audit_id = a.id)
            """).first()?.decode(column: "n", as: Int64.self) ?? 0
        if unchained > 0 { return bad("unchained_audit", nil) }
        return DMSChainReport(entries: entries, ok: true, problem: nil, brokenAtSeq: nil, head: expectedPrev)
    }
}
