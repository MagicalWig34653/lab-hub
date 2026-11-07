import Vapor
import Fluent
import SQLKit

// WP-D2 DMS-Kern. Modul-Migration (läuft immer, auch bei deaktiviertem Modul). Expand-only: nur neue Tabellen, Funktionen, Trigger.
// Mandantensicherheit auch in der Datenbank: Verweise zwischen DMS-Tabellen sind zusammengesetzt (tenant_id, id), ein Verweis über Mandantengrenzen scheitert am Fremdschlüssel.
// `schema_version` bleibt unverändert (Modulstände stehen in `_fluent_migrations`, siehe Handoff K3).

struct CreateDMSCore: AsyncMigration {
    let name = "dms_016_core"
    func prepare(on db: any Database) async throws {
        try await run(db, [
            """
            CREATE TABLE dms_document_types (id uuid PRIMARY KEY DEFAULT gen_random_uuid(), tenant_id uuid NOT NULL,
              name text NOT NULL CHECK (char_length(name) BETWEEN 1 AND 100),
              code text CHECK (code IS NULL OR code ~ '^[a-z0-9_]{1,40}$'),
              description text CHECK (description IS NULL OR char_length(description) <= 1000),
              default_retention_years integer CHECK (default_retention_years IS NULL OR default_retention_years BETWEEN 0 AND 100),
              created_at timestamptz NOT NULL DEFAULT now(), UNIQUE (tenant_id, id))
            """,
            "CREATE UNIQUE INDEX dms_document_types_name ON dms_document_types (tenant_id, lower(name))",
            "CREATE UNIQUE INDEX dms_document_types_code ON dms_document_types (tenant_id, code) WHERE code IS NOT NULL",
            """
            CREATE TABLE dms_tag_groups (id uuid PRIMARY KEY DEFAULT gen_random_uuid(), tenant_id uuid NOT NULL,
              name text NOT NULL CHECK (char_length(name) BETWEEN 1 AND 100), exclusive boolean NOT NULL DEFAULT false,
              created_at timestamptz NOT NULL DEFAULT now(), UNIQUE (tenant_id, id))
            """,
            "CREATE UNIQUE INDEX dms_tag_groups_name ON dms_tag_groups (tenant_id, lower(name))",
            """
            CREATE TABLE dms_tags (id uuid PRIMARY KEY DEFAULT gen_random_uuid(), tenant_id uuid NOT NULL,
              name text NOT NULL CHECK (char_length(name) BETWEEN 1 AND 100), group_id uuid,
              color text CHECK (color IS NULL OR color ~ '^#[0-9a-fA-F]{6}$'),
              created_at timestamptz NOT NULL DEFAULT now(), UNIQUE (tenant_id, id),
              FOREIGN KEY (tenant_id, group_id) REFERENCES dms_tag_groups (tenant_id, id))
            """,
            "CREATE UNIQUE INDEX dms_tags_name ON dms_tags (tenant_id, lower(name))",
            """
            CREATE TABLE dms_storage_paths (id uuid PRIMARY KEY DEFAULT gen_random_uuid(), tenant_id uuid NOT NULL,
              name text NOT NULL CHECK (char_length(name) BETWEEN 1 AND 100), template text NOT NULL CHECK (char_length(template) BETWEEN 1 AND 300),
              created_at timestamptz NOT NULL DEFAULT now(), UNIQUE (tenant_id, id))
            """,
            "CREATE UNIQUE INDEX dms_storage_paths_name ON dms_storage_paths (tenant_id, lower(name))",
            """
            CREATE TABLE dms_custom_fields (id uuid PRIMARY KEY DEFAULT gen_random_uuid(), tenant_id uuid NOT NULL,
              name text NOT NULL CHECK (char_length(name) BETWEEN 1 AND 100), code text NOT NULL CHECK (code ~ '^[a-z][a-z0-9_]{0,39}$'),
              data_type text NOT NULL CHECK (data_type IN ('string','int','decimal','date','bool','select','contact')),
              options jsonb, created_at timestamptz NOT NULL DEFAULT now(), UNIQUE (tenant_id, id))
            """,
            "CREATE UNIQUE INDEX dms_custom_fields_code ON dms_custom_fields (tenant_id, code)",
            "CREATE UNIQUE INDEX dms_custom_fields_name ON dms_custom_fields (tenant_id, lower(name))",
            // Dokument. Papierkorb = trashed_at (der Status bleibt, damit Restore den früheren Stand herstellt). ASN je Mandant eindeutig.
            """
            CREATE TABLE dms_documents (id uuid PRIMARY KEY DEFAULT gen_random_uuid(), tenant_id uuid NOT NULL,
              title text NOT NULL CHECK (char_length(title) BETWEEN 1 AND 300), doc_date date,
              received_at timestamptz NOT NULL DEFAULT now(),
              document_type_id uuid, storage_path_id uuid, asn bigint CHECK (asn IS NULL OR asn > 0),
              status text NOT NULL DEFAULT 'needs_review' CHECK (status IN ('processing','needs_review','archived')),
              trashed_at timestamptz, trashed_by uuid, trash_reason text CHECK (trash_reason IS NULL OR char_length(trash_reason) BETWEEN 1 AND 500),
              created_by uuid, created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now(),
              rev integer NOT NULL DEFAULT 1, UNIQUE (tenant_id, id),
              CHECK ((trashed_at IS NULL) = (trash_reason IS NULL)), CHECK (status <> 'archived' OR asn IS NOT NULL),
              FOREIGN KEY (tenant_id, document_type_id) REFERENCES dms_document_types (tenant_id, id),
              FOREIGN KEY (tenant_id, storage_path_id) REFERENCES dms_storage_paths (tenant_id, id))
            """,
            "CREATE UNIQUE INDEX dms_documents_asn ON dms_documents (tenant_id, asn) WHERE asn IS NOT NULL",
            "CREATE INDEX dms_documents_list ON dms_documents (tenant_id, created_at, id) WHERE trashed_at IS NULL",
            "CREATE INDEX dms_documents_trash ON dms_documents (tenant_id, created_at, id) WHERE trashed_at IS NOT NULL",
            // Dateien eines Dokuments. Das Original (role = original) gibt es je Dokument genau einmal; es ist unveränderlich.
            """
            CREATE TABLE dms_document_files (id uuid PRIMARY KEY DEFAULT gen_random_uuid(), tenant_id uuid NOT NULL, document_id uuid NOT NULL,
              role text NOT NULL CHECK (role IN ('original','archive','thumbnail','derivative')),
              file_id uuid NOT NULL REFERENCES files (id), mime text NOT NULL, size_bytes bigint NOT NULL CHECK (size_bytes >= 0),
              page_count integer CHECK (page_count IS NULL OR page_count >= 0), sha256 text NOT NULL CHECK (sha256 ~ '^[0-9a-f]{64}$'),
              original_name text CHECK (original_name IS NULL OR char_length(original_name) <= 255),
              created_at timestamptz NOT NULL DEFAULT now(),
              FOREIGN KEY (tenant_id, document_id) REFERENCES dms_documents (tenant_id, id))
            """,
            "CREATE UNIQUE INDEX dms_document_files_original ON dms_document_files (document_id) WHERE role = 'original'",
            "CREATE UNIQUE INDEX dms_document_files_role ON dms_document_files (document_id, role) WHERE role IN ('archive','thumbnail')",
            "CREATE INDEX dms_document_files_hash ON dms_document_files (tenant_id, sha256) WHERE role = 'original'",
            """
            CREATE TABLE dms_document_tags (tenant_id uuid NOT NULL, document_id uuid NOT NULL, tag_id uuid NOT NULL,
              source text NOT NULL DEFAULT 'manual' CHECK (source IN ('manual','rule','suggestion')), assigned_by uuid,
              assigned_at timestamptz NOT NULL DEFAULT now(), PRIMARY KEY (document_id, tag_id),
              FOREIGN KEY (tenant_id, document_id) REFERENCES dms_documents (tenant_id, id),
              FOREIGN KEY (tenant_id, tag_id) REFERENCES dms_tags (tenant_id, id))
            """,
            "CREATE INDEX dms_document_tags_tag ON dms_document_tags (tenant_id, tag_id)",
            """
            CREATE TABLE dms_document_fields (tenant_id uuid NOT NULL, document_id uuid NOT NULL, field_id uuid NOT NULL,
              value_text text, value_numeric numeric, value_date date, value_bool boolean, PRIMARY KEY (document_id, field_id),
              CHECK (num_nonnulls(value_text, value_numeric, value_date, value_bool) = 1),
              FOREIGN KEY (tenant_id, document_id) REFERENCES dms_documents (tenant_id, id),
              FOREIGN KEY (tenant_id, field_id) REFERENCES dms_custom_fields (tenant_id, id))
            """,
            // AK-D-REV-1: Original unveränderlich auf Datenbankebene (UPDATE, DELETE, TRUNCATE)
            """
            CREATE OR REPLACE FUNCTION dms_protect_original() RETURNS trigger LANGUAGE plpgsql AS $$
            BEGIN
              IF OLD.role = 'original' THEN
                RAISE EXCEPTION 'dms_original_immutable: Das Original eines Dokuments ist unveränderlich' USING ERRCODE = 'integrity_constraint_violation';
              END IF;
              IF TG_OP = 'DELETE' THEN RETURN OLD; END IF;
              RETURN NEW;
            END $$
            """,
            "CREATE TRIGGER dms_document_files_protect BEFORE UPDATE OR DELETE ON dms_document_files FOR EACH ROW EXECUTE FUNCTION dms_protect_original()",
            """
            CREATE OR REPLACE FUNCTION dms_block_truncate() RETURNS trigger LANGUAGE plpgsql AS $$
            BEGIN
              RAISE EXCEPTION 'dms_original_immutable: Dokumentdateien dürfen nicht geleert werden' USING ERRCODE = 'integrity_constraint_violation';
            END $$
            """,
            "CREATE TRIGGER dms_document_files_no_truncate BEFORE TRUNCATE ON dms_document_files FOR EACH STATEMENT EXECUTE FUNCTION dms_block_truncate()",
            // Auch die Dateizeile (Hash, Größe, Schlüssel) eines Originals ist gesperrt
            """
            CREATE OR REPLACE FUNCTION dms_protect_original_file() RETURNS trigger LANGUAGE plpgsql AS $$
            BEGIN
              IF TG_OP = 'DELETE' OR NEW.id IS DISTINCT FROM OLD.id OR NEW.tenant_id IS DISTINCT FROM OLD.tenant_id OR NEW.sha256 IS DISTINCT FROM OLD.sha256
                 OR NEW.size_bytes IS DISTINCT FROM OLD.size_bytes OR NEW.storage_key IS DISTINCT FROM OLD.storage_key THEN
                IF EXISTS (SELECT 1 FROM dms_document_files WHERE file_id = OLD.id AND role = 'original') THEN
                  RAISE EXCEPTION 'dms_original_immutable: Die Datei eines Originals ist unveränderlich' USING ERRCODE = 'integrity_constraint_violation';
                END IF;
              END IF;
              IF TG_OP = 'DELETE' THEN RETURN OLD; END IF;
              RETURN NEW;
            END $$
            """,
            "CREATE TRIGGER dms_files_protect BEFORE UPDATE OR DELETE ON files FOR EACH ROW EXECUTE FUNCTION dms_protect_original_file()",
            // Eine vergebene ASN bleibt unverändert
            """
            CREATE OR REPLACE FUNCTION dms_protect_asn() RETURNS trigger LANGUAGE plpgsql AS $$
            BEGIN
              IF OLD.asn IS NOT NULL AND NEW.asn IS DISTINCT FROM OLD.asn THEN
                RAISE EXCEPTION 'dms_asn_immutable: Die Archivnummer ist unveränderlich' USING ERRCODE = 'integrity_constraint_violation';
              END IF;
              RETURN NEW;
            END $$
            """,
            "CREATE TRIGGER dms_documents_protect_asn BEFORE UPDATE ON dms_documents FOR EACH ROW EXECUTE FUNCTION dms_protect_asn()"])
    }
    func revert(on db: any Database) async throws {
        try await run(db, [
            "DROP TRIGGER dms_files_protect ON files",
            "DROP TABLE dms_document_fields", "DROP TABLE dms_document_tags", "DROP TABLE dms_document_files", "DROP TABLE dms_documents",
            "DROP TABLE dms_custom_fields", "DROP TABLE dms_storage_paths", "DROP TABLE dms_tags", "DROP TABLE dms_tag_groups", "DROP TABLE dms_document_types",
            "DROP FUNCTION dms_protect_original()", "DROP FUNCTION dms_block_truncate()", "DROP FUNCTION dms_protect_original_file()", "DROP FUNCTION dms_protect_asn()"])
    }
}
