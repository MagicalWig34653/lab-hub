import Vapor
import Fluent
import SQLKit
import HubCore

// WP-R6c Render-Ergebnisse und Render-Aufträge zu finalen Belegen. Modul-Migration, Expand-only (zwei neue Tabellen, kein Eingriff in bestehende).
// Finale Belege sind per Trigger unveränderlich (`invoice_028_documents`), daher steht das Ergebnis des Renderns in einer eigenen Tabelle.
// Invarianten stehen in der Datenbank, nicht nur im Job:
//  1. Je Beleg höchstens eine Zustandszeile (`UNIQUE (document_id)`); sie entsteht nur für einen finalen Beleg, nur mit dem Inhalt-Hash dieses Belegs
//     und nur mit einer Datei desselben Mandanten und derselben Prüfsumme.
//  2. Eine Zustandszeile wird nie geändert und nie gelöscht (auch nicht per TRUNCATE): ein fertiges PDF bleibt, wie es ist.
//  3. Der Fremdschlüssel auf `files` hat kein CASCADE und kein SET NULL: Solange ein Beleg-PDF die Datei referenziert, kann keine Löschfunktion
//     (DMS-Löschen, Aufräumen unreferenzierter Bytes) die `files`-Zeile entfernen; ohne `files`-Zeile bleiben auch die Bytes (alle Aufräumwege prüfen sie).
//  `invoice_render_jobs` ist die einzige veränderliche Tabelle: sie merkt sich den jüngsten Auftrag je Beleg (für Status und Wiederholung).

struct CreateInvoiceRender: AsyncMigration {
    let name = "invoice_030_render"

    func prepare(on db: any Database) async throws {
        try await run(db, [
            """
            CREATE TABLE invoice_render_states (id uuid PRIMARY KEY DEFAULT gen_random_uuid(), tenant_id uuid NOT NULL, document_id uuid NOT NULL,
              layout_key text NOT NULL CHECK (char_length(layout_key) BETWEEN 1 AND 64), layout_version integer NOT NULL CHECK (layout_version >= 1),
              input_hash text NOT NULL CHECK (char_length(input_hash) BETWEEN 1 AND 128), pdf_sha256 text NOT NULL CHECK (pdf_sha256 ~ '^[0-9a-f]{64}$'),
              file_id uuid NOT NULL REFERENCES files (id) ON DELETE RESTRICT, renderer_version text NOT NULL CHECK (char_length(renderer_version) BETWEEN 1 AND 128),
              created_at timestamptz NOT NULL DEFAULT now(),
              UNIQUE (document_id), FOREIGN KEY (tenant_id, document_id) REFERENCES invoice_documents (tenant_id, id) ON DELETE RESTRICT)
            """,
            """
            CREATE OR REPLACE FUNCTION invoice_render_states_guard() RETURNS trigger LANGUAGE plpgsql AS $$
            DECLARE d invoice_documents%ROWTYPE;
            BEGIN
              IF TG_OP <> 'INSERT' THEN RAISE EXCEPTION 'render state is immutable' USING ERRCODE = '23000'; END IF;
              SELECT * INTO d FROM invoice_documents WHERE id = NEW.document_id AND tenant_id = NEW.tenant_id;
              IF NOT FOUND OR d.status <> 'final' OR d.content_hash IS DISTINCT FROM NEW.input_hash THEN
                RAISE EXCEPTION 'render state needs a final document with the same content hash' USING ERRCODE = '23000';
              END IF;
              IF NOT EXISTS (SELECT 1 FROM files f WHERE f.id = NEW.file_id AND f.tenant_id = NEW.tenant_id AND f.sha256 = NEW.pdf_sha256) THEN
                RAISE EXCEPTION 'render state needs a file of the same tenant with the same checksum' USING ERRCODE = '23503';
              END IF;
              RETURN NEW;
            END $$
            """,
            "CREATE TRIGGER invoice_render_states_guard BEFORE INSERT OR UPDATE OR DELETE ON invoice_render_states FOR EACH ROW EXECUTE FUNCTION invoice_render_states_guard()",
            """
            CREATE OR REPLACE FUNCTION invoice_render_states_no_truncate() RETURNS trigger LANGUAGE plpgsql AS $$
            BEGIN RAISE EXCEPTION 'render states are never truncated' USING ERRCODE = '23000'; END $$
            """,
            "CREATE TRIGGER invoice_render_states_no_truncate BEFORE TRUNCATE ON invoice_render_states FOR EACH STATEMENT EXECUTE FUNCTION invoice_render_states_no_truncate()",
            // Jüngster Auftrag je Beleg. Kein Fremdschlüssel auf `jobs`: Aufträge können nach Aufbewahrungsfrist entfernt werden, der Status fällt dann auf „nicht gestartet“.
            """
            CREATE TABLE invoice_render_jobs (document_id uuid PRIMARY KEY, tenant_id uuid NOT NULL, job_id uuid NOT NULL,
              created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now(),
              FOREIGN KEY (tenant_id, document_id) REFERENCES invoice_documents (tenant_id, id) ON DELETE RESTRICT)
            """,
            "CREATE INDEX invoice_render_jobs_job ON invoice_render_jobs (job_id)"])
    }

    func revert(on db: any Database) async throws {
        try await run(db, [
            "DROP TABLE invoice_render_jobs",
            "DROP TABLE invoice_render_states",
            "DROP FUNCTION invoice_render_states_no_truncate()", "DROP FUNCTION invoice_render_states_guard()"])
    }
}
