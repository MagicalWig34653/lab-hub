# Roadmap und Arbeitspakete

Status: Entwurf, Stand 01.11.2026. Reihenfolge: Kern → DMS M1 → OCR/Suche → PWA + DMS-UI → Rechnungsmodul → Verknüpfung → Hardening. Aufwand: S ≈ 1 Agent-Session, M ≈ 2–4, L ≈ 5+ (Schätzungen, keine Zusage). **P** = parallelisierbar mit den genannten WPs (kein gemeinsamer Dateibesitz: Migrationen und `contracts/openapi.yaml` nur von einem Agent zugleich ändern, `AGENTS.md` Abschnitt 7).

Statusspalte pflegen: `offen` · `in Arbeit (Agent/Branch)` · `fertig (Commit)`. Jedes WP erfüllt die Definition of Done aus `AGENTS.md` Abschnitt 8; sie wird unten nicht wiederholt. Testkennungen `AK-<WP>-<n>`.

Ausgangsstand (vorhanden, getestet laut `deploy/README.md`/Tests): `migrate`, `schema_version`, `counters`/`CounterService`, `idempotency_keys`/`IdempotencyService`, `jobs`/`JobService` (Lease), `/health`, `/ready`, `HubConfig`, Deploy-Skripte (Compose real getestet, Swarm ungetestet).

## Übersicht

| Phase | WP | Titel | Abh. | Größe | Parallel | Status |
| --- | --- | --- | --- | --- | --- | --- |
| 0 Kern | K0 | Baseline: Build/Test verifizieren, CI-Skript | – | S | P zu allen | fertig (Baseline); F-03 offen |
| | K1 | Auth: Nutzer, Passkeys, Sitzungen, Einladung, Audit | K0 | L | P K4, D1 | offen |
| | K2 | Mandanten, Mitgliedschaft, Rollen, Berechtigungen | K1 | M | | erledigt (Branch wp-K2, Handoff docs/handoff/WP-K2.md) |
| | K3 | Modul-System (`HubModule`, Aktivierung, Guard) | K2 | M | P K4, K6 | erledigt (Branch wp-K3, Handoff docs/handoff/WP-K3.md) |
| | K4 | OpenAPI-Vertrag, Fehlerformat, Pagination, Vertragstest | K0 | M | P K1, D1 | erledigt (Branch wp-K4, Handoff docs/handoff/WP-K4.md) |
| | K5 | Kontakte und `links` | K2, K4 | M | P K6, K7 | umgesetzt (Branch wp-K5, `docs/handoff/WP-K5.md`) |
| | K6 | Zähler-Erweiterung (transaktional, Schlüsselraum) | K0 | S | P K3, K5 | umgesetzt (Branch wp-K6, `docs/handoff/WP-K6.md`) |
| | K7 | Events/Outbox, Webhooks | K3 | M | P K5 | offen |
| 1 DMS M1 | D1 | ObjectStore (FS, DB, S3), `files`, Hash | K0 | M | P K1, K4 | offen |
| | D2 | DMS-Kern: Dokumente, Upload, Stammdaten, Papierkorb | K3, K5, D1 | L | | umgesetzt (Branch wp-D2, `docs/handoff/WP-D2.md`) |
| 2 OCR/Suche | O1 | Job-Erweiterung, Ingest-Zustandsautomat, Worker-Befehl | D2 | M | | offen |
| | O2 | OCR-Worker, Textspeicherung, Archivversion | O1 | L | P S1 (Teil) | offen |
| | S1 | DMS-Suche (tsvector, pg_trgm, Filter) | D2 (O2 für OCR-Text) | M | P F1 | offen |
| | S2 | Globale Suche im Kern | S1, K3 | M | P F2 | offen |
| 3 PWA | F1 | PWA-Gerüst, Login, Shell | K1, K4 | M | P D2, S1 | erledigt (Branch wp-F1, Handoff docs/handoff/WP-F1.md) |
| | F2 | Modul-Navigation, Mandantenwechsel, Einstellungen | F1, K3 | M | P S2 | offen |
| | F3 | Service Worker, Offline-Shell, Update | F1 | M | P F2, F4 | offen |
| | F4 | DMS-UI: Upload, Liste, Detail, Suche | F2, D2, S1 | L | P F3 | offen |
| 3b DMS vertiefen | D3 | Regeln, Vorschläge, Kontakt-Matching, Duplikate | O2, S1 | L | P F4 | offen |
| | D4 | Quellen: Mail-Ingest, Konsumordner, Share-API | O1 | L | P D3 | offen |
| | D5 | Revisionssicherheit: Löschkonzept, Prüf-Job, Export | D2 | M | P D3, D4 | offen |
| | D6 | Paperless-Import | D2, D3 | M | P D5 | offen |
| | F5 | DMS-UI: Prüfen, Regeln, Stammdaten, Papierkorb | F4, D3, D5 | M | | offen |
| 4 Rechnung | R0 | Spike: Linux-Build Rechenkern, Testvektoren | K0 | S | P ab Phase 0 | umgesetzt (Branch wp-R0, `docs/handoff/WP-R0.md`) |
| | R1 | Stammdaten Rechnung | K3, K5, R0 | M | | offen |
| | R2 | Belege, Berechnung, Finalisieren mit Hub-Zähler | R1, K6 | L | | offen |
| | R3 | Zahlungen, Gutschrift, Umwandlung | R2 | M | | offen |
| | R4 | Taxlab-Import/Export | R2 | M | P R3 | offen |
| | R5 | E-Rechnung Erzeugung (Server) | R2 | M | P R3, R4 | offen |
| | R6a | Spike Renderer: Optionen (a)/(b)/(c) gegen Referenz-PDFs | R0 | M | P R1, R2 | offen |
| | R6 | Server-Renderer und Layout-Engine (Pflicht, Linux) | R6a, R2 | L | | offen |
| | R7 | Ausgaben, EÜR/USt-Berichte | R3 | L | | offen |
| | F6 | Rechnungs-UI (erstellen, bearbeiten, finalisieren, PDF, Zahlungen, Berichte) | F2, R2, R6 | L | P R3.. | offen |
| | F7 | Layout-Verwaltung und Designer in der PWA | F6, R6 | L | | offen |
| 5 Verknüpfung | X1 | Beleg↔Dokument, Events, Steuerberater-Export | D5, R3 | M | | offen |
| 6 Hardening | H1 | Lizenzen (BoringSSL), SBOM, Abhängigkeitsprüfung | K0 | M | P ab Phase 0 | offen |
| | H2 | Backup/Restore mit Hash-Verifikation | D2 | M | | offen |
| | H3 | Datenschutz: Export/Löschung je Kontakt/Mandant | K5, D5 | M | | offen |
| | H4 | Update-/Swarm-Test real (Repliken, Rolling, Rollback) | K3, O2 | M | | offen |
| | H5 | Last-/Skalierungstest (Suche, OCR-Backlog) | S1, O2 | M | | offen |
| | H6 | Befunde Security-Review 07.11.2026 (Quota/Waisen-Blobs, merged_into-Prüfung, Idempotency-Hash bei Streams, Rate-Limit hinter Proxy, Audit-Trigger-Rechte) | O1, S1 | S | | offen |

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

**WP-S1 Suche (M).** `MODUL-DMS.md` Abschnitt 6, ADR 0005. Akzeptanz: AK-S1-1 Wortstamm („Rechnung“↔„Rechnungen“); S1-2 Tippfehler per Trigram; S1-3 Phrase/Operatoren (`websearch_to_tsquery`); S1-4 Filter + Facetten; S1-5 Mandant/Berechtigung je Treffer; S1-6 Qualitätskorpus (200 synthetische Texte) Recall@10-Schwelle, Ergebnis dokumentiert; S1-7 Antwortzeit bei 100 000 synthetischen Dokumenten dokumentiert (kein hartes Ziel, Messwert in ADR 0005 nachtragen). Abh.: D2. **P** F1.

**WP-S2 Globale Suche (M).** Kern `search_documents`, `SearchIndexing`-Protokoll, Endpunkt `GET /search`. Akzeptanz: Kontakte und DMS-Dokumente in einer Trefferliste, Treffer ohne Berechtigung fehlen, deaktiviertes Modul fehlt. Abh.: S1, K3.

## Phase 3 – PWA und DMS-UI

**WP-F1 PWA-Gerüst (M).** `FRONTEND.md` Abschnitte 2, 3, 5, 12: Projekt anlegen, shadcn-Basis, Login/Passkey, Guard, API-Client, i18n de/en, Mock-Backend, Build ins Backend-Image. Akzeptanz: AK-F1-1 `npm run check`/`test` grün; F1-2 E2E: Einladung → Passkey → Dashboard gegen echtes Backend; F1-3 `npm run build` erzeugt statisches Bundle, Backend liefert `/` und Deep-Link-Fallback; F1-4 i18n-Vollständigkeitstest. Abh.: K1, K4.

*Status WP-F1: AK-F1-1…4 umgesetzt und getestet (Branch wp-F1); Backend-Auslieferung und Dockerfile-Stufe sind nur als Vorschlag im Handoff, siehe `docs/handoff/WP-F1.md`.*

**WP-F2 Modulnavigation (M).** AK-F2-1…3 (`FRONTEND.md` 4), Mandantenwechsel, Einstellungsseiten (Profil, Passkeys, Sitzungen, Module). Abh.: F1, K3.
*Status WP-F2: umgesetzt und getestet (Branch wp-F2): Modulnavigation, Mandantenwechsel, Einstellungen (Profil, Passkeys, Recovery-Codes, Sitzungen, Module, Mitglieder/Einladungen), Platzhalter `/dms`; siehe `docs/handoff/WP-F2.md`.*

**WP-F3 PWA/Offline (M).** AK siehe `FRONTEND.md` Abschnitt 7; Manifest, Icons, Service Worker, Update-Hinweis. Test: Playwright-PWA-Lauf. Abh.: F1.

**WP-F4 DMS-UI (L).** Upload (Dropzone, Fortschritt), Liste + Suche + Filter, Detail + Vorschau, Metadaten bearbeiten, Papierkorb. Akzeptanz: AK-F4-1 E2E Upload → Verarbeitung abgeschlossen → Treffer in Suche; F4-2 a11y (axe) ohne serious/critical; F4-3 Tastaturbedienung der Liste; F4-4 Fehlerzustände (Quarantäne, Duplikat) sichtbar. Abh.: F2, D2, S1.

**WP-D3 Regeln und Vorschläge (L).** `MODUL-DMS.md` 5.4, Tabellen `dms_rules`, `dms_suggestions`, `dms_duplicates`; Kontakt-Matching. Akzeptanz: AK-D5, deterministische Vorschläge, Trockenlauf, Regex-Zeitlimit-Test, Duplikat-Stufen 1–2. Abh.: O2, S1.

**WP-D4 Quellen (L).** Mail-Ingest (IMAP-Polling mit Lease), Konsumordner (Stabilitätsprüfung), Share-/Scan-API. Akzeptanz: AK-D3 plus Mail-Test gegen lokalen Test-IMAP-Server (Docker, synthetische Mails); Geheimnisse nie in DB/Log. Abh.: O1. Offen: F-22.

**WP-D5 Revisionssicherheit (M).** `MODUL-DMS.md` Abschnitt 8: AK-D-REV-1…4, Prüf-Job, Export-Job (ZIP + Index + Manifest). Abh.: D2.

**WP-D6 Paperless-Import (M).** `MODUL-DMS.md` Abschnitt 10, AK-D9, nur synthetische Fixture. Abh.: D2, D3. Offen: F-23.

**WP-F5 DMS-UI vertiefen (M).** Prüf-Warteschlange mit Vorschlägen, Regeln mit Trockenlauf, Tag-Pflege/Merge, Quellen, Papierkorb/Löschkonzept, Export. Abh.: F4, D3, D5.

## Phase 4 – Rechnungsmodul

(Details `MODUL-RECHNUNG.md`. Vollständigkeit ohne App: Belege erstellen/bearbeiten/finalisieren, Nummern, PDF, E-Rechnung, Zahlungen, Berichte. Entscheidungen F-08/F-27/F-31 neu bewertet, F-09/F-26 offen.)

**WP-R0 Spike Rechenkern (S–M).** Ziel: `TaxlabCore`/`TaxlabModel` (+ Nummernformat, `TaxlabReports`, E-Rechnung ohne Rendering) unter Linux bauen und testen; bei Erfolg Auslagerung in gemeinsames SwiftPM-Repo planen, sonst Neuimplementierung gegen Testvektoren. Akzeptanz: dokumentiertes Ergebnis (Ja/Nein, nötige Änderungen) in `MODUL-RECHNUNG.md`; gemeinsame Testvektoren (JSON) aus taxlab-Tests abgeleitet (synthetisch). Teststrategie: Docker `swift:6.2` Build der Pakete. Abh.: K0. **P**.
*Status WP-R0: Ja für Core/Model (unverändert Linux-tauglich, 53 + 135 Tests grün), teilweise für Reports/E-Rechnung; 50 Testvektoren; siehe `MODUL-RECHNUNG.md` Abschnitt 12 und `docs/handoff/WP-R0.md`. Entscheidung F-27 offen.*

**WP-R1 Stammdaten (M).** Einstellungen, Steuerzeiträume, Serien, Belegtypen, Artikel. Mandantentrennung/Rechte. Abh.: K3, K5, R0.

**WP-R2 Belege und Finalisieren (L).** Entwurf CRUD, Positionen, Berechnung (Konformität mit Testvektoren), Zustandsautomat, Finalisieren mit Hub-Zähler; Invarianten per DB (`MODUL-RECHNUNG.md` Abschnitte 2, 4). Akzeptanz: AK-R4 (50 parallele Finalisierungen, zwei Instanzen), Final unveränderlich (SQL-Test), Idempotenz. Abh.: R1, K6.

**WP-R3 Zahlungen, Gutschrift, Umwandlung (M).** Skonto, Zuordnung nie still, Verknüpfungen Beleg↔Beleg. Abh.: R2.

**WP-R4 Taxlab-Import/Export (M).** `MODUL-RECHNUNG.md` Abschnitt 8; Format nach F-09. Akzeptanz: Fixture-Import identisch, idempotent, Zähler gesetzt. Abh.: R2.

**WP-R5 E-Rechnung (M).** Erzeugung CII/XRechnung aus finalem Beleg; Validierung nach F-26. Abh.: R2.

**WP-R6a Spike Renderer (M).** Ziel: Entscheidungsgrundlage F-08: Optionen (a) Swift-Portierung `TaxlabLayout`/`TaxlabRender` mit Swift-PDF-Bibliothek, (b) HTML/CSS + headless Chromium, (c) Typst-Pipeline. Akzeptanz: je Option dieselben 5 synthetischen Layouts (Briefkopf, Positionstabelle, mehrseitig, Summenblock, Fußzeile; Vorbild `tools/layoutcheck` in taxlab) → PDF; Vergleich Treue (Seitenzahl, Textpositionen ±Toleranz, extrahierter Text), Determinismus, Laufzeit, Image-Größe, Lizenz, PDF/A-3-Fähigkeit; Ergebnis als ADR 0008 (vorgeschlagen). Abh.: R0. **P**.

**WP-R6 Server-Renderer und Layout-Engine (L).** Linux-tauglicher Renderer als Worker-Job (`invoice.render`, Lease wie ADR 0006), Layoutmodell (Import des Taxlab-/Totals-Layoutformats nach `IMPORT-ADAPTER.md`/`LAYOUT-DESIGNER.md`), Platzhalter, Seitenumbruch, Standardlayouts. Akzeptanz: Referenz-Layoutfälle aus R6a bestehen mit festgelegter Toleranz; Finalisieren speichert PDF + Layoutversion + Inhalt-Hash (nie neu erzeugt); zwei Worker erzeugen genau ein PDF je Beleg. Abh.: R6a, R2.

**WP-R7 Ausgaben und Berichte (L).** EÜR/USt serverseitig, Vergleich mit Referenzwerten aus taxlab (synthetische Fälle). Abh.: R3.

**WP-F6 Rechnungs-UI (L).** Kontakte, Artikel, Belegliste/-editor mit Live-Summenvorschau, Finalisieren, PDF-Vorschau/-Download, E-Rechnung, Zahlungen, Berichte (EÜR/USt). Akzeptanz: E2E ohne App: Beleg anlegen → finalisieren → Nummer → PDF → Zahlung → Bericht. Abh.: F2, R2, R6.

**WP-F7 Layout-Verwaltung und Designer (L).** `FRONTEND.md` Abschnitt 13: Layoutliste, Import, Parameter, Vorschau; grafischer Designer nach Teilung in F7a (Verwaltung) und F7b (Designer) planen. Abh.: F6, R6.

## Phase 5 – Verknüpfung

**WP-X1 Beleg↔Dokument (M).** `MODUL-RECHNUNG.md` 9, `MODUL-DMS.md` 11: Events `invoice.document.finalized` → DMS-Ablage; Eingangsrechnung-Vorschlag; Steuerberater-Export; Löschsperre verknüpfter Dokumente. Akzeptanz: Ende-zu-Ende-Test (E2E Playwright): Rechnung finalisieren → Dokument im DMS verlinkt, Wiederholung erzeugt kein zweites; Eingangsrechnung per Upload → Vorschlag → Ausgabe. Abh.: D5, R3.

## Phase 6 – Hardening

**WP-H1 Lizenzen (M).** `docs/LIZENZEN.md` (Inventar nach Vorbild `timetrack-backend/docs/LIZENZEN.md`), SBOM, Prüfergebnis aus WP-K0 und F-03 umsetzen, Lizenzprüfung als Skript. Akzeptanz: jede Abhängigkeit mit SPDX-Eintrag; Befund BoringSSL dokumentiert mit gewählter Lösung. **P** ab Phase 0.

**WP-H2 Backup/Restore (M).** Skripte `deploy/backup.sh`, `restore.sh`; konsistentes Paar DB + ObjectStore; Restore-Test in frischer Umgebung mit Hash-Prüfung aller Dateien. Akzeptanz: automatischer Restore-Test in Docker, Abweichung = Fehlschlag.

**WP-H3 Datenschutz (M).** Auskunftsexport je Kontakt/Mandant, Löschablauf mit Aufbewahrungsprüfung, Löschung aus Suchindex. Abh.: K5, D5.

**WP-H4 Update-/Swarm-Test (M).** Echter Swarm (nicht auf geteiltem Docker-Host): 2 Backend- + 2 Worker-Repliken, rollierendes Update mit Schemaänderung (Expand/Contract), Rollback, `/ready`-Verhalten, Job-Lease beim Verschieben. Akzeptanz: dokumentierter Lauf in `deploy/README.md`, keine verlorene Anfrage/Job.

**WP-H5 Last/Skalierung (M).** Messen: Suche bei 100 000 Dokumenten, OCR-Durchsatz mit n Workern, Upload großer Dateien; Messwerte in `docs/`.

## Pflege dieser Datei

Beim Start eines WP: Status auf „in Arbeit“ mit Agent/Branch. Beim Abschluss: „fertig (Commit)“, Übergabevermerk (Stand, ausgeführte Tests, offene Punkte, nächster Schritt) direkt unter dem WP. Neue WPs mit Nummer fortlaufend je Präfix ergänzen, nie umnummerieren.

## Security-Review 07.11.2026 (WP-H6)

Statischer Review (Skill `security-audit`) von K1, K2, K3, K4, K5, D1, D2: keine kritischen, hohen oder mittleren Befunde, alle WPs pass. Offene Punkte für WP-H6: (1) D2 Upload: Mandanten-Quota, Idempotency-Key vor `store.put` reservieren oder GC für unreferenzierte Blobs (`DMSUpload.swift`); (2) K5/D2: `ContactService.exists` um `merged_into IS NULL` ergänzen, damit nach einem Merge keine Links auf den Quellkontakt entstehen; (3) K4: Idempotency-Middleware hasht bei Stream-Routen den Body nicht, vor Einsatz auf Stream-Routen Inhalts-Hash ergänzen; (4) K1: Rate-Limit nutzt `remoteAddress`, Trusted-Proxy-Konfiguration fehlt; (5) K1: DB-Rolle darf Audit-Trigger evtl. deaktivieren (Rollenverteilung/REVOKE im Betrieb klären). Kein Review der PWA (F1).
