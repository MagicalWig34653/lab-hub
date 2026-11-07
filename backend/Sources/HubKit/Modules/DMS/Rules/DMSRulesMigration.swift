import Vapor
import Fluent
import SQLKit

// WP-D3 Regeln, Vorschläge, Duplikate (MODUL-DMS 5.4, 5.1). Modul-Migration `dms_020_rules`, expand-only, `schema_version` unverändert.
// - `dms_rules`: Bedingungen/Aktionen als versioniertes JSON, Modus `suggest` (Standard) oder `auto` (F-25). Löschen = `deleted_at` (Vorschläge verweisen weiter).
// - `dms_suggestions`: ein Vorschlag je (Dokument, Art, Quelle, Regel, Wert). Der Unique-Index macht „genau einmal“ auch bei doppeltem Lauf wahr.
// - `dms_duplicates`: Stufe 1 `sha256`, Stufe 2 `text_hash` und `similarity`. Ein Treffer ist ein Hinweis, nie ein stilles Verwerfen.
// - `dms_document_fingerprints` / `dms_text_shingles`: Text-Hash und Bottom-k-Skizze der Wort-Shingles für die Ähnlichkeitssuche (Index statt Tabellenscan).
// - `dms_ingest_items.sender`: Absender (Mail-Quelle, D4) für die Regelbedingung `sender_contains`; Uploads lassen ihn leer.
// Verweise zwischen DMS-Tabellen sind zusammengesetzte Fremdschlüssel (tenant_id, id): ein Verweis über Mandantengrenzen scheitert in der Datenbank.

struct CreateDMSRules: AsyncMigration {
    let name = "dms_020_rules"

    func prepare(on db: any Database) async throws {
        try await run(db, [
            """
            CREATE TABLE dms_rules (id uuid PRIMARY KEY DEFAULT gen_random_uuid(), tenant_id uuid NOT NULL,
              name text NOT NULL CHECK (char_length(name) BETWEEN 1 AND 100),
              priority integer NOT NULL DEFAULT 0 CHECK (priority BETWEEN -1000 AND 1000),
              enabled boolean NOT NULL DEFAULT true,
              mode text NOT NULL DEFAULT 'suggest' CHECK (mode IN ('suggest', 'auto')),
              confidence numeric(4,3) NOT NULL DEFAULT 0.800 CHECK (confidence BETWEEN 0 AND 1),
              conditions jsonb NOT NULL, actions jsonb NOT NULL, version integer NOT NULL DEFAULT 1 CHECK (version >= 1),
              created_by uuid, created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now(), deleted_at timestamptz,
              UNIQUE (tenant_id, id))
            """,
            "CREATE UNIQUE INDEX dms_rules_name ON dms_rules (tenant_id, lower(name)) WHERE deleted_at IS NULL",
            "CREATE INDEX dms_rules_active ON dms_rules (tenant_id, priority DESC, created_at, id) WHERE deleted_at IS NULL AND enabled",
            """
            CREATE TABLE dms_suggestions (id uuid PRIMARY KEY DEFAULT gen_random_uuid(), tenant_id uuid NOT NULL, document_id uuid NOT NULL, ingest_item_id uuid,
              kind text NOT NULL CHECK (kind IN ('correspondent', 'type', 'tag', 'date', 'title', 'path')),
              value jsonb NOT NULL, value_key text NOT NULL CHECK (char_length(value_key) <= 400),
              source text NOT NULL CHECK (source IN ('rule', 'contact_match')), rule_id uuid, rule_version integer,
              confidence numeric(4,3) NOT NULL CHECK (confidence BETWEEN 0 AND 1),
              reason text NOT NULL CHECK (char_length(reason) BETWEEN 1 AND 400), evidence jsonb NOT NULL DEFAULT '{}'::jsonb,
              state text NOT NULL DEFAULT 'open' CHECK (state IN ('open', 'accepted', 'rejected')),
              applied_automatically boolean NOT NULL DEFAULT false, decided_by uuid, decided_at timestamptz,
              created_at timestamptz NOT NULL DEFAULT now(),
              UNIQUE (tenant_id, id),
              FOREIGN KEY (tenant_id, document_id) REFERENCES dms_documents (tenant_id, id),
              FOREIGN KEY (tenant_id, rule_id) REFERENCES dms_rules (tenant_id, id),
              CHECK ((source = 'rule') = (rule_id IS NOT NULL)),
              CHECK ((state = 'open') = (decided_at IS NULL)),
              CHECK (NOT applied_automatically OR state = 'accepted'))
            """,
            "CREATE UNIQUE INDEX dms_suggestions_once ON dms_suggestions (tenant_id, document_id, kind, source, COALESCE(rule_id, '00000000-0000-0000-0000-000000000000'::uuid), value_key)",
            "CREATE INDEX dms_suggestions_list ON dms_suggestions (tenant_id, state, created_at, id)",
            "CREATE INDEX dms_suggestions_document ON dms_suggestions (tenant_id, document_id, created_at, id)",
            "CREATE INDEX dms_suggestions_rule ON dms_suggestions (tenant_id, rule_id) WHERE rule_id IS NOT NULL",
            """
            CREATE TABLE dms_duplicates (id uuid PRIMARY KEY DEFAULT gen_random_uuid(), tenant_id uuid NOT NULL, document_id uuid NOT NULL, duplicate_of uuid NOT NULL,
              method text NOT NULL CHECK (method IN ('sha256', 'text_hash', 'similarity')), score numeric(4,3) NOT NULL CHECK (score BETWEEN 0 AND 1),
              state text NOT NULL DEFAULT 'open' CHECK (state IN ('open', 'confirmed', 'dismissed')), decided_by uuid, decided_at timestamptz,
              created_at timestamptz NOT NULL DEFAULT now(),
              UNIQUE (tenant_id, id), UNIQUE (tenant_id, document_id, duplicate_of, method), CHECK (document_id <> duplicate_of),
              CHECK ((state = 'open') = (decided_at IS NULL)),
              FOREIGN KEY (tenant_id, document_id) REFERENCES dms_documents (tenant_id, id),
              FOREIGN KEY (tenant_id, duplicate_of) REFERENCES dms_documents (tenant_id, id))
            """,
            "CREATE INDEX dms_duplicates_list ON dms_duplicates (tenant_id, state, created_at, id)",
            "CREATE INDEX dms_duplicates_of ON dms_duplicates (tenant_id, duplicate_of)",
            """
            CREATE TABLE dms_document_fingerprints (document_id uuid PRIMARY KEY, tenant_id uuid NOT NULL, text_hash text NOT NULL CHECK (text_hash ~ '^[0-9a-f]{64}$'),
              words integer NOT NULL CHECK (words >= 0), created_at timestamptz NOT NULL DEFAULT now(),
              FOREIGN KEY (tenant_id, document_id) REFERENCES dms_documents (tenant_id, id))
            """,
            "CREATE INDEX dms_fingerprints_hash ON dms_document_fingerprints (tenant_id, text_hash)",
            """
            CREATE TABLE dms_text_shingles (tenant_id uuid NOT NULL, document_id uuid NOT NULL, h bigint NOT NULL, PRIMARY KEY (document_id, h),
              FOREIGN KEY (tenant_id, document_id) REFERENCES dms_documents (tenant_id, id))
            """,
            "CREATE INDEX dms_text_shingles_h ON dms_text_shingles (tenant_id, h)",
            "ALTER TABLE dms_ingest_items ADD COLUMN sender text CHECK (sender IS NULL OR char_length(sender) <= 320)"])
    }

    func revert(on db: any Database) async throws {
        try await run(db, ["ALTER TABLE dms_ingest_items DROP COLUMN sender", "DROP TABLE dms_text_shingles", "DROP TABLE dms_document_fingerprints",
                           "DROP TABLE dms_duplicates", "DROP TABLE dms_suggestions", "DROP TABLE dms_rules"])
    }
}
