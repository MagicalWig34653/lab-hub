import Vapor
import Fluent
import SQLKit
import HubCore

// WP-BR1: Aufträge der Scan-Bridge (Nutzerseite und gemeinsame Hilfen). Zustandslos (ADR 0003): Zustand, Lease und Ablauf liegen in PostgreSQL,
// Zeitpunkte kommen aus `now()` der Datenbank, nie aus der Instanzuhr; jede Statusänderung läuft in einer Transaktion mit Zeilensperre.

enum DMSScanJobs {
    static let columns = "id, device_id, state, params::text AS params, pages, command, error_code, document_id, created_at, updated_at, finished_at"

    static let busy = HubError(.conflict, "scan_device_busy")
    static let offline = HubError(.conflict, "scan_bridge_offline")
    static let commandInvalid = HubError(.conflict, "scan_command_invalid")
    static let transitionInvalid = HubError(.conflict, "scan_transition_invalid")

    static func out(_ r: any SQLRow) throws -> ScanJobOut {
        ScanJobOut(id: try r.decode(column: "id", as: UUID.self).lower, device_id: try r.decode(column: "device_id", as: UUID.self).lower,
                   state: try r.decode(column: "state", as: String.self),
                   params: try JSONDecoder().decode(ScanParams.self, from: Data(try r.decode(column: "params", as: String.self).utf8)),
                   pages: try r.decode(column: "pages", as: Int.self), command: try r.decode(column: "command", as: String?.self),
                   error_code: try r.decode(column: "error_code", as: String?.self), document_id: try r.decode(column: "document_id", as: UUID?.self)?.lower,
                   created_at: iso(try r.decode(column: "created_at", as: Date.self)), updated_at: iso(try r.decode(column: "updated_at", as: Date.self)),
                   finished_at: try r.decode(column: "finished_at", as: Date?.self).map(iso))
    }

    static func load(_ id: UUID, tenant: UUID, lock: Bool = false, on s: any SQLDatabase) async throws -> ScanJobOut? {
        try await s.raw("SELECT \(unsafeRaw: columns) FROM dms_scan_jobs WHERE tenant_id = \(bind: tenant) AND id = \(bind: id)\(unsafeRaw: lock ? " FOR UPDATE" : "")").first().map(out)
    }

    // MARK: Ablauf (Lease und Warteschlange)

    /// Beendet Aufträge, deren Lease abgelaufen ist (`failed`/`bridge_lost`, mit Abbruchwunsch `cancelled`) und nie abgeholte Aufträge (`failed`/`expired`).
    /// Nie eine automatische Wiederholung: ein zweiter Einzug könnte Papier doppelt oder falsch verarbeiten. Jeder Aufruf der Routen löst das aus; parallele Aufrufe
    /// sind sicher (die Zeile gewinnt genau ein `UPDATE`, Audit-Eintrag genau einmal).
    static func sweep(tenant: UUID, on s: any SQLDatabase) async throws {
        // Zeilen in fester Reihenfolge sperren (gleichzeitige Aufräumläufe überholen sich nicht); die Bedingung wird nach dem Warten neu geprüft, die Zeile gewinnt genau einer
        let lost = try await s.raw("""
            WITH due AS (SELECT id FROM dms_scan_jobs WHERE tenant_id = \(bind: tenant) AND state IN (\(unsafeRaw: DMSScan.activeStates)) AND lease_until < now() ORDER BY id FOR UPDATE)
            UPDATE dms_scan_jobs j SET state = CASE WHEN j.command = 'cancel' THEN 'cancelled' ELSE 'failed' END,
              error_code = CASE WHEN j.command = 'cancel' THEN NULL ELSE 'bridge_lost' END, command = NULL, lease_until = NULL, finished_at = now(), updated_at = now()
            FROM due WHERE j.id = due.id AND j.state IN (\(unsafeRaw: DMSScan.activeStates)) AND j.lease_until < now() RETURNING j.id, j.state
            """).all()
        for row in lost {
            let state = try row.decode(column: "state", as: String.self)
            try await AuditLog.record(AuditEvent(action: "dms.scan.job.\(state)", tenant: tenant, subjectType: "dms.scan_job", subjectID: try row.decode(column: "id", as: UUID.self).lower,
                                                 meta: state == "failed" ? ["error": .token("bridge_lost")] : [:]), on: s)
        }
        let expired = try await s.raw("""
            WITH due AS (SELECT id FROM dms_scan_jobs WHERE tenant_id = \(bind: tenant) AND state = 'queued' AND created_at < now() - make_interval(secs => \(bind: DMSScan.queueExpirySeconds)) ORDER BY id FOR UPDATE)
            UPDATE dms_scan_jobs j SET state = 'failed', error_code = 'expired', finished_at = now(), updated_at = now()
            FROM due WHERE j.id = due.id AND j.state = 'queued' RETURNING j.id
            """).all()
        for row in expired {
            try await AuditLog.record(AuditEvent(action: "dms.scan.job.failed", tenant: tenant, subjectType: "dms.scan_job", subjectID: try row.decode(column: "id", as: UUID.self).lower,
                                                 meta: ["error": .token("expired")]), on: s)
        }
    }

    // MARK: Nutzer: Geräte, Aufträge

    static func devices(tenant: UUID, db: any Database) async throws -> [ScanDeviceOut] {
        try await dmsTransaction(db) { _, s in
            try await sweep(tenant: tenant, on: s)
            return try await s.raw("""
                SELECT d.id, d.name, d.capabilities::text AS capabilities, b.name AS bridge_name,
                  (b.last_seen_at > now() - make_interval(secs => \(bind: DMSScan.bridgeOnlineSeconds))) AS online,
                  EXISTS (SELECT 1 FROM dms_scan_jobs j WHERE j.tenant_id = d.tenant_id AND j.device_id = d.id AND j.state IN (\(unsafeRaw: DMSScan.openStates))) AS busy
                FROM dms_scan_devices d JOIN dms_scan_bridges b ON b.tenant_id = d.tenant_id AND b.id = d.bridge_id
                WHERE d.tenant_id = \(bind: tenant) AND d.active ORDER BY d.name, d.id
                """).all().map { r in
                ScanDeviceOut(id: try r.decode(column: "id", as: UUID.self).lower, name: try r.decode(column: "name", as: String.self),
                              bridge_name: try r.decode(column: "bridge_name", as: String.self), online: try r.decode(column: "online", as: Bool.self),
                              busy: try r.decode(column: "busy", as: Bool.self),
                              capabilities: try JSONDecoder().decode(ScanCapabilities.self, from: Data(try r.decode(column: "capabilities", as: String.self).utf8)))
            }
        }
    }

    static func create(_ input: ScanCreate, tenant: UUID, actor: UUID, requestID: String, db: any Database) async throws -> ScanJobOut {
        try await dmsTransaction(db) { _, s in
            // Zeilensperre auf dem Gerät: gleichzeitige Anlagen (auch über zwei Instanzen) laufen nacheinander; der Teilindex bleibt als Rückhalt in der Datenbank
            guard let device = try await s.raw("""
                SELECT d.capabilities::text AS capabilities, (b.last_seen_at > now() - make_interval(secs => \(bind: DMSScan.bridgeOnlineSeconds))) AS online
                FROM dms_scan_devices d JOIN dms_scan_bridges b ON b.tenant_id = d.tenant_id AND b.id = d.bridge_id
                WHERE d.tenant_id = \(bind: tenant) AND d.id = \(bind: input.deviceID) AND d.active FOR UPDATE OF d
                """).first() else { throw DMSError.notFound }
            let caps = try JSONDecoder().decode(ScanCapabilities.self, from: Data(try device.decode(column: "capabilities", as: String.self).utf8))
            let params = try input.params(for: caps)
            if let type = input.documentTypeID,
               try await s.raw("SELECT 1 AS x FROM dms_document_types WHERE tenant_id = \(bind: tenant) AND id = \(bind: type)").first() == nil { throw HubError.invalid("document_type_id") }
            try await sweep(tenant: tenant, on: s)
            guard try device.decode(column: "online", as: Bool.self) else { throw offline }
            if try await s.raw("SELECT 1 AS x FROM dms_scan_jobs WHERE tenant_id = \(bind: tenant) AND device_id = \(bind: input.deviceID) AND state IN (\(unsafeRaw: DMSScan.openStates)) LIMIT 1").first() != nil { throw busy }
            guard let row = try await s.raw("""
                INSERT INTO dms_scan_jobs (tenant_id, device_id, params, created_by)
                VALUES (\(bind: tenant), \(bind: input.deviceID), \(bind: String(decoding: try JSONEncoder().encode(params), as: UTF8.self))::text::jsonb, \(bind: actor))
                RETURNING \(unsafeRaw: columns)
                """).first() else { throw Abort(.internalServerError) }
            let job = try out(row)
            try await AuditLog.record(AuditEvent(action: "dms.scan.job.created", actor: actor, tenant: tenant, subjectType: "dms.scan_job", subjectID: job.id, requestID: requestID), on: s)
            return job
        }
    }

    static func get(_ id: UUID, tenant: UUID, db: any Database) async throws -> ScanJobOut {
        try await dmsTransaction(db) { _, s in
            try await sweep(tenant: tenant, on: s)
            guard let job = try await load(id, tenant: tenant, on: s) else { throw DMSError.notFound }
            return job
        }
    }

    /// Nutzerbefehl `next_page`, `finish` oder `cancel`. Der Befehl bleibt am Auftrag, bis die Bridge den Zustand wechselt (Verlust einer Antwort kostet nichts).
    /// Abbrechen: nicht abgeholt = sofort `cancelled`, vor dem Hochladen = Befehl an die Bridge, danach nicht mehr möglich.
    static func command(_ name: String, job id: UUID, tenant: UUID, actor: UUID, requestID: String, db: any Database) async throws -> ScanJobOut {
        try await dmsTransaction(db) { _, s in
            try await sweep(tenant: tenant, on: s)
            guard let row = try await s.raw("SELECT state, command FROM dms_scan_jobs WHERE tenant_id = \(bind: tenant) AND id = \(bind: id) FOR UPDATE").first() else { throw DMSError.notFound }
            let state = try row.decode(column: "state", as: String.self), pending = try row.decode(column: "command", as: String?.self)
            let free = pending == nil || pending == name
            switch (name, state) {
            case ("cancel", "queued"):
                try await s.raw("UPDATE dms_scan_jobs SET state = 'cancelled', finished_at = now(), updated_at = now() WHERE tenant_id = \(bind: tenant) AND id = \(bind: id)").run()
                try await AuditLog.record(AuditEvent(action: "dms.scan.job.cancelled", actor: actor, tenant: tenant, subjectType: "dms.scan_job", subjectID: id.lower, requestID: requestID), on: s)
            case ("cancel", "claimed"), ("cancel", "scanning"), ("cancel", "waiting_for_page"), ("next_page", "waiting_for_page"), ("finish", "scanning"), ("finish", "waiting_for_page"):
                guard free || name == "cancel" else { throw commandInvalid }
                try await s.raw("UPDATE dms_scan_jobs SET command = \(bind: name), updated_at = now() WHERE tenant_id = \(bind: tenant) AND id = \(bind: id)").run()
                if pending != name {   // Wiederholung desselben Befehls bleibt ohne zweiten Eintrag
                    try await AuditLog.record(AuditEvent(action: "dms.scan.job.command", actor: actor, tenant: tenant, subjectType: "dms.scan_job", subjectID: id.lower,
                                                         meta: ["command": .token(name)], requestID: requestID), on: s)
                }
            default:
                throw commandInvalid
            }
            guard let job = try await load(id, tenant: tenant, on: s) else { throw DMSError.notFound }
            return job
        }
    }
}
