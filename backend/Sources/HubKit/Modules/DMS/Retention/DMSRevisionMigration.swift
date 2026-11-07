import Vapor
import Fluent
import SQLKit

// WP-D5 Revisionssicherheit (MODUL-DMS 8, GoBD-orientiert, keine Konformitätszusage, F-24). Modul-Migration, Expand-only:
// neue Spalten mit Standardwert, neue Tabellen, Funktionen und Trigger. `schema_version` bleibt unverändert (Modulstand steht in `_fluent_migrations`).
//
// Bausteine:
//  - `dms_documents.retention_until` (manuelle Verlängerung) und `legal_hold`; die Frist aus dem Dokumenttyp wird berechnet (`dms_retention_end`).
//  - `dms_deletion_log`: Löschprotokoll, append-only (AK-D-REV-4). Nur wer in derselben Transaktion einen Protokolleintrag schrieb, darf das Original löschen
//    (Ausnahme im Trigger `dms_protect_original`; AK-D-REV-1 bleibt für jeden anderen Weg bestehen).
//  - `dms_audit_chain`/`dms_audit_heads`: Hash-Kette über die DMS-Einträge des `audit_log` (F-16), je Mandant, beim Commit angehängt (deferred Constraint-Trigger:
//    die Kopfzeile wird erst am Ende der Transaktion gesperrt, dadurch kein Sperrzyklus mit Zählern oder Dokumentzeilen).
//  - `dms_integrity_runs` (Prüf-Job `dms.verify`) und `dms_exports` (Export-Job `dms.export`).

struct CreateDMSRevision: AsyncMigration {
    let name = "dms_021_revision"

    func prepare(on db: any Database) async throws {
        try await run(db, [
            "ALTER TABLE dms_documents ADD COLUMN retention_until date, ADD COLUMN legal_hold boolean NOT NULL DEFAULT false",
            // Ende der Aufbewahrung: Ende des Kalenderjahres des Bezugsdatums plus Jahre (Praxisannahme; Jahre je Dokumenttyp oder Standard), mindestens die manuelle Frist.
            """
            CREATE OR REPLACE FUNCTION dms_retention_end(p_base date, p_years integer, p_override date) RETURNS date LANGUAGE sql IMMUTABLE AS $$
              SELECT GREATEST(CASE WHEN p_years IS NULL OR p_years <= 0 THEN NULL
                                   ELSE make_date(extract(year FROM p_base)::integer + p_years, 12, 31) END, p_override)
            $$
            """,
            // Löschprotokoll (AK-D-REV-4): bleibt nach dem Löschen bestehen, enthält weder Inhalte noch Titel
            """
            CREATE TABLE dms_deletion_log (id uuid PRIMARY KEY DEFAULT gen_random_uuid(), tenant_id uuid NOT NULL, document_id uuid NOT NULL,
              asn bigint, document_type_id uuid, doc_date date, retention_until date,
              original_sha256 text NOT NULL CHECK (original_sha256 ~ '^[0-9a-f]{64}$'), original_size bigint NOT NULL, file_count integer NOT NULL,
              purged_by uuid, purged_at timestamptz NOT NULL DEFAULT now(), txid bigint NOT NULL DEFAULT txid_current(), UNIQUE (tenant_id, document_id))
            """,
            "CREATE INDEX dms_deletion_log_time ON dms_deletion_log (tenant_id, purged_at, id)",
            """
            CREATE OR REPLACE FUNCTION dms_append_only() RETURNS trigger LANGUAGE plpgsql AS $$
            BEGIN RAISE EXCEPTION 'dms_append_only: % ist nur anhängbar', TG_TABLE_NAME USING ERRCODE = 'integrity_constraint_violation'; END $$
            """,
            "CREATE TRIGGER dms_deletion_log_rows BEFORE UPDATE OR DELETE ON dms_deletion_log FOR EACH ROW EXECUTE FUNCTION dms_append_only()",
            "CREATE TRIGGER dms_deletion_log_truncate BEFORE TRUNCATE ON dms_deletion_log FOR EACH STATEMENT EXECUTE FUNCTION dms_append_only()",
            // Ausnahme von AK-D-REV-1: Löschen eines Originals nur in der Transaktion, die das Löschprotokoll für genau dieses Dokument geschrieben hat
            """
            CREATE OR REPLACE FUNCTION dms_protect_original() RETURNS trigger LANGUAGE plpgsql AS $$
            BEGIN
              IF OLD.role = 'original' THEN
                IF TG_OP = 'DELETE' AND EXISTS (SELECT 1 FROM dms_deletion_log l WHERE l.tenant_id = OLD.tenant_id AND l.document_id = OLD.document_id AND l.txid = txid_current()) THEN
                  RETURN OLD;
                END IF;
                RAISE EXCEPTION 'dms_original_immutable: Das Original eines Dokuments ist unveränderlich' USING ERRCODE = 'integrity_constraint_violation';
              END IF;
              IF TG_OP = 'DELETE' THEN RETURN OLD; END IF;
              RETURN NEW;
            END $$
            """,
            // Hash-Kette (F-16)
            "CREATE TABLE dms_audit_heads (tenant_id uuid PRIMARY KEY, seq bigint NOT NULL, hash text NOT NULL)",
            """
            CREATE TABLE dms_audit_chain (tenant_id uuid NOT NULL, seq bigint NOT NULL, audit_id bigint NOT NULL UNIQUE, prev_hash text NOT NULL, hash text NOT NULL,
              PRIMARY KEY (tenant_id, seq))
            """,
            """
            CREATE OR REPLACE FUNCTION dms_audit_hash(p_prev text, p_id bigint, p_at timestamptz, p_action text, p_actor uuid, p_tenant uuid, p_stype text, p_sid text,
                                                      p_meta jsonb, p_request text) RETURNS text LANGUAGE sql IMMUTABLE AS $$
              SELECT encode(sha256(convert_to(concat_ws('|', p_prev, p_id::text, to_char(p_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US'), p_action,
                coalesce(p_actor::text, ''), coalesce(p_tenant::text, ''), coalesce(p_stype, ''), coalesce(p_sid, ''), p_meta::text, coalesce(p_request, '')), 'UTF8')), 'hex')
            $$
            """,
            """
            CREATE OR REPLACE FUNCTION dms_audit_chain_append() RETURNS trigger LANGUAGE plpgsql AS $$
            DECLARE h record; nh text;
            BEGIN
              IF NEW.tenant_id IS NULL OR NEW.action NOT LIKE 'dms.%' THEN RETURN NULL; END IF;
              INSERT INTO dms_audit_heads (tenant_id, seq, hash) VALUES (NEW.tenant_id, 0, repeat('0', 64)) ON CONFLICT DO NOTHING;
              SELECT seq, hash INTO h FROM dms_audit_heads WHERE tenant_id = NEW.tenant_id FOR UPDATE;
              nh := dms_audit_hash(h.hash, NEW.id, NEW.at, NEW.action, NEW.actor_user_id, NEW.tenant_id, NEW.subject_type, NEW.subject_id, NEW.meta, NEW.request_id);
              INSERT INTO dms_audit_chain (tenant_id, seq, audit_id, prev_hash, hash) VALUES (NEW.tenant_id, h.seq + 1, NEW.id, h.hash, nh);
              UPDATE dms_audit_heads SET seq = h.seq + 1, hash = nh WHERE tenant_id = NEW.tenant_id;
              RETURN NULL;
            END $$
            """,
            "CREATE CONSTRAINT TRIGGER audit_log_dms_chain AFTER INSERT ON audit_log DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION dms_audit_chain_append()",
            "CREATE TRIGGER dms_audit_chain_rows BEFORE UPDATE OR DELETE ON dms_audit_chain FOR EACH ROW EXECUTE FUNCTION dms_append_only()",
            "CREATE TRIGGER dms_audit_chain_truncate BEFORE TRUNCATE ON dms_audit_chain FOR EACH STATEMENT EXECUTE FUNCTION dms_append_only()",
            // Prüfläufe
            """
            CREATE TABLE dms_integrity_runs (id uuid PRIMARY KEY DEFAULT gen_random_uuid(), tenant_id uuid NOT NULL,
              state text NOT NULL DEFAULT 'queued' CHECK (state IN ('queued', 'running', 'passed', 'failed', 'error')),
              requested_by uuid, job_id uuid, created_at timestamptz NOT NULL DEFAULT now(), started_at timestamptz, finished_at timestamptz,
              files_checked integer NOT NULL DEFAULT 0, files_bad integer NOT NULL DEFAULT 0, chain_entries bigint, chain_ok boolean,
              error_code text CHECK (error_code IS NULL OR error_code ~ '^[a-z0-9_.]{1,64}$'), report jsonb, UNIQUE (tenant_id, id))
            """,
            "CREATE INDEX dms_integrity_runs_list ON dms_integrity_runs (tenant_id, created_at DESC, id)",
            // Exporte
            """
            CREATE TABLE dms_exports (id uuid PRIMARY KEY DEFAULT gen_random_uuid(), tenant_id uuid NOT NULL,
              state text NOT NULL DEFAULT 'queued' CHECK (state IN ('queued', 'running', 'done', 'failed')), params jsonb NOT NULL DEFAULT '{}'::jsonb,
              requested_by uuid, job_id uuid, created_at timestamptz NOT NULL DEFAULT now(), finished_at timestamptz,
              document_count integer, file_count integer, size_bytes bigint, sha256 text CHECK (sha256 IS NULL OR sha256 ~ '^[0-9a-f]{64}$'),
              manifest_sha256 text CHECK (manifest_sha256 IS NULL OR manifest_sha256 ~ '^[0-9a-f]{64}$'), file_id uuid,
              error_code text CHECK (error_code IS NULL OR error_code ~ '^[a-z0-9_.]{1,64}$'), UNIQUE (tenant_id, id))
            """,
            "CREATE INDEX dms_exports_list ON dms_exports (tenant_id, created_at DESC, id)"])
    }

    func revert(on db: any Database) async throws {
        try await run(db, [
            "DROP TABLE dms_exports", "DROP TABLE dms_integrity_runs",
            "DROP TRIGGER audit_log_dms_chain ON audit_log",
            "DROP TABLE dms_audit_chain", "DROP TABLE dms_audit_heads",
            "DROP FUNCTION dms_audit_chain_append()", "DROP FUNCTION dms_audit_hash(text, bigint, timestamptz, text, uuid, uuid, text, text, jsonb, text)",
            // Zustand von dms_016 wiederherstellen
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
            "DROP TABLE dms_deletion_log", "DROP FUNCTION dms_append_only()", "DROP FUNCTION dms_retention_end(date, integer, date)",
            "ALTER TABLE dms_documents DROP COLUMN legal_hold, DROP COLUMN retention_until"])
    }
}
