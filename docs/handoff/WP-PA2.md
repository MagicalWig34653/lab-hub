# Übergabe WP-PA2 (Paperless-Import in der PWA)

Stand 28.11.2026, auf `main` (Ausgangsstand e44d11c). Nur lokale Wegwerf-Container mit **erfundenen** Daten; keine Verbindung zu einer echten Paperless-Instanz, kein Deploy. Backend, Datenbank und OpenAPI-Vertrag sind **unverändert**: die Routen für Anlegen, Liste, Status, Bericht, Abbruch und Notizen gab es seit WP-D6/PA1.

## Was neu ist
- Seite **docs → Verwaltung → Import** (`/dms/imports`, sichtbar mit `dms.import.read`; Formular und Abbruch nur mit `dms.import.manage`): Quelle (REST-API oder Export-Verzeichnis), Adresse, Token, Art (Trockenlauf vorausgewählt oder Import mit Schalter für die Texterkennung), Läufe mit Fortschritt und Abbruch, Bericht (Anzahlen, Befunde mit Einträgen, Archivnummern, Rechte und Sichtbarkeit, Regelvorschläge, JSON-Datei). Alle Lauf-, Feld- und Befundcodes haben deutsche und englische Texte; unbekannte Codes erscheinen roh.
- **Notizen** am Dokument (`NotesPanel.svelte`): reiner Text, Datum, Herkunft „aus Paperless“; ohne Notizen kein Abschnitt.
- **Prüfseite**: zeigt `report.orphans` (Aufräumlauf aus WP-D5b; Karte 39B9543B).

## Umgang mit dem Token
- Passwortfeld ohne `name`, `autocomplete="off"`, Hinweise für Passwortmanager; wird beim Absenden **immer** geleert (auch wenn der Hub die Anfrage ablehnt), ebenso beim Wechsel der Quelle und beim Verlassen der Seite.
- Nirgends in `localStorage`, `sessionStorage`, Cookies, IndexedDB, Cache, URL, DOM oder Konsole; es steht nur in der einen Anfrage, die den Lauf anlegt (Test prüft alle Anfragen).
- Backend wie PA1: verschlüsselt nur während des Laufs, danach gelöscht; nie in Antworten, Logs oder Audit.
- **Grenze:** Ob ein Browser oder Passwortmanager trotz dieser Hinweise anbietet, den Wert zu speichern, liegt beim Browser und ist nicht automatisch prüfbar (Hinweis in der PA3-Anleitung: ablehnen). Das Anbieten wurde nicht in Safari oder Firefox ausprobiert.

## Akzeptanzkriterien
| AK | Beleg |
| --- | --- |
| PA2-1 Quelle, Trockenlauf, Fortschritt, Abbruch, Bericht, Token | `pwa/src/lib/modules-impl/dms/import.test.ts`; `pwa/e2e-mock/dms-import.spec.ts` (Quelle, Fortschritt, Abbruch, Export, abgelehnte und doppelte Anfragen, fehlgeschlagener Lauf, Rechte, Token); `pwa/e2e/dms-import.spec.ts` gegen echtes Backend |
| PA2-2 Notizen am Dokument | Mock: Text statt Markup, Herkunft, Datum, ohne Notizen kein Abschnitt; echt: Notiz aus der Instanz am importierten Dokument |
| PA2-3 E2E gegen echtes Backend, hell/dunkel | `scripts/e2e-paperless-pwa.sh`; Bilder `docs/screenshots/pa2/` (Computer und Handy, hell und dunkel) |

## Rot, dann grün
1. Vor der Umsetzung: `import.test.ts` rot (Modul `./import` fehlt); `e2e-mock/dms-import.spec.ts` **6 von 6 rot**.
2. Echter E2E gegen den alten Stand e44d11c (eigener Worktree, danach entfernt): rot, es gibt keinen Menüpunkt `dms-nav-imports`.
3. Beim Prüfen gefunden, je erst rot, dann behoben:
   - Eine verspätet eintreffende Antwort der Läufeliste leerte die Liste, nachdem nichts mehr nachfragte (`a late answer of the run list …`: erwartet 1 Lauf, erhalten 0).
   - Abgebrochene und fehlgeschlagene Berichte zeigten „Höchste Nummer 0“ und „0 Besitzer“; diese Werte zählt das Backend erst am Ende eines Laufs (`import-asn`: erwartet 0, erhalten 1). Jetzt nur bei fertigen Läufen; ein Lauf ohne Zahlen zeigt nur seinen Grund.
4. Drei Läufe des echten E2E waren wegen **falscher Erwartungen im Test** rot (unbekannter Host wird ohne Allowlist erst vom Worker abgelehnt; UUIDs des echten Backends sind groß; ein Schritt prüfte die Zeile des vorigen Laufs). Der Test wartet jetzt auf die Zeile des neuen Laufs.

## Echter E2E (`scripts/e2e-paperless-pwa.sh`)
Eigene Container (Postgres 17, Redis, paperless-ngx 3.5.1, Name `labhub-pa2-e2e-<pid>`), 10 erfundene Dokumente aus `scripts/paperless-e2e/seed.py`, `App serve` und `App worker --kinds dms.import.paperless`, Weiterleitung mit 0,6 s Verzögerung je Anfrage (`slowproxy.py`, neues viertes Argument; Verhalten ohne Argument unverändert). Ablauf: Trockenlauf mit Fortschritt (schreibt nichts) → Import mit Abbruch → neuer Lauf gegen dieselbe Quelle übernimmt genau den Rest → Export-Verzeichnis (`document_exporter`) → falsches Token → abgelehnte Adresse → Token nirgends im Browser → Notiz am Dokument. Danach: 0 Treffer des Tokens in `pg_dump` und Logs, kein Lauf behielt ein Token.

## Offen
- Der echte E2E läuft nicht in der CI (Paperless-Image, wie PA1); die CI deckt die Mock-Tests ab.
- Gegen den Hub mit **Schalter für interne Ziele und Allowlist** lief die Seite nicht (das Skript nutzt den Entwicklungsschalter); die Richtlinie selbst prüft `scripts/e2e-paperless-import.sh` (PA1/PA3V).
- Die Vorschau bleibt in den Bildern des Dokuments leer (Chromium ohne Oberfläche zeigt PDF im Rahmen nicht).
- Die Detailangabe mancher Befunde ist die rohe des Backends (z. B. „Dokument 7 – 1“ = eine ältere Fassung).
- Nächster Schritt: PA7 (Teil 1, Zielrechner), dann **PA3 durch den Nutzer** (`docs/ANLEITUNG-PA3-PAPERLESS-PROBELAUF.md`).

## Gegenlesen (`docs/AGENT-WORKFLOW.md`, frischer Agent, nur lesend)
Urteil „fail“ mit 5 Befunden, alle am Code bestätigt und behoben; kein Weg gefunden, auf dem das Token bleibt, angezeigt oder protokolliert wird, kein XSS, keine privaten Daten im Diff.
1. Fehlgeschlagener **Import**-Lauf zeigte „importiert: 0“ (das Backend setzt `documents_imported` auch dann): rot (`reportHasData`, Mock-E2E `import-counts` erwartet 0, erhalten 1), behoben; der echte E2E prüft den Fehlschlag jetzt als Import. Der Mock verhält sich wie das Backend.
2. Bilder und Testzahlen fehlten noch in der Übergabe: nachgetragen.
3. Zusammengesetzte Verweise (`document:7/type:3`, `tag:1-2`) wurden falsch benannt: rot (`refParts`), behoben.
4. Verlorene Dokumente, Werte und Verweise (`duplicate_hash_imported`, `reference_*`, `custom_field_value_dropped`, gekürzte Texte) galten als bloßer Hinweis: rot, behoben (stehen jetzt oben als „Nicht vollständig übernommen“).
5. Die Prüfung „Token nicht in der Datenbank“ im neuen Skript hätte bei gescheitertem `pg_dump` bestanden: Auszug wird jetzt geprüft und enthält als Gegenprobe `dms_imports`. **Offen:** `scripts/e2e-paperless-import.sh` (PA1) hat dasselbe Muster, hier nicht geändert.

## Ausgeführt (28.11.2026, macOS, auf dem committeten Stand)
- `npm run check`: 1034 Dateien, 0 Fehler, 0 Warnungen; `npm test`: 128 Tests grün; `npm run test:e2e:mock`: 81 grün, 4 übersprungen (reine Bildläufe ohne `SCREENSHOT_DIR`).
- `scripts/e2e-paperless-pwa.sh`: 1 Test grün (alle Schritte oben), 0 Token-Treffer, 5 Läufe, keiner mit gespeichertem Token.
- `scripts/ci.sh` gegen eine eigene Wegwerf-Postgres: shellcheck, CI-Gates, Backup/Restore, OpenAPI-YAML, PWA grün; Swift **575 Tests, 27 übersprungen, 1 Fehler** (`testLeaseRenewalKeepsLongJobFromSecondWorker`, zeitabhängig, Systemlast bis 209, schon in `WP-PA1.md` als lastabhängig vermerkt; Backend unverändert), einzeln nachgeholt grün (`JobWorkerTests` 5/5). Die danach ausgelassenen Schritte `check-third-party-notices.sh` und `generate-sbom.mjs --check` einzeln grün. Der Lauf lag vor den Korrekturen aus dem Gegenlesen (nur PWA und das neue Skript); die PWA-Prüfungen oben liefen danach.
- GitHub-CI auf 6bd254e (Lauf 46100135739): grün, alle drei Jobs (PWA/Vertrag/Skripte, Backend-Tests mit Postgres 17, Renderer arm64).
- Nachtrag: Anzeige der verwaisten Dateien auf der Prüfseite hell und dunkel angesehen (Computer und Handy, `docs/screenshots/pa2/9-orphans-*`, **Mock-Backend**; der Mock-Test nimmt die Bilder mit `SCREENSHOT_DIR` auf). Der CI-Lauf zu diesem Nachtrag steht auf der Karte.
