import Vapor
import Fluent
import SQLKit

// WP-R2 Belege des Rechnungsmoduls. Modul-Migration (läuft immer, auch bei deaktiviertem Modul), Expand-only: nur neue Tabellen, Funktionen und Trigger.
// Invarianten (MODUL-RECHNUNG.md Abschnitt 2) stehen in der Datenbank, nicht nur in der API:
//  1. Nach dem Finalisieren ist ein Beleg samt Positionen, Zusatzkosten und Steuersummen unveränderlich (Trigger; Korrektur später per Gutschrift, WP-R3).
//  2. Nummer eindeutig je (Mandant, Serie) unter allen vergebenen Nummern (Teilindex, Grund für PostgreSQL, ADR 0001).
//  3. Beträge `numeric`, nie Gleitkomma; Verweise zwischen Modultabellen zusammengesetzt (tenant_id, id), Kontakt per Trigger auf denselben Mandanten geprüft.

struct CreateInvoiceDocuments: AsyncMigration {
    let name = "invoice_028_documents"

    func prepare(on db: any Database) async throws {
        try await run(db, [
            """
            CREATE TABLE invoice_documents (id uuid PRIMARY KEY DEFAULT gen_random_uuid(), tenant_id uuid NOT NULL REFERENCES tenants (id),
              document_type_id uuid NOT NULL, kind text NOT NULL CHECK (kind IN ('quote', 'order_confirmation', 'delivery_note', 'invoice', 'credit_note')),
              series_id uuid, contact_id uuid REFERENCES contacts (id),
              status text NOT NULL DEFAULT 'draft' CHECK (status IN ('draft', 'final', 'cancelled')),
              number text CHECK (number IS NULL OR char_length(number) BETWEEN 1 AND 100), counter_value bigint CHECK (counter_value IS NULL OR counter_value >= 1),
              issue_date date NOT NULL, due_date date, delivery_date date,
              currency text NOT NULL CHECK (currency ~ '^[A-Z]{3}$'), price_mode text NOT NULL DEFAULT 'net' CHECK (price_mode IN ('net', 'gross')),
              discount_percent numeric(7,4) NOT NULL DEFAULT 0 CHECK (discount_percent BETWEEN 0 AND 100), discount_amount numeric(18,4),
              rounding_mode text NOT NULL DEFAULT 'halfAwayFromZero' CHECK (rounding_mode IN ('halfAwayFromZero', 'halfEven', 'towardZero')),
              header_text text CHECK (header_text IS NULL OR char_length(header_text) <= 5000), footer_text text CHECK (footer_text IS NULL OR char_length(footer_text) <= 5000),
              note text CHECK (note IS NULL OR char_length(note) <= 5000),
              net_total numeric(18,4) NOT NULL DEFAULT 0, tax_total numeric(18,4) NOT NULL DEFAULT 0, gross_total numeric(18,4) NOT NULL DEFAULT 0, discount_total numeric(18,4) NOT NULL DEFAULT 0,
              tax_regime text CHECK (tax_regime IS NULL OR tax_regime IN ('standard', 'small_business')),
              sender jsonb, recipient jsonb, content_hash text CHECK (content_hash IS NULL OR content_hash ~ '^[0-9a-f]{64}$'),
              finalized_at timestamptz, finalized_by uuid, rev integer NOT NULL DEFAULT 1,
              created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now(), UNIQUE (tenant_id, id),
              FOREIGN KEY (tenant_id, document_type_id) REFERENCES invoice_document_types (tenant_id, id),
              FOREIGN KEY (tenant_id, series_id) REFERENCES invoice_series (tenant_id, id),
              CHECK ((status = 'draft') = (number IS NULL AND counter_value IS NULL)),
              CHECK ((status = 'draft') = (finalized_at IS NULL)),
              CHECK (status = 'draft' OR (series_id IS NOT NULL AND content_hash IS NOT NULL AND sender IS NOT NULL AND recipient IS NOT NULL)))
            """,
            // Eindeutigkeit der vergebenen Nummern (Entwürfe haben keine). Ein Verstoß beim Finalisieren wird zu 409 `number_conflict`.
            "CREATE UNIQUE INDEX invoice_documents_number ON invoice_documents (tenant_id, series_id, number) WHERE number IS NOT NULL",
            "CREATE INDEX invoice_documents_list ON invoice_documents (tenant_id, created_at DESC, id)",
            "CREATE INDEX invoice_documents_contact ON invoice_documents (tenant_id, contact_id) WHERE contact_id IS NOT NULL",
            """
            CREATE TABLE invoice_lines (id uuid PRIMARY KEY DEFAULT gen_random_uuid(), tenant_id uuid NOT NULL, document_id uuid NOT NULL, position integer NOT NULL CHECK (position >= 1),
              kind text NOT NULL CHECK (kind IN ('item', 'text')), item_id uuid, description text NOT NULL CHECK (char_length(description) <= 5000), unit text CHECK (unit IS NULL OR char_length(unit) <= 20),
              quantity numeric(18,4), second_quantity numeric(18,4), unit_price numeric(18,4), tax_rate numeric(7,4) CHECK (tax_rate IS NULL OR tax_rate BETWEEN 0 AND 100),
              discount_kind text CHECK (discount_kind IS NULL OR discount_kind IN ('percent', 'amount')), discount_value numeric(18,4),
              UNIQUE (document_id, position), FOREIGN KEY (tenant_id, document_id) REFERENCES invoice_documents (tenant_id, id) ON DELETE CASCADE,
              FOREIGN KEY (tenant_id, item_id) REFERENCES invoice_items (tenant_id, id),
              CHECK (kind = 'text' OR (quantity IS NOT NULL AND unit_price IS NOT NULL AND tax_rate IS NOT NULL)),
              CHECK (kind = 'item' OR (quantity IS NULL AND second_quantity IS NULL AND unit_price IS NULL AND tax_rate IS NULL AND discount_kind IS NULL AND discount_value IS NULL)),
              CHECK ((discount_kind IS NULL) = (discount_value IS NULL)))
            """,
            """
            CREATE TABLE invoice_charges (id uuid PRIMARY KEY DEFAULT gen_random_uuid(), tenant_id uuid NOT NULL, document_id uuid NOT NULL, position integer NOT NULL CHECK (position >= 1),
              description text NOT NULL CHECK (char_length(description) BETWEEN 1 AND 200), tax_rate numeric(7,4) NOT NULL CHECK (tax_rate BETWEEN 0 AND 100), amount numeric(18,4) NOT NULL,
              UNIQUE (document_id, position), FOREIGN KEY (tenant_id, document_id) REFERENCES invoice_documents (tenant_id, id) ON DELETE CASCADE)
            """,
            // Summen je Steuersatz (Ergebnis des Rechenkerns, mit jedem Speichern des Entwurfs neu berechnet)
            """
            CREATE TABLE invoice_tax_totals (tenant_id uuid NOT NULL, document_id uuid NOT NULL, rate numeric(7,4) NOT NULL, net numeric(18,4) NOT NULL, tax numeric(18,4) NOT NULL, gross numeric(18,4) NOT NULL,
              PRIMARY KEY (document_id, rate), FOREIGN KEY (tenant_id, document_id) REFERENCES invoice_documents (tenant_id, id) ON DELETE CASCADE)
            """,
            // Unveränderlichkeit: Beleg
            """
            CREATE OR REPLACE FUNCTION invoice_documents_guard() RETURNS trigger LANGUAGE plpgsql AS $$
            BEGIN
              IF TG_OP = 'DELETE' THEN
                IF OLD.status <> 'draft' THEN RAISE EXCEPTION 'final document is immutable' USING ERRCODE = '23000'; END IF;
                RETURN OLD;
              END IF;
              IF TG_OP = 'UPDATE' AND OLD.status <> 'draft' THEN RAISE EXCEPTION 'final document is immutable' USING ERRCODE = '23000'; END IF;
              IF NEW.contact_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM contacts c WHERE c.id = NEW.contact_id AND c.tenant_id = NEW.tenant_id) THEN
                RAISE EXCEPTION 'contact belongs to another tenant' USING ERRCODE = '23503';
              END IF;
              RETURN NEW;
            END $$
            """,
            "CREATE TRIGGER invoice_documents_guard BEFORE INSERT OR UPDATE OR DELETE ON invoice_documents FOR EACH ROW EXECUTE FUNCTION invoice_documents_guard()",
            // Unveränderlichkeit: Positionen, Zusatzkosten, Steuersummen (Elternzeile muss Entwurf sein; beim Löschen des Entwurfs per CASCADE ist sie schon weg)
            """
            CREATE OR REPLACE FUNCTION invoice_children_guard() RETURNS trigger LANGUAGE plpgsql AS $$
            DECLARE parent_status text;
            BEGIN
              SELECT status INTO parent_status FROM invoice_documents WHERE id = CASE WHEN TG_OP = 'DELETE' THEN OLD.document_id ELSE NEW.document_id END;
              IF parent_status IS NOT NULL AND parent_status <> 'draft' THEN RAISE EXCEPTION 'final document is immutable' USING ERRCODE = '23000'; END IF;
              RETURN CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
            END $$
            """,
            "CREATE TRIGGER invoice_lines_guard BEFORE INSERT OR UPDATE OR DELETE ON invoice_lines FOR EACH ROW EXECUTE FUNCTION invoice_children_guard()",
            "CREATE TRIGGER invoice_charges_guard BEFORE INSERT OR UPDATE OR DELETE ON invoice_charges FOR EACH ROW EXECUTE FUNCTION invoice_children_guard()",
            "CREATE TRIGGER invoice_tax_totals_guard BEFORE INSERT OR UPDATE OR DELETE ON invoice_tax_totals FOR EACH ROW EXECUTE FUNCTION invoice_children_guard()"])
    }

    func revert(on db: any Database) async throws {
        try await run(db, ["DROP TABLE invoice_tax_totals", "DROP TABLE invoice_charges", "DROP TABLE invoice_lines", "DROP TABLE invoice_documents",
                           "DROP FUNCTION invoice_children_guard()", "DROP FUNCTION invoice_documents_guard()"])
    }
}
