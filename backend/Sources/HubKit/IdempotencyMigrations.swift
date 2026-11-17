import Vapor
import Fluent
import SQLKit

/// WP-H12 (Codex-Befund 7): `idempotency_keys.locked_at` ist der Beginn der Lease einer nicht abgeschlossenen Zeile (DB-Zeit).
/// Expand-only: neue Spalte mit Standardwert `now()`; vorhandene Zeilen werden mit `created_at` vorbelegt, alter Code ignoriert die Spalte.
/// Rollout: Migration vor dem Code-Update; ein alter Prozess lässt `locked_at` auf dem Standardwert, was für die Lease korrekt ist.
/// `schema_version` bleibt unverändert (wie 020: der Stand wird nur von den Migrationen 001-017 geführt; Tests prüfen 17).
struct CreateIdempotencyLease: AsyncMigration {
    let name = "021_idempotency_lease"
    func prepare(on db: any Database) async throws {
        try await run(db, [
            "ALTER TABLE idempotency_keys ADD COLUMN locked_at timestamptz NOT NULL DEFAULT now()",
            "UPDATE idempotency_keys SET locked_at = created_at",
            "CREATE INDEX idempotency_keys_created ON idempotency_keys (created_at)"])
    }
    func revert(on db: any Database) async throws {
        try await run(db, ["DROP INDEX idempotency_keys_created", "ALTER TABLE idempotency_keys DROP COLUMN locked_at"])
    }
}
