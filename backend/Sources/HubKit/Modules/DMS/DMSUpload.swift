import Vapor
import Foundation
import Crypto
import NIOCore
import SQLKit

// WP-D2: Upload-Pfad. Der Request-Body wird gestreamt (kein Vollpuffern), der Typ per Magic Bytes bestimmt (nicht per Endung oder Content-Type),
// das Größenlimit während des Streams durchgesetzt, der SHA-256 inkrementell vom ObjectStore berechnet. F-18: Upload immer über das Backend.

/// Erlaubte Dateitypen (Erkennung am Dateianfang). Weitere Typen (Office, ZIP-Container, E-Rechnung-XML) folgen mit den jeweiligen WPs.
enum DMSFileKind: String, Sendable {
    case pdf, png, jpeg, tiff, webp

    var mime: String {
        switch self {
        case .pdf: "application/pdf"
        case .png: "image/png"
        case .jpeg: "image/jpeg"
        case .tiff: "image/tiff"
        case .webp: "image/webp"
        }
    }
    var fileExtension: String { self == .jpeg ? "jpg" : rawValue }

    /// Mindestens so viele Bytes werden zur Erkennung gelesen (kürzere Dateien werden vollständig geprüft).
    static let sniffLength = 12

    static func sniff(_ b: [UInt8]) -> DMSFileKind? {
        func starts(_ p: [UInt8], at o: Int = 0) -> Bool { b.count >= o + p.count && Array(b[o..<(o + p.count)]) == p }
        if starts([0x25, 0x50, 0x44, 0x46, 0x2D]) { return .pdf }                                  // %PDF-
        if starts([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) { return .png }
        if starts([0xFF, 0xD8, 0xFF]) { return .jpeg }
        if starts([0x49, 0x49, 0x2A, 0x00]) || starts([0x4D, 0x4D, 0x00, 0x2A]) { return .tiff }
        if starts([0x52, 0x49, 0x46, 0x46]) && starts([0x57, 0x45, 0x42, 0x50], at: 8) { return .webp }  // RIFF....WEBP
        return nil
    }
}

/// Parameter des Uploads (Query). Alles wird vor dem Lesen des Bodys geprüft.
struct DMSUploadParams: Sendable {
    let originalName: String?
    let title: String
    let docDate: String?
    let typeID: UUID?
    let archive: Bool

    init(_ req: Request) throws {
        let name: String? = req.query["filename"]
        var cleaned: String?
        if let name, !name.isEmpty {
            // nur der Dateiname, keine Pfade oder Steuerzeichen
            let base = name.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? ""
            let c = String(base.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }).trimmingCharacters(in: .whitespaces)
            guard !c.isEmpty, c.count <= 255 else { throw DMSError.invalid("filename") }
            cleaned = c.precomposedStringWithCanonicalMapping
        }
        originalName = cleaned
        let explicit: String? = req.query["title"]
        if let explicit { title = try DMSError.title(explicit) } else {
            let stem = cleaned.map { ($0 as NSString).deletingPathExtension } ?? ""
            title = stem.trimmingCharacters(in: .whitespaces).isEmpty ? "Dokument" : String(stem.prefix(300))
        }
        if let d: String = req.query["doc_date"] { docDate = try DMSError.date(d, "doc_date") } else { docDate = nil }
        if let t: String = req.query["document_type_id"] {
            guard let id = UUID(uuidString: t) else { throw DMSError.invalid("document_type_id") }
            typeID = id
        } else { typeID = nil }
        let a: String? = req.query["archive"]
        switch a { case nil, "false": archive = false; case "true": archive = true; default: throw DMSError.invalid("archive") }
    }
}

/// Pull-basierter Eingangsstrom: erst die schon gelesenen Anfangs-Chunks, dann der Rest des Bodys; bricht beim Überschreiten des Limits ab.
private final class UploadSource: @unchecked Sendable {
    var iterator: Request.Body.AsyncIterator
    var head: [ByteBuffer]
    var received: Int64
    let limit: Int64
    init(iterator: Request.Body.AsyncIterator, head: [ByteBuffer], received: Int64, limit: Int64) {
        self.iterator = iterator; self.head = head; self.received = received; self.limit = limit
    }
    func next() async throws -> ByteBuffer? {
        if !head.isEmpty { return head.removeFirst() }
        guard let chunk = try await iterator.next() else { return nil }
        received += Int64(chunk.readableBytes)
        if received > limit { throw HubError(.payloadTooLarge, "payload_too_large") }
        return chunk
    }
}

enum DMSUpload {
    /// Liest den Anfang, bestimmt den Typ und liefert den gesamten Body als Strom. Unbekannter Typ: 415, bevor etwas gespeichert wird.
    static func open(_ req: Request, limit: Int64) async throws -> (kind: DMSFileKind, stream: ByteStream) {
        if let length = req.headers.first(name: .contentLength).flatMap(Int64.init), length > limit { throw HubError(.payloadTooLarge, "payload_too_large") }
        var iterator = req.body.makeAsyncIterator()
        var head: [ByteBuffer] = [], sniffed: [UInt8] = [], received: Int64 = 0
        while sniffed.count < DMSFileKind.sniffLength, let chunk = try await iterator.next() {
            received += Int64(chunk.readableBytes)
            if received > limit { throw HubError(.payloadTooLarge, "payload_too_large") }
            sniffed.append(contentsOf: chunk.readableBytesView.prefix(DMSFileKind.sniffLength - sniffed.count))
            head.append(chunk)
        }
        guard let kind = DMSFileKind.sniff(sniffed) else { throw HubError(.unsupportedMediaType, "unsupported_media_type") }
        let source = UploadSource(iterator: iterator, head: head, received: received, limit: limit)
        return (kind, ByteStream(unfolding: { try await source.next() }))
    }

    /// Stabiler Hash der Anfrage für den Idempotency-Key: Inhalt (SHA-256) plus alle Parameter. Gleicher Key + anderer Inhalt/Parameter = 422.
    static func requestHash(sha256: String, params: DMSUploadParams) -> String {
        var h = SHA256()
        h.update(data: Data("dms-upload\n\(sha256)\n\(params.originalName ?? "")\n\(params.title)\n\(params.docDate ?? "")\n\(params.typeID?.uuidString ?? "")\n\(params.archive)".utf8))
        return h.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Kompletter Upload: Strom speichern, Datei registrieren, Dokument idempotent anlegen. Antwort 201 mit dem Dokument.
    static func handle(_ req: Request, module: DMSModule) async throws -> Response {
        let context = try req.requireTenant()
        let actor = try req.requireAuth().user.id
        guard let key = req.headers.first(name: IdempotencyMiddleware.header), !key.isEmpty, key.count <= 255 else { throw HubError(.badRequest, "idempotency_key_required") }
        let params = try DMSUploadParams(req)
        let (kind, stream) = try await open(req, limit: module.maxUploadBytes)
        let store = try module.makeStore(req)
        let stored = try await store.put(tenant: context.tenantID, stream: stream, expectedSHA256: nil)
        let s = try sql(req.db)
        let fileID = try await FileRecordService(s).register(stored, backend: store.kind, contentType: kind.mime)
        let requestID = req.requestId
        let tenant = context.tenantID
        let db = req.db
        let result = try await IdempotencyService(s).execute(tenant: tenant, key: key, requestHash: requestHash(sha256: stored.key.sha256, params: params)) {
            let doc = try await DMSDocuments.create(
                tenant: tenant, actor: actor, requestID: requestID,
                doc: .init(title: params.title, docDate: params.docDate, typeID: params.typeID, originalName: params.originalName, archive: params.archive,
                           kind: kind, stored: stored, fileID: fileID), on: db)
            let encoder = JSONEncoder()
            return StoredResponse(status: 201, body: String(decoding: try encoder.encode(doc), as: UTF8.self))
        }
        var headers = HTTPHeaders()
        headers.contentType = .json
        return Response(status: HTTPResponseStatus(statusCode: result.status), headers: headers, body: .init(string: result.body))
    }
}

// MARK: Auslieferung

enum DMSDownload {
    static let roles: Set<String> = ["original", "archive", "thumbnail", "derivative"]

    /// `Content-Disposition` mit ASCII-Rückfall und UTF-8-Namen (RFC 6266/5987). Der Name kommt aus dem Titel, nie aus dem Speicherschlüssel.
    static func disposition(_ inline: Bool, title: String, ext: String) -> String {
        var name = title.precomposedStringWithCanonicalMapping.unicodeScalars.map { s -> Character in
            (CharacterSet.controlCharacters.contains(s) || "/\\:*?\"<>|".unicodeScalars.contains(s)) ? "_" : Character(s)
        }.map(String.init).joined().trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        if name.isEmpty { name = "dokument" }
        name = String(name.prefix(120)) + "." + ext
        let ascii = String(name.unicodeScalars.map { $0.isASCII && $0 != "%" ? Character($0) : "_" })
        let encoded = name.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_~")) ?? "dokument"
        return "\(inline ? "inline" : "attachment"); filename=\"\(ascii)\"; filename*=UTF-8''\(encoded)"
    }

    static func ext(for mime: String) -> String {
        switch mime { case "application/pdf": "pdf"; case "image/png": "png"; case "image/jpeg": "jpg"; case "image/tiff": "tiff"; case "image/webp": "webp"; default: "bin" }
    }

    static func response(file: DMSDocuments.StoredFile, tenant: UUID, store: any ObjectStore, inline: Bool) async throws -> Response {
        let key = try ObjectKey(tenantID: tenant, sha256: file.sha256)
        let stream: ByteStream
        do { stream = try await store.get(key) } catch ObjectStoreError.notFound { throw HubError(.notFound, "not_found") }
        var headers = HTTPHeaders()
        headers.replaceOrAdd(name: .contentType, value: file.mime)
        headers.replaceOrAdd(name: .contentDisposition, value: disposition(inline, title: file.title, ext: ext(for: file.mime)))
        headers.replaceOrAdd(name: "X-Content-Type-Options", value: "nosniff")
        headers.replaceOrAdd(name: "Content-Security-Policy", value: "default-src 'none'; sandbox")
        headers.replaceOrAdd(name: .cacheControl, value: "private, no-store")
        let body = Response.Body(asyncStream: { writer in
            do {
                for try await chunk in stream { try await writer.writeBuffer(chunk) }
                try await writer.write(.end)
            } catch { try await writer.write(.error(error)) }
        }, count: Int(file.size))
        return Response(status: .ok, headers: headers, body: body)
    }
}
