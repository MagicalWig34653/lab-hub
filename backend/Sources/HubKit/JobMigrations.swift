import Vapor
import Fluent
import SQLKit

/// WP-O1 (ADR 0006 Nr. 4): `jobs.priority` und `jobs.last_error`. Expand-only: neue Spalten mit Standardwert, der Zustand `failed_permanent`
/// ist nur ein neuer Textwert (`jobs.state` ist ungeprüft). Alter Code legt Jobs weiter ohne Priorität (0) an. Rollout: Migration vor Worker-Update;
/// ein alter Worker würde `failed_permanent`-Zeilen wieder abholen (alte Abfrage `state <> 'done'`), daher alte Worker vorher beenden (Handoff WP-O1).
/// `schema_version` 15 -> 17 (016 ist die DMS-Modulmigration ohne Versionsänderung).
struct CreateJobsPriority: AsyncMigration {
    let name = "017_jobs_priority"
    func prepare(on db: any Database) async throws {
        try await run(db, [
            "ALTER TABLE jobs ADD COLUMN priority integer NOT NULL DEFAULT 0",
            "ALTER TABLE jobs ADD COLUMN last_error text CHECK (last_error IS NULL OR char_length(last_error) <= 64)",
            "CREATE INDEX jobs_claim ON jobs (priority DESC, run_at, created_at) WHERE state IN ('queued', 'running')",
            "UPDATE schema_version SET version = 17 WHERE version < 17"])
    }
    func revert(on db: any Database) async throws {
        try await run(db, [
            "DROP INDEX jobs_claim", "ALTER TABLE jobs DROP COLUMN last_error", "ALTER TABLE jobs DROP COLUMN priority",
            "UPDATE schema_version SET version = 15 WHERE version = 17"])
    }
}
