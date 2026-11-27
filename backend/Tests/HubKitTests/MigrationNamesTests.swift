import Fluent
import XCTest
@testable import HubKit

/// WP-ST3: Die in `_fluent_migrations` gespeicherten Namen und ihre Reihenfolge sind Teil jeder Bestandsdatenbank. Ein Umbau (z. B. Typ in ein anderes
/// Target) darf sie nicht verändern, sonst laufen Migrationen erneut. Neue Migrationen werden hier am Ende ihres Blocks ergänzt. Keine Datenbank nötig.
final class MigrationNamesTests: XCTestCase {
    func testAKST3_3_storedMigrationNamesAndOrderAreUnchanged() {
        let names = (HubMigrations.all + InstalledModules.all.flatMap(\.migrations)).map(\.name)
        XCTAssertEqual(names, [
            "001_schema_version", "002_counters", "003_idempotency_keys", "004_jobs", "005_files", "006_users", "007_passkey_credentials",
            "008_sessions", "009_invitations", "010_recovery_codes", "011_audit_log", "012_auth_support", "013_tenants", "014_modules",
            "015_contacts", "017_jobs_priority", "018_audit_hardening", "019_audit_trigger_privilege", "020_api_tokens",
            "dms_026_api_token_tenant", "021_idempotency_lease", "022_user_accent",
            "dms_016_core", "dms_017_ingest", "dms_018_search", "dms_019_ocr", "dms_020_rules", "dms_021_revision", "dms_022_sources",
            "dms_023_import", "dms_024_extraction", "dms_025_document_source", "dms_027_ocr_quarantine_sync",
            "invoice_027_master", "invoice_028_documents", "invoice_029_payments"
        ])
    }
}
