import Vapor
import Fluent
import SQLKit
import Crypto
import NIOCore

// WP-D4: gemeinsamer Eingang für Quellen (Mail, Konsumordner): Magic Bytes, Dedup über den Objektspeicher, Quota, Idempotenz je Quelle
// (`dms_source_items`), Ingest-Vorgang mit Quelle und Absender. Das Dokument und der Idempotenz-Eintrag entstehen in EINER Transaktion:
// ein Absturz davor hinterlässt höchstens einen unreferenzierten Blob (H6-Aufräumen), nie ein halbes Dokument; eine Wiederholung findet den Eintrag.

struct DMSSourceLimits: Sendable {
    var maxUploadBytes: Int64 = 100 * 1024 * 1024
    var quotaBytes: Int64 = 1024 * 1024 * 1024 * 1024
    var ocrEnabled = true

    static func fromEnvironment(_ env: [String: String] = ProcessInfo.processInfo.environment) -> DMSSourceLimits {
        var l = DMSSourceLimits()
        if let v = env["DMS_MAX_UPLOAD_BYTES"].flatMap(Int64.init), v > 0 { l.maxUploadBytes = v }
        if let v = env["DMS_TENANT_QUOTA_BYTES"].flatMap(Int64.init), v > 0 { l.quotaBytes = v }
        l.ocrEnabled = env["DMS_OCR_ENABLED"] != "false"
        return l
    }
}

enum SourceIngestOutcome: Sendable, Equatable {
    case ingested(UUID)
    case duplicate          // Idempotenz: dieses Element wurde bei dieser Quelle schon aufgenommen
    case unsupportedType    // keine erlaubte Dateiart (Magic Bytes)
    case tooLarge
}

enum DMSSourceIngest {
    static func itemKey(_ parts: String...) -> String {
        SHA256.hash(data: Data(parts.joined(separator: "\u{1F}").utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func title(fromFilename name: String?, fallback: String) -> String {
        let stem = name.map { ($0 as NSString).deletingPathExtension }?.trimmingCharacters(in: .whitespaces) ?? ""
        return stem.isEmpty ? fallback : String(stem.prefix(300))
    }

    /// Nur Dateiname, keine Pfade/Steuerzeichen, höchstens 255 Zeichen; sonst nil.
    static func cleanName(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let base = raw.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? ""
        let c = String(base.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }).trimmingCharacters(in: .whitespaces)
        return c.isEmpty || c.count > 255 ? nil : c.precomposedStringWithCanonicalMapping
    }

    /// WP-D7: Text einer Mail (Kopfzeilen + Mailtext, schon aus HTML abgeleitet) und der HTML-Teil als Derivat. Statt eines OCR-Jobs läuft der Textschritt
    /// (Index, Klassifikation, Extraktion) in derselben Transaktion wie die Aufnahme: Zustandsfolge hashed -> ocr_queued -> ocr_done -> classified -> done.
    struct MailText: Sendable {
        let text: String
        let html: Data?
    }

    typealias AfterCreate = @Sendable (_ document: UUID, _ db: any Database) async throws -> Void

    static func stream(_ bytes: Data) -> ByteStream {
        let offset = UnsafeSendableBox(0)
        return ByteStream(unfolding: {
            guard offset.value < bytes.count else { return nil }
            let end = min(offset.value + objectStoreChunkSize, bytes.count)
            defer { offset.value = end }
            return ByteBuffer(data: bytes[offset.value..<end])
        })
    }

    /// Dokument-ID eines schon aufgenommenen Elements (Idempotenz-Eintrag), sonst nil.
    static func existingDocument(source: DMSSourceRow, key: String, db: any Database) async throws -> UUID? {
        try await sql(db).raw("SELECT document_id FROM dms_source_items WHERE tenant_id = \(bind: source.tenant) AND source_id = \(bind: source.id) AND item_key = \(bind: key)").first()?
            .decode(column: "document_id", as: UUID?.self)
    }

    /// Nimmt eine Datei (Bytes im Speicher) auf. `itemKey` bestimmt die Idempotenz. Die Datei wird zuerst im Objektspeicher abgelegt (Dedup, Hash),
    /// danach in einer Transaktion Idempotenz-Eintrag + Dokument. Bei Duplikat/Fehler wird ein unreferenzierter Blob wieder entfernt.
    /// `kind`: feste Dateiart (die Mail selbst als `.eml`), sonst Erkennung am Dateianfang.
    static func ingest(bytes: Data, filename: String?, title: String, itemKey: (_ contentSHA256: String) -> String, sender: String?, originRef: String,
                       source: DMSSourceRow, ingestSource: DMSIngest.Source, limits: DMSSourceLimits, config: ObjectStoreConfig, requestID: String,
                       kind forced: DMSFileKind? = nil, mail: MailText? = nil, afterCreate: AfterCreate? = nil,
                       db: any Database) async throws -> SourceIngestOutcome {
        guard Int64(bytes.count) <= limits.maxUploadBytes else { return .tooLarge }
        guard let kind = forced ?? DMSFileKind.sniff(Array(bytes.prefix(DMSFileKind.sniffLength))) else { return .unsupportedType }
        return try await ingest(stream: stream(bytes), kind: kind, filename: filename, title: title, itemKey: itemKey, sender: sender, originRef: originRef, source: source,
                                ingestSource: ingestSource, limits: limits, config: config, requestID: requestID, mail: mail, afterCreate: afterCreate, db: db)
    }

    static func ingest(stream: ByteStream, kind: DMSFileKind, filename: String?, title: String, itemKey: (_ contentSHA256: String) -> String, sender: String?, originRef: String,
                       source: DMSSourceRow, ingestSource: DMSIngest.Source, limits: DMSSourceLimits, config: ObjectStoreConfig, requestID: String,
                       mail: MailText? = nil, afterCreate: AfterCreate? = nil,
                       db: any Database) async throws -> SourceIngestOutcome {
        let s = try sql(db)
        let store = try config.makeStore(db: s)
        let stored = try await store.put(tenant: source.tenant, stream: stream, expectedSHA256: nil)
        let html: (stored: StoredObject, name: String)?
        if let data = mail?.html, !data.isEmpty { html = (try await store.put(tenant: source.tenant, stream: Self.stream(data), expectedSHA256: nil), "mail.html") } else { html = nil }
        let key = itemKey(stored.key.sha256)
        let tenant = source.tenant, sourceID = source.id, actor = source.createdBy
        func discard() async {
            await DMSUpload.discardIfUnreferenced(stored.key, config: config, db: db, logger: Logger(label: "dms.source"))
            if let html { await DMSUpload.discardIfUnreferenced(html.stored.key, config: config, db: db, logger: Logger(label: "dms.source")) }
        }
        do {
            let result: UUID? = try await dmsTransaction(db) { tx, t in
                // Idempotenz zuerst: wer den Eintrag nicht anlegen kann, hat das Element schon aufgenommen.
                guard try await t.raw("""
                    INSERT INTO dms_source_items (tenant_id, source_id, item_key) VALUES (\(bind: tenant), \(bind: sourceID), \(bind: key))
                    ON CONFLICT (source_id, item_key) DO NOTHING RETURNING item_key
                    """).first() != nil else { return nil }
                let doc = try await DMSDocuments.create(
                    tenant: tenant, actor: actor, requestID: requestID,
                    doc: .init(title: title, docDate: nil, typeID: nil, originalName: filename, archive: false, kind: kind, stored: stored, backend: store.kind,
                               quotaBytes: limits.quotaBytes, verifyBlob: { t in try await config.makeStore(db: t).exists(stored.key) },
                               ocrPriority: (limits.ocrEnabled && mail == nil) ? DMSOCR.priorityBulk : nil, ingestSource: ingestSource, originRef: String(originRef.prefix(500)), sender: sender), on: tx)
                try await t.raw("UPDATE dms_source_items SET document_id = \(bind: doc.id) WHERE source_id = \(bind: sourceID) AND item_key = \(bind: key)").run()
                if let mail, let item = doc.ingest_item_id {
                    if let html {
                        let fileID = try await FileRecordService(t).register(html.stored, backend: store.kind, contentType: "text/html")
                        try await t.raw("""
                            INSERT INTO dms_document_files (tenant_id, document_id, role, file_id, mime, size_bytes, sha256, original_name)
                            VALUES (\(bind: tenant), \(bind: doc.id), 'derivative', \(bind: fileID), 'text/html', \(bind: html.stored.size), \(bind: html.stored.key.sha256), \(bind: html.name))
                            """).run()
                    }
                    try await DMSIngest.advance(item, tenant: tenant, to: .ocrQueued, on: t)
                    if !mail.text.isEmpty { try await DMSTexts.add(document: doc.id, tenant: tenant, engine: "mail", lang: OCRToolEngine.detectLanguage(mail.text), text: mail.text, on: tx) }
                    try await DMSIngest.advance(item, tenant: tenant, to: .ocrDone, on: t)
                    try await DMSTextStep.complete(item: item, document: doc.id, tenant: tenant, text: mail.text, requestID: requestID, on: tx)
                    for next in [DMSIngest.State.classified, .done] { try await DMSIngest.advance(item, tenant: tenant, to: next, on: t) }
                    try await AuditLog.record(AuditEvent(action: "dms.ingest.text_done", actor: nil, tenant: tenant, subjectType: "dms.ingest_item", subjectID: item.uuidString,
                                                         meta: ["engine": .safe("mail"), "characters": .number(Int64(mail.text.count)), "html": .number(html == nil ? 0 : 1)], requestID: requestID), on: t)
                }
                if let afterCreate { try await afterCreate(doc.id, tx) }
                return doc.id
            }
            if let result { return .ingested(result) }
            await discard()
            return .duplicate
        } catch {
            await discard()
            throw error
        }
    }
}
