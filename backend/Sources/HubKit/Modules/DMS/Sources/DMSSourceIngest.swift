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

    /// Nimmt eine Datei (Bytes im Speicher) auf. `itemKey` bestimmt die Idempotenz. Die Datei wird zuerst im Objektspeicher abgelegt (Dedup, Hash),
    /// danach in einer Transaktion Idempotenz-Eintrag + Dokument. Bei Duplikat/Fehler wird ein unreferenzierter Blob wieder entfernt.
    static func ingest(bytes: Data, filename: String?, title: String, itemKey: (_ contentSHA256: String) -> String, sender: String?, originRef: String,
                       source: DMSSourceRow, ingestSource: DMSIngest.Source, limits: DMSSourceLimits, config: ObjectStoreConfig, requestID: String,
                       db: any Database) async throws -> SourceIngestOutcome {
        guard Int64(bytes.count) <= limits.maxUploadBytes else { return .tooLarge }
        guard let kind = DMSFileKind.sniff(Array(bytes.prefix(DMSFileKind.sniffLength))) else { return .unsupportedType }
        let offset = UnsafeSendableBox(0)
        let stream = ByteStream(unfolding: {
            guard offset.value < bytes.count else { return nil }
            let end = min(offset.value + objectStoreChunkSize, bytes.count)
            defer { offset.value = end }
            return ByteBuffer(data: bytes[offset.value..<end])
        })
        return try await ingest(stream: stream, kind: kind, filename: filename, title: title, itemKey: itemKey, sender: sender, originRef: originRef, source: source,
                                ingestSource: ingestSource, limits: limits, config: config, requestID: requestID, db: db)
    }

    static func ingest(stream: ByteStream, kind: DMSFileKind, filename: String?, title: String, itemKey: (_ contentSHA256: String) -> String, sender: String?, originRef: String,
                       source: DMSSourceRow, ingestSource: DMSIngest.Source, limits: DMSSourceLimits, config: ObjectStoreConfig, requestID: String,
                       db: any Database) async throws -> SourceIngestOutcome {
        let s = try sql(db)
        let store = try config.makeStore(db: s)
        let stored = try await store.put(tenant: source.tenant, stream: stream, expectedSHA256: nil)
        let key = itemKey(stored.key.sha256)
        let tenant = source.tenant, sourceID = source.id, actor = source.createdBy
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
                               ocrPriority: limits.ocrEnabled ? DMSOCR.priorityBulk : nil, ingestSource: ingestSource, originRef: String(originRef.prefix(500)), sender: sender), on: tx)
                try await t.raw("UPDATE dms_source_items SET document_id = \(bind: doc.id) WHERE source_id = \(bind: sourceID) AND item_key = \(bind: key)").run()
                return doc.id
            }
            if let result { return .ingested(result) }
            await DMSUpload.discardIfUnreferenced(stored.key, config: config, db: db, logger: Logger(label: "dms.source"))
            return .duplicate
        } catch {
            await DMSUpload.discardIfUnreferenced(stored.key, config: config, db: db, logger: Logger(label: "dms.source"))
            throw error
        }
    }
}
