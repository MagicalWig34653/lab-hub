# Modul DMS (Dokumentenmanagement) – Entwurf

Status: Entwurf, Stand 01.11.2026. Modulschlüssel `dms`. Rahmen: `ARCHITEKTUR.md` (Kern, Modul-System, API-Stil), `decisions/0005-dms-suche-postgres.md`, `decisions/0006-ocr-job-queue.md`. Offene Entscheidungen: `OFFENE-FRAGEN.md` (F-xx).

**Quellenlage Paperless-ngx.** Aussagen über Paperless-ngx stammen aus Allgemeinwissen (keine Recherche, kein Quellcode gelesen); Unsicheres ist mit **(zu verifizieren)** markiert. Paperless-ngx steht unter GPL-3.0: Es werden nur Funktionen als Vorbild genommen, kein Code/Text/Testdaten (`AGENTS.md` Abschnitt 6). Kein UI-Klon; Bedienkonzept entsteht in `FRONTEND.md`.

## 1. Paperless-ngx: Struktur und Einschränkungen

Struktur (Kurzfassung):
- **Dokument** = Metadaten + Datei: Original (unverändert abgelegt) + optionale Archivversion (per OCRmyPDF erzeugtes, durchsuchbares PDF/A) + Thumbnail + Textinhalt.
- Zuordnungen: **Korrespondent**, **Dokumenttyp**, **Tags** (n:m), **Speicherpfad** (Vorlage für Ablagepfad/Dateiname), **benutzerdefinierte Felder** (typisiert), **Archiv-Seriennummer (ASN)**, Erstellungsdatum.
- **Matching** von Korrespondent/Typ/Tag/Speicherpfad: Algorithmen „kein, beliebiges Wort, alle Wörter, exakte Phrase, Regex, unscharf, automatisch (trainiertes Klassifikationsmodell)“ (zu verifizieren: genaue Liste).
- **Eingang**: Konsumordner (Dateiüberwachung), Web-Upload, REST-API, Mail-Regeln (IMAP-Postfächer), Barcode/ASN-Trennseiten.
- **Verarbeitung**: asynchrone Aufgaben (Celery mit Redis (zu verifizieren: Standard)), OCR, Volltextindex (Whoosh in älteren Versionen, neuere evtl. Tantivy – zu verifizieren), Klassifikation.
- **Workflows** (Trigger: Konsum, hinzugefügt, geändert, zeitgesteuert; Aktionen: Zuweisen, Entfernen, Webhook, E-Mail) – Details zu verifizieren.
- **Berechtigungen**: Besitzer + Ansicht/Änderung je Benutzer/Gruppe (Objektrechte), Superuser.
- Weiteres: gespeicherte Ansichten, Freigabelinks, Papierkorb (neuere Versionen), Mehrbenutzer, Dokumentenhistorie/Audit (neuere Versionen, zu verifizieren).

## 2. Problem → Ursache → Lösung im Hub

Die Spalte „Problem“ beschreibt bekannte Reibungspunkte typischer Paperless-Installationen (aus Erfahrungswissen, nicht belegt; zu verifizieren, bevor sie als Fakt zitiert werden).

| # | Problem | Vermutete Ursache | Lösung im Hub |
| --- | --- | --- | --- |
| P1 | **Tag-Wildwuchs**: hunderte Tags, Dubletten, unklare Bedeutung | Tags sind die einzige freie Ordnungsachse; Matching legt automatisch neue Zuordnungen an | Feste Achsen statt Tag-Sammelbecken: Korrespondent (= Kern-Kontakt), Dokumenttyp, Speicherpfad/Ablage, typisierte Felder. Tags bleiben, aber mit **Tag-Gruppen** (Namensraum, optional „exklusiv“), Pflege-Ansicht (unbenutzt, ähnlich = Merge-Vorschlag per `pg_trgm`), Merge mit Audit. Automatik legt **nie** neue Tags an, nur Vorschläge für vorhandene |
| P2 | **Matching-Regeln greifen falsch** (Wort kommt zufällig vor, Regex zu breit) | Regel wirkt direkt und still; keine Vorschau, keine Erklärung | Regeln erzeugen zunächst **Vorschläge mit Begründung** (`dms_suggestions`: Regel, Treffertext-Auszug, Konfidenz). Automatische Anwendung nur je Regel freigegeben („auto“ erst nach N bestätigten Vorschlägen **[Annahme]**). Regel-Vorschau gegen vorhandene Dokumente (Trefferliste, Trockenlauf) vor Aktivierung. Priorität und „erste Regel gewinnt“ explizit, Regelversion im Audit |
| P3 | **Skalierung OCR/Index im Single-Container** (OCR blockiert CPU, ein Worker, Redis nötig) | Task-Queue und Worker im selben Container, Zustand in Redis/Dateisystem | OCR als **Datenbank-Job mit Lease** (ADR 0006): beliebig viele Worker-Repliken, kein Redis, Absturz = Lease läuft ab, Job neu. OCR-Worker als eigener Service/Image, Index in Postgres (kein separater Indexprozess, ADR 0005). Priorität, Retry mit Backoff, Poison-Quarantäne nach N Versuchen |
| P4 | **Dateinamen/Speicherpfad-Chaos** (Pfadvorlagen ändern Dateien nachträglich, Umbenennungen brechen Backups/Verweise) | Dateiname = Funktion der Metadaten, wird bei Änderung neu berechnet | **Entkopplung**: physischer Schlüssel ist inhaltsadressiert (`<tenant>/<sha256…>`), unveränderlich. Speicherpfad ist ein **virtueller** Name (Vorlage), nur für Anzeige, Download und Export. Änderung der Vorlage verändert keine gespeicherten Objekte; Export wendet aktuelle Vorlage an; Namenskollisionen werden mit Suffix aufgelöst (deterministisch) |
| P5 | **Fehlende Beleg-Verknüpfung** (Eingangsrechnung im DMS ist nicht mit Buchung/Zahlung verbunden) | DMS kennt keine Fachobjekte | Kern-Tabelle `links` (Dokument ↔ Eingangsrechnung/Ausgabe/Zahlung/Projekt) mit Quelle und Umkehrbarkeit; Events `dms.document.classified` → Rechnungsmodul schlägt Beleg vor (`MODUL-RECHNUNG.md` Abschnitt 9) |
| P6 | **Schwache Mandantentrennung** (eine Instanz, Objektrechte pro Dokument) | Mandant ist kein Konzept; Trennung nur über Besitzer/Gruppen | `tenant_id` überall, Pfad-Mandant, Rollen je Mandant (ARCHITEKTUR 4.1/4.2), Tests auf fremde IDs; optional Postgres RLS (F-15). Externe (Steuerberater, Kunde) über `grants` je Objekt oder Sicht |
| P7 | **Konsumordner-Races** (Datei noch im Kopiervorgang, doppelte Verarbeitung, Verlust bei Absturz) | Dateisystem-Ereignisse, Verarbeitung nicht atomar mit Verschieben | Konsumordner nur als **Quelle** mit Stabilitätsprüfung (Größe+mtime unverändert über 2 Zyklen, Mindestalter), Verarbeitung: lesen → SHA-256 → Upload in den Objektspeicher + `dms_ingest_items` (unique `(tenant, source, sha256, name, mtime)`) in **einer** DB-Transaktion → erst danach Quelldatei nach `.done/` verschieben. Absturz dazwischen = Wiederholung, Duplikat per Hash harmlos (idempotent). Poller hält Lease je Quelle (nur eine Instanz). Empfohlen: Upload per HTTP/Mail statt gemountetem Ordner, siehe Abschnitt 4 |
| P8 | **Löschen ohne Revisionssicherheit** (Löschen entfernt Datei und Metadaten, kein Nachweis) | Papierkorb/Hard-Delete ohne Aufbewahrungslogik | Originale unveränderlich; „Löschen“ = **Soft-Delete** mit Grund, Audit; Hard-Delete nur über Löschkonzept (Abschnitt 8): Aufbewahrungsfrist je Typ, `legal_hold`, Vier-Augen-Option, Löschprotokoll mit Hash des gelöschten Objekts |
| P9 | **Duplikate** (gleiche Datei mehrfach, gleiche Rechnung als Scan und Mail) | Nur Prüfsumme der Datei, keine inhaltliche Erkennung | Stufe 1 Hash (exakt); Stufe 2 Text-Ähnlichkeit (normalisierter Text-Hash + `pg_trgm`-Ähnlichkeit + Schlüsselfelder Absender/Datum/Betrag); Treffer = Warnung mit Gegenüberstellung, nie stilles Verwerfen |
| P10 | **ASN-Handhabung** (Seriennummer von Hand/Barcode, Lücken, Kollisionen bei parallelem Import) | Zähler nicht atomar | ASN aus Hub-Zähler `dms.asn` (atomar, `CounterService`), Vergabe beim Übergang in „archiviert“; Lücken sind dokumentiert, nicht still |
| P11 | **KI/ML-Klassifikation als Blackbox** | Modell trainiert lokal, schwer erklärbar | Regelbasiert zuerst (erklärbar); KI nur optional, mit Freigabe je Kunde, immer als Vorschlag mit Begründung (Abschnitt 5.4) |
| P12 | **Einzelner Speicherort** (Dateisystem im Container) | Dateien im Containervolume | `ObjectStore`-Abstraktion (FS/S3/DB), Backup konsistent mit DB, Hash-Prüfung beim Restore |

## 3. Datenmodell

Alle Tabellen mit Präfix `dms_`, `tenant_id uuid NOT NULL` (außer Kerntabellen anders bezeichnet), Primärschlüssel `uuid`. Kern-Tabellen aus `ARCHITEKTUR.md`: `contacts`, `files`, `links`, `audit_log`, `search_documents`, `counters`, `jobs`, `events`.

```
files (Kern)  1 ── n  dms_document_files  n ── 1  dms_documents  n ── 1  contacts (Korrespondent)
                                              │  n ── 1 dms_document_types
                                              │  n ── 1 dms_storage_paths
                                              ├─ n ── n dms_tags            (dms_document_tags)
                                              ├─ 1 ── n dms_document_fields ── 1 dms_custom_fields
                                              ├─ 1 ── n dms_document_texts  (Revisionen des extrahierten Textes)
                                              ├─ 1 ── n dms_suggestions
                                              └─ n ── n links (Kern)        (Rechnung, Zahlung, Projekt …)
dms_sources 1 ── n dms_ingest_items ── 0..1 dms_documents
dms_rules 1 ── n dms_suggestions
```

| Tabelle | Wichtige Spalten / Regeln |
| --- | --- |
| `dms_documents` | (Stand D2: `status` nur `processing`/`needs_review`/`archived`; Papierkorb ist `trashed_at` mit Pflichtgrund, der Status bleibt erhalten; Korrespondent über Kern-`links` kind `correspondent`, kein Fremdschlüssel-Feld; Verweise mandantensicher per `(tenant_id, id)`) `id`, `title`, `doc_date` (Belegdatum), `received_at`, `document_type_id`, `correspondent_id` → `contacts`, `storage_path_id`, `asn bigint` (unique je Mandant, teilweise Index `WHERE asn IS NOT NULL`), `status` (`processing`,`needs_review`,`archived`,`trashed`), `source_id`, `retention_until date`, `legal_hold bool`, `trashed_at`, `trashed_by`, `trash_reason`, `created_by`, `created_at`, `rev int` (optimistische Sperre). Kein physisches Löschen im Normalbetrieb |
| `dms_document_files` | `document_id`, `role` (`original`,`archive`,`thumbnail`,`derivative`), `file_id` → `files`, `mime`, `page_count`, `sha256` (Kopie für Prüfung), `created_at`. **Unique** `(document_id) WHERE role='original'`; Trigger/Constraint verbietet UPDATE/DELETE auf `role='original'` (Test). Zweite Fassung eines Originals = neues Dokument oder neue Version (`dms_document_versions`, F-21 offen) |
| `files` (Kern) | `id`, `tenant_id`, `sha256`, `size`, `mime`, `store_key`, `created_at`; unique `(tenant_id, sha256)` (Deduplizierung der Bytes) |
| `dms_document_texts` | `document_id`, `version`, `engine` (`pdf_text`,`tesseract`,`vision`…), `lang`, `text`, `quality real`, `tsv tsvector` (generierte Spalte), `created_at`. Neuere Version ersetzt nicht, wird ergänzt; aktuelle = höchste `version` |
| `dms_document_types` | `name`, `description`, `default_retention_years`, `default_storage_path_id`, `code` (stabil, für Regeln/Export) |
| `dms_tags` | `name`, `group_id` → `dms_tag_groups(id, name, exclusive bool)`, `color`, `deprecated_at`, `merged_into` |
| `dms_document_tags` | `(document_id, tag_id)`, `source` (`manual`,`rule`,`suggestion`), `assigned_by`, `assigned_at` |
| `dms_storage_paths` | `name`, `template` (z. B. `{doc_date:yyyy}/{type}/{correspondent}/{title}`), `slug_rules` |
| `dms_custom_fields` | `name`, `code`, `data_type` (`string`,`int`,`decimal`,`date`,`bool`,`select`,`contact`), `options jsonb`, Beträge als `decimal` |
| `dms_document_fields` | `(document_id, field_id)`, typisierte Wertspalten (`value_text`, `value_numeric`, `value_date`, `value_bool`), CHECK je Typ |
| `dms_sources` | `kind` (`upload`,`folder`,`mail`,`api`,`share_ext`,`scanner`), `config jsonb` (ohne Geheimnisse; Geheimnis nur als Referenz `secret_ref`), `enabled`, `default_rule_set` |
| `dms_ingest_items` | `source_id`, `origin_ref` (z. B. Mail-Message-ID, Dateiname+mtime), `sha256`, `file_id`, `state`, `error_code`, `attempts`, `document_id`, `received_at`; unique `(tenant_id, source_id, origin_ref, sha256)` |
| `dms_rules` | `name`, `priority`, `enabled`, `mode` (`suggest`,`auto`), `conditions jsonb` (Schema versioniert), `actions jsonb`, `version`, `created_by`; Änderungen im Audit |
| `dms_suggestions` | `document_id`, `kind` (`correspondent`,`type`,`tag`,`field`,`link`,`path`), `value jsonb`, `rule_id` oder `engine`, `confidence`, `evidence jsonb` (Textauszug-Offsets), `state` (`open`,`accepted`,`rejected`), `decided_by`, `decided_at`. Ablehnungen fließen in Regelstatistik |
| `dms_duplicates` | `document_id`, `duplicate_of`, `method` (`sha256`,`text_hash`,`similarity`), `score`, `state` |
| `dms_share_links` | `document_id`, `token_hash`, `expires_at`, `max_views`, `created_by`; kein Klartext-Token in der DB |
| `dms_saved_views` | `user_id`, `name`, `filter jsonb`, `shared bool` |
| `dms_deletion_log` | `document_id`, `sha256_original`, `deleted_at`, `deleted_by`, `reason`, `approved_by`, `retention_checked bool` – bleibt nach Hard-Delete bestehen |

Berechtigungen (Namensraum `dms.*`): `document.read`, `document.create`, `document.update`, `document.trash`, `document.purge`, `document.download_original`, `tag.manage`, `rule.manage`, `source.manage`, `suggestion.decide`, `share.create`, `export.run`. **Stand WP-D2:** umgesetzt sind `document.read|create|update|trash|download_original`, `tag.manage` und `master.manage` (Typen, Pfade, Felder; neu, steht für die übrigen Stammdaten); `member` erhält zusätzlich `download_original`, `accountant` alles außer `purge`/`source.manage`. Die Berechtigungen werden vom Modul `dms` deklariert (K3), nicht mehr im Kernkatalog; das frühere `dms.document.delete` entfällt zugunsten von `document.trash`. **Stand WP-D3:** neu `dms.rule.read` (accountant, member), `dms.rule.manage` (accountant; auch Trockenlauf), `dms.suggestion.read` (accountant, member, tax_advisor), `dms.suggestion.decide` (accountant, member); Duplikate: `document.read` bzw. `document.update` (entscheiden). Standardrollen: `owner` alle; `accountant` ohne `purge`/`source.manage`; `member` lesen+erstellen; `tax_advisor` `document.read` + `export.run` auf freigegebene Sicht; `customer_viewer` nur über `grants`.

## 4. Ingest-Pipeline

```
Quelle ─► ingest_item(received) ─► Datei im ObjectStore (stored) ─► SHA-256, Duplikatprüfung (hashed)
      ─► Textextraktion/OCR-Job (text_extracted) ─► Klassifikation/Regeln (classified)
      ─► needs_review | archived (ASN vergeben) ─► Event dms.document.received / archived
```
Zustände von `dms_ingest_items.state`: `received → stored → hashed → ocr_queued → ocr_done → classified → done`; Fehlerzustände `failed_retryable`, `failed_permanent` (Quarantäne mit `error_code`, sichtbar in der UI, manuell wiederholbar). Jeder Übergang ist idempotent (Schlüssel `(ingest_item, state)`).

Quellen:
1. **Upload (Web/API)** – `POST /api/v1/tenants/{t}/dms/uploads` (multipart oder Streaming), `Idempotency-Key` Pflicht, Antwort 202 mit `ingest_item_id`; mehrere Dateien möglich. Erlaubte Typen per Inhalt (Magic Bytes) geprüft, nicht nur Endung; Größenlimit konfigurierbar; Archiv-/ZIP-Entpackung mit Limit (Zip-Bomb-Schutz).
2. **Konsumordner** (`kind=folder`) – nur für Betriebsarten, in denen ein Ordner für Worker erreichbar ist (Einzelhost-Compose oder NFS/Knoten-Label im Swarm). Ablauf siehe P7. **Nicht** Standard; empfohlen werden stattdessen Upload per HTTP/WebDAV-ähnlicher Brücke, Mail oder ein kleiner `hub-ingest`-Client (späteres WP). Scanner mit „Scan to SMB/FTP“ → Brücke nötig (offen, F-22).
3. **Mail** (`kind=mail`) – IMAP-Postfach je Quelle, Polling als Job mit Lease (kein Dauerprozess nötig, **[Annahme]** Intervall 1–5 min; IDLE später). Regeln: Absender/Betreff-Filter, Anhänge extrahieren, optional Mail-Body als PDF (Rendering offen), Verarbeitete Mail wird markiert/verschoben erst nach DB-Commit; `origin_ref` = `Message-ID` + Anhang-Index. Zugangsdaten als Secret-Referenz (Datei `_FILE`), nie in `config`. Empfang per SMTP (eigene Adresse am Hub) ist Alternative mit eigenem Betriebsaufwand (F-22).
4. **Scanner/Share-Extension** – Swift-Apps (iOS Teilen-Menü, Dokumentenscanner/VisionKit) laden per Upload-API hoch; Quelle `share_ext`, Gerätename in `origin_ref`. Optional liefert die App bereits Text (Apple Vision) als `client_text` mit; der Server behandelt ihn als **ungeprüft** (`engine=vision`), OCR auf dem Server läuft trotzdem, wenn F-07 es verlangt.
5. **API** (`kind=api`) – Modulübergreifend: Rechnungsmodul liefert PDF/E-Rechnung ein (`source_module` im Event).

**Umsetzung WP-D4 (Stand 08.11.2026).** Quellen `mail` und `folder` sind Zeilen in `dms_sources` (Migration `dms_022_sources`); jede Quelle ist eine Job-Kette (`dms.mail.poll`, `dms.folder.scan`): der Lauf plant den nächsten selbst ein (Lease, höchstens ein offener Job je Quelle). Mail: IMAP über implizites TLS, eigener schlanker Client (kein Dauerprozess, kein offener Port), Passwort AES-256-GCM-verschlüsselt mit `SECRET_KEY`, Idempotenz je Quelle über `dms_source_items` (Message-ID + Anhang-Hash, Mailtext: Message-ID), Absender in `dms_ingest_items.sender` (Regelbedingung `sender_contains`), Mailtext optional als PDF (`include_body`), Mail danach gelesen/verschoben, nie gelöscht. Konsumordner: Worker-Volume `<DMS_FOLDER_ROOT>/<mandant>/<Pfad>`, Stabilitätsprüfung über zwei Messungen (`dms_folder_observations`), danach `processed/` bzw. `failed/`. Share-/Scan-API: `POST …/dms/share` mit persönlichem Token (Scope `dms.upload`, Minimalstand F-05, Tabelle `api_tokens`). Rechte `dms.source.read|manage` (Buchhaltung, Owner). Details und offene Punkte: `docs/handoff/WP-D4.md`, Betrieb: `deploy/README.md`.

Gemeinsame Regeln: Eingang erzeugt Audit (`dms.ingest.received`), nie ein Dokument ohne Original in `files`. Maximale Parallelität pro Mandant begrenzt (Fairness, Job-Priorität).

## 5. Verarbeitung

### 5.1 Hash und Duplikate
SHA-256 beim Empfang, Streaming (kein Vollpuffern). Exakt gleicher Hash im Mandanten → `dms_duplicates(method=sha256)`, Datei wird nicht erneut gespeichert (Deduplizierung auf `files`), neues Dokument nur nach Bestätigung (Standard: Hinweis „Duplikat von …“, Eingangseintrag bleibt als `done` mit Verweis). Inhaltliche Duplikate nach OCR (5.3).

### 5.2 OCR-Job (ADR 0006)
Job `kind=dms.ocr`, Payload `{ingest_item_id}`; Worker holt per `JobService.claim(owner:leaseSeconds:)` und **verlängert** die Lease periodisch (`renew`), schreibt Ergebnis in einer Transaktion und schließt mit `complete` (nur Besitzer, nur bei gültiger Lease – vorhanden und getestet). Ablauf: Original aus ObjectStore nach `tmpfs` → (a) PDF mit Textschicht: Text direkt extrahieren (`pdftotext`/PDFKit-Äquivalent, Qualität prüfen), sonst (b) Rasterisieren + OCR. Ergebnis: `dms_document_texts` + Archivversion (durchsuchbares PDF, ob PDF/A: F-21). Engine-Entscheidung: F-07 (Empfehlung: `ocrmypdf` + Tesseract im Worker-Image, Sprachen `deu`,`eng`). Zeitlimit je Seite/Dokument, Speicherlimit, Retry max. 3 mit Backoff, danach `failed_permanent`. Der Worker schreibt nie ins Container-Dateisystem außer `tmpfs`.
- Reihenfolge/Priorität: manuelle Uploads vor Massenimport (`run_at`/Priorität – `jobs` braucht dafür eine Spalte `priority`, Migration in WP-O1).
- Original bleibt **unverändert**; OCR erzeugt nur abgeleitete Dateien (`role=archive`).

### 5.3 Textextraktion und Normalisierung
Text Unicode-normalisiert (NFC), Silbentrennung am Zeilenende optional bereinigt (Regel, abschaltbar), Sprache erkannt (Heuristik, F-07). Aus dem Text werden **Extraktionskandidaten** gebildet (Datum, IBAN, USt-ID, Beträge, Rechnungsnummer) mit Offset, als Vorschläge (`dms_suggestions kind=field`), nicht als Wahrheit.

**Dokumenterkennung (WP-D7, umgesetzt).** Der Extraktor (`Modules/DMS/Extraction`) ist für **alle** Dokumente gleich: Detektoren je `DocumentKind` (`invoice`, `receipt`, `contract`, `letter`, `bank_statement`, `insurance`, `tax_notice`, `reminder`, `other`) liefern Score und Begründung, der höchste gewinnt (Schwellen 0,6 sicher, 0,35 unsicher, darunter `other`). Allgemeine Fakten (`facts`): Datum, Fälligkeit/Frist, Beträge mit Währung, IBAN (Prüfsumme), USt-ID (Format), Referenz/Aktenzeichen, Aussteller, Titelvorschlag, jeweils mit Fundstelle (Offset), Konfidenz und Begründung. Voll ausgebaut ist nur `invoice` (Rechnungsnummer, Brutto/Netto/Steuer, Fälligkeit, Verkäufer); `reminder` verhindert, dass eine Mahnung als Rechnung zählt. Neue Art = ein weiterer `DocumentDetector`, keine Schemaänderung. Ergebnis je Dokument in `dms_extractions` (Extraktorversion, `kind`, `facts` als JSON, Übersichtsspalten Betrag, Währung, Belegdatum, Fälligkeit, Referenz für Filter/Sortierung), Vorschläge `source=extraction` (Dokumenttyp, Datum, Titel; Korrespondent weiter über den Kontakt-Abgleich), nichts wird angewendet. Andere Module lesen nur über `DocumentFacts` und das Outbox-Ereignis `dms.document.classified`. Mail: die Mail ist das Original (`.eml`, byte-identisch), Anhänge sind eigene Dokumente mit Link `mail_attachment`, der HTML-Teil ist ein Derivat (nie aktiv ausgeliefert), sein Text steht im Suchindex. Details: `docs/handoff/WP-D7.md`.

### 5.3a Dokumentarten und Fakten (WP-D8)

Alle Arten laufen durch denselben Extraktor (`Modules/DMS/Extraction`); Ergebnis je Dokument in `dms_extractions` (`kind`, `facts` als Liste aus Typ, Wert, Währung, Konfidenz, Begründung, Fundstelle). Keine Schemaänderung: die Liste der Faktentypen ist erweiterbar (Zeichenketten, im Vertrag als Enum geführt). Extraktorversion 2. Alles deterministisch, ohne KI und ohne externe Dienste; jede Art hat einen eigenen `DocumentDetector` mit Score, Begründung je Punkt und Gegenindizien. Auswahl: höchster Score; ab 0,60 sicher, 0,35 bis 0,60 unsicher, darunter `other`. **Keine-Falschpositive-Regel:** Eine Art ohne eigenes Strukturmerkmal (Überschrift/Kennung, bei Behörden zusätzlich Behörde im Briefkopf) wird auf höchstens 0,45 gedeckelt (Behörde ohne Briefkopf 0,3), also lieber unsicher oder `other`.

Konfliktregeln (in `DocumentExtractor.resolve`, jede Deckelung steht in der Begründung): sichere Mahnung deckelt Rechnung auf 0,3; sicheres Behördenschreiben (mit Bescheid-/Aktenzeichen-Kennzeichen) deckelt Mahnung auf 0,5 und Rechnung auf 0,3 („Mahnung des Finanzamts“ bleibt Behördenschreiben); Kassenbon/Kontoauszug mit eigener Überschrift deckeln Rechnung auf 0,3, wenn keine Rechnungsnummer vorkommt; ist Rechnung oder Mahnung sicher, fallen Arten ohne eigene Struktur auf 0,3; ein sicherer Versicherungsschein deckelt Vertrag auf 0,5.

Formate: Beträge als Dezimalzeichenkette mit zwei Nachkommastellen (`1234.56`, nie Gleitkomma; Salden und Erstattungen mit Vorzeichen `-`), Daten `yyyy-MM-dd` (deutsche und englische Formate), Zeitspannen ISO 8601 (`P3M`, `P6W`, `P30D`, `P1Y`), Zahlweise `monthly|quarterly|semiannual|yearly`, `auto_renewal` `true|false`, Laufzeit `indefinite` für unbefristet. Validierung: IBAN mod 97, Steuer-ID Prüfziffer (ISO 7064) und Ziffernregel, Steuernummer Format, USt-ID Format. Ein ungültiger Wert ergibt keinen Fakt.

| Art (`kind`) | Faktentypen (zusätzlich zu den allgemeinen: `date`, `due_date`, `deadline`, `amount`, `iban`, `vat_id`, `seller`, `title`, `reference`) |
| --- | --- |
| `invoice` (D7) | `invoice_number`, `amount_gross`, `amount_net`, `amount_tax`, `due_date` |
| `contract` | `counterparty` (Vertragspartner), `contract_number`, `date` (Vertragsdatum), `period_start`, `period_end`, `term` (ISO-Dauer oder `indefinite`), `notice_period` (ISO-Dauer, Wert und Einheit), `auto_renewal`, `recurring_amount` + `payment_interval` |
| `insurance` | `insurer`, `policy_number`, `premium` + `payment_interval`, `period_start`, `period_end`, `due_date`, `date` |
| `tax_notice` (Finanzverwaltung) und `letter` (sonstige Behörde) | `authority`, `reference` (Aktenzeichen, Steuernummer), `tax_number`, `tax_id`, `date` (Bescheid-/Schreibendatum), `due_date` (Zahlungsfrist), `deadline` (sonstige Frist, z. B. Stellungnahme), `objection_deadline` (Einspruchs-/Widerspruchsfrist; abgeleitete Fristen nur mit Konfidenz 0,5 und Hinweis), `settlement_amount` (positiv = Zahlung an die Behörde, negativ = Erstattung), `notice_type` (`tax_assessment`, `tax_prepayment`, `fee_notice`, `fine`, `hearing`, `summons`, `reminder`, `request`, `notice`) |
| `bank_statement` | `iban`, `period_start`, `period_end`, `balance_opening`, `balance_closing` (Soll = negativ), `date` |
| `receipt` (Kassenbon) | `seller` (Händler), `date`, `amount` (Summe), `amount_tax_7`, `amount_tax_19`, `payment_method` (`cash`, `debit_card`, `credit_card`, `paypal`, `card`) |
| `reminder` (D7) | allgemeine Fakten (Betrag, Bezug, Frist) |

Übersichtsspalten (`amount`, `currency`, `extracted_date`, `due_date`, `reference`, Filter/Sortierung der Dokumentliste) stammen je Art aus dem passenden Fakt: Betrag = Rechnung Brutto, Vertrag `recurring_amount`, Versicherung `premium`, Behörde `settlement_amount`, Kontoauszug `balance_closing`, Kassenbon Summe; Fälligkeit/Frist = Rechnung/Versicherung `due_date`, Vertrag `period_end`, Behörde die früheste von Zahlungs-, Einspruchs- und sonstiger Frist; Referenz = Rechnungs-/Vertrags-/Policennummer, Aktenzeichen, beim Kontoauszug die IBAN. Damit findet `due_to` in der Dokumentliste überfällige Fristen aller Arten. Vorschläge für den Dokumenttyp nutzen weiter `DMSExtraction.typeNames`. Qualität und Grenzen: `docs/handoff/WP-D8.md` (Entwicklungs- und Holdout-Korpus getrennt, Zahlen sind an synthetischen Texten gemessen).

### 5.4 Klassifikation (regelbasiert, optional KI)
1. **Regelbasiert (Standard)**: Bedingungen über Text (Phrase, Wort, Regex mit Zeitlimit, `pg_trgm`-Ähnlichkeit), Absender (Mail), Quelle, Dateiname, extrahierte Felder, Kontakt-Match (USt-ID/IBAN/Name-Ähnlichkeit gegen `contacts`). Aktion: Korrespondent/Typ/Pfad/Tags/Felder/Verknüpfungsvorschlag. Wirkung nach `mode` (`suggest` Standard). Regex mit Sicherheitslimit (kein katastrophales Backtracking: Timeout/Längenlimit).
2. **Optional KI** (Opt-in je Kunde): lokal (Embeddings/Klassifikator auf dem Server, `pgvector` später) oder extern (nur ausdrücklich, mit Anzeige, welche Daten gesendet werden; Mandant/Quelle konfigurierbar; Protokoll in `audit_log`, ohne Inhalt). KI erzeugt ausschließlich Vorschläge mit Begründung; Standard **aus**. Entscheidung F-11.

Akzeptanz: gleiche Eingabe + gleiche Regelversion = gleiche Vorschläge (deterministisch, Test); eine Regel ohne `auto` ändert nie Metadaten ohne Bestätigung.

## 6. Suche (ADR 0005)

- Spalte `dms_document_texts.tsv` = `to_tsvector('german', unaccent(title || ' ' || text))` (generierte Spalte oder Trigger), GIN-Index; Titel/Korrespondent/Tags gewichtet (`setweight` A/B/C). Abfrage `websearch_to_tsquery('german', …)` mit `ts_rank_cd`; Fallback bei wenigen Treffern: `pg_trgm` (`%`/`<->`) auf Titel, Korrespondentenname, Dateiname (Tippfehler). Zweite Konfiguration `english` für Dokumente mit Sprache `en` (je Dokument `lang`, Abfrage kombiniert, **[Annahme]** zwei Konfigurationen reichen).
- Filter (Typ, Korrespondent, Tags, Datum, Felder, ASN, Quelle, Status) als normale Indizes/Joins; Facetten über `GROUP BY` mit Limit.
- Trefferauszug `ts_headline` (begrenzt auf n Zeichen; teuer → nur für die Seite der Ergebnisse).
- Rechteprüfung je Treffer im selben Statement (Mandant + Grants), nie nachgelagert.
- Globale Suche (Kern `search_documents`) bekommt je Dokument einen Eintrag; ACL-Hinweis dient der Vorfilterung, maßgeblich bleibt die Prüfung.
- Später: `pgvector` für „ähnliche Dokumente“ (nur lokal; Embedding-Modell offen).
- Qualitätsprüfung (ADR 0001 „Offen“): 200 synthetische deutsche OCR-Texte mit Rauschen (Zahlendreher, Trennungen), Soll-Treffer pro Anfrage; Recall@10 ≥ 0,9 für Wortstamm-Anfragen **[Annahme Schwelle]**.
- Akzeptanz: „Rechnung“ findet „Rechnungen“ und „Rechnungsnummer“ nicht (Komposita!) – bekannte Grenze der deutschen Wortstämme; Gegenmaßnahme `pg_trgm`-Fallback, im Test dokumentiert.

### 6.1 Übersicht, Summen, Quelle und Zähler (WP-D9)

- **Gemeinsamer Filtersatz:** `GET dms/documents` und `GET dms/search` verwenden dieselben Bedingungen (`DMSDocuments.extractionConditions`): Art, Sicherheit, Währung, Betrag von/bis, Belegdatum, Fälligkeit, Referenz, `source`, `has_open_suggestions`. Ohne `q` liefert die Suche bei gleichem Filter dieselbe Menge wie die Liste. `sort`/`order` gelten an beiden Routen; die Suche kennt zusätzlich `sort=relevance` (Standard, Cursor = Score).
- **Suchtreffer** tragen `source`, `open_suggestions` und `extraction` (Übersichtswerte: Art, Betrag, Währung, Belegdatum, Fälligkeit, Referenz), damit die Oberfläche keine Einzelabrufe je Zeile braucht.
- **Summe je Währung:** `GET dms/documents?totals=true` liefert `totals` (`currency`, `sum` als Dezimalzeichenkette aus `numeric`, `count`) über die gesamte gefilterte Menge, ohne Cursor; Papierkorb nur mit `trashed=true`; Beträge ohne Währung bilden die Gruppe `currency: null`. Das Feld `total` (mit `count=true`) zählt weiterhin nur nach Papierkorb, nicht nach den übrigen Filtern.
- **Quelle:** `dms_documents.source` = `upload` | `mail` | `folder` | `share` (Share-/Scan-API mit Api-Token) | `import` (Paperless) | `api` | `unknown`. Setzt der Anlegepfad (`DMSDocuments.create`, Standard aus dem Eingangsvorgang, Import überschreibt); Migration `dms_025_document_source` füllt den Bestand aus dem frühesten Eingangsvorgang (`api` mit Herkunft `paperless:` = `import`), dann aus `mail_attachment`-Verknüpfungen, sonst `unknown`.
- **Offene Vorschläge:** `open_suggestions` je Dokument (Zählung nur für die Seite, Index `dms_suggestions_open_document`), Filter `has_open_suggestions`.
- **Zähler:** `GET dms/stats` (Recht `dms.document.read`): `queued`, `failed` (Quarantäne), `open_suggestions`, `overdue` (Fälligkeit vor `today`, Standard Datenbankdatum; Verträge zählen nicht), `new_last_7_days`; je Dokument einmal gezählt, Papierkorb nie.

## 7. Speicherpfade und Dateinamen

- **Physisch** immer inhaltsadressiert (ARCHITEKTUR 4.5), nie vom Titel abhängig.
- **Virtuell**: `dms_storage_paths.template` mit Platzhaltern `{doc_date:yyyy}`, `{doc_date:MM}`, `{type}`, `{correspondent}`, `{title}`, `{asn}`, `{field:<code>}`, `{tags:<gruppe>}`. Bereinigung: Unicode-NFC, verbotene Zeichen ersetzt, Länge ≤ 120, kein führender Punkt, deterministische Kollisionsauflösung (`-2`, `-3`, Reihenfolge nach `asn`).
- Verwendung: Download-Dateiname (`Content-Disposition`), Export (Abschnitt 11, Steuerberater), WebDAV-ähnliche Sicht (später). Änderung am Dokument oder der Vorlage verändert keine gespeicherten Objekte.
- Akzeptanz: Dokument umbenennen ändert `store_key` nicht (Test); gleiche Titel in gleichem Pfad ergeben eindeutige Namen.

## 8. Revisionssicherheit und Löschkonzept (GoBD-orientiert, keine Rechtsberatung)

Anforderungen, die technisch umgesetzt werden (fachliche Prüfung durch Steuerberater/Jurist offen, F-24):
1. **Unveränderbarkeit**: Original (`role=original`) wird nie überschrieben; DB-Constraint/Trigger verbietet UPDATE/DELETE; ObjectStore-Schlüssel inhaltsadressiert; optional S3 Object Lock/WORM (konfigurierbar, F-06).
2. **Integrität**: SHA-256 beim Eingang gespeichert (`files.sha256`, `dms_document_files.sha256`); periodischer Prüf-Job (`dms.verify`, Stichprobe/rollierend) liest Objekte und vergleicht; Abweichung = Audit + Alarm.
3. **Nachvollziehbarkeit**: alle Änderungen an Metadaten im Audit (Wer, Wann, Alt→Neu bei Metadaten, ohne Dokumentinhalt); Audit append-only, optional Hash-Kette (F-16).
4. **Aufbewahrung**: `retention_until` aus Dokumenttyp + `doc_date` (Standardfristen konfigurierbar, nicht fest verdrahtet; Hinweis in Doku auf 6/8/10 Jahre Praxiswerte, F-24); `legal_hold` sperrt jedes Löschen.
5. **Löschen**: Stufe 1 *Papierkorb* (Soft-Delete, wiederherstellbar, Grund Pflicht); Stufe 2 *Endgültig löschen* (`document.purge`) nur wenn `retention_until` abgelaufen und kein `legal_hold`, optional Vier-Augen; schreibt `dms_deletion_log` (Hash, Zeitpunkt, Person); entfernt Metadaten, Text (Suchindex), Archivdatei, Thumbnails, Bytes im ObjectStore nur wenn keine andere Referenz (Referenzzählung per `files`-Nutzung). Verknüpfte Belege (z. B. finalisierte Rechnung referenziert Dokument) blockieren Purge.
6. **Backups** enthalten gelöschte Daten bis zum Ablauf der Backup-Aufbewahrung; Doku nennt das (Datenschutz).
7. **Export/Prüfzugriff**: Betriebsprüfer-/Steuerberater-Export mit Index (Abschnitt 11).
- Akzeptanz: AK-D-REV-1: Versuch, Original zu ändern/löschen, scheitert auf DB-Ebene (Test mit direktem SQL). AK-D-REV-2: Purge vor Fristablauf/mit `legal_hold` = 409. AK-D-REV-3: manipulierte Datei im Store wird vom Prüf-Job erkannt (Test mit synthetischer Korruption). AK-D-REV-4: Löschprotokoll bleibt nach Purge erhalten.

## 9. API-Entwurf

Basis `/api/v1/tenants/{tenant}/dms` (Stil: `ARCHITEKTUR.md` Abschnitt 5). Entwurf, endgültig im OpenAPI-Vertrag.

| Methode, Pfad | Zweck | Berechtigung |
| --- | --- | --- |
| `POST /uploads` | Datei(en) einliefern, 202 + `ingest_item_id` | `document.create` |
| `GET /ingest-items?state=` | Eingangsstatus/Fehler | `document.read` |
| `POST /ingest-items/{id}/retry` | Quarantäne wiederholen | `document.update` |
| `GET /documents` | Liste, Filter, Suche (`q`), Cursor | `document.read` |
| `GET /documents/{id}` | Metadaten inkl. Zuordnungen, Felder, Links | `document.read` |
| `PATCH /documents/{id}` | Metadaten ändern (`If-Match`) | `document.update` |
| `GET /documents/{id}/file?role=original\|archive\|thumbnail` | Download (Streaming, Range) | `document.read` / `download_original` |
| `GET /documents/{id}/text` | Extrahierter Text | `document.read` |
| `POST /documents/{id}/trash`, `POST /documents/{id}/restore` | Papierkorb | `document.trash` |
| `POST /documents/{id}/purge` | Endgültig (Löschkonzept) | `document.purge` |
| `GET/POST /documents/{id}/links`, `DELETE …/{link}` | Verknüpfungen | `document.update` |
| `GET /documents/{id}/suggestions`, `POST …/{sid}/accept\|reject` | Vorschläge | `suggestion.decide` |
| `GET/POST/PATCH /types`, `/tags`, `/tag-groups`, `/storage-paths`, `/custom-fields` | Stammdaten | `tag.manage` u. a. |
| `POST /tags/{id}/merge` | Tag-Merge mit Audit | `tag.manage` |
| `GET/POST/PATCH /rules`, `POST /rules/{id}/preview` | Regeln, Trockenlauf | `rule.manage` |
| `GET/POST/PATCH /sources`, `POST /sources/{id}/test` | Eingangsquellen | `source.manage` |
| `GET /duplicates`, `POST /duplicates/{id}/resolve` | Duplikate | `document.update` |
| `POST /share-links`, `DELETE …` | Freigabelinks | `share.create` |
| `POST /exports` + `GET /exports/{id}` | Export-Job (ZIP + Index) | `export.run` |
| `GET /stats` | Zähler (Eingang, Fehler, Backlog) | `document.read` |

Events (veröffentlicht): `dms.document.received`, `dms.document.classified`, `dms.document.archived`, `dms.document.trashed`, `dms.document.purged`, `dms.ingest.failed`. Abonniert: `invoice.document.finalized` (Ausgangsrechnung archivieren, wenn eingeschaltet), `invoice.document.cancelled` (Verweis aktualisieren).

## 10. Import aus Paperless-ngx (Migrationsweg)

Umgesetzt in WP-D6 (Handoff `docs/handoff/WP-D6.md`). Quelle ist ein **Export des Kunden** (Verzeichnis von `document_exporter`: `manifest.json` + Dateien) **oder** die REST-API einer Instanz (nur GET, Token); niemals deren Datenbank. Entwicklung und Tests ausschließlich mit synthetischer Fixture (`backend/Tests/Fixtures/paperless-synthetic/`, per `generate.py` selbst erzeugt, 10 erfundene Dokumente) und einem Mock-API-Server. Das Manifest-/API-Format ist aus der Funktionsbeschreibung abgeleitet und **gegen eine echte Instanz noch nicht verifiziert** (nur bekannte Felder werden gelesen, Unbekanntes wird übersprungen). Paperless ist GPL-3.0: kein Code, keine Texte, keine Testdaten übernommen.

**Läufe** (`dms_imports`, Routen `POST|GET imports`, `GET imports/{id}`, `GET imports/{id}/report`, `POST imports/{id}/cancel`; Rechte `dms.import.read|manage`, nur Buchhaltung und Owner): Quelle (`export` mit relativem Pfad unter `DMS_IMPORT_ROOT/<mandant>/` im Worker, oder `api` mit `base_url` und `token`), Modus `dry_run` | `import`, Option `ocr`. Der Job `dms.import.paperless` läuft mit Lease (genau ein Worker je Lauf, Absturz = Fortsetzung durch einen anderen Worker nach Lease-Ablauf), Fortschritt je Dokument (`progress`), Abbruch vor dem nächsten Dokument.
1. Referenzdaten: Korrespondent -> neuer Kontakt (`is_correspondent`; **nie** still mit einem gleichnamigen vorhandenen Kontakt zusammengeführt, stattdessen Befund `contact_possible_duplicate`), Dokumenttyp, Tag (gleichnamige, auch nur in der Schreibweise abweichende, werden zu einem Tag zusammengeführt, Befund `reference_matched_by_name`; ähnliche Namen per Dreiergruppen-Maß wie `pg_trgm` als `tag_similar`), Speicherpfad -> `dms_storage_paths` (Platzhalter `created_year`, `created_month`, `correspondent`, `document_type`, `title`, `asn` übersetzt; Filter und andere Platzhalter -> `storage_path_untranslatable`, Pfad wird nicht gesetzt), benutzerdefinierte Felder (string/url -> string, date, boolean -> bool, integer -> int, float und monetary -> decimal (Währung geht verloren, Befund), select -> select; `documentlink` -> `custom_field_unsupported`).
2. Dokumente über `DMSDocuments.create` (Quota, Magic Bytes, Hash, Dedup, Ingest-Vorgang `source=api`, `origin_ref=paperless:<id>`): Original -> `role=original`, Archivdatei (nur PDF mit passender Prüfsumme) -> `role=archive`, Titel, `created` -> `doc_date`, `added` -> `received_at`, ASN (Zähler `dms:asn` je Seite vorab per `CounterService.ensureAtLeast` mit Audit auf mindestens das Maximum der Seite, am Ende auf das Maximum der Quelle; Kollision mit einem vorhandenen Dokument -> ohne ASN importiert, Befund `asn_collision`), Inhalt -> `dms_document_texts` mit `engine=imported` (Dokument mit Text: Ingest sofort `done`, kein OCR, keine Regeln; ohne Text: OCR-Job mit Massenpriorität, falls `ocr` an), Tags, Felder, Korrespondent (Verweis mit Quelle `import`), Notizen -> `dms_document_notes` (Route `GET documents/{id}/notes`). Prüfsumme der Quelle (32 Hexzeichen = MD5, 64 = SHA-256) wird gegen die neu berechnete verglichen; Abweichung = Dokument übersprungen (`checksum_mismatch`), fehlende Prüfsumme = Befund `file_without_checksum`. Dateien nur als reguläre Dateien im Exportverzeichnis (kein `..`, keine Links).
3. Idempotent und fortsetzbar: Schlüssel `(Quelle, Art, Paperless-ID)` in `dms_import_items`; gleicher Inhalt aus einer anderen Paperless-Quelle wird nicht noch einmal übernommen (`duplicate_hash_imported`). Ein neuer Lauf gegen dieselbe Quelle ergänzt nur Fehlendes (auch nach Abbruch oder Fehler). **Der Quellenschlüssel des Exports ist sein Pfad**: derselbe Export unter einem anderen Pfad legt Kontakte und Stammdaten (gleichnamige Typen/Tags/Pfade/Felder werden verwendet) neu an bzw. ordnet sie zu, Dokumente mit gleichem Hash werden nicht doppelt importiert.
4. Trockenlauf schreibt nichts ins DMS (keine Dokumente, Dateien, Kontakte, Stammdaten, Zähler); der Bericht enthält Anzahlen, Konflikte (ASN-Kollision, vorhandene Namen), Dateien ohne Prüfsumme, ähnliche Tags. Der Bericht (JSON-Datei, `labhub-paperless-import-report/1`) ist auch bei Abbruch und Fehler abrufbar.
5. Rechte: Besitzer und Berechtigungen der Quelle werden **nicht** übernommen (nur Zähler im Bericht, F-23, Benutzer- und Gruppeneinträge des Manifests werden nie gelesen). Matching-Regeln werden **nicht** migriert, sondern als `rule_suggestions` im Bericht ausgegeben (Vorschläge für `dms_rules` im `suggest`-Modus; Semantik weicht ab, P2).
6. Sicherheit der REST-Quelle: nur `https` mit Zertifikatsprüfung, keine Weiterleitungen, Host-Allowlist `DMS_IMPORT_HOST_ALLOWLIST` (Backend und Worker), Loopback/Link-Local gesperrt, Token mit `SecretBox` verschlüsselt (nie in Antworten, Audit, Logs), Fehler nur als Codes.
- Akzeptanz AK-D9 (Tests `DMSImportTests.swift`): Fixture (10 Dokumente, 6 Tags davon 1 Dublette und 1 ähnlicher, 4 Korrespondenten, 3 Typen, 2 Pfade davon 1 nicht übersetzbar, 3 Felder, 3 Notizen, 2 Archivdateien) importiert vollständig, Hashes identisch, Beziehungen korrekt; zweiter Lauf ändert nichts; ASN-Zähler >= Maximum; Trockenlauf schreibt nichts; Abbruch und Fortsetzung; Mandantentrennung; Rechte; zwei Worker -> Lauf genau einmal.

## 11. Steuerberater-Export und Rechnungsverknüpfung

- **Export-Job** `dms.export`: Auswahl (Zeitraum, Typen, Verknüpfung „mit Buchung“) → ZIP mit Dateien (Namen aus Speicherpfad-Vorlage), `index.csv`/`index.xml` (ASN, Datum, Korrespondent, Typ, Beträge, Hash, verknüpfte Belegnummer) und `MANIFEST.sha256`. Ablage im ObjectStore, Download mit Ablaufzeit. Vorbild-Datenformat für Betriebsprüfung (Z3/GDPdU-ähnlich) ist **nicht** Teil von V1 (F-24).
- **Beleg↔Dokument** (Kern `links`, Details Rechnungsseite `MODUL-RECHNUNG.md` Abschnitt 9): Arten `attachment` (E-Rechnung/PDF gehört zum Beleg), `evidence` (Eingangsrechnung → Ausgabe), `payment_proof` (Kontoauszug/Quittung), `reference`. Quelle (`manual`,`rule`,`suggestion`) Pflicht; jede automatische Verknüpfung erst als Vorschlag. Verknüpftes Dokument kann nicht endgültig gelöscht werden (Abschnitt 8).
- E-Rechnungen (XML/ZUGFeRD) im DMS: Eingang erkennt Anhang-XML, extrahiert strukturierte Felder (Rechnungsnummer, Betrag, Datum, USt-ID) als **verlässliche** Felder (Quelle `einvoice`, höhere Konfidenz als OCR) und legt XML + PDF als zusammengehörige Dateien ab (`role=original` + `role=derivative`? Zuordnung offen, F-21).

## 12. Frontend-Sicht
Bedienung (Eingang/Prüfen, Liste, Detail, Regel-Vorschau, Tag-Pflege, Papierkorb) in `FRONTEND.md` Abschnitt 8; eigenes Bedienkonzept, kein Paperless-Layout.

## 13. Akzeptanzkriterien (Modul gesamt)

- AK-D1: Upload eines synthetischen PDFs erzeugt Original (Hash stimmt), Dokument, Audit-Eintrag, Event; wiederholter Upload (gleicher `Idempotency-Key`) erzeugt nichts Neues.
- AK-D2: Zwei Worker-Instanzen verarbeiten 100 Eingänge: jeder Eingang genau einmal OCR-verarbeitet; Kill eines Workers mitten im Job → anderer übernimmt nach Lease-Ablauf.
- AK-D3: Konsumordner: unvollständig kopierte Datei wird nicht verarbeitet; Absturz zwischen Speichern und Verschieben erzeugt kein Duplikat.
- AK-D4: Suche: Wortstamm-, Tippfehler-, Phrasen-, Filtertests; fremder Mandant liefert 0 Treffer, fremde ID 404.
- AK-D5: Regel im `suggest`-Modus ändert nie Metadaten; Annahme eines Vorschlags schreibt Audit; Trockenlauf listet Treffer.
- AK-D6: Revisionstests AK-D-REV-1…4.
- AK-D7: ASN-Vergabe unter Parallelität lückenlos eindeutig (Muster `PostgresTests`).
- AK-D8: Modul deaktiviert → 404 `module_disabled`, Daten erhalten.
- AK-D9: Paperless-Fixture-Import (Abschnitt 10).

## 14. Meilensteine

| M | Inhalt | WP (Roadmap) |
| --- | --- | --- |
| M1 | Dateikern: `ObjectStore` (FS+DB, S3 danach), `files`, Upload, Hash, Dokument-CRUD, Stammdaten (Typ, Tag, Pfad, Felder), Audit, Papierkorb | WP-D1, WP-D2 |
| M2 | Ingest-Zustandsautomat, OCR-Worker (Lease), Textspeicherung, Archivversion | WP-O1, WP-O2 |
| M3 | Suche (tsvector, pg_trgm), Filter, globale Suche | WP-S1, WP-S2 |
| M4 | Regeln als Vorschläge, Kontakt-Matching, Duplikaterkennung | WP-D3 |
| M5 | Quellen: Mail-Ingest, Konsumordner, Share-Extension-API | WP-D4 |
| M6 | Revisionssicherheit: Löschkonzept, Prüf-Job, Export | WP-D5 |
| M7 | Paperless-Import | WP-D6 |
| M8 | Verknüpfung mit Rechnungsmodul, Steuerberater-Export | WP-X1 |
| M9 | optional: KI-Vorschläge (lokal), `pgvector` | später |

## 15. Offen

F-06 (Objektspeicher), F-07 (OCR-Engine), F-11 (KI), F-21 (Versionen/PDF-A/E-Rechnung-Dateirollen), F-22 (Mail/Scanner-Brücke), F-23 (Paperless-Rechteübernahme), F-24 (Aufbewahrungsfristen, GoBD-Prüfung durch Fachperson). Siehe `OFFENE-FRAGEN.md`.
