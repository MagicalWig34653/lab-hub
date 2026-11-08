# Übergabe WP-F5 (DMS-UI vertiefen)

Stand 08.11.2026, Branch `wp-F5` auf `main` 73cff2a (enthält D3, D5, K2b, H7). Alles unter `pwa/` plus Doku (`docs/FRONTEND.md`, diese Datei, Statuszeile in `docs/ROADMAP.md`). Keine Änderung an `backend/`, `contracts/`, `Dockerfile*`, `deploy/`. Keine neue Abhängigkeit (`docs/LIZENZEN.md` unverändert). Tests und Implementierung entstanden in derselben Session (kein belegter Rot-Lauf); die Hilfsfunktionen haben eigene Vitest-Tests (`admin.test.ts`).

## Umgesetzt
Unterseiten `/dms/review`, `/dms/rules`, `/dms/duplicates`, `/dms/masters`, `/dms/trash`, `/dms/integrity`, `/dms/exports` mit Teilnavigation (nur mit passender Berechtigung sichtbar). Einzelheiten und Festlegungen: `docs/FRONTEND.md` Abschnitt 8 „Umsetzung WP-F5“.
- **Prüf-Warteschlange:** offene Vorschläge gesamt (Filter Art) und je Dokument im Detail; Wert mit Namen, Begründung der Regel im Klartext, Sicherheit, Regelname; Tasten A/R/E, J/K/Pfeile, Roving-Tabindex, Live-Region; Stale-Hinweis (Ziel gelöscht oder 409 `suggestion_stale`), `suggestion_decided` entfernt die Zeile.
- **Regeln:** Liste mit Bilanz, Editor (Bedingungen/Aktionen/Priorität/Sicherheit/Modus), Trockenlauf mit Trefferliste, `timed_out`-Warnung, `truncated`, Feldfehler (`invalid_regex` u. a.); `auto` nur nach aktuellem Trockenlauf speicherbar.
- **Duplikate:** Liste, Gegenüberstellung, Entscheidung. **Stammdaten:** Typen (mit Aufbewahrung in Jahren), Tag-Gruppen, Tags, Pfade, Felder (anlegen, ändern/umbenennen, löschen). **Papierkorb:** Frist, Quelle der Frist, Löschsperre, Verlängerung, Hinderungsgründe, Wiederherstellen, Purge nur Owner mit Bestätigungsdialog, Löschprotokoll. **Integrität:** Lauf, Bericht, Kopf-Hash. **Export:** Job, Status, Download.
- Geteilter Baustein `components/app/ConfirmDialog.svelte` (natives `<dialog>`). `dmsAdminApi` im API-Client. `masters.ts` lädt zusätzlich die Ablagepfade.
- Mock `pwa/mock/dms-admin.ts` (Regeln wirken beim Upload, Marker `(a+)+$`, `MOCK-TAMPER`, Seed-Optionen).

## Tests (tatsächlich ausgeführt)
Mock (Dateien in `pwa/`):
- `npm ci`, `npm run check` (0 Fehler, 0 Warnungen, Vertragstypen aktuell), `npm test` (Vitest **72 Tests**, 11 Dateien; neu `admin.test.ts`, `messages.test.ts` auf alle Quelldateien des Moduls erweitert, nicht abgeschwächt), `npm run build`, `npm run test:e2e:mock`: **39 Tests grün** (28 bestehende unverändert + 11 neue in `e2e-mock/dms-admin.spec.ts`). axe serious/critical = 0 auf Prüf-Warteschlange, Regelliste, Regel-Editor mit Trockenlauf, Papierkorb, Purge-Dialog, Export, Integrität (grün und Alarm), Duplikate, Stammdaten, englischer UI.
- Mock-E2E deckt: Prüf-Workflow mit Tastatur (Regel -> Upload -> Vorschlag mit Begründung -> A/R/J/K -> Wirkung am Dokument -> Stale-Hinweis nach Löschen des Tags), Regel mit Trockenlauf (Treffer, ungültiger Regex, Zeitlimit, `auto` gesperrt bis aktueller Trockenlauf), Papierkorb/Purge (Hinderungsgründe, Löschsperre, Dialog mit Esc/Abbrechen/Bestätigung, Löschprotokoll ohne Titel, Mitglied sieht keine Purge-Aktion), Export, Integrität inkl. manipulierter Datei (Lauf und Export scheitern), Duplikate, Stammdaten.

Echt (`npm run test:e2e:dms`, Umgebung wie `docs/FRONTEND.md` Abschnitt 11):
- Eigene Datenbank `labhub_f5` auf 127.0.0.1:15432 (eigene Rolle, danach beides gelöscht), Backend als Debug-Build vom Stand des Branches (`swift build --product App --scratch-path` außerhalb des Repos), Worker-Container aus `Dockerfile.worker` (Ziel `worker`, `--kinds dms.ocr,dms.verify,dms.export`, read-only Root, tmpfs, `--network host`), Port 5174. Ergebnis: **1 Test grün (~14 s, echte OCR)** mit dem neuen Pfad: Dokumenttyp „Rechnung“ anlegen -> Regel mit Trockenlauf (0 Treffer) speichern -> Scan-PDF hochladen -> OCR fertig -> Vorschlag mit Regel-Begründung in der Prüf-Warteschlange -> per Taste A annehmen -> Typ am Dokument gesetzt; dazu Integritätsprüfung (bestanden, Kopf-Hash 64 Hex), Export (fertig, ZIP mit `PK`-Kopf), Papierkorbseite mit Hinderungsgrund „Frist nicht abgelaufen“ (Buchhaltung ohne Purge-Recht). Danach `docker rm`, `docker rmi`, Datenbank und Rolle gelöscht, Build-Verzeichnis entfernt.
- Der erste echte Lauf fand einen Fehler: das Backend schreibt Vorschlagswerte in Kleinbuchstaben, die Stammdaten-IDs kommen anders geschrieben; der Name wurde nicht gefunden (Anzeige „74eb9a68“). Behoben durch Vergleich ohne Beachtung der Groß-/Kleinschreibung (`sameId`) und gleiche Behandlung in `draftFromRule`; Vitest-Test ergänzt.
- Gegengeprüft: `docker build -f Dockerfile.worker --target worker` auf diesem Stand (enthält den ZIPArchive-Fix): **Exit 0**.
- Nicht ausgeführt: `npm run test:e2e` (Anmeldung), Backend-Tests (`swift test`), `scripts/ci.sh`. Echter Purge-Erfolgspfad ist im echten E2E nicht belegt (Frist 10 Jahre, nur Owner); er ist nur im Mock belegt.

## Befunde (Backend, Fremdbesitz, nicht geändert)
1. **Migration `dms_021_revision` scheitert mit einer einzelnen, nicht-privilegierten Rolle**: `CREATE CONSTRAINT TRIGGER audit_log_dms_chain ON audit_log` -> `permission denied for table audit_log` (42501), weil `018_audit_hardening` TRIGGER auch dem Eigentümer entzieht. Mit Superuser-Rolle läuft sie durch (so liefen die Backend-Tests). Der echte Lauf brauchte deshalb eine Superuser-Rolle. Betrifft `AUTO_MIGRATE`/`migrate` im Betrieb mit der von `setup.sh` angelegten Einzelrolle (H6/D5/Deploy klären: Migration mit privilegierter Rolle oder `GRANT TRIGGER` in der Migration).
2. **Fehlende Routen (nicht erfunden):** Tag-Merge (`POST /tags/{id}/merge` nur im Konzept; die Seite sagt es), Neu-Klassifikation bestehender Dokumente, Änderung des Vorschlagswerts („Ändern“ heißt: im Dokument bearbeiten), Zeitplan/Benachrichtigung für Prüfläufe, Auswahl einzelner Dokumente im Export hat die Oberfläche nicht (Parameter `document_ids` existiert im Vertrag), Aufbewahrung je Dokumenttyp nur über `default_retention_years` am Typ.
3. Die Papierkorb-Seite fragt den Aufbewahrungszustand je Dokument einzeln (`…/retention`, höchstens 3 parallel, 25 je Seite); ein Feld in der Papierkorb-Liste wäre besser.
4. Deploy: Worker-Dienste starten nur `--kinds dms.ocr` (D5-Handoff); Prüfung und Export brauchen `dms.verify,dms.export`, sonst bleiben Läufe `queued` (die Seiten zeigen dann dauerhaft „Wartet“).

## Offen / nächster Schritt
- Quellen-Verwaltung (D4) bewusst nicht gebaut. Extraktionskandidaten (D3 offen) erscheinen noch nicht als Vorschlagsart.
- Kontakt-Vorschläge (`contact_match`) sind in der Oberfläche vorbereitet (Name aus der Kontaktliste, Begrenzung auf 200 Kontakte), aber weder im Mock noch im echten E2E getestet.
- Prüf-Warteschlange lädt 25 je Seite („Mehr laden“); Tastatur-Workflow arbeitet auf den geladenen Zeilen.
- Reviewer-Lauf empfohlen für die Purge-Oberfläche (Bestätigung, Sperren) und `ConfirmDialog`.
