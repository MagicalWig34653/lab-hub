import Vapor
import Fluent
import SQLKit

// WP-S1 DMS-Suche (ADR 0005). Modul-Migration `dms_018_search`, expand-only: neue Tabelle, neue Spalten auf `dms_documents`, Funktionen, Trigger, Suchkonfigurationen.
// `schema_version` bleibt unverändert (Modulstände stehen in `_fluent_migrations`).
//
// Aufbau des Index (alles in der Datenbank, kein Zustand in der Instanz):
// - `dms_document_texts`: Revisionen des extrahierten Textes (OCR füllt sie ab O2). Die höchste `version` gilt.
// - `dms_documents.body_tsv`: tsvector des aktuellen Textes (Gewicht C), vom Trigger auf `dms_document_texts` geführt.
// - `dms_documents.meta_text`: Korrespondent, Typ, Tags und Dateiname des Originals als Text, von Triggern geführt.
// - `dms_documents.search_tsv` (generierte Spalte): Titel (A, deutsch + englisch) || Metadaten (B) || Text (C); GIN-Index.
// - `dms_documents.trgm_src` (generierte Spalte): Titel + Metadaten in Kleinschreibung für `pg_trgm` (Tippfehler); GIN-Index.
// Unterstriche und Schrägstriche im Titel sowie alle Satzzeichen im Dateinamen werden zu Leerzeichen (sonst bildet der Parser ein einziges „file“-Token).
// Die Suchkonfigurationen `dms_german` und `dms_english` kopieren `german`/`english` und schalten `unaccent` vor.
// Rechte: `CREATE EXTENSION` für `pg_trgm` und `unaccent` (beide „trusted“ ab PostgreSQL 13) darf der Datenbankbesitzer; Image postgres:17 bringt beide mit.

struct CreateDMSSearch: AsyncMigration {
    let name = "dms_018_search"

    func prepare(on db: any Database) async throws {
        try await run(db, [
            "CREATE EXTENSION IF NOT EXISTS pg_trgm",
            "CREATE EXTENSION IF NOT EXISTS unaccent",
            """
            DO $$ BEGIN
              IF NOT EXISTS (SELECT 1 FROM pg_ts_config WHERE cfgname = 'dms_german' AND cfgnamespace = current_schema()::regnamespace) THEN
                CREATE TEXT SEARCH CONFIGURATION dms_german (COPY = german);
                ALTER TEXT SEARCH CONFIGURATION dms_german ALTER MAPPING FOR asciiword, word, numword, asciihword, hword, numhword, hword_asciipart, hword_part, hword_numpart WITH unaccent, german_stem;
              END IF;
              IF NOT EXISTS (SELECT 1 FROM pg_ts_config WHERE cfgname = 'dms_english' AND cfgnamespace = current_schema()::regnamespace) THEN
                CREATE TEXT SEARCH CONFIGURATION dms_english (COPY = english);
                ALTER TEXT SEARCH CONFIGURATION dms_english ALTER MAPPING FOR asciiword, word, numword, asciihword, hword, numhword, hword_asciipart, hword_part, hword_numpart WITH unaccent, english_stem;
              END IF;
            END $$
            """,
            // Textrevisionen. Der Verweis ist zusammengesetzt (tenant_id, document_id): ein Text an einem fremden Dokument scheitert in der Datenbank.
            """
            CREATE TABLE dms_document_texts (id uuid PRIMARY KEY DEFAULT gen_random_uuid(), tenant_id uuid NOT NULL, document_id uuid NOT NULL,
              version integer NOT NULL CHECK (version >= 1), engine text NOT NULL CHECK (char_length(engine) BETWEEN 1 AND 40),
              lang text NOT NULL DEFAULT 'de' CHECK (lang IN ('de', 'en')),
              text text NOT NULL CHECK (char_length(text) <= 3000000), quality real CHECK (quality IS NULL OR quality BETWEEN 0 AND 1),
              created_at timestamptz NOT NULL DEFAULT now(), UNIQUE (document_id, version),
              FOREIGN KEY (tenant_id, document_id) REFERENCES dms_documents (tenant_id, id))
            """,
            """
            ALTER TABLE dms_documents
              ADD COLUMN meta_text text NOT NULL DEFAULT '',
              ADD COLUMN body_tsv tsvector NOT NULL DEFAULT ''::tsvector,
              ADD COLUMN search_tsv tsvector GENERATED ALWAYS AS (
                setweight(to_tsvector('dms_german'::regconfig, regexp_replace(title, '[_/]+', ' ', 'g')) || to_tsvector('dms_english'::regconfig, regexp_replace(title, '[_/]+', ' ', 'g')), 'A')
                || setweight(to_tsvector('dms_german'::regconfig, meta_text) || to_tsvector('dms_english'::regconfig, meta_text), 'B')
                || body_tsv) STORED,
              ADD COLUMN trgm_src text GENERATED ALWAYS AS (lower(title || ' ' || meta_text)) STORED
            """,
            "CREATE INDEX dms_documents_search_gin ON dms_documents USING gin (search_tsv)",
            "CREATE INDEX dms_documents_trgm ON dms_documents USING gin (trgm_src gin_trgm_ops)",

            // Text -> body_tsv (aktuelle Version = höchste)
            """
            CREATE OR REPLACE FUNCTION dms_sync_body() RETURNS trigger LANGUAGE plpgsql AS $$
            DECLARE doc uuid; cur record;
            BEGIN
              doc := CASE WHEN TG_OP = 'DELETE' THEN OLD.document_id ELSE NEW.document_id END;
              SELECT t.lang, t.text INTO cur FROM dms_document_texts t WHERE t.document_id = doc ORDER BY t.version DESC LIMIT 1;
              UPDATE dms_documents SET body_tsv = CASE WHEN cur.text IS NULL THEN ''::tsvector
                ELSE setweight(to_tsvector(CASE cur.lang WHEN 'en' THEN 'dms_english'::regconfig ELSE 'dms_german'::regconfig END, cur.text), 'C') END
              WHERE id = doc;
              RETURN NULL;
            END $$
            """,
            "CREATE TRIGGER dms_document_texts_sync AFTER INSERT OR UPDATE OR DELETE ON dms_document_texts FOR EACH ROW EXECUTE FUNCTION dms_sync_body()",

            // Metadaten -> meta_text (Korrespondent, Typ, Tags, Dateiname des Originals)
            """
            CREATE OR REPLACE FUNCTION dms_refresh_meta(p_doc uuid) RETURNS void LANGUAGE plpgsql AS $$
            BEGIN
              UPDATE dms_documents d SET meta_text = left(concat_ws(' ',
                (SELECT c.display_name FROM links l JOIN contacts c ON c.id = l.to_id AND c.tenant_id = l.tenant_id
                  WHERE l.tenant_id = d.tenant_id AND l.from_type = 'dms.document' AND l.from_id = d.id AND l.to_type = 'contact'
                    AND l.kind = 'correspondent' AND l.removed_at IS NULL ORDER BY l.created_at, l.id LIMIT 1),
                (SELECT t.name FROM dms_document_types t WHERE t.tenant_id = d.tenant_id AND t.id = d.document_type_id),
                (SELECT string_agg(g.name, ' ' ORDER BY g.name) FROM dms_document_tags x JOIN dms_tags g ON g.tenant_id = x.tenant_id AND g.id = x.tag_id WHERE x.document_id = d.id),
                (SELECT regexp_replace(f.original_name, '[^[:alnum:]]+', ' ', 'g') FROM dms_document_files f WHERE f.document_id = d.id AND f.role = 'original')), 2000)
              WHERE d.id = p_doc;
            END $$
            """,
            """
            CREATE OR REPLACE FUNCTION dms_trg_refresh_doc() RETURNS trigger LANGUAGE plpgsql AS $$
            DECLARE doc uuid;
            BEGIN
              IF TG_TABLE_NAME = 'dms_document_tags' THEN
                IF TG_OP = 'DELETE' THEN doc := OLD.document_id; ELSE doc := NEW.document_id; END IF;
              ELSIF TG_TABLE_NAME = 'dms_document_files' THEN doc := NEW.document_id;
              ELSE doc := NEW.id;
              END IF;
              PERFORM dms_refresh_meta(doc);
              RETURN NULL;
            END $$
            """,
            "CREATE TRIGGER dms_documents_meta_ins AFTER INSERT ON dms_documents FOR EACH ROW EXECUTE FUNCTION dms_trg_refresh_doc()",
            "CREATE TRIGGER dms_documents_meta_upd AFTER UPDATE OF document_type_id ON dms_documents FOR EACH ROW EXECUTE FUNCTION dms_trg_refresh_doc()",
            "CREATE TRIGGER dms_document_tags_meta AFTER INSERT OR DELETE ON dms_document_tags FOR EACH ROW EXECUTE FUNCTION dms_trg_refresh_doc()",
            "CREATE TRIGGER dms_document_files_meta AFTER INSERT ON dms_document_files FOR EACH ROW WHEN (NEW.role = 'original') EXECUTE FUNCTION dms_trg_refresh_doc()",
            // Korrespondent (Kern-links)
            """
            CREATE OR REPLACE FUNCTION dms_trg_refresh_link() RETURNS trigger LANGUAGE plpgsql AS $$
            BEGIN
              IF NEW.from_type = 'dms.document' AND NEW.kind = 'correspondent' THEN PERFORM dms_refresh_meta(NEW.from_id); END IF;
              RETURN NULL;
            END $$
            """,
            "CREATE TRIGGER dms_links_meta AFTER INSERT OR UPDATE ON links FOR EACH ROW EXECUTE FUNCTION dms_trg_refresh_link()",
            // Umbenennung von Kontakt, Tag, Dokumenttyp
            """
            CREATE OR REPLACE FUNCTION dms_trg_refresh_rename() RETURNS trigger LANGUAGE plpgsql AS $$
            BEGIN
              IF TG_TABLE_NAME = 'contacts' THEN
                PERFORM dms_refresh_meta(l.from_id) FROM links l WHERE l.tenant_id = NEW.tenant_id AND l.to_type = 'contact' AND l.to_id = NEW.id
                  AND l.from_type = 'dms.document' AND l.kind = 'correspondent' AND l.removed_at IS NULL;
              ELSIF TG_TABLE_NAME = 'dms_tags' THEN
                PERFORM dms_refresh_meta(x.document_id) FROM dms_document_tags x WHERE x.tag_id = NEW.id;
              ELSE
                PERFORM dms_refresh_meta(d.id) FROM dms_documents d WHERE d.tenant_id = NEW.tenant_id AND d.document_type_id = NEW.id;
              END IF;
              RETURN NULL;
            END $$
            """,
            "CREATE TRIGGER dms_contacts_meta AFTER UPDATE OF display_name ON contacts FOR EACH ROW WHEN (OLD.display_name IS DISTINCT FROM NEW.display_name) EXECUTE FUNCTION dms_trg_refresh_rename()",
            "CREATE TRIGGER dms_tags_meta AFTER UPDATE OF name ON dms_tags FOR EACH ROW WHEN (OLD.name IS DISTINCT FROM NEW.name) EXECUTE FUNCTION dms_trg_refresh_rename()",
            "CREATE TRIGGER dms_document_types_meta AFTER UPDATE OF name ON dms_document_types FOR EACH ROW WHEN (OLD.name IS DISTINCT FROM NEW.name) EXECUTE FUNCTION dms_trg_refresh_rename()"])
    }

    func revert(on db: any Database) async throws {
        try await run(db, [
            "DROP TRIGGER dms_contacts_meta ON contacts", "DROP TRIGGER dms_links_meta ON links",
            "DROP TRIGGER dms_tags_meta ON dms_tags", "DROP TRIGGER dms_document_types_meta ON dms_document_types",
            "DROP TRIGGER dms_document_tags_meta ON dms_document_tags", "DROP TRIGGER dms_document_files_meta ON dms_document_files",
            "DROP TRIGGER dms_documents_meta_ins ON dms_documents", "DROP TRIGGER dms_documents_meta_upd ON dms_documents",
            "DROP TABLE dms_document_texts",
            "ALTER TABLE dms_documents DROP COLUMN search_tsv, DROP COLUMN trgm_src, DROP COLUMN body_tsv, DROP COLUMN meta_text",
            "DROP FUNCTION dms_sync_body()", "DROP FUNCTION dms_refresh_meta(uuid)", "DROP FUNCTION dms_trg_refresh_doc()", "DROP FUNCTION dms_trg_refresh_link()",
            "DROP FUNCTION dms_trg_refresh_rename()",
            "DROP TEXT SEARCH CONFIGURATION IF EXISTS dms_german", "DROP TEXT SEARCH CONFIGURATION IF EXISTS dms_english"])
        // Die Erweiterungen pg_trgm und unaccent bleiben bestehen (können von anderen Teilen genutzt werden).
    }
}
