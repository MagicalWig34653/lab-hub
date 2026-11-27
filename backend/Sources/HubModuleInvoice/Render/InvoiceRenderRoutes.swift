import Vapor
import Fluent
import SQLKit
import HubCore

// WP-R6c: `GET documents/{id}/pdf` (Recht invoice.document.read) liefert das gespeicherte PDF; `POST documents/{id}/render` (Recht invoice.document.finalize)
// stößt die Erzeugung an, wenn noch keine läuft und noch kein PDF existiert. Beides ist idempotent: ein fertiges PDF wird nie ersetzt, ein laufender
// Auftrag nie verdoppelt. Alle Abfragen sind mandantengefiltert (fremder Mandant oder fremde Beleg-Id = 404).
// Fehlercodes (409): `document_not_final` (Entwurf), `render_pending` (läuft, mit Retry-After), `render_failed` (Auftrag endgültig fehlgeschlagen), `render_not_started`
// (vor R6c finalisiert und noch nicht angestoßen); `POST render` beantwortet die drei letzten Fälle mit 202 bzw. startet neu.

struct InvoiceRenderStatusOut: Content, Sendable {
    let document_id: UUID
    /// `ready` oder `pending`
    let status: String
    let pdf_sha256: String?
    let layout_key: String?
    let layout_version: Int?
    let renderer_version: String?
    let rendered_at: String?
}

enum InvoiceRenderRoutes {
    struct State { let fileSHA: String, size: Int64, layoutKey: String, layoutVersion: Int, rendererVersion: String, createdAt: Date }

    /// Beleg des Mandanten sperren (`lock`) oder lesen; 404 für fremde oder unbekannte Belege, 409 `document_not_final` für Entwürfe. Rückgabe: Belegnummer.
    private static func finalDocument(_ id: UUID, tenant: UUID, lock: Bool, on s: any SQLDatabase) async throws -> String? {
        let query: SQLQueryString = lock
            ? "SELECT status, number FROM invoice_documents WHERE tenant_id = \(bind: tenant) AND id = \(bind: id) FOR UPDATE"
            : "SELECT status, number FROM invoice_documents WHERE tenant_id = \(bind: tenant) AND id = \(bind: id)"
        guard let row = try await s.raw(query).first() else { throw InvoiceError.notFound }
        guard try row.decode(column: "status", as: String.self) == "final" else { throw HubError(.conflict, "document_not_final") }
        return try row.decode(column: "number", as: String?.self)
    }

    private static func state(_ id: UUID, tenant: UUID, on s: any SQLDatabase) async throws -> State? {
        guard let r = try await s.raw("""
            SELECT pdf_sha256, f.size_bytes, layout_key, layout_version, renderer_version, st.created_at
            FROM invoice_render_states st JOIN files f ON f.id = st.file_id
            WHERE st.tenant_id = \(bind: tenant) AND st.document_id = \(bind: id)
            """).first() else { return nil }
        return State(fileSHA: try r.decode(column: "pdf_sha256", as: String.self), size: try r.decode(column: "size_bytes", as: Int64.self),
                     layoutKey: try r.decode(column: "layout_key", as: String.self), layoutVersion: try r.decode(column: "layout_version", as: Int.self),
                     rendererVersion: try r.decode(column: "renderer_version", as: String.self), createdAt: try r.decode(column: "created_at", as: Date.self))
    }

    /// Zustand des jüngsten Auftrags: `queued`, `running`, `done`, `failed_permanent` oder nil (kein Auftrag bekannt).
    private static func jobState(_ id: UUID, tenant: UUID, on s: any SQLDatabase) async throws -> String? {
        try await s.raw("""
            SELECT j.state FROM invoice_render_jobs r JOIN jobs j ON j.id = r.job_id WHERE r.tenant_id = \(bind: tenant) AND r.document_id = \(bind: id)
            """).first()?.decode(column: "state", as: String.self)
    }

    private static func iso(_ d: Date) -> String { ISO8601DateFormatter().string(from: d) }

    static func out(_ id: UUID, _ st: State?) -> InvoiceRenderStatusOut {
        InvoiceRenderStatusOut(document_id: id, status: st == nil ? "pending" : "ready", pdf_sha256: st?.fileSHA, layout_key: st?.layoutKey, layout_version: st?.layoutVersion,
                               renderer_version: st?.rendererVersion, rendered_at: st.map { iso($0.createdAt) })
    }

    // MARK: Download

    static func pdf(_ req: Request, store: @Sendable (any SQLDatabase) throws -> any ObjectStore) async throws -> Response {
        let tenant = try req.requireTenant().tenantID
        let id = try InvoiceValidation.id(req)
        let s = try sql(req.db)
        let number = try await finalDocument(id, tenant: tenant, lock: false, on: s)
        let disposition: String = req.query["disposition"] ?? "attachment"
        guard ["attachment", "inline"].contains(disposition) else { throw InvoiceError.invalid("disposition") }
        guard let st = try await state(id, tenant: tenant, on: s) else {
            switch try await jobState(id, tenant: tenant, on: s) {
            case "queued", "running": throw HubError(.conflict, "render_pending", headers: ["Retry-After": "2"])
            case "failed_permanent": throw HubError(.conflict, "render_failed")
            default: throw HubError(.conflict, "render_not_started")
            }
        }
        let etag = "\"\(st.fileSHA)\""
        var headers = HTTPHeaders()
        headers.replaceOrAdd(name: .eTag, value: etag)
        headers.replaceOrAdd(name: .cacheControl, value: "private, no-cache")
        headers.replaceOrAdd(name: "X-Content-Type-Options", value: "nosniff")
        if req.headers.first(name: .ifNoneMatch) == etag { return Response(status: .notModified, headers: headers) }
        let key = try ObjectKey(tenantID: tenant, sha256: st.fileSHA)
        let stream: ByteStream
        do { stream = try await store(s).get(key) } catch ObjectStoreError.notFound { throw HubError(.internalServerError, "render_file_missing") }
        headers.replaceOrAdd(name: .contentType, value: "application/pdf")
        headers.replaceOrAdd(name: .contentDisposition, value: Self.disposition(inline: disposition == "inline", number: number))
        headers.replaceOrAdd(name: "Content-Security-Policy", value: "default-src 'none'; sandbox; frame-src 'none'; base-uri 'none'; form-action 'none'")
        let body = Response.Body(asyncStream: { writer in
            do {
                for try await chunk in stream { try await writer.writeBuffer(chunk) }
                try await writer.write(.end)
            } catch { try await writer.write(.error(error)) }
        }, count: Int(st.size))
        return Response(status: .ok, headers: headers, body: body)
    }

    /// Dateiname aus der Belegnummer, nur `A–Z a–z 0–9 . _ -` (alles andere wird `_`); nie aus dem Speicherschlüssel.
    static func disposition(inline: Bool, number: String?) -> String {
        let safe = String((number ?? "").unicodeScalars.map { s -> Character in
            (s.isASCII && (s.properties.isAlphabetic || (s.value >= 48 && s.value <= 57) || "._-".unicodeScalars.contains(s))) ? Character(s) : "_"
        }.prefix(100))
        return "\(inline ? "inline" : "attachment"); filename=\"\(safe.isEmpty ? "beleg" : safe).pdf\""
    }

    // MARK: Anstoßen

    /// Ein fertiges PDF bleibt (200 `ready`); läuft ein Auftrag, ändert sich nichts (202 `pending`); sonst (fehlgeschlagen, vor R6c finalisiert) wird genau ein neuer Auftrag
    /// eingereiht (202). Der Beleg ist während der Entscheidung gesperrt: zwei gleichzeitige Aufrufe reihen nicht doppelt ein.
    static func render(_ req: Request) async throws -> Response {
        let tenant = try req.requireTenant().tenantID, actor = try req.requireAuth().user.id, requestID = req.requestId
        let id = try InvoiceValidation.id(req)
        let result = try await invoiceTransaction(req.db) { s -> (InvoiceRenderStatusOut, HTTPStatus) in
            _ = try await finalDocument(id, tenant: tenant, lock: true, on: s)
            if let st = try await state(id, tenant: tenant, on: s) { return (out(id, st), .ok) }
            switch try await jobState(id, tenant: tenant, on: s) {
            case "queued", "running": return (out(id, nil), .accepted)
            default:
                try await InvoiceRenderJob.enqueue(document: id, tenant: tenant, on: s)
                try await AuditLog.record(AuditEvent(action: "invoice.document.render_requested", actor: actor, tenant: tenant, subjectType: "invoice.document", subjectID: id.uuidString,
                                                     requestID: requestID), on: s)
                return (out(id, nil), .accepted)
            }
        }
        var headers = HTTPHeaders()
        headers.contentType = .json
        return Response(status: result.1, headers: headers, body: .init(data: try JSONEncoder().encode(result.0)))
    }
}
