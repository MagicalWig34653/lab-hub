import Vapor
import Fluent
import SQLKit

// WP-D5 Aufbewahrung und Löschkonzept (MODUL-DMS 8, GoBD-orientiert; ausdrücklich keine Rechtsberatung und keine Konformitätszusage, F-24).
// Frist = Ende des Kalenderjahres von `doc_date` (ohne Belegdatum: Eingangsdatum) plus Jahre. Jahre: `dms_document_types.default_retention_years`, sonst der Standard des
// Betreibers (`DMS_DEFAULT_RETENTION_YEARS`, Standard 10; 0 = keine Frist). Praxiswerte (6/8/10 Jahre) sind Konfiguration, nicht fest verdrahtet.
// Eine manuelle Frist (`retention_until`) kann nur verlängern: wirksam ist immer das Spätere. `legal_hold` sperrt jedes endgültige Löschen.

/// Grund, warum ein endgültiges Löschen (noch) nicht möglich ist; stabile Fehlercodes (409).
enum DMSPurgeBlocker: String, Sendable, CaseIterable {
    case notTrashed = "document_not_trashed"
    case legalHold = "legal_hold"
    case retention = "retention_not_expired"
    case linked = "document_linked"
}

struct DMSRetentionOut: Content, Sendable {
    let document_id: UUID
    let legal_hold: Bool
    /// Wirksames Fristende (`yyyy-MM-dd`); nil = keine Frist.
    let retention_until: String?
    /// Woher die Frist kommt: document_type, default, manual oder none.
    let retention_source: String
    /// Nur die manuell gesetzte Verlängerung.
    let retention_override: String?
    let trashed: Bool
    let blockers: [String]
    let can_purge: Bool
    let note: String
}

struct DMSRetentionBody: Content {
    var legal_hold: Bool?
    var retention_until: String?
}

enum DMSRetention {
    static let note = "Aufbewahrungsfristen sind eine konfigurierbare, GoBD-orientierte Voreinstellung und keine Rechtsberatung oder Konformitätszusage."
    static let defaultYears = 10

    /// Standardjahre aus der Umgebung (0...100), ungültig/leer: 10.
    static func defaultYears(_ env: [String: String]) -> Int {
        env["DMS_DEFAULT_RETENTION_YEARS"].flatMap(Int.init).flatMap { (0...100).contains($0) ? $0 : nil } ?? defaultYears
    }

    struct State: Sendable {
        let documentID: UUID
        let trashed: Bool
        let legalHold: Bool
        let retentionUntil: String?
        let source: String
        let override: String?
        let expired: Bool
        let linked: Bool

        var blockers: [DMSPurgeBlocker] {
            var out: [DMSPurgeBlocker] = []
            if !trashed { out.append(.notTrashed) }
            if legalHold { out.append(.legalHold) }
            if !expired { out.append(.retention) }
            if linked { out.append(.linked) }
            return out
        }
    }

    /// Liest den Aufbewahrungszustand eines Dokuments des Mandanten (mit Zeilensperre, wenn `lock`). Fremd/unbekannt: nil.
    static func state(_ id: UUID, tenant: UUID, defaultYears: Int, lock: Bool, on s: any SQLDatabase) async throws -> State? {
        let suffix: SQLQueryString = lock ? "FOR UPDATE OF d" : ""
        guard let r = try await s.raw("""
            SELECT d.trashed_at IS NOT NULL AS trashed, d.legal_hold, d.retention_until::text AS override,
              dms_retention_end(COALESCE(d.doc_date, (d.received_at AT TIME ZONE 'UTC')::date), COALESCE(t.default_retention_years, \(bind: defaultYears)::integer), NULL)::text AS computed,
              dms_retention_end(COALESCE(d.doc_date, (d.received_at AT TIME ZONE 'UTC')::date), COALESCE(t.default_retention_years, \(bind: defaultYears)::integer), d.retention_until)::text AS effective,
              (t.default_retention_years IS NOT NULL) AS from_type,
              COALESCE(dms_retention_end(COALESCE(d.doc_date, (d.received_at AT TIME ZONE 'UTC')::date), COALESCE(t.default_retention_years, \(bind: defaultYears)::integer), d.retention_until) < current_date, true) AS expired,
              EXISTS (SELECT 1 FROM links l WHERE l.tenant_id = d.tenant_id AND l.removed_at IS NULL
                AND ((l.to_type = 'dms.document' AND l.to_id = d.id) OR (l.from_type = 'dms.document' AND l.from_id = d.id AND l.to_type <> 'contact'))) AS linked
            FROM dms_documents d LEFT JOIN dms_document_types t ON t.tenant_id = d.tenant_id AND t.id = d.document_type_id
            WHERE d.tenant_id = \(bind: tenant) AND d.id = \(bind: id) \(suffix)
            """).first() else { return nil }
        let computed = try r.decode(column: "computed", as: String?.self), effective = try r.decode(column: "effective", as: String?.self)
        let override = try r.decode(column: "override", as: String?.self)
        let source: String
        if effective == nil { source = "none" }
        else if let override, override == effective, override != computed { source = "manual" }
        else { source = try r.decode(column: "from_type", as: Bool.self) ? "document_type" : "default" }
        return State(documentID: id, trashed: try r.decode(column: "trashed", as: Bool.self), legalHold: try r.decode(column: "legal_hold", as: Bool.self),
                     retentionUntil: effective, source: source, override: override, expired: try r.decode(column: "expired", as: Bool.self),
                     linked: try r.decode(column: "linked", as: Bool.self))
    }

    static func out(_ st: State) -> DMSRetentionOut {
        DMSRetentionOut(document_id: st.documentID, legal_hold: st.legalHold, retention_until: st.retentionUntil, retention_source: st.source,
                        retention_override: st.override, trashed: st.trashed, blockers: st.blockers.map(\.rawValue), can_purge: st.blockers.isEmpty, note: note)
    }

    static func get(_ id: UUID, tenant: UUID, defaultYears: Int, on s: any SQLDatabase) async throws -> DMSRetentionOut {
        guard let st = try await state(id, tenant: tenant, defaultYears: defaultYears, lock: false, on: s) else { throw DMSError.notFound }
        return out(st)
    }

    /// Löschsperre setzen/aufheben und Frist verlängern (nie verkürzen). Audit `dms.document.retention_changed` (ohne Inhalte).
    static func update(_ id: UUID, body: DMSRetentionBody, tenant: UUID, actor: UUID, requestID: String, defaultYears: Int, on db: any Database) async throws -> DMSRetentionOut {
        guard body.legal_hold != nil || body.retention_until != nil else { throw DMSError.invalid("legal_hold", "required") }
        let until = try body.retention_until.map { try DMSError.date($0, "retention_until") }
        return try await dmsTransaction(db) { _, s in
            guard let st = try await state(id, tenant: tenant, defaultYears: defaultYears, lock: true, on: s) else { throw DMSError.notFound }
            if let until, let current = st.retentionUntil, until < current { throw DMSError.invalid("retention_until", "shorten_not_allowed") }
            try await s.raw("""
                UPDATE dms_documents SET legal_hold = COALESCE(\(bind: body.legal_hold), legal_hold), retention_until = COALESCE(\(bind: until)::text::date, retention_until),
                  rev = rev + 1, updated_at = now() WHERE tenant_id = \(bind: tenant) AND id = \(bind: id)
                """).run()
            var meta: [String: AuditValue] = [:]
            if let hold = body.legal_hold { meta["legal_hold"] = .number(hold ? 1 : 0) }
            if until != nil { meta["retention_extended"] = .number(1) }
            try await AuditLog.record(AuditEvent(action: "dms.document.retention_changed", actor: actor, tenant: tenant, subjectType: "dms.document", subjectID: id.uuidString,
                                                 meta: meta, requestID: requestID), on: s)
            guard let now = try await state(id, tenant: tenant, defaultYears: defaultYears, lock: false, on: s) else { throw DMSError.notFound }
            return out(now)
        }
    }

    // MARK: Löschprotokoll lesen

    struct LogEntry: Content, Sendable {
        let id: UUID
        let document_id: UUID
        let asn: Int64?
        let document_type_id: UUID?
        let doc_date: String?
        let retention_until: String?
        let original_sha256: String
        let original_size: Int64
        let file_count: Int
        let purged_by: UUID?
        let purged_at: String
    }

    /// Die letzten 100 Einträge, neueste zuerst.
    static func log(tenant: UUID, on s: any SQLDatabase) async throws -> [LogEntry] {
        try await s.raw("""
            SELECT id, document_id, asn, document_type_id, doc_date::text AS doc_date, retention_until::text AS retention_until, original_sha256, original_size, file_count,
              purged_by, purged_at FROM dms_deletion_log WHERE tenant_id = \(bind: tenant) ORDER BY purged_at DESC, id DESC LIMIT 100
            """).all().map { r in
            LogEntry(id: try r.decode(column: "id", as: UUID.self), document_id: try r.decode(column: "document_id", as: UUID.self), asn: try r.decode(column: "asn", as: Int64?.self),
                     document_type_id: try r.decode(column: "document_type_id", as: UUID?.self), doc_date: try r.decode(column: "doc_date", as: String?.self),
                     retention_until: try r.decode(column: "retention_until", as: String?.self), original_sha256: try r.decode(column: "original_sha256", as: String.self),
                     original_size: try r.decode(column: "original_size", as: Int64.self), file_count: Int(try r.decode(column: "file_count", as: Int32.self)),
                     purged_by: try r.decode(column: "purged_by", as: UUID?.self), purged_at: iso(try r.decode(column: "purged_at", as: Date.self)))
        }
    }
}

// MARK: Endgültiges Löschen

struct DMSPurgeOut: Content, Sendable {
    let document_id: UUID
    let purged_at: String
    let files_removed: Int
    let blobs_removed: Int
}

enum DMSPurge {
    /// Alle Tabellen mit Fremdschlüssel auf `dms_documents`, in Löschreihenfolge (Kinder zuerst). Ein Test vergleicht die Liste mit dem Datenbankkatalog:
    /// eine neue Tabelle (z. B. Vorschläge aus D3) muss hier ergänzt werden, sonst schlägt der Test fehl statt das Löschen still zu brechen.
    static let childTables = ["dms_ingest_transitions", "dms_text_shingles", "dms_document_fingerprints", "dms_suggestions", "dms_duplicates", "dms_ingest_items", "dms_document_texts", "dms_document_fields", "dms_document_tags", "dms_document_files"]

    /// `config`: Objektspeicher. Zuerst alles in EINER Transaktion (Prüfung, Löschprotokoll, Zeilen, Audit), danach die Bytes: nur wenn im Mandanten keine
    /// `files`-Zeile mehr auf sie zeigt (Sperre je Blob wie beim Upload, H6). Fällt der Schritt danach aus, bleibt höchstens ein unreferenzierter Blob (Speicherverbrauch, kein Datenverlust).
    static func purge(_ id: UUID, tenant: UUID, actor: UUID, requestID: String, defaultYears: Int, config: ObjectStoreConfig, db: any Database, logger: Logger) async throws -> DMSPurgeOut {
        struct Tx: Sendable { let out: DMSPurgeOut; let candidates: [String] }
        let tx = try await dmsTransaction(db) { _, s -> Tx in
            guard let st = try await DMSRetention.state(id, tenant: tenant, defaultYears: defaultYears, lock: true, on: s) else { throw DMSError.notFound }
            if let first = st.blockers.first { throw HubError(.conflict, first.rawValue) }
            let files = try await s.raw("""
                SELECT file_id, sha256, role, size_bytes FROM dms_document_files WHERE tenant_id = \(bind: tenant) AND document_id = \(bind: id) ORDER BY created_at, id
                """).all()
            guard let original = try files.first(where: { try $0.decode(column: "role", as: String.self) == "original" }) else { throw HubError(.conflict, "conflict") }
            let doc = try await s.raw("SELECT asn, doc_date::text AS doc_date, document_type_id FROM dms_documents WHERE tenant_id = \(bind: tenant) AND id = \(bind: id)").first()
            try await s.raw("""
                INSERT INTO dms_deletion_log (tenant_id, document_id, asn, document_type_id, doc_date, retention_until, original_sha256, original_size, file_count, purged_by)
                VALUES (\(bind: tenant), \(bind: id), \(bind: try doc?.decode(column: "asn", as: Int64?.self)), \(bind: try doc?.decode(column: "document_type_id", as: UUID?.self)),
                        \(bind: try doc?.decode(column: "doc_date", as: String?.self))::text::date, \(bind: st.retentionUntil)::text::date,
                        \(bind: try original.decode(column: "sha256", as: String.self)), \(bind: try original.decode(column: "size_bytes", as: Int64.self)), \(bind: files.count), \(bind: actor))
                """).run()
            let fileIDs = Array(Set(try files.map { try $0.decode(column: "file_id", as: UUID.self) }))
            let hashes = Array(Set(try files.map { try $0.decode(column: "sha256", as: String.self) })).sorted()
            for h in hashes { try await DMSUpload.lockBlob(tenant: tenant, sha256: h, on: s) }   // Reihenfolge wie beim Upload: Blob, dann Zeilen
            // Kinder löschen. Ingest: Übergänge über das Item, alles andere über document_id.
            try await s.raw("""
                DELETE FROM dms_ingest_transitions WHERE tenant_id = \(bind: tenant) AND ingest_item_id IN (SELECT id FROM dms_ingest_items WHERE tenant_id = \(bind: tenant) AND document_id = \(bind: id))
                """).run()
            // WP-D3: Duplikat-Paare, in denen das Dokument das Gegenstück ist (die Spalte document_id löscht die Schleife)
            try await s.raw("DELETE FROM dms_duplicates WHERE tenant_id = \(bind: tenant) AND duplicate_of = \(bind: id)").run()
            for table in childTables.dropFirst() {
                try await s.raw("DELETE FROM \(unsafeRaw: table) WHERE tenant_id = \(bind: tenant) AND document_id = \(bind: id)").run()
            }
            // Verweise des Dokuments (z. B. Korrespondent) bleiben als Historie, gelten aber nicht mehr als aktiv
            try await s.raw("""
                UPDATE links SET removed_at = now() WHERE tenant_id = \(bind: tenant) AND from_type = 'dms.document' AND from_id = \(bind: id) AND removed_at IS NULL
                """).run()
            try await s.raw("DELETE FROM dms_documents WHERE tenant_id = \(bind: tenant) AND id = \(bind: id)").run()
            // Dateizeilen nur löschen, wenn kein anderes Dokument sie nutzt (Dedup); die Bytes folgen nach dem Commit
            var removable: [String] = []
            for fid in fileIDs {
                if try await s.raw("SELECT 1 AS x FROM dms_document_files WHERE file_id = \(bind: fid)").first() == nil,
                   let gone = try await s.raw("DELETE FROM files WHERE id = \(bind: fid) AND tenant_id = \(bind: tenant) RETURNING sha256").first() {
                    removable.append(try gone.decode(column: "sha256", as: String.self))
                }
            }
            let purgedAt = try await s.raw("SELECT purged_at FROM dms_deletion_log WHERE tenant_id = \(bind: tenant) AND document_id = \(bind: id)").first()?.decode(column: "purged_at", as: Date.self) ?? Date()
            try await AuditLog.record(AuditEvent(action: "dms.document.purged", actor: actor, tenant: tenant, subjectType: "dms.document", subjectID: id.uuidString,
                                                 meta: ["files": .number(Int64(files.count)), "blobs": .number(Int64(removable.count))], requestID: requestID), on: s)
            return Tx(out: DMSPurgeOut(document_id: id, purged_at: iso(purgedAt), files_removed: files.count, blobs_removed: 0), candidates: removable)
        }
        var removed = 0
        for sha in tx.candidates {
            do { if try await removeBlobIfUnreferenced(try ObjectKey(tenantID: tenant, sha256: sha), config: config, db: db) { removed += 1 } }
            catch { logger.warning("purge blob cleanup failed", metadata: ["error": .string(String(describing: type(of: error)))]) }
        }
        return DMSPurgeOut(document_id: id, purged_at: tx.out.purged_at, files_removed: tx.out.files_removed, blobs_removed: removed)
    }

    /// Löscht die Bytes nur, wenn im Mandanten keine `files`-Zeile auf (Mandant, Hash) zeigt (unter der Blob-Sperre).
    static func removeBlobIfUnreferenced(_ key: ObjectKey, config: ObjectStoreConfig, db: any Database) async throws -> Bool {
        try await db.transaction { tx in
            let s = try sql(tx)
            try await DMSUpload.lockBlob(tenant: key.tenantID, sha256: key.sha256, on: s)
            guard try await s.raw("SELECT 1 AS x FROM files WHERE tenant_id = \(bind: key.tenantID) AND sha256 = \(bind: key.sha256)").first() == nil else { return false }
            let store = try config.makeStore(db: s)
            guard try await store.exists(key) else { return false }
            try await store.delete(key)
            return true
        }
    }
}
