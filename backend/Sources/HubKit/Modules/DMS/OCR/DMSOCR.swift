import Vapor
import Fluent
import SQLKit
import NIOCore

// WP-O2: Job `dms.ocr` (MODUL-DMS 5.2, ADR 0006). Payload `{ingest_item_id, tenant_id}`. Der Handler ist idempotent und „genau einmal“ wirksam:
// Das Ergebnis (Text, Archivdatei, Zustandsübergänge) entsteht in EINER Transaktion unter der Zeilensperre des Ingest-Items; wer den Zustand `ocr_done` oder weiter
// vorfindet, tut nichts (zweiter Worker, wiederholter Job, abgelaufene Lease). Das Original wird nur gelesen.
// Zustandsfolge: hashed -> ocr_queued (Upload, gleiche Transaktion wie der Job) -> ocr_done -> classified -> done. Die Klassifikation (D3) fügt sich zwischen
// ocr_done und classified ein; bis dahin durchläuft der Handler beide Schritte ohne Arbeit, damit ein indiziertes Dokument `done` ist.

struct CreateDMSOCR: AsyncMigration {
    let name = "dms_019_ocr"
    func prepare(on db: any Database) async throws {
        try await run(db, ["ALTER TABLE dms_ingest_items ADD COLUMN job_id uuid"])
    }
    func revert(on db: any Database) async throws {
        try await run(db, ["ALTER TABLE dms_ingest_items DROP COLUMN job_id"])
    }
}

struct DMSProcessingOut: Content, Sendable {
    struct Step: Content, Sendable { let state: String; let at: String }
    struct TextInfo: Content, Sendable { let engine: String; let lang: String; let version: Int; let characters: Int }
    let document_id: UUID
    let ingest_item_id: UUID?
    /// Ingest-Zustand (`none`, wenn es keinen Eingangsvorgang gibt).
    let state: String
    /// Für die Anzeige: none, pending, queued, processing, done, retrying, failed.
    let phase: String
    let error_code: String?
    let steps: [Step]
    let text: TextInfo?
    let has_archive: Bool
    let updated_at: String?
}

enum DMSOCR {
    static let kind = "dms.ocr"
    static let maxAttempts = 3
    static let priorityManual = 10   // Uploads durch Nutzer vor Massenimport (Priorität 0)
    static let priorityBulk = 0

    private struct Payload: Codable { let ingest_item_id: UUID; let tenant_id: UUID }

    // MARK: Einreihen

    /// Setzt das Item auf `ocr_queued` und legt den Job an (eine Transaktion des Aufrufers). Nur der Aufruf, der den Übergang vollzieht, legt den Job an.
    @discardableResult
    static func enqueue(item: UUID, tenant: UUID, priority: Int, on s: any SQLDatabase) async throws -> UUID? {
        guard try await DMSIngest.advance(item, tenant: tenant, to: .ocrQueued, on: s) else { return nil }
        let payload = String(decoding: try JSONEncoder().encode(Payload(ingest_item_id: item, tenant_id: tenant)), as: UTF8.self)
        let job = try await JobService(s).enqueue(kind: kind, payload: payload, priority: priority)
        try await s.raw("UPDATE dms_ingest_items SET job_id = \(bind: job) WHERE tenant_id = \(bind: tenant) AND id = \(bind: item)").run()
        return job
    }

    // MARK: Manuelles Wiederholen (WP-H6)

    /// Setzt den dauerhaft fehlgeschlagenen (`failed_permanent`) Eingangsvorgang des Dokuments zurück und reiht einen neuen OCR-Job ein
    /// (alles in einer Transaktion, Audit `dms.ingest.retried`). Kein solcher Vorgang: 409 `ingest_not_failed`; Papierkorb: 409 `document_trashed`;
    /// fremdes/unbekanntes Dokument: 404. Zwei gleichzeitige Aufrufe: genau einer wirkt (Zeilensperre), der andere erhält 409.
    static func retryPermanent(document: UUID, tenant: UUID, actor: UUID, requestID: String, priority: Int, on db: any Database) async throws -> DMSProcessingOut {
        try await dmsTransaction(db) { _, s in
            guard let doc = try await s.raw("SELECT trashed_at FROM dms_documents WHERE tenant_id = \(bind: tenant) AND id = \(bind: document) FOR SHARE").first()
            else { throw DMSError.notFound }
            if try doc.decode(column: "trashed_at", as: Date?.self) != nil { throw DMSError.trashed }
            guard let row = try await s.raw("""
                SELECT id FROM dms_ingest_items WHERE tenant_id = \(bind: tenant) AND document_id = \(bind: document) AND state = 'failed_permanent'
                ORDER BY created_at DESC, id DESC LIMIT 1
                """).first() else { throw HubError(.conflict, "ingest_not_failed") }
            let item = try row.decode(column: "id", as: UUID.self)
            guard try await DMSIngest.retry(item, tenant: tenant, on: s) else { throw HubError(.conflict, "ingest_not_failed") }
            let state = try await s.raw("SELECT state FROM dms_ingest_items WHERE tenant_id = \(bind: tenant) AND id = \(bind: item)").first()?.decode(column: "state", as: String.self)
            var queued = false
            if state == "ocr_queued" || state == "hashed" {
                if state == "ocr_queued" {
                    // der alte Job ist `failed_permanent`: zurück auf `hashed`, damit `enqueue` den Übergang vollzieht und einen neuen Job anlegt
                    try await s.raw("UPDATE dms_ingest_items SET state = 'hashed', updated_at = now() WHERE tenant_id = \(bind: tenant) AND id = \(bind: item)").run()
                }
                queued = try await enqueue(item: item, tenant: tenant, priority: priority, on: s) != nil
            }
            try await AuditLog.record(AuditEvent(action: "dms.ingest.retried", actor: actor, tenant: tenant, subjectType: "dms.ingest_item", subjectID: item.uuidString,
                                                 meta: ["queued": .number(queued ? 1 : 0)], requestID: requestID), on: s)
            guard let out = try await status(document: document, tenant: tenant, on: s) else { throw DMSError.notFound }
            return out
        }
    }

    // MARK: Handler

    /// `storeFactory` liefert den Objektspeicher aus der Worker-Umgebung. `tempRoot`: tmpfs (Arbeitsverzeichnis je Auftrag, wird immer entfernt).
    static func handler(engine: any OCRExtracting, tempRoot: String, storeFactory: @escaping @Sendable (any SQLDatabase) throws -> any ObjectStore) -> JobHandler {
        return { job, s in
            guard let payload = try? JSONDecoder().decode(Payload.self, from: Data(job.payload.utf8)) else { throw PermanentJobError(code: "payload_invalid") }
            try await process(job: job, payload: payload, engine: engine, tempRoot: tempRoot, store: try storeFactory(s), s: s)
        }
    }

    private static func process(job: ClaimedJob, payload: Payload, engine: any OCRExtracting, tempRoot: String, store: any ObjectStore, s: any SQLDatabase) async throws {
        let tenant = payload.tenant_id, item = payload.ingest_item_id
        guard let row = try await s.raw("SELECT state, document_id FROM dms_ingest_items WHERE tenant_id = \(bind: tenant) AND id = \(bind: item)").first(),
              let document = try row.decode(column: "document_id", as: UUID?.self)
        else { throw PermanentJobError(code: "ingest_item_missing") }
        switch try row.decode(column: "state", as: String.self) {
        case "ocr_done", "classified", "done", "failed_permanent": return       // schon erledigt bzw. in Quarantäne: nichts tun (idempotent)
        case "failed_retryable": _ = try await DMSIngest.retry(item, tenant: tenant, on: s)
        case "hashed": _ = try await DMSIngest.advance(item, tenant: tenant, to: .ocrQueued, on: s)
        case "ocr_queued": break
        default: throw PermanentJobError(code: "ingest_state_invalid")
        }
        guard let file = try await s.raw("""
            SELECT sha256, mime FROM dms_document_files WHERE tenant_id = \(bind: tenant) AND document_id = \(bind: document) AND role = 'original'
            """).first() else { try await giveUp(item, tenant: tenant, code: "original_missing", job: job, permanent: true, on: s); throw PermanentJobError(code: "original_missing") }
        let sha = try file.decode(column: "sha256", as: String.self), mime = try file.decode(column: "mime", as: String.self)

        let workDir = URL(fileURLWithPath: tempRoot, isDirectory: true).appendingPathComponent("lh-ocr-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: workDir) }

        let extraction: OCRExtraction
        do {
            let input = workDir.appendingPathComponent("input")
            try await copy(try await store.get(try ObjectKey(tenantID: tenant, sha256: sha)), to: input)
            extraction = try await engine.extract(input: input, mime: mime, workDir: workDir)
        } catch is CancellationError {
            throw CancellationError()
        } catch let f as OCRFailure {
            let final = f.permanent || job.attempts >= maxAttempts
            try await giveUp(item, tenant: tenant, code: f.code, job: job, permanent: final, on: s)
            if f.permanent { throw PermanentJobError(code: f.code) }
            throw f
        } catch ObjectStoreError.notFound {
            try await giveUp(item, tenant: tenant, code: "original_missing", job: job, permanent: true, on: s)
            throw PermanentJobError(code: "original_missing")
        } catch {
            if Task.isCancelled { throw CancellationError() }
            try await giveUp(item, tenant: tenant, code: "ocr_failed", job: job, permanent: job.attempts >= maxAttempts, on: s)
            throw error
        }

        // Archivdatei in den Objektspeicher (inhaltsadressiert, idempotent), danach alles Weitere in einer Transaktion
        let archive: (stored: StoredObject, fileID: UUID)?
        if let url = extraction.archive {
            let stored = try await store.put(tenant: tenant, stream: try fileStream(url), expectedSHA256: nil)
            archive = (stored, try await FileRecordService(s).register(stored, backend: store.kind, contentType: "application/pdf"))
        } else { archive = nil }
        guard let database = s as? any Database else { throw OCRFailure(code: "database_unavailable", permanent: false) }
        _ = try await dmsTransaction(database) { txDB, tx in
            guard let cur = try await tx.raw("SELECT state FROM dms_ingest_items WHERE tenant_id = \(bind: tenant) AND id = \(bind: item) FOR UPDATE").first() else { return false }
            let state = try cur.decode(column: "state", as: String.self)
            guard state == "ocr_queued" else { return false }   // ein anderer Worker war schneller (oder Item steht im Fehlerzustand): kein zweites Ergebnis
            try await DMSTexts.add(document: document, tenant: tenant, engine: extraction.engine, lang: extraction.lang, text: extraction.text, on: txDB)
            if let archive {
                try await tx.raw("""
                    INSERT INTO dms_document_files (tenant_id, document_id, role, file_id, mime, size_bytes, sha256, page_count)
                    VALUES (\(bind: tenant), \(bind: document), 'archive', \(bind: archive.fileID), 'application/pdf', \(bind: archive.stored.size), \(bind: archive.stored.key.sha256), \(bind: extraction.pages))
                    ON CONFLICT (document_id, role) WHERE role IN ('archive', 'thumbnail') DO NOTHING
                    """).run()
            }
            if let pages = extraction.pages {
                try await tx.raw("UPDATE dms_document_files SET page_count = COALESCE(page_count, \(bind: pages)) WHERE tenant_id = \(bind: tenant) AND document_id = \(bind: document) AND role = 'archive'").run()
            }
            try await DMSIngest.advance(item, tenant: tenant, to: .ocrDone, on: tx)
            // WP-D3: Klassifikation (Regeln, Kontakt-Matching, Duplikate) zwischen ocr_done und classified, in derselben Transaktion unter der Zeilensperre des Items
            try await DMSClassify.run(item: item, document: document, tenant: tenant, text: extraction.text, on: txDB)
            for next in [DMSIngest.State.classified, .done] { try await DMSIngest.advance(item, tenant: tenant, to: next, on: tx) }
            try await AuditLog.record(AuditEvent(action: "dms.ingest.ocr_done", actor: nil, tenant: tenant, subjectType: "dms.ingest_item", subjectID: item.uuidString,
                                                 meta: ["engine": .safe(extraction.engine), "ocr": .number(extraction.usedOCR ? 1 : 0), "pdfa": .number(extraction.pdfa ? 1 : 0),
                                                        "pages": .number(Int64(extraction.pages ?? 0)), "characters": .number(Int64(extraction.text.count))]), on: tx)
            return true
        }
    }

    /// Fehler im Ingest-Item festhalten (endgültig oder wiederholbar). Aus `done` oder bei gleichem Zustand ohne Wirkung.
    private static func giveUp(_ item: UUID, tenant: UUID, code: String, job: ClaimedJob, permanent: Bool, on s: any SQLDatabase) async throws {
        _ = try await DMSIngest.fail(item, tenant: tenant, code: code, retryable: !permanent, on: s)
    }

    // MARK: Dateien

    private static func copy(_ stream: ByteStream, to url: URL) async throws {
        guard FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw OCRFailure(code: "workdir_unwritable", permanent: false) }
        let h = try FileHandle(forWritingTo: url)
        defer { try? h.close() }
        for try await chunk in stream { try h.write(contentsOf: Data(buffer: chunk)) }
    }

    private static func fileStream(_ url: URL) throws -> ByteStream {
        let box = UnsafeSendableBox(try FileHandle(forReadingFrom: url))
        return ByteStream(unfolding: {
            guard let d = try box.value.read(upToCount: objectStoreChunkSize), !d.isEmpty else { try? box.value.close(); return nil }
            return ByteBuffer(data: d)
        })
    }

    // MARK: Status (GET documents/{id}/processing)

    static func status(document: UUID, tenant: UUID, on s: any SQLDatabase) async throws -> DMSProcessingOut? {
        guard try await s.raw("SELECT 1 AS x FROM dms_documents WHERE tenant_id = \(bind: tenant) AND id = \(bind: document)").first() != nil else { return nil }
        let archive = try await s.raw("SELECT 1 AS x FROM dms_document_files WHERE tenant_id = \(bind: tenant) AND document_id = \(bind: document) AND role = 'archive'").first() != nil
        var textInfo: DMSProcessingOut.TextInfo?
        if let t = try await s.raw("""
            SELECT engine, lang, version, char_length(text) AS n FROM dms_document_texts WHERE tenant_id = \(bind: tenant) AND document_id = \(bind: document)
            ORDER BY version DESC LIMIT 1
            """).first() {
            textInfo = .init(engine: try t.decode(column: "engine", as: String.self), lang: try t.decode(column: "lang", as: String.self),
                             version: Int(try t.decode(column: "version", as: Int32.self)), characters: Int(try t.decode(column: "n", as: Int32.self)))
        }
        guard let row = try await s.raw("""
            SELECT i.id, i.state, i.error_code, i.updated_at, (SELECT j.state FROM jobs j WHERE j.id = i.job_id) AS job_state
            FROM dms_ingest_items i WHERE i.tenant_id = \(bind: tenant) AND i.document_id = \(bind: document) ORDER BY i.created_at DESC, i.id DESC LIMIT 1
            """).first() else {
            return DMSProcessingOut(document_id: document, ingest_item_id: nil, state: "none", phase: "none", error_code: nil, steps: [], text: textInfo, has_archive: archive, updated_at: nil)
        }
        let id = try row.decode(column: "id", as: UUID.self), state = try row.decode(column: "state", as: String.self)
        let jobState = try row.decode(column: "job_state", as: String?.self)
        let phase: String
        switch state {
        case "received", "stored", "hashed": phase = "pending"
        case "ocr_queued": phase = jobState == "running" ? "processing" : "queued"
        case "ocr_done", "classified": phase = "processing"
        case "done": phase = "done"
        case "failed_retryable": phase = "retrying"
        default: phase = "failed"
        }
        let steps = try await s.raw("SELECT state, at FROM dms_ingest_transitions WHERE tenant_id = \(bind: tenant) AND ingest_item_id = \(bind: id) ").all()
            .map { DMSProcessingOut.Step(state: try $0.decode(column: "state", as: String.self), at: iso(try $0.decode(column: "at", as: Date.self))) }
            .sorted { (DMSIngest.State(rawValue: $0.state)?.index ?? 99) < (DMSIngest.State(rawValue: $1.state)?.index ?? 99) }
        return DMSProcessingOut(document_id: document, ingest_item_id: id, state: state, phase: phase, error_code: try row.decode(column: "error_code", as: String?.self),
                                steps: steps, text: textInfo, has_archive: archive, updated_at: iso(try row.decode(column: "updated_at", as: Date.self)))
    }
}
