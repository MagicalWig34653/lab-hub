import Vapor
import Fluent
import SQLKit

// WP-K2 Mandanten. Expand: neue Tabellen und neue Spalten. `users.is_admin` (WP-K1) bleibt bestehen, wird aber nicht mehr gelesen
// oder geschrieben; sie entfällt in einer späteren Contract-Migration, sobald kein Server mehr mit WP-K1-Code läuft.

/// Mandanten, Mitgliedschaften (Rolle je Mandant), Betreiberkennzeichen am Nutzer, Mandant und Rolle an der Einladung.
/// Bestand aus WP-K1: gibt es Nutzer, entsteht ein Mandant "Hauptmandant"; ehemalige Admins werden Owner und Betreiber, alle anderen Member;
/// offene Einladungen gelten für diesen Mandanten mit Rolle `member`.
struct CreateTenants: AsyncMigration {
    let name = "013_tenants"
    func prepare(on db: any Database) async throws {
        try await run(db, [
            """
            CREATE TABLE tenants (id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
              name text NOT NULL CHECK (char_length(name) BETWEEN 1 AND 80),
              created_at timestamptz NOT NULL DEFAULT now(), disabled_at timestamptz)
            """,
            """
            CREATE TABLE memberships (tenant_id uuid NOT NULL REFERENCES tenants (id), user_id uuid NOT NULL REFERENCES users (id),
              role text NOT NULL CHECK (role IN ('owner','accountant','member','tax_advisor','customer_viewer')),
              created_at timestamptz NOT NULL DEFAULT now(), PRIMARY KEY (tenant_id, user_id))
            """,
            "CREATE INDEX memberships_user ON memberships (user_id)",
            "ALTER TABLE users ADD COLUMN is_operator boolean NOT NULL DEFAULT false",
            "ALTER TABLE invitations ADD COLUMN tenant_id uuid REFERENCES tenants (id)",
            "ALTER TABLE invitations ADD COLUMN role text CHECK (role IN ('owner','accountant','member','tax_advisor','customer_viewer'))",
            // Bestand übernehmen
            "INSERT INTO tenants (name) SELECT 'Hauptmandant' WHERE EXISTS (SELECT 1 FROM users)",
            """
            INSERT INTO memberships (tenant_id, user_id, role)
            SELECT t.id, u.id, CASE WHEN u.is_admin THEN 'owner' ELSE 'member' END FROM users u CROSS JOIN (SELECT id FROM tenants LIMIT 1) t
            """,
            "UPDATE users SET is_operator = is_admin",
            "UPDATE invitations SET tenant_id = (SELECT id FROM tenants LIMIT 1), role = 'member' WHERE tenant_id IS NULL AND EXISTS (SELECT 1 FROM tenants)",
            "UPDATE schema_version SET version = 13 WHERE version = 12"])
    }
    func revert(on db: any Database) async throws {
        try await run(db, [
            "UPDATE users SET is_admin = is_operator",
            "ALTER TABLE invitations DROP COLUMN role",
            "ALTER TABLE invitations DROP COLUMN tenant_id",
            "ALTER TABLE users DROP COLUMN is_operator",
            "DROP TABLE memberships",
            "DROP TABLE tenants",
            "UPDATE schema_version SET version = 12 WHERE version = 13"])
    }
}
