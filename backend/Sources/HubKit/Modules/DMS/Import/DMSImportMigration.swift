import Vapor
import Fluent
import SQLKit

// WP-D6: Paperless-Import. Tabellen für Läufe, Idempotenz-Zuordnung (Quelle + Paperless-ID -> Hub-Objekt), Befunde und Dokumentnotizen.
// Expand-only (nur neue Tabellen), `schema_version` unverändert (Modulmigration, Nachweis in `_fluent_migrations`).
// Keine Zugangsdaten im Klartext: das Token der REST-Quelle steht verschlüsselt in `secret_enc` (SecretBox, gebunden an Mandant und Lauf).

struct CreateDMSImport: AsyncMigration {
    let name = "dms_023_import"
    func prepare(on db: any Database) async throws {
        try await run(db, [
            """
            CREATE TABLE dms_imports (id uuid PRIMARY KEY DEFAULT gen_random_uuid(), tenant_id uuid NOT NULL,
              source_kind text NOT NULL CHECK (source_kind IN ('export', 'api')),
              source_key text NOT NULL CHECK (char_length(source_key) BETWEEN 1 AND 300),
              config jsonb NOT NULL, secret_enc text CHECK (secret_enc IS NULL OR char_length(secret_enc) <= 2000),
              mode text NOT NULL CHECK (mode IN ('dry_run', 'import')),
              options jsonb NOT NULL DEFAULT '{}'::jsonb,
              state text NOT NULL DEFAULT 'queued' CHECK (state IN ('queued', 'running', 'done', 'failed', 'cancelled')),
              cancel_requested boolean NOT NULL DEFAULT false,
              progress jsonb NOT NULL DEFAULT '{}'::jsonb, report jsonb,
              error_code text CHECK (error_code IS NULL OR error_code ~ '^[a-z0-9_.]{1,64}$'),
              job_id uuid, requested_by uuid NOT NULL REFERENCES users (id),
              created_at timestamptz NOT NULL DEFAULT now(), started_at timestamptz, finished_at timestamptz,
              UNIQUE (tenant_id, id), CHECK ((state = 'failed') = (error_code IS NOT NULL)))
            """,
            "CREATE INDEX dms_imports_list ON dms_imports (tenant_id, created_at DESC, id)",
            // Idempotenz: Schlüssel (Quelle, Art, Paperless-ID). Ohne Fremdschlüssel auf die Ziele (ein endgültig gelöschtes Dokument soll den Import nicht blockieren).
            """
            CREATE TABLE dms_import_items (tenant_id uuid NOT NULL, source_key text NOT NULL,
              kind text NOT NULL CHECK (kind IN ('document', 'correspondent', 'tag', 'type', 'path', 'field')),
              ext_id bigint NOT NULL, target_id uuid NOT NULL, sha256 text CHECK (sha256 IS NULL OR sha256 ~ '^[0-9a-f]{64}$'),
              run_id uuid NOT NULL, created_at timestamptz NOT NULL DEFAULT now(),
              PRIMARY KEY (tenant_id, source_key, kind, ext_id), FOREIGN KEY (tenant_id, run_id) REFERENCES dms_imports (tenant_id, id))
            """,
            "CREATE INDEX dms_import_items_hash ON dms_import_items (tenant_id, sha256) WHERE sha256 IS NOT NULL",
            "CREATE INDEX dms_import_items_run ON dms_import_items (tenant_id, run_id, kind)",
            // Befunde je Lauf (Warnungen, Konflikte, Hinweise); (Lauf, Code, Referenz) eindeutig, damit ein fortgesetzter Lauf nichts doppelt meldet.
            """
            CREATE TABLE dms_import_findings (tenant_id uuid NOT NULL, run_id uuid NOT NULL, code text NOT NULL CHECK (code ~ '^[a-z0-9_.]{1,64}$'),
              ref text NOT NULL CHECK (char_length(ref) <= 100), detail text CHECK (detail IS NULL OR char_length(detail) <= 300),
              created_at timestamptz NOT NULL DEFAULT now(), PRIMARY KEY (run_id, code, ref),
              FOREIGN KEY (tenant_id, run_id) REFERENCES dms_imports (tenant_id, id))
            """,
            // Notizen zu Dokumenten (Paperless-Notizen); Herkunftsschlüssel macht den Import je Notiz idempotent.
            """
            CREATE TABLE dms_document_notes (id uuid PRIMARY KEY DEFAULT gen_random_uuid(), tenant_id uuid NOT NULL, document_id uuid NOT NULL,
              body text NOT NULL CHECK (char_length(body) BETWEEN 1 AND 20000), noted_at timestamptz,
              origin text CHECK (origin IS NULL OR char_length(origin) <= 100), created_by uuid, created_at timestamptz NOT NULL DEFAULT now(),
              FOREIGN KEY (tenant_id, document_id) REFERENCES dms_documents (tenant_id, id))
            """,
            "CREATE INDEX dms_document_notes_doc ON dms_document_notes (tenant_id, document_id, created_at)",
            "CREATE UNIQUE INDEX dms_document_notes_origin ON dms_document_notes (document_id, origin) WHERE origin IS NOT NULL"])
    }
    func revert(on db: any Database) async throws {
        try await run(db, ["DROP TABLE dms_document_notes", "DROP TABLE dms_import_findings", "DROP TABLE dms_import_items", "DROP TABLE dms_imports"])
    }
}
