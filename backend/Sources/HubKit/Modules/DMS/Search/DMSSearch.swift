import Vapor
import Fluent
import SQLKit

// WP-S1 DMS-Suche (ADR 0005, MODUL-DMS.md Abschnitt 6): Route GET /api/v1/tenants/{tenant}/dms/search.
// Treffer = Dokumente des Mandanten ohne Papierkorb. Mandant und Papierkorb stecken in demselben SQL-Statement wie der Treffertest (nie nachgelagert).
// Rechte: die Route verlangt `dms.document.read` (ModuleGuard). Objektfreigaben (`grants`) gibt es noch nicht; sie kämen an dieselbe Stelle (WHERE von `hitsSQL`).
// Ranking: Volltexttreffer (Score 1 + ts_rank_cd, Gewichte Titel > Metadaten > Text) vor Tippfehler-Treffern (Score = word_similarity, < 1).
// Cursor: (Score, id) absteigend nach Score; der Score steckt als Text im `createdAt`-Feld des Standard-Cursors (K4).

struct DMSSearchHit: Content, Sendable {
    let id: UUID
    let title: String
    let doc_date: String?
    let document_type_id: UUID?
    let storage_path_id: UUID?
    let correspondent_id: UUID?
    let asn: Int64?
    let status: String
    let created_at: String
    /// Volltexttreffer haben Score >= 1, reine Tippfehler-Treffer Score < 1.
    let score: Double
    /// Textauszug (Text, sonst Titel); Treffer stehen zwischen U+E000 und U+E001 (private Zeichen, kein HTML, der Client escaped selbst).
    let snippet: String?
}

struct DMSFacetEntry: Content, Sendable, Equatable {
    let value: String
    let count: Int
}

struct DMSFacets: Content, Sendable {
    var document_type: [DMSFacetEntry] = []
    var tag: [DMSFacetEntry] = []
    var correspondent: [DMSFacetEntry] = []
    var storage_path: [DMSFacetEntry] = []
    var year: [DMSFacetEntry] = []
}

struct DMSSearchPage: Content, Sendable {
    let items: [DMSSearchHit]
    let next_cursor: String?
    let total: Int?
    let facets: DMSFacets?
}

enum DMSSearch {
    static let maxQueryLength = 200, maxTags = 10, facetLimit = 20
    /// Schwelle für `word_similarity` (Tippfehler). 0,35 erfasst einen Buchstabendreher in Wörtern ab ca. sieben Zeichen (siehe ADR 0005).
    static let trigramThreshold = "0.35"
    static let startMark = "\u{E000}", endMark = "\u{E001}"

    struct Params: Sendable {
        var tenant: UUID
        var q: String
        var fuzzy = true
        var typeID: UUID?
        var storagePathID: UUID?
        var correspondentID: UUID?
        var tagIDs: [UUID] = []
        var dateFrom: String?
        var dateTo: String?
        var facets = false
        var page: HubPageRequest

        /// Operatoren der Websuche (Phrase, `-`, `or`) bedeuten exakte Treffer: der Tippfehler-Fallback bleibt dann aus.
        var trigramActive: Bool {
            guard fuzzy, q.count >= 3 else { return false }
            if q.contains("\"") { return false }
            return !q.split(separator: " ").contains { $0.hasPrefix("-") || $0.lowercased() == "or" }
        }
    }

    static func parse(_ req: Request, tenant: UUID) throws -> Params {
        let raw: String = req.query["q"] ?? ""
        let q = raw.replacingOccurrences(of: "\0", with: "").trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCanonicalMapping
        guard !q.isEmpty else { throw DMSError.invalid("q", "required") }
        guard q.count <= maxQueryLength else { throw DMSError.invalid("q", "too_long") }
        var p = Params(tenant: tenant, q: q, page: try HubPageRequest(req))
        if let f: String = req.query["fuzzy"] {
            guard ["true", "false"].contains(f) else { throw DMSError.invalid("fuzzy") }
            p.fuzzy = f == "true"
        }
        if let f: String = req.query["facets"] {
            guard ["true", "false"].contains(f) else { throw DMSError.invalid("facets") }
            p.facets = f == "true"
        }
        func uuid(_ name: String) throws -> UUID? {
            guard let s: String = req.query[name] else { return nil }
            guard let id = UUID(uuidString: s) else { throw DMSError.invalid(name) }
            return id
        }
        p.typeID = try uuid("document_type_id")
        p.storagePathID = try uuid("storage_path_id")
        p.correspondentID = try uuid("correspondent_id")
        if let s: String = req.query["tag_id"] {
            let parts = s.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            guard parts.count <= maxTags, !parts.isEmpty else { throw DMSError.invalid("tag_id") }
            p.tagIDs = try parts.map { guard let id = UUID(uuidString: $0) else { throw DMSError.invalid("tag_id") }; return id }
        }
        if let s: String = req.query["date_from"] { p.dateFrom = try DMSError.date(s, "date_from") }
        if let s: String = req.query["date_to"] { p.dateTo = try DMSError.date(s, "date_to") }
        return p
    }

    // MARK: SQL

    /// Gemeinsame Treffermenge `(id, score)`: Mandant, Papierkorb, Treffertest und Filter in einem Statement.
    static func hitsSQL(_ p: Params) -> SQLQueryString {
        let q = p.q, plain = p.q
        let tsq: SQLQueryString = "(websearch_to_tsquery('dms_german', \(bind: q)) || websearch_to_tsquery('dms_english', \(bind: q)))"
        var s: SQLQueryString = """
            SELECT d.id, (CASE WHEN d.search_tsv @@ \(tsq) THEN 1 + ts_rank_cd('{0.1, 0.2, 0.4, 1.0}', d.search_tsv, \(tsq), 32)
                               ELSE word_similarity(\(bind: plain)::text, d.trgm_src) END)::float8 AS score
            FROM dms_documents d
            WHERE d.tenant_id = \(bind: p.tenant) AND d.trashed_at IS NULL
              AND (d.search_tsv @@ \(tsq) OR (\(bind: p.trigramActive)::boolean AND \(bind: plain)::text <% d.trgm_src))
            """
        if let id = p.typeID { s += " AND d.document_type_id = \(bind: id)" }
        if let id = p.storagePathID { s += " AND d.storage_path_id = \(bind: id)" }
        if let id = p.correspondentID {
            s += """
                  AND EXISTS (SELECT 1 FROM links l WHERE l.tenant_id = d.tenant_id AND l.from_type = 'dms.document' AND l.from_id = d.id
                    AND l.to_type = 'contact' AND l.kind = 'correspondent' AND l.removed_at IS NULL AND l.to_id = \(bind: id))
                 """
        }
        for tag in p.tagIDs {
            s += " AND EXISTS (SELECT 1 FROM dms_document_tags x WHERE x.tenant_id = d.tenant_id AND x.document_id = d.id AND x.tag_id = \(bind: tag))"
        }
        if let d = p.dateFrom { s += " AND d.doc_date >= \(bind: d)::text::date" }
        if let d = p.dateTo { s += " AND d.doc_date <= \(bind: d)::text::date" }
        return s
    }

    static func run(_ p: Params, on db: any Database) async throws -> DMSSearchPage {

        try await db.transaction { tx in
            let s = try sql(tx)
            try await s.raw("SELECT set_config('pg_trgm.word_similarity_threshold', \(literal: trigramThreshold), true)").run()
            let hits = hitsSQL(p)
            let q = p.q
            let tsq: SQLQueryString = "(websearch_to_tsquery('dms_german', \(bind: q)) || websearch_to_tsquery('dms_english', \(bind: q)))"
            let options = "StartSel=\(startMark), StopSel=\(endMark), MaxFragments=2, MaxWords=30, MinWords=12"

            var curScore: String?, curID: UUID?
            if let c = p.page.cursor {
                guard Double(c.createdAt) != nil else { throw HubError(.badRequest, "invalid_cursor") }
                curScore = c.createdAt; curID = c.id
            }
            let rows = try await s.raw("""
                WITH hits AS (\(hits)),
                page AS (SELECT h.id, h.score FROM hits h
                         WHERE \(bind: curScore)::text IS NULL OR h.score < \(bind: curScore)::float8 OR (h.score = \(bind: curScore)::float8 AND h.id > \(bind: curID)::uuid)
                         ORDER BY h.score DESC, h.id LIMIT \(bind: p.page.limit + 1))
                SELECT d.id, d.title, d.doc_date::text AS doc_date, d.document_type_id, d.storage_path_id,
                  (SELECT l.to_id FROM links l WHERE l.tenant_id = d.tenant_id AND l.from_type = 'dms.document' AND l.from_id = d.id AND l.to_type = 'contact'
                     AND l.kind = 'correspondent' AND l.removed_at IS NULL ORDER BY l.created_at, l.id LIMIT 1) AS correspondent_id,
                  d.asn, d.status, d.created_at, p.score, p.score::text AS score_text,
                  COALESCE(
                    CASE WHEN t.text IS NOT NULL THEN ts_headline((CASE t.lang WHEN 'en' THEN 'dms_english' ELSE 'dms_german' END)::regconfig, left(t.text, 100000), \(tsq), \(bind: options)::text) END,
                    ts_headline('dms_german'::regconfig, d.title, \(tsq), \(bind: options)::text)) AS snippet
                FROM page p JOIN dms_documents d ON d.id = p.id
                LEFT JOIN LATERAL (SELECT x.lang, x.text FROM dms_document_texts x WHERE x.document_id = d.id ORDER BY x.version DESC LIMIT 1) t ON true
                ORDER BY p.score DESC, d.id
                """).all()
            var scoreText: [UUID: String] = [:]
            let hitsOut = try rows.map { r -> DMSSearchHit in
                let id = try r.decode(column: "id", as: UUID.self)
                scoreText[id] = try r.decode(column: "score_text", as: String.self)
                return DMSSearchHit(
                    id: id, title: try r.decode(column: "title", as: String.self), doc_date: try r.decode(column: "doc_date", as: String?.self),
                    document_type_id: try r.decode(column: "document_type_id", as: UUID?.self), storage_path_id: try r.decode(column: "storage_path_id", as: UUID?.self),
                    correspondent_id: try r.decode(column: "correspondent_id", as: UUID?.self), asn: try r.decode(column: "asn", as: Int64?.self),
                    status: try r.decode(column: "status", as: String.self), created_at: iso(try r.decode(column: "created_at", as: Date.self)),
                    score: try r.decode(column: "score", as: Double.self), snippet: try r.decode(column: "snippet", as: String?.self))
            }
            let page = HubPage(fetched: hitsOut, limit: p.page.limit, cursorOf: { PageCursor(createdAt: scoreText[$0.id] ?? "0", id: $0.id) })

            var total: Int?
            if p.page.wantsCount {
                total = Int(try await s.raw("WITH hits AS (\(hits)) SELECT count(*)::bigint AS n FROM hits").first()?.decode(column: "n", as: Int64.self) ?? 0)
            }
            var facets: DMSFacets?
            if p.facets { facets = try await facetsSQL(hits: hits, tenant: p.tenant, on: s) }
            return DMSSearchPage(items: page.items, next_cursor: page.next_cursor, total: total, facets: facets)
        }
    }

    /// Facettenzahlen über die gesamte (gefilterte) Treffermenge, nicht über die Seite; je Facette die häufigsten `facetLimit` Werte.
    static func facetsSQL(hits: SQLQueryString, tenant: UUID, on s: any SQLDatabase) async throws -> DMSFacets {
        let rows = try await s.raw("""
            WITH hits AS (\(hits))
            (SELECT 'document_type' AS facet, d.document_type_id::text AS value, count(*)::bigint AS n FROM hits h JOIN dms_documents d ON d.id = h.id
               WHERE d.document_type_id IS NOT NULL GROUP BY 2 ORDER BY 3 DESC, 2 LIMIT \(literal: facetLimit))
            UNION ALL
            (SELECT 'tag', x.tag_id::text, count(*) FROM hits h JOIN dms_document_tags x ON x.document_id = h.id AND x.tenant_id = \(bind: tenant) GROUP BY 2 ORDER BY 3 DESC, 2 LIMIT \(literal: facetLimit))
            UNION ALL
            (SELECT 'correspondent', l.to_id::text, count(*) FROM hits h JOIN links l ON l.from_id = h.id AND l.tenant_id = \(bind: tenant) AND l.from_type = 'dms.document'
               AND l.to_type = 'contact' AND l.kind = 'correspondent' AND l.removed_at IS NULL GROUP BY 2 ORDER BY 3 DESC, 2 LIMIT \(literal: facetLimit))
            UNION ALL
            (SELECT 'storage_path', d.storage_path_id::text, count(*) FROM hits h JOIN dms_documents d ON d.id = h.id
               WHERE d.storage_path_id IS NOT NULL GROUP BY 2 ORDER BY 3 DESC, 2 LIMIT \(literal: facetLimit))
            UNION ALL
            (SELECT 'year', extract(year FROM d.doc_date)::int::text, count(*) FROM hits h JOIN dms_documents d ON d.id = h.id
               WHERE d.doc_date IS NOT NULL GROUP BY 2 ORDER BY 2 DESC LIMIT \(literal: facetLimit))
            """).all()
        var out = DMSFacets()
        for r in rows {
            let value = try r.decode(column: "value", as: String.self)
            let entry = DMSFacetEntry(value: UUID(uuidString: value)?.uuidString ?? value, count: Int(try r.decode(column: "n", as: Int64.self)))
            switch try r.decode(column: "facet", as: String.self) {
            case "document_type": out.document_type.append(entry)
            case "tag": out.tag.append(entry)
            case "correspondent": out.correspondent.append(entry)
            case "storage_path": out.storage_path.append(entry)
            default: out.year.append(entry)
            }
        }
        return out
    }
}

/// Texte des Dokuments (Revisionen). Für O2 (OCR) und Testbefüllung; die höchste `version` gilt für die Suche, der Trigger führt den Index.
enum DMSTexts {
    /// Fügt eine neue Revision an (Version = höchste + 1); gleichzeitige Schreiber führen zu einer Verletzung von `UNIQUE (document_id, version)`, der Aufrufer wiederholt.
    @discardableResult
    static func add(document: UUID, tenant: UUID, engine: String, lang: String, text: String, quality: Float? = nil, on db: any Database) async throws -> Int {
        let s = try sql(db)
        guard let row = try await s.raw("""
            INSERT INTO dms_document_texts (tenant_id, document_id, version, engine, lang, text, quality)
            SELECT \(bind: tenant), d.id, COALESCE((SELECT max(version) FROM dms_document_texts WHERE document_id = d.id), 0) + 1, \(bind: engine), \(bind: lang), \(bind: text), \(bind: quality)
            FROM dms_documents d WHERE d.id = \(bind: document) AND d.tenant_id = \(bind: tenant)
            RETURNING version
            """).first() else { throw DMSError.notFound }
        return Int(try row.decode(column: "version", as: Int32.self))
    }
}
