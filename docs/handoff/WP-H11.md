# WP-H11: hohe Befunde aus dem Codex-Review (17.11.2026)

Quelle: `docs/handoff/REVIEW-codex-2026-11-17.md`, Befunde 1 bis 3. Branch `wp-H11`, nicht gemergt.

## Umsetzung
- **AK-H11-1** `PL.int` (`PaperlessModel.swift`): `Int64(exactly:)` statt `Int64(d)`. `inf`, NaN, Bruchteile und Werte außerhalb von Int64 liefern `nil` (Quelldaten ungültig, wie bisher bei nicht lesbaren Feldern). Test `H11ParsingTests`.
- **AK-H11-2** Export-ZIP und OCR-Archivdatei laufen über `DMSUpload.registerWithinQuota` (neue Datei `Modules/DMS/ExportQuota.swift`): Blob-Sperre, Quota-Sperre, dann `files`-Zeile, in derselben Transaktion wie das Ergebnis (gleiche Reihenfolge wie `DMSDocuments.create`). Bytes, die der Mandant schon hat, zählen nicht doppelt. Die Handler nehmen `quotaBytes` (Standard `DMS_TENANT_QUOTA_BYTES` über `DMSSourceLimits`), `WorkerCommand` bleibt unverändert.
  Bei Überschreitung: Blob wird verworfen, falls nichts auf ihn zeigt; Export `failed` mit `error_code = storage_quota_exceeded`, Job `failed_permanent`; OCR-Item `failed_permanent` mit `storage_quota_exceeded` (wiederholbar über `retryPermanent`, sobald Platz ist). Tests `H11ExportQuotaTests`, `H11OCRQuotaTests`.
- **AK-H11-3** `FilesystemObjectStore.get`: Deskriptor gehört einer Klasse (`DescriptorHandle`) mit idempotentem `close()` und `deinit`; Lesefehler und EOF schließen sofort, ein verworfener Strom (Abbruch, Cancel) schließt über `deinit`. Tests `H11FilesystemFDTests` (zählen `/dev/fd`).

## Entscheidung / offene Punkte
- OCR bei Quota-Überschreitung: Auftrag scheitert endgültig mit klarem Code (Vorgabe), statt die Archivdatei still wegzulassen. Alternative (Text indizieren, Archiv weglassen) wäre möglich; Entscheidung beim Nutzer.
- Neuer Problem-Code wurde nicht eingeführt: `storage_quota_exceeded` existiert bereits (Upload); als Job-Fehlercode in `dms_exports.error_code` und `dms_ingest_items.error_code`. Falls i18n/openapi die Codeliste der Jobfehler führt, ist das bei H10b nachzuziehen (nicht angefasst).
- Auch die Fehlerpfade des Export-ZIP-Lesers (`fileStream` in DMSExport/DMSOCR schließen den FileHandle nur bei EOF) wurden nicht geändert; gleiches Muster, geringeres Risiko (kurzlebiger Job), nicht Teil der Befunde.

## Tests
`scripts/ci.sh` mit TEST_DB_NAME=labhub_h11: 384 Swift-Tests, 14 übersprungen, 0 Fehler (Exit 0). Die 5 H11-Tests (AK-H11-1 bis 3) wurden vor dem Fix geschrieben; ein separat protokollierter roter Lauf liegt nicht vor (Postgres war zeitweise nicht erreichbar). Im Quota-Test erscheint eine Warnung "quota cleanup failed" (ConnectionPoolTimeout): das Aufräumen des Blobs ist best effort, ein verbliebener Blob ist nur Speicherverbrauch.
