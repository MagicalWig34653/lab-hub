# Übergabe WP-F4b (PWA an Backend-Stand, echter E2E mit OCR-Worker)

Stand 07.11.2026, Branch `wp-F4b` auf `main` 306a73a (enthält F4, O2, S1, H6). Alles unter `pwa/` plus Doku. Kein Backend-, Vertrags-, Dockerfile- oder Deploy-Änderung.

## Umgesetzt
- **Vertragstypen** (`src/lib/api/types.ts`) mit `npm run gen:api` neu erzeugt (Verarbeitungsstatus, Retry, `search` mit optionalem `q`, Fehlercodes).
- **Durchsuchen:** `GET …/dms/search` auch ohne Suchbegriff (`snippet` null); Datumsfilter, Facetten und mehrere Tags sind ohne Suchbegriff wieder aktiv. Nur der Papierkorb nutzt `GET …/documents?trashed=true` (Suche schließt ihn aus).
- **Verarbeitungsstatus:** `ingest_state`/`ingest_error_code`-Mockfelder entfernt. Upload-Warteschlange pollt `GET …/documents/{id}/processing` (nur wenn die Upload-Antwort `ingest_item_id` hat) bis `phase` done/none/failed; `failed` = Quarantäne mit `error_code`; Aktion „Verarbeitung erneut starten“ = `POST …/processing/retry` (Upload-Panel und Detailseite, Recht `dms.document.update`). Detailseite zeigt die Phase, lädt nach `done` die Dateien neu (Archivversion für die Vorschau). Liste markiert kürzlich eingegangene, nicht archivierte Zeilen (Verarbeitung/Quarantäne, höchstens 3 parallele Abfragen).
- **Fehlercodes:** `storage_quota_exceeded` (413) hat eigenen Zustand `quota` und Text, unterscheidet sich von `payload_too_large`; `upload_interrupted` (409) wird bis zu 3 Mal automatisch mit demselben Idempotency-Key wiederholt. `error.ingest_not_failed|storage_quota_exceeded|upload_interrupted` de/en, neue Schlüssel `dms.processing.*`, `dms.upload.error.quota`, `dms.filter.trashLimited` (entfernt: `dms.filter.dateNeedsSearch`, `dms.filter.oneTagInList`).
- **Mock** (`pwa/mock/dms.ts`) bildet `…/processing`, `…/processing/retry`, leere Suche, Quota, Unterbrechung nach (Dateiinhalts-Marker).
- **Echter E2E** `pwa/e2e/dms.spec.ts` + `e2e/scan-pdf.ts` (Scan-PDF ohne Textschicht, im Browser gezeichnet), Befehl `npm run test:e2e:dms`. In `docs/FRONTEND.md` Abschnitt 8/11 und `AGENTS.md` Abschnitt 3 eingetragen.
- Backend-Auslieferung der PWA nicht umgesetzt; nur geprüft, dass `npm run build` läuft.

## Tests (ausgeführt)
- Mock: `npm ci`, `npm run check`, `npm test` (Vitest 65 Tests, 10 Dateien), `npm run build`, `npm run test:e2e:mock` (28 Tests, darunter neu: Durchsuchen ohne Suchbegriff mit Datum/Facetten/mehreren Tags, Verarbeitungsstatus, Quarantäne-Wiederholung, Quota, Unterbrechung; axe serious/critical = 0 in den bestehenden und neuen Prüfungen). Bestehende Tests nur angepasst (Upload-Test auf `fetchProcessing`), nicht abgeschwächt.
- Echt: eigene Datenbank `labhub_f4b` (angelegt, danach gelöscht), Backend als Debug-Build (`swift build --scratch-path` außerhalb des Repos, `App serve`, `AUTO_MIGRATE=true`), `App worker --kinds dms.ocr` im Container aus `Dockerfile.worker` (Stufe `worker`, ocrmypdf/Tesseract fehlen auf dem Host; read-only Root, tmpfs, `--network host`), Vite-Proxy auf Port 5174. `npm run test:e2e:dms`: **grün (1 Test, ~7 s, echte OCR)**, aber **nur mit einem lokalen, nicht committeten Backend-Patch** (siehe Blocker; Patch danach per `git checkout` verworfen). Ohne Patch scheitert derselbe Test am Blocker. Nicht ausgeführt: `npm run test:e2e` (Anmeldung) in diesem Lauf; Quarantäne/Quota/Unterbrechung gegen das echte Backend; Backend-Tests.

## Blocker / Befund (Backend, Fremdbesitz)
**`GET /api/v1/tenants/{tenant}` liefert nur Kernberechtigungen.** `TenancyRoutes.swift` gibt `c.permissions` zurück, das der `TenantGuard` aus `Permissions.of(role)` füllt; die Modulberechtigungen (`dms.document.*`) kommen nur bei Modulrouten über den `ModuleGuard` dazu. Der Vertrag beschreibt `permissions` als `<modul>.<ressource>.<aktion>`. Folge gegen das echte Backend: `workspace.can('dms.document.read')` ist für jede Rolle (auch Inhaber) falsch, die DMS-Seite zeigt „Für die Dokumente fehlt die Berechtigung“. Der Mock enthält die `dms.*`-Rechte, deshalb fiel das bisher nicht auf. Vorschlag (Backend-WP): im Handler die Berechtigungen aller wirksamen Module hinzufügen (`ModuleService.statuses` + `registry.permissions(of:module:)` für `effective`), plus Test. Mit genau diesem Patch lief der E2E grün.

## Offen
- Backend-Fix oben, danach `npm run test:e2e:dms` ohne Patch wiederholen.
- Quarantäne-Wiederholung gegen das echte Backend ungeprüft (nur Mock); `pdf_encrypted` als Auslöser wäre möglich.
- Fehlertexte für `error_code`-Werte (z. B. `pdf_encrypted`) sind roh; Übersetzung offen.
- Listenmarker fragt `…/processing` je Zeile (höchstens 25 Aufrufe je Seite); ein Feld in der Trefferliste wäre besser.
- Polling ohne Ereignisse (K7). Bootstrap des echten E2E ist einmalig: je Lauf frische Datenbank.
- Backend-Auslieferung der PWA (WP-F1-Vorschlag: Dockerfile-Stufe + Static-Middleware mit Deep-Link-Fallback) offen.
