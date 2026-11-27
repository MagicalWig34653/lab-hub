import Vapor
import Fluent
import SQLKit
import HubCore

// WP-BR1 (docs/SCAN-BRIDGE.md Abschnitt 3): Tabellen der Scan-Bridge. Expand-only, `schema_version` unverändert (Modulstände stehen in `_fluent_migrations`).
// - `dms_scan_bridges`: eine Bridge je API-Token (Token-ID eindeutig), Lebenszeichen aus der Datenbankzeit.
// - `dms_scan_devices`: Gerät je Bridge; `device_key` ist ein Hash (SHA-256 hex), nie eine IP oder URL. Entfernte Geräte bleiben (`active = false`), damit alte Aufträge gültig bleiben.
// - `dms_scan_jobs`: Zustand, Lease (`lease_until`, Datenbankzeit), Befehl des Nutzers, Ergebnis. Höchstens ein offener Auftrag je Gerät (Teilindex), nicht nur Prüfung in der Route.
struct CreateDMSScanBridge: AsyncMigration {
    let name = "dms_028_scan_bridge"
    func prepare(on db: any Database) async throws {
        try await run(db, [
            """
            CREATE TABLE dms_scan_bridges (id uuid PRIMARY KEY DEFAULT gen_random_uuid(), tenant_id uuid NOT NULL,
              token_id uuid NOT NULL UNIQUE REFERENCES api_tokens (id),
              name text NOT NULL CHECK (char_length(name) BETWEEN 1 AND 100), version text NOT NULL CHECK (char_length(version) BETWEEN 1 AND 40),
              last_seen_at timestamptz NOT NULL DEFAULT now(), created_at timestamptz NOT NULL DEFAULT now(), UNIQUE (tenant_id, id))
            """,
            """
            CREATE TABLE dms_scan_devices (id uuid PRIMARY KEY DEFAULT gen_random_uuid(), tenant_id uuid NOT NULL, bridge_id uuid NOT NULL,
              device_key text NOT NULL CHECK (device_key ~ '^[0-9a-f]{64}$'),
              name text NOT NULL CHECK (char_length(name) BETWEEN 1 AND 100), capabilities jsonb NOT NULL,
              active boolean NOT NULL DEFAULT true, seen_at timestamptz NOT NULL DEFAULT now(),
              UNIQUE (tenant_id, id), UNIQUE (bridge_id, device_key), FOREIGN KEY (tenant_id, bridge_id) REFERENCES dms_scan_bridges (tenant_id, id))
            """,
            """
            CREATE TABLE dms_scan_jobs (id uuid PRIMARY KEY DEFAULT gen_random_uuid(), tenant_id uuid NOT NULL, device_id uuid NOT NULL, params jsonb NOT NULL,
              state text NOT NULL DEFAULT 'queued' CHECK (state IN ('queued', 'claimed', 'scanning', 'waiting_for_page', 'uploading', 'done', 'failed', 'cancelled')),
              command text CHECK (command IN ('next_page', 'finish', 'cancel')),
              lease_until timestamptz, pages integer NOT NULL DEFAULT 0 CHECK (pages BETWEEN 0 AND 500), document_id uuid,
              error_code text CHECK (error_code ~ '^[a-z0-9_]{1,64}$'),
              created_by uuid NOT NULL REFERENCES users (id), created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now(),
              claimed_at timestamptz, finished_at timestamptz,
              FOREIGN KEY (tenant_id, device_id) REFERENCES dms_scan_devices (tenant_id, id),
              CHECK ((state IN ('claimed', 'scanning', 'waiting_for_page', 'uploading')) = (lease_until IS NOT NULL)))
            """,
            "CREATE UNIQUE INDEX dms_scan_jobs_open_device ON dms_scan_jobs (device_id) WHERE state IN ('queued', 'claimed', 'scanning', 'waiting_for_page', 'uploading')",
            "CREATE INDEX dms_scan_jobs_queue ON dms_scan_jobs (tenant_id, created_at, id) WHERE state = 'queued'",
            "CREATE INDEX dms_scan_jobs_leases ON dms_scan_jobs (tenant_id, lease_until) WHERE lease_until IS NOT NULL"])
    }
    func revert(on db: any Database) async throws {
        try await run(db, ["DROP TABLE dms_scan_jobs", "DROP TABLE dms_scan_devices", "DROP TABLE dms_scan_bridges"])
    }
}
