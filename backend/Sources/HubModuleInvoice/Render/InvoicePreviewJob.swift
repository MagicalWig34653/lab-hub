import Vapor
import Fluent
import SQLKit
import HubCore

// WP-R6d: Vorschau eines Entwurfs über den Worker (das API-Image hat kein Typst). Die API friert die Eingabe ein (Entwurf wie beim Finalisieren aufbereitet,
// aber ohne Nummer: `status = preview`, Nummer `ENTWURF`, aktuelle Absender- und Empfängerdaten) und reiht `invoice.preview` ein. Der Worker rendert mit der
// gewählten oder zugeordneten Layoutversion und schreibt das PDF in die Vorschauzeile.
// Ablage und Ablauf (ADR 0008, Nachtrag R6d): PDF als `bytea` in `invoice_previews` (Datenbank, kein Objektspeicher, keine `files`-Zeile, keine Quote),
// gültig 15 Minuten; danach 404. Gelöscht wird beim nächsten Anfordern im Mandanten und mit jedem Vorschau-Job (alle Mandanten, eine Stunde nach Ablauf),
// höchstens `maxActivePerTenant` gültige Vorschauen je Mandant. Kein Hintergrundprozess in der API, keine Datei im Container.

enum InvoicePreviewJob {
    static let kind = "invoice.preview"
    static let ttlSeconds = 900
    static let maxActivePerTenant = 20
    static let maxBytes = 20 * 1024 * 1024
    /// Vor PDF-Erzeugung finaler Belege (5): eine Vorschau wartet jemand ab.
    static let priority = 4

    struct Payload: Codable, Sendable { let tenant_id: UUID; let preview_id: UUID }

    static func handler(renderer: any InvoiceRendering, storeFactory: @escaping @Sendable (any SQLDatabase) throws -> any ObjectStore) -> JobHandler {
        return { job, s in
            guard let payload = try? JSONDecoder().decode(Payload.self, from: Data(job.payload.utf8)) else { throw PermanentJobError(code: "payload_invalid") }
            // Aufräumen ohne eigenen Zeitplan: längst abgelaufene Vorschauen aller Mandanten
            try await s.raw("DELETE FROM invoice_previews WHERE expires_at < now() - interval '1 hour'").run()
            guard let row = try await s.raw("""
                SELECT input, layout_version_id FROM invoice_previews WHERE tenant_id = \(bind: payload.tenant_id) AND id = \(bind: payload.preview_id) AND expires_at > now() AND pdf IS NULL
                """).first() else { return }   // abgelaufen, gelöscht oder schon fertig: nichts zu tun
            let input = try row.decode(column: "input", as: String.self)
            let layout = try await row.decode(column: "layout_version_id", as: UUID?.self).asyncMap {
                try await InvoiceLayouts.layout(version: $0, tenant: payload.tenant_id, store: try storeFactory(s), on: s)
            } ?? .standard
            try Task.checkCancellation()
            let pdf = try await InvoiceRenderJob.renderMapped(renderer, Data(input.utf8), layout: layout)
            guard pdf.count <= maxBytes else { throw PermanentJobError(code: "preview_too_large") }
            guard let database = s as? any Database else { throw PermanentJobError(code: "database_unavailable") }
            try await invoiceTransaction(database) { tx in
                guard try await tx.raw("""
                    SELECT 1 AS x FROM jobs WHERE id = \(bind: job.id) AND state = 'running' AND attempts = \(bind: job.attempts) AND lease_until >= now() FOR UPDATE
                    """).first() != nil else { throw CancellationError() }
                try await tx.raw("""
                    UPDATE invoice_previews SET pdf = \(bind: pdf)
                    WHERE tenant_id = \(bind: payload.tenant_id) AND id = \(bind: payload.preview_id) AND expires_at > now() AND pdf IS NULL
                    """).run()
            }
        }
    }

    // MARK: Routen

    /// `POST documents/{id}/preview` (Body optional `layout_id`): 202 mit Vorschau-Id. Nur Entwürfe (sonst 409 `document_not_draft`).
    static func create(_ req: Request) async throws -> Response {
        let tenant = try req.requireTenant().tenantID, actor = try req.requireAuth().user.id
        let id = try InvoiceValidation.id(req)
        var layoutID: UUID?
        if let buffer = req.body.data, buffer.readableBytes > 0 {
            guard let b = try? JSONDecoder().decode([String: LayoutJSON].self, from: Data(buffer: buffer)) else { throw InvoiceError.invalid("body", "invalid") }
            for key in b.keys where key != "layout_id" { throw InvoiceError.invalid(key, "unknown") }
            switch b["layout_id"] {
            case nil, .null?: break
            case .string(let v)?: guard let u = UUID(uuidString: v) else { throw InvoiceError.invalid("layout_id", "not_found") }; layoutID = u
            default: throw InvoiceError.invalid("layout_id", "invalid")
            }
        }
        let previewID = UUID(), chosenLayout = layoutID
        let out = try await invoiceTransaction(req.db) { s -> String in
            guard let doc = try await s.raw("""
                SELECT status, kind, contact_id, issue_date::text AS issue, coalesce(series_id,
                       (SELECT default_series_id FROM invoice_document_types t WHERE t.tenant_id = d.tenant_id AND t.id = d.document_type_id)) AS series
                FROM invoice_documents d WHERE d.tenant_id = \(bind: tenant) AND d.id = \(bind: id)
                """).first() else { throw InvoiceError.notFound }
            guard try doc.decode(column: "status", as: String.self) == "draft" else { throw HubError(.conflict, "document_not_draft") }
            try await s.raw("DELETE FROM invoice_previews WHERE tenant_id = \(bind: tenant) AND expires_at <= now()").run()
            let active = try await s.raw("SELECT count(*)::bigint AS n FROM invoice_previews WHERE tenant_id = \(bind: tenant)").first()?.decode(column: "n", as: Int64.self) ?? 0
            guard active < maxActivePerTenant else { throw HubError(.tooManyRequests, "too_many_requests") }

            let version: UUID?
            if let chosenLayout {
                guard let v = try await InvoiceLayouts.latestVersion(layout: chosenLayout, tenant: tenant, on: s) else { throw InvoiceError.invalid("layout_id", "not_found") }
                version = v
            } else {
                version = try await InvoiceLayouts.resolve(kind: try doc.decode(column: "kind", as: String.self), series: try doc.decode(column: "series", as: UUID?.self), tenant: tenant, on: s)
            }

            // Eingabe wie beim Finalisieren, aber ohne Nummer und Hash: Absender aus den Einstellungen, Empfänger aus dem Kontakt, Steuerregime nach Belegdatum
            guard var object = try JSONSerialization.jsonObject(with: Data(try await InvoiceDocuments.fetch(id, tenant: tenant, on: s).utf8)) as? [String: Any] else { throw InvoiceError.notFound }
            guard let sender = try await InvoiceDocuments.senderJSON(tenant: tenant, on: s) else { throw InvoiceError.invalid("settings", "required") }
            object["sender"] = try JSONSerialization.jsonObject(with: Data(sender.json.utf8))
            if let contact = try doc.decode(column: "contact_id", as: UUID?.self), let recipient = try await InvoiceDocuments.recipientJSON(contact: contact, tenant: tenant, on: s) {
                object["recipient"] = try JSONSerialization.jsonObject(with: Data(recipient.utf8))
            } else { object["recipient"] = [String: Any]() }
            object["tax_regime"] = try await InvoiceDocuments.taxRegime(issueDate: try doc.decode(column: "issue", as: String.self), tenant: tenant, on: s)
            object["status"] = "preview"; object["number"] = "ENTWURF"
            object["finalized_at"] = try await s.raw("SELECT to_char(now() AT TIME ZONE 'UTC', 'YYYY-MM-DD\"T\"HH24:MI:SS\"Z\"') AS t").first()?.decode(column: "t", as: String.self)
            let input = String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)

            let payload = String(decoding: try JSONEncoder().encode(Payload(tenant_id: tenant, preview_id: previewID)), as: UTF8.self)
            let job = try await JobService(s).enqueue(kind: kind, payload: payload, priority: priority)
            guard let row = try await s.raw("""
                INSERT INTO invoice_previews (id, tenant_id, document_id, layout_version_id, input, job_id, requested_by, expires_at)
                VALUES (\(bind: previewID), \(bind: tenant), \(bind: id), \(bind: version), \(bind: input), \(bind: job), \(bind: actor), now() + make_interval(secs => \(bind: ttlSeconds)))
                RETURNING expires_at
                """).first() else { throw InvoiceError.notFound }
            let expires = ISO8601DateFormatter().string(from: try row.decode(column: "expires_at", as: Date.self))
            return String(decoding: try JSONSerialization.data(withJSONObject: ["id": previewID.uuidString, "document_id": id.uuidString, "status": "pending", "expires_at": expires],
                                                               options: [.sortedKeys]), as: UTF8.self)
        }
        return invoiceJSONResponse(out, status: .accepted)
    }

    /// `GET previews/{id}`: PDF (200), in Arbeit (409 `render_pending`), fehlgeschlagen (409 `render_failed`); abgelaufen, fremd oder unbekannt: 404.
    static func get(_ req: Request) async throws -> Response {
        let tenant = try req.requireTenant().tenantID
        let id = try InvoiceValidation.id(req)
        let s = try sql(req.db)
        guard let row = try await s.raw("""
            SELECT p.pdf, j.state FROM invoice_previews p LEFT JOIN jobs j ON j.id = p.job_id
            WHERE p.tenant_id = \(bind: tenant) AND p.id = \(bind: id) AND p.expires_at > now()
            """).first() else { throw InvoiceError.notFound }
        guard let pdf = try row.decode(column: "pdf", as: Data?.self) else {
            switch try row.decode(column: "state", as: String?.self) {
            case "queued"?, "running"?: throw HubError(.conflict, "render_pending", headers: ["Retry-After": "1"])
            default: throw HubError(.conflict, "render_failed")
            }
        }
        var headers = HTTPHeaders()
        headers.replaceOrAdd(name: .contentType, value: "application/pdf")
        headers.replaceOrAdd(name: .cacheControl, value: "private, no-store")
        headers.replaceOrAdd(name: "X-Content-Type-Options", value: "nosniff")
        headers.replaceOrAdd(name: .contentDisposition, value: "inline; filename=\"vorschau.pdf\"")
        headers.replaceOrAdd(name: "Content-Security-Policy", value: "default-src 'none'; sandbox; frame-src 'none'; base-uri 'none'; form-action 'none'")
        return Response(status: .ok, headers: headers, body: .init(data: pdf))
    }
}

extension Optional {
    func asyncMap<T>(_ f: (Wrapped) async throws -> T) async rethrows -> T? {
        switch self { case .some(let w): return try await f(w); case .none: return nil }
    }
}
