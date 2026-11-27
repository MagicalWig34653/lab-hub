import Vapor
import Fluent
import SQLKit
import HubCore

// WP-R6d: Layoutmodell V1. Modul-Migration, Expand-only: neue Tabellen und eine neue, leere Spalte `invoice_documents.layout_version_id`.
//  - `invoice_layouts`: Layout je Mandant (Name). `invoice_layout_versions`: unveränderliche, fortlaufende Versionen mit den Parametern (JSON, `schema`).
//  - `invoice_layout_assets`: geprüfte Logos je Mandant und SHA-256 (Bytes im Objektspeicher, `files`-Zeile; Fremdschlüssel ohne CASCADE: kein Aufräumweg
//    entfernt ein Logo, das ein Layout nutzen kann).
//  - `invoice_layout_assignments`: Zuordnung je Belegart und/oder Serie (beide leer = Vorgabe des Mandanten).
//  - `invoice_documents.layout_version_id`: beim Finalisieren eingefroren (der Beleg-Trigger verbietet jede spätere Änderung); leer = Standardlayout.
//  - `invoice_previews`: kurzlebige Vorschau-PDF in der Datenbank (ADR 0008 Nachtrag: Ablage und Ablauf), nie im Objektspeicher und nie in `files`.

struct CreateInvoiceLayouts: AsyncMigration {
    let name = "invoice_031_layouts"

    func prepare(on db: any Database) async throws {
        try await run(db, [
            """
            CREATE TABLE invoice_layouts (id uuid PRIMARY KEY DEFAULT gen_random_uuid(), tenant_id uuid NOT NULL REFERENCES tenants (id),
              name text NOT NULL CHECK (char_length(name) BETWEEN 1 AND 100), created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now(),
              UNIQUE (tenant_id, id))
            """,
            """
            CREATE TABLE invoice_layout_versions (id uuid PRIMARY KEY DEFAULT gen_random_uuid(), tenant_id uuid NOT NULL, layout_id uuid NOT NULL,
              version integer NOT NULL CHECK (version >= 1), params jsonb NOT NULL CHECK (jsonb_typeof(params) = 'object'), created_by uuid,
              created_at timestamptz NOT NULL DEFAULT now(),
              UNIQUE (layout_id, version), UNIQUE (tenant_id, id), FOREIGN KEY (tenant_id, layout_id) REFERENCES invoice_layouts (tenant_id, id) ON DELETE RESTRICT)
            """,
            """
            CREATE OR REPLACE FUNCTION invoice_layout_versions_guard() RETURNS trigger LANGUAGE plpgsql AS $$
            BEGIN RAISE EXCEPTION 'layout versions are immutable' USING ERRCODE = '23000'; END $$
            """,
            "CREATE TRIGGER invoice_layout_versions_guard BEFORE UPDATE OR DELETE ON invoice_layout_versions FOR EACH ROW EXECUTE FUNCTION invoice_layout_versions_guard()",
            "CREATE TRIGGER invoice_layout_versions_no_truncate BEFORE TRUNCATE ON invoice_layout_versions FOR EACH STATEMENT EXECUTE FUNCTION invoice_layout_versions_guard()",
            """
            CREATE TABLE invoice_layout_assets (id uuid PRIMARY KEY DEFAULT gen_random_uuid(), tenant_id uuid NOT NULL REFERENCES tenants (id),
              sha256 text NOT NULL CHECK (sha256 ~ '^[0-9a-f]{64}$'), file_id uuid NOT NULL REFERENCES files (id) ON DELETE RESTRICT,
              content_type text NOT NULL CHECK (content_type IN ('image/png', 'image/jpeg')), width integer NOT NULL CHECK (width BETWEEN 1 AND 2000),
              height integer NOT NULL CHECK (height BETWEEN 1 AND 2000), size_bytes bigint NOT NULL CHECK (size_bytes BETWEEN 1 AND 524288),
              created_at timestamptz NOT NULL DEFAULT now(), UNIQUE (tenant_id, sha256))
            """,
            """
            CREATE TABLE invoice_layout_assignments (id uuid PRIMARY KEY DEFAULT gen_random_uuid(), tenant_id uuid NOT NULL REFERENCES tenants (id),
              document_kind text CHECK (document_kind IS NULL OR document_kind IN ('quote', 'order_confirmation', 'delivery_note', 'invoice', 'credit_note')),
              series_id uuid, layout_id uuid NOT NULL, created_at timestamptz NOT NULL DEFAULT now(),
              FOREIGN KEY (tenant_id, series_id) REFERENCES invoice_series (tenant_id, id) ON DELETE CASCADE,
              FOREIGN KEY (tenant_id, layout_id) REFERENCES invoice_layouts (tenant_id, id) ON DELETE RESTRICT)
            """,
            """
            CREATE UNIQUE INDEX invoice_layout_assignments_key ON invoice_layout_assignments
              (tenant_id, coalesce(document_kind, ''), coalesce(series_id, '00000000-0000-0000-0000-000000000000'::uuid))
            """,
            "ALTER TABLE invoice_documents ADD COLUMN layout_version_id uuid",
            """
            ALTER TABLE invoice_documents ADD CONSTRAINT invoice_documents_layout_version FOREIGN KEY (tenant_id, layout_version_id)
              REFERENCES invoice_layout_versions (tenant_id, id) ON DELETE RESTRICT
            """,
            """
            CREATE TABLE invoice_previews (id uuid PRIMARY KEY DEFAULT gen_random_uuid(), tenant_id uuid NOT NULL, document_id uuid NOT NULL,
              layout_version_id uuid, input text NOT NULL, job_id uuid NOT NULL, requested_by uuid, pdf bytea CHECK (pdf IS NULL OR octet_length(pdf) <= 20971520),
              created_at timestamptz NOT NULL DEFAULT now(), expires_at timestamptz NOT NULL,
              FOREIGN KEY (tenant_id, document_id) REFERENCES invoice_documents (tenant_id, id) ON DELETE CASCADE,
              FOREIGN KEY (tenant_id, layout_version_id) REFERENCES invoice_layout_versions (tenant_id, id) ON DELETE RESTRICT)
            """,
            // Auch ein Worker ohne R6d (Rolling Update) kann für einen Beleg mit eingefrorener Version kein anderes Layout festschreiben.
            """
            CREATE OR REPLACE FUNCTION invoice_layout_state_guard() RETURNS trigger LANGUAGE plpgsql AS $$
            BEGIN
              IF EXISTS (SELECT 1 FROM invoice_documents d JOIN invoice_layout_versions v ON v.id = d.layout_version_id
                         WHERE d.id = NEW.document_id AND (v.layout_id::text <> NEW.layout_key OR v.version <> NEW.layout_version)) THEN
                RAISE EXCEPTION 'render state must use the layout version frozen on the document' USING ERRCODE = '23000';
              END IF;
              RETURN NEW;
            END $$
            """,
            "CREATE TRIGGER invoice_layout_state_guard BEFORE INSERT ON invoice_render_states FOR EACH ROW EXECUTE FUNCTION invoice_layout_state_guard()",
            "CREATE INDEX invoice_previews_expiry ON invoice_previews (expires_at)",
            "CREATE INDEX invoice_previews_tenant ON invoice_previews (tenant_id, expires_at)"])
    }

    func revert(on db: any Database) async throws {
        try await run(db, [
            "DROP TRIGGER IF EXISTS invoice_layout_state_guard ON invoice_render_states", "DROP FUNCTION invoice_layout_state_guard()",
            "DROP TABLE invoice_previews",
            "ALTER TABLE invoice_documents DROP COLUMN layout_version_id",
            "DROP TABLE invoice_layout_assignments", "DROP TABLE invoice_layout_assets", "DROP TABLE invoice_layout_versions", "DROP TABLE invoice_layouts",
            "DROP FUNCTION invoice_layout_versions_guard()"])
    }
}
