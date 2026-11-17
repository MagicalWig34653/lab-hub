import Vapor
import Fluent
import SQLKit

// WP-R1 Stammdaten des Rechnungsmoduls. Modul-Migration (läuft immer, auch bei deaktiviertem Modul). Expand-only: nur neue Tabellen, Funktion, Trigger;
// bestehende Tabellen bleiben unberührt. Revert entfernt alles wieder. `schema_version` bleibt unverändert (Modulstände stehen in `_fluent_migrations`, wie bei DMS).
// Mandantensicherheit auch in der Datenbank: Verweise zwischen Modultabellen sind zusammengesetzt (tenant_id, id). Beträge nur `numeric` (nie Gleitkomma).

struct CreateInvoiceMaster: AsyncMigration {
    let name = "invoice_027_master"

    func prepare(on db: any Database) async throws {
        try await run(db, [
            // Absender und Einstellungen: genau eine Zeile je Mandant (PUT ersetzt, `rev` zählt mit)
            """
            CREATE TABLE invoice_settings (tenant_id uuid PRIMARY KEY REFERENCES tenants (id),
              sender_name text NOT NULL CHECK (char_length(sender_name) BETWEEN 1 AND 200),
              street text CHECK (street IS NULL OR char_length(street) <= 200), postal_code text CHECK (postal_code IS NULL OR char_length(postal_code) <= 20),
              city text CHECK (city IS NULL OR char_length(city) <= 100), country text CHECK (country IS NULL OR country ~ '^[A-Z]{2}$'),
              tax_number text CHECK (tax_number IS NULL OR char_length(tax_number) <= 40), vat_id text CHECK (vat_id IS NULL OR char_length(vat_id) <= 20),
              email text CHECK (email IS NULL OR char_length(email) <= 200), phone text CHECK (phone IS NULL OR char_length(phone) <= 50),
              website text CHECK (website IS NULL OR char_length(website) <= 200), bank_name text CHECK (bank_name IS NULL OR char_length(bank_name) <= 100),
              iban text CHECK (iban IS NULL OR iban ~ '^[A-Z]{2}[0-9]{2}[A-Z0-9]{11,30}$'), bic text CHECK (bic IS NULL OR bic ~ '^[A-Z0-9]{8}([A-Z0-9]{3})?$'),
              currency text NOT NULL DEFAULT 'EUR' CHECK (currency ~ '^[A-Z]{3}$'), payment_term_days integer NOT NULL DEFAULT 14 CHECK (payment_term_days BETWEEN 0 AND 365),
              abbreviation text CHECK (abbreviation IS NULL OR abbreviation ~ '^[A-Za-z0-9]{1,10}$'), footer_text text CHECK (footer_text IS NULL OR char_length(footer_text) <= 2000),
              rev integer NOT NULL DEFAULT 1, created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now())
            """,
            // Steuerzeiträume (Regelbesteuerung/Kleinunternehmer mit Gültigkeit). Zeiträume eines Mandanten überlappen nie (Trigger als Rückfall zur Prüfung in der API).
            """
            CREATE TABLE invoice_tax_periods (id uuid PRIMARY KEY DEFAULT gen_random_uuid(), tenant_id uuid NOT NULL REFERENCES tenants (id),
              regime text NOT NULL CHECK (regime IN ('standard', 'small_business')), valid_from date NOT NULL, valid_to date,
              note text CHECK (note IS NULL OR char_length(note) <= 500), created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now(),
              UNIQUE (tenant_id, id), CHECK (valid_to IS NULL OR valid_to >= valid_from))
            """,
            "CREATE INDEX invoice_tax_periods_range ON invoice_tax_periods (tenant_id, valid_from)",
            """
            CREATE OR REPLACE FUNCTION invoice_tax_periods_no_overlap() RETURNS trigger LANGUAGE plpgsql AS $$
            BEGIN
              PERFORM pg_advisory_xact_lock(hashtextextended('invoice_tax_periods:' || NEW.tenant_id::text, 0));
              IF EXISTS (SELECT 1 FROM invoice_tax_periods o WHERE o.tenant_id = NEW.tenant_id AND o.id <> NEW.id
                         AND daterange(o.valid_from, o.valid_to, '[]') && daterange(NEW.valid_from, NEW.valid_to, '[]')) THEN
                RAISE EXCEPTION 'tax period overlaps another period' USING ERRCODE = '23P01';
              END IF;
              RETURN NEW;
            END $$
            """,
            "CREATE TRIGGER invoice_tax_periods_no_overlap BEFORE INSERT OR UPDATE ON invoice_tax_periods FOR EACH ROW EXECUTE FUNCTION invoice_tax_periods_no_overlap()",
            // Nummernserien: das Format bestimmt den Zähler-Gültigkeitsbereich; der Zähler selbst liegt im Kern (`counters`, Schlüssel `invoice:<serie>[-jjjj[-mm]]`)
            """
            CREATE TABLE invoice_series (id uuid PRIMARY KEY DEFAULT gen_random_uuid(), tenant_id uuid NOT NULL REFERENCES tenants (id),
              code text NOT NULL CHECK (code ~ '^[a-z][a-z0-9_]{0,39}$'), name text NOT NULL CHECK (char_length(name) BETWEEN 1 AND 100),
              number_format text NOT NULL CHECK (char_length(number_format) BETWEEN 1 AND 100),
              counter_scope text NOT NULL CHECK (counter_scope IN ('continuous', 'per_year', 'per_month')),
              active boolean NOT NULL DEFAULT true, created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now(), UNIQUE (tenant_id, id))
            """,
            "CREATE UNIQUE INDEX invoice_series_code ON invoice_series (tenant_id, code)",
            // Belegtypen: feste Arten (`kind`), je Mandant benennbar, mit optionaler Standardserie
            """
            CREATE TABLE invoice_document_types (id uuid PRIMARY KEY DEFAULT gen_random_uuid(), tenant_id uuid NOT NULL REFERENCES tenants (id),
              code text NOT NULL CHECK (code ~ '^[a-z][a-z0-9_]{0,39}$'), name text NOT NULL CHECK (char_length(name) BETWEEN 1 AND 100),
              kind text NOT NULL CHECK (kind IN ('quote', 'order_confirmation', 'delivery_note', 'invoice', 'credit_note')),
              default_series_id uuid, active boolean NOT NULL DEFAULT true,
              created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now(), UNIQUE (tenant_id, id),
              FOREIGN KEY (tenant_id, default_series_id) REFERENCES invoice_series (tenant_id, id))
            """,
            "CREATE UNIQUE INDEX invoice_document_types_code ON invoice_document_types (tenant_id, code)",
            "CREATE UNIQUE INDEX invoice_document_types_name ON invoice_document_types (tenant_id, lower(name))",
            // Artikel: Preis und Steuersatz als numeric(18,4) bzw. numeric(7,4); Bestand wird nur gespeichert (Lagerführung später)
            """
            CREATE TABLE invoice_items (id uuid PRIMARY KEY DEFAULT gen_random_uuid(), tenant_id uuid NOT NULL REFERENCES tenants (id),
              sku text CHECK (sku IS NULL OR char_length(sku) BETWEEN 1 AND 60), name text NOT NULL CHECK (char_length(name) BETWEEN 1 AND 200),
              description text CHECK (description IS NULL OR char_length(description) <= 2000), unit text CHECK (unit IS NULL OR char_length(unit) BETWEEN 1 AND 20),
              unit_price numeric(18,4) NOT NULL, price_includes_tax boolean NOT NULL DEFAULT false,
              tax_rate numeric(7,4) NOT NULL CHECK (tax_rate BETWEEN 0 AND 100),
              track_stock boolean NOT NULL DEFAULT false, stock_quantity numeric(18,4), active boolean NOT NULL DEFAULT true,
              created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now(), UNIQUE (tenant_id, id),
              CHECK (stock_quantity IS NULL OR track_stock))
            """,
            "CREATE UNIQUE INDEX invoice_items_sku ON invoice_items (tenant_id, lower(sku)) WHERE sku IS NOT NULL",
            "CREATE INDEX invoice_items_list ON invoice_items (tenant_id, lower(name), id)"])
    }

    func revert(on db: any Database) async throws {
        try await run(db, ["DROP TABLE invoice_items", "DROP TABLE invoice_document_types", "DROP TABLE invoice_series",
                           "DROP TABLE invoice_tax_periods", "DROP FUNCTION invoice_tax_periods_no_overlap()", "DROP TABLE invoice_settings"])
    }
}
