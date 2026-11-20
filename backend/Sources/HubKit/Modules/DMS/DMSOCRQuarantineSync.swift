import Vapor
import Fluent
import SQLKit

/// WP-H17 (Codex-Befund 8, Rest): Scheitert ein OCR-Job endgültig (Quarantäne nach Absturzschleife im Kern, Versuche erschöpft oder `permanent`),
/// setzt ein Trigger auf `jobs` den zugehörigen Eingangsvorgang (`dms_ingest_items.job_id`) in derselben Transaktion auf `failed_permanent`.
/// Der Kern kennt keine DMS-Tabellen; das Modul hängt sich über die eigene Migration an (wie die übrigen DMS-Trigger auf Kerntabellen).
///
/// - Wirkt nur für Jobs der Art `dms.ocr` und Items in `ocr_queued` oder `failed_retryable` (Eskalation wie `DMSIngest.fail`); ein vom Handler gesetztes
///   `failed_permanent` (eigener Fehlercode) und erledigte Items bleiben unberührt. `resume_state` wird wie in `DMSIngest.fail` mit dem bisherigen Zustand belegt,
///   damit der manuelle Retry (`DMSOCR.retryPermanent`) unverändert funktioniert.
/// - Fehlercode des Items = `jobs.last_error`, falls er die Spaltenbedingung `^[a-z0-9_.]{1,64}$` erfüllt, sonst `error` (der Jobübergang darf nie an der CHECK-Bedingung scheitern).
/// - Zustandslos (ADR 0003): die Logik steht in der Datenbank, jede Instanz und jeder Pfad (`claim`-Quarantäne, `fail`) lösen sie gleich aus.
/// - Backfill: bereits hängende Items (Job `failed_permanent`, Item `ocr_queued`) werden beim Einspielen berichtigt.
/// `schema_version` bleibt unverändert (wie die übrigen DMS-Modulmigrationen). Revert entfernt Trigger und Funktion.
struct CreateDMSOCRQuarantineSync: AsyncMigration {
    let name = "dms_027_ocr_quarantine_sync"
    func prepare(on db: any Database) async throws {
        try await run(db, [
            """
            CREATE OR REPLACE FUNCTION dms_ocr_job_quarantined() RETURNS trigger LANGUAGE plpgsql AS $$
            BEGIN
              UPDATE dms_ingest_items SET state = 'failed_permanent',
                     error_code = CASE WHEN NEW.last_error ~ '^[a-z0-9_.]{1,64}$' THEN NEW.last_error ELSE 'error' END,
                     resume_state = COALESCE(resume_state, state), updated_at = now()
               WHERE job_id = NEW.id AND state IN ('ocr_queued', 'failed_retryable');
              RETURN NULL;
            END $$
            """,
            "DROP TRIGGER IF EXISTS dms_ocr_job_quarantined ON jobs",
            """
            CREATE TRIGGER dms_ocr_job_quarantined AFTER UPDATE OF state ON jobs FOR EACH ROW
              WHEN (NEW.kind = 'dms.ocr' AND NEW.state = 'failed_permanent' AND OLD.state IS DISTINCT FROM 'failed_permanent')
              EXECUTE FUNCTION dms_ocr_job_quarantined()
            """,
            """
            UPDATE dms_ingest_items i SET state = 'failed_permanent',
                   error_code = CASE WHEN j.last_error ~ '^[a-z0-9_.]{1,64}$' THEN j.last_error ELSE 'error' END,
                   resume_state = COALESCE(i.resume_state, i.state), updated_at = now()
              FROM jobs j WHERE j.id = i.job_id AND j.kind = 'dms.ocr' AND j.state = 'failed_permanent' AND i.state IN ('ocr_queued', 'failed_retryable')
            """])
    }
    func revert(on db: any Database) async throws {
        try await run(db, ["DROP TRIGGER IF EXISTS dms_ocr_job_quarantined ON jobs", "DROP FUNCTION IF EXISTS dms_ocr_job_quarantined()"])
    }
}
