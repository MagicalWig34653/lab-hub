import Vapor
import Fluent
import SQLKit
import Crypto

// WP-D3 Duplikaterkennung (MODUL-DMS 5.1, P9). Treffer sind Hinweise mit Gegenüberstellung, nie stilles Verwerfen.
// Stufe 1 `sha256`: gleiches Original im Mandanten (beim Anlegen, Hash bekannt). Stufe 2 nach dem Text:
//   `text_hash`: SHA-256 des normalisierten Textes (Kleinschreibung, ohne Akzente und Satzzeichen, Leerräume vereinheitlicht) ist gleich -> Score 1.
//   `similarity`: Bottom-k-Skizze der Wort-Dreiergruppen (Shingles); Jaccard-Schätzung >= 0,8, oder >= 0,5 bei gleichem Belegdatum und Titelähnlichkeit (pg_trgm) >= 0,7.
// Paare: `document_id` = das gerade verarbeitete (jüngere) Dokument, `duplicate_of` = das schon vorhandene. Eindeutig je (Dokument, Gegenstück, Methode).
// Gleichzeitige Verarbeitung zweier Kopien: eine Transaktions-Sperre je Mandant sorgt dafür, dass die spätere die frühere sieht (genau ein Paar, nie keines).

struct DMSDuplicateOut: Content, Sendable {
    let id: UUID
    let document_id: UUID
    let document_title: String
    let duplicate_of: UUID
    let duplicate_of_title: String
    let method: String
    let score: Double
    let state: String
    let decided_by: UUID?
    let decided_at: String?
    let created_at: String
}

enum DMSDuplicates {
    static let sketchSize = 128
    static let shingleWords = 3
    static let minWords = 12
    static let strongThreshold = 0.8, weakThreshold = 0.5, titleThreshold = 0.7
    static let maxPerDocument = 20

    // MARK: Stufe 1

    static func detectHash(document: UUID, sha256: String, tenant: UUID, on s: any SQLDatabase) async throws {
        try await s.raw("""
            INSERT INTO dms_duplicates (tenant_id, document_id, duplicate_of, method, score)
            SELECT \(bind: tenant), \(bind: document), f.document_id, 'sha256', 1 FROM dms_document_files f
            JOIN dms_documents d ON d.id = f.document_id AND d.tenant_id = f.tenant_id
            WHERE f.tenant_id = \(bind: tenant) AND f.sha256 = \(bind: sha256) AND f.role = 'original' AND f.document_id <> \(bind: document) AND d.trashed_at IS NULL
            ORDER BY f.created_at, f.id LIMIT \(bind: maxPerDocument)
            ON CONFLICT DO NOTHING
            """).run()
    }

    // MARK: Stufe 2

    struct Fingerprint: Sendable, Equatable {
        let textHash: String
        let words: Int
        /// Aufsteigend sortierte Bottom-k-Hashes (als UInt64).
        let sketch: [UInt64]
    }

    /// `nil`, wenn der Text für einen Vergleich zu kurz ist.
    static func fingerprint(of text: String) -> Fingerprint? {
        let normalized = DMSContactMatch.normalize(text)
        let words = normalized.split(separator: " ")
        guard words.count >= minWords else { return nil }
        let hash = SHA256.hash(data: Data(normalized.utf8)).map { String(format: "%02x", $0) }.joined()
        var hashes = Set<UInt64>()
        for i in 0...(words.count - shingleWords) {
            let digest = SHA256.hash(data: Data((words[i] + " " + words[i + 1] + " " + words[i + 2]).utf8))
            hashes.insert(digest.prefix(8).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) })
        }
        return Fingerprint(textHash: hash, words: words.count, sketch: Array(hashes.sorted().prefix(sketchSize)))
    }

    /// Jaccard-Schätzung zweier Bottom-k-Skizzen.
    static func similarity(_ a: [UInt64], _ b: [UInt64]) -> Double {
        let setA = Set(a), setB = Set(b)
        let union = Array(setA.union(setB).sorted().prefix(sketchSize))
        guard !union.isEmpty else { return 0 }
        return Double(union.filter { setA.contains($0) && setB.contains($0) }.count) / Double(union.count)
    }

    struct Found: Sendable { let method: String; let score: Double }

    /// Speichert den Fingerabdruck und sucht Gegenstücke. Muss in der Transaktion des Aufrufers laufen. Liefert die Anzahl neuer Paare.
    @discardableResult
    static func detectText(document: UUID, tenant: UUID, text: String, on s: any SQLDatabase) async throws -> Int {
        // Eine Fassung des Fingerabdrucks je Dokument (die jüngste Textrevision gilt)
        try await s.raw("DELETE FROM dms_text_shingles WHERE document_id = \(bind: document) AND tenant_id = \(bind: tenant)").run()
        guard let fp = fingerprint(of: text) else {
            try await s.raw("DELETE FROM dms_document_fingerprints WHERE document_id = \(bind: document) AND tenant_id = \(bind: tenant)").run()
            return 0
        }
        // Sperre je Mandant: gleichzeitig verarbeitete Kopien sehen sich gegenseitig (die zweite wartet bis zum Commit der ersten)
        let lockKey = "dms.dup:" + tenant.uuidString
        try await s.raw("SELECT pg_advisory_xact_lock(hashtext(\(bind: lockKey)))").run()
        try await s.raw("""
            INSERT INTO dms_document_fingerprints (document_id, tenant_id, text_hash, words) VALUES (\(bind: document), \(bind: tenant), \(bind: fp.textHash), \(bind: fp.words))
            ON CONFLICT (document_id) DO UPDATE SET text_hash = EXCLUDED.text_hash, words = EXCLUDED.words, created_at = now()
            """).run()
        for h in fp.sketch {
            try await s.raw("INSERT INTO dms_text_shingles (tenant_id, document_id, h) VALUES (\(bind: tenant), \(bind: document), \(bind: Int64(bitPattern: h))) ON CONFLICT DO NOTHING").run()
        }

        var found: [UUID: Found] = [:]
        // exakt gleicher normalisierter Text
        for row in try await s.raw("""
            SELECT p.document_id FROM dms_document_fingerprints p JOIN dms_documents d ON d.id = p.document_id AND d.tenant_id = p.tenant_id
            WHERE p.tenant_id = \(bind: tenant) AND p.text_hash = \(bind: fp.textHash) AND p.document_id <> \(bind: document) AND d.trashed_at IS NULL
            ORDER BY p.created_at, p.document_id LIMIT \(bind: maxPerDocument)
            """).all() { found[try row.decode(column: "document_id", as: UUID.self)] = Found(method: "text_hash", score: 1) }

        // Ähnlichkeit über Shingles
        let hashes = fp.sketch.map { Int64(bitPattern: $0) }
        let candidates = try await s.raw("""
            SELECT h.document_id,
              similarity(d.title, (SELECT title FROM dms_documents WHERE tenant_id = \(bind: tenant) AND id = \(bind: document)))::float8 AS title_similarity,
              (d.doc_date IS NOT NULL AND d.doc_date = (SELECT doc_date FROM dms_documents WHERE tenant_id = \(bind: tenant) AND id = \(bind: document))) AS same_date
            FROM (SELECT document_id, count(*) AS n FROM dms_text_shingles WHERE tenant_id = \(bind: tenant) AND h = ANY(\(bind: hashes)::bigint[]) AND document_id <> \(bind: document)
                  GROUP BY document_id ORDER BY n DESC, document_id LIMIT 15) h
            JOIN dms_documents d ON d.id = h.document_id AND d.tenant_id = \(bind: tenant) AND d.trashed_at IS NULL
            ORDER BY h.n DESC, h.document_id
            """).all()
        for c in candidates {
            let other = try c.decode(column: "document_id", as: UUID.self)
            if found[other] != nil { continue }
            let sketch = try await s.raw("SELECT h FROM dms_text_shingles WHERE tenant_id = \(bind: tenant) AND document_id = \(bind: other) ORDER BY h").all()
                .map { UInt64(bitPattern: try $0.decode(column: "h", as: Int64.self)) }.sorted()
            let score = similarity(fp.sketch, sketch)
            let metadata = try c.decode(column: "same_date", as: Bool.self) && (try c.decode(column: "title_similarity", as: Double.self)) >= titleThreshold
            if score >= strongThreshold || (score >= weakThreshold && metadata) { found[other] = Found(method: "similarity", score: min(1, (score * 1000).rounded() / 1000)) }
        }

        var created = 0
        for (other, f) in found.sorted(by: { $0.value.score != $1.value.score ? $0.value.score > $1.value.score : $0.key.uuidString < $1.key.uuidString }).prefix(maxPerDocument) {
            let inserted = try await s.raw("""
                INSERT INTO dms_duplicates (tenant_id, document_id, duplicate_of, method, score) VALUES (\(bind: tenant), \(bind: document), \(bind: other), \(bind: f.method), \(bind: f.score))
                ON CONFLICT DO NOTHING RETURNING id
                """).first()
            if inserted != nil { created += 1 }
        }
        return created
    }

    // MARK: Lesen und Entscheiden

    private static let columns = """
        p.id, p.document_id, a.title AS document_title, p.duplicate_of, b.title AS duplicate_of_title, p.method, p.score::float8 AS score, p.state, p.decided_by, p.decided_at, p.created_at
        """

    private static func out(_ r: any SQLRow) throws -> DMSDuplicateOut {
        DMSDuplicateOut(id: try r.decode(column: "id", as: UUID.self), document_id: try r.decode(column: "document_id", as: UUID.self),
                        document_title: try r.decode(column: "document_title", as: String.self), duplicate_of: try r.decode(column: "duplicate_of", as: UUID.self),
                        duplicate_of_title: try r.decode(column: "duplicate_of_title", as: String.self), method: try r.decode(column: "method", as: String.self),
                        score: try r.decode(column: "score", as: Double.self), state: try r.decode(column: "state", as: String.self), decided_by: try r.decode(column: "decided_by", as: UUID?.self),
                        decided_at: try r.decode(column: "decided_at", as: Date?.self).map(iso), created_at: iso(try r.decode(column: "created_at", as: Date.self)))
    }

    /// Liste mit Gegenüberstellung (beide Titel); Papierkorb-Dokumente auf einer Seite des Paares blenden den Eintrag aus.
    static func list(tenant: UUID, page: HubPageRequest, state: String?, document: UUID?, method: String?, on db: any Database) async throws -> HubPage<DMSDuplicateOut> {
        let s = try sql(db)
        let cur = page.cursor
        let rows = try await s.raw("""
            SELECT \(unsafeRaw: columns), p.created_at::text AS created_text FROM dms_duplicates p
            JOIN dms_documents a ON a.id = p.document_id AND a.tenant_id = p.tenant_id JOIN dms_documents b ON b.id = p.duplicate_of AND b.tenant_id = p.tenant_id
            WHERE p.tenant_id = \(bind: tenant) AND a.trashed_at IS NULL AND b.trashed_at IS NULL
              AND (\(bind: state)::text IS NULL OR p.state = \(bind: state)::text) AND (\(bind: method)::text IS NULL OR p.method = \(bind: method)::text)
              AND (\(bind: document)::uuid IS NULL OR p.document_id = \(bind: document)::uuid OR p.duplicate_of = \(bind: document)::uuid)
              AND (\(bind: cur?.createdAt)::text IS NULL OR (p.created_at, p.id) > (\(bind: cur?.createdAt)::timestamptz, \(bind: cur?.id)::uuid))
            ORDER BY p.created_at, p.id LIMIT \(bind: page.limit + 1)
            """).all()
        let items = try rows.map { (try out($0), try $0.decode(column: "created_text", as: String.self)) }
        var total: Int?
        if page.wantsCount {
            total = Int(try await s.raw("""
                SELECT count(*)::bigint AS n FROM dms_duplicates p JOIN dms_documents a ON a.id = p.document_id AND a.tenant_id = p.tenant_id
                JOIN dms_documents b ON b.id = p.duplicate_of AND b.tenant_id = p.tenant_id
                WHERE p.tenant_id = \(bind: tenant) AND a.trashed_at IS NULL AND b.trashed_at IS NULL AND (\(bind: state)::text IS NULL OR p.state = \(bind: state)::text)
                  AND (\(bind: method)::text IS NULL OR p.method = \(bind: method)::text)
                  AND (\(bind: document)::uuid IS NULL OR p.document_id = \(bind: document)::uuid OR p.duplicate_of = \(bind: document)::uuid)
                """).first()?.decode(column: "n", as: Int64.self) ?? 0)
        }
        let created = Dictionary(uniqueKeysWithValues: items.map { ($0.0.id, $0.1) })
        return HubPage(fetched: items.map(\.0), limit: page.limit, cursorOf: { PageCursor(createdAt: created[$0.id] ?? "", id: $0.id) }, total: total)
    }

    static func load(_ id: UUID, tenant: UUID, on s: any SQLDatabase) async throws -> DMSDuplicateOut? {
        guard let row = try await s.raw("""
            SELECT \(unsafeRaw: columns) FROM dms_duplicates p JOIN dms_documents a ON a.id = p.document_id AND a.tenant_id = p.tenant_id
            JOIN dms_documents b ON b.id = p.duplicate_of AND b.tenant_id = p.tenant_id WHERE p.tenant_id = \(bind: tenant) AND p.id = \(bind: id)
            """).first() else { return nil }
        return try out(row)
    }

    /// Entscheidung des Nutzers: `confirmed` (ist ein Duplikat, Dokument bleibt) oder `dismissed` (kein Duplikat). Es wird nichts gelöscht oder verschoben.
    static func resolve(_ id: UUID, to state: String, tenant: UUID, actor: UUID, requestID: String, on db: any Database) async throws -> DMSDuplicateOut {
        guard state == "confirmed" || state == "dismissed" else { throw DMSError.invalid("state") }
        return try await dmsTransaction(db) { _, s in
            guard let row = try await s.raw("SELECT method, state FROM dms_duplicates WHERE tenant_id = \(bind: tenant) AND id = \(bind: id) FOR UPDATE").first() else { throw DMSError.notFound }
            guard try row.decode(column: "state", as: String.self) == "open" else { throw HubError(.conflict, "conflict", detail: "Das Duplikat wurde schon entschieden.") }
            try await s.raw("UPDATE dms_duplicates SET state = \(bind: state), decided_by = \(bind: actor), decided_at = now() WHERE tenant_id = \(bind: tenant) AND id = \(bind: id)").run()
            try await AuditLog.record(AuditEvent(action: "dms.duplicate.resolved", actor: actor, tenant: tenant, subjectType: "dms.duplicate", subjectID: id.uuidString,
                                                 meta: ["state": .safe(state), "method": .safe(try row.decode(column: "method", as: String.self))], requestID: requestID), on: s)
            guard let out = try await load(id, tenant: tenant, on: s) else { throw DMSError.notFound }
            return out
        }
    }
}
