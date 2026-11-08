import Vapor
import Fluent
import SQLKit
import NIOCore

// WP-D6: der eigentliche Importlauf. Ablauf: Referenzdaten abbilden (Korrespondenten -> Kontakte, Typen, Tags, Speicherpfade, Felder), dann Dokumente seitenweise.
// Jede Wirkung im DMS (Dokument, Dateien, Tags, Felder, Verweis, Notizen, Text, Idempotenz-Eintrag) entsteht in EINER Transaktion; eine Wiederholung findet den
// Eintrag `dms_import_items` und tut nichts. Der Trockenlauf durchläuft dieselben Prüfungen, schreibt aber nur Befunde und Fortschritt des Laufs (keine Inhalte).
// Die Archivnummern werden je Seite vor den Dokumenten mit `CounterService.ensureAtLeast` (Audit `counter.raised`) mindestens auf das Maximum der Seite gehoben,
// so dass ein paralleler Upload nie eine Nummer vergibt, die der Import noch setzen will.

final class DMSImportRunner: @unchecked Sendable {
    struct Cancelled: Error {}
    static let pageSize = 100
    static let maxFindings = 20_000

    struct FieldDef: Sendable { let id: UUID; let hubType: String; let options: [PLOption] }

    let run: DMSImport.RunRow
    let source: any PaperlessSource
    let config: ObjectStoreConfig
    let limits: DMSSourceLimits
    let db: any Database
    let s: any SQLDatabase
    let requestID: String
    let afterDocument: (@Sendable (Int) async throws -> Void)?
    var importing: Bool { run.mode == "import" }
    var tenant: UUID { run.tenant }
    var key: String { source.key }

    private(set) var counts: [String: Int] = [:]
    private(set) var refs = PLReferences()
    private var corr: [Int64: UUID] = [:], types: [Int64: UUID] = [:], tags: [Int64: UUID] = [:], paths: [Int64: UUID] = [:], fields: [Int64: FieldDef] = [:]
    private var seen: [String: [String: UUID]] = [:]
    private var owners = Set<Int64>()
    private var maxASN: Int64 = 0
    private var processed = 0
    private var total: Int?
    private var findingsWritten = 0

    init(run: DMSImport.RunRow, source: any PaperlessSource, config: ObjectStoreConfig, limits: DMSSourceLimits, db: any Database, s: any SQLDatabase, requestID: String,
         afterDocument: (@Sendable (Int) async throws -> Void)?) {
        self.run = run; self.source = source; self.config = config; self.limits = limits; self.db = db; self.s = s; self.requestID = requestID; self.afterDocument = afterDocument
    }

    func count(_ k: String, _ n: Int = 1) { counts[k, default: 0] += n }

    func finding(_ code: String, _ ref: String, _ detail: String? = nil) async throws {
        count("findings_\(code)")
        guard findingsWritten < Self.maxFindings else { return }
        findingsWritten += 1
        try await s.raw("""
            INSERT INTO dms_import_findings (tenant_id, run_id, code, ref, detail) VALUES (\(bind: tenant), \(bind: run.id), \(bind: code), \(bind: String(ref.prefix(100))), \(bind: detail.map { String($0.prefix(300)) }))
            ON CONFLICT DO NOTHING
            """).run()
    }

    // MARK: Ablauf

    func execute() async throws {
        refs = try await source.references()
        count("source_users", refs.userCount); count("source_groups", refs.groupCount)
        try await mapReferences()
        try await analyseReferences()
        try await source.pages(size: Self.pageSize) { docs, total in
            self.total = total
            if let top = docs.compactMap(\.asn).filter({ $0 > 0 }).max() {
                self.maxASN = max(self.maxASN, top)
                if self.importing { try await self.raiseCounter(self.maxASN) }
            }
            for doc in docs {
                try await self.importDocument(doc)
                self.processed += 1
                try await self.afterDocument?(self.processed)
                try await self.heartbeat()
            }
        }
        count("owners_seen", owners.count)
        count("asn_max_seen", Int(maxASN))
        if importing, maxASN > 0 { try await raiseCounter(maxASN) }
    }

    private func raiseCounter(_ value: Int64) async throws {
        _ = try await dmsTransaction(db) { _, t in
            try await CounterService(t, auditHook: AuditLogCounterHook()).ensureAtLeast(tenant: self.tenant, key: DMSDocuments.asnKey, value: value, reason: "paperless_import", on: t)
        }
    }

    /// Fortschritt festhalten und Abbruchwunsch lesen (eine Abfrage je Dokument).
    private func heartbeat() async throws {
        var progress = counts.filter { !$0.key.hasPrefix("findings_") }
        progress["processed"] = processed
        if let total { progress["total"] = total }
        let json = String(decoding: try JSONEncoder().encode(progress), as: UTF8.self)
        let row = try await s.raw("""
            UPDATE dms_imports SET progress = \(bind: json)::text::jsonb WHERE tenant_id = \(bind: tenant) AND id = \(bind: run.id) AND state = 'running' RETURNING cancel_requested
            """).first()
        guard let row else { throw CancellationError() }   // Lauf nicht mehr `running` (z. B. von außen beendet): nichts weiter schreiben
        if try row.decode(column: "cancel_requested", as: Bool.self) { throw Cancelled() }
    }

    // MARK: Referenzdaten

    private func mapped(_ kind: String, _ ext: Int64) async throws -> UUID? {
        try await s.raw("""
            SELECT target_id FROM dms_import_items WHERE tenant_id = \(bind: tenant) AND source_key = \(bind: key) AND kind = \(bind: kind) AND ext_id = \(bind: ext)
            """).first()?.decode(column: "target_id", as: UUID.self)
    }

    private func claim(_ kind: String, _ ext: Int64, _ target: UUID, sha256: String? = nil, on t: any SQLDatabase) async throws -> Bool {
        try await t.raw("""
            INSERT INTO dms_import_items (tenant_id, source_key, kind, ext_id, target_id, sha256, run_id)
            VALUES (\(bind: tenant), \(bind: key), \(bind: kind), \(bind: ext), \(bind: target), \(bind: sha256), \(bind: run.id)) ON CONFLICT DO NOTHING RETURNING ext_id
            """).first() != nil
    }

    private func clean(_ s: String, _ max: Int) -> String {
        let t = s.precomposedStringWithCanonicalMapping.trimmingCharacters(in: .whitespacesAndNewlines)
        return String(t.prefix(max))
    }

    /// Typ, Tag, Pfad, Feld: gleichnamige vorhandene Einträge werden verwendet (Hinweis im Bericht), sonst angelegt.
    private func resolve(_ kind: String, label: String, table: String, ext: PLEntity, name: String, audit: String, create: @escaping @Sendable (any SQLDatabase) async throws -> UUID) async throws -> UUID {
        if let id = try await mapped(kind, ext.id) { count("\(label)_existing"); return id }
        let lower = name.lowercased()
        if let id = seen[kind]?[lower] {
            try await finding("reference_matched_by_name", "\(kind):\(ext.id)", name); count("\(label)_merged")
            if importing { _ = try await dmsTransaction(db) { _, t in try await self.claim(kind, ext.id, id, on: t) } }
            return id
        }
        if let row = try await s.raw("SELECT id FROM \(unsafeRaw: table) WHERE tenant_id = \(bind: tenant) AND lower(name) = \(bind: lower)").first() {
            let id = try row.decode(column: "id", as: UUID.self)
            try await finding("reference_matched_by_name", "\(kind):\(ext.id)", name); count("\(label)_matched")
            if importing { _ = try await dmsTransaction(db) { _, t in try await self.claim(kind, ext.id, id, on: t) } }
            seen[kind, default: [:]][lower] = id
            return id
        }
        let id: UUID
        if importing {
            id = try await dmsTransaction(db) { _, t in
                let new = try await create(t)
                _ = try await self.claim(kind, ext.id, new, on: t)
                try await AuditLog.record(AuditEvent(action: "dms.\(audit).created", actor: self.run.requestedBy, tenant: self.tenant, subjectType: "dms.\(audit)", subjectID: new.uuidString,
                                                     meta: ["source": .safe("paperless_import")], requestID: self.requestID), on: t)
                return new
            }
            count("\(label)_created")
        } else { id = UUID(); count("\(label)_would_create") }
        seen[kind, default: [:]][lower] = id
        return id
    }

    private func mapReferences() async throws {
        let tenant = self.tenant
        for t in refs.types {
            let name = clean(t.name, 100)
            guard !name.isEmpty else { continue }
            types[t.id] = try await resolve("type", label: "types", table: "dms_document_types", ext: t, name: name, audit: "type") { tx in
                try await tx.raw("INSERT INTO dms_document_types (tenant_id, name) VALUES (\(bind: tenant), \(bind: name)) RETURNING id").first()!.decode(column: "id", as: UUID.self)
            }
        }
        for t in refs.tags {
            let name = clean(t.name, 100)
            guard !name.isEmpty else { continue }
            let color = t.color.flatMap { $0.range(of: "^#[0-9a-fA-F]{6}$", options: .regularExpression) != nil ? $0 : nil }
            tags[t.id] = try await resolve("tag", label: "tags", table: "dms_tags", ext: t, name: name, audit: "tag") { tx in
                try await tx.raw("INSERT INTO dms_tags (tenant_id, name, color) VALUES (\(bind: tenant), \(bind: name), \(bind: color)) RETURNING id").first()!.decode(column: "id", as: UUID.self)
            }
        }
        for p in refs.paths {
            let name = clean(p.name, 100)
            guard !name.isEmpty else { continue }
            guard let template = PL.template(p.template ?? "") else {
                try await finding("storage_path_untranslatable", "path:\(p.id)", name); count("paths_untranslatable"); continue
            }
            paths[p.id] = try await resolve("path", label: "paths", table: "dms_storage_paths", ext: p, name: name, audit: "storage_path") { tx in
                try await tx.raw("INSERT INTO dms_storage_paths (tenant_id, name, template) VALUES (\(bind: tenant), \(bind: name), \(bind: template)) RETURNING id").first()!.decode(column: "id", as: UUID.self)
            }
        }
        for f in refs.fields { try await mapField(f) }
        for c in refs.correspondents { try await mapCorrespondent(c) }
    }

    private static let fieldTypes = ["string": "string", "url": "string", "date": "date", "boolean": "bool", "integer": "int", "float": "decimal", "monetary": "decimal", "select": "select"]

    private func mapField(_ f: PLEntity) async throws {
        let name = clean(f.name, 100)
        guard !name.isEmpty else { return }
        guard var hub = Self.fieldTypes[f.dataType ?? ""] else {
            try await finding("custom_field_unsupported", "field:\(f.id)", "\(name) (\(f.dataType ?? "?"))"); count("fields_unsupported"); return
        }
        var options = f.options
        if hub == "select" {
            let labels = options.map { clean($0.label, 100) }
            if !(1...100).contains(labels.count) || Set(labels).count != labels.count || labels.contains(where: \.isEmpty) {
                try await finding("custom_field_options_invalid", "field:\(f.id)", name); hub = "string"; options = []
            } else { options = zip(options, labels).map { PLOption(id: $0.id, label: $1) } }
        }
        if f.dataType == "monetary" { try await finding("monetary_currency_dropped", "field:\(f.id)", name) }
        if let id = try await mapped("field", f.id) {
            count("fields_existing"); fields[f.id] = FieldDef(id: id, hubType: hub, options: options); return
        }
        let lower = name.lowercased()
        if let row = try await s.raw("SELECT id, data_type FROM dms_custom_fields WHERE tenant_id = \(bind: tenant) AND lower(name) = \(bind: lower)").first() {
            let id = try row.decode(column: "id", as: UUID.self)
            guard try row.decode(column: "data_type", as: String.self) == hub else { try await finding("custom_field_type_conflict", "field:\(f.id)", name); count("fields_conflict"); return }
            try await finding("reference_matched_by_name", "field:\(f.id)", name); count("fields_matched")
            if importing { _ = try await dmsTransaction(db) { _, t in try await self.claim("field", f.id, id, on: t) } }
            fields[f.id] = FieldDef(id: id, hubType: hub, options: options)
            return
        }
        if let sid = seen["field"]?[lower], let def = fields.values.first(where: { $0.id == sid }) {
            try await finding("reference_matched_by_name", "field:\(f.id)", name); count("fields_merged")
            if importing { _ = try await dmsTransaction(db) { _, t in try await self.claim("field", f.id, sid, on: t) } }
            fields[f.id] = def
            return
        }
        let id: UUID
        if importing {
            let tenant = self.tenant, labels = options.map(\.label), hubType = hub
            id = try await dmsTransaction(db) { _, t in
                var code = PL.code(from: name), n = 1
                while try await t.raw("SELECT 1 AS x FROM dms_custom_fields WHERE tenant_id = \(bind: tenant) AND code = \(bind: code)").first() != nil { n += 1; code = String(PL.code(from: name).prefix(36)) + "_\(n)" }
                let optionsJSON: String? = hubType == "select" ? String(decoding: try JSONEncoder().encode(labels), as: UTF8.self) : nil
                let new = try await t.raw("""
                    INSERT INTO dms_custom_fields (tenant_id, name, code, data_type, options) VALUES (\(bind: tenant), \(bind: name), \(bind: code), \(bind: hubType), \(bind: optionsJSON)::text::jsonb) RETURNING id
                    """).first()!.decode(column: "id", as: UUID.self)
                _ = try await self.claim("field", f.id, new, on: t)
                try await AuditLog.record(AuditEvent(action: "dms.custom_field.created", actor: self.run.requestedBy, tenant: tenant, subjectType: "dms.custom_field", subjectID: new.uuidString,
                                                     meta: ["source": .safe("paperless_import")], requestID: self.requestID), on: t)
                return new
            }
            count("fields_created")
        } else { id = UUID(); count("fields_would_create") }
        seen["field", default: [:]][lower] = id
        fields[f.id] = FieldDef(id: id, hubType: hub, options: options)
    }

    private func mapCorrespondent(_ c: PLEntity) async throws {
        if let id = try await mapped("correspondent", c.id) { corr[c.id] = id; count("correspondents_existing"); return }
        let name = clean(c.name, 200)
        guard !name.isEmpty else { return }
        // Dubletten-Hinweis (K5): gleichnamige vorhandene Kontakte. Nie still zusammenführen: der Korrespondent wird als eigener Kontakt angelegt.
        let same = try await s.raw("""
            SELECT id FROM contacts WHERE tenant_id = \(bind: tenant) AND lower(display_name) = \(bind: name.lowercased()) AND deleted_at IS NULL AND merged_into IS NULL ORDER BY created_at, id LIMIT 5
            """).all().map { try $0.decode(column: "id", as: UUID.self).uuidString.lowercased() }
        if !same.isEmpty { try await finding("contact_possible_duplicate", "correspondent:\(c.id)", "\(name): \(same.joined(separator: ", "))"); count("correspondents_possible_duplicates") }
        guard importing else { corr[c.id] = UUID(); count("correspondents_would_create"); return }
        let fields = try ContactFields(ContactBody(kind: "organization", display_name: name, is_correspondent: true), creating: true)
        let id: UUID = try await dmsTransaction(db) { tx, t in
            let created = try await ContactService.create(tenant: self.tenant, actor: self.run.requestedBy, fields: fields, requestID: self.requestID, on: tx)
            _ = try await self.claim("correspondent", c.id, created.id, on: t)
            return created.id
        }
        corr[c.id] = id
        count("correspondents_created")
    }

    /// Hinweise ohne Schreibwirkung: ähnliche Tag-Namen (Dreiergruppen wie `pg_trgm`) und Matching-Regeln (nur Bericht, keine Übernahme).
    private func analyseReferences() async throws {
        let grams = refs.tags.map { ($0, PL.trigrams($0.name)) }
        for i in grams.indices {
            for j in grams.indices where j > i {
                let a = grams[i], b = grams[j]
                guard a.0.name.lowercased() != b.0.name.lowercased() else { continue }
                let sim = PL.similarity(a.1, b.1)
                if sim >= 0.6 { try await finding("tag_similar", "tag:\(a.0.id)-\(b.0.id)", "\(a.0.name) / \(b.0.name) (\(String(format: "%.2f", sim)))"); count("tags_similar") }
            }
        }
    }

    /// Vorschläge für `dms_rules` aus den Matching-Algorithmen der Quelle; die Semantik weicht ab (P2), daher nie automatisch angelegt.
    var ruleSuggestions: [[String: Any]] {
        var out: [[String: Any]] = []
        for (kind, list) in [("correspondent", refs.correspondents), ("document_type", refs.types), ("tag", refs.tags), ("storage_path", refs.paths)] {
            for e in list where e.algorithm != 0 {
                out.append(["target_kind": kind, "target_name": e.name, "algorithm": PL.algorithmName(e.algorithm), "match": String(e.match.prefix(300)), "case_insensitive": e.insensitive,
                            "translatable": (1...5).contains(e.algorithm) && !e.match.isEmpty])
                if out.count >= 500 { return out }
            }
        }
        return out
    }

    // MARK: Dokumente

    private func fileStream(_ url: URL) throws -> ByteStream {
        let box = UnsafeSendableBox(try FileHandle(forReadingFrom: url))
        return ByteStream(unfolding: {
            guard let d = try box.value.read(upToCount: objectStoreChunkSize), !d.isEmpty else { try? box.value.close(); return nil }
            return ByteBuffer(data: d)
        })
    }

    private func importDocument(_ doc: PLDoc) async throws {
        count("documents_seen")
        if let o = doc.owner { owners.insert(o) }
        let ref = "document:\(doc.id)"
        if importing, try await mapped("document", doc.id) != nil { count("documents_skipped_existing"); return }

        func unknown(_ what: String, _ id: Int64?, _ known: Bool) async throws { if let id, !known { try await finding("reference_unknown", "\(ref)/\(what):\(id)"); count("documents_reference_dropped") } }
        var typeID: UUID?, pathID: UUID?, correspondentID: UUID?
        if let t = doc.type { typeID = types[t]; try await unknown("type", t, typeID != nil) }
        if let p = doc.path {
            pathID = paths[p]
            if pathID == nil { if refs.paths.contains(where: { $0.id == p }) { count("documents_reference_dropped") } else { try await unknown("path", p, false) } }
        }
        if let c = doc.correspondent { correspondentID = corr[c]; try await unknown("correspondent", c, correspondentID != nil) }
        let tagIDs = Array(Set(try await doc.tags.asyncCompactMap { id -> UUID? in let t = self.tags[id]; try await unknown("tag", id, t != nil); return t }))

        let maxBytes = limits.maxUploadBytes
        let original: LocalFile?
        do { original = try await source.materialize(doc, .original, maxBytes: maxBytes) }
        catch let e as ImportError where e.code == "file_too_large" { try await finding("file_too_large", ref); count("documents_skipped"); return }
        guard let original else { try await finding("file_missing", ref); count("documents_skipped"); return }
        defer { original.discard() }
        guard let kind = DMSFileKind.sniff(original.head()) else { try await finding("unsupported_type", ref); count("documents_skipped"); return }
        switch PL.checksumMatches(doc.checksum, original) {
        case false?: try await finding("checksum_mismatch", ref); count("documents_skipped"); return
        case nil: try await finding("file_without_checksum", ref); count("files_without_checksum")
        case true?: break
        }
        // gleicher Inhalt wurde schon aus einer Paperless-Quelle übernommen (anderer Schlüssel): kein zweites Dokument
        if try await s.raw("SELECT 1 AS x FROM dms_import_items WHERE tenant_id = \(bind: tenant) AND kind = 'document' AND sha256 = \(bind: original.sha256) LIMIT 1").first() != nil {
            try await finding("duplicate_hash_imported", ref); count("documents_skipped"); return
        }
        if try await s.raw("SELECT 1 AS x FROM dms_document_files WHERE tenant_id = \(bind: tenant) AND sha256 = \(bind: original.sha256) AND role = 'original' LIMIT 1").first() != nil {
            try await finding("hash_exists", ref); count("documents_hash_exists")
        }
        // Archivversion: nur ein PDF mit passender Prüfsumme
        var archive: LocalFile?
        if doc.archiveAvailable || doc.archiveRef != nil {
            do { archive = try await source.materialize(doc, .archive, maxBytes: maxBytes) } catch let e as ImportError where e.code == "file_too_large" { archive = nil; try await finding("archive_too_large", ref) }
            if archive == nil, doc.archiveRef != nil { try await finding("archive_missing", ref) }
            if let a = archive {
                if PL.checksumMatches(doc.archiveChecksum, a) == false { try await finding("archive_checksum_mismatch", ref); a.discard(); archive = nil }
                else if DMSFileKind.sniff(a.head()) != .pdf { try await finding("archive_unsupported", ref); a.discard(); archive = nil }
            }
        }
        defer { archive?.discard() }
        // Archivnummer: Kollision mit einem vorhandenen Dokument -> ohne Nummer importieren, im Bericht
        var asn: Int64? = doc.asn.flatMap { $0 > 0 ? $0 : nil }
        if let a = asn, try await s.raw("SELECT 1 AS x FROM dms_documents WHERE tenant_id = \(bind: tenant) AND asn = \(bind: a)").first() != nil {
            try await finding("asn_collision", ref, "ASN \(a)"); count("asn_collisions"); asn = nil
        }
        var title = clean(doc.title, 400)
        if title.isEmpty { title = "Dokument \(doc.id)" }
        if title.count > 300 { try await finding("title_truncated", ref); title = String(title.prefix(300)) }
        var text = doc.content.replacingOccurrences(of: "\0", with: "").precomposedStringWithCanonicalMapping.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.count > 500_000 { text = String(text.prefix(500_000)); try await finding("text_truncated", ref) }
        let fieldValues = try await convertFields(doc, ref: ref)

        guard importing else {
            count("documents_would_import"); count("files_original"); if archive != nil { count("files_archive") }
            count("notes_total", doc.notes.count)
            return
        }

        // Dateien in den Objektspeicher (Dedup, Hash gegen die Messung geprüft), danach alles in einer Transaktion
        let store = try config.makeStore(db: s)
        let stored = try await store.put(tenant: tenant, stream: try fileStream(original.url), expectedSHA256: original.sha256)
        var archiveStored: StoredObject?
        do {
            if let a = archive { archiveStored = try await store.put(tenant: tenant, stream: try fileStream(a.url), expectedSHA256: a.sha256) }
        } catch { await discard(stored.key); throw error }
        let logger = Logger(label: "dms.import")
        do {
            let ocrPriority: Int? = (text.isEmpty && run.ocr && limits.ocrEnabled) ? DMSOCR.priorityBulk : nil
            let docDate = PL.date(doc.created), received = PL.timestamp(doc.added)
            let name = DMSSourceIngest.cleanName(doc.originalName)
            let (asnFinal, archiveFinal, tenant, run, requestID, config) = (asn, archiveStored, self.tenant, self.run, self.requestID, self.config)
            let (typeID, pathID, correspondentID, tagIDs, title, text, fieldValues, notes) = (typeID, pathID, correspondentID, tagIDs, title, text, fieldValues, doc.notes)
            let created: UUID? = try await dmsTransaction(db) { tx, t in
                let placeholder = UUID()
                guard try await self.claim("document", doc.id, placeholder, sha256: stored.key.sha256, on: t) else { return nil }
                let out = try await DMSDocuments.create(
                    tenant: tenant, actor: run.requestedBy, requestID: requestID,
                    doc: .init(title: title, docDate: docDate, typeID: typeID, originalName: name, archive: false, kind: kind, stored: stored, backend: store.kind,
                               quotaBytes: self.limits.quotaBytes, verifyBlob: { t in try await config.makeStore(db: t).exists(stored.key) },
                               ocrPriority: ocrPriority, ingestSource: .api, originRef: "paperless:\(doc.id)", sender: nil, documentSource: .import), on: tx)
                let id = out.id
                try await t.raw("UPDATE dms_import_items SET target_id = \(bind: id) WHERE tenant_id = \(bind: tenant) AND source_key = \(bind: self.key) AND kind = 'document' AND ext_id = \(bind: doc.id)").run()
                // Archivnummer (Kollision zwischen Prüfung und Schreiben: ohne Nummer weiter), Eingangsdatum, Speicherpfad
                var asnApplied = asnFinal
                if let a = asnApplied, try await t.raw("SELECT 1 AS x FROM dms_documents WHERE tenant_id = \(bind: tenant) AND asn = \(bind: a)").first() != nil { asnApplied = nil }
                try await t.raw("""
                    UPDATE dms_documents SET received_at = COALESCE(\(bind: received)::timestamptz, received_at), storage_path_id = \(bind: pathID), asn = \(bind: asnApplied),
                      status = CASE WHEN \(bind: asnApplied)::bigint IS NOT NULL THEN 'archived' ELSE status END
                    WHERE tenant_id = \(bind: tenant) AND id = \(bind: id)
                    """).run()
                for tag in tagIDs {
                    try await t.raw("INSERT INTO dms_document_tags (tenant_id, document_id, tag_id, assigned_by) VALUES (\(bind: tenant), \(bind: id), \(bind: tag), \(bind: run.requestedBy)) ON CONFLICT DO NOTHING").run()
                }
                for v in fieldValues {
                    try await t.raw("""
                        INSERT INTO dms_document_fields (tenant_id, document_id, field_id, value_text, value_numeric, value_date, value_bool)
                        VALUES (\(bind: tenant), \(bind: id), \(bind: v.field), \(bind: v.text)::text, \(bind: v.numeric)::text::numeric, \(bind: v.date)::text::date, \(bind: v.bool)::boolean)
                        ON CONFLICT DO NOTHING
                        """).run()
                }
                if let c = correspondentID {
                    _ = try await LinkService.create(tenant: tenant, actor: run.requestedBy, body: LinkBody(from_type: "dms.document", from_id: id, to_type: "contact", to_id: c, kind: DMSDocuments.correspondentKind, source: "import"),
                                                     requestID: requestID, on: tx)
                }
                for (i, n) in notes.enumerated() {
                    try await t.raw("""
                        INSERT INTO dms_document_notes (tenant_id, document_id, body, noted_at, origin, created_by)
                        VALUES (\(bind: tenant), \(bind: id), \(bind: String(n.text.prefix(20000))), \(bind: PL.timestamp(n.created))::timestamptz, \(bind: "paperless:note:\(n.id.map(String.init) ?? "i\(i)")"), \(bind: run.requestedBy))
                        ON CONFLICT DO NOTHING
                        """).run()
                }
                if !text.isEmpty { try await DMSTexts.add(document: id, tenant: tenant, engine: "imported", lang: OCRToolEngine.detectLanguage(text), text: text, on: tx) }
                if let a = archiveFinal {
                    try await DMSUpload.lockBlob(tenant: tenant, sha256: a.key.sha256, on: t)
                    let fileID = try await FileRecordService(t).register(a, backend: store.kind, contentType: "application/pdf")
                    try await t.raw("""
                        INSERT INTO dms_document_files (tenant_id, document_id, role, file_id, mime, size_bytes, sha256) VALUES (\(bind: tenant), \(bind: id), 'archive', \(bind: fileID), 'application/pdf', \(bind: a.size), \(bind: a.key.sha256))
                        ON CONFLICT DO NOTHING
                        """).run()
                }
                // Ingest-Vorgang: mit übernommenem Text ist er fertig (kein OCR, keine Regeln: die Metadaten stammen aus der Quelle); ohne Text läuft OCR (Option)
                if ocrPriority == nil, let item = out.ingest_item_id {
                    for st in [DMSIngest.State.ocrQueued, .ocrDone, .classified, .done] { try await DMSIngest.advance(item, tenant: tenant, to: st, on: t) }
                }
                return id
            }
            guard created != nil else {
                await discard(stored.key); if let a = archiveStored { await discard(a.key) }
                count("documents_skipped_existing"); return
            }
            count("files_original"); if archiveStored != nil { count("files_archive") }
            count("notes_imported", doc.notes.count)
            if asn != nil { count("asn_assigned") }
        } catch let e as HubError where e.code != "storage_quota_exceeded" {
            await discard(stored.key); if let a = archiveStored { await discard(a.key) }
            try await finding("document_failed", ref, e.code); count("documents_failed"); _ = logger
        } catch let e as any DatabaseError where e.isConstraintFailure {
            await discard(stored.key); if let a = archiveStored { await discard(a.key) }
            try await finding("document_failed", ref, "constraint"); count("documents_failed")
        } catch {
            await discard(stored.key); if let a = archiveStored { await discard(a.key) }
            throw error
        }
    }

    private func discard(_ key: ObjectKey) async {
        await DMSUpload.discardIfUnreferenced(key, config: config, db: db, logger: Logger(label: "dms.import"))
    }

    // MARK: Felder

    struct FieldValue: Sendable { let field: UUID; var text: String?; var numeric: String?; var date: String?; var bool: Bool? }

    private func convertFields(_ doc: PLDoc, ref: String) async throws -> [FieldValue] {
        var out: [FieldValue] = []
        for fv in doc.fields {
            guard let def = fields[fv.field] else { try await finding("custom_field_value_dropped", "\(ref)/field:\(fv.field)"); count("field_values_dropped"); continue }
            var v = FieldValue(field: def.id)
            switch (def.hubType, fv.value) {
            case ("string", _): if let t = fv.value.text?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty, t.count <= 1000 { v.text = t }
            case ("int", .int(let i)): v.numeric = String(i)
            case ("bool", .bool(let b)): v.bool = b
            case ("date", _): v.date = PL.date(fv.value.text)
            case ("decimal", .int(let i)): v.numeric = String(i)
            case ("decimal", .double(let d)): v.numeric = String(format: "%.4f", d)
            case ("decimal", .string(let s)):
                // Geldbetrag der Quelle: Währungskürzel vorn wird verworfen („EUR12.50“); Beträge mit mehr als vier Nachkommastellen werden nicht übernommen
                if let m = s.range(of: "-?[0-9]{1,15}(\\.[0-9]{1,4})?$", options: .regularExpression), s.range(of: "^[A-Za-z]{0,3}-?[0-9]{1,15}(\\.[0-9]{1,4})?$", options: .regularExpression) != nil { v.numeric = String(s[m]) }
            case ("select", _):
                let raw = fv.value.text ?? ""
                if let o = def.options.first(where: { $0.id == raw }) ?? def.options.first(where: { $0.label == raw }) ?? Int(raw).flatMap({ def.options.indices.contains($0) ? def.options[$0] : nil }) { v.text = o.label }
            default: break
            }
            if v.text == nil, v.numeric == nil, v.date == nil, v.bool == nil { try await finding("custom_field_value_dropped", "\(ref)/field:\(fv.field)"); count("field_values_dropped"); continue }
            out.append(v)
        }
        return out
    }

    // MARK: Abschluss und Bericht

    static func finish(_ run: DMSImport.RunRow, state: String, code: String?, runner: DMSImportRunner?, db: any Database, s: any SQLDatabase) async throws {
        let report = try await buildReport(run, state: state, code: code, runner: runner, s: s)
        let json = String(decoding: try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]), as: UTF8.self)
        let counts = (report["counts"] as? [String: Int]) ?? [:]
        let action = state == "done" ? "completed" : state
        _ = try await dmsTransaction(db) { _, t in
            guard try await t.raw("""
                UPDATE dms_imports SET state = \(bind: state), error_code = \(bind: code), report = \(bind: json)::text::jsonb, finished_at = now()
                WHERE tenant_id = \(bind: run.tenant) AND id = \(bind: run.id) AND state = 'running' RETURNING id
                """).first() != nil else { return false }
            var meta: [String: AuditValue] = ["mode": .safe(run.mode)]
            for k in ["documents_seen", "documents_imported", "documents_would_import", "documents_skipped", "documents_failed", "asn_collisions"] { if let n = counts[k] { meta[k] = .number(Int64(n)) } }
            if let code { meta["code"] = .safe(code) }
            try await AuditLog.record(AuditEvent(action: "dms.import.\(action)", actor: run.requestedBy, tenant: run.tenant, subjectType: "dms.import", subjectID: run.id.uuidString, meta: meta), on: t)
            return true
        }
    }

    private static func buildReport(_ run: DMSImport.RunRow, state: String, code: String?, runner: DMSImportRunner?, s: any SQLDatabase) async throws -> [String: Any] {
        var counts: [String: Int]
        if let runner { counts = runner.counts } else {
            let p = try await s.raw("SELECT progress::text AS p FROM dms_imports WHERE tenant_id = \(bind: run.tenant) AND id = \(bind: run.id)").first()?.decode(column: "p", as: String.self)
            counts = (p.flatMap { try? JSONDecoder().decode([String: Int].self, from: Data($0.utf8)) }) ?? [:]
            counts["processed"] = nil; counts["total"] = nil
        }
        if run.mode == "import" {
            counts["documents_imported"] = Int(try await s.raw("SELECT count(*)::bigint AS n FROM dms_import_items WHERE tenant_id = \(bind: run.tenant) AND run_id = \(bind: run.id) AND kind = 'document'").first()?.decode(column: "n", as: Int64.self) ?? 0)
        }
        var findings: [String: Any] = [:]
        let rows = try await s.raw("""
            SELECT code, ref, detail, total FROM (SELECT code, ref, detail, count(*) OVER (PARTITION BY code) AS total, row_number() OVER (PARTITION BY code ORDER BY ref) AS rn
              FROM dms_import_findings WHERE tenant_id = \(bind: run.tenant) AND run_id = \(bind: run.id)) f WHERE rn <= 100 ORDER BY code, ref
            """).all()
        for r in rows {
            let c = try r.decode(column: "code", as: String.self)
            let total = Int(try r.decode(column: "total", as: Int64.self))
            var entry = (findings[c] as? [String: Any]) ?? ["total": total, "items": [[String: String]]()]
            var items = entry["items"] as? [[String: String]] ?? []
            var item = ["ref": try r.decode(column: "ref", as: String.self)]
            if let d = try r.decode(column: "detail", as: String?.self) { item["detail"] = d }
            items.append(item); entry["items"] = items; findings[c] = entry
        }
        let counter = try await s.raw("SELECT value FROM counters WHERE tenant_id = \(bind: run.tenant) AND key = \(bind: DMSDocuments.asnKey.rawValue)").first()?.decode(column: "value", as: Int64.self)
        let counterValue: Any = counter.map({ Int($0) as Any }) ?? NSNull()
        var report: [String: Any] = [
            "format": "labhub-paperless-import-report/1", "mode": run.mode, "source_kind": run.sourceKind, "state": state, "counts": counts, "findings": findings,
            "asn": ["max_seen": counts["asn_max_seen"] ?? 0, "collisions": counts["asn_collisions"] ?? 0, "counter_value": counterValue] as [String: Any],
            "rights": ["owners_seen": counts["owners_seen"] ?? 0, "source_users": counts["source_users"] ?? 0, "source_groups": counts["source_groups"] ?? 0,
                       "imported": false, "note_code": "rights_not_imported"],
            "rule_suggestions": runner?.ruleSuggestions ?? []]
        if let code { report["error_code"] = code }
        return report
    }
}

extension Array {
    func asyncCompactMap<T>(_ transform: (Element) async throws -> T?) async rethrows -> [T] {
        var out: [T] = []
        for e in self { if let v = try await transform(e) { out.append(v) } }
        return out
    }
}
