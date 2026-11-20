# WP-H17: OCR-Job endgültig gescheitert, Ingest-Eintrag bleibt `ocr_queued`, Retry 409

Stand 20.11.2026, Branch `wp-H17-ocr-quarantine`, Projektkarte 812FAC63 (Codex-Befund 8, Rest nach H14).

## Ursache

`JobService.claim` setzt einen Job nach `maxAttempts` abgelaufenen Leases (Absturzschleife) auf `failed_permanent` (`last_error = lease_expired`), ohne dass ein Handler läuft. Der Kern kennt keine DMS-Tabellen, der Ingest-Eintrag (`dms_ingest_items`) blieb `ocr_queued`: Die Übersicht zählte das Dokument als `queued` statt `failed`, kein Banner, der Retry-Pfad wurde nur durch die H14-Toleranz erreicht. Dasselbe galt für jeden anderen Weg, der den Job endgültig scheitern lässt, ohne `DMSIngest.fail` zu durchlaufen.

## Änderung

- Migration `dms_027_ocr_quarantine_sync` (`DMSOCRQuarantineSync.swift`): Trigger `AFTER UPDATE OF state ON jobs`, nur `kind = 'dms.ocr'` und Übergang nach `failed_permanent`. Er setzt Items in `ocr_queued`/`failed_retryable` in derselben Transaktion auf `failed_permanent`, `error_code` = `last_error` (nur wenn er `^[a-z0-9_.]{1,64}$` erfüllt, sonst `error`), `resume_state` wie `DMSIngest.fail`. Eigene Fehlercodes des Handlers (`failed_permanent` mit Code) und erledigte Items bleiben unberührt. Backfill für bereits hängende Items. `CREATE OR REPLACE FUNCTION`, Revert entfernt Trigger und Funktion. Zustandslos (ADR 0003): jede Instanz und jeder Pfad löst es gleich aus. `schema_version` unverändert.
- Retry (`DMSOCR.retryPermanent`, H14) unverändert: bleibt einmalig, ein zweiter Aufruf ergibt 409 `ingest_not_failed`.

## Nachweise

- `DMSH17Tests` (5): AK-H17-1 Absturzschleife → Item `failed_permanent/lease_expired/ocr_queued`, Phase `failed`, Zähler `queued`→`failed`, Retry einmal, Worker schließt ab; AK-H17-2 Versuche erschöpft/`permanent` mit unzulässigem Code → `error`; AK-H17-3 keine Überschreibung fremder Codes, andere Job-Arten ignoriert; AK-H17-4 zwei Instanzen, Retry `[200, 409]`; AK-H17-5 Backfill und Revert. Zeit kontrolliert über `lease_until` in der Datenbank. Rot belegt per Gegenprobe (Migration ohne Trigger: 17 Fehlschläge).
- E2E `scripts/e2e-dms-ocr-failure.sh` (`pwa/e2e/dms-ocr-failure.spec.ts`): echtes `App serve`, echte Postgres-Datenbank, echter `App worker`-Prozess, Chromium headless, keine Mocks. (A) beschädigtes PDF → `input_invalid` → Banner → Retry → erneut Banner. (B) Lease abgelaufen, Worker holt → Quarantäne → Banner `lease_expired`, Zähler `failed`=2/`queued`=0 → Retry → Worker schließt ab → Banner weg, zweiter Retry 409, Zähler `failed`=1. Gegenprobe (`E2E_PRE_SQL='DROP TRIGGER dms_ocr_job_quarantined ON jobs'`): rot bei (B).
- Gate `scripts/ci.sh` mit echter Datenbank (siehe Projektkarte).

## Grenzen

- Auf dem Host fehlen `ocrmypdf`/`tesseract`/`gs`. Der Worker prüft sie beim Start nur per `--version`; das E2E-Skript setzt dafür Preflight-Attrappen ans PATH-Ende (nur wenn das Werkzeug fehlt; Aufruf sonst Exit 99). Beide Szenarien benutzen die Werkzeuge nicht (Textschicht → `pdftotext`, beschädigte Datei scheitert an `pdfinfo`). Echte Scan-OCR bleibt bei `scripts/ocr-container-test.sh` und `npm run test:e2e:dms` mit Worker-Image.
- Das E2E ist kein Teil von `scripts/ci.sh` (braucht Chromium, Binary und Container); Aufruf von Hand.
