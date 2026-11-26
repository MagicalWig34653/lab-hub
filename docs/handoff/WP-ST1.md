# WP-ST1: GitHub-CI (Backend, PWA, Vertrag)

Stand 26.11.2026, ausgehend von `42da5df`.

## Umgesetzt

- `.github/workflows/ci.yml`, ausgelöst bei jedem Push und Pull Request, nur `contents: read`.
  - Job Backend: Dienst `postgres:17`, `scripts/ci-backend.sh`: volle Swift-Suite im Ziel `worker-test` aus `Dockerfile.worker` (Swift 6.2, Linux, OCR-Werkzeuge) im Host-Netz; Docker ist durchgereicht, damit die Mail-Tests (GreenMail) laufen.
  - Job PWA: shellcheck, `scripts/test-ci-gates.sh`, `check-env-docs.sh`, `npm ci`, Vertrags-YAML, `npm run check` (inkl. Abgleich `types.ts` mit dem Vertrag), Unit-Tests, Mock-E2E (Chromium).
- `scripts/check-test-report.sh` (AK-ST1-1): listet übersprungene Tests mit Begründung (Log, Lauf-Zusammenfassung, Warnhinweis); rot bei fehlender Abschlusszeile, fehlgeschlagenem Test, übersprungenem Datenbanktest oder wenn kein `PostgresTests`-Fall bestanden hat. In der CI zusätzlich `LH_MAX_SKIPPED=2` (erwartet: AK-S1-7 Messlauf, AK-O2-5 read-only Root): jeder weitere Skip ist rot, auch bei Mail- oder Mehrprozess-Tests. Kommt ein erwarteter Skip dazu, die Zahl in `ci.yml` anpassen.
- `scripts/check-workflows.sh` (AK-ST1-3): Actions auf 40-stelligen Commit, keine Schreibrechte, Secrets, Image-Pushes, Releases oder `pull_request_target`. Textprüfung der Workflow-Dateien; aufgerufene Skripte prüft sie nicht.
- `scripts/test-ci-gates.sh`: Tests beider Prüfungen mit synthetischen Eingaben, Teil von `scripts/ci.sh` und der CI.
- Fix: `DMSMailTests` übersetzte unter Linux nicht (`SOCK_STREAM` ist in Glibc ein eigener Typ).
- Fix im Produkt (Fund aus der CI): `migrate` hält die Sperre auf einer Verbindung und migriert auf einer zweiten; ein Pool hat eine je Event-Loop. Mit einem Kern lief auch ein einzelner Aufruf in `connectionRequestTimeout`. Die Sperre nutzt jetzt den eigenen Pool `psql_migration_lock`. Eine Verbindung entsteht erst beim Migrieren und bleibt bis zum Prozessende offen; das zählt nur bei `AUTO_MIGRATE=true` (eine Verbindung mehr), die Deploy-Dateien setzen `false` und migrieren in einem eigenen Prozess.
- Fix im Produkt (Fund aus der CI): Ignoriert ein OCR-Werkzeug unter Linux das Abbruchsignal, beendet `timeout` nach 5 s die Gruppe samt sich selbst mit `KILL`; Foundation meldet Signal 9, geprüft wurde nur Exit 137. Ergebnis war `ocr_failed` statt `ocr_timeout`.
- Fix: `WorkerProcessTests` fand das Programm unter Linux nicht und übersprang drei Mehrprozess-Tests.
- Die CI prüft shellcheck ab Stufe `warning` (die ältere Version des Runners meldet Hinweise, die neuere nicht melden).
- Container-Images (`postgres:17`, `swift:6.2-noble`) sind wie in `compose.yaml` und den Dockerfiles per Tag angegeben, nicht per Digest. Keine neue Abhängigkeit im Produkt.

## Tests

Zuerst rot: `scripts/test-ci-gates.sh` ohne die Prüfskripte, 7 Fehler (alle Positivfälle). Danach grün. Nach dem Gegenlesen (schreibgeschützter Agent, Urteil pass, 4 Befunde) 3 neue Fälle rot, dann grün.

OCR-Zeitlimit zuerst rot: `testAKO2_4_timeLimitReportedWhenProcessIgnoresTerm` (Commit `f846a19`) und dieselbe Probe auf `OCRProcess.swift` im Linux-Container (Signal 9, `timedOut=false`), nach `b5e43a6` grün.

Lokal am 26.11.2026 (macOS, eigene Wegwerf-Postgres 17):

- `scripts/ci.sh` (Node-Teil getrennt), Stand mit allen Fixes: 450 Tests, 14 übersprungen (OCR-, Mess- und Linux-Voraussetzungen), 0 Fehler.
- Zuerst rot, dann grün: `PostgresTests.testMigrationOnSingleEventLoop` (neu) und `testParallelMigrationsAreSafe` mit 4 Event-Loops (`connectionRequestTimeout`); Gate-Test „großes Protokoll“ (Auswertung meldete fälschlich fehlende Datenbanktests, `grep -q` brach die Pipe ab).
- Erster GitHub-Lauf 45880169500 (Branch `wp-st1-ci`): rot, 443 bestanden, 5 übersprungen, 1 Fehler (Migration), dazu shellcheck.
- Rot-Probe: `swift test` ohne erreichbare Datenbank, Auswertung Exit 1.
- PWA: `check` ohne Fehler, 106 Unit-Tests, Mock-E2E 59/59.
- `scripts/ci-backend.sh` lief lokal nicht durch: Der Compiler wurde in der Docker-VM (4 GB, geteilt mit anderen Containern) wegen Speichermangel beendet. Die Auswertung meldete beide Läufe rot. Der Linux-Lauf ist über GitHub belegt.

## Ergebnis auf GitHub

| Lauf | Commit (Branch `wp-st1-ci`) | Ergebnis |
| --- | --- | --- |
| 45880169500 | `b07afd5` | rot: Migration (`connectionRequestTimeout`), shellcheck |
| 45882067114 | `2543686` | PWA grün; Backend rot: 447 bestanden, 2 übersprungen, OCR-Zeitlimit |
| 45884605819 | `f846a19` | rot wie erwartet: neuer Test zum OCR-Zeitlimit (448 bestanden, 2 übersprungen, 1 Fehler) |
| 45884703767 | `b5e43a6` | grün: Backend 449 bestanden, 2 übersprungen; PWA `check`, 106 Unit-Tests, Mock-E2E 59/59, Vertrag |

Der Lauf auf `main` ist der CI-Lauf des Stands, der diesen Vermerk enthält; seine Nummer steht auf der Board-Karte.

## Offen

- Unter Linux erreicht das erste Abbruchsignal (`TERM`) die Werkzeuge nicht in jeder Umgebung (vermutlich geerbte Signalmaske, siehe Kommentar in `OCRProcess.swift`); beendet wird dann nach weiteren 5 s.
- Kein Cache für den Swift-Build; jeder Lauf übersetzt neu.
- `backup-restore-test.sh`, `check-third-party-notices.sh`, SBOM-Prüfung und die echten E2E-Läufe (`test:e2e`, `test:e2e:dms`, Stack) laufen weiter nur lokal.
- Nächster Schritt laut Roadmap: PA1 und ST4 (ST2 hängt an ST1).
