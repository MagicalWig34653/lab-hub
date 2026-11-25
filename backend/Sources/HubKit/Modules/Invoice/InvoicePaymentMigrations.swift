import Vapor
import Fluent
import SQLKit

// WP-R3 Zahlungen, Skonto, Verknüpfungen Beleg↔Beleg. Modul-Migration, Expand-only: zwei nullbare Spalten am Beleg, drei neue Tabellen.
// Invarianten stehen in der Datenbank, nicht nur in der API:
//  1. Aktive Zuordnungen übersteigen nie den Zahlbetrag; über den Rechnungsbetrag (abzüglich Gutschriften) nur mit Kennzeichen `overpayment`.
//  2. Zugeordnet wird nur auf finale Rechnungen gleicher Währung und gleichen Mandanten, immer mit bestätigendem Nutzer (`confirmed_by` NOT NULL).
//  3. Zahlungen und Zuordnungen werden nie geändert oder gelöscht: nur Storno bzw. Rücknahme (Historie bleibt).
//  4. Umwandlung und Gutschrift bleiben verknüpft, sobald der Zielbeleg finalisiert ist.

struct CreateInvoicePayments: AsyncMigration {
    let name = "invoice_029_payments"

    func prepare(on db: any Database) async throws {
        try await run(db, [
            """
            ALTER TABLE invoice_documents
              ADD COLUMN skonto_percent numeric(7,4) CHECK (skonto_percent > 0 AND skonto_percent < 100),
              ADD COLUMN skonto_days integer CHECK (skonto_days BETWEEN 0 AND 365),
              ADD CONSTRAINT invoice_documents_skonto CHECK ((skonto_percent IS NULL) = (skonto_days IS NULL))
            """,
            """
            CREATE TABLE invoice_document_links (id uuid PRIMARY KEY DEFAULT gen_random_uuid(), tenant_id uuid NOT NULL, from_document_id uuid NOT NULL, to_document_id uuid NOT NULL,
              kind text NOT NULL CHECK (kind IN ('conversion', 'credit_note', 'reference')), created_at timestamptz NOT NULL DEFAULT now(), created_by uuid,
              CHECK (from_document_id <> to_document_id),
              FOREIGN KEY (tenant_id, from_document_id) REFERENCES invoice_documents (tenant_id, id) ON DELETE CASCADE,
              FOREIGN KEY (tenant_id, to_document_id) REFERENCES invoice_documents (tenant_id, id) ON DELETE CASCADE)
            """,
            // Ein erzeugter Beleg hat genau eine Herkunft; eine Referenz gibt es je Belegpaar einmal (richtungslos).
            "CREATE UNIQUE INDEX invoice_document_links_origin ON invoice_document_links (to_document_id) WHERE kind <> 'reference'",
            """
            CREATE UNIQUE INDEX invoice_document_links_reference ON invoice_document_links (LEAST(from_document_id, to_document_id), GREATEST(from_document_id, to_document_id))
              WHERE kind = 'reference'
            """,
            "CREATE INDEX invoice_document_links_from ON invoice_document_links (tenant_id, from_document_id)",
            "CREATE INDEX invoice_document_links_to ON invoice_document_links (tenant_id, to_document_id)",
            """
            CREATE OR REPLACE FUNCTION invoice_document_links_guard() RETURNS trigger LANGUAGE plpgsql AS $$
            BEGIN
              IF TG_OP = 'UPDATE' THEN RAISE EXCEPTION 'document link is immutable' USING ERRCODE = '23000'; END IF;
              -- Beim Löschen eines Entwurfs (CASCADE) ist der Zielbeleg schon weg.
              IF OLD.kind <> 'reference' AND EXISTS (SELECT 1 FROM invoice_documents d WHERE d.id = OLD.to_document_id AND d.status <> 'draft') THEN
                RAISE EXCEPTION 'document link is locked' USING ERRCODE = '23000';
              END IF;
              RETURN OLD;
            END $$
            """,
            "CREATE TRIGGER invoice_document_links_guard BEFORE UPDATE OR DELETE ON invoice_document_links FOR EACH ROW EXECUTE FUNCTION invoice_document_links_guard()",
            """
            CREATE TABLE invoice_payments (id uuid PRIMARY KEY DEFAULT gen_random_uuid(), tenant_id uuid NOT NULL REFERENCES tenants (id), contact_id uuid REFERENCES contacts (id),
              paid_on date NOT NULL, amount numeric(18,4) NOT NULL CHECK (amount > 0), currency text NOT NULL CHECK (currency ~ '^[A-Z]{3}$'),
              method text NOT NULL DEFAULT 'bank_transfer' CHECK (method IN ('bank_transfer', 'cash', 'card', 'direct_debit', 'other')),
              reference text CHECK (reference IS NULL OR char_length(reference) <= 500), note text CHECK (note IS NULL OR char_length(note) <= 5000),
              created_at timestamptz NOT NULL DEFAULT now(), created_by uuid NOT NULL,
              voided_at timestamptz, voided_by uuid, void_reason text CHECK (void_reason IS NULL OR char_length(void_reason) BETWEEN 1 AND 500),
              UNIQUE (tenant_id, id), CHECK ((voided_at IS NULL) = (voided_by IS NULL) AND (voided_at IS NULL) = (void_reason IS NULL)))
            """,
            "CREATE INDEX invoice_payments_list ON invoice_payments (tenant_id, created_at DESC, id)",
            """
            CREATE TABLE invoice_payment_allocations (id uuid PRIMARY KEY DEFAULT gen_random_uuid(), tenant_id uuid NOT NULL, payment_id uuid NOT NULL, document_id uuid NOT NULL,
              amount numeric(18,4) NOT NULL CHECK (amount > 0), skonto_amount numeric(18,4) NOT NULL DEFAULT 0 CHECK (skonto_amount >= 0), overpayment boolean NOT NULL DEFAULT false,
              confirmed_by uuid NOT NULL, confirmed_at timestamptz NOT NULL DEFAULT now(), revoked_at timestamptz, revoked_by uuid,
              CHECK ((revoked_at IS NULL) = (revoked_by IS NULL)),
              FOREIGN KEY (tenant_id, payment_id) REFERENCES invoice_payments (tenant_id, id),
              FOREIGN KEY (tenant_id, document_id) REFERENCES invoice_documents (tenant_id, id))
            """,
            "CREATE UNIQUE INDEX invoice_payment_allocations_active ON invoice_payment_allocations (payment_id, document_id) WHERE revoked_at IS NULL",
            "CREATE INDEX invoice_payment_allocations_document ON invoice_payment_allocations (tenant_id, document_id)",
            "CREATE INDEX invoice_payment_allocations_payment ON invoice_payment_allocations (tenant_id, payment_id)",
            """
            CREATE OR REPLACE FUNCTION invoice_payments_guard() RETURNS trigger LANGUAGE plpgsql AS $$
            BEGIN
              IF TG_OP = 'DELETE' THEN RAISE EXCEPTION 'payments are never deleted' USING ERRCODE = '23000'; END IF;
              IF TG_OP = 'UPDATE' THEN
                IF OLD.voided_at IS NOT NULL OR (to_jsonb(NEW) - 'voided_at' - 'voided_by' - 'void_reason') IS DISTINCT FROM (to_jsonb(OLD) - 'voided_at' - 'voided_by' - 'void_reason') THEN
                  RAISE EXCEPTION 'payment is immutable' USING ERRCODE = '23000';
                END IF;
                IF EXISTS (SELECT 1 FROM invoice_payment_allocations a WHERE a.payment_id = OLD.id AND a.revoked_at IS NULL) THEN
                  RAISE EXCEPTION 'payment is allocated' USING ERRCODE = '23000';
                END IF;
              ELSIF NEW.contact_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM contacts c WHERE c.id = NEW.contact_id AND c.tenant_id = NEW.tenant_id) THEN
                RAISE EXCEPTION 'contact belongs to another tenant' USING ERRCODE = '23503';
              END IF;
              RETURN NEW;
            END $$
            """,
            "CREATE TRIGGER invoice_payments_guard BEFORE INSERT OR UPDATE OR DELETE ON invoice_payments FOR EACH ROW EXECUTE FUNCTION invoice_payments_guard()",
            // Die Zeilensperren (erst Zahlung, dann Beleg) serialisieren parallele Zuordnungen auch am Dienst vorbei.
            """
            CREATE OR REPLACE FUNCTION invoice_allocations_guard() RETURNS trigger LANGUAGE plpgsql AS $$
            DECLARE p invoice_payments%ROWTYPE; d invoice_documents%ROWTYPE; used numeric; settled numeric; credits numeric;
            BEGIN
              IF TG_OP = 'DELETE' THEN RAISE EXCEPTION 'allocations are never deleted' USING ERRCODE = '23000'; END IF;
              IF TG_OP = 'UPDATE' THEN
                IF OLD.revoked_at IS NOT NULL OR NEW.revoked_at IS NULL OR (to_jsonb(NEW) - 'revoked_at' - 'revoked_by') IS DISTINCT FROM (to_jsonb(OLD) - 'revoked_at' - 'revoked_by') THEN
                  RAISE EXCEPTION 'allocation is immutable' USING ERRCODE = '23000';
                END IF;
                RETURN NEW;
              END IF;
              SELECT * INTO p FROM invoice_payments WHERE id = NEW.payment_id AND tenant_id = NEW.tenant_id FOR UPDATE;
              IF NOT FOUND OR p.voided_at IS NOT NULL OR NEW.revoked_at IS NOT NULL THEN RAISE EXCEPTION 'payment cannot be allocated' USING ERRCODE = '23000'; END IF;
              SELECT * INTO d FROM invoice_documents WHERE id = NEW.document_id AND tenant_id = NEW.tenant_id FOR UPDATE;
              IF NOT FOUND OR d.status <> 'final' OR d.kind <> 'invoice' OR d.currency <> p.currency THEN
                RAISE EXCEPTION 'document cannot receive payments' USING ERRCODE = '23000';
              END IF;
              SELECT coalesce(sum(amount), 0) INTO used FROM invoice_payment_allocations WHERE payment_id = NEW.payment_id AND revoked_at IS NULL;
              IF used + NEW.amount > p.amount THEN RAISE EXCEPTION 'allocations exceed the payment' USING ERRCODE = '23000'; END IF;
              IF NOT NEW.overpayment THEN
                SELECT coalesce(sum(amount + skonto_amount), 0) INTO settled FROM invoice_payment_allocations WHERE document_id = NEW.document_id AND revoked_at IS NULL;
                SELECT coalesce(sum(c.gross_total), 0) INTO credits FROM invoice_document_links l JOIN invoice_documents c ON c.id = l.to_document_id
                  WHERE l.from_document_id = NEW.document_id AND l.kind = 'credit_note' AND c.status = 'final';
                IF settled + NEW.amount + NEW.skonto_amount > d.gross_total + credits THEN RAISE EXCEPTION 'allocations exceed the invoice' USING ERRCODE = '23000'; END IF;
              END IF;
              RETURN NEW;
            END $$
            """,
            "CREATE TRIGGER invoice_allocations_guard BEFORE INSERT OR UPDATE OR DELETE ON invoice_payment_allocations FOR EACH ROW EXECUTE FUNCTION invoice_allocations_guard()"])
    }

    func revert(on db: any Database) async throws {
        try await run(db, ["DROP TABLE invoice_payment_allocations", "DROP TABLE invoice_payments", "DROP TABLE invoice_document_links",
                           "DROP FUNCTION invoice_allocations_guard()", "DROP FUNCTION invoice_payments_guard()", "DROP FUNCTION invoice_document_links_guard()",
                           "ALTER TABLE invoice_documents DROP CONSTRAINT invoice_documents_skonto, DROP COLUMN skonto_percent, DROP COLUMN skonto_days"])
    }
}
