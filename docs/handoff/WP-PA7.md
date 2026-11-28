# Übergabe WP-PA7 (Teil 1): Zielrechner, Backup und Restore im großen Maßstab

Stand 28.11.2026, Basis `978403b` (origin/main). Teil 1 für den Probelauf (`docs/PAPERLESS-ABLOESUNG.md`, Abschnitt 4, Schritt 3): AK-PA7-1 und AK-PA7-2. AK-PA7-3 folgte am selben Tag als Teil 3 (Abschnitt am Ende).

## Umgesetzt
- `docs/ANLEITUNG-ZIELRECHNER.md`: Anleitung mit Platzbedarf (Planungsregeln und Messwerte), Docker-Installation, Bau, `setup.sh`, Start, erste Anmeldung (Weg A `localhost`/SSH-Tunnel geprüft, Weg B Domain mit TLS-Proxy **nicht** geprüft), Sicherung, Notfall-Restore auf neuem Rechner, Messung (Abschnitt 8), Stolpersteine, Abbau. Verweise in `README.md`, `AGENTS.md`, `deploy/README.md`, `docs/ROADMAP.md`, `docs/PAPERLESS-ABLOESUNG.md`.
- `scripts/pa7-restore-probe.sh` und `scripts/pa7-synth-bestand.py`: Messwerkzeug auf einem laufenden Compose-Stack. Erfundene PDFs über die echte Upload-Route, Backup, Test-Restore, Restore in neue Datenbank, Vergleich (Zeilenzahlen, Fingerabdruck), SHA-256 und Größe jedes Objekts **neu aus den wiederhergestellten Bytes**, danach Backend und Worker (gleiche Images und Secrets) auf der wiederhergestellten Datenbank mit Prüflauf `dms.verify`. Verlangt `DMS_OCR_ENABLED=false`. Läuft nicht in der CI (braucht einen Stack).
- Drei echte Fehler beim Durchlaufen der Anleitung in einer frischen Linux-VM behoben oder dokumentiert:
  1. **Secret-Dateien unter Linux nicht lesbar** (`deploy/setup.sh`): `0600` des Hostnutzers, Container als UID 10001, `migrate` endete mit „Secret-Datei für DB_PASSWORD nicht lesbar“. Jetzt `0644` im `0700`-Verzeichnis (Compose hängt die Dateien einzeln ein). Auf macOS mit Colima war es nie aufgefallen.
  2. **`PUBLIC_URL` ohne Port bei `localhost`** (`deploy/setup.sh`): Passkey-Herkunft passte nicht zur Adresse im Browser. Jetzt `http://localhost:<Port>`; mit Domain und HTTPS unverändert.
  3. **Exportierte `DB_HOST=127.0.0.1` überstimmt die `.env` von Compose** (Anleitungsfehler im Entwurf, bei der Notfall-Wiederherstellung aufgefallen): Backup und Restore laufen in der Anleitung in einer Unterschale.
- `deploy/compose/compose.yaml`: `DMS_OCR_ENABLED` (Standard `true`, unverändertes Verhalten) wird an Backend **und** Worker durchgereicht (bisher nur über die Umgebung des Prozesses; im Worker fehlte der Schalter für Mail- und Ordnerquellen).

## Tests und Belege
- **Test zuerst rot:** `scripts/test-ci-gates.sh` um vier Prüfungen erweitert (AK-PA7-1: Port in `PUBLIC_URL` bei `localhost`, keiner bei Domain mit HTTPS; Secret-Verzeichnis `drwx------`, Secret-Dateien `-rw-r--r--`, auf einer Kopie von `deploy/` mit echtem `setup.sh --non-interactive`). Vor der Korrektur lokal rot gesehen (`FAIL … PUBLIC_URL enthält den Port des Backends`, `FAIL … lh_db_password für UID 10001 lesbar (ist -rw-------, erwartet -rw-r--r--)`), danach grün. Der echte Fehler 1 zeigte sich zuerst im Stack der VM (`migrate` Exit 1, Log siehe oben).
- **E2E:** (a) `npm run test:e2e:stack` (Playwright, echter Chromium, virtueller Passkey) von meinem Mac gegen den Stack in der frischen VM, über die weitergeleitete Adresse `http://localhost:18480`: Einrichtung per Passkey, Einladung, Scan-Upload, OCR, Suche, Vorschau, Papierkorb grün (zweimal, auf je einem frisch nach der Anleitung eingerichteten Stack). (b) `scripts/pa7-restore-probe.sh` in zwei Stufen, Messwerte in `docs/ANLEITUNG-ZIELRECHNER.md` Abschnitt 8 (Stufe 1: 0,96 GiB, Stufe 2: 4,84 GiB, 8 850 Dokumente im Lauf): Hash-Prüfung grün (0 Abweichungen bei 11 074 Objekten, Prüflauf der Anwendung `passed`, Audit-Kette ok). (c) Notfall-Restore auf einem zweiten frischen Stack: 80 s, `/ready` nach 3 s, Prüflauf `passed`, 8 850 Dateien, 0 Abweichungen.
- **Lokal (Mac):** `shellcheck deploy/*.sh scripts/*.sh docker-entrypoint.sh`, `scripts/test-ci-gates.sh`, `scripts/check-env-docs.sh`, `scripts/check-workflows.sh` grün; PWA `npm run check`, `npm test` (128 Tests) und `npm run test:e2e:mock` (81 bestanden, 4 übersprungen) grün. Die Swift-Suite lief **nicht** lokal (Docker-VM des Macs reicht dafür nicht, siehe Projektnotiz); am Swift-Code änderte dieses WP nichts, sie läuft in der GitHub-CI.
- **CI:** GitHub-Lauf 46111341772 auf `dc73c75` grün (Backend-Tests Postgres 17, Renderer arm64, PWA/Vertrag/Skripte).
- Nicht ausgeführt: Weg B (Domain, TLS-Proxy), Swarm, x86-64-Hardware, macOS-Docker, Lesbarkeit eines verschlüsselten Mail-Passworts nach dem Notfall-Restore, `deploy/update.sh` in der VM, `OBJECT_STORE=fs` (Compose hängt dafür kein Volume ein, wie in WP-H2 vermerkt).

## Wichtige Zahlen (Details und Hochrechnung in der Anleitung, Abschnitt 8)
- Bau: Backend-Image 442 MB in 4:00 min, Worker 899 MB in 5:06 min (6 Kerne); Build-Cache 15,3 GiB, nach dem Bau entfernen.
- 4,84 GiB Nutzbytes: Datenbank 5,11 GiB (+ ca. 1 GiB Journal), Sicherung 5,53 GiB, Backup 281 s, Test-Restore 86 s, Restore 83 s. Spitzenbedarf mit Quelle, Sicherung und Test-Restore nebeneinander: 16,8 GiB (3,5 × Nutzbytes).
- Planungsregel: freier Platz ≥ 3,5 × Nutzbytes + 20 GiB (mit Bau).

## Offene Punkte und nächste Schritte
- **Nutzer:** Rechner nach der Anleitung einrichten (Abschnitte 2 bis 5, danach `scripts/pa7-restore-probe.sh`), dann PA3 (`docs/ANLEITUNG-PA3-PAPERLESS-PROBELAUF.md`). Zeiten auf der echten Hardware weichen ab; mit dem echten Bestand vor PA8 wiederholen.
- Offen außerhalb der Akzeptanzkriterien: Weg B (TLS-Proxy mit `TRUSTED_PROXIES`), automatische Sicherung (Cron/Timer) und Aufbewahrung, getrennte Migrationsrolle (weiter dokumentiert, nicht umgesetzt), `OBJECT_STORE=fs` im Compose.
- Hinweis zur Probe: Ein Lauf auf dem Produktivstack legt einen Messmandanten mit erfundenen Dokumenten an (Name „PA7 Messung …“); er bleibt im Hub zurück, bis der Stack abgebaut wird. Für den Dauerbetrieb besser auf einem Probestack messen und dann abbauen (Anleitung Abschnitt 10).

# Übergabe WP-PA7 (Teil 3): Prüflauf periodisch, Export-ZIPs nach Frist, zwei Instanzen

Stand 28.11.2026, Basis `23782d4`. AK-PA7-3. Kein Deploy, kein Image.

## Umgesetzt
- **Ohne Zeitgeber, ohne neuen Dienst:** zwei Aufräumschritte der vorhandenen Worker (`jobSweeps`, `backend/Sources/HubModuleDMS/Integrity/DMSMaintenance.swift`). Sie laufen, wenn der Worker keinen Job hat. Compose und Swarm starten den Worker schon mit `dms.verify` und `dms.export`; für den Betrieb ist nichts einzurichten.
- **Prüflauf:** je Mandant mit aktivem DMS und Bestand (Original oder Löschprotokoll) spätestens alle `DMS_VERIFY_INTERVAL_HOURS` (Standard 168, `0` = aus). Fällig ist nur, wenn kein Lauf im Abstand liegt (auch einer von Hand), keiner offen ist (Job wartet oder läuft); `error` zählt nur 24 h. Die verbindliche Prüfung läuft unter einer Datenbanksperre je Mandant in der Transaktion, die Lauf, Job und Audit `dms.integrity.scheduled` anlegt; Zeiten aus `now()`.
- **Export-ZIPs:** `DMS_EXPORT_RETENTION_DAYS` (Standard 30, `0` = nie) nach `finished_at`: Zustand `expired`, `expired_at`, Audit `dms.export.expired`; die `files`-Zeile geht nur, wenn weder eine Dokumentdatei noch ein anderer fertiger Export sie nutzt (`dms_exports.file_id` hat keinen Fremdschlüssel; Verweise anderer Module sichert ihr Fremdschlüssel), danach die Bytes unter der Blob-Sperre. Fällt der letzte Schritt aus, räumt der Verwaisten-Lauf von `dms.verify` das Objekt nach 24 h.
- Migration `dms_032_export_expiry` (Expand: Zustand `expired`, `expired_at`, Teilindex; `schema_version` unverändert; Revert setzt abgelaufene Exporte auf `failed`/`expired`). Vertrag und `types.ts`: `expired`, `expired_at`.
- PWA: Exportseite zeigt „Abgelaufen“ mit Zeitpunkt ohne Download sowie den Hinweis zur Frist; die Prüfseite nennt den Zeitplan. de und en.
- Betrieb: Variablen an den Worker in Compose und Swarm, `.env.example`, `deploy/README.md`, `docs/ANLEITUNG-ZIELRECHNER.md`. `scripts/pa7-restore-probe.sh` schaltet den Zeitplan für den Prüf-Worker auf der wiederhergestellten Datenbank ab, damit die gemessene Zeit nur den Lauf von Hand enthält.

## Annahmen (nicht vom Nutzer entschieden, änderbar)
- Standard 7 Tage zwischen zwei Prüfläufen, jeder Lauf liest den ganzen Bestand (gemessen in Teil 1: 4,84 GiB in 13 s); keine Stichprobe wie in `docs/MODUL-DMS.md` 8 skizziert.
- Standard 30 Tage Aufbewahrung der Export-ZIPs; gilt auch für schon vorhandene Exporte.

## Tests und Belege
Befehl für die neuen Backend-Tests (eigene Wegwerf-Datenbank Postgres 17 auf Port 15437):
`TEST_DB_PORT=15437 swift test --scratch-path "${TMPDIR:-/tmp}/labhub-build" --explicit-target-dependency-import-check=error --filter 'DMSVerifyScheduleTests|DMSExportExpiryTests|DMSMaintenanceE2ETests'`

- **Zuerst rot** (Stand `23782d4` plus nur die Tests; sie nutzen die vorhandene Schnittstelle `jobSweeps`): 13 Tests, 13 rot (27 Fehlschläge: kein Aufräumschritt; E2E mit echten Prozessen 0 statt 1 geplanten Lauf). Dabei fiel ein Testfehler auf (die Upload-Route nimmt kein ZIP an, 415); der Fall „Dokumentdatei nutzt dieselben Bytes“ entsteht seitdem direkt in der Datenbank.
- **Grün:** 13 von 13.
- **Prüflauf periodisch (`DMSVerifyScheduleTests`, 7):** `testAKPA7_3_tenantWithDocumentsGetsExactlyOneScheduledRun`, `…nextRunOnlyAfterTheInterval`, `…intervalIsConfigurableAndZeroDisables`, `…manualRunCountsAndOpenRunsDoNotPileUp`, `…errorRunIsRetriedAfterOneDay`, `…disabledModuleIsNotScheduled`, `…twoInstancesRacingScheduleOneRunPerTenant`.
- **Export-ZIPs nach Frist (`DMSExportExpiryTests`, 5):** `testAKPA7_3_expiredExportZipIsRemoved`, `…exportRetentionIsConfigurableAndZeroKeeps`, `…expiryKeepsBytesThatAreStillReferenced`, `…twoInstancesExpireEachExportOnce`, `…migrationRevertsAndReapplies`.
- **Zwei Instanzen, echter E2E:** `DMSMaintenanceE2ETests.testAKPA7_3_twoWorkerProcessesScheduleExactlyOneRunAndExpireTheExport`: zwei echte `App worker --kinds dms.verify,dms.export` gegen dieselbe Datenbank. Der Test sperrt die Tabelle der Läufe, bis beide Instanzen gleichzeitig beim Einplanen warten, gibt sie dann frei: genau **ein** geplanter Lauf (ein Job, ein Audit `scheduled`, ein `checked`, `passed`, 3 Dateien); nach Zurückdatieren genau ein zweiter; ein abgelaufenes Export-ZIP genau einmal entfernt; beide Prozesse laufen weiter, keine Meldung „Aufräumschritt fehlgeschlagen“, SIGTERM mit Status 0.
- **Gegenprobe:** Ohne die Sperre je Mandant legen die beiden Prozesse **2** Läufe an (E2E rot), der Rennen-Test 6 statt 4 Jobs. Sperre danach unverändert wiederhergestellt.
- **PWA:** `e2e-mock/dms-admin.spec.ts` „AK-PA7-3 expired export …“ zuerst rot (Hinweis zur Frist fehlt), dann grün; Axe ohne schwere Verstöße in hell und dunkel; Bilder beider Seiten in hell und dunkel angesehen.
- **Gesamt lokal:** `LH_PG_CONTAINER=<postgres-container> TEST_DB_PORT=15437 scripts/ci.sh` grün (shellcheck, Gate-Tests, `check-env-docs` 49 Variablen, Backup/Restore, OpenAPI-YAML, PWA `check` und 128 Unit-Tests, Swift **588 Tests, 27 übersprungen, 0 Fehler**, Lizenzhinweise, SBOM); `npx playwright test -c playwright.mock.config.ts` 82 bestanden, 4 übersprungen.
- **Commit und CI:** `7d677d1` auf `origin/main`; GitHub-Lauf 46126454700 grün (Backend-Tests Postgres 17 unter Linux: 588 Tests, 2 übersprungen, 0 Fehler, alle 13 neuen Tests samt Zwei-Prozess-E2E bestanden; Renderer arm64; PWA/Vertrag/Skripte).
- **Nicht ausgeführt:** E2E der PWA gegen ein echtes Backend (`test:e2e:dms`, `test:e2e:stack`) und `scripts/pa7-restore-probe.sh` nach der kleinen Änderung (eine Umgebungsvariable).

## Grenzen
- Die Schritte laufen nur im Leerlauf: Bei dauerhaft voller Warteschlange (z. B. Vollimport) folgen Prüflauf und Aufräumen erst danach.
- Ohne Worker mit der jeweiligen Job-Art geschieht nichts. Es wird keine Meldung verschickt; ein fehlgeschlagener Lauf steht in der Oberfläche und als `dms.integrity.failed` im Audit-Log.
- Ein Download, der genau beim Ablauf läuft, kann abbrechen (nach 30 Tagen unerheblich).
- Mandanten mit abgeschaltetem DMS werden nicht geprüft; ihre abgelaufenen Export-ZIPs werden trotzdem entfernt.
- Weiter offen (nicht Teil dieses Auftrags): Weg B (TLS-Proxy), automatische Sicherung, getrennte Migrationsrolle.
