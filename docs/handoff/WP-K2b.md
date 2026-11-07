# WP-K2b: Modulrechte in `GET /api/v1/tenants/{tenant}` (Bugfix)

Branch `wp-K2b`. Befund aus `docs/handoff/WP-F4b.md` (Blocker): Die Antwort enthielt nur Kernrechte, die PWA zeigte auf den DMS-Seiten für jede Rolle „Berechtigung fehlt“.

## Änderung
- `backend/Sources/HubKit/Tenancy/TenancyRoutes.swift`: Der Handler ergänzt die Kernrechte um die Rechte aller für den Mandanten **wirksamen** Module (`ModuleService.statuses`, `effective`), gefiltert auf die Rolle (`ModuleRegistry.permissions(of:module:)`; Owner: alle). Deaktivierte Module (Betreiber, Mandant oder fehlendes `requires`) liefern keine Rechte. Keine Migration, kein neuer Zustand (je Aufruf aus der DB).
- Test zuerst: `ModuleTests.testK2b_TenantPermissionsIncludeModulePermissionsOfEffectiveModulesPerRole` (alle fünf Rollen gegen die Rollenmatrix der Testmodule `ping`/`pong`; Modul aus = nur Kernrechte; ping an; pong mit `requires`; wieder aus).
- Vertrag: Schema unverändert (`permissions` war schon als `<modul>.<ressource>.<aktion>` beschrieben), nur die Beschreibung präzisiert; Vertragstest grün.

## Tests (ausgeführt)
- `scripts/ci.sh` mit `TEST_DB_NAME=labhub_k2b`: grün, 232 Tests, 14 übersprungen (Linux-/Container-spezifisch wie zuvor), 0 Fehler.
- Echter E2E ohne lokalen Patch (Debug-Backend mit Scratch-Pfad außerhalb des Repos, `AUTO_MIGRATE=true`, `DB_TLS=disable`, je Lauf frische Datenbank auf 127.0.0.1:15432, danach gelöscht; Worker `App worker --kinds dms.ocr` im Container aus `Dockerfile.worker` mit `--network host`, read-only Root, danach Image entfernt):
  - `npm run test:e2e:dms` (`E2E_PORT=5174`, `E2E_DMS=1`): **1 Test grün (~7 s, echte OCR)**; der F4b-Blocker ist behoben.
  - `npm run test:e2e` (Anmeldung, `E2E_PORT=5173`, ohne `E2E_DMS`): **1 grün, 1 übersprungen** (DMS-Spec ohne `E2E_DMS`). Ein erster Lauf mit gesetztem `E2E_DMS` scheiterte erwartungsgemäß, weil beide Specs dieselbe einmalige Bootstrap-Datenbank brauchen (Bedienfehler, kein Fehler des Codes).
- Nicht geprüft: Mock-E2E/Vitest (nicht Teil des Auftrags).

## Befund außerhalb des Umfangs (DMS, Fremdbesitz)
`docker build -f Dockerfile.worker --target worker` scheitert auf `main` (nach D5) im Release-Build unter Linux: `Modules/DMS/Integrity/ZIPArchive.swift:37`, „unable to type-check this expression in reasonable time“ (Ausdruck für `dosDate`/`dosTime`). Der macOS-Debug-Build ist grün. Für den E2E wurde das Image aus einer temporären Kopie mit aufgeteiltem Ausdruck gebaut (nicht committet). Der DMS-Owner muss den Ausdruck aufteilen.
