import Vapor
import Fluent
import SQLKit

// WP-K5 Kontakte und Links. Expand-only (neue Tabellen). Keine Fremdschlüssel auf `tenants`/`users` (wie `files`, `counters`),
// damit ältere Migrationen unabhängig zurückgenommen werden können. Fremdschlüssel nur innerhalb der Kontakt-Tabellen.

/// Kontakte (Person/Organisation) mit Anschriften, E-Mails, Bankverbindungen, Aliasen (Matching, z. B. DMS-Korrespondent) und die generische Tabelle `links`.
/// `schema_version` 14 -> 15 (014 belegt WP-K3). Ohne 014 (Zweig vor dem Merge von K3) springt die Version von 13 auf 15.
/// Revert stellt 14 wieder her, wenn eine Migration `014_*` angewendet ist, sonst 13.
struct CreateContacts: AsyncMigration {
    let name = "015_contacts"
    func prepare(on db: any Database) async throws {
        try await run(db, [
            """
            CREATE TABLE contacts (id uuid PRIMARY KEY DEFAULT gen_random_uuid(), tenant_id uuid NOT NULL,
              kind text NOT NULL CHECK (kind IN ('person','organization')),
              display_name text NOT NULL CHECK (char_length(display_name) BETWEEN 1 AND 200),
              first_name text, last_name text, company_name text,
              vat_id text CHECK (vat_id IS NULL OR vat_id ~ '^[A-Z]{2}[A-Z0-9]{2,12}$'),
              is_customer boolean NOT NULL DEFAULT false, is_supplier boolean NOT NULL DEFAULT false, is_correspondent boolean NOT NULL DEFAULT false,
              note text,
              merged_into uuid REFERENCES contacts (id), merged_at timestamptz, deleted_at timestamptz,
              created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now(),
              CHECK ((merged_into IS NULL) = (merged_at IS NULL)), CHECK (merged_into IS NULL OR merged_into <> id))
            """,
            "CREATE INDEX contacts_list ON contacts (tenant_id, created_at, id) WHERE deleted_at IS NULL AND merged_into IS NULL",
            "CREATE INDEX contacts_vat ON contacts (tenant_id, vat_id) WHERE vat_id IS NOT NULL",
            """
            CREATE TABLE contact_addresses (id uuid PRIMARY KEY DEFAULT gen_random_uuid(), tenant_id uuid NOT NULL,
              contact_id uuid NOT NULL REFERENCES contacts (id) ON DELETE CASCADE, position integer NOT NULL DEFAULT 0,
              label text, street text, postal_code text, city text, country text CHECK (country IS NULL OR country ~ '^[A-Z]{2}$'))
            """,
            "CREATE INDEX contact_addresses_contact ON contact_addresses (contact_id)",
            """
            CREATE TABLE contact_emails (id uuid PRIMARY KEY DEFAULT gen_random_uuid(), tenant_id uuid NOT NULL,
              contact_id uuid NOT NULL REFERENCES contacts (id) ON DELETE CASCADE, position integer NOT NULL DEFAULT 0,
              email text NOT NULL CHECK (char_length(email) BETWEEN 3 AND 254), label text)
            """,
            "CREATE UNIQUE INDEX contact_emails_unique ON contact_emails (contact_id, lower(email))",
            "CREATE INDEX contact_emails_tenant ON contact_emails (tenant_id, lower(email))",
            """
            CREATE TABLE contact_bank_accounts (id uuid PRIMARY KEY DEFAULT gen_random_uuid(), tenant_id uuid NOT NULL,
              contact_id uuid NOT NULL REFERENCES contacts (id) ON DELETE CASCADE, position integer NOT NULL DEFAULT 0,
              iban text NOT NULL CHECK (iban ~ '^[A-Z]{2}[0-9]{2}[A-Z0-9]{11,30}$'), bic text, holder text)
            """,
            "CREATE UNIQUE INDEX contact_bank_accounts_unique ON contact_bank_accounts (contact_id, iban)",
            "CREATE INDEX contact_bank_accounts_tenant ON contact_bank_accounts (tenant_id, iban)",
            """
            CREATE TABLE contact_aliases (id uuid PRIMARY KEY DEFAULT gen_random_uuid(), tenant_id uuid NOT NULL,
              contact_id uuid NOT NULL REFERENCES contacts (id) ON DELETE CASCADE,
              alias text NOT NULL CHECK (char_length(alias) BETWEEN 1 AND 200))
            """,
            "CREATE UNIQUE INDEX contact_aliases_unique ON contact_aliases (contact_id, lower(alias))",
            "CREATE INDEX contact_aliases_tenant ON contact_aliases (tenant_id, lower(alias))",
            // Generische Verknüpfungen. Entfernen setzt removed_at (Eintrag bleibt, umkehrbar); aktiv ist höchstens ein gleicher Eintrag.
            """
            CREATE TABLE links (id uuid PRIMARY KEY DEFAULT gen_random_uuid(), tenant_id uuid NOT NULL,
              from_type text NOT NULL CHECK (from_type ~ '^[a-z][a-z0-9_.]{0,63}$'), from_id uuid NOT NULL,
              to_type text NOT NULL CHECK (to_type ~ '^[a-z][a-z0-9_.]{0,63}$'), to_id uuid NOT NULL,
              kind text NOT NULL CHECK (kind ~ '^[a-z][a-z0-9_.]{0,63}$'),
              source text NOT NULL CHECK (source IN ('manual','rule','import','merge','system')),
              created_by uuid, created_at timestamptz NOT NULL DEFAULT now(), removed_at timestamptz, removed_by uuid)
            """,
            "CREATE UNIQUE INDEX links_active_unique ON links (tenant_id, from_type, from_id, to_type, to_id, kind) WHERE removed_at IS NULL",
            "CREATE INDEX links_from ON links (tenant_id, from_type, from_id)",
            "CREATE INDEX links_to ON links (tenant_id, to_type, to_id)",
            "UPDATE schema_version SET version = 15 WHERE version < 15"])
    }
    func revert(on db: any Database) async throws {
        try await run(db, [
            "DROP TABLE links", "DROP TABLE contact_aliases", "DROP TABLE contact_bank_accounts", "DROP TABLE contact_emails",
            "DROP TABLE contact_addresses", "DROP TABLE contacts",
            """
            UPDATE schema_version SET version = CASE WHEN EXISTS (SELECT 1 FROM _fluent_migrations WHERE left(name, 4) = '014_') THEN 14 ELSE 13 END
            WHERE version = 15
            """])
    }
}
