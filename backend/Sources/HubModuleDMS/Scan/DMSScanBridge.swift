import Vapor
import Fluent
import SQLKit
import HubCore

// WP-BR1: Bridge-Seite (Token mit Scope `dms.scan.bridge`, Recht `dms.source.manage` der Rolle des Token-Inhabers). Die Bridge fragt ab (Polling), der Hub
// vermittelt; Geräte werden nur über einen Hash geführt (keine IP/URL im Hub). Ergebnis: vorhandene Scan-API mit `Idempotency-Key: scan-<job>`.

enum DMSScanBridge {
    /// Erlaubte Zustandswechsel der Bridge. `cancelled` nur auf Wunsch des Nutzers (Befehl `cancel`), nie beim Hochladen. Liegt ein Abbruchwunsch vor, darf die Bridge
    /// nur noch abbrechen oder scheitern, nie weiterarbeiten: ein angenommener Abbruch steht so nie neben einem Upload.
    static func allowed(from: String, to: String, command: String?) -> Bool {
        if command == "cancel" {
            return (to == "cancelled" && ["claimed", "scanning", "waiting_for_page"].contains(from)) || (to == "failed" && ["claimed", "scanning", "waiting_for_page", "uploading"].contains(from))
        }
        switch from {
        case "claimed": return ["scanning", "failed"].contains(to)
        case "scanning": return ["scanning", "waiting_for_page", "uploading", "failed"].contains(to)
        case "waiting_for_page": return ["waiting_for_page", "scanning", "uploading", "failed"].contains(to)
        case "uploading": return ["uploading", "done", "failed"].contains(to)
        default: return false
        }
    }

    // MARK: Registrierung

    /// Lebenszeichen, Version und vollständige Geräteliste. Eine Bridge je Token; die Liste ersetzt die bisherige (fehlende Geräte werden inaktiv, ihre ID bleibt gültig).
    static func register(_ reg: ScanRegistration, token: UUID, tenant: UUID, actor: UUID, requestID: String, db: any Database) async throws -> ScanRegisterOut {
        try await dmsTransaction(db) { _, s in
            guard let bridge = try await s.raw("""
                INSERT INTO dms_scan_bridges (tenant_id, token_id, name, version) VALUES (\(bind: tenant), \(bind: token), \(bind: reg.name), \(bind: reg.version))
                ON CONFLICT (token_id) DO UPDATE SET name = EXCLUDED.name, version = EXCLUDED.version, last_seen_at = now()
                RETURNING id, (xmax = 0) AS inserted
                """).first() else { throw Abort(.internalServerError) }
            let id = try bridge.decode(column: "id", as: UUID.self)
            // die Bridge-Zeile ist bis zum Commit gesperrt: gleichzeitige Registrierungen desselben Tokens laufen nacheinander
            let keys = reg.devices.map(\.key)
            try await s.raw("UPDATE dms_scan_devices SET active = false WHERE tenant_id = \(bind: tenant) AND bridge_id = \(bind: id) AND active AND device_key <> ALL (\(bind: keys)::text[])").run()
            var devices: [ScanRegisterOut.Device] = []
            for d in reg.devices {
                guard let row = try await s.raw("""
                    INSERT INTO dms_scan_devices (tenant_id, bridge_id, device_key, name, capabilities)
                    VALUES (\(bind: tenant), \(bind: id), \(bind: d.key), \(bind: d.name), \(bind: String(decoding: try JSONEncoder().encode(d.capabilities), as: UTF8.self))::text::jsonb)
                    ON CONFLICT (bridge_id, device_key) DO UPDATE SET name = EXCLUDED.name, capabilities = EXCLUDED.capabilities, active = true, seen_at = now()
                    RETURNING id
                    """).first() else { throw Abort(.internalServerError) }
                devices.append(.init(id: try row.decode(column: "id", as: UUID.self).lower, key: d.key))
            }
            if try bridge.decode(column: "inserted", as: Bool.self) {
                try await AuditLog.record(AuditEvent(action: "dms.scan.bridge.registered", actor: actor, tenant: tenant, subjectType: "dms.scan_bridge", subjectID: id.lower,
                                                     meta: ["devices": .number(Int64(devices.count))], requestID: requestID), on: s)
            }
            return ScanRegisterOut(id: id.lower, lease_seconds: DMSScan.leaseSeconds, devices: devices)
        }
    }

    /// Lebenszeichen für jeden Aufruf der Bridge; die Bridge muss sich vorher registriert haben.
    private static func touch(token: UUID, tenant: UUID, on s: any SQLDatabase) async throws -> UUID {
        guard let row = try await s.raw("UPDATE dms_scan_bridges SET last_seen_at = now() WHERE tenant_id = \(bind: tenant) AND token_id = \(bind: token) RETURNING id").first()
        else { throw HubError(.conflict, "conflict", detail: "bridge_not_registered") }
        return try row.decode(column: "id", as: UUID.self)
    }

    // MARK: Übernehmen

    /// Nächsten Auftrag der eigenen Geräte übernehmen. Genau ein Aufrufer gewinnt (`FOR UPDATE SKIP LOCKED`), die Lease läuft ab der Datenbankzeit.
    static func claim(token: UUID, tenant: UUID, db: any Database) async throws -> ScanClaimOut? {
        try await dmsTransaction(db) { _, s in
            let bridge = try await touch(token: token, tenant: tenant, on: s)
            try await DMSScanJobs.sweep(tenant: tenant, on: s)
            guard let row = try await s.raw("""
                WITH next AS (
                  SELECT j.id FROM dms_scan_jobs j JOIN dms_scan_devices d ON d.tenant_id = j.tenant_id AND d.id = j.device_id
                  WHERE j.tenant_id = \(bind: tenant) AND j.state = 'queued' AND d.bridge_id = \(bind: bridge) AND d.active
                  ORDER BY j.created_at, j.id FOR UPDATE OF j SKIP LOCKED LIMIT 1)
                UPDATE dms_scan_jobs j SET state = 'claimed', lease_until = now() + make_interval(secs => \(bind: DMSScan.leaseSeconds)), claimed_at = now(), updated_at = now()
                FROM next WHERE j.id = next.id
                RETURNING j.id, j.params::text AS params, (SELECT device_key FROM dms_scan_devices WHERE id = j.device_id) AS device_key
                """).first() else { return nil }
            return ScanClaimOut(id: try row.decode(column: "id", as: UUID.self).lower, device_key: try row.decode(column: "device_key", as: String.self), state: "claimed",
                                params: try JSONDecoder().decode(ScanParams.self, from: Data(try row.decode(column: "params", as: String.self).utf8)), lease_seconds: DMSScan.leaseSeconds)
        }
    }

    // MARK: Zustand melden

    /// Das gemeldete Dokument muss der Upload der Bridge selbst sein: gespeicherte Antwort des Schlüssels `scan-<job>` in diesem Mandanten, Eingangsvorgang der Scan-API
    /// (`share_ext`) mit dem Token dieser Bridge als Herkunft, nicht im Papierkorb. Ein vorab über die Oberfläche oder mit einem anderen Token unter diesem Schlüssel angelegtes
    /// Dokument wird so nie als Ergebnis angenommen.
    private static func resultDocumentIsValid(_ document: UUID, job: UUID, token: UUID, tenant: UUID, on s: any SQLDatabase) async throws -> Bool {
        let rows = try await s.raw("""
            SELECT response_body FROM idempotency_keys WHERE tenant_id = \(bind: tenant) AND key IN (\(bind: DMSScan.idempotencyKeys(job: job)[0]), \(bind: DMSScan.idempotencyKeys(job: job)[1]))
              AND state = 'done' AND response_status = 201
            """).all()
        for row in rows {
            guard let object = try? JSONSerialization.jsonObject(with: Data(try row.decode(column: "response_body", as: String.self).utf8)) as? [String: Any],
                  let text = object["id"] as? String, UUID(uuidString: text) == document else { continue }
            return try await s.raw("""
                SELECT 1 AS x FROM dms_documents d WHERE d.tenant_id = \(bind: tenant) AND d.id = \(bind: document) AND d.trashed_at IS NULL
                  AND EXISTS (SELECT 1 FROM dms_ingest_items i WHERE i.tenant_id = d.tenant_id AND i.document_id = d.id AND i.source = 'share_ext'
                                AND i.origin_ref = \(bind: "api_token:\(token.lower)"))
                """).first() != nil
        }
        return false
    }

    static func report(_ input: ScanReport, job: UUID, token: UUID, tenant: UUID, actor: UUID, requestID: String, db: any Database) async throws -> ScanReportOut {
        try await dmsTransaction(db) { _, s in
            let bridge = try await touch(token: token, tenant: tenant, on: s)
            try await DMSScanJobs.sweep(tenant: tenant, on: s)
            guard let row = try await s.raw("""
                SELECT j.state, j.command, j.error_code, j.pages, j.document_id, d.bridge_id FROM dms_scan_jobs j
                JOIN dms_scan_devices d ON d.tenant_id = j.tenant_id AND d.id = j.device_id
                WHERE j.tenant_id = \(bind: tenant) AND j.id = \(bind: job) FOR UPDATE OF j
                """).first(), try row.decode(column: "bridge_id", as: UUID.self) == bridge else { throw DMSError.notFound }   // fremder Mandant, fremde Bridge: 404
            let state = try row.decode(column: "state", as: String.self), command = try row.decode(column: "command", as: String?.self)
            let errorCode = try row.decode(column: "error_code", as: String?.self), pages = try row.decode(column: "pages", as: Int.self)
            let current = try row.decode(column: "document_id", as: UUID?.self)
            func answer(_ state: String, _ pages: Int, _ command: String?) -> ScanReportOut {
                ScanReportOut(id: job.lower, state: state, pages: pages, commands: command.map { [$0] } ?? [], lease_seconds: DMSScan.leaseSeconds)
            }
            let active = ["claimed", "scanning", "waiting_for_page", "uploading"].contains(state)

            guard let to = input.state else {   // Lebenszeichen: Lease verlängern, Seitenzahl nachtragen
                guard active else { return answer(state, pages, nil) }
                try await s.raw("UPDATE dms_scan_jobs SET lease_until = now() + make_interval(secs => \(bind: DMSScan.leaseSeconds)), pages = COALESCE(\(bind: input.pages), pages), updated_at = now() WHERE tenant_id = \(bind: tenant) AND id = \(bind: job)").run()
                return answer(state, input.pages ?? pages, command)
            }
            // abgeschlossen: nur Wiederholungen und das späte Ergebnis einer verlorenen Lease
            if !active {
                if state == to, to == "done", current == input.documentID { return answer(state, pages, nil) }
                if state == to, to == "cancelled" { return answer(state, pages, nil) }
                if state == to, to == "failed", errorCode == input.errorCode { return answer(state, pages, nil) }   // verlorene Antwort: Wiederholung ist unschädlich
                guard state == "failed", errorCode == "bridge_lost", to == "done" else { throw DMSScanJobs.transitionInvalid }
            } else if !allowed(from: state, to: to, command: command) {
                throw DMSScanJobs.transitionInvalid
            }
            if to == "done" {
                guard let document = input.documentID, try await resultDocumentIsValid(document, job: job, token: token, tenant: tenant, on: s) else { throw HubError.invalid("document_id", "not_from_this_job") }
            }
            let newPages = input.pages ?? pages
            switch to {
            case "done":
                try await s.raw("""
                    UPDATE dms_scan_jobs SET state = 'done', document_id = \(bind: input.documentID), error_code = NULL, command = NULL, lease_until = NULL, pages = \(bind: newPages),
                      finished_at = now(), updated_at = now() WHERE tenant_id = \(bind: tenant) AND id = \(bind: job)
                    """).run()
            case "failed":
                try await s.raw("""
                    UPDATE dms_scan_jobs SET state = 'failed', error_code = \(bind: input.errorCode), command = NULL, lease_until = NULL, pages = \(bind: newPages),
                      finished_at = now(), updated_at = now() WHERE tenant_id = \(bind: tenant) AND id = \(bind: job)
                    """).run()
            case "cancelled":
                try await s.raw("UPDATE dms_scan_jobs SET state = 'cancelled', command = NULL, lease_until = NULL, pages = \(bind: newPages), finished_at = now(), updated_at = now() WHERE tenant_id = \(bind: tenant) AND id = \(bind: job)").run()
            default:
                // der Befehl bleibt, bis die Bridge ihn mit dem passenden Zustandswechsel quittiert (nächste Seite: scanning, fertig: uploading)
                let rest: String? = (command == "next_page" && to == "scanning") || (command == "finish" && to == "uploading") ? nil : command
                try await s.raw("""
                    UPDATE dms_scan_jobs SET state = \(bind: to), command = \(bind: rest), lease_until = now() + make_interval(secs => \(bind: DMSScan.leaseSeconds)), pages = \(bind: newPages),
                      updated_at = now() WHERE tenant_id = \(bind: tenant) AND id = \(bind: job)
                    """).run()
                return answer(to, newPages, rest)
            }
            // hier endet nur ein echter Übergang in einen Endzustand (Wiederholungen kehrten oben zurück)
            let meta: [String: AuditValue] = to == "failed" ? ["error": .token(input.errorCode ?? "error")] : [:]
            try await AuditLog.record(AuditEvent(action: "dms.scan.job.\(to)", actor: actor, tenant: tenant, subjectType: "dms.scan_job", subjectID: job.lower, meta: meta, requestID: requestID), on: s)
            return answer(to, newPages, nil)
        }
    }
}
