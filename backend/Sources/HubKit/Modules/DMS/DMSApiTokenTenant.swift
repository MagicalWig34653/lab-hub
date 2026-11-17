import Vapor
import Fluent
import SQLKit

/// WP-H10b (Expand): API-Token an genau einen Mandanten binden. `tenant_id` ist zunächst nullable (Expand/Contract, alte Instanzen lesen die Tabelle weiter).
/// Backfill: Tokens von Nutzern mit genau einer Mitgliedschaft werden an diesen Mandanten gebunden (eindeutig); bei mehreren Mitgliedschaften bleibt die
/// Bindung leer und das Token wird abgewiesen (401 `api_token_unbound`), bis es neu erstellt wird. NOT NULL folgt als Contract-Schritt in einem späteren WP.
/// `schema_version` bleibt unverändert (wie die übrigen DMS-Modulmigrationen).
struct CreateDMSApiTokenTenant: AsyncMigration {
    let name = "dms_026_api_token_tenant"
    func prepare(on db: any Database) async throws {
        try await run(db, [
            "ALTER TABLE api_tokens ADD COLUMN tenant_id uuid REFERENCES tenants (id)",
            """
            UPDATE api_tokens t SET tenant_id = m.tenant_id
            FROM (SELECT user_id, (array_agg(tenant_id))[1] AS tenant_id FROM memberships GROUP BY user_id HAVING count(*) = 1) m
            WHERE t.user_id = m.user_id AND t.tenant_id IS NULL
            """,
            "CREATE INDEX api_tokens_tenant ON api_tokens (tenant_id) WHERE tenant_id IS NOT NULL"])
    }
    func revert(on db: any Database) async throws {
        try await run(db, ["DROP INDEX IF EXISTS api_tokens_tenant", "ALTER TABLE api_tokens DROP COLUMN IF EXISTS tenant_id"])
    }
}
