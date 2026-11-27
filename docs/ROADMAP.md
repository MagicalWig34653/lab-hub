# Roadmap und Arbeitspakete

Status: Entwurf, Stand 01.11.2026, ergänzt 25.11.2026 (Phasen 7–10; **nächste Arbeit zuerst:** PA1 und ST4; ST1 ist fertig). Reihenfolge: Kern → DMS M1 → OCR/Suche → PWA + DMS-UI → Rechnungsmodul → Verknüpfung → Hardening. Aufwand: S ≈ 1 Agent-Session, M ≈ 2–4, L ≈ 5+ (Schätzungen, keine Zusage). **P** = parallelisierbar mit den genannten WPs (kein gemeinsamer Dateibesitz: Migrationen und `contracts/openapi.yaml` nur von einem Agent zugleich ändern, `AGENTS.md` Abschnitt 7).

Statusspalte pflegen: `offen` · `in Arbeit (Agent/Branch)` · `fertig (Commit)`. Jedes WP erfüllt die Definition of Done aus `AGENTS.md` Abschnitt 8; sie wird unten nicht wiederholt. Testkennungen `AK-<WP>-<n>`.

Ausgangsstand (vorhanden, getestet laut `deploy/README.md`/Tests): `migrate`, `schema_version`, `counters`/`CounterService`, `idempotency_keys`/`IdempotencyService`, `jobs`/`JobService` (Lease), `/health`, `/ready`, `HubConfig`, Deploy-Skripte (Compose real getestet, Swarm ungetestet).

## Übersicht

| Phase | WP | Titel | Abh. | Größe | Parallel | Status |
| --- | --- | --- | --- | --- | --- | --- |
| 0 Kern | K0 | Baseline: Build/Test verifizieren, CI-Skript | – | S | P zu allen | fertig (Baseline); F-03 offen |
| | K1 | Auth: Nutzer, Passkeys, Sitzungen, Einladung, Audit | K0 | L | P K4, D1 | offen |
| | K2 | Mandanten, Mitgliedschaft, Rollen, Berechtigungen | K1 | M | | erledigt (Branch wp-K2, Handoff docs/handoff/WP-K2.md) |
| | K2b | Bugfix: `GET /tenants/{tenant}` liefert Modulrechte wirksamer Module (Befund F4b) | K2, K3 | S | | umgesetzt (Branch wp-K2b, Handoff docs/handoff/WP-K2b.md) |
| | K3 | Modul-System (`HubModule`, Aktivierung, Guard) | K2 | M | P K4, K6 | erledigt (Branch wp-K3, Handoff docs/handoff/WP-K3.md) |
| | K4 | OpenAPI-Vertrag, Fehlerformat, Pagination, Vertragstest | K0 | M | P K1, D1 | erledigt (Branch wp-K4, Handoff docs/handoff/WP-K4.md) |
| | K5 | Kontakte und `links` | K2, K4 | M | P K6, K7 | umgesetzt (Branch wp-K5, `docs/handoff/WP-K5.md`) |
| | K6 | Zähler-Erweiterung (transaktional, Schlüsselraum) | K0 | S | P K3, K5 | umgesetzt (Branch wp-K6, `docs/handoff/WP-K6.md`) |
| | K7 | Events/Outbox, Webhooks | K3 | M | P K5 | offen |
| 1 DMS M1 | D1 | ObjectStore (FS, DB, S3), `files`, Hash | K0 | M | P K1, K4 | offen |
| | D2 | DMS-Kern: Dokumente, Upload, Stammdaten, Papierkorb | K3, K5, D1 | L | | umgesetzt (Branch wp-D2, `docs/handoff/WP-D2.md`) |
| 2 OCR/Suche | O1 | Job-Erweiterung, Ingest-Zustandsautomat, Worker-Befehl | D2 | M | | umgesetzt (Branch wp-O1, `docs/handoff/WP-O1.md`) |
| | O2 | OCR-Worker, Textspeicherung, Archivversion | O1 | L | P S1 (Teil) | offen |
| | S1 | DMS-Suche (tsvector, pg_trgm, Filter) | D2 (O2 für OCR-Text) | M | P F1 | umgesetzt (Branch wp-S1, `docs/handoff/WP-S1.md`) |
| | S2 | Globale Suche im Kern | S1, K3 | M | P F2 | offen |
| 3 PWA | F1 | PWA-Gerüst, Login, Shell | K1, K4 | M | P D2, S1 | erledigt (Branch wp-F1, Handoff docs/handoff/WP-F1.md) |
| | F2 | Modul-Navigation, Mandantenwechsel, Einstellungen | F1, K3 | M | P S2 | offen |
| | F3 | Service Worker, Offline-Shell, Update | F1 | M | P F2, F4 | offen |
| | F4 | DMS-UI: Upload, Liste, Detail, Suche | F2, D2, S1 | L | P F3 | umgesetzt (Branch wp-F4, Handoff docs/handoff/WP-F4.md) |
| | F4b | PWA an Backend-Stand (Verarbeitungsstatus, Durchsuchen, Quota/Unterbrechung) und echter E2E mit OCR-Worker | F4, O2, H6 | S | | umgesetzt, echter E2E nur mit lokalem Backend-Patch grün (Branch wp-F4b, Handoff docs/handoff/WP-F4b.md) |
| 3b DMS vertiefen | D3 | Regeln, Vorschläge, Kontakt-Matching, Duplikate | O2, S1 | L | P F4 | offen |
| | D4 | Quellen: Mail-Ingest, Konsumordner, Share-API | O1 | L | P D3 | offen |
| | D7 | Dokumenterkennung (alle Arten, voll: Rechnung) im Mail-Eingang und OCR-Text; Mail als Original, HTML-Text | D3, D4 | L | | umgesetzt (Branch wp-D7, `docs/handoff/WP-D7.md`) |
| | D8 | Weitere Dokumentarten im Extraktor: Vertrag, Versicherung, Behörde/Steuer, Kontoauszug, Kassenbon mit eigenen Fakten | D7 | M | | umgesetzt (Branch wp-D8, `docs/handoff/WP-D8.md`) |
| | D9 | Backend-Lücken der Dokumentübersicht: Summe je Währung, Quelle am Dokument, Suche mit Extraktionswerten/-filtern/Sortierung, `has_open_suggestions`, Dashboard-Zähler | D7, D4, D6, F4c | M | | umgesetzt (Branch wp-D9, `docs/handoff/WP-D9.md`) |
| | D5 | Revisionssicherheit: Löschkonzept, Prüf-Job, Export | D2 | M | P D3, D4 | offen |
| | D6 | Paperless-Import | D2, D3 | M | P D5 | offen |
| | F5 | DMS-UI: Prüfen, Regeln, Stammdaten, Papierkorb | F4, D3, D5 | M | | offen |
| | F5b | DMS-UI: Quellen-Verwaltung, API-Tokens, Scanner-Hinweis, Dashboard-Karte | F5, D4 | S | | umgesetzt (Branch wp-F5b, `docs/handoff/WP-F5b.md`) |
| | F4c | Dokumentübersicht (alle Dokumentarten), Eingang, gegliederte Seitenleiste der App-Shell | F4, F5, F5b, D7 | M | | umgesetzt (Branch wp-F4c, `docs/handoff/WP-F4c.md`) |
| | F4d | PWA an D8/D9: Summenzeile je Währung, Quelle (Spalte/Filter), Dashboard-Zähler aus `dms/stats`, serverseitiger Filter offene Vorschläge, Fakten je Art, Suchtreffer mit Art/Betrag | F4c, D8, D9 | S | | umgesetzt, Gate siehe Handoff (Branch wp-F4d, `docs/handoff/WP-F4d.md`) |
| 4 Rechnung | R0 | Spike: Linux-Build Rechenkern, Testvektoren | K0 | S | P ab Phase 0 | umgesetzt (Branch wp-R0, `docs/handoff/WP-R0.md`) |
| | R1 | Stammdaten Rechnung | K3, K5, R0 | M | | umgesetzt (Branch wp-R1, `docs/handoff/WP-R1.md`) |
| | R2 | Belege, Berechnung, Finalisieren mit Hub-Zähler | R1, K6 | L | | umgesetzt (Branch wp-R2, `docs/handoff/WP-R2.md`) |
| | R3 | Zahlungen, Gutschrift, Umwandlung | R2 | M | | umgesetzt (`docs/handoff/WP-R3.md`) |
| | R4 | Import/Export der bisherigen App | R2 | M | P R3 | offen |
| | R5 | E-Rechnung Erzeugung (Server) | R2 | M | P R3, R4 | offen |
| | R6a | Spike Renderer: Optionen (a)/(b)/(c) gegen Referenz-PDFs | R0 | M | P R1, R2 | offen |
| | R6 | Server-Renderer und Layout-Engine (Pflicht, Linux) | R6a, R2 | L | | offen |
| | R7 | Ausgaben, EÜR/USt-Berichte | R3 | L | | offen |
| | F6 | Rechnungs-UI (erstellen, bearbeiten, finalisieren, PDF, Zahlungen, Berichte) | F2, R2, R6 | L | P R3.. | offen |
| | F7 | Layout-Verwaltung und Designer in der PWA | F6, R6 | L | | offen |
| 5 Verknüpfung | X1 | Beleg↔Dokument, Events, Steuerberater-Export | D5, R3 | M | | offen |
| 6 Hardening | H1 | Lizenzen (BoringSSL), SBOM, Abhängigkeitsprüfung | K0 | M | P ab Phase 0 | offen |
| | H2 | Backup/Restore mit Hash-Verifikation | D2 | M | | fertig, Branch wp-H2 (Handoff `docs/handoff/WP-H2.md`) |
| | H3 | Datenschutz: Export/Löschung je Kontakt/Mandant | K5, D5 | M | | offen |
| | H4 | Update-/Swarm-Test real (Repliken, Rolling, Rollback) | K3, O2 | M | | offen |
| | H5 | Last-/Skalierungstest (Suche, OCR-Backlog) | S1, O2 | M | | offen |
| | H6 | Befunde Security-Review 07.11.2026 (Quota/Waisen-Blobs, merged_into-Prüfung, Idempotency-Hash bei Streams, Rate-Limit hinter Proxy, Audit-Trigger-Rechte) | O1, S1 | S | | fertig (Branch wp-H6, Übergabe `docs/handoff/WP-H6.md`) |
| | H7 | Flaky `testTwoWorkersCompleteEachRunExactlyOnce` (Hash-Ketten-Prüfung nicht atomar) und echte YAML-Prüfung des Vertrags in `scripts/ci.sh` | D5, H6 | S | | fertig (Branch wp-H7, Übergabe `docs/handoff/WP-H7.md`) |
| | H8 | Migrationen mit normaler Einzelrolle: `018_audit_hardening` entzog TRIGGER, `dms_021_revision` scheiterte (`permission denied for table audit_log`); Folgemigration `019_audit_trigger_privilege` und Test mit nicht-privilegierter Rolle | H6, D5 | S | | fertig (Branch wp-H8, Übergabe `docs/handoff/WP-H8.md`) |
| | H9 | PWA-Auslieferung durch das Backend (Dockerfile-Stufe, Static-Middleware, CSP/Header), Gesamtlauf Compose-Stack mit Browser-E2E, Umgebungsvariablen-Doku-Prüfung (`scripts/check-env-docs.sh`), ObjectStoreConfig-Validierung beim Start | F1, F4c, O2, D4, H8 | M | | fertig (a56d9f5; Übergabe `docs/handoff/WP-H9.md`; Replik-Proxy und Migrationsrolle nur dokumentiert) |
| | H10 | Befunde Security-Audit 08.11.2026: Extraktor-ReDoS (Frist, Kappung, begrenzte Quantoren, `extraction_timeout`), IMAP-Zielprüfung (nur DNS-Namen, SSRF-/Port-Sperre, Rebinding-Schutz, `target_not_allowed`), Meta-Refresh in HTML-Vorschau, Pfadpräfix `exp`/`exp2` und Manifest-Race, SecretBox >= 32 Byte, IMAP-Antwortgrenzen. Offen: **H10b** (Befund 5: API-Token an Mandant binden, braucht Migration und Vertragsänderung, nach D9) | D7, D8 | M | | fertig (Branch wp-H10, Übergabe `docs/handoff/WP-H10.md`) |
| | H11 | Codex-Review 17.11.2026, hohe Befunde: Paperless-Zahlen außerhalb von Int64 (kein Absturz), Quota für Export-ZIP und OCR-Archivdatei (`storage_quota_exceeded`), Dateideskriptor des Filesystem-Stores bei Abbruch/Fehler schließen | H10 | S | | fertig (Branch wp-H11, Übergabe `docs/handoff/WP-H11.md`) |
| | H10b | API-Token an genau einen Mandanten binden (Befund 5): `api_tokens.tenant_id` (Migration `dms_026_api_token_tenant`, Expand, nullable, Backfill bei genau einer Mitgliedschaft), Prüfung bei jeder Nutzung (fremder Mandant 404 `not_found`, ungebundenes Token 401 `api_token_unbound`), Vertrag und i18n. Contract-Schritt (NOT NULL) offen | H10, D4 | S | | fertig (Branch wp-H10b, `docs/handoff/WP-H10b.md`) |
| | H12 | Codex-Befunde 7 und 10: Idempotency-Key mit Lease (`locked_at`, Takeover nach Ablauf, `executeAtomic`, `purgeExpired`; Migration `021_idempotency_lease`) und `DMSModule.onActivate` stößt die Job-Kette aktiver Quellen neu an | H10 | S | | fertig (Branch wp-H12, Übergabe `docs/handoff/WP-H12.md`) |
| | H13 | Codex-Befunde 5 und 6: Recovery-Codes-Erzeugung unter Nutzerzeilen-Sperre, Passkey-Login mit `FOR UPDATE` auf der Credential-Zeile (Zaehler faellt nie zurueck) | H12 | S | | fertig (Branch wp-H13, Uebergabe `docs/handoff/WP-H13.md`) |
| | H14 | Codex-Befunde 8 und 4: OCR-Retry nach Quarantäne durch Absturzschleife (Item `ocr_queued` mit Job `failed_permanent` gilt als fehlgeschlagen, Status `failed`/`lease_expired`) und generische Link-Route schützt `dms.document` (Modul aktiv, Mandant, Papierkorb 409, Berechtigung, Zeilensperre, `rev+1`; auch Entfernen/Rückgängig) | H10 | S | | fertig (auf main: f644e78 Schreibpfad, Leseroute Nachtrag 24.11., Übergabe `docs/handoff/WP-H14.md`) |
| | H15 | Codex-Befund 9: DMS-Detail speichert mit der rev des Formulars (`formRev`, nur von `fillForm` gesetzt), nicht mit der vom OCR-Polling aktualisierten; 412 zeigt Konflikt und Knopf „Aktuellen Stand laden“ | H14 | S | | fertig (Branch wp-H15, Übergabe `docs/handoff/WP-H15.md`) |
| | H16 | Lastempfindliche Tests stabilisieren: `testIdempotencyMiddlewareParallelRunsWorkOnce` (Test-Fixture legte `idempotency_keys` ohne `locked_at` an, Takeover-Pfad lieferte 500 unter Last; jetzt echte Migrationen) und `testHugeInputIsBounded` (Wanduhr-Frist unter Last; jetzt Zeichenbudget deterministisch, Produktfrist unverändert) | H12, H10 | S | | fertig (Branch wp-H16, Übergabe `docs/handoff/WP-H16.md`) |
| | H17 | Codex-Befund 8 (Rest): Scheitert ein `dms.ocr`-Job endgültig (Absturzschleife im Kern, Versuche erschöpft, `permanent`), setzt ein Trigger auf `jobs` (Migration `dms_027_ocr_quarantine_sync`, mit Backfill) den Ingest-Eintrag in derselben Transaktion auf `failed_permanent`; Übersicht zählt `failed` statt `queued`, Banner und Retry der PWA greifen, Retry bleibt einmalig (zweiter 409). Regression `DMSH17Tests` (kontrollierte Zeit per Lease in der Datenbank) und echtes E2E `scripts/e2e-dms-ocr-failure.sh` (Backend, Postgres, Worker-Prozess, ohne Mocks), Handoff `docs/handoff/WP-H17.md` | erledigt (lokal grün) |
| 7 Struktur | ST1 | GitHub-CI (Backend mit Postgres, PWA, Vertrag; ohne Image/Release) | – | S | P zu allen | fertig (auf main, Übergabe `docs/handoff/WP-ST1.md`) |
|  | ST2 | Kern vom DMS-Modul entkoppeln (Job-Handler, Token-Scopes, Link-Schutz, Fehlertyp) | ST1 | M |  | fertig (auf main, Übergabe `docs/handoff/WP-ST2.md`) |
|  | ST3 | Swift-Targets `HubCore`/`HubModule*` (F-14) | ST2 | M | nicht parallel zu Backend-WPs | offen |
|  | ST4 | PWA Darstellung: System/Hell/Dunkel mit Einstellungsseite | – | S | P ST1–ST3 | fertig (mit ST7, Übergabe `docs/handoff/WP-ST7.md`) |
|  | ST5 | PWA Grundbausteine: Fehlertexte, Versions-/Fähigkeitsprüfung, Betreiber-Modulschalter | ST4 | M | P ST2 | offen |
|  | ST6 | PWA-Namen: „LAB hub“, Module „docs“ und „invoice“ (F-01) | – | S | P ST1–ST3 | fertig (Übergabe `docs/handoff/WP-ST6.md`) |
|  | ST7 | PWA-Redesign nach Vorbild TimeTrack, Akzentfarbe je Benutzer | ST4 | M |  | umgesetzt, Abnahme durch den Nutzer offen (Übergabe `docs/handoff/WP-ST7.md`) |
| 8 Scan-Bridge | BR1 | Hub: Scan-Aufträge, Geräte, Bridge-Routen, Scope und Rechte | ST2 | M |  | offen |
|  | BR2 | Bridge-Dienst (SANE, sane-airscan), Container, E2E mit `test`-Gerät | BR1 | L |  | offen |
|  | BR3 | PWA: Scanner wählen und Scan starten | BR2, ST4 | M | P BR4 | offen |
|  | BR4 | Bridge-Betrieb, Lizenzhinweise, optionaler Ordner-Eingang (F-22) | BR2 | M | P BR3 | offen |
| 9 Ablösung | PA1 | Paperless-Import gegen echte Instanz (lokal, erfundene Daten) und Sicherheitsprüfung | D6 | M | P ST4 | offen |
|  | PA2 | PWA: Import anlegen, Trockenlauf, Bericht, Notizen | PA1, F2 | M |  | offen |
|  | PA3 | Probelauf mit API-Lese-Token gegen die echte Instanz und Inventur der Eingangswege (Nutzer) | PA1, PA2, PA7 (Teil 1) | S |  | offen |
|  | PA4 | Miniaturen (Worker, Route, Liste) | O2 | M | P PA2 | offen |
|  | PA5 | Gespeicherte Ansichten, Mehrfachauswahl, Massenbearbeitung | F4c, S1 | L | P PA4 | offen |
|  | PA6 | Lücken aus dem Probelauf (Dateitypen, signierte PDFs, Import-Abbildung) | PA3 | M–L |  | offen |
|  | PA7 | Betriebsreife: Zielrechner, Restore, Zeitplan Prüflauf, Aufräumen Exporte | H2, H9 | M |  | offen |
|  | PA8 | Vollimport, Parallelbetrieb, Umschalten (Nutzer) | PA3–PA7 | M |  | offen |
| 10 Modul-Apps | AB1 | Geräteanmeldung für Apps (Token mit Scopes, Widerruf) | ST2 | M |  | offen |
|  | AB2 | Änderungs-Feed für Zwischenstände | D2 | M | P AB1 | offen |
|  | AB3 | Abgeleitete Fassungen (Anmerkungen) hochladen | D2, D5 | M |  | offen |
|  | APP-M0 | App „docs“: Anzeigename, Bundle-ID, Xcode-Projekt, gemeinsame Pakete, CI | F-33 (Rest) | S |  | offen |
|  | APP-M1 | iPhone/iPad: Anmeldung, Dokumentenscanner, Teilen, Eingang | APP-M0, AB1 | L |  | offen |
|  | APP-M2 | Finden, Klärstapel, Live Text, Mehrfenster, Scan über Bridge | APP-M1, AB2, BR2, PA4 | L |  | offen |
|  | APP-M3 | Native Mac-App, ImageCaptureCore, Continuity, Spotlight, App Intents | APP-M2 | L |  | offen |
|  | APP-M4 | Widgets, Steuerelemente, Sperrbildschirm, Live Activities, Mitteilungen, Handoff | APP-M2 | M | P APP-M3 | offen |
|  | APP-M5 | Dateien/Finder (File Provider), Quick Look, Miniaturen, Drucken | APP-M3, PA4 | L |  | offen |
|  | APP-M6 | Eigenständiger Modus, CloudKit, Verbinden mit Hub, Anmerkungen | APP-M3, AB3 | L |  | offen |
|  | APP-M7 | Foundation Models, Vision Pro, Watch, Push, eSCL direkt | APP-M4–M6 | L |  | offen |
|  | APP-I0 | App „invoice“: Konzept zum Anbinden an den Hub (eigene App je Modul) | APP-M1, R4 | S |  | offen |

Grundsatz: Hub ohne Swift-App nutzbar (`AGENTS.md`); die Rechnungsphase ist daher kein optionaler Anhang, sondern gleichwertig. Kritische Pfade: **DMS** K0 → K1 → K2 → K3 → D2 → O1 → O2 → S1 → F4; **Rechnung** R0 (Linux-Rechenkern) → R1 → R2 → R6a/R6 (Renderer) → F6 → F7; beide laufen nach K3 parallel (getrennter Dateibesitz). Früh parallel starten: K4, D1, K6, R0, H1, F1 (sobald K1/K4).

## Phase 0 – Kern

**WP-K0 Baseline (S).** Ziel: Bestehendes verifizieren und Lizenzbefund prüfen. Zusatzauftrag: in der aufgelösten `swift-nio-ssl`-Version (`Package.resolved`) `LICENSE` und Header der `CNIOBoringSSL`-Dateien auswerten (Anzahl Dateien mit altem OpenSSL-/SSLeay-Header, Apache-2.0, ISC; ISC unkritisch), Befehl und Ergebnis in `docs/LIZENZEN.md` dokumentieren, Rückfalloptionen laut `OFFENE-FRAGEN.md` F-03; Rechtsfrage bleibt nicht abschließend geklärt. Akzeptanz: `swift build`/`swift test` mit Scratch-Pfad laufen gegen lokales Postgres; falls `--build-system native` nötig, in `AGENTS.md` eintragen; `deploy/` unverändert lauffähig; `.env.example` vollständig. Test: vorhandene `HealthTests`, `PostgresTests` grün; Ergebnis in `README.md` notiert. Abh.: –.

*Übergabevermerk 01.11.2026:* `scripts/ci.sh` (shellcheck, `swift build`, `swift test`, Scratch-Pfad) lief grün: 11 Tests, 0 Fehler, davon 6 Postgres-Tests gegen lokales Postgres 17; kein `--build-system native` nötig (Swift 6.4.2, macOS arm64). `.env.example` vervollständigt. `deploy/` unverändert, **nicht** erneut ausgeführt. Lizenzbefund (`docs/LIZENZEN.md`): 323 von 643 CNIOBoringSSL-Dateien mit altem OpenSSL-Header, 2.37.5 ist die neueste Version; F-03 braucht Nutzerentscheidung. Nächster Schritt: K4, K6, D1, R0 (parallel möglich), dann K1.

**WP-K1 Auth (L).** Ziel: Nutzer, Passkeys, Sitzungen. Details `ARCHITEKTUR.md` 4.1; Vorbild-Dateien dort. Akzeptanz: AK-K1-1 Setup-Token-Bootstrap des ersten Nutzers; K1-2 Passkey-Registrierung/-Login mit virtuellem Authenticator; K1-3 Einladung, Einmal-Link, Ablauf; K1-4 Recovery-Codes einmalig; K1-5 Sitzung gilt auf zweiter Instanz; K1-6 Rate-Limit instanzübergreifend (DB); K1-7 „alle Geräte abmelden“; K1-8 Audit-Einträge ohne Nutzdaten, Tabelle append-only (UPDATE scheitert). Test: XCTVapor + Postgres, virtueller Authenticator als Testhilfe, Zwei-Instanzen-Test. Migrationen `users`, `passkey_credentials`, `sessions`, `invitations`, `recovery_codes`, `audit_log`. Offen: F-04, F-05.
*Status WP-K1: AK-K1-1…8 umgesetzt und getestet (Branch wp-K1); offen: Notfall-Passwort, API-Tokens mit Scopes, Proxy-Vertrauen fürs Rate-Limit, siehe `docs/handoff/WP-K1.md`.*

**WP-K2 Mandanten und Rechte (M).** Ziel: `tenants`, `memberships`, Rollen, Berechtigungen (`ARCHITEKTUR.md` 4.2). Akzeptanz: AK-K2-1…3 (dort). Test: generierte Matrix Rolle×Berechtigung×Route; Mandantentrennung mit zwei Mandanten und fremden IDs (404). Abh.: K1.

*Status WP-K2: AK-K2-1 und AK-K2-2 umgesetzt und getestet (Branch wp-K2); AK-K2-3 (RLS-Spike, F-15) nicht durchgeführt, siehe `docs/handoff/WP-K2.md`.*

**WP-K3 Modul-System (M).** Ziel: `HubModule`, Registry, `tenant_modules`, `ModuleGuard`, `/api/v1/modules`, Beispielmodul `ping` (nur Test). Akzeptanz: AK-K3-1…6 (`ARCHITEKTUR.md` 3.5). Test: Zwei-Instanzen-Aktivierung, Guard-Test über alle Routen, Migration deaktivierter Module. Abh.: K2. ADR 0004 auf „akzeptiert“ setzen, wenn Nutzer bestätigt.

*Status WP-K3: AK-K3-1…6 umgesetzt und getestet (Branch wp-K3); offen: Aufteilung in Swift-Targets (F-14) beim ersten echten Modul, Events/Jobs/Suchindex-Hook im Protokoll, siehe `docs/handoff/WP-K3.md`.*

**WP-K4 API-Vertrag (M).** Ziel: `contracts/openapi.yaml`, Problem-Details-Fehler, Cursor-Pagination-Helfer, `Idempotency-Key`-Middleware (nutzt `IdempotencyService`), `X-Request-Id`, Versionsendpunkt. Akzeptanz: AK-K4-1…3 (`ARCHITEKTUR.md` Abschnitt 5). Test: Vertragstest Routen↔Vertrag (Vorbild `timetrack-backend/Tests/.../Contract/`), Pagination-Parallelitätstest. Abh.: K0.

**WP-K5 Kontakte und Links (M).** Akzeptanz: CRUD mit Mandantentrennung; Dubletten-Hinweis (USt-ID/IBAN); Merge mit Umschreiben der `links` und Audit; `links` mit Quelle, Umkehrbarkeit (Löschen = Eintrag mit `removed_at`, nicht still). Test: Merge-Test, Mandantentrennung, Rechte. Abh.: K2, K4.

**WP-K6 Zähler (S).** Akzeptanz: `CounterService.next(on: tx)` innerhalb fremder Transaktion; Rollback gibt Nummer frei (Zählerstand rollt zurück); `ensureAtLeast(tenant,key,value)` für Importe mit Audit; Test mit 2 Verbindungen parallel 1000 Nummern ohne Doppel/Lücke. Abh.: K0.

**WP-K7 Events/Outbox/Webhooks (M).** Akzeptanz: AK-K7-1…3 (`ARCHITEKTUR.md` 4.9); Webhook-Signatur, Retry/Backoff, SSRF-Schutz getestet; `LISTEN/NOTIFY` als Weckruf. Abh.: K3.

## Phase 1 – DMS M1

**WP-D1 ObjectStore (M).** Ziel: Protokoll `ObjectStore`, Implementierungen FS und DB (`bytea`/Large Object), S3 (nach F-06 priorisieren), Tabelle `files`. Akzeptanz: AK-D1-1 Contract-Test gegen alle Backends (put/get/exists/delete, Hash-Prüfung, Streaming ohne Vollpuffern bei 1 GiB synthetisch, Speicherverbrauch begrenzt); D1-2 `put` mit falschem Hash scheitert; D1-3 gleiche Bytes → eine Speicherung (Dedup); D1-4 FS-Backend nur mit Konfigurationswarnung bei Replikas>1 (Test der Konfigurationsprüfung). Test: S3 gegen lokalen Garage/MinIO in Testprofil (Docker), sonst übersprungen mit Ausgabe. Abh.: K0. **P**.
*Status WP-D1: Protokoll, FS, DB, `files` fertig und getestet (Branch wp-D1); S3 offen, siehe `docs/handoff/WP-D1.md`.*

**WP-D2 DMS-Kern (L).** Ziel: Tabellen `dms_*` (Dokument, Dateien, Typ, Tag/Gruppe, Pfad, Felder, Papierkorb), Upload-Route, Audit, Events, Berechtigungen (`MODUL-DMS.md` Abschnitte 3, 4.1, 7, 9). Akzeptanz: AK-D1 (Modul gesamt, Upload), AK-D8, Papierkorb/Restore, ASN-Vergabe atomar (AK-D7), Original per DB-Constraint unveränderlich (AK-D-REV-1), Mandantentrennung. Test wie genannt, plus Zwei-Instanzen-Upload. Abh.: K3, K5, D1.
*Status WP-D2: AK-D1 (Upload, ohne Event), AK-D7, AK-D8, AK-D-REV-1, Papierkorb/Restore, Mandantentrennung, Rechte je Route, Zwei-Instanzen-Upload umgesetzt und getestet (Branch wp-D2); offen: Events (K7), `purge`, Versionen, Archiv-/Thumbnail-Erzeugung (O2), siehe `docs/handoff/WP-D2.md`.*

## Phase 2 – OCR und Suche

**WP-O1 Ingest-Automat und Worker-Befehl (M).** Ziel: `dms_ingest_items` mit Zustandsautomat, `jobs.priority` (Migration, Expand-Regel), `App worker --kinds …`, Graceful Shutdown gibt Leases frei (`JobService.release`), Lease-Erneuerung. Akzeptanz: AK-O1-1 jeder Zustandsübergang idempotent (Wiederholung ohne Effekt); O1-2 Kill -9 eines Workers → Job nach Lease-Ablauf von anderem; O1-3 Poison-Job nach 3 Versuchen `failed_permanent`; O1-4 SIGTERM gibt Lease frei. Test: Mehrprozess-Test mit zwei Worker-Prozessen/Verbindungen. Abh.: D2.

**WP-O2 OCR (L).** Ziel: Job `dms.ocr` (`MODUL-DMS.md` 5.2, ADR 0006), Textextraktion, `dms_document_texts`, Archivversion, Worker-Image. Entscheidung F-07 nötig (Empfehlung Tesseract/ocrmypdf). Akzeptanz: AK-O2-1 synthetisches Scan-PDF (selbst erzeugte Bilder mit bekanntem Text) → Text enthält Soll-Wörter (Wortfehlerrate ≤ Schwelle, Schwelle im Test festlegen); O2-2 PDF mit Textschicht ohne OCR extrahiert; O2-3 Original bleibt byte-identisch; O2-4 Zeit-/Speicherlimit greift (Bombentest); O2-5 Worker schreibt nicht außerhalb `tmpfs` (Test mit read-only Root im Container); O2-6 AK-D2 (zwei Worker, genau einmal). Abh.: O1.

*Status WP-O2: umgesetzt und getestet (Branch wp-O2): Job `dms.ocr`, Textschicht ohne OCR, ocrmypdf/Tesseract (deu, eng) mit PDF/A-2b-Archivversion, Zeit-/Seiten-/Speicherlimit, `GET …/documents/{id}/processing`, `ingest_item_id` in der Upload-Antwort, `Dockerfile.worker`, Compose-Dienst `worker` (Swarm nur Syntax); AK-O2-1…6 siehe `docs/handoff/WP-O2.md`. F-07/F-21 nach Empfehlung als Annahme umgesetzt (Nutzerbestätigung offen).*

**WP-S1 Suche (M).** `MODUL-DMS.md` Abschnitt 6, ADR 0005. Akzeptanz: AK-S1-1 Wortstamm („Rechnung“↔„Rechnungen“); S1-2 Tippfehler per Trigram; S1-3 Phrase/Operatoren (`websearch_to_tsquery`); S1-4 Filter + Facetten; S1-5 Mandant/Berechtigung je Treffer; S1-6 Qualitätskorpus (200 synthetische Texte) Recall@10-Schwelle, Ergebnis dokumentiert; S1-7 Antwortzeit bei 100 000 synthetischen Dokumenten dokumentiert (kein hartes Ziel, Messwert in ADR 0005 nachtragen). Abh.: D2. **P** F1.
*Status WP-S1: AK-S1-1…7 umgesetzt und getestet (Branch wp-S1); Messlauf S1-7 nur mit `LH_SEARCH_PERF=1`, Messwerte in ADR 0005; offen: OCR-Text (O2), Objektfreigaben je Treffer (grants), Text-Tippfehler, siehe `docs/handoff/WP-S1.md`.*

**WP-S2 Globale Suche (M).** Kern `search_documents`, `SearchIndexing`-Protokoll, Endpunkt `GET /search`. Akzeptanz: Kontakte und DMS-Dokumente in einer Trefferliste, Treffer ohne Berechtigung fehlen, deaktiviertes Modul fehlt. Abh.: S1, K3.

## Phase 3 – PWA und DMS-UI

**WP-F1 PWA-Gerüst (M).** `FRONTEND.md` Abschnitte 2, 3, 5, 12: Projekt anlegen, shadcn-Basis, Login/Passkey, Guard, API-Client, i18n de/en, Mock-Backend, Build ins Backend-Image. Akzeptanz: AK-F1-1 `npm run check`/`test` grün; F1-2 E2E: Einladung → Passkey → Dashboard gegen echtes Backend; F1-3 `npm run build` erzeugt statisches Bundle, Backend liefert `/` und Deep-Link-Fallback; F1-4 i18n-Vollständigkeitstest. Abh.: K1, K4.

*Status WP-F1: AK-F1-1…4 umgesetzt und getestet (Branch wp-F1); Backend-Auslieferung und Dockerfile-Stufe sind nur als Vorschlag im Handoff, siehe `docs/handoff/WP-F1.md`.*

**WP-F2 Modulnavigation (M).** AK-F2-1…3 (`FRONTEND.md` 4), Mandantenwechsel, Einstellungsseiten (Profil, Passkeys, Sitzungen, Module). Abh.: F1, K3.
*Status WP-F2: umgesetzt und getestet (Branch wp-F2): Modulnavigation, Mandantenwechsel, Einstellungen (Profil, Passkeys, Recovery-Codes, Sitzungen, Module, Mitglieder/Einladungen), Platzhalter `/dms`; siehe `docs/handoff/WP-F2.md`.*

**WP-F3 PWA/Offline (M).** AK siehe `FRONTEND.md` Abschnitt 7; Manifest, Icons, Service Worker, Update-Hinweis. Test: Playwright-PWA-Lauf. Abh.: F1.

**WP-F4 DMS-UI (L).** Upload (Dropzone, Fortschritt), Liste + Suche + Filter, Detail + Vorschau, Metadaten bearbeiten, Papierkorb. Akzeptanz: AK-F4-1 E2E Upload → Verarbeitung abgeschlossen → Treffer in Suche; F4-2 a11y (axe) ohne serious/critical; F4-3 Tastaturbedienung der Liste; F4-4 Fehlerzustände (Quarantäne, Duplikat) sichtbar. Abh.: F2, D2, S1.

*Status WP-F4: AK-F4-1…4 gegen das Mock-Backend umgesetzt und getestet (Branch wp-F4), E2E gegen das echte Backend nicht gelaufen; offen: Verarbeitungs-/Quarantänestatus (Backend-Route fehlt, O2), Datumsfilter/Facetten ohne Suchbegriff, siehe `docs/handoff/WP-F4.md`.*

*Status WP-F4b: PWA auf Verarbeitungsstatus (`…/processing`, `…/processing/retry`), Durchsuchen über `…/search`, `storage_quota_exceeded`/`upload_interrupted` umgestellt; Mock-E2E und Vitest grün; echter E2E (`npm run test:e2e:dms`, echtes Backend + OCR-Worker im Container) belegt Upload bis Papierkorb, aber nur mit einem lokalen, nicht committeten Backend-Patch: `GET /tenants/{tenant}` liefert keine Modulberechtigungen (`dms.*`), die PWA zeigt allen Rollen „Berechtigung fehlt“. Siehe `docs/handoff/WP-F4b.md`.*

**WP-D3 Regeln und Vorschläge (L).** `MODUL-DMS.md` 5.4, Tabellen `dms_rules`, `dms_suggestions`, `dms_duplicates`; Kontakt-Matching. Akzeptanz: AK-D5, deterministische Vorschläge, Trockenlauf, Regex-Zeitlimit-Test, Duplikat-Stufen 1–2. Abh.: O2, S1.
*Status WP-D3: umgesetzt und getestet (Branch wp-D3): Regeln (CRUD, Bedingungen Text/Regex/Absender/Dateiname/Quelle, Priorität, Version), Trockenlauf, Vorschläge mit Begründung und Konfidenz (Annehmen/Ablehnen, Audit), Kontakt-Matching (IBAN, USt-ID, Alias, Name), `auto` nur je Regel ausdrücklich, Duplikate Stufe 1 (Hash) und 2 (Text-Hash, Shingles, pg_trgm-Titel); Migration `dms_020_rules`; AK-D3-1…13 siehe `docs/handoff/WP-D3.md`. Offen: Extraktionskandidaten Betrag/IBAN/Rechnungsnummer, Tippfehler im Kontakt-Matching, Regeln für Mail-Absender erst mit D4.*

**WP-D4 Quellen (L).** Mail-Ingest (IMAP-Polling mit Lease), Konsumordner (Stabilitätsprüfung), Share-/Scan-API. Akzeptanz: AK-D3 plus Mail-Test gegen lokalen Test-IMAP-Server (Docker, synthetische Mails); Geheimnisse nie in DB/Log. Abh.: O1. Offen: F-22.
*Status WP-D4: umgesetzt und getestet (Branch wp-D4; Migrationen `dms_022_sources` und Kern `020_api_tokens`): Mail-Ingest per IMAP-Polling (implizites TLS, eigener schlanker Client, Passwort AES-256-GCM mit `SECRET_KEY`, Job-Kette `dms.mail.poll` mit Lease, Idempotenz über Message-ID + Anhang-Hash, Absender für `sender_contains`, Mail danach gelesen/verschoben, nie gelöscht), Konsumordner (`dms.folder.scan`, Stabilitätsprüfung über zwei Messungen, `processed/`/`failed/`, Worker-Volume pro Mandant), Share-/Scan-API mit persönlichem API-Token (Minimalstand F-05, Scope `dms.upload`), Quellen-Verwaltung (`dms.source.*`, Test-Verbindung, letzter Lauf); Mail-Tests gegen GreenMail in Docker; Worker-Deploy mit allen fünf Job-Arten (Compose real getestet, Swarm nur Syntax). Offen: SSRF-Beschränkung (nur `DMS_MAIL_HOST_ALLOWLIST`), STARTTLS/OAuth2, PWA-Seiten, Neuverschlüsselung bei Schlüsselwechsel, F-22 SMB/FTP-Brücke; siehe `docs/handoff/WP-D4.md`.

**WP-D5 Revisionssicherheit (M).** `MODUL-DMS.md` Abschnitt 8: AK-D-REV-1…4, Prüf-Job, Export-Job (ZIP + Index + Manifest). Abh.: D2.
*Status WP-D5: umgesetzt und getestet (Branch wp-D5; Migration `dms_021_revision`): Aufbewahrung je Dokumenttyp (konfigurierbar, GoBD-orientiert, keine Konformitätszusage), Löschsperre, Purge nur aus Papierkorb nach Frist/ohne Sperre/ohne Verknüpfung mit Löschprotokoll und Blob-Referenzprüfung, Hash-Kette des DMS-Audits (F-16), Prüf-Job `dms.verify`, Export-Job `dms.export` (ZIP + index.csv + manifest.json mit SHA-256), 231 Tests grün; offen: Deploy der Worker-Arten, Zeitplaner, Alarmkanal; siehe `docs/handoff/WP-D5.md`.*

**WP-D7 Dokumenterkennung (L).** Allgemeiner, deterministischer Extraktor (Detektoren je Dokumentart, voll ausgebaut `invoice`, einfach `reminder` und Stichwortarten, Fallback `other`), Fakten mit Fundstelle/Konfidenz/Begründung, Tabelle `dms_extractions`, Vorschläge (nie still angewendet), Felder in Liste/Details/Filter/Sortierung, `DocumentFacts` + Outbox für spätere Module; Mail-Original (.eml), Anhänge verknüpft, HTML-Text im Index. Abh.: D3, D4.
*Status WP-D7: umgesetzt (Branch wp-D7, Handoff `docs/handoff/WP-D7.md`, Migration `dms_024_extraction`): AK-D7-1…17, Korpus mit 42 synthetischen Fällen (Precision 1,0, Recall 1,0 für „Rechnung“). Offen: Hervorhebung/UI (PWA), Rechnungsmodul-Anbindung (X1) über `DocumentFacts`, HTML-zu-PDF-Rendern (spätere Option).*

**WP-D6 Paperless-Import (M).** `MODUL-DMS.md` Abschnitt 10, AK-D9, nur synthetische Fixture. Abh.: D2, D3. Offen: F-23.
*Status WP-D6: umgesetzt (Branch wp-D6, Handoff `docs/handoff/WP-D6.md`): Export-Verzeichnis (D6a) und REST-API (D6b) mit Trockenlauf/Bericht, idempotent und fortsetzbar, Abbruch, ASN über `ensureAtLeast`, Worker-Job `dms.import.paperless` mit Lease; synthetische Fixture + Mock-API. Nicht gegen eine echte Instanz verifiziert, F-23 wie vorgeschlagen umgesetzt (Annahme bis Bestätigung).*

**WP-F5 DMS-UI vertiefen (M).** Prüf-Warteschlange mit Vorschlägen, Regeln mit Trockenlauf, Tag-Pflege/Merge, Quellen, Papierkorb/Löschkonzept, Export. Abh.: F4, D3, D5.
*Status WP-F5: umgesetzt (Branch wp-F5, Handoff `docs/handoff/WP-F5.md`): Prüf-Warteschlange (Tastatur, Stale-Hinweis), Regeln mit Trockenlauf, Duplikate, Stammdaten, Papierkorb/Löschkonzept mit Purge-Bestätigung, Integritätsprüfung, Export; Mock-E2E und echter E2E (Regel -> Scan -> Vorschlag -> annehmen) grün. Quellen-Verwaltung (D4) nicht gebaut; Tag-Merge, Neu-Klassifikation und Zeitplan haben keine Backend-Route. Befund: Migration `dms_021` scheitert bei einer einzelnen, nicht-privilegierten Datenbankrolle nach `018_audit_hardening`.*

**WP-F5b DMS-UI Quellen und API-Tokens (S).** Quellen-Verwaltung (Mail/IMAP, Konsumordner) mit Verbindungstest, letztem Lauf, Fehlercodes; API-Tokens (einmalige Anzeige, Widerruf); Seite „Scanner einrichten“; Dashboard-Karte „Verarbeitung“. Abh.: F5, D4.
*Status WP-F5b: umgesetzt (Branch wp-F5b, Handoff `docs/handoff/WP-F5b.md`); Befunde und fehlende Routen siehe Handoff.*

**WP-F4c Dokumentübersicht und Eingang (M).** Eigene tabellarische Übersicht für alle Dokumentarten (Art, Betrag, Fälligkeit, Referenz, Status; Presets, Filter, Sortierung, Suche), Detail mit erkannten Fakten und Mail-Vorschau, Eingangsansicht, gegliederte Seitenleiste für die ganze Shell. Abh.: F4, F5, F5b, D7.
*Status WP-F4c: umgesetzt (Branch wp-F4c, Handoff `docs/handoff/WP-F4c.md`); fehlende Backend-Felder siehe Handoff.*

## Phase 4 – Rechnungsmodul

(Details `MODUL-RECHNUNG.md`. Vollständigkeit ohne App: Belege erstellen/bearbeiten/finalisieren, Nummern, PDF, E-Rechnung, Zahlungen, Berichte. Entscheidungen F-08/F-27/F-31 neu bewertet, F-09/F-26 offen.)

**WP-R0 Spike Rechenkern (S–M).** Ziel: Rechenkern der bisherigen App (mit Nummernformat, Berichten und E-Rechnung ohne Rendering) unter Linux bauen und testen; bei Erfolg Auslagerung in gemeinsames SwiftPM-Repo planen, sonst Neuimplementierung gegen Testvektoren. Akzeptanz: dokumentiertes Ergebnis (Ja/Nein, nötige Änderungen) in `MODUL-RECHNUNG.md`; gemeinsame synthetische Testvektoren (JSON). Teststrategie: Docker `swift:6.2` Build der Pakete. Abh.: K0. **P**.
*Status WP-R0: abgeschlossen; 50 synthetische Testvektoren; siehe `MODUL-RECHNUNG.md` Abschnitt 12 und `docs/handoff/WP-R0.md`. F-27 entschieden (07.11.2026): Neuimplementierung gegen die Vektoren.*

**WP-R1 Stammdaten (M).** Einstellungen, Steuerzeiträume, Serien, Belegtypen, Artikel. Mandantentrennung/Rechte. Abh.: K3, K5, R0.
*Status WP-R1: umgesetzt (Modul `invoice`: Einstellungen/Absender, Steuerzeiträume, Belegtypen, Nummernserien über den Kernzähler, Artikel; Details und Annahmen `MODUL-RECHNUNG.md` Abschnitt 13 und `docs/handoff/WP-R1.md`). Nächster Schritt: WP-R2 (Belege, Finalisieren).*

**WP-R2 Belege und Finalisieren (L).** Entwurf CRUD, Positionen, Berechnung (Konformität mit Testvektoren), Zustandsautomat, Finalisieren mit Hub-Zähler; Invarianten per DB (`MODUL-RECHNUNG.md` Abschnitte 2, 4). Akzeptanz: AK-R4 (50 parallele Finalisierungen, zwei Instanzen), Final unveränderlich (SQL-Test), Idempotenz. Abh.: R1, K6.
*Status WP-R2: umgesetzt (Rechenkern gegen die Testvektoren, Beleg-Entwurf CRUD mit Serversummen, Finalisieren mit Hub-Zähler in einer Transaktion, Unveränderlichkeit per Trigger, AK-R4 mit 50 parallelen Finalisierungen über zwei Instanzen; Details `MODUL-RECHNUNG.md` Abschnitt 14 und `docs/handoff/WP-R2.md`). Nächste Schritte: R3 (Zahlungen, Gutschrift), R5, R6a.*

**WP-R3 Zahlungen, Gutschrift, Umwandlung (M).** Skonto, Zuordnung nie still, Verknüpfungen Beleg↔Beleg. Abh.: R2.
*Status WP-R3: umgesetzt (Zahlungen mit Skonto, Zuordnung nur nach Bestätigung, Gutschrift, Umwandlung, Verknüpfungen, Salden gegen die Testvektoren, E2E über HTTP gegen Postgres; Details `MODUL-RECHNUNG.md` Abschnitt 15 und `docs/handoff/WP-R3.md`). Skontoregeln sind Annahme (F-32). Nächste Schritte: R4, R5, R6a, danach Bankimport (R3b), R7.*

**WP-R4 Import/Export der bisherigen App (M).** `MODUL-RECHNUNG.md` Abschnitt 8; Format nach F-09. Akzeptanz: Fixture-Import identisch, idempotent, Zähler gesetzt. Abh.: R2.

**WP-R5 E-Rechnung (M).** Erzeugung CII/XRechnung aus finalem Beleg; Validierung nach F-26. Abh.: R2.

**WP-R6a Spike Renderer (M).** Ziel: Entscheidungsgrundlage F-08: Optionen (a) Swift-Portierung des App-Renderers mit Swift-PDF-Bibliothek, (b) HTML/CSS + headless Chromium, (c) Typst-Pipeline. Akzeptanz: je Option dieselben 5 synthetischen Layouts (Briefkopf, Positionstabelle, mehrseitig, Summenblock, Fußzeile) → PDF; Vergleich Treue (Seitenzahl, Textpositionen ±Toleranz, extrahierter Text), Determinismus, Laufzeit, Image-Größe, Lizenz, PDF/A-3-Fähigkeit; Ergebnis als ADR 0008 (vorgeschlagen). Abh.: R0. **P**.

**WP-R6 Server-Renderer und Layout-Engine (L).** Linux-tauglicher Renderer als Worker-Job (`invoice.render`, Lease wie ADR 0006), Layoutmodell (Import vorhandener Layouts), Platzhalter, Seitenumbruch, Standardlayouts. Akzeptanz: Referenz-Layoutfälle aus R6a bestehen mit festgelegter Toleranz; Finalisieren speichert PDF + Layoutversion + Inhalt-Hash (nie neu erzeugt); zwei Worker erzeugen genau ein PDF je Beleg. Abh.: R6a, R2.

**WP-R7 Ausgaben und Berichte (L).** EÜR/USt serverseitig, Vergleich mit Referenzwerten der bisherigen App (synthetische Fälle). Abh.: R3.

**WP-F6 Rechnungs-UI (L).** Kontakte, Artikel, Belegliste/-editor mit Live-Summenvorschau, Finalisieren, PDF-Vorschau/-Download, E-Rechnung, Zahlungen, Berichte (EÜR/USt). Akzeptanz: E2E ohne App: Beleg anlegen → finalisieren → Nummer → PDF → Zahlung → Bericht. Abh.: F2, R2, R6.

**WP-F7 Layout-Verwaltung und Designer (L).** `FRONTEND.md` Abschnitt 13: Layoutliste, Import, Parameter, Vorschau; grafischer Designer nach Teilung in F7a (Verwaltung) und F7b (Designer) planen. Abh.: F6, R6.

## Phase 5 – Verknüpfung

**WP-X1 Beleg↔Dokument (M).** `MODUL-RECHNUNG.md` 9, `MODUL-DMS.md` 11: Events `invoice.document.finalized` → DMS-Ablage; Eingangsrechnung-Vorschlag; Steuerberater-Export; Löschsperre verknüpfter Dokumente. Akzeptanz: Ende-zu-Ende-Test (E2E Playwright): Rechnung finalisieren → Dokument im DMS verlinkt, Wiederholung erzeugt kein zweites; Eingangsrechnung per Upload → Vorschlag → Ausgabe. Abh.: D5, R3.

## Phase 6 – Hardening

**WP-H1 Lizenzen (M).** `docs/LIZENZEN.md` (Inventar nach Vorbild `timetrack-backend/docs/LIZENZEN.md`), SBOM, Prüfergebnis aus WP-K0 und F-03 umsetzen, Lizenzprüfung als Skript. Akzeptanz: jede Abhängigkeit mit SPDX-Eintrag; Befund BoringSSL dokumentiert mit gewählter Lösung. **P** ab Phase 0. **Stand 20.11.2026:** BoringSSL-Teil fertig (`swift-nio-ssl` 2.37.6, `legal/` im Image, `scripts/check-third-party-notices.sh`); SPDX-Inventar und SBOM (`legal/sbom/lab-hub.cdx.json`, `scripts/generate-sbom.mjs --check` in `ci.sh`) für SwiftPM und npm fertig, Image-Pakete (OS/Toolchain) nicht erfasst.

**WP-H2 Backup/Restore (M).** Skripte `deploy/backup.sh`, `restore.sh`; konsistentes Paar DB + ObjectStore; Restore-Test in frischer Umgebung mit Hash-Prüfung aller Dateien. Akzeptanz: automatischer Restore-Test in Docker, Abweichung = Fehlschlag.

**WP-H3 Datenschutz (M).** Auskunftsexport je Kontakt/Mandant, Löschablauf mit Aufbewahrungsprüfung, Löschung aus Suchindex. Abh.: K5, D5.

**WP-H4 Update-/Swarm-Test (M).** Echter Swarm (nicht auf geteiltem Docker-Host): 2 Backend- + 2 Worker-Repliken, rollierendes Update mit Schemaänderung (Expand/Contract), Rollback, `/ready`-Verhalten, Job-Lease beim Verschieben. Akzeptanz: dokumentierter Lauf in `deploy/README.md`, keine verlorene Anfrage/Job.

**WP-H5 Last/Skalierung (M).** Messen: Suche bei 100 000 Dokumenten, OCR-Durchsatz mit n Workern, Upload großer Dateien; Messwerte in `docs/`.

## Phase 7 – Struktur (Abgleich Timetrack)

Grundlage: `docs/ARCHITEKTUR-ABGLEICH-TIMETRACK.md` (25.11.2026). Timetrack ist Strukturidee, kein Code wird kopiert. PWA offline/installierbar bleibt **WP-F3**.

**WP-ST1 GitHub-CI (S).** Akzeptanz: AK-ST1-1 Push/PR startet Backend-Tests gegen Postgres 17 (übersprungene Tests werden sichtbar, ein Lauf ohne Datenbanktests ist rot); ST1-2 PWA `check`, Unit-Tests, Mock-E2E, Vertragsprüfung; ST1-3 Actions auf Commit gepinnt, keine Secrets, kein Image-Push, kein Release; ST1-4 Lauf auf `main` grün.

**WP-ST2 Kern entkoppeln (M).** Akzeptanz: AK-ST2-1 Module liefern Job-Handler über `HubModule`, `WorkerCommand` nennt kein `DMS*`; ST2-2 Token-Scopes deklarieren die Module; ST2-3 Link-Schutz als Haken des Moduls, `LinkService` und `ApiTokens` ohne `DMS*`; ST2-4 Test, der `DMS`/`Invoice`-Bezeichner außerhalb von `Modules/<Name>` und der Modulliste verbietet; volle Suite unverändert grün.

**WP-ST3 Swift-Targets (M).** F-14 (Nutzer 07.11.2026: spätestens vor dem zweiten Modul). Akzeptanz: AK-ST3-1 `HubCore`, `HubModuleDMS`, `HubModuleInvoice`, Zusammenbau in `HubKit`/`App`; ST3-2 Module importieren einander nicht (Package-Manifest erzwingt es); ST3-3 Images, SBOM und Tests grün. Abh.: ST2.

**WP-ST4 PWA Darstellung (S).** Akzeptanz: AK-ST4-1 Standard folgt `prefers-color-scheme`, Wahl System/Hell/Dunkel bleibt je Gerät; ST4-2 kein Aufblitzen der falschen Farbe beim Laden (mit der CSP aus H9 verträglich); ST4-3 Playwright-Bilder und axe-Kontrast für Kernseiten hell und dunkel, angesehen.

**WP-ST5 PWA Grundbausteine (M).** Akzeptanz: AK-ST5-1 einheitliche Fehlerbeschreibung je Problem-Code; ST5-2 Prüfung von `/api/version` mit Hinweis bei unpassendem Stand; ST5-3 Betreiber schaltet Module in der Oberfläche (nur Betreiberrecht, Test erlaubt/verboten).

**WP-ST6 PWA-Namen (S).** Nutzer 25.11.2026: Die PWA heißt „LAB hub“, die Module „docs“, „invoice“ usw. Akzeptanz: AK-ST6-1 Titel, App-Name und Recovery-Datei zeigen „LAB hub“ (Manifest in WP-F3 übernimmt den Namen); ST6-2 Modulüberschriften in de und en „docs“ bzw. „invoice“, interne Schlüssel und Routen (`dms`, `invoice`) unverändert; ST6-3 Tests angepasst, Bilder hell und dunkel angesehen.

**WP-ST7 PWA-Redesign (M).** Nutzer 26.11.2026: Oberfläche nach dem Vorbild TimeTrack, Akzentfarbe je Benutzer; vor der Abnahme prüft eine nicht bauende Sitzung die Bilder (hell/dunkel, Handy/Computer). Akzeptanz: AK-ST7-1 Akzent im Konto je Benutzer, zwei Instanzen sehen denselben Stand; ST7-2 nur `#rgb`/`#rrggbb`; ST7-3 Schrift auf Fläche, Hover und Tinte ≥ 4,5:1 für jede Farbe; ST7-4 Zwischenspeicher je Benutzer; ST7-5 E2E: eigene Farbe je Benutzer über Neuladen und Anmeldung; ST7-6 bei 390 px kein seitliches Scrollen. Migration `022_user_accent`.

## Phase 8 – Scan-Bridge

Grundlage: `docs/SCAN-BRIDGE.md`.

**WP-BR1 Hub-Seite (M).** Akzeptanz: AK-BR1-1 Tabellen und Routen laut Abschnitt 3 im Vertrag; BR1-2 zwei Verbindungen übernehmen einen Auftrag genau einmal, Lease über `now()`, Ablauf ⇒ `failed` ohne Wiederholung, spätes Ergebnis derselben Bridge möglich; BR1-3 Mandantentrennung, Rechte, falscher Scope; BR1-4 Upload mit `Idempotency-Key: scan-<job>` erzeugt ein Dokument.

**WP-BR2 Bridge-Dienst (L).** Akzeptanz: AK-BR2-1 Verfügbarkeit von SANE-`test`-Backend und sane-airscan im gewählten Basis-Image belegt, Versionen und Lizenzen in `docs/LIZENZEN.md`; BR2-2 E2E Hub + Bridge-Container + `test`-Gerät: mehrseitiger Scan wird Dokument; BR2-3 eSCL-Attrappe über festen Eintrag; BR2-4 Parameter nur aus Positivliste, kein Shell-Aufruf; BR2-5 Upload-Abbruch und Neustart ohne Verlust und ohne Doppel; BR2-6 Image amd64 und arm64 lokal gebaut (kein Push ohne vom Nutzer festgelegtes Ziel).

**WP-BR3 PWA Scannen (M).** Akzeptanz: AK-BR3-1 Gerät, Quelle, Auflösung, Farbe wählen; starten, nächste Seite, fertig, abbrechen; BR3-2 Zustände und Fehler verständlich, Bridge offline sichtbar; BR3-3 Playwright gegen echten Hub und Bridge, Bilder hell und dunkel angesehen.

**WP-BR4 Betrieb (M).** Akzeptanz: AK-BR4-1 Anleitung und Compose-Beispiel (feste Geräte, Host-Netz); BR4-2 Lizenztexte und Quellenhinweis im Image, SBOM; BR4-3 optionaler Ordner-Eingang: nur stabile Dateien, genau ein Dokument, Verschieben nach Erfolg (nur nach Entscheidung F-22).

## Phase 9 – Paperless-Ablösung

Grundlage und Reihenfolge: `docs/PAPERLESS-ABLOESUNG.md`. Private Bestandsdaten gelangen nie in Repo oder Modellkontext.

**WP-PA1 Import verifizieren (M).** Akzeptanz: AK-PA1-1 lokale paperless-ngx-Instanz im Container mit erfundenen Dokumenten (Skript, Version festgehalten, kein GPL-Code im Repo); PA1-2 Import aus Export **und** API vergleicht Anzahlen und Hashes, Abweichungen als Tests (rot, dann behoben); PA1-3 Sicherheitsprüfung D6 (SSRF, TLS, Pfade, Transaktion), Befunde behoben oder dokumentiert; PA1-4 API-Weg (F-34) mit einem Benutzer nur mit Leserechten: Anzahlen entsprechen dem für ihn Sichtbaren, fehlende Rechte ergeben einen klaren Befund; PA1-5 API-Version fest angefragt (`Accept: …; version=`) und gegen die geprüfte Paperless-Version getestet; PA1-6 Prüfsummen über die API belegt (falls die Quelle sie liefert) oder im Bericht als fehlend ausgewiesen, mit Weg zur Gegenprüfung; PA1-7 gespeichertes Token wird gelöscht, sobald der Lauf beendet ist (fertig, fehlgeschlagen, abgebrochen); PA1-8 Dokumente mit mehreren Fassungen: übernommen oder im Bericht gezählt.

**WP-PA2 Import in der PWA (M).** Akzeptanz: AK-PA2-1 Quelle wählen, Trockenlauf, Fortschritt, Abbruch, Bericht; Adresse und Token trägt der Nutzer hier ein (Passwortfeld, ohne Speichern im Browser), das Token wird nie wieder angezeigt oder protokolliert; PA2-2 Notizen am Dokument sichtbar; PA2-3 E2E gegen echtes Backend, Bilder hell und dunkel.

**WP-PA3 Probelauf (S, Nutzer).** Weg entschieden (F-34, 25.11.2026): API-Token nur zum Lesen, vom Nutzer selbst im Hub eingetragen. Start erst nach PA1 und PA2. Akzeptanz: AK-PA3-1 Anleitung (eigener Paperless-Benutzer nur mit Leserechten, Netz- und Zertifikatsvoraussetzungen, Token widerrufen) ohne Datenweitergabe; PA3-2 Trockenlauf-Zahlen und Befundcodes liegen vor, Anzahl Dokumente mit Paperless verglichen; PA3-3 genutzte Eingangswege und Funktionen aufgelistet, Lücken eingestuft.

**WP-PA4 Miniaturen (M).** Akzeptanz: AK-PA4-1 Worker erzeugt Rolle `thumbnail`, Quota und Zeitlimit; PA4-2 Nachlauf für Bestand, fortsetzbar; PA4-3 Liste hell/dunkel, ohne Recht kein Zugriff.

**WP-PA5 Ansichten und Massenbearbeitung (L).** Akzeptanz: AK-PA5-1 gespeicherte Ansichten je Nutzer/Mandant; PA5-2 Mehrfachauswahl mit Typ, Tags, Korrespondent, Papierkorb, mit `rev`-Konflikten je Dokument und Audit; PA5-3 E2E.

**WP-PA6 Lücken aus dem Probelauf (M–L).** Umfang erst nach PA3; je Lücke eigenes Akzeptanzkriterium.

**WP-PA7 Betriebsreife (M).** Akzeptanz: AK-PA7-1 Anleitung Zielrechner inkl. Platzbedarf; PA7-2 Restore mit großem synthetischem Bestand gemessen; PA7-3 Prüflauf periodisch ohne Hand (zustandslos), alte Export-ZIPs nach Frist entfernt; Zwei-Instanzen-Test.

**WP-PA8 Umschalten (M, Nutzer).** Akzeptanz: Abschnitt 6 der Ablösungsplanung.

## Phase 10 – Native Modul-Apps und Hub-Voraussetzungen

Grundlage: `docs/APP-DMS.md`. Je Modul eine eigene native App, an den Hub anbindbar (Nutzer 25.11.2026); „docs“ zuerst. Kein Hub-WP darf eine App voraussetzen. Die APP-Meilensteine liegen außerhalb dieses Repositorys (Aufteilung: APP-M0).

**WP-AB1 Geräteanmeldung (M).** Akzeptanz: AK-AB1-1 Anmeldung über System-Browser, Einmalcode mit PKCE gegen Gerätetoken; AB1-2 Scopes, Mandantenbindung, Widerruf wirkt sofort, Liste in der PWA; AB1-3 abgefangener oder zweiter Code scheitert; Zwei-Instanzen-Test; AB1-4 jede Modul-App erhält ein eigenes Token, begrenzt auf ihr Modul (Test: Token der „docs“-App erreicht keine Rechnungsrouten).

**WP-AB2 Änderungs-Feed (M).** Akzeptanz: AK-AB2-1 „Änderungen seit Cursor“ inkl. Löschungen, rechte- und mandantengefiltert; AB2-2 keine verlorene Änderung bei gleichzeitigen Schreibern (Zwei-Verbindungen-Test).

**WP-AB3 Fassungen (M).** Akzeptanz: AK-AB3-1 Upload einer abgeleiteten Datei, Original unverändert; AB3-2 Quota, Audit, Löschkonzept erfasst sie.

**APP-M0 bis APP-M7 (App „docs“).** Inhalt und „Fertig, wenn“ je Meilenstein: `docs/APP-DMS.md` Abschnitt 9; Integrationen je Meilenstein Abschnitt 5.

**WP-APP-I0 App „invoice“ (S, Konzept).** Annahme: Die vorhandene Rechnungs-App (Bestandsprodukt) wird die native App des Moduls. Akzeptanz: AK-APP-I0-1 Konzept für das Anbinden an den Hub (Anmeldung und gemeinsame Pakete aus `APP-DMS.md` Abschnitt 7, Betrieb mit und ohne Hub, Übernahme der Daten über R4); AK-APP-I0-2 nötige Hub-WPs benannt; kein Eingriff in das App-Repository ohne Absprache.

## Pflege dieser Datei

Beim Start eines WP: Status auf „in Arbeit“ mit Agent/Branch. Beim Abschluss: „fertig (Commit)“, Übergabevermerk (Stand, ausgeführte Tests, offene Punkte, nächster Schritt) direkt unter dem WP. Neue WPs mit Nummer fortlaufend je Präfix ergänzen, nie umnummerieren.

## Security-Review 07.11.2026 (WP-H6)

Statischer Review (Skill `security-audit`) von K1, K2, K3, K4, K5, D1, D2: keine kritischen, hohen oder mittleren Befunde, alle WPs pass. Offene Punkte für WP-H6: (1) D2 Upload: Mandanten-Quota, Idempotency-Key vor `store.put` reservieren oder GC für unreferenzierte Blobs (`DMSUpload.swift`); (2) K5/D2: `ContactService.exists` um `merged_into IS NULL` ergänzen, damit nach einem Merge keine Links auf den Quellkontakt entstehen; (3) K4: Idempotency-Middleware hasht bei Stream-Routen den Body nicht, vor Einsatz auf Stream-Routen Inhalts-Hash ergänzen; (4) K1: Rate-Limit nutzt `remoteAddress`, Trusted-Proxy-Konfiguration fehlt; (5) K1: DB-Rolle darf Audit-Trigger evtl. deaktivieren (Rollenverteilung/REVOKE im Betrieb klären). Kein Review der PWA (F1).

## Ideen aus Vergleich mit „haben“ (17.11.2026, Planung)

Quelle: Funktionsvergleich (Codex-Review, extern). „haben“ steht unter AGPL-3.0: nur Funktionsideen eigenständig umsetzen, keinen Code, keine Vorlagen, Texte oder Testdaten übernehmen. Nutzerhinweis: Strom sparen, Builds/Tests/Docker/Simulator nur nachts 22–6 Uhr.

| Idee | Bezug | Anmerkung |
| --- | --- | --- |
| Durchgängiger Weg Beleg → Rechnung → Zahlung; jede Kennzahl bis zum Beleg aufklappbar | R2, R3, R7, X1 | R7-API liefert Herkunftsposten und Rechenweg; `Decimal`/`numeric` |
| Bankimport CAMT/CSV mit begründeten Zuordnungsvorschlägen (nie still zuordnen) | neu nach R3 (R3b) | dedupliziert, lokal, Bestätigung durch Nutzer |
| Server-PDF mit Livevorschau; Typst im R6a-Spike ernsthaft prüfen (Layouttreue, PDF/A-3, Reproduzierbarkeit, isolierter Kindprozess ohne Netz) | R6a, R6, F6, F7 | Entscheidung erst nach Spike |
| CSV-Import mit Spaltenzuordnung, Trockenlauf, Fehlerbericht (zuerst Kontakte) | neu (K-Import) | ergänzt D6 |
| Globale Schnellsuche und Befehlspalette, Tastaturführung | S2, F2 | |
| Serienrechnungen, Mahnworkflow | nach R3 | Jobs/Leases, idempotent |
| Backup mit regelmäßigem Test-Restore (DB, Objekte, Schlüssel) | H2 | |
| Jahresabgleich nach Fremdimport | R4, R7 | später |

Offen (an Nutzer): Reihenfolge nach Rechnungskern – Bankimport vor oder nach Server-PDF? Annahme bis dahin: R2 → R6a-Spike → R3 → Bankimport → R7.

**Swarm-Zuschnitt (Prüfung):** Zwei Anwendungsservices (Backend inkl. PWA, Worker) mit externem PostgreSQL passen zur Architektur (ADR 0003; `deploy/swarm/stack.yaml` hat bereits diesen Zuschnitt, Migration als einmaliger Job). Mit PostgreSQL als drittem Service wären es drei; ein Einzelservice bräuchte eine gesondert zu prüfende Web+Worker-Zusammenlegung. Realer Swarm-Test bleibt H4 (offen).
