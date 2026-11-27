# Übergabe WP-PA1 (Paperless-Import gegen echte Instanz und Sicherheitsprüfung)

Stand 27.11.2026, auf `main`. Geprüft gegen **paperless-ngx 3.5.1** (Image `ghcr.io/paperless-ngx/paperless-ngx:3.5.1`, API-Version 10, Header `X-Version`/`X-Api-Version`), lokal im Container (Port nur `127.0.0.1`), mit **erfundenen** Dokumenten. Keine Verbindung zu einer echten Instanz, keine echten Dokumente, kein Code und keine Texte aus Paperless-ngx (GPL-3.0): Paperless wird nur über seine öffentliche REST-API und sein Werkzeug `document_exporter` bedient, die Dokumente entstehen in `scripts/paperless-e2e/seed.py` (eigener PDF-/PNG-Erzeuger).

## Ablauf (rot, dann grün)
1. Rote Tests zuerst: `DMSImportPA1Tests` (AK-PA1-4 bis AK-PA1-8) gegen den Mock in den Antwortformen der echten Instanz: `Executed 6 tests, with 32 failures` (Lauf vor der Umsetzung, Quelle der Antwortformen: Erkundung der laufenden Instanz).
2. Umsetzung, danach grün: `DMSImportPA1Tests` + `DMSImportTests` + `PaperlessMappingTests` zusammen `Executed 23 tests, with 0 failures`.
3. Echter E2E-Lauf `scripts/e2e-paperless-import.sh`: startet Paperless 3.5.1 und Redis (Wegwerf-Container, Wegwerf-Kennwörter), befüllt sie, exportiert mit `document_exporter`, startet zwei Hub-Instanzen (`App serve`) und zwei Worker-Prozesse (`App worker`) auf einer echten Postgres-Datenbank und vergleicht Hashes und Titel gegen die Instanz selbst: `E2E Paperless-Import: alles ok`, 65 Prüfungen.

## Befunde und Behebung (AK-PA1-2 bis PA1-8)
| # | Befund | Beleg | Behoben |
| --- | --- | --- | --- |
| 1 | Token der REST-Quelle blieb nach dem Lauf verschlüsselt in `dms_imports.secret_enc` | `testAKPA1_7_tokenIsRemovedWhenTheRunEnds`; E2E „Token nach dem Lauf gelöscht“ | ja: `secret_enc = NULL` beim Beenden (fertig/fehlgeschlagen/abgebrochen) und beim Abbruch eines wartenden Laufs. Während des Laufs bleibt es für die Fortsetzung nach Worker-Absturz |
| 2 | Keine feste API-Version: ohne Angabe antwortet Paperless mit der Standardversion | `testAKPA1_5_apiVersionIsPinned`; echte Instanz: `version=99` -> 406, `version=1` -> 406 | ja: `Accept: application/json; version=10`; 406 -> `source_api_version_unsupported` |
| 3 | Zwei Fassungen eines Dokuments: Export liefert die Fassung als eigenen Eintrag mit `root_document` (wäre ein zweites, stammdatenloses Dokument), API liefert `versions` | `testAKPA1_8_*`; E2E „Fassungen im Bericht gezählt“ | ja: ein Dokument, neueste Fassung (wie `download` sie ausliefert), ältere im Bericht (`versions_skipped`, `document_versions_skipped`); verwaiste Fassung bleibt ein eigenes Dokument |
| 4 | Annahme „REST-API liefert keine Prüfsummen“ falsch: `versions[].checksum` (SHA-256 des Originals) und `metadata.archive_checksum` existieren | `testAKPA1_6_*`; E2E „alle Prüfsummen über die API belegt“, Hashes gleich der Instanz | ja: jede Datei geprüft, `files_checksum_verified`; Abweichung -> `checksum_mismatch`/`archive_checksum_mismatch`, nichts übernommen; ältere Stände ohne Prüfsummen: weiter `files_without_checksum` |
| 5 | 403 (Token gültig, Leserecht fehlt) wurde wie ein falsches Token als `source_auth_failed` gemeldet | `testAKPA1_4_*`; E2E „ohne Rechte“ gegen echten Benutzer ohne Rechte | ja: `source_permission_denied` |
| 6 | Benutzer mit eingeschränkter Sicht: Stammdaten (Korrespondenten, Tags, …) liefert die API leer, die Verweise wurden als `reference_unknown` („gelöscht“) gemeldet | `testAKPA1_4_*`; E2E „Leser“: 8 von 10 Dokumenten, 0 Stammdaten | ja: Befund `reference_not_visible`, Bericht `rights.visibility_note_code = api_visible_to_token_user_only`. Anzahlen = das für den Benutzer Sichtbare (AK-PA1-4) |
| 7 | Die Archivprüfsumme der API steht nur in den Metadaten | E2E | ja: eine Anfrage je Dokument mit Archivdatei (`/api/documents/{id}/metadata/`) |
| 8 | `document_exporter` schreibt auch den **Papierkorb** (`deleted_at` gesetzt): der Export-Import übernahm gelöschte Dokumente, die API listet sie nicht | E2E rot (`Export: Dokumente in der Datenbank: ist '11', erwartet '10'`), `testAKPA1_2_trashedEntriesOfTheExportAreSkipped` (rot mit 8 Fehlern, dann grün) | ja: Dokumente, Fassungen, Notizen und Feldwerte mit `deleted_at` werden übersprungen; Bericht `documents_in_trash`, Befund `document_in_trash_skipped` |

Bestätigt ohne Änderung: Original-Download (`?original=true`) liefert die neueste Fassung, `?version=<id>` eine ältere; die Archivdatei der neuesten Fassung ist der Standard-Download; Export-Manifest und API stimmen bei Titel (Umlaute, ß), Tags, Feldern, Notizen, ASN, Datum überein (E2E: gleiche Originalhashes, gleiche Anzahl Tags/Felder/Feldwerte in beiden Mandanten).

## Sicherheitsprüfung D6 (AK-PA1-3)
Durchgeführt vom umsetzenden Agenten; **ein unabhängiger Reviewer-Lauf steht weiter aus.**

| Bereich | Ergebnis | Beleg |
| --- | --- | --- |
| SSRF | `http` ohne Entwicklungsschalter, Loopback, `localhost`, Link-Local (Metadaten), `::1` -> 422 mit Grund; Allowlist und Auflösung/Rebinding-Schutz aus H10 unverändert | E2E gegen Hub ohne `DMS_IMPORT_INSECURE_DEV` (5 Prüfungen), `testAKD9_endpointPolicy` |
| TLS | Zertifikatsprüfung scheitert gegen selbstsigniertes Zertifikat mit `source_tls_failed`, kein Aufruf erreicht den Server | `testAKD9_tlsCertificateIsVerified`. **Offen:** die Instanz im Container spricht nur HTTP; ein Handshake gegen eine echte Instanz hinter TLS ist nicht gelaufen. Eine Instanz mit eigener Zertifizierungsstelle (typisch im Heimnetz) scheitert heute immer (kein eigener Aussteller einstellbar), siehe „Offen“ |
| Weiterleitungen | werden nicht verfolgt, das Token geht nur an den eingetragenen Host; `next` der Seitenabfrage wird nie als URL verwendet (Seitennummer wird selbst gebildet) | `testAKD9_apiImportMatchesExportImport` (Weiterleitung -> `source_http_error`); zu `next`: nur durch Code belegt (`PaperlessAPISource.results`), kein eigener Test |
| Pfade (Export) | Pfad mit `..` -> 422; Symlinks, Geschwisterverzeichnis `exp2`, Dateitausch zwischen Prüfung und Öffnen aus H10 | E2E „Export-Pfad mit .. abgelehnt“, `testAKD9_hostileExportIsContained`, `testAKH10_6_siblingDirectoryWithSamePrefixIsRejected`, `testAKH10_6_manifestSymlinkIsNeverFollowed` |
| Geheimnis | Token nirgends im Klartext: nicht in der Datenbank (`pg_dump`), nicht in Hub- und Worker-Logs, nicht im Audit, nicht in Antworten; nach dem Lauf auch nicht mehr verschlüsselt (Befund 1) | E2E „Token nirgends im Klartext in der Datenbank“, „in keinem Log“, „Kein Lauf behielt ein Token“ |
| Transaktion | je Dokument eine Transaktion (Dokument, Dateien, Tags, Felder, Verweis, Notizen, Text, Idempotenz-Eintrag); Abbruch, Fortsetzung, zwei Worker, Lease-Ablauf | `testAKD9_cancelThenResume`, `…twoWorkersRunEachImportExactlyOnce`, `…leaseExpiryResumesRun`; E2E: zwei Worker-Prozesse, kein Job mit mehr als einem Versuch |
| Hash-Abweichung | untergeschobene oder beschädigte Datei wird nicht übernommen | `testAKPA1_6_*` (Original und Archiv) |
| Rechte der Quelle | Benutzer, Gruppen und Kennwort-Hashes des Manifests werden nie gelesen (Kanarienwert); Besitzer/Rechte nicht übernommen (F-23) | Kanarienwert: `testAKD9_fullImportCountsHashesRelationsAndIdempotentRepeat`; Rechte nicht übernommen: `testAKD9_dryRunWritesNothingAndReports` |
| Antwortgrößen | JSON höchstens 32 MiB, Datei höchstens `maxUploadBytes` (Content-Length und gezähltes Lesen), Manifest 128 MiB | Code; bestehende Tests `file_too_large` |

## Ausgeführt
- `DMSImportPA1Tests` rot (32 Fehler) vor, grün nach der Umsetzung; Import-Tests gesamt 23 grün; `scripts/e2e-paperless-import.sh` grün (65 Prüfungen); volle Suite `scripts/ci.sh` auf dem Stand von bac77a2: Exit 0, 499 Tests, 0 Fehler, 22 übersprungen (14 bekannte und 8 Mail-Tests, weil GreenMail unter Last nicht bereit wurde; diese 8 einzeln nachgeholt, grün). Zwei Läufe davor scheiterten bei Systemlast über 100 an je anderen zeitabhängigen Tests (`testAKD1_1_concurrentTwoInstances`, `testAKD9_apiImportMatchesExportImport` mit `connectionRequestTimeout`, `testLeaseRenewalKeepsLongJobFromSecondWorker`), alle einzeln grün.
- Paperless-Container laufen nur während des E2E-Skripts (Name `labhub-pa1-e2e-<pid>`), das Skript entfernt Container, Netz und Datenbank.

- GitHub-CI zu 38ad248 (Lauf 45984255204): grün, Backend 499 Tests, 2 übersprungen, 0 Fehler, darin die 7 Tests aus `DMSImportPA1Tests`.

## Offen / Annahmen
- **TLS mit eigener Zertifizierungsstelle** (Heimnetz-Instanz mit selbst ausgestelltem Zertifikat): der Hub vertraut nur dem System-Zertifikatsspeicher. Entscheidung für PA3 nötig (Zertifikat einer öffentlichen Stelle verlangen, oder `DMS_IMPORT_CA_FILE` einführen). Nicht still entschieden.
- Ältere Fassungen werden nicht importiert, nur gezählt (Entscheidung, ob sie als Dokument/Datei übernommen werden sollen, nach dem Probelauf PA3/PA6).
- Das Manifest wird weiter komplett geladen (Grenze 128 MiB, Schätzung rund 10 000–14 000 Dokumente, siehe `PAPERLESS-ABLOESUNG.md`), kein Stream-Parser.
- Geprüft nur mit Version 3.5.1. Eine andere Paperless-Version kann andere Antwortformen liefern (`Accept` ist fest auf 10); PA3 muss die Version der echten Instanz mit dem Bericht abgleichen.
- Abbildung von Währung in Geldfeldern, `documentlink`-Feldern, Regeln: unverändert wie in D6 (Probelauf entscheidet).
