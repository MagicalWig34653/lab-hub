import Vapor
import Fluent
import SQLKit

enum HubMigrations {
    static let all: [any Migration] = [CreateSchemaVersion(), CreateCounters(), CreateIdempotencyKeys(), CreateJobs(), CreateFiles(),
        CreateUsers(), CreatePasskeyCredentials(), CreateSessions(), CreateInvitations(), CreateRecoveryCodes(), CreateAuditLog(), CreateAuthSupport()]
}

func run(_ db: any Database, _ stmts: [String]) async throws {
    guard let s = db as? any SQLDatabase else { throw Abort(.internalServerError) }
    for st in stmts { try await s.raw(SQLQueryString(st)).run() }
}

/// Dokumentiert den Schemastand (zusätzlich zu Fluents `_fluent_migrations`).
struct CreateSchemaVersion: AsyncMigration {
    let name = "001_schema_version"
    func prepare(on db: any Database) async throws {
        try await run(db, [
            "CREATE TABLE schema_version (version integer PRIMARY KEY, name text NOT NULL, applied_at timestamptz NOT NULL DEFAULT now())",
            "INSERT INTO schema_version (version, name) VALUES (1, 'base')"])
    }
    func revert(on db: any Database) async throws { try await run(db, ["DROP TABLE schema_version"]) }
}

/// Atomarer Nummernzähler je Mandant und Schlüssel.
struct CreateCounters: AsyncMigration {
    let name = "002_counters"
    func prepare(on db: any Database) async throws {
        try await run(db, [
            "CREATE TABLE counters (tenant_id uuid NOT NULL, key text NOT NULL, value bigint NOT NULL, PRIMARY KEY (tenant_id, key))",
            "UPDATE schema_version SET version = 2 WHERE version = 1"])
    }
    func revert(on db: any Database) async throws { try await run(db, ["DROP TABLE counters"]) }
}

struct CreateIdempotencyKeys: AsyncMigration {
    let name = "003_idempotency_keys"
    func prepare(on db: any Database) async throws {
        try await run(db, [
            """
            CREATE TABLE idempotency_keys (tenant_id uuid NOT NULL, key text NOT NULL, request_hash text NOT NULL,
              state text NOT NULL DEFAULT 'in_progress', response_status integer, response_body text,
              created_at timestamptz NOT NULL DEFAULT now(), PRIMARY KEY (tenant_id, key))
            """,
            "UPDATE schema_version SET version = 3 WHERE version = 2"])
    }
    func revert(on db: any Database) async throws { try await run(db, ["DROP TABLE idempotency_keys"]) }
}

struct CreateJobs: AsyncMigration {
    let name = "004_jobs"
    func prepare(on db: any Database) async throws {
        try await run(db, [
            """
            CREATE TABLE jobs (id uuid PRIMARY KEY DEFAULT gen_random_uuid(), kind text NOT NULL, payload text NOT NULL DEFAULT '{}',
              state text NOT NULL DEFAULT 'queued', run_at timestamptz NOT NULL DEFAULT now(),
              lease_owner text, lease_until timestamptz, attempts integer NOT NULL DEFAULT 0,
              created_at timestamptz NOT NULL DEFAULT now(), finished_at timestamptz)
            """,
            "CREATE INDEX jobs_due ON jobs (run_at) WHERE state <> 'done'",
            "UPDATE schema_version SET version = 4 WHERE version = 3"])
    }
    func revert(on db: any Database) async throws { try await run(db, ["DROP TABLE jobs"]) }
}

/// WP-D1: Datei-Metadaten und Chunk-Speicher des Datenbank-Backends. Expand-only (neue Tabellen).
struct CreateFiles: AsyncMigration {
    let name = "005_files"
    func prepare(on db: any Database) async throws {
        try await run(db, [
            """
            CREATE TABLE files (id uuid PRIMARY KEY DEFAULT gen_random_uuid(), tenant_id uuid NOT NULL,
              sha256 text NOT NULL CHECK (sha256 ~ '^[0-9a-f]{64}$'), size_bytes bigint NOT NULL CHECK (size_bytes >= 0),
              content_type text NOT NULL DEFAULT 'application/octet-stream', backend text NOT NULL, storage_key text NOT NULL,
              created_at timestamptz NOT NULL DEFAULT now(), UNIQUE (tenant_id, sha256))
            """,
            """
            CREATE TABLE object_chunks (tenant_id uuid NOT NULL, sha256 text NOT NULL, seq integer NOT NULL, data bytea NOT NULL,
              PRIMARY KEY (tenant_id, sha256, seq))
            """,
            "UPDATE schema_version SET version = 5 WHERE version = 4"])
    }
    func revert(on db: any Database) async throws {
        try await run(db, ["DROP TABLE object_chunks", "DROP TABLE files", "UPDATE schema_version SET version = 4 WHERE version = 5"])
    }
}
