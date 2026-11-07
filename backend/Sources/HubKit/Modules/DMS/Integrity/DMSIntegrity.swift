import Vapor
import Fluent
import SQLKit
import NIOCore

// WP-D5 Prüf-Job `dms.verify` (MODUL-DMS 8, AK-D-REV-3). Liest jedes referenzierte Objekt des Mandanten aus dem ObjectStore, bildet SHA-256 und Größe und vergleicht
// beide mit der Datenbank (`files`, Kopie in `dms_document_files`); danach prüft er die Audit-Hash-Kette (F-16).
// Abweichung = Fehler: der Lauf endet mit Zustand `failed`, der Bericht nennt Dokument, Rolle und Art (nie Inhalte), und es entsteht ein Audit-Eintrag `dms.integrity.failed` (Alarm).
// „Genau einmal“: die Lease des Jobs (ADR 0006) sperrt den Lauf; zusätzlich schließt nur der Aufruf ab, der den Zustand `running` -> Ergebnis vollzieht (Zeilen-Update mit Bedingung).
// Handler ist idempotent: ein bereits abgeschlossener Lauf wird nicht erneut angefasst. Auslösung nur über die Route (kein Zeitplaner im Hub: periodisch per externem Aufruf, offener Punkt).

struct DMSIntegrityReport: Codable, Sendable {
    struct Finding: Codable, Sendable { let document_id: UUID; let role: String; let problem: String }
    struct Chain: Codable, Sendable { let entries: Int64; let ok: Bool; let problem: String?; let broken_at_seq: Int64?; let head: String }
    let findings: [Finding]
    let truncated: Bool
    let chain: Chain
}

struct DMSIntegrityOut: Content, Sendable {
    let id: UUID
    let state: String
    let created_at: String
    let started_at: String?
    let finished_at: String?
    let files_checked: Int
    let files_bad: Int
    let chain_entries: Int64?
    let chain_ok: Bool?
    let error_code: String?
    let report: DMSIntegrityReport?
}

enum DMSIntegrity {
    static let kind = "dms.verify"
    static let maxAttempts = 3
    static let maxFindings = 500

    private struct Payload: Codable { let run_id: UUID; let tenant_id: UUID }

    // MARK: Einreihen und Lesen

    /// Legt den Lauf und den Job in einer Transaktion an (202 Accepted in der Route).
    static func enqueue(tenant: UUID, actor: UUID, requestID: String, on db: any Database) async throws -> DMSIntegrityOut {
        try await dmsTransaction(db) { _, s in
            guard let row = try await s.raw("INSERT INTO dms_integrity_runs (tenant_id, requested_by) VALUES (\(bind: tenant), \(bind: actor)) RETURNING id").first() else { throw Abort(.internalServerError) }
            let run = try row.decode(column: "id", as: UUID.self)
            let payload = String(decoding: try JSONEncoder().encode(Payload(run_id: run, tenant_id: tenant)), as: UTF8.self)
            let job = try await JobService(s).enqueue(kind: kind, payload: payload, priority: DMSOCR.priorityBulk)
            try await s.raw("UPDATE dms_integrity_runs SET job_id = \(bind: job) WHERE tenant_id = \(bind: tenant) AND id = \(bind: run)").run()
            try await AuditLog.record(AuditEvent(action: "dms.integrity.requested", actor: actor, tenant: tenant, subjectType: "dms.integrity_run", subjectID: run.uuidString, requestID: requestID), on: s)
            guard let out = try await load(run, tenant: tenant, on: s) else { throw Abort(.internalServerError) }
            return out
        }
    }

    private static let columns = "id, state, created_at, started_at, finished_at, files_checked, files_bad, chain_entries, chain_ok, error_code, report::text AS report"

    private static func out(_ r: any SQLRow) throws -> DMSIntegrityOut {
        let report = try r.decode(column: "report", as: String?.self).flatMap { try? JSONDecoder().decode(DMSIntegrityReport.self, from: Data($0.utf8)) }
        return DMSIntegrityOut(id: try r.decode(column: "id", as: UUID.self), state: try r.decode(column: "state", as: String.self),
                               created_at: iso(try r.decode(column: "created_at", as: Date.self)), started_at: try r.decode(column: "started_at", as: Date?.self).map(iso),
                               finished_at: try r.decode(column: "finished_at", as: Date?.self).map(iso), files_checked: Int(try r.decode(column: "files_checked", as: Int32.self)),
                               files_bad: Int(try r.decode(column: "files_bad", as: Int32.self)), chain_entries: try r.decode(column: "chain_entries", as: Int64?.self),
                               chain_ok: try r.decode(column: "chain_ok", as: Bool?.self), error_code: try r.decode(column: "error_code", as: String?.self), report: report)
    }

    static func load(_ id: UUID, tenant: UUID, on s: any SQLDatabase) async throws -> DMSIntegrityOut? {
        try await s.raw("SELECT \(unsafeRaw: columns) FROM dms_integrity_runs WHERE tenant_id = \(bind: tenant) AND id = \(bind: id)").first().map(out)
    }

    /// Die letzten 50 Läufe, neueste zuerst.
    static func list(tenant: UUID, on s: any SQLDatabase) async throws -> [DMSIntegrityOut] {
        try await s.raw("SELECT \(unsafeRaw: columns) FROM dms_integrity_runs WHERE tenant_id = \(bind: tenant) ORDER BY created_at DESC, id DESC LIMIT 50").all().map(out)
    }

    // MARK: Handler

    static func handler(storeFactory: @escaping @Sendable (any SQLDatabase) throws -> any ObjectStore) -> JobHandler {
        return { job, s in
            guard let payload = try? JSONDecoder().decode(Payload.self, from: Data(job.payload.utf8)) else { throw PermanentJobError(code: "payload_invalid") }
            try await process(job: job, payload: payload, store: try storeFactory(s), s: s)
        }
    }

    private static func process(job: ClaimedJob, payload: Payload, store: any ObjectStore, s: any SQLDatabase) async throws {
        let tenant = payload.tenant_id, run = payload.run_id
        guard try await s.raw("""
            UPDATE dms_integrity_runs SET state = 'running', started_at = COALESCE(started_at, now())
            WHERE tenant_id = \(bind: tenant) AND id = \(bind: run) AND state IN ('queued', 'running') RETURNING id
            """).first() != nil else { return }   // abgeschlossen oder unbekannt: nichts tun

        var findings: [DMSIntegrityReport.Finding] = []
        var truncated = false, checked = 0, bad = 0
        func note(_ file: UUID, _ problem: String) async throws {
            bad += 1
            for r in try await s.raw("SELECT document_id, role FROM dms_document_files WHERE tenant_id = \(bind: tenant) AND file_id = \(bind: file) ORDER BY created_at, id").all() {
                if findings.count >= maxFindings { truncated = true; return }
                findings.append(.init(document_id: try r.decode(column: "document_id", as: UUID.self), role: try r.decode(column: "role", as: String.self), problem: problem))
            }
        }
        do {
            let files = try await s.raw("""
                SELECT fl.id, fl.sha256, fl.size_bytes, EXISTS (SELECT 1 FROM dms_document_files df WHERE df.file_id = fl.id AND (df.sha256 <> fl.sha256 OR df.size_bytes <> fl.size_bytes)) AS record_mismatch
                FROM files fl WHERE fl.tenant_id = \(bind: tenant) AND EXISTS (SELECT 1 FROM dms_document_files df WHERE df.file_id = fl.id) ORDER BY fl.id
                """).all()
            for f in files {
                try Task.checkCancellation()
                let id = try f.decode(column: "id", as: UUID.self), sha = try f.decode(column: "sha256", as: String.self), size = try f.decode(column: "size_bytes", as: Int64.self)
                checked += 1
                if try f.decode(column: "record_mismatch", as: Bool.self) { try await note(id, "record_mismatch"); continue }
                do {
                    var hasher = StreamHasher()
                    for try await chunk in try await store.get(try ObjectKey(tenantID: tenant, sha256: sha)) { hasher.update(chunk) }
                    let actual = hasher.size
                    if hasher.finish() != sha { try await note(id, "hash_mismatch") }
                    else if actual != size { try await note(id, "size_mismatch") }
                } catch ObjectStoreError.notFound { try await note(id, "missing") }
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let e as PermanentJobError {
            throw e
        } catch {
            if Task.isCancelled { throw CancellationError() }
            if job.attempts >= maxAttempts {
                _ = try await s.raw("""
                    UPDATE dms_integrity_runs SET state = 'error', error_code = 'store_unavailable', finished_at = now()
                    WHERE tenant_id = \(bind: tenant) AND id = \(bind: run) AND state = 'running'
                    """).run()
                throw PermanentJobError(code: "store_unavailable")
            }
            throw error
        }
        let chain = try await DMSAuditChain.verify(tenant: tenant, on: s)
        let report = DMSIntegrityReport(findings: findings, truncated: truncated,
                                        chain: .init(entries: chain.entries, ok: chain.ok, problem: chain.problem, broken_at_seq: chain.brokenAtSeq, head: chain.head))
        let json = String(decoding: try { let e = JSONEncoder(); e.outputFormatting = [.sortedKeys]; return try e.encode(report) }(), as: UTF8.self)
        let failed = bad > 0 || !chain.ok
        guard let database = s as? any Database else { throw PermanentJobError(code: "database_unavailable") }
        let (checkedCount, badCount) = (checked, bad)
        _ = try await dmsTransaction(database) { _, tx in
            guard try await tx.raw("""
                UPDATE dms_integrity_runs SET state = \(bind: failed ? "failed" : "passed"), finished_at = now(), files_checked = \(bind: checkedCount), files_bad = \(bind: badCount),
                  chain_entries = \(bind: chain.entries), chain_ok = \(bind: chain.ok), report = \(bind: json)::text::jsonb
                WHERE tenant_id = \(bind: tenant) AND id = \(bind: run) AND state = 'running' RETURNING id
                """).first() != nil else { return false }   // ein anderer Aufruf hat bereits abgeschlossen: kein zweites Ergebnis, kein zweiter Audit-Eintrag
            try await AuditLog.record(AuditEvent(action: "dms.integrity.checked", tenant: tenant, subjectType: "dms.integrity_run", subjectID: run.uuidString,
                                                 meta: ["files": .number(Int64(checkedCount)), "bad": .number(Int64(badCount)), "chain_ok": .number(chain.ok ? 1 : 0)]), on: tx)
            if failed {
                try await AuditLog.record(AuditEvent(action: "dms.integrity.failed", tenant: tenant, subjectType: "dms.integrity_run", subjectID: run.uuidString,
                                                     meta: ["bad": .number(Int64(badCount)), "chain_ok": .number(chain.ok ? 1 : 0)]), on: tx)
            }
            return true
        }
    }
}
