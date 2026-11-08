# Übergabe WP-D6 (Paperless-Import)

Stand 08.11.2026, Branch `wp-D6` (auf `main`, Commit c490b6f = bis D4). Test-DB `labhub_d6`. Tests und Implementierung entstanden in derselben Session (kein getrennter Rot-Lauf). Kein Reviewer-Lauf; **empfohlen** (Schwerpunkte: SSRF/TLS der REST-Quelle, Dateizugriff im Exportverzeichnis, Transaktion in `DMSImportRunner.importDocument`).

## Umgesetzt (`backend/Sources/HubKit/Modules/DMS/Import/`)
- D6a Export-Verzeichnis und D6b REST-API in einem Stand. Beschreibung der Abbildung: `docs/MODUL-DMS.md` Abschnitt 10.
- Migration `dms_023_import` (`dms_imports`, `dms_import_items`, `dms_import_findings`, `dms_document_notes`), Revert getestet, `schema_version` unverändert.
- Routen: `POST|GET imports`, `GET imports/{id}`, `GET imports/{id}/report`, `POST imports/{id}/cancel`, `GET documents/{id}/notes`. Rechte `dms.import.read|manage` (Buchhaltung, Owner). Vertrag +6 Pfade (86), PWA-Typen regeneriert.
- Worker-Job `dms.import.paperless` (Lease, Fortschritt je Dokument, Abbruch), in Registry, Compose und Swarm (`--kinds`, Volume `DMS_IMPORT_SOURCE` read-only unter `/mnt/import`, `DMS_IMPORT_HOST_ALLOWLIST`), `.env.example`, `deploy/README.md`.
- Fixture `backend/Tests/Fixtures/paperless-synthetic/` (`generate.py`, reproduzierbar, `--check`), Mock-API in den Tests.
- Neue Problem-Codes: keine (nur vorhandene `conflict`, `validation_failed`, `not_found`), daher keine i18n-Änderung nötig.

## Tests (`Modules/DMSImportTests.swift`, nennen AK-D9)
Mapping/Policy-Logik, Trockenlauf schreibt nichts + Bericht, Vollimport (Zählungen, Hashes, Beziehungen, ASN-Zähler + Audit), Wiederholung ohne Duplikate, Abbruch/Fortsetzung, zwei Worker = genau einmal, Lease-Ablauf-Fortsetzung, feindliches Export (.., Symlink, Prüfsumme, Typ, Größe), Quota, OCR-Option, Rechte/Mandanten/Validierung/Geheimnis, TLS-Prüfung (selbstsigniertes Zertifikat, braucht `openssl`), API-Import gegen Mock. Bestehende Tests nur erweitert (Rechtematrix, Migration, Tabellenliste).

## Ergebnis (ausgeführt)
`LH_SCRATCH=/tmp/labhub-build-d6 TEST_DB_NAME=labhub_d6 scripts/ci.sh`: Exit 0, 304 Tests, 14 übersprungen (die bekannten), 0 Fehler. `docker compose config` (Compose, Swarm) und shellcheck ohne Fehler.

## Offen / Annahmen
- Manifest-/API-Format **nicht gegen eine echte Instanz verifiziert** (nur synthetisch, aus Funktionsbeschreibung).
- REST-API liefert in der Annahme keine Prüfsummen: alle Dateien erscheinen als `file_without_checksum`.
- Manifest wird komplett geladen (max. 128 MiB), kein Stream-Parser. DNS-Rebinding nicht abgefangen (Allowlist/Netzregel). Lauf ist an den Quellpfad/-URL gebunden; ein Lauf je Quelle gleichzeitig.
- `AsyncHTTPClient`/`NIOSSL` direkt importiert, nicht in `Package.swift` deklariert (transitiv über Vapor; Entscheidung des Package-Besitzers).
- Notizen: nur Lese-Route, keine Schreib-UI; PWA-Seiten für Import fehlen. Docker-Worker-Image mit der neuen Art nicht gebaut/getestet.
- F-23 wie vorgeschlagen umgesetzt (Annahme bis Bestätigung).
