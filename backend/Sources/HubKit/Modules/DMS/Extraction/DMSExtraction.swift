import Vapor
import Fluent
import SQLKit
import Crypto

// WP-D7: Ingest-Schritt „Extraktion“ (zwischen ocr_done und classified, direkt nach der Klassifikation aus D3) und Speicherung.
// - Migration `dms_024_extraction` (Modul, expand-only, `schema_version` unverändert): `dms_extractions` (je Dokument genau eine Zeile: Art, Score, Fakten als JSON mit Quelle,
//   Extraktorversion, Text-Hash; die wichtigsten Fakten zusätzlich als Übersichtsspalten für Filter/Sortierung, bewusst ohne Vorzugsbehandlung einer Dokumentart),
//   `dms_event_outbox` (schlanke interne Outbox für „Dokument klassifiziert“; K7/X1 lesen später mit `FOR UPDATE SKIP LOCKED` und setzen `delivered_at`),
//   Erweiterung von `dms_suggestions` um die Quelle `extraction`.
// - Läuft in der Transaktion des Aufrufers (OCR-Handler, Mail-Aufnahme, Neu-Lauf) unter der Zeilensperre des Dokuments: ein Ergebnis je Dokument, auch mit zwei Workern.
// - Nichts wird angewendet: Vorschläge (Dokumentart -> Dokumenttyp, Datum, Titel) sind `open`. Der Korrespondent kommt aus dem Kontakt-Abgleich (D3) über IBAN/USt-ID im Text.

struct CreateDMSExtraction: AsyncMigration {
    let name = "dms_024_extraction"
    func prepare(on db: any Database) async throws {
        try await run(db, [
            """
            CREATE TABLE dms_extractions (document_id uuid PRIMARY KEY, tenant_id uuid NOT NULL,
              extractor_version integer NOT NULL CHECK (extractor_version >= 1),
              text_sha256 text NOT NULL CHECK (text_sha256 ~ '^[0-9a-f]{64}$'),
              kind text NOT NULL CHECK (kind ~ '^[a-z_]{1,40}$'),
              kind_score numeric(4,3) NOT NULL CHECK (kind_score BETWEEN 0 AND 1), kind_certain boolean NOT NULL,
              kind_reasons jsonb NOT NULL, scores jsonb NOT NULL, facts jsonb NOT NULL,
              amount numeric(14,2), currency text CHECK (currency IS NULL OR currency ~ '^[A-Z]{3}$'),
              extracted_date date, due_date date, reference text CHECK (reference IS NULL OR char_length(reference) <= 100),
              runs integer NOT NULL DEFAULT 1, created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now(),
              FOREIGN KEY (tenant_id, document_id) REFERENCES dms_documents (tenant_id, id))
            """,
            "CREATE INDEX dms_extractions_kind ON dms_extractions (tenant_id, kind, document_id)",
            "CREATE INDEX dms_extractions_amount ON dms_extractions (tenant_id, amount, document_id) WHERE amount IS NOT NULL",
            "CREATE INDEX dms_extractions_date ON dms_extractions (tenant_id, extracted_date, document_id) WHERE extracted_date IS NOT NULL",
            "CREATE INDEX dms_extractions_due ON dms_extractions (tenant_id, due_date, document_id) WHERE due_date IS NOT NULL",
            "CREATE INDEX dms_extractions_reference ON dms_extractions (tenant_id, reference) WHERE reference IS NOT NULL",
            """
            CREATE TABLE dms_event_outbox (id uuid PRIMARY KEY DEFAULT gen_random_uuid(), tenant_id uuid NOT NULL,
              type text NOT NULL CHECK (type ~ '^[a-z][a-z0-9_.]{0,63}$'), subject_id uuid NOT NULL, dedup_key text NOT NULL CHECK (char_length(dedup_key) <= 200),
              payload jsonb NOT NULL, created_at timestamptz NOT NULL DEFAULT now(), delivered_at timestamptz,
              UNIQUE (tenant_id, type, subject_id, dedup_key))
            """,
            "CREATE INDEX dms_event_outbox_pending ON dms_event_outbox (created_at, id) WHERE delivered_at IS NULL",
            "ALTER TABLE dms_suggestions DROP CONSTRAINT IF EXISTS dms_suggestions_source_check",
            "ALTER TABLE dms_suggestions ADD CONSTRAINT dms_suggestions_source_check CHECK (source IN ('rule', 'contact_match', 'extraction'))"])
    }
    func revert(on db: any Database) async throws {
        try await run(db, [
            "DELETE FROM dms_suggestions WHERE source = 'extraction'",
            "ALTER TABLE dms_suggestions DROP CONSTRAINT IF EXISTS dms_suggestions_source_check",
            "ALTER TABLE dms_suggestions ADD CONSTRAINT dms_suggestions_source_check CHECK (source IN ('rule', 'contact_match'))",
            "DROP TABLE dms_event_outbox", "DROP TABLE dms_extractions"])
    }
}

// MARK: Lesemodell (stabile interne Schnittstelle für andere Module)

/// Typisiertes Faktenprofil einer Rechnung (für das Rechnungsmodul, WP X1: Eingangsrechnung-Vorschlag). Beträge sind Dezimalzeichenketten.
struct InvoiceProfile: Content, Sendable, Equatable {
    let number: String?
    let issue_date: String?
    let due_date: String?
    let gross: String?
    let net: String?
    let tax: String?
    let currency: String?
    let seller_name: String?
    let seller_iban: String?
    let seller_vat_id: String?
}

/// `DocumentFacts`: lesende Sicht auf das Extraktionsergebnis eines Dokuments. Andere Module (Rechnung, später weitere) lesen NUR hierüber und
/// schlagen Verknüpfungen vor (Bestätigung nötig, F-25); sie schreiben nie in `dms_extractions`.
struct DocumentFacts: Sendable {
    let documentID: UUID
    let kind: DocumentKind
    let kindScore: Double
    let kindCertain: Bool
    let extractorVersion: Int
    let facts: [ExtractedFact]
    let reasons: [String]
    let updatedAt: Date

    func fact(_ type: FactType) -> ExtractedFact? {
        facts.filter { $0.type == type.rawValue }.sorted { ($0.confidence, -($0.source?.offset ?? 0)) > ($1.confidence, -($1.source?.offset ?? 0)) }.first
    }

    /// Nur für Rechnungen (Art `invoice`); die Zuordnung der Fakten steht hier an einer Stelle.
    var invoice: InvoiceProfile? {
        guard kind == .invoice else { return nil }
        return InvoiceProfile(number: fact(.invoiceNumber)?.value, issue_date: fact(.date)?.value, due_date: fact(.dueDate)?.value, gross: fact(.amountGross)?.value,
                              net: fact(.amountNet)?.value, tax: fact(.amountTax)?.value,
                              currency: fact(.amountGross)?.currency ?? fact(.amountNet)?.currency, seller_name: fact(.seller)?.value, seller_iban: fact(.iban)?.value, seller_vat_id: fact(.vatID)?.value)
    }
}

struct DMSFactOut: Content, Sendable {
    let type: String
    let value: String
    let currency: String?
    let confidence: Double
    let reason: String
    let source: FactSource?
}

struct DMSExtractionOut: Content, Sendable {
    let kind: String
    let kind_score: Double
    let kind_certain: Bool
    let extractor_version: Int
    let amount: String?
    let currency: String?
    let extracted_date: String?
    let due_date: String?
    let reference: String?
    let updated_at: String
    /// Nur in der Detailansicht und unter `documents/{id}/extraction`.
    var reasons: [String]?
    var facts: [DMSFactOut]?
    var invoice: InvoiceProfile?
}

extension FactSource: @unchecked Sendable {}

enum DMSExtraction {
    static let eventType = "dms.document.classified"

    // MARK: Zusammenfassung für Übersicht/Filter

    struct Summary: Equatable {
        var amount: String?, currency: String?, date: String?, due: String?, reference: String?
    }

    /// Übersichtswerte gelten für jede Art, kommen aber je Art aus dem passenden Fakt (WP-D8, `docs/MODUL-DMS.md` „Dokumentarten und Fakten“):
    /// Betrag = Rechnung Brutto, Vertrag wiederkehrender Betrag, Versicherung Beitrag, Behörde Zahlbetrag/Erstattung (vorzeichenbehaftet), Kontoauszug Endsaldo, sonst `amount`.
    /// Fälligkeit/Frist = die früheste bekannte Frist (Fälligkeit, Zahlungs-/Einspruchsfrist, Frist), beim Vertrag das Vertragsende, bei der Versicherung Fälligkeit, sonst Ablauf.
    static func summary(_ r: ExtractionResult) -> Summary {
        func best(_ t: FactType) -> ExtractedFact? {
            r.facts(t).sorted { ($0.confidence, -($0.source?.offset ?? 0)) > ($1.confidence, -($1.source?.offset ?? 0)) }.first
        }
        func earliest(_ types: [FactType]) -> String? { types.flatMap { r.facts($0) }.map(\.value).min() }
        let money: ExtractedFact?
        let due: String?
        let reference: ExtractedFact?
        switch r.kind {
        case .contract:
            money = best(.recurringAmount) ?? best(.amount); due = best(.periodEnd)?.value ?? best(.dueDate)?.value; reference = best(.contractNumber) ?? best(.reference)
        case .insurance:
            money = best(.premium) ?? best(.amount); due = best(.dueDate)?.value ?? best(.periodEnd)?.value; reference = best(.policyNumber) ?? best(.reference)
        case .taxNotice, .letter:
            money = best(.settlementAmount) ?? best(.amount); due = earliest([.dueDate, .objectionDeadline, .deadline]); reference = best(.reference)
        case .bankStatement:
            money = best(.balanceClosing); due = nil; reference = best(.iban)
        default:
            money = best(.amountGross) ?? best(.amount); due = best(.dueDate)?.value; reference = best(.invoiceNumber) ?? best(.reference)
        }
        return Summary(amount: money?.value, currency: money?.currency, date: best(.date)?.value, due: due, reference: reference.map { String($0.value.prefix(100)) })
    }

    // MARK: Laden

    static func loadFacts(document: UUID, tenant: UUID, on s: any SQLDatabase) async throws -> DocumentFacts? {
        guard let r = try await s.raw("""
            SELECT kind, kind_score::float8 AS kind_score, kind_certain, extractor_version, facts::text AS facts, kind_reasons::text AS reasons, updated_at
            FROM dms_extractions WHERE tenant_id = \(bind: tenant) AND document_id = \(bind: document)
            """).first() else { return nil }
        let facts = (try? JSONDecoder().decode([ExtractedFact].self, from: Data(try r.decode(column: "facts", as: String.self).utf8))) ?? []
        let reasons = (try? JSONDecoder().decode([String].self, from: Data(try r.decode(column: "reasons", as: String.self).utf8))) ?? []
        return DocumentFacts(documentID: document, kind: DocumentKind(rawValue: try r.decode(column: "kind", as: String.self)) ?? .other,
                             kindScore: try r.decode(column: "kind_score", as: Double.self), kindCertain: try r.decode(column: "kind_certain", as: Bool.self),
                             extractorVersion: Int(try r.decode(column: "extractor_version", as: Int32.self)), facts: facts, reasons: reasons,
                             updatedAt: try r.decode(column: "updated_at", as: Date.self))
    }

    static func out(_ f: DocumentFacts, detail: Bool) -> DMSExtractionOut {
        let s = summary(ExtractionResult(kind: f.kind, kindScore: f.kindScore, kindCertain: f.kindCertain, reasons: f.reasons, scores: [], facts: f.facts))
        var o = DMSExtractionOut(kind: f.kind.rawValue, kind_score: f.kindScore, kind_certain: f.kindCertain, extractor_version: f.extractorVersion, amount: s.amount, currency: s.currency,
                                 extracted_date: s.date, due_date: s.due, reference: s.reference, updated_at: iso(f.updatedAt))
        if detail {
            o.reasons = f.reasons
            o.facts = f.facts.map { DMSFactOut(type: $0.type, value: $0.value, currency: $0.currency, confidence: $0.confidence, reason: $0.reason, source: $0.source) }
            o.invoice = f.invoice
        }
        return o
    }

    // MARK: Lauf

    private struct DocRow { var title: String; var docDate: String?; var typeID: UUID?; var filename: String?; var sender: String?; var trashed: Bool }

    private static func canonical(_ facts: [ExtractedFact]) -> String {
        let enc = JSONEncoder(); enc.outputFormatting = [.sortedKeys]
        return String(decoding: (try? enc.encode(facts)) ?? Data("[]".utf8), as: UTF8.self)
    }

    private static func json<T: Encodable>(_ v: T) -> String {
        let enc = JSONEncoder(); enc.outputFormatting = [.sortedKeys]
        return String(decoding: (try? enc.encode(v)) ?? Data("null".utf8), as: UTF8.self)
    }

    /// Extrahiert, speichert (ein Ergebnis je Dokument), legt Vorschläge und das Ereignis an. In der Transaktion des Aufrufers.
    /// `rerun`: ausdrücklicher Neu-Lauf (zählt hoch); sonst Ingest. Gleicher Text + gleiche Version = gleiche Zeile, keine doppelten Vorschläge/Ereignisse.
    @discardableResult
    static func run(document: UUID, tenant: UUID, text: String, subject: String? = nil, requestID: String? = nil, ingestItem: UUID? = nil, actor: UUID? = nil, rerun: Bool = false,
                    on db: any Database) async throws -> ExtractionResult {
        let s = try sql(db)
        guard let d = try await s.raw("""
            SELECT d.title, d.doc_date::text AS doc_date, d.document_type_id, d.trashed_at,
              (SELECT f.original_name FROM dms_document_files f WHERE f.document_id = d.id AND f.role = 'original') AS filename,
              (SELECT i.sender FROM dms_ingest_items i WHERE i.tenant_id = d.tenant_id AND i.document_id = d.id ORDER BY i.created_at DESC, i.id DESC LIMIT 1) AS sender
            FROM dms_documents d WHERE d.tenant_id = \(bind: tenant) AND d.id = \(bind: document) FOR UPDATE
            """).first() else { throw DMSError.notFound }
        let row = DocRow(title: try d.decode(column: "title", as: String.self), docDate: try d.decode(column: "doc_date", as: String?.self), typeID: try d.decode(column: "document_type_id", as: UUID?.self),
                         filename: try d.decode(column: "filename", as: String?.self), sender: try d.decode(column: "sender", as: String?.self),
                         trashed: try d.decode(column: "trashed_at", as: Date?.self) != nil)
        let result = DocumentExtractor.extract(ExtractionInput(text: text, subject: subject, sender: row.sender, filename: row.filename))
        let sum = summary(result)
        let textHash = SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
        let scores = result.scores.map { ["kind": $0.kind.rawValue, "score": String($0.score)] }
        try await s.raw("""
            INSERT INTO dms_extractions (document_id, tenant_id, extractor_version, text_sha256, kind, kind_score, kind_certain, kind_reasons, scores, facts, amount, currency, extracted_date, due_date, reference)
            VALUES (\(bind: document), \(bind: tenant), \(bind: ExtractionResult.version), \(bind: textHash), \(bind: result.kind.rawValue), \(bind: result.kindScore), \(bind: result.kindCertain),
                    \(bind: json(result.reasons))::text::jsonb, \(bind: json(scores))::text::jsonb, \(bind: canonical(result.facts))::text::jsonb, \(bind: sum.amount)::text::numeric,
                    \(bind: sum.currency), \(bind: sum.date)::text::date, \(bind: sum.due)::text::date, \(bind: sum.reference))
            ON CONFLICT (document_id) DO UPDATE SET extractor_version = EXCLUDED.extractor_version, text_sha256 = EXCLUDED.text_sha256, kind = EXCLUDED.kind, kind_score = EXCLUDED.kind_score,
              kind_certain = EXCLUDED.kind_certain, kind_reasons = EXCLUDED.kind_reasons, scores = EXCLUDED.scores, facts = EXCLUDED.facts, amount = EXCLUDED.amount, currency = EXCLUDED.currency,
              extracted_date = EXCLUDED.extracted_date, due_date = EXCLUDED.due_date, reference = EXCLUDED.reference, runs = dms_extractions.runs + 1, updated_at = now()
            """).run()
        // Ereignis „Dokument klassifiziert“ (Outbox): je (Version, Text, Art) genau eines
        let payload = json(["document_id": document.uuidString.lowercased(), "kind": result.kind.rawValue, "kind_certain": result.kindCertain ? "true" : "false",
                            "extractor_version": String(ExtractionResult.version)])
        try await s.raw("""
            INSERT INTO dms_event_outbox (tenant_id, type, subject_id, dedup_key, payload)
            VALUES (\(bind: tenant), \(bind: eventType), \(bind: document), \(bind: "v\(ExtractionResult.version):\(textHash.prefix(16)):\(result.kind.rawValue):\(result.kindCertain)"), \(bind: payload)::text::jsonb)
            ON CONFLICT DO NOTHING
            """).run()
        var suggestions = 0
        if !row.trashed { suggestions = try await suggest(result, row: row, document: document, tenant: tenant, ingestItem: ingestItem, on: s) }
        try await AuditLog.record(AuditEvent(action: rerun ? "dms.extraction.rerun" : "dms.extraction.completed", actor: actor, tenant: tenant, subjectType: "dms.document", subjectID: document.uuidString,
                                             meta: ["kind": .safe(result.kind.rawValue), "certain": .number(result.kindCertain ? 1 : 0), "facts": .number(Int64(result.facts.count)),
                                                    "suggestions": .number(Int64(suggestions)), "version": .number(Int64(ExtractionResult.version))], requestID: requestID), on: s)
        return result
    }

    // MARK: Vorschläge

    /// Dokumenttyp-Namen je Art (Code oder Name ohne Beachtung der Schreibweise). Ein fehlender Typ ergibt keinen Vorschlag; Stammdaten legt der Extraktor nie an.
    static let typeNames: [DocumentKind: [String]] = [
        .invoice: ["invoice", "rechnung", "eingangsrechnung", "rechnungen"], .reminder: ["reminder", "mahnung", "zahlungserinnerung"], .receipt: ["receipt", "quittung", "kassenbon", "beleg"],
        .contract: ["contract", "vertrag"], .insurance: ["insurance", "versicherung"], .bankStatement: ["bank_statement", "kontoauszug"],
        .taxNotice: ["tax_notice", "steuerbescheid", "finanzamt"], .letter: ["letter", "brief", "behoerdenbrief", "behördenbrief"]]

    private static func suggest(_ r: ExtractionResult, row: DocRow, document: UUID, tenant: UUID, ingestItem: UUID?, on s: any SQLDatabase) async throws -> Int {
        guard r.kind != .other else { return 0 }
        struct C { let kind: String; let value: [String: String]; let key: String; let confidence: Double; let reason: String; let evidence: [String: String] }
        var list: [C] = []
        let ev = ["extractor_version": String(ExtractionResult.version), "kind": r.kind.rawValue]
        let kindConfidence = (r.kindScore * 0.9 * 1000).rounded() / 1000
        if row.typeID == nil, let names = typeNames[r.kind] {
            if let t = try await s.raw("""
                SELECT id FROM dms_document_types WHERE tenant_id = \(bind: tenant) AND (code = ANY(\(bind: names)::text[]) OR lower(name) = ANY(\(bind: names)::text[])) ORDER BY created_at, id LIMIT 1
                """).first() {
                let id = try t.decode(column: "id", as: UUID.self).uuidString.lowercased()
                list.append(C(kind: "type", value: ["document_type_id": id], key: id, confidence: kindConfidence,
                              reason: "Dokumentart erkannt: \(r.kind.rawValue) (Score \(DocumentExtractor.fmt(r.kindScore))\(r.kindCertain ? "" : ", unsicher"))", evidence: ev))
            }
        }
        if row.docDate == nil, let date = r.facts(.date).max(by: { ($0.confidence, -($0.source?.offset ?? 0)) < ($1.confidence, -($1.source?.offset ?? 0)) }), date.confidence >= 0.6 {
            list.append(C(kind: "date", value: ["doc_date": date.value], key: date.value, confidence: (date.confidence * 0.9 * 1000).rounded() / 1000, reason: "Belegdatum aus dem Text: " + date.reason,
                          evidence: ev.merging(["offset": String(date.source?.offset ?? -1), "excerpt": date.source?.excerpt ?? ""]) { a, _ in a }))
        }
        let stem = row.filename.map { ($0 as NSString).deletingPathExtension }
        if row.title == "Dokument" || row.title == stem.map({ String($0.prefix(300)) }) {
            var title: String?
            var reason = ""
            if r.kind == .invoice, let number = r.first(.invoiceNumber) {
                title = ["Rechnung", r.first(.seller)?.value, number.value].compactMap { $0 }.joined(separator: " "); reason = "Titel aus Aussteller und Rechnungsnummer"
            } else if let t = r.first(.title) { title = t.value; reason = "Titel aus dem Betreff" }
            if let title, let clean = try? DMSError.title(String(title.prefix(300))), clean != row.title {
                list.append(C(kind: "title", value: ["title": clean], key: String(clean.prefix(400)), confidence: 0.6, reason: reason, evidence: ev))
            }
        }
        var inserted = 0
        for c in list {
            if try await s.raw("""
                INSERT INTO dms_suggestions (tenant_id, document_id, ingest_item_id, kind, value, value_key, source, confidence, reason, evidence)
                VALUES (\(bind: tenant), \(bind: document), \(bind: ingestItem), \(bind: c.kind), \(bind: DMSRuleJSON.encode(c.value))::text::jsonb, \(bind: c.key), 'extraction', \(bind: c.confidence),
                        \(bind: String(c.reason.prefix(400))), \(bind: DMSRuleJSON.encode(c.evidence))::text::jsonb)
                ON CONFLICT DO NOTHING RETURNING id
                """).first() != nil { inserted += 1 }
        }
        return inserted
    }

    // MARK: Neu-Lauf (Route)

    /// Wiederholt die Extraktion mit dem zuletzt gespeicherten Text. Papierkorb: 409; kein Text: 409 (`conflict`, Detail `no_text`); fremdes Dokument: 404.
    static func rerun(document: UUID, tenant: UUID, actor: UUID, requestID: String, on db: any Database) async throws -> DMSExtractionOut {
        try await dmsTransaction(db) { tx, s in
            guard let doc = try await s.raw("SELECT trashed_at FROM dms_documents WHERE tenant_id = \(bind: tenant) AND id = \(bind: document) FOR UPDATE").first() else { throw DMSError.notFound }
            if try doc.decode(column: "trashed_at", as: Date?.self) != nil { throw DMSError.trashed }
            guard let t = try await s.raw("SELECT text FROM dms_document_texts WHERE tenant_id = \(bind: tenant) AND document_id = \(bind: document) ORDER BY version DESC LIMIT 1").first()
            else { throw HubError(.conflict, "conflict", detail: "no_text") }
            _ = try await run(document: document, tenant: tenant, text: try t.decode(column: "text", as: String.self), requestID: requestID, actor: actor, rerun: true, on: tx)
            guard let f = try await loadFacts(document: document, tenant: tenant, on: s) else { throw DMSError.notFound }
            return out(f, detail: true)
        }
    }
}

/// Gemeinsamer Textschritt von OCR-Handler und Mail-Aufnahme: Klassifikation (D3), dann Extraktion (D7). Eine Stelle, damit beide Wege gleich laufen.
enum DMSTextStep {
    static func complete(item: UUID, document: UUID, tenant: UUID, text: String, requestID: String? = nil, on db: any Database) async throws {
        try await DMSClassify.run(item: item, document: document, tenant: tenant, text: text, requestID: requestID, on: db)
        try await DMSExtraction.run(document: document, tenant: tenant, text: text, requestID: requestID, ingestItem: item, on: db)
    }
}

/// Abfrageparameter der Dokumentliste für die Extraktion (strikt geprüft, 422 mit Feldnamen).
enum DMSExtractionQuery {
    /// `allowRelevance`: die Suche kennt zusätzlich `sort=relevance` (Standard); das lässt `apply` unberührt.
    static func apply(_ req: Request, to f: inout DMSDocuments.Filter, allowRelevance: Bool = false) throws {
        if let kind: String = req.query["kind"] {
            guard DocumentKind(rawValue: kind) != nil else { throw DMSError.invalid("kind") }
            f.kind = kind
        }
        if let raw: String = req.query["kind_certain"] {
            guard raw == "true" || raw == "false" else { throw DMSError.invalid("kind_certain") }
            f.kindCertain = raw == "true"
        }
        if let c: String = req.query["currency"] {
            guard c.range(of: "^[A-Z]{3}$", options: .regularExpression) != nil else { throw DMSError.invalid("currency") }
            f.currency = c
        }
        for (name, keyPath) in [("amount_min", \DMSDocuments.Filter.amountMin), ("amount_max", \.amountMax)] {
            if let v: String = req.query[name] {
                guard v.range(of: "^-?[0-9]{1,13}(\\.[0-9]{1,2})?$", options: .regularExpression) != nil else { throw DMSError.invalid(name) }
                f[keyPath: keyPath] = v
            }
        }
        for (name, keyPath) in [("extracted_from", \DMSDocuments.Filter.extractedFrom), ("extracted_to", \.extractedTo), ("due_from", \.dueFrom), ("due_to", \.dueTo)] {
            if let v: String = req.query[name] { f[keyPath: keyPath] = try DMSError.date(v, name) }
        }
        if let r: String = req.query["reference"] {
            guard !r.isEmpty, r.count <= 100 else { throw DMSError.invalid("reference") }
            f.reference = r
        }
        // WP-D9: Quelle und offene Vorschläge (Liste und Suche gleich)
        if let raw: String = req.query["source"] {
            guard DMSDocumentSource(rawValue: raw) != nil else { throw DMSError.invalid("source") }
            f.source = raw
        }
        if let raw: String = req.query["has_open_suggestions"] {
            guard raw == "true" || raw == "false" else { throw DMSError.invalid("has_open_suggestions") }
            f.hasOpenSuggestions = raw == "true"
        }
        if let sort: String = req.query["sort"], !(allowRelevance && sort == "relevance") {
            guard ["created_at", "amount", "extracted_date", "due_date"].contains(sort) else { throw DMSError.invalid("sort") }
            f.sort = sort
        }
        if let order: String = req.query["order"] {
            guard order == "asc" || order == "desc" else { throw DMSError.invalid("order") }
            f.descending = order == "desc"
        }
    }
}
