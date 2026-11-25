# Struktur-Abgleich: lab-hub gegen Timetrack/Chronolog

Status: Planung, Stand 25.11.2026. Vergleichsstände (nur gelesen): `timetrack-backend` 9117515, `timetrack-pwa` bc0e305, `timetrack-apple` ba7e0b2, lab-hub 2938d2c.

**Vorgabe (Nutzer, 25.11.2026):** Timetrack ist eine **Idee für die Struktur** (Module, Aufbau der PWA), kein Muster zum 1:1-Übernehmen. Aus den Vorbild-Repos wird kein Code kopiert; übernommen wird nur, was lab-hub konkret hilft. Die DMS-App folgt ausdrücklich **nicht** dem Vorbild Chronolog (eigenes Konzept in `APP-DMS.md`).

## 1. Ergebnis in Kürze

- Das Modulsystem von lab-hub ist **weiter** als das von Timetrack (Protokoll mit Abhängigkeiten, Rechten, Migrationen, Mandanten). Ein Umbau „auf Timetrack“ wäre ein Rückschritt.
- Die Lücken liegen woanders: Der Kern hängt am DMS-Modul, die beschlossene Target-Aufteilung (F-14) fehlt, es gibt **keine GitHub-CI**, die PWA ist nicht installierbar und **schaltet nie in den Dunkelmodus**.
- Für Apps gibt es noch kein Repository und keine Geräteanmeldung im Backend.

## 2. Backend

| Thema | timetrack-backend | lab-hub | Bewertung / WP |
| --- | --- | --- | --- |
| Targets | `TimetrackKit` + `App` | `HubKit` + `App` | gleich grob; lab-hub hat Entscheidung F-14 (07.11.2026: Targets **spätestens vor dem zweiten Modul**). Rechnung ist als zweites Modul da, die Aufteilung nicht → **ST3** |
| Moduldefinition | `enum ModuleKey` (reine Schalter) | `protocol HubModule` (`requires`, `enhances`, Rechte, Migrationen, Navigation, Routen, `onActivate`) + `InstalledModules` | lab-hub behalten |
| Modul-Registry | ungecacht, Server + Konto, Sperre per `MODULES_DISABLED` | geprüft (Schlüssel, Zyklen), Betreiber + Mandant, ungecacht in der DB | Abweichung gewollt (Mandanten statt Konten); Env-Sperre nicht nötig |
| Guard | Pfad-Middleware mit zentraler Zuordnungstabelle | Guard je Route (`ModuleRoutes.on`), Rechte deklariert | lab-hub behalten |
| Job-Handler | kein Modulbezug | `Worker/WorkerCommand.swift` verdrahtet alle `dms.*`-Handler fest; ADR 0004 sieht Job-Handler im Protokoll vor | **ST2** |
| Kern → Modul | – | `Auth/ApiTokens.swift` wirft `DMSError` und kennt nur den Scope `dms.upload`; `Contacts/LinkService.swift` ruft `DMSSources.dmsActive` und `DMSError` auf | verletzt ADR 0004 Punkt 4, blockiert ST3 und neue Scopes (Scan-Bridge, App) → **ST2** |
| Ordnung im Modul | Ordner je Fachgebiet | `Modules/DMS/{Import,Sources,OCR,…}`, `Modules/Invoice` | passt; größte Datei 543 Zeilen, kein Umbau |
| Vertrag | `contracts/openapi.yaml` | `contracts/openapi.yaml` + Vertragstest | gleich |
| CI | 7 Workflows (`ci`, `codeql`, `dependency-review`, `docker`, `release`, `deploy-branch`, `pages`) | **keine** `.github/workflows`; nur `scripts/ci.sh` lokal | **ST1** (nur Prüfungen; Image-Push und Release nicht Teil) |
| Betrieb | `deploy/compose`, `deploy/swarm`, Skripte | ebenso | gleich; offen H4 |

## 3. PWA

| Thema | timetrack-pwa | lab-hub `pwa/` | Bewertung / WP |
| --- | --- | --- | --- |
| Stack | SvelteKit, shadcn-svelte, adapter-static, Vitest, Playwright | ebenso | gleich |
| Fachcode | `lib/<fachgebiet>` + `components/<fachgebiet>` | `lib/modules-impl/dms` (Komponenten und Logik zusammen) | lab-hub-Weg behalten: ein Ordner je Modul; Rechnung (F6) als `modules-impl/invoice` mit eigenem Manifest |
| Module | `lib/modules/map.ts` (Routen-Zuordnung), `store.svelte.ts` | `manifest.ts`, `registry.ts`, `resolve.ts`, `routes.ts`, `sidebar.ts` | lab-hub weiter |
| Darstellung | `lib/theme` (System/Hell/Dunkel, Akzent), Seite „Darstellung“ | `.dark`-Farben in `routes/layout.css`, aber **kein Code setzt die Klasse `dark`** und `prefers-color-scheme` wird nicht ausgewertet | Nutzer sehen immer Hell → **ST4** (hoch) |
| Installierbar/offline | `service-worker.ts`, `lib/pwa/*`, `manifest.webmanifest`, `offline.html`, Icons, eigener Playwright-PWA-Lauf | nichts davon (`static/` enthält nur `licenses.json`) | vorhandenes **WP-F3** (offen), nicht neu angelegt |
| Fehler und API-Stand | `lib/errors/describe`, `lib/api/api-version`, `capabilities` | `lib/api/{client,errors,types}` | **ST5**: Versions-/Fähigkeitsprüfung (wichtig, sobald Apps und Bridge mitreden) |
| Betreiberseiten | `routes/(app)/admin/*` (u. a. Module) | `settings/modules` schaltet nur je Mandant; Betreiberschalter nur per API | **ST5** |
| E2E | `e2e`, `e2e-mock`, `e2e-pwa` | `e2e`, `e2e-mock`, Stack-Läufe | PWA-Lauf kommt mit F3 |
| Sprachen | de, in Dateien je Gebiet | de/en, Kern + Modultexte | lab-hub behalten |

## 4. Apple-App

| Thema | timetrack-apple (nur Strukturidee) | Folgerung für die DMS-App |
| --- | --- | --- |
| Projekt | XcodeGen (`project.yml`), mehrere Targets | Projekt und Bundle-ID legt der Nutzer in Xcode an; ob danach XcodeGen genutzt wird, entscheidet APP-M0 |
| Pakete | `TimetrackCore` (Modelle, Netz, Auth, Sync), `TimetrackStores`, `TimetrackDesign` | Trennung Kern / Speicher / Oberfläche übernehmen als Idee; Schnitt in `APP-DMS.md` Abschnitt 7 |
| Quellen | Ordner je Funktion, plattformübergreifend geteilt | übernehmen als Idee |
| Plattformen | iOS, macOS, watchOS, Widgets | eigenes Bild (inkl. visionOS-Prüfung), siehe `APP-DMS.md` |
| Backend | eigene Auth-Pfade | lab-hub fehlt eine **Geräteanmeldung** (Sitzungen akzeptieren zwar `Authorization: Bearer`, aber es gibt keinen Weg, wie eine App an ein Token kommt) → **AB1** |

## 5. Bewusst nicht übernommen

- Modulschalter als reines `enum` mit Pfadtabelle (weniger als `HubModule`).
- Konto-weise Modulschalter (lab-hub arbeitet je Mandant).
- MariaDB/SQLite (ADR 0001: PostgreSQL), MCP, OIDC, Push: kein Strukturthema; bei Bedarf eigene WPs.
- Release-, Deploy- und TestFlight-Workflows: Veröffentlichungen bleiben beim Nutzer.

## 6. Umbau-WPs und Reihenfolge

`ST1 → ST2 → ST3`, parallel dazu `ST4 → ST5` (anderer Dateibesitz). Begründung: Erst CI als Sicherheitsnetz, dann entkoppeln, dann Targets schneiden. ST2 ist Voraussetzung für die neuen Token-Scopes in `SCAN-BRIDGE.md` (BR1) und `APP-DMS.md` (AB1). Akzeptanzkriterien in `ROADMAP.md`, Phase 7.
