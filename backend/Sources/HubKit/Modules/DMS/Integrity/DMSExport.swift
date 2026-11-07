import Vapor
import Fluent
import SQLKit
import Crypto
import NIOCore

// WP-D5 Export-Job `dms.export` (MODUL-DMS 8/11, AK-D-REV-4: Prüfzugriff). Ergebnis: ein ZIP im ObjectStore (Rolle: Datei des Mandanten, nicht Teil eines Dokuments) mit
//   documents/<ASN oder Kurz-ID>/<rolle>-<name>   die Dateien (Original und Archivfassung),
//   index.csv                                       eine Zeile je Datei (Dokument, Titel, Datum, Typ, ASN, Rolle, Pfad, SHA-256, Größe),
//   manifest.json                                   Format, Zeitpunkt, Hash-Kette (Kopf) und je Datei Pfad, SHA-256, Größe (auch für index.csv).
// Das Manifest ist von außen prüfbar: `sha256sum` jeder Datei gegen `files[].sha256`. Beim Packen wird jede Datei gegen den gespeicherten Hash geprüft; stimmt etwas nicht,
// scheitert der Export (`integrity_failed`) statt Manipuliertes auszuliefern. Der Export enthält Dokumente ohne Papierkorb. Keine GoBD-Konformitätsaussage (F-24).
// Genau einmal: Lease des Jobs, zusätzlich schließt nur der Aufruf ab, der `running` -> `done` vollzieht; der ZIP-Schreiber ist deterministisch (Zeitstempel = Anlegezeit); zwischen zwei Läufen ändert sich der Kopf der Audit-Kette im Manifest, die Bytes sind also nicht identisch.

struct DMSExportParams: Content, Sendable {
    var document_ids: [UUID]?
    var date_from: String?
    var date_to: String?
    var document_type_id: UUID?
}

struct DMSExportOut: Content, Sendable {
    let id: UUID
    let state: String
    let params: DMSExportParams
    let created_at: String
    let finished_at: String?
    let document_count: Int?
    let file_count: Int?
    let size_bytes: Int64?
    let sha256: String?
    let manifest_sha256: String?
    let error_code: String?
}

enum DMSExport {
    static let kind = "dms.export"
    static let maxAttempts = 3
    static let maxDocuments = 20_000
    static let format = "labhub-dms-export/1"

    private struct Payload: Codable { let export_id: UUID; let tenant_id: UUID }

    // MARK: Einreihen und Lesen

    static func enqueue(_ params: DMSExportParams, tenant: UUID, actor: UUID, requestID: String, on db: any Database) async throws -> DMSExportOut {
        var p = params
        if let ids = p.document_ids {
            guard !ids.isEmpty, ids.count <= maxDocuments else { throw DMSError.invalid("document_ids") }
            p.document_ids = Array(Set(ids)).sorted { $0.uuidString < $1.uuidString }
        }
        if let d = p.date_from { p.date_from = try DMSError.date(d, "date_from") }
        if let d = p.date_to { p.date_to = try DMSError.date(d, "date_to") }
        let json = String(decoding: try { let e = JSONEncoder(); e.outputFormatting = [.sortedKeys]; return try e.encode(p) }(), as: UTF8.self)
        let final = p
        return try await dmsTransaction(db) { _, s in
            if let t = final.document_type_id { try await DMSDocuments.requireRef("dms_document_types", t, tenant: tenant, field: "document_type_id", on: s) }
            guard let row = try await s.raw("INSERT INTO dms_exports (tenant_id, params, requested_by) VALUES (\(bind: tenant), \(bind: json)::text::jsonb, \(bind: actor)) RETURNING id").first()
            else { throw Abort(.internalServerError) }
            let id = try row.decode(column: "id", as: UUID.self)
            let payload = String(decoding: try JSONEncoder().encode(Payload(export_id: id, tenant_id: tenant)), as: UTF8.self)
            let job = try await JobService(s).enqueue(kind: kind, payload: payload, priority: DMSOCR.priorityBulk)
            try await s.raw("UPDATE dms_exports SET job_id = \(bind: job) WHERE tenant_id = \(bind: tenant) AND id = \(bind: id)").run()
            try await AuditLog.record(AuditEvent(action: "dms.export.requested", actor: actor, tenant: tenant, subjectType: "dms.export", subjectID: id.uuidString, requestID: requestID), on: s)
            guard let out = try await load(id, tenant: tenant, on: s) else { throw Abort(.internalServerError) }
            return out
        }
    }

    private static let columns = "id, state, params::text AS params, created_at, finished_at, document_count, file_count, size_bytes, sha256, manifest_sha256, error_code"

    private static func out(_ r: any SQLRow) throws -> DMSExportOut {
        let params = (try? JSONDecoder().decode(DMSExportParams.self, from: Data(try r.decode(column: "params", as: String.self).utf8))) ?? DMSExportParams()
        return DMSExportOut(id: try r.decode(column: "id", as: UUID.self), state: try r.decode(column: "state", as: String.self), params: params,
                            created_at: iso(try r.decode(column: "created_at", as: Date.self)), finished_at: try r.decode(column: "finished_at", as: Date?.self).map(iso),
                            document_count: try r.decode(column: "document_count", as: Int32?.self).map(Int.init), file_count: try r.decode(column: "file_count", as: Int32?.self).map(Int.init),
                            size_bytes: try r.decode(column: "size_bytes", as: Int64?.self), sha256: try r.decode(column: "sha256", as: String?.self),
                            manifest_sha256: try r.decode(column: "manifest_sha256", as: String?.self), error_code: try r.decode(column: "error_code", as: String?.self))
    }

    static func load(_ id: UUID, tenant: UUID, on s: any SQLDatabase) async throws -> DMSExportOut? {
        try await s.raw("SELECT \(unsafeRaw: columns) FROM dms_exports WHERE tenant_id = \(bind: tenant) AND id = \(bind: id)").first().map(out)
    }

    static func list(tenant: UUID, on s: any SQLDatabase) async throws -> [DMSExportOut] {
        try await s.raw("SELECT \(unsafeRaw: columns) FROM dms_exports WHERE tenant_id = \(bind: tenant) ORDER BY created_at DESC, id DESC LIMIT 50").all().map(out)
    }

    /// Hash des ZIP, wenn der Export fertig ist (für den Download).
    static func result(_ id: UUID, tenant: UUID, on s: any SQLDatabase) async throws -> (sha256: String, size: Int64)? {
        guard let r = try await s.raw("SELECT sha256, size_bytes FROM dms_exports WHERE tenant_id = \(bind: tenant) AND id = \(bind: id) AND state = 'done'").first(),
              let sha = try r.decode(column: "sha256", as: String?.self), let size = try r.decode(column: "size_bytes", as: Int64?.self) else { return nil }
        return (sha, size)
    }

    // MARK: Handler

    static func handler(tempRoot: String, storeFactory: @escaping @Sendable (any SQLDatabase) throws -> any ObjectStore) -> JobHandler {
        return { job, s in
            guard let payload = try? JSONDecoder().decode(Payload.self, from: Data(job.payload.utf8)) else { throw PermanentJobError(code: "payload_invalid") }
            try await process(job: job, payload: payload, tempRoot: tempRoot, store: try storeFactory(s), s: s)
        }
    }

    private struct DocRow { let id: UUID; let title: String; let docDate: String?; let typeName: String?; let asn: Int64? }
    private struct FileRow { let doc: DocRow; let role: String; let sha256: String; let size: Int64; let mime: String; let path: String }

    private static func fail(_ run: UUID, tenant: UUID, code: String, on s: any SQLDatabase) async throws {
        try await s.raw("""
            UPDATE dms_exports SET state = 'failed', error_code = \(bind: code), finished_at = now() WHERE tenant_id = \(bind: tenant) AND id = \(bind: run) AND state = 'running'
            """).run()
    }

    private static func process(job: ClaimedJob, payload: Payload, tempRoot: String, store: any ObjectStore, s: any SQLDatabase) async throws {
        let tenant = payload.tenant_id, id = payload.export_id
        guard let row = try await s.raw("""
            UPDATE dms_exports SET state = 'running' WHERE tenant_id = \(bind: tenant) AND id = \(bind: id) AND state IN ('queued', 'running')
            RETURNING params::text AS params, created_at
            """).first() else { return }   // abgeschlossen oder unbekannt
        let params = (try? JSONDecoder().decode(DMSExportParams.self, from: Data(try row.decode(column: "params", as: String.self).utf8))) ?? DMSExportParams()
        let createdAt = try row.decode(column: "created_at", as: Date.self)

        let docs = try await s.raw("""
            SELECT d.id, d.title, d.doc_date::text AS doc_date, t.name AS type_name, d.asn FROM dms_documents d
            LEFT JOIN dms_document_types t ON t.tenant_id = d.tenant_id AND t.id = d.document_type_id
            WHERE d.tenant_id = \(bind: tenant) AND d.trashed_at IS NULL
              AND (\(bind: params.document_ids)::uuid[] IS NULL OR d.id = ANY(\(bind: params.document_ids)::uuid[]))
              AND (\(bind: params.document_type_id)::uuid IS NULL OR d.document_type_id = \(bind: params.document_type_id)::uuid)
              AND (\(bind: params.date_from)::text IS NULL OR COALESCE(d.doc_date, (d.received_at AT TIME ZONE 'UTC')::date) >= \(bind: params.date_from)::text::date)
              AND (\(bind: params.date_to)::text IS NULL OR COALESCE(d.doc_date, (d.received_at AT TIME ZONE 'UTC')::date) <= \(bind: params.date_to)::text::date)
            ORDER BY d.asn NULLS LAST, d.created_at, d.id LIMIT \(bind: maxDocuments + 1)
            """).all().map { DocRow(id: try $0.decode(column: "id", as: UUID.self), title: try $0.decode(column: "title", as: String.self), docDate: try $0.decode(column: "doc_date", as: String?.self),
                                    typeName: try $0.decode(column: "type_name", as: String?.self), asn: try $0.decode(column: "asn", as: Int64?.self)) }
        if docs.count > maxDocuments { try await fail(id, tenant: tenant, code: "export_too_large", on: s); throw PermanentJobError(code: "export_too_large") }

        let workDir = URL(fileURLWithPath: tempRoot, isDirectory: true).appendingPathComponent("lh-export-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: workDir) }
        let zipURL = workDir.appendingPathComponent("export.zip")
        guard FileManager.default.createFile(atPath: zipURL.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw PermanentJobError(code: "workdir_unwritable") }

        var written: [FileRow] = []
        var manifestSHA = "", zipSHA = "", zipSize: Int64 = 0
        do {
            let handle = try FileHandle(forWritingTo: zipURL)
            defer { try? handle.close() }
            let zip = ZIPWriter(handle: handle, timestamp: createdAt)
            for doc in docs {
                let folder = doc.asn.map { "ASN-\($0)" } ?? "ID-\(doc.id.uuidString.lowercased())"
                let files = try await s.raw("""
                    SELECT role, sha256, size_bytes, mime, original_name FROM dms_document_files
                    WHERE tenant_id = \(bind: tenant) AND document_id = \(bind: doc.id) AND role IN ('original', 'archive') ORDER BY role
                    """).all()
                for f in files {
                    try Task.checkCancellation()
                    let role = try f.decode(column: "role", as: String.self), sha = try f.decode(column: "sha256", as: String.self)
                    let mime = try f.decode(column: "mime", as: String.self), size = try f.decode(column: "size_bytes", as: Int64.self)
                    let path = "documents/\(folder)/\(role)-\(safeName(doc.title)).\(DMSDownload.ext(for: mime))"
                    do {
                        let r = try await zip.add(name: path, stream: try await store.get(try ObjectKey(tenantID: tenant, sha256: sha)))
                        guard r.sha256 == sha, r.size == size else {
                            try await fail(id, tenant: tenant, code: "integrity_failed", on: s)
                            throw PermanentJobError(code: "integrity_failed")
                        }
                    } catch ObjectStoreError.notFound {
                        try await fail(id, tenant: tenant, code: "integrity_failed", on: s)
                        throw PermanentJobError(code: "integrity_failed")
                    } catch is ZIPTooLarge {
                        try await fail(id, tenant: tenant, code: "export_too_large", on: s)
                        throw PermanentJobError(code: "export_too_large")
                    }
                    written.append(FileRow(doc: doc, role: role, sha256: sha, size: size, mime: mime, path: path))
                }
            }
            let index = Data(indexCSV(written).utf8)
            let idx = try await zip.add(name: "index.csv", data: index)
            let chain = try await DMSAuditChain.verify(tenant: tenant, on: s)
            let manifest = try manifestJSON(tenant: tenant, createdAt: createdAt, files: written, index: idx, chain: chain)
            manifestSHA = hex(manifest)
            try await zip.add(name: "manifest.json", data: manifest)
            try zip.finish()
        } catch is ZIPTooLarge {
            try await fail(id, tenant: tenant, code: "export_too_large", on: s)
            throw PermanentJobError(code: "export_too_large")
        } catch let e as PermanentJobError {
            throw e
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if Task.isCancelled { throw CancellationError() }
            if job.attempts >= maxAttempts { try await fail(id, tenant: tenant, code: "export_failed", on: s); throw PermanentJobError(code: "export_failed") }
            throw error
        }

        // ZIP in den Objektspeicher (inhaltsadressiert, idempotent), danach Ergebnis in einer Transaktion
        let stored = try await store.put(tenant: tenant, stream: try fileStream(zipURL), expectedSHA256: nil)
        zipSHA = stored.key.sha256; zipSize = stored.size
        let fileID = try await FileRecordService(s).register(stored, backend: store.kind, contentType: "application/zip")
        guard let database = s as? any Database else { throw PermanentJobError(code: "database_unavailable") }
        let (docCount, fileCount, finalSHA, finalSize, manifestHash) = (docs.count, written.count, zipSHA, zipSize, manifestSHA)
        _ = try await dmsTransaction(database) { _, tx in
            guard try await tx.raw("""
                UPDATE dms_exports SET state = 'done', finished_at = now(), document_count = \(bind: docCount), file_count = \(bind: fileCount), size_bytes = \(bind: finalSize),
                  sha256 = \(bind: finalSHA), manifest_sha256 = \(bind: manifestHash), file_id = \(bind: fileID)
                WHERE tenant_id = \(bind: tenant) AND id = \(bind: id) AND state = 'running' RETURNING id
                """).first() != nil else { return false }
            try await AuditLog.record(AuditEvent(action: "dms.export.completed", tenant: tenant, subjectType: "dms.export", subjectID: id.uuidString,
                                                 meta: ["documents": .number(Int64(docCount)), "files": .number(Int64(fileCount)), "size": .number(finalSize)]), on: tx)
            return true
        }
    }

    // MARK: Inhalt

    static func safeName(_ title: String) -> String {
        let mapped = title.precomposedStringWithCanonicalMapping.unicodeScalars.map { s -> Character in
            (CharacterSet.controlCharacters.contains(s) || "/\\:*?\"<>|".unicodeScalars.contains(s)) ? "_" : Character(s)
        }.map(String.init).joined().trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        return mapped.isEmpty ? "dokument" : String(mapped.prefix(80))
    }

    /// CSV nach RFC 4180 (UTF-8); Zellen, die mit `= + - @` beginnen, werden mit `'` entschärft (Tabellenkalkulations-Injektion).
    static func csv(_ cell: String?) -> String {
        guard var c = cell else { return "" }
        if let f = c.first, "=+-@\t\r".contains(f) { c = "'" + c }
        return c.contains(where: { ",\"\n\r".contains($0) }) ? "\"" + c.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : c
    }

    private static func indexCSV(_ files: [FileRow]) -> String {
        var lines = ["document_id,asn,title,doc_date,document_type,role,path,sha256,size_bytes,mime"]
        for f in files {
            lines.append([f.doc.id.uuidString.lowercased(), f.doc.asn.map(String.init), f.doc.title, f.doc.docDate, f.doc.typeName, f.role, f.path, f.sha256, String(f.size), f.mime]
                .map { csv($0) }.joined(separator: ","))
        }
        return lines.joined(separator: "\r\n") + "\r\n"
    }

    private static func manifestJSON(tenant: UUID, createdAt: Date, files: [FileRow], index: (sha256: String, size: Int64), chain: DMSChainReport) throws -> Data {
        struct Entry: Encodable { let path: String; let sha256: String; let size_bytes: Int64; let role: String; let document_id: String? }
        struct Chain: Encodable { let entries: Int64; let ok: Bool; let head: String }
        struct Manifest: Encodable {
            let format: String; let tenant_id: String; let created_at: String; let hash_algorithm: String; let note: String; let audit_chain: Chain; let files: [Entry]
        }
        var entries = files.map { Entry(path: $0.path, sha256: $0.sha256, size_bytes: $0.size, role: $0.role, document_id: $0.doc.id.uuidString.lowercased()) }
        entries.append(Entry(path: "index.csv", sha256: index.sha256, size_bytes: index.size, role: "index", document_id: nil))
        let m = Manifest(format: format, tenant_id: tenant.uuidString.lowercased(), created_at: iso(createdAt), hash_algorithm: "SHA-256",
                         note: "Prüfzugriff auf den Dokumentenbestand. Keine Aussage zur Konformität mit steuerrechtlichen Vorgaben (GoBD-orientiert).",
                         audit_chain: .init(entries: chain.entries, ok: chain.ok, head: chain.head), files: entries)
        let e = JSONEncoder(); e.outputFormatting = [.sortedKeys, .prettyPrinted]
        return try e.encode(m)
    }

    private static func hex(_ d: Data) -> String { SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined() }

    private static func fileStream(_ url: URL) throws -> ByteStream {
        let box = UnsafeSendableBox(try FileHandle(forReadingFrom: url))
        return ByteStream(unfolding: {
            guard let d = try box.value.read(upToCount: objectStoreChunkSize), !d.isEmpty else { try? box.value.close(); return nil }
            return ByteBuffer(data: d)
        })
    }
}
