# Modul Rechnung, Name „invoice“ (Nutzer 25.11.2026) – Entwurf

Status: Entwurf, Stand 01.11.2026. Modulschlüssel `invoice`. **Alle Entscheidungen hier sind Vorschläge**; offene Punkte sind mit **[OFFEN F-xx]** markiert (`OFFENE-FRAGEN.md`). Rahmen: `ARCHITEKTUR.md`. Namensfrage F-01.

Fachliches Vorbild ist die bisherige Rechnungs-App (nicht Teil dieses Repositories). Fachmodell und Regeln werden dort nachgelesen und **nicht kopiert**; dieses Dokument beschreibt nur das Hub-Modul.

Hinweis: Rechtliche und steuerliche Aussagen in diesem Dokument sind keine Beratung; fachliche Freigabe durch Steuerberater ist offen.

## 1. Ziel und Abgrenzung

Grundsatz: Hub eigenständig vollständig; Swift-Apps sind optionale Clients (Offline-/Eigenständigkeit).

Ziel (Nutzeranforderung 01.11.2026): Das Rechnungsprogramm ist im Hub **vollständig ohne Swift-App** nutzbar (Belege erstellen/bearbeiten/finalisieren, Nummernvergabe, PDF-Erzeugung, E-Rechnung, Zahlungen, Berichte), PWA und optionale Apps nutzen denselben Bestand, Belege mit dem DMS verknüpft sind und Nummern zentral vergeben werden. **Nicht Ziel von V1 des Hubs**: Zwei-Wege-Sync mit CloudKit, Bank-Import, Steuer-App (LAB tax), Lagerführung.

| Betriebsart der Swift-App | Datenhaltung | Nummern | Hub nötig |
| --- | --- | --- | --- |
| eigenständig lokal / iCloud (heute) | lokal mit iCloud-Abgleich | Zähler der App | nein |
| **Hub-Modus** (Stufe 1, `ARCHITEKTUR.md` Abschnitt 6) | Hub (Postgres); lokal nur Cache/Warteschlange | Hub-Zähler | ja |

Die App bleibt gleichwertig eigenständig (`PLATTFORM-VISION.md` 8.9). Wechsel nur per Export/Import (Abschnitt 8), nie still.

## 2. Funktionsumfang serverseitig (Vorschlag)

Zuordnung der Funktionsbereiche:

| Bereich | Im Hub-Modul V1 | Anmerkung |
| --- | --- | --- |
| Mandant/Einstellungen | ja, Kern `tenants` + `invoice_settings`, Steuerzeiträume | Kleinunternehmer/Regelbesteuerung mit Zeitraum |
| Kontakte | **Kern** (`contacts`), Vorgaben im Modul | ARCHITEKTUR 4.3 |
| Artikel/Katalog | ja (`invoice_items`), Lagerangaben zunächst nur speichern | Lagerführung später |
| Belegtypen, Belege, Positionen | ja | Zustandsautomat serverseitig erzwungen |
| Verknüpfungen Beleg↔Beleg | ja (Umwandlung, Gutschrift, Referenz) | Beleg↔Dokument über Kern `links` |
| Zahlungen, Skonto | ja | Zuordnung nie still |
| Nummernvergabe | ja, **Hub-Zähler** | Abschnitt 4 |
| Berechnung (Summen, Rundung) | ja, **deterministisch, Dezimal**, Linux-Rechenkern Pflicht | Abschnitt 3 |
| PDF-Rendering, Layouts, Designer | ja, **Pflicht** (Linux-Renderer; Designer in PWA gestuft) | Abschnitt 5 |
| E-Rechnung erzeugen/prüfen | ja (Erzeugung), Prüfung offen | Abschnitt 6 |
| Ausgaben, Eingangsrechnungen, EÜR, USt | ja (Phase 2) | Abschnitt 7 |
| Banking (Kontoauszug-Import) | nein in V1 | später |
| Import aus der bisherigen App | ja | Abschnitt 8 |

Tabellen (Präfix `invoice_`): `invoice_settings`, `invoice_tax_regimes`, `invoice_document_types`, `invoice_series`, `invoice_documents` (Status, Nummer, Kontakt, Datumsfelder, Summen als `numeric`), `invoice_lines`, `invoice_render_states` (Layoutversion, Inhalt-Hash, PDF-`file_id`), `invoice_payments`, `invoice_items`, `invoice_expenses`, `invoice_custom_fields`. Der Spaltenentwurf entsteht je WP; kein Vorab-Schema hier.

Invarianten (als DB-Constraints + Tests):
1. Finale Belege sind unveränderlich (Trigger verbietet UPDATE auf Inhalt, Korrektur nur per Storno/Gutschrift).
2. `UNIQUE (tenant_id, series_id, number) WHERE status = 'final'` (Teil-Index, Grund für PostgreSQL, ADR 0001).
3. Beträge `numeric(18,4)` (Rundungsregeln Abschnitt 3), Währung je Beleg; kein Gleitkomma.
4. Zahlungssumme ≤ Rechnungssumme, außer bewusst als Überzahlung gekennzeichnet.

## 3. Rechenkern

**Entschieden (F-27, 07.11.2026):** Der Hub implementiert die Rechenregeln (Steuergruppen, Rundung, Nummernformat, Salden) selbst, Linux-tauglich, gegen synthetische Testvektoren (JSON, Dezimal-Strings) unter `backend/Tests/Fixtures/invoice-vectors/`. Ein gemeinsames Paket mit der App ist später möglich. Ausgeschlossen bleibt, dass der Hub Summen vom Client übernimmt: Der Server erzwingt die Invarianten.

## 4. Nummernvergabe über den Hub-Zähler

- Hub-Modus: Finalisieren **nur online**, Nummer aus `CounterService.next(tenant:key:)` mit Key `invoice.<series_id>` in derselben Transaktion wie der Statuswechsel → Final (atomar, ohne Lücke bei Erfolg). Nutzerentscheidung „zentraler atomarer Zähler, Finalisieren nur online“ (Stand 18.10.2026).
- `POST …/documents/{id}/finalize` mit `Idempotency-Key`; Wiederholung liefert dieselbe Nummer (vorhanden: `IdempotencyService`).
- Rollback der Transaktion gibt die Nummer nicht frei: `UPDATE … RETURNING` in einer Transaktion bleibt nach Rollback lückenfrei, weil der Zählerstand mit zurückrollt. Die aktuelle `CounterService.next` ist ein einzelnes Statement (autocommit); für Finalisierung muss der Zähler innerhalb der Beleg-Transaktion laufen (WP-K6: `next(on: tx)`). Test: Fehler nach Nummernvergabe → keine Lücke.
- Nummernformat (Jahr, Serie, Stellen, Rücksetzung); Formatierung als reine Funktion.
- Dokumentierte Freigabe einer Lücke (Storno einer Nummer) nur mit Grund, Audit.
- Untergrenzen beim Import/Verbinden (App hatte Nummern bis N): Zähler wird auf `max(Zähler, N)` gesetzt, Audit. **[OFFEN F-09]**
- AK-R4: 50 parallele Finalisierungen über zwei Instanzen ergeben 50 verschiedene lückenlose Nummern; Fehlerfall ohne Lücke.

## 5. PDF-Rendering und Layouts im Hub (Entscheidung F-08 neu bewertet)

Anforderung: Der Hub rendert selbst, Linux-tauglich, ohne App. Der Renderer der bisherigen App nutzt Apple-Frameworks und läuft nicht unter Linux. Ziel bleibt Treue zu den vorhandenen Layouts.

| Option | Beschreibung | Vorteile | Nachteile |
| --- | --- | --- | --- |
| a Swift-Portierung | Renderer der App auf Linux: Layout-Engine bleibt, Zeichnen/Schrift über Swift-PDF-Bibliothek bzw. eigenen PDF-Writer, Schriftmetriken über FreeType/HarfBuzz | gleiche Layoutlogik wie App (höchste Treue, ein Layoutmodell), kein Browser im Image | Portierungsaufwand, PDF/A-3 selbst zu liefern |
| b HTML/CSS + headless Chromium | Layoutmodell → HTML/CSS → PDF im Worker-Container | etabliert, gute Typografie | große Images, Abweichungen zur App, Determinismus/Seitenumbruch schwer |
| c Typst-Pipeline | Layoutmodell → Typst → PDF per Binary im Worker | schnell, deterministisch, kleines Image | zweite Layoutsprache, Layouttreue nur über Übersetzer; Lizenz/PDF-A-Unterstützung zu verifizieren |

Entscheidung per Spike WP-R6a (`ROADMAP.md`), Ergebnis als ADR 0008. **Entschieden (Nutzer, 27.11.2026, F-08): Typst mit kleinem Schritt für die Factur-X-Metadaten** (Spike `docs/spikes/WP-R6a/BERICHT.md`; die Tabelle oben ist der Stand vor dem Spike). Umsetzungsplan: `docs/handoff/WP-R6-PLAN.md`. Regeln unabhängig von der Option: Rendering als Worker-Job mit Lease; das PDF eines finalen Belegs ist das zum Finalisierungszeitpunkt erzeugte Artefakt (`invoice_render_states`: Layoutversion, Inhalt-Hash, `file_id`) und wird nie neu erzeugt; Layouts sind versionierte Mandantendaten (`invoice_layouts`); Import vorhandener Layouts über ein dokumentiertes Importformat (nur synthetische Fixtures in Tests). Die App behält ihren eigenen Renderer für Offline-Betrieb; Abweichungen zwischen App- und Hub-PDF sind erwartbar und werden im Konformitätstest quantifiziert. Layout-Designer in der PWA: `FRONTEND.md` Abschnitt 13.

## 6. E-Rechnung

Formate: XRechnung 3.0.x, ZUGFeRD/Factur-X, Validierung (KoSIT-Validator/Schematron als Referenz), Eingang (Einlesen). Vorschlag:
- **Erzeugung** (CII-XML) aus dem finalen Beleg, im Hub gegen das Belegmodell des Hubs. Einbettung in PDF/A-3 setzt PDF-Erzeugung voraus (siehe 5).
- **Validierung** serverseitig: Referenzvalidator ist Java (KoSIT); Betrieb als Sidecar-Container oder nur als CI-/Testwerkzeug **[OFFEN F-26]**.
- **Eingang**: E-Rechnungs-Anhänge (XML in PDF oder reines XML) liefert das DMS ein (`MODUL-DMS.md` Abschnitt 11); das Rechnungsmodul bietet daraus „Eingangsrechnung als Entwurf anlegen“ (nach Nutzeraktion).
- Aufbewahrung: XML und PDF als zusammengehörige unveränderliche Dateien (Kern `files`), Hash im Beleg.
- Rechtlicher Rahmen (Pflichten ab 2025/2027/2028 in Deutschland) wird hier nicht beschrieben; vor Umsetzung fachlich prüfen.

## 7. EÜR/USt-Berichte (Phase 2)

Serverseitig als Berichtsdienst `GET …/reports/euer?year=`, `…/reports/vat?period=` mit demselben Rechenkern (Abschnitt 3). Ergebnisse sind Berechnungen aus Daten (reproduzierbar), kein gespeicherter Zustand; Export CSV/PDF nach Renderer-Entscheidung. Steuerberater-Export: Belegliste + verknüpfte Dokumente (`MODUL-DMS.md` Abschnitt 11). Fachliche Freigabe durch Steuerberater offen.

## 8. Übernahme aus der bisherigen App

- Quelle: ein Export der App; ein verschlüsseltes Backup wird nur entschlüsselt angenommen (oder mit Nutzerpasswort im Client entschlüsselt). Welches Format kanonisch ist: **[OFFEN F-09]** (Vorschlag: definierter JSON-Export `invoice-export/v1` mit Dezimal-Strings, Anhänge als Dateien + SHA-256).
- Ablauf: Trockenlauf mit Bericht → Import in einer Transaktion je Mandant → Zähler auf Maximum setzen → Anhänge in `files`/DMS (Rechnungs-PDFs als Dokumente Typ „Ausgangsrechnung“, optional) → Abschlussbericht. Idempotent über `origin_ref = legacy:<uuid>`.
- Finale Belege werden **unverändert** (Nummer, Summen, Zeitstempel, Render-Artefakt) übernommen, nicht neu berechnet; Abweichung zwischen gespeicherter und neu berechneter Summe wird gemeldet (Konformitätsprüfung mit dem Rechenkern).
- Importe aus Altsystemen bleiben Funktion der App; der Hub importiert nur ihr Exportformat.
- Rückweg: Export `invoice-export/v1` aus dem Hub (Pflicht für „Wechsel nie still“).
- Akzeptanz: synthetische Export-Fixture (aus der App erzeugt, **ohne** echte Kundendaten) importiert; Summen/Nummern identisch; zweiter Import ändert nichts; Fixture für Mehrmandanten.

## 9. Verknüpfung mit dem DMS

- Ausgangsrechnung finalisiert → Event `invoice.document.finalized` → DMS legt PDF (+XML) als Dokument Typ „Ausgangsrechnung“ ab (wenn `dms` aktiv; `enhances`), setzt `retention_until`, verknüpft per `links(kind=attachment, source=rule)`.
- Eingangsrechnung: DMS-Dokument mit Feldern aus Text/E-Rechnung → Vorschlag „Ausgabe anlegen“ (`suggestion kind=link`) → nach Bestätigung Entwurf in `invoice_expenses` + Link `evidence`.
- Zahlung: Beleg (Quittung/Kontoauszugsseite) → `payment_proof`.
- Alle Verknüpfungen mit Quelle, umkehrbar, auditiert; finale Belege behalten Verweis auf Dokument-ID **und** Hash, damit ein nachträgliches Löschen im DMS blockiert wird (MODUL-DMS Abschnitt 8).
- Akzeptanz: Finalisieren mit DMS aus → kein Fehler, kein Link; mit DMS an → genau ein Dokument, Wiederholung erzeugt kein zweites.

## 10. API-Entwurf (Auszug)

Basis `/api/v1/tenants/{t}/invoice`: `contacts` (Kern, nicht hier), `items`, `series`, `documents` (CRUD, `POST /{id}/finalize`, `POST /{id}/cancel`, `POST /{id}/convert`, `GET /{id}/pdf`, `GET /{id}/einvoice`), `payments`, `expenses`, `reports/euer`, `reports/vat`, `imports/legacy`, `exports/legacy`. Berechtigungen `invoice.*` (`document.read|write|finalize|cancel`, `payment.write`, `report.read`, `import.run`). Fehlercodes u. a. `document_final_immutable`, `number_conflict`, `series_not_found`.

## 11. Meilensteine

| M | Inhalt | WP |
| --- | --- | --- |
| R0 | Spike: Rechenkern unter Linux, Testvektoren | WP-R0 |
| R1 | Stammdaten: Einstellungen, Serien, Artikel, Belegtypen | WP-R1 |
| R2 | Belege (Entwurf), Positionen, Berechnung, Zustandsautomat, Finalisieren mit Hub-Zähler | WP-R2 |
| R3 | Zahlungen, Gutschrift/Umwandlung, Verknüpfungen Beleg↔Beleg | WP-R3 |
| R4 | Import/Export der bisherigen App | WP-R4 |
| R5 | E-Rechnung Erzeugung (Server) | WP-R5 |
| R6 | Renderer-Spike, Server-Renderer und Layout-Engine (Pflicht) | WP-R6a, WP-R6 |
| R7 | Ausgaben, EÜR/USt-Berichte | WP-R7 |
| R8 | DMS-Verknüpfung | WP-X1 |

## 12. R0 – Spike Rechenkern (WP-R0, 01.11.2026)

Geprüft wurde, ob der Rechenkern der bisherigen App unter Linux nutzbar ist. Entschieden (F-27, 07.11.2026): Neuimplementierung im Hub gegen Testvektoren (Abschnitt 3).

**Testvektoren:** `backend/Tests/Fixtures/invoice-vectors/` (`rounding.json` 14, `document-totals.json` 16, `number-format.json` 15, `balances.json` 5 = 50 Vektoren). Eingaben synthetisch, alle Beträge, Mengen und Sätze als Dezimal-Strings. Sie decken Rundung nur je Steuersatz auf Dokumentebene, Netto-/Brutto-Modus, Positions-/Dokumentrabatt, Zusatzkosten, Gutschrift, Rundungsmodi, Nummernformat-Token und Fehlerfälle sowie Salden ab. Erwartungswerte ohne Nachkomma-Nullen (`"291.9"`): Tests vergleichen numerisch, nicht als Text.

**Offen:** Skonto-Quelle (F-32). F-08 ist am 27.11.2026 entschieden (Typst, ADR 0008).

## 13. R1 – Stammdaten (WP-R1, 17.11.2026)

Umgesetzt als HubModule `invoice` (`backend/Sources/HubModuleInvoice/`), Migration `invoice_027_master` (Expand-only, Revert vorhanden, `schema_version` unverändert wie beim DMS). Routen unter `/api/v1/tenants/{tenant}/invoice/` (Vertrag `contracts/openapi.yaml`):

| Bereich | Route | Tabelle | Besonderheiten |
| --- | --- | --- | --- |
| Absender/Einstellungen | `settings` (GET, PUT) | `invoice_settings` (eine Zeile je Mandant) | PUT ersetzt, `rev` zählt; IBAN mit Prüfziffer, Land ISO-2, Währung ISO-4217, Zahlungsziel, Kürzel für `{ABBR}` |
| Steuerzeiträume | `tax-periods` | `invoice_tax_periods` | `standard` (Regelbesteuerung) oder `small_business`; Zeiträume überlappen nie (API 409 `tax_period_overlap`, Trigger als Rückfall, Sperre je Mandant) |
| Belegtypen | `document-types` | `invoice_document_types` | feste Arten `quote`, `order_confirmation`, `delivery_note`, `invoice`, `credit_note`; Standardserie optional |
| Nummernserien | `series` | `invoice_series` | Format-Syntax `{YYYY} {YY} {MM} {N:n} {ABBR} {CLIENT} {PROJECT}`, Gültigkeitsbereich folgt aus dem Format; Zähler liegt im Kern |
| Artikel | `items` | `invoice_items` | `numeric(18,4)`/`numeric(7,4)`, Beträge nur als Dezimal-Strings |

Zählerschlüssel (Grundlage für WP-R2): `CounterKey(space: "invoice", name: <serie-uuid>[-<jjjj>[-<mm>]])`, je nach Gültigkeitsbereich fortlaufend, je Jahr oder je Monat. Eine Serie gilt als benutzt, sobald ein Zähler-Eintrag existiert (auch durch `start_number`); dann sind Format und Löschen gesperrt (409 `series_in_use`). `start_number` beim Anlegen hebt den Zähler des laufenden Zeitraums (UTC, Datenbankuhr) über `ensureAtLeast` an (Audit `counter.raised`). Nummernformat und Zählerschlüssel sind gegen die Testvektoren `number-format.json` geprüft (F-27: Neuimplementierung).

Berechtigungen: `invoice.master.read` (accountant, member, tax_advisor, Owner) und `invoice.master.manage` (accountant, Owner); `customer_viewer` hat keinen Zugriff auf Stammdaten (Annahme, da hier keine feinere Matrix steht). Anlegen akzeptiert optional `Idempotency-Key`. Annahmen und offene Punkte: `docs/handoff/WP-R1.md`.

## 14. R2 – Belege, Berechnung, Finalisieren (WP-R2, 23.11.2026)

Migration `invoice_028_documents` (Expand-only, Revert vorhanden), Code in `backend/Sources/HubModuleInvoice/` (`InvoiceCalculator`, `InvoiceDocuments`, `InvoiceDocumentMigrations`). Routen unter `/api/v1/tenants/{tenant}/invoice/documents` (Vertrag `contracts/openapi.yaml`):

| Route | Berechtigung | Verhalten |
| --- | --- | --- |
| `GET documents` | `invoice.document.read` | Liste (Filter `status`, `kind`, `contact_id`), ohne Positionen |
| `POST documents` | `invoice.document.create` | Entwurf ohne Nummer; Summen rechnet der Server; optional `Idempotency-Key` |
| `GET documents/{id}` | `invoice.document.read` | Beleg mit `lines`, `charges`, `tax_totals` |
| `PATCH documents/{id}` | `invoice.document.update` | Kopf teilweise, `lines`/`charges` ersetzen komplett; nur Entwurf (sonst 409 `document_final_immutable`) |
| `DELETE documents/{id}` | `invoice.document.update` | nur Entwurf |
| `POST documents/{id}/finalize` | `invoice.document.finalize` | siehe unten |

**Rechenkern** (`InvoiceCalculator`, F-27: Neuimplementierung gegen `backend/Tests/Fixtures/invoice-vectors/`): Rundung nur je Steuersatz auf Belegebene, Netto- und Brutto-Modus, Positions- und Belegrabatt (Prozent oder fester Betrag), Zusatzkosten ohne Rabatt, Rundungsmodi `halfAwayFromZero`/`halfEven`/`towardZero`, Zweitmenge. Alle 14 + 16 Vektoren grün (die 15 Zahlenformat- und 5 Saldo-Vektoren betreffen WP-R3/R6). Beträge nur als Dezimal-Strings, nie Gleitkomma; Summen auf 2 Stellen. Der Client sendet keine Summen (422 `unknown_field`), sie entstehen bei jedem Speichern aus den gespeicherten Zeilen.

**Finalisieren** (eine Transaktion, mit `Idempotency-Key` zusätzlich atomar mit dem Schlüssel): Beleg sperren (`FOR UPDATE`) → Vorbedingungen (Kontakt, mindestens eine Positionszeile, aktive Serie aus Beleg oder Standardserie des Belegtyps, Absender-Einstellungen vorhanden; sonst 422) → Nummer über `CounterService.next(on:)` mit dem Schlüssel aus `InvoiceNumbering.counterKey` (Zeitraum nach **Belegdatum**, nicht nach Finalisierungszeitpunkt) → Format der Serie → Steuerregime aus dem Steuerzeitraum zum Belegdatum (sonst `standard`) → Absender (Einstellungen) und Empfänger (Kontakt, erste Adresse) als `jsonb` einfrieren → SHA-256 über Inhalt, Nummer, Zählerwert, Serie, Regime, Absender, Empfänger → Status `final`. Jeder Fehler rollt den Zähler mit zurück (keine Nummernlücke); eine bereits belegte Nummer (Altbestand) = 409 `number_conflict`; zweites Finalisieren = 409 `document_final_immutable`.

**Unveränderlichkeit in der Datenbank:** Trigger `invoice_documents_guard` (UPDATE/DELETE eines nicht-Entwurfs scheitern, Kontakt muss zum Mandanten gehören) und `invoice_children_guard` (Positionen, Zusatzkosten, Steuersummen eines nicht-Entwurfs: INSERT/UPDATE/DELETE scheitern); CHECKs: Entwurf ⇔ keine Nummer/kein Finalisierungszeitpunkt, final braucht Serie, Hash, Absender, Empfänger; Teilindex `(tenant_id, series_id, number) WHERE number IS NOT NULL` hält Nummern eindeutig. Korrektur eines finalen Belegs erfolgt später per Gutschrift (WP-R3), nie durch Ändern.

Berechtigungen (jetzt vom Modul deklariert, aus dem Kernkatalog `Tenancy/Roles.swift` entfernt): `read` accountant/member/tax_advisor/Owner, `create` und `update` accountant/member/Owner, `finalize` nur accountant/Owner. Annahmen und offene Punkte: `docs/handoff/WP-R2.md`.

## 15. R3 – Zahlungen, Skonto, Gutschrift, Umwandlung (WP-R3, 25.11.2026)

Migration `invoice_029_payments` (Expand-only, Revert vorhanden), Code `InvoicePayments`, `InvoiceLinks`, `InvoicePaymentMigrations`. Vertrag `contracts/openapi.yaml`; Basis `/api/v1/tenants/{tenant}/invoice/`:

| Route | Berechtigung | Verhalten |
| --- | --- | --- |
| `GET/POST payments`, `GET payments/{id}` | `invoice.payment.read` / `.write` | Zahlung entsteht immer ohne Zuordnung; Filter `unassigned`, `contact_id` |
| `GET payments/{id}/suggestions` | `invoice.payment.read` | nur Lesen; offene Rechnungen mit Begründung (Nummer im Verwendungszweck, Betrag, Betrag mit Skonto, Kontakt) |
| `POST payments/{id}/allocations` | `invoice.payment.write` | einziger Weg zur Zuordnung: `document_id`, `amount`, optional `skonto_amount`, `overpayment`, Pflicht `confirmed: true` |
| `DELETE payments/{id}/allocations/{allocation}` | `invoice.payment.write` | Rücknahme, Historie bleibt |
| `POST payments/{id}/void` | `invoice.payment.write` | Storno mit Grund, nur ohne aktive Zuordnung |
| `GET documents/{id}/balance` | `invoice.payment.read` | `paid`, `skonto`, `credited`, `open_balance`, `total_balance`, Status |
| `POST documents/{id}/convert` | `invoice.document.create` | Entwurf der Zielart aus finalem Beleg, Verknüpfung `conversion` |
| `POST documents/{id}/credit-note` | `invoice.document.create` | Gutschrift-Entwurf mit negierten Mengen, Verknüpfung `credit_note` |
| `GET/POST documents/{id}/links`, `DELETE …/links/{link}` | `invoice.document.read` / `.update` | von Hand nur `reference`; Systemverknüpfungen nicht entfernbar |

**Zuordnung nie still:** Beleg, Betrag und Skonto kommen ausschließlich aus der bestätigten Anfrage; `confirmed_by`/`confirmed_at` und Audit werden gespeichert.

**Skonto (Annahme F-32):** Bedingung `skonto_percent` + `skonto_days` am Beleg (nach dem Finalisieren unveränderlich). Gewährt wird nur ausdrücklich, bei Zahldatum ≤ Belegdatum + Tage, höchstens Satz × (Brutto − Gutschriften), und nur wenn Zahlung plus Skonto den Rest ausgleichen.

**Salden:** `open_balance` = Brutto − Zahlungen − Skonto; `total_balance` zieht finalisierte Gutschriften ab (Vektoren `balances.json`).

**Invarianten in der Datenbank:** Zuordnungen ≤ Zahlbetrag; über Rechnung abzüglich Gutschriften nur mit Kennzeichen `overpayment`; nur finale Rechnungen gleicher Währung und gleichen Mandanten; Zahlungen und Zuordnungen nie ändern oder löschen (nur Storno/Rücknahme); Systemverknüpfungen zu finalen Belegen nie ändern oder löschen. Parallele Zuordnungen serialisieren über Zeilensperren (Zahlung, dann Beleg). Annahmen und offene Punkte: `docs/handoff/WP-R3.md`.


## 16. R6c – PDF-Erzeugung als Job, Speicherung, Download (WP-R6c, 27.11.2026)

Migration `invoice_030_render` (Expand-only, Revert vorhanden), Code `Render/InvoiceRenderJob`, `Render/InvoiceRenderRoutes`, `Render/InvoiceRenderMigrations`, `InvoiceModuleHooks`. Übergabe `docs/handoff/WP-R6c.md`. Basis `/api/v1/tenants/{tenant}/invoice/`:

| Route | Berechtigung | Verhalten |
| --- | --- | --- |
| `GET documents/{id}/pdf` | `invoice.document.read` | das beim Finalisieren erzeugte PDF (PDF/A-3b) aus dem Objektspeicher; `ETag` = SHA-256; 409 `document_not_final`, `render_pending` (mit `Retry-After`), `render_failed`, `render_not_started` |
| `POST documents/{id}/render` | `invoice.document.finalize` | idempotent: fertig → 200 `ready`; läuft → 202 `pending`; sonst (fehlgeschlagen, vor R6c finalisiert) genau ein neuer Auftrag → 202 |

**Ablauf:** `finalize` reiht den Job `invoice.render` in derselben Transaktion ein (Rollback = kein Job). Der Worker rendert nur aus den eingefrorenen Belegdaten, speichert die Bytes inhaltsadressiert, registriert sie in `files` und schreibt die Zustandszeile `invoice_render_states` (Layoutschlüssel und -version, Inhalt-Hash der Eingabe, SHA-256, `file_id`, Rendererversion). Abschluss nur als Lease-Besitzer; zwei Worker oder doppelte Jobs ergeben ein PDF und eine Zeile.

**Invarianten in der Datenbank:** Zustandszeile nur für einen finalen Beleg mit dessen Inhalt-Hash und einer Datei desselben Mandanten und derselben Prüfsumme; nie ändern, löschen oder leeren; der Fremdschlüssel auf `files` ist RESTRICT, damit keine Löschfunktion (DMS-Löschen, Aufräumen unreferenzierter Bytes) eine referenzierte Beleg-Datei entfernt. **Ein fertiges PDF wird nie neu erzeugt** (F-37: Belege vor WP-R5 behalten ein PDF ohne eingebettetes XML).
