import Vapor
import Fluent
import SQLKit

// WP-K1 Auth. Expand-only: ausschließlich neue Tabellen; Revert entfernt sie wieder und setzt `schema_version` zurück.

/// Nutzer (global, Mandantenzuordnung kommt mit `memberships` in WP-K2). `is_admin` ist ein Übergang bis zu den Rollen aus WP-K2.
struct CreateUsers: AsyncMigration {
    let name = "006_users"
    func prepare(on db: any Database) async throws {
        try await run(db, [
            """
            CREATE TABLE users (id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
              handle text NOT NULL UNIQUE CHECK (handle ~ '^[a-z0-9][a-z0-9._-]{2,31}$'),
              display_name text NOT NULL CHECK (char_length(display_name) BETWEEN 1 AND 80),
              is_admin boolean NOT NULL DEFAULT false,
              created_at timestamptz NOT NULL DEFAULT now(), disabled_at timestamptz)
            """,
            "UPDATE schema_version SET version = 6 WHERE version = 5"])
    }
    func revert(on db: any Database) async throws {
        try await run(db, ["DROP TABLE users", "UPDATE schema_version SET version = 5 WHERE version = 6"])
    }
}

struct CreatePasskeyCredentials: AsyncMigration {
    let name = "007_passkey_credentials"
    func prepare(on db: any Database) async throws {
        try await run(db, [
            """
            CREATE TABLE passkey_credentials (id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
              user_id uuid NOT NULL REFERENCES users (id), credential_id bytea NOT NULL UNIQUE, public_key bytea NOT NULL,
              sign_count bigint NOT NULL DEFAULT 0, name text NOT NULL, backed_up boolean NOT NULL DEFAULT false,
              created_at timestamptz NOT NULL DEFAULT now(), last_used_at timestamptz, revoked_at timestamptz)
            """,
            "CREATE INDEX passkey_credentials_user ON passkey_credentials (user_id)",
            "UPDATE schema_version SET version = 7 WHERE version = 6"])
    }
    func revert(on db: any Database) async throws {
        try await run(db, ["DROP TABLE passkey_credentials", "UPDATE schema_version SET version = 6 WHERE version = 7"])
    }
}

/// Sitzungen: nur der Hash des Tokens liegt in der Datenbank; Ablauf und Widerruf werden mit DB-`now()` geprüft.
struct CreateSessions: AsyncMigration {
    let name = "008_sessions"
    func prepare(on db: any Database) async throws {
        try await run(db, [
            """
            CREATE TABLE sessions (id uuid PRIMARY KEY DEFAULT gen_random_uuid(), user_id uuid NOT NULL REFERENCES users (id),
              token_hash text NOT NULL UNIQUE, kind text NOT NULL DEFAULT 'normal' CHECK (kind IN ('normal', 'recovery')),
              created_at timestamptz NOT NULL DEFAULT now(), expires_at timestamptz NOT NULL,
              last_seen_at timestamptz NOT NULL DEFAULT now(), revoked_at timestamptz)
            """,
            "CREATE INDEX sessions_user ON sessions (user_id) WHERE revoked_at IS NULL",
            "UPDATE schema_version SET version = 8 WHERE version = 7"])
    }
    func revert(on db: any Database) async throws {
        try await run(db, ["DROP TABLE sessions", "UPDATE schema_version SET version = 7 WHERE version = 8"])
    }
}

struct CreateInvitations: AsyncMigration {
    let name = "009_invitations"
    func prepare(on db: any Database) async throws {
        try await run(db, [
            """
            CREATE TABLE invitations (id uuid PRIMARY KEY DEFAULT gen_random_uuid(), token_hash text NOT NULL UNIQUE,
              created_by uuid NOT NULL, created_at timestamptz NOT NULL DEFAULT now(), expires_at timestamptz NOT NULL,
              used_at timestamptz, used_by uuid)
            """,
            "UPDATE schema_version SET version = 9 WHERE version = 8"])
    }
    func revert(on db: any Database) async throws {
        try await run(db, ["DROP TABLE invitations", "UPDATE schema_version SET version = 8 WHERE version = 9"])
    }
}

struct CreateRecoveryCodes: AsyncMigration {
    let name = "010_recovery_codes"
    func prepare(on db: any Database) async throws {
        try await run(db, [
            """
            CREATE TABLE recovery_codes (id uuid PRIMARY KEY DEFAULT gen_random_uuid(), user_id uuid NOT NULL REFERENCES users (id),
              code_hash text NOT NULL, created_at timestamptz NOT NULL DEFAULT now(), used_at timestamptz, UNIQUE (user_id, code_hash))
            """,
            "UPDATE schema_version SET version = 10 WHERE version = 9"])
    }
    func revert(on db: any Database) async throws {
        try await run(db, ["DROP TABLE recovery_codes", "UPDATE schema_version SET version = 9 WHERE version = 10"])
    }
}

/// Audit-Log: nur anhängen. Trigger verweigern UPDATE, DELETE und TRUNCATE (auch dem Anwendungsbenutzer).
/// `meta` enthält nur Kennzeichen/Zahlen (siehe `AuditEvent`), keine Nutzdaten.
struct CreateAuditLog: AsyncMigration {
    let name = "011_audit_log"
    func prepare(on db: any Database) async throws {
        try await run(db, [
            """
            CREATE TABLE audit_log (id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY, at timestamptz NOT NULL DEFAULT now(),
              action text NOT NULL, actor_user_id uuid, tenant_id uuid, subject_type text, subject_id text,
              meta jsonb NOT NULL DEFAULT '{}'::jsonb, request_id text)
            """,
            "CREATE INDEX audit_log_at ON audit_log (at)",
            """
            CREATE OR REPLACE FUNCTION audit_log_immutable() RETURNS trigger LANGUAGE plpgsql AS $$
            BEGIN RAISE EXCEPTION 'audit_log is append-only' USING ERRCODE = 'insufficient_privilege'; END $$
            """,
            "CREATE TRIGGER audit_log_no_change BEFORE UPDATE OR DELETE ON audit_log FOR EACH ROW EXECUTE FUNCTION audit_log_immutable()",
            "CREATE TRIGGER audit_log_no_truncate BEFORE TRUNCATE ON audit_log FOR EACH STATEMENT EXECUTE FUNCTION audit_log_immutable()",
            "UPDATE schema_version SET version = 11 WHERE version = 10"])
    }
    func revert(on db: any Database) async throws {
        try await run(db, ["DROP TABLE audit_log", "DROP FUNCTION audit_log_immutable()",
                           "UPDATE schema_version SET version = 10 WHERE version = 11"])
    }
}

/// WP-H6 (K1-Befund 5): Rechte auf `audit_log` einschränken. Dem Anwendungsbenutzer (hier: Eigentümer der Tabelle) und PUBLIC werden alle Rechte entzogen;
/// übrig bleiben INSERT und SELECT (kein UPDATE, DELETE, TRUNCATE, TRIGGER). Die Trigger aus 011 bleiben als zweite Schicht.
/// Grenze (ehrlich): mit EINER Datenbankrolle, die Eigentümerin der Tabelle ist, kann diese Rolle per `GRANT` oder `ALTER TABLE … DISABLE TRIGGER` alles zurückholen;
/// die Maßnahme schützt vor versehentlichem/automatisiertem DML (SQL-Injection ohne DDL-Fähigkeit) und macht jede Aufhebung zu einer eigenen, sichtbaren DDL-Anweisung.
/// Vollständiger Schutz braucht getrennte Rollen (Migrationsrolle als Eigentümerin, Laufzeitrolle nur mit INSERT/SELECT): `deploy/README.md`, Abschnitt „Datenbankrollen“.
/// Keine Schemaänderung, daher keine `schema_version` (wie bei 016).
struct HardenAuditLog: AsyncMigration {
    let name = "018_audit_hardening"
    func prepare(on db: any Database) async throws {
        try await run(db, [
            "REVOKE ALL ON audit_log FROM PUBLIC",
            "REVOKE ALL ON audit_log FROM CURRENT_USER",
            "GRANT SELECT, INSERT ON audit_log TO CURRENT_USER"])
    }
    func revert(on db: any Database) async throws {
        try await run(db, ["GRANT ALL ON audit_log TO CURRENT_USER"])
    }
}

/// WP-H8 (Befund aus WP-F5): `018_audit_hardening` hat dem Eigentümer auch TRIGGER entzogen. Mit einer normalen, nicht-privilegierten Einzelrolle
/// (so legt `setup.sh` sie an) scheitert danach jede Migration, die einen Trigger auf `audit_log` anlegt (`dms_021_revision`: `permission denied for table audit_log`);
/// Tests und Dev-Compose laufen als Superuser und merkten es nicht. Reparatur als Folgemigration (018 bleibt unverändert, ausgelieferte Namen ändern sich nie):
/// Dem Eigentümer wird TRIGGER zurückgegeben. Das schwächt die Härtung nicht messbar: Der Eigentümer kann sich jedes Recht ohnehin per `GRANT` selbst geben und
/// `ALTER TABLE … DISABLE TRIGGER` ausführen; UPDATE, DELETE und TRUNCATE bleiben entzogen (kein Rückbau der DML-Hürde), die Trigger aus 011 bleiben die zweite Schicht.
/// Wirkt für frische und bestehende Installationen (Kern-Migrationen laufen vor Modul-Migrationen). Keine `schema_version`-Änderung (nur Rechte, wie 016/018).
struct RestoreAuditTriggerPrivilege: AsyncMigration {
    let name = "019_audit_trigger_privilege"
    func prepare(on db: any Database) async throws {
        try await run(db, ["GRANT TRIGGER ON audit_log TO CURRENT_USER"])
    }
    func revert(on db: any Database) async throws {
        try await run(db, ["REVOKE TRIGGER ON audit_log FROM CURRENT_USER"])
    }
}

/// Hilfstabellen der Anmeldung: kurzlebige WebAuthn-Challenges und Rate-Limit-Ereignisse (beides in der DB, nie im Speicher).
struct CreateAuthSupport: AsyncMigration {
    let name = "012_auth_support"
    func prepare(on db: any Database) async throws {
        try await run(db, [
            """
            CREATE TABLE auth_challenges (id uuid PRIMARY KEY DEFAULT gen_random_uuid(), purpose text NOT NULL,
              challenge bytea NOT NULL, payload jsonb NOT NULL DEFAULT '{}'::jsonb, user_id uuid, invitation_id uuid,
              created_at timestamptz NOT NULL DEFAULT now(), expires_at timestamptz NOT NULL, consumed_at timestamptz)
            """,
            "CREATE TABLE rate_limit_events (key text NOT NULL, occurred_at timestamptz NOT NULL DEFAULT now())",
            "CREATE INDEX rate_limit_events_key ON rate_limit_events (key, occurred_at)",
            "UPDATE schema_version SET version = 12 WHERE version = 11"])
    }
    func revert(on db: any Database) async throws {
        try await run(db, ["DROP TABLE rate_limit_events", "DROP TABLE auth_challenges",
                           "UPDATE schema_version SET version = 11 WHERE version = 12"])
    }
}
