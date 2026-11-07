import Vapor
import Fluent
import SQLKit

/// WP-K3: Modulschalter. Expand-only (neue Tabellen).
/// `installation_modules`: Betreiberebene; keine Zeile = installiert und an. `tenant_modules`: Mandantenebene; keine Zeile = aus.
/// Wirksam = Installation an UND Mandant an UND alle `requires` wirksam. Kein Cache, jede Anfrage liest frisch.
struct CreateModules: AsyncMigration {
    let name = "014_modules"
    func prepare(on db: any Database) async throws {
        try await run(db, [
            """
            CREATE TABLE installation_modules (module_key text PRIMARY KEY CHECK (module_key ~ '^[a-z][a-z0-9]{0,31}$'),
              enabled boolean NOT NULL, updated_by uuid REFERENCES users (id), updated_at timestamptz NOT NULL DEFAULT now())
            """,
            """
            CREATE TABLE tenant_modules (tenant_id uuid NOT NULL REFERENCES tenants (id),
              module_key text NOT NULL CHECK (module_key ~ '^[a-z][a-z0-9]{0,31}$'),
              enabled boolean NOT NULL, updated_by uuid REFERENCES users (id), updated_at timestamptz NOT NULL DEFAULT now(),
              PRIMARY KEY (tenant_id, module_key))
            """,
            "UPDATE schema_version SET version = 14 WHERE version = 13"])
    }
    func revert(on db: any Database) async throws {
        try await run(db, ["DROP TABLE tenant_modules", "DROP TABLE installation_modules", "UPDATE schema_version SET version = 13 WHERE version = 14"])
    }
}
