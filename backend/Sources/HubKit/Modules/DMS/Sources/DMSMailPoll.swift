import Vapor
import Fluent
import SQLKit
import Crypto

// WP-D4: Job `dms.mail.poll` (Payload `{source_id, tenant_id}`). Ein Lauf = eine IMAP-Sitzung (implizites TLS), keine offenen Ports, kein Dauerprozess.
// Ablauf je Nachricht: `UID SEARCH UNSEEN` -> `UID FETCH BODY.PEEK[]` -> Anhänge (erlaubte Typen per Magic Bytes) und optional der Mailtext als PDF
// in die Aufnahme -> ERST NACH dem Commit der Dokumente die Nachricht als gelesen markieren und (falls konfiguriert) in `processed_mailbox` verschieben.
// Nie löschen. Stürzt der Lauf zwischen Commit und Markieren ab, findet die Wiederholung die Idempotenz-Einträge (Message-ID + Anhang-Hash) und legt nichts doppelt an.
// Fehler eines Laufs (Verbindung, Anmeldung, TLS) werden an der Quelle festgehalten und der nächste Lauf eingeplant (Rückstau mit steigendem Abstand);
// der Job selbst endet normal, damit die Job-Kette nie in der Quarantäne abreißt. Das Passwort wird nur im Speicher entschlüsselt und taucht in keinem Log auf.

enum DMSMailPoll {
    static let kind = "dms.mail.poll"

    static func handler(storeConfig: @escaping @Sendable () throws -> ObjectStoreConfig, box: SecretBox?, imap: IMAPOptions, limits: DMSSourceLimits) -> JobHandler {
        return { job, s in
            guard let payload = try? JSONDecoder().decode(DMSSources.SourcePayload.self, from: Data(job.payload.utf8)) else { throw PermanentJobError(code: "payload_invalid") }
            guard let db = s as? any Database else { throw PermanentJobError(code: "database_unavailable") }
            try await run(job: job, payload: payload, storeConfig: storeConfig, box: box, imap: imap, limits: limits, db: db, s: s)
        }
    }

    /// Zähler eines Laufs (die IMAP-Sitzung läuft in einer nebenläufigen Closure).
    final class Tally: @unchecked Sendable {
        private(set) var stats: [String: Int] = ["messages": 0, "ingested": 0, "duplicates": 0, "skipped": 0, "failed": 0]
        private(set) var failure: String?
        func add(_ key: String, _ n: Int) { stats[key, default: 0] += n }
        func fail(_ code: String) { if failure == nil { failure = code } }
    }

    private static func run(job: ClaimedJob, payload: DMSSources.SourcePayload, storeConfig: () throws -> ObjectStoreConfig, box: SecretBox?, imap: IMAPOptions,
                            limits: DMSSourceLimits, db: any Database, s: any SQLDatabase) async throws {
        let tenant = payload.tenant_id
        guard let source = try await DMSSources.row(payload.source_id, tenant: tenant, on: s), source.kind == .mail, source.enabled,
              try await DMSSources.dmsActive(tenant: tenant, on: s) else { return }   // gelöscht/abgeschaltet: Kette endet
        let config = try source.decode(MailSourceConfig.self)
        let tally = Tally()
        var failure: String?
        do {
            guard let box else { throw IMAPError(code: "secret_key_missing") }
            guard let sealed = source.secretEnc else { throw IMAPError(code: "secret_missing") }
            let password: String
            do { password = try box.open(sealed, tenant: tenant, source: source.id) } catch { throw IMAPError(code: "secret_unreadable") }
            let objectStore = try storeConfig()
            try await IMAPClient.withSession(host: config.host, port: config.port, user: config.username, password: password, options: imap) { session in
                try await session.select(config.mailbox)
                let uids = try await session.searchUnseen(from: config.sender_contains, subject: config.subject_contains)
                for uid in uids.prefix(config.max_per_run) {
                    try Task.checkCancellation()
                    tally.add("messages", 1)
                    if let size = try await session.size(of: uid), size > imap.maxMessageBytes { tally.add("skipped", 1); tally.add("failed", 1); try await settle(uid, session, config); continue }
                    let raw = try await session.fetch(uid)
                    let result = try await process(raw: raw, source: source, config: config, limits: limits, objectStore: objectStore, db: db, requestID: "mail-\(job.id.uuidString.prefix(8).lowercased())")
                    tally.add("ingested", result.ingested); tally.add("duplicates", result.duplicates)
                    tally.add("skipped", result.skipped); tally.add("failed", result.failed)
                    if result.failed == 0 { try await settle(uid, session, config) }   // fehlgeschlagene (z. B. Quota) bleiben ungelesen und werden wiederholt
                    else { tally.fail(result.errorCode ?? "ingest_failed") }
                }
            }
            failure = tally.failure
        } catch is CancellationError {
            throw CancellationError()
        } catch let e as IMAPError {
            failure = e.code
        } catch let e as HubError {
            failure = e.code == "storage_quota_exceeded" ? "storage_quota_exceeded" : "ingest_failed"
        } catch {
            failure = "poll_failed"
        }
        try await finish(source: source, job: job, stats: tally.stats, failure: failure ?? tally.failure, config: config, db: db, s: s)
    }

    /// Markiert als gelesen und verschiebt (nie löschen). Fehler hier brechen den Lauf nicht ab: die Idempotenz verhindert Doppelaufnahme.
    private static func settle(_ uid: UInt32, _ session: IMAPSession, _ config: MailSourceConfig) async throws {
        try await session.markSeen(uid)
        if let target = config.processed_mailbox, !target.isEmpty { try await session.moveOrCopy(uid, to: target) }
    }

    struct MessageResult { var ingested = 0, duplicates = 0, skipped = 0, failed = 0; var errorCode: String? }

    /// Verarbeitet eine Nachricht (ohne IMAP). Ein Element, das nach dem Commit erneut kommt, zählt als Duplikat.
    static func process(raw: Data, source: DMSSourceRow, config: MailSourceConfig, limits: DMSSourceLimits, objectStore: ObjectStoreConfig, db: any Database, requestID: String) async throws -> MessageResult {
        let mail = MailParser.parse(raw)
        let messageKey = mail.messageID ?? "nomsgid:" + DMSSourceIngest.itemKey(String(decoding: raw.prefix(4096), as: UTF8.self), "\(raw.count)")
        let idRef = String(messageKey.prefix(300))
        var result = MessageResult()
        func note(_ outcome: SourceIngestOutcome) {
            switch outcome {
            case .ingested: result.ingested += 1
            case .duplicate: result.duplicates += 1
            case .unsupportedType, .tooLarge: result.skipped += 1
            }
        }
        func attempt(_ work: () async throws -> SourceIngestOutcome) async {
            do { note(try await work()) } catch let e as HubError { result.failed += 1; result.errorCode = e.code == "storage_quota_exceeded" ? e.code : "ingest_failed" } catch { result.failed += 1; result.errorCode = "ingest_failed" }
        }
        var index = 0
        for attachment in mail.attachments {
            index += 1
            if attachment.isInline, attachment.hasContentID { result.skipped += 1; continue }   // eingebettete Bilder (Signaturen, Logos)
            let name = DMSSourceIngest.cleanName(attachment.filename)
            await attempt {
                try await DMSSourceIngest.ingest(bytes: attachment.data, filename: name, title: DMSSourceIngest.title(fromFilename: name, fallback: "Mailanhang"),
                                                 itemKey: { DMSSourceIngest.itemKey("mail", messageKey, $0) }, sender: mail.from, originRef: "mail:\(idRef)#\(index)",
                                                 source: source, ingestSource: .mail, limits: limits, config: objectStore, requestID: requestID, db: db)
            }
        }
        if config.include_body, let body = mail.textBody?.trimmingCharacters(in: .whitespacesAndNewlines), !body.isEmpty {
            let pdf = MailBodyPDF.render(subject: mail.subject, from: mail.from, date: mail.date, body: body)
            await attempt {
                try await DMSSourceIngest.ingest(bytes: pdf, filename: "mail.pdf", title: String((mail.subject?.isEmpty == false ? mail.subject! : "Mail").prefix(300)),
                                                 itemKey: { _ in DMSSourceIngest.itemKey("mailbody", messageKey) }, sender: mail.from, originRef: "mail:\(idRef)#body",
                                                 source: source, ingestSource: .mail, limits: limits, config: objectStore, requestID: requestID, db: db)
            }
        }
        return result
    }

    private static func finish(source: DMSSourceRow, job: ClaimedJob, stats: [String: Int], failure: String?, config: MailSourceConfig, db: any Database, s: any SQLDatabase) async throws {
        let tenant = source.tenant
        // Rückstau bei Fehlern: Intervall * 2^(Folgefehler), höchstens 1 Stunde (Folgefehler = Fehler im letzten Lauf -> grob verdoppeln)
        var computed = config.interval_seconds
        if failure != nil {
            let previousError = try await s.raw("SELECT last_status = 'error' AS e FROM dms_sources WHERE tenant_id = \(bind: tenant) AND id = \(bind: source.id)").first()?.decode(column: "e", as: Bool?.self) ?? false
            computed = min(3600, config.interval_seconds * ((previousError ?? false) ? 4 : 2))
        }
        let delay = computed
        _ = try await dmsTransaction(db) { _, t in
            try await DMSSources.record(source.id, tenant: tenant, stats: stats, error: failure, on: t)
            try await DMSSources.schedule(source: source.id, tenant: tenant, delaySeconds: delay, expedite: false, afterJob: job.id, on: t)
            return 0
        }
    }
}
