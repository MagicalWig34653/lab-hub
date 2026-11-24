# Übergabe WP-H15 (Codex-Befund 9, PWA)

Branch `wp-H15` (auf `main` f644e78).

## Umgesetzt
- `pwa/src/lib/modules-impl/dms/DocumentDetail.svelte`: eigene `formRev`, nur in `fillForm` gesetzt. Das OCR-Polling übernimmt weiter `files`/`status`, aber nicht mehr `rev`. `save()` sendet `formRev` als If-Match. Bei 412 (`precondition_failed`, bestehender i18n-Text `error.precondition_failed`) erscheint die Fehlermeldung plus Knopf `dms-edit-reload` („Aktuellen Stand laden“, verwirft eigene Änderungen und füllt das Formular neu).
- i18n de/en: neuer Schlüssel `dms.edit.reload` (Vollständigkeitstest `messages.test.ts` grün).

## Tests
- `pwa/e2e-mock/dms.spec.ts` AK-H15-1: Fremdänderung während der Verarbeitung, Speichern zeigt Konflikt und überschreibt nichts (Server-Titel bleibt), Neuladen zeigt Fremdstand, danach Speichern gelingt. Rot protokolliert vor dem Fix (`dms-edit-error` nie sichtbar, Überschreiben), grün danach.
- Gate: `npm run check`, `npm test` (104), `test:e2e:mock` (58) grün; `TEST_DB_NAME=labhub_h15 scripts/ci.sh`: erster Lauf rot nur in `ApiPostgresTests.testIdempotencyMiddlewareParallelRunsWorkOnce` (unter Last, 500er); Einzelwiederholung grün, zweiter Gesamtlauf Exit 0 (402 Tests, 14 Skips).

## Offen
- Kein Backend-/Vertragseingriff. Die Fremdänderung während laufender Verarbeitung bleibt im Formular unsichtbar, bis gespeichert wird (bewusst, kein Auto-Merge).

## Nachtrag 24.11.2026 (Karte 8EE48D41)
- Konfliktanzeige (Meldung „Der Datensatz wurde zwischenzeitlich geändert.“ und Knopf „Aktuellen Stand laden“) in hell und dunkel gesichtet: `docs/screenshots/dms-konflikt-light.png`, `docs/screenshots/dms-konflikt-dark.png` (Mock-Backend, synthetische Daten).
- Gegenprobe: Fix in `DocumentDetail.svelte` zurückgenommen, AK-H15-1 rot (`dms-edit-error` nie sichtbar); mit Fix grün. `npm run check`, `npm test` (104), `test:e2e:mock` (58) grün auf 3d0163d. Swift-Suite nicht neu gelaufen (kein Backend-Eingriff).
