# Übergabe WP-PA3V: Vorbereitung PA3 (Download-Zeitlimit, Anleitung interne Ziele und Allowlist)

Stand 28.11.2026, am Stand `origin/main` f9accae. Zwei Funde aus dem Review `docs/handoff/WP-PA1R.md` (Abschnitt „Karten“), beide vor PA3 nötig. Nur lokale Container mit erfundenen Dokumenten; keine Verbindung zu einer echten Paperless-Instanz, kein Token des Nutzers, kein Deploy.

## Ergebnis in Kürze
- **Download-Zeitlimit (Karte 2 aus PA1R): Vermutung widerlegt, kein Fix nötig.** `client.execute(req, timeout: .seconds(120))` begrenzt nur die Zeit bis zum Antwortkopf, nicht den Datenstrom. Ein Download, der länger als die Frist läuft, wird vollständig geladen; nur ein Stillstand von 60 s (Leerlauffrist `read`) bricht ab. Belegt mit einem Test (Server im Prozess) und mit dem E2E gegen paperless-ngx 3.5.1 (große erfundene Datei über eine gebremste Leitung, Lauf länger als 120 s).
- **Anleitung (Karte 1 aus PA1R):** `docs/ANLEITUNG-PA3-PAPERLESS-PROBELAUF.md`, Abschnitt 3: Schalter `DMS_ALLOW_INTERNAL_TARGETS=true` nur zusammen mit `DMS_IMPORT_HOST_ALLOWLIST=<genau dieser Host>`, Eintrag ohne Port erlaubt jeden Port, danach wieder abschalten (mit Kontrolllauf). Das Verhalten der Anleitung prüft der E2E (Abschnitt 8 des Skripts) gegen echte Hub-Prozesse mit der Betriebsrichtlinie.
- Karte 3 (verwaiste Blobs) nur gelesen, kein Code: Der Prüfjob `dms.verify` (WP-D5) findet unreferenzierte Blobs **nicht** (Abschnitt „Karte 3“).

## Befund Download-Zeitlimit
Code: `PaperlessAPISource.request` ruft `client.execute(req, timeout:)`; `materialize` streamt danach `response.body` in eine Datei. In async-http-client 1.36.2 (`HTTPClient+execute.swift`, `executeCancellable`) wird die Frist als Aufgabe auf dem Event-Loop geplant und per `defer` abgebrochen, sobald `execute` mit dem Antwortkopf zurückkehrt; der Datenstrom läuft danach ohne diese Frist. Es bleibt die Leerlauffrist `HTTPClient.Configuration.timeout.read` (60 s ohne Daten).

- **Test zuerst** (`backend/Tests/HubKitTests/Modules/DMSImportDownloadTimeoutTests.swift`, Frist per Naht `requestTimeout` auf 2 s gesetzt, Server liefert 512 KiB über 4 s):
  - Erwartung des Reviews war rot (Abbruch nach 2 s). Lauf 28.11. 00:11: `testAKPA3V_1_longDownloadIsNotCutOffByTheRequestTimeout` **grün** (4,2 s, Datei vollständig). Damit ist die Vermutung widerlegt; es gibt keinen roten Lauf, weil es keinen Fehler gibt.
  - Ein dritter Test für eine neue Gesamtobergrenze war im selben Lauf rot (kein solcher Mechanismus vorhanden: Download über 6 s endete erfolgreich trotz 2 s „Gesamtfrist“). Er wurde **verworfen**, nicht umgesetzt: eine Obergrenze für die Gesamtdauer brächte genau den Abbruch großer Scans, den die Karte vermeiden will; gegen einen endlos tröpfelnden Server schützen Größenlimit (`DMS_MAX_UPLOAD_BYTES`) und Abbruch des Laufs.
  - `testAKPA3V_2_stalledDownloadEndsAfterTheIdleTimeout`: Server bleibt mitten im Strom stehen, Ende mit `source_unreachable` nach der Leerlauffrist (im Test 1 s).
- **Code:** nur die Naht `requestTimeout` (Standard unverändert 120 s) und ein Kommentar zur tatsächlichen Wirkung.
- **E2E** (`scripts/e2e-paperless-import.sh`, Abschnitt 6b): `scripts/paperless-e2e/large.py` legt ein erfundenes PDF von 36 MiB an (kleine Textseite, Zufallsbytes als Dateianhang), `scripts/paperless-e2e/slowproxy.py` bremst die Antworten ab dem ersten MiB auf 300 000 B/s. Der Import über diese Leitung muss `done` sein, länger als 120 s dauern, kein Dokument überspringen, Hashes und Größe des Originals müssen der Instanz entsprechen.
  - Erster Versuch mit einem großen eingebetteten Bild: der Worker der Paperless-Instanz starb beim Aufnehmen am Speicher (SIGKILL, Docker-VM 4 GiB). Ursache ist die Miniatur des Bildes, nicht der Hub; daher Dateianhang statt Bild.

## Anleitung interne Ziele und Allowlist
Geprüft aus dem Code (`PaperlessEndpoint.parse`, `vetTarget`, `NetworkTargetPolicy.fromEnvironment`, Compose/Swarm-Dateien) und im E2E (Abschnitt 8):
- ohne Schalter: `https://localhost:<port>` beim Anlegen 422;
- Schalter an, Allowlist `localhost:<port>`: anderer Port 422, anderer interner Host 422, genau dieser Host 202, der Lauf besteht die Zielprüfung und scheitert erst beim Verbinden (Paperless spricht dort kein TLS), Platzhalter-Token danach gelöscht.

## Karte 3: unreferenzierte Blobs (nur gelesen)
- `DMSIntegrity` (`backend/Sources/HubModuleDMS/Integrity/DMSIntegrity.swift`) prüft nur Objekte, auf die eine `files`-Zeile **mit** Eintrag in `dms_document_files` zeigt (Abfrage um Zeile 105). Ein Blob, den der Import (`DMSImportRunner`, `store.put` vor der Transaktion) oder ein Upload schrieb, bevor der Prozess zwischen `put` und Commit starb, hat keine `files`-Zeile; der Prüflauf sieht ihn nicht und meldet nichts. Dasselbe gilt für Staging-Teile (`object_chunks` mit `sha256 = 'tmp:…'`), wenn der Prozess mitten in `put` starb.
- Aufräumen gibt es nur im laufenden Prozess (`DMSUpload.discardIfUnreferenced`, unter Blob-Sperre); nach einem Absturz bleibt der Blob. Folge: nur Speicherverbrauch (und Mandanten-Quota zählt ihn nicht, weil die Quota über `files` rechnet), kein Datenverlust.
- Vorschlag für ein eigenes WP (nicht vor PA3 nötig): Aufräumlauf, der Blobs ohne `files`-Zeile und alte `tmp:`-Teile nach einer Schonfrist (z. B. 24 h, DB-Zeit) unter der Blob-Sperre löscht, mit Zwei-Instanzen-Test; optional zählt `dms.verify` sie im Bericht.

## Belege
- Test grün (Messung): siehe oben, Lauf 28.11. 00:11 und 00:13.
- E2E `scripts/e2e-paperless-import.sh` gegen paperless-ngx 3.5.1 (lokal, erfundene Daten), 28.11. 00:24–00:34: **89 ok, 0 Fehler** (bisher 70; neu 12 in Abschnitt 6b, 7 in Abschnitt 8). Große Datei: 37 749 604 Bytes über 300 000 B/s, **Lauf 261 s** (über 120 s), Ergebnis `done`, Hash und Größe des Originals gleich der Instanz, Token gelöscht. Abschnitt 8: `source_tls_failed` nach bestandener Zielprüfung.
- Der erste E2E-Versuch (00:15) brach vor Abschnitt 6b ab (57 ok bis dahin, 0 Fehler): Paperless-Worker SIGKILL beim Aufnehmen des Bildes, siehe oben.
- Volle Suite lokal (`swift test`, eigene Datenbank im lokalen Postgres-Container), 28.11. 00:38–00:49: **568 Tests, 27 übersprungen, 0 Fehler** (wie zuvor 27 Übersprungene: OCR-, Linux- und Mail-Werkzeuge).
  - Vorläufe: Lauf 1 brach mit einer Vapor-Assertion ab („Response body stream writer deinitialized before .end or .error“). Ursache war der eigene Stillstand-Test: Sein Test-Server beendete den Strom nicht, nachdem der Client getrennt hatte. Er endet jetzt wie `DMSUpload` immer mit `.end` oder `.error`. Lauf 2: 568 Tests, 1 Fehler `DMSImportExportTests.testAKD9_hostileExportIsContained` mit `connectionRequestTimeout` (Pool der Datenbank) bei Last über 70 und parallel laufendem E2E; einzeln und zusammen mit den neuen Tests grün (13/13), in Lauf 3 ebenfalls grün.
- GitHub-CI zu 219ec95 (Tests, Skripte, Anleitung, Bericht): Lauf 46084494864, **grün** (Backend-Tests mit Postgres 17, PWA/Vertrag/Skripte, Renderer arm64). Das E2E läuft nicht in der CI (lokal, siehe oben).

## Offene Punkte
- Karte „Unreferenzierte Blobs nach Absturz im Import“ (FCCE676C) bleibt offen: Es fehlt ein Aufräumlauf für unreferenzierte Objekte (eigenes WP, siehe unten).
- PA3 selbst (Lauf gegen die echte Instanz) bleibt beim Nutzer; die Anleitung ist ein Entwurf für AK-PA3-1 (Paperless-Version der echten Instanz gegen 3.5.1 abgleichen).
