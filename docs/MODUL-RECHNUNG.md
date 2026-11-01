# Modul Rechnung (heute „Taxlab“, später „LAB income“ o. ä.) – Entwurf

Status: Entwurf, Stand 01.11.2026. Modulschlüssel `invoice`. **Alle Entscheidungen hier sind Vorschläge**; offene Punkte sind mit **[OFFEN F-xx]** markiert (`OFFENE-FRAGEN.md`). Rahmen: `ARCHITEKTUR.md`. Namensfrage F-01.

Fachliche Quelle ist das Repo `taxlab` (`taxlab` (lokaler Checkout, Pfad entwicklungsrechnerspezifisch)). Fachmodell und Regeln werden dort nachgelesen und **nicht kopiert**; dieses Dokument verweist nur:

| Thema | Quelle in taxlab |
| --- | --- |
| Entitäten, Zustände Entwurf→Final, Verknüpfungen | `docs/FACHMODELL.md`, `docs/DATENMODELL-V2-V3.md` |
| Rundung, Steuergruppen, Summen, Skonto | `docs/RECHENKERN.md` (Swift-Paket `Packages/TaxlabCore`) |
| Nummernformat, Nummernvergabe, Lücken | `docs/NUMMERNVERGABE.md`, `FACHMODELL.md` Abschnitt F09 |
| Ausgaben, EÜR, Eingangsrechnungen | `docs/EUER.md` |
| E-Rechnung (XRechnung, ZUGFeRD/Factur-X, Validierung) | `docs/EINVOICE.md` (`Packages/TaxlabEInvoice`) |
| PDF-Rendering | `docs/RENDERER.md` (`Packages/TaxlabRender`), Layouts `docs/LAYOUT-DESIGNER.md` |
| Speicher-/Sync-Protokolle | `docs/STORAGE-SCHNITTSTELLEN.md`, `docs/SYNC.md` |

Hinweis: Rechtliche und steuerliche Aussagen in diesem Dokument sind keine Beratung; fachliche Freigabe durch Steuerberater ist offen (taxlab-Doku führt dazu eigene Vorbehalte).

## 1. Ziel und Abgrenzung

Grundsatz: Hub eigenständig vollständig; Swift-Apps sind optionale Clients (Offline-/Eigenständigkeit).

Ziel (Nutzeranforderung 01.11.2026): Das Rechnungsprogramm ist im Hub **vollständig ohne Swift-App** nutzbar (Belege erstellen/bearbeiten/finalisieren, Nummernvergabe, PDF-Erzeugung, E-Rechnung, Zahlungen, Berichte), PWA und optionale Apps nutzen denselben Bestand, Belege mit dem DMS verknüpft sind und Nummern zentral vergeben werden. **Nicht Ziel von V1 des Hubs**: Zwei-Wege-Sync mit CloudKit, Bank-Import, Steuer-App (LAB tax), Lagerführung.

| Betriebsart der Swift-App | Datenhaltung | Nummern | Hub nötig |
| --- | --- | --- | --- |
| eigenständig lokal / iCloud (heute) | SQLite + CloudKit | CloudKit-CAS | nein |
| **Hub-Modus** (Stufe 1, `ARCHITEKTUR.md` Abschnitt 6) | Hub (Postgres); lokal nur Cache/Warteschlange | Hub-Zähler | ja |

Die App bleibt gleichwertig eigenständig (`PLATTFORM-VISION.md` 8.9). Wechsel nur per Export/Import (Abschnitt 8), nie still.

## 2. Funktionsumfang serverseitig (Vorschlag)

Zuordnung der Taxlab-Funktionen (F-IDs aus der taxlab-Doku; Detailtabelle dort in `docs/KONZEPT.md`/`FACHMODELL.md`):

| Bereich | Im Hub-Modul V1 | Anmerkung |
| --- | --- | --- |
| Mandant/Einstellungen (F01, F15) | ja, Kern `tenants` + `invoice_settings`, `TaxRegimePeriod` | Kleinunternehmer/Regelbesteuerung mit Zeitraum |
| Kontakte | **Kern** (`contacts`), Vorgaben im Modul | ARCHITEKTUR 4.3 |
| Artikel/Katalog | ja (`invoice_items`), Lager (`StockInfo`) zunächst nur speichern | Lagerführung später |
| Belegtypen, Belege, Positionen (F07, F08, F12) | ja | Zustandsautomat serverseitig erzwungen |
| Verknüpfungen Beleg↔Beleg (F10, F11) | ja (Umwandlung, Gutschrift, Referenz) | Beleg↔Dokument über Kern `links` |
| Zahlungen, Skonto (F11, F14) | ja | Zuordnung nie still (taxlab-Regel) |
| Nummernvergabe (F09) | ja, **Hub-Zähler** | Abschnitt 4 |
| Berechnung (Summen, Rundung) | ja, **deterministisch, Dezimal**, Linux-Rechenkern Pflicht | Abschnitt 3 |
| PDF-Rendering, Layouts, Designer | ja, **Pflicht** (Linux-Renderer; Designer in PWA gestuft) | Abschnitt 5 |
| E-Rechnung erzeugen/prüfen | ja (Erzeugung), Prüfung offen | Abschnitt 6 |
| Ausgaben, Eingangsrechnungen, EÜR, USt | ja (Phase 2) | Abschnitt 7 |
| Banking (Kontoauszug-Import) | nein in V1 | taxlab `KONTOAUSZUG.md` |
| Import Totals/Taxlab-Export | ja | Abschnitt 8 |

Tabellen (Präfix `invoice_`): `invoice_settings`, `invoice_tax_regimes`, `invoice_document_types`, `invoice_series`, `invoice_documents` (Status, Nummer, Kontakt, Datumsfelder, Summen als `numeric`), `invoice_lines`, `invoice_render_states` (Layoutversion, Inhalt-Hash, PDF-`file_id`), `invoice_payments`, `invoice_items`, `invoice_expenses`, `invoice_custom_fields`. Spaltenentwurf entsteht je WP per Abgleich mit `DATENMODELL-V2-V3.md`; kein Vorab-Schema hier.

Invarianten (als DB-Constraints + Tests):
1. Finale Belege sind unveränderlich (Trigger verbietet UPDATE auf Inhalt, Korrektur nur per Storno/Gutschrift).
2. `UNIQUE (tenant_id, series_id, number) WHERE status = 'final'` (Teil-Index, Grund für PostgreSQL, ADR 0001).
3. Beträge `numeric(18,4)` (Rundungsregeln aus `RECHENKERN.md`), Währung je Beleg; kein Gleitkomma.
4. Zahlungssumme ≤ Rechnungssumme, außer bewusst als Überzahlung gekennzeichnet.

## 3. Rechenkern: Wiederverwendung

Die Rechenregeln (Steuergruppen, Rundung, Skonto) existieren als Swift-Paket `TaxlabCore` mit 51+ Tests (`RECHENKERN.md`). Optionen:

| Option | Beschreibung | Vor-/Nachteil |
| --- | --- | --- |
| **A (Vorschlag)** | Pakete `TaxlabCore`, `TaxlabModel` (Foundation-only?) in ein eigenes SwiftPM-Repo auslagern und als Abhängigkeit des Hub-Moduls nutzen | Eine Wahrheit, Tests gelten für beide; erfordert **Linux-Build-Nachweis** (zu verifizieren: Pakete deklarieren macOS/iOS 26, Abhängigkeiten laut Doku nur Foundation) und Paket-Extraktion im taxlab-Repo |
| B | Regeln im Hub nach Doku neu schreiben | Doppelte Pflege, Abweichungsrisiko; nur mit Kreuztests (gleiche Testvektoren) |
| C | Hub rechnet nicht, nimmt Summen vom Client | schwach: Server kann Invarianten nicht erzwingen |

Seit der Anforderung „Hub ohne App“ ist Option C ausgeschlossen. Empfehlung A mit Spike (WP-R0): Linux-Build von `TaxlabCore`/`TaxlabModel`, Testvektoren (JSON, Dezimal-Strings) als gemeinsame Konformitätsfixtur. Fällt der Spike negativ aus: B mit gemeinsamen Testvektoren. **[OFFEN F-27]**

## 4. Nummernvergabe über den Hub-Zähler

- Hub-Modus: Finalisieren **nur online**, Nummer aus `CounterService.next(tenant:key:)` mit Key `invoice.<series_id>` in derselben Transaktion wie der Statuswechsel → Final (atomar, ohne Lücke bei Erfolg). Nutzerentscheidung „zentraler atomarer Zähler, Finalisieren nur online“ (taxlab `NUMMERNVERGABE.md`, Revision 18.10.2026).
- `POST …/documents/{id}/finalize` mit `Idempotency-Key`; Wiederholung liefert dieselbe Nummer (vorhanden: `IdempotencyService`).
- Rollback der Transaktion gibt die Nummer nicht frei: `UPDATE … RETURNING` in einer Transaktion bleibt nach Rollback lückenfrei, weil der Zählerstand mit zurückrollt. Die aktuelle `CounterService.next` ist ein einzelnes Statement (autocommit); für Finalisierung muss der Zähler innerhalb der Beleg-Transaktion laufen (WP-K6: `next(on: tx)`). Test: Fehler nach Nummernvergabe → keine Lücke.
- Nummernformat (Jahr, Serie, Stellen, Rücksetzung) gemäß F09 in taxlab; Formatierung als reine Funktion (Teil von `TaxlabCore`/`TaxlabModel`).
- Dokumentierte Freigabe einer Lücke (Storno einer Nummer) nur mit Grund, Audit.
- Untergrenzen beim Import/Verbinden (App hatte Nummern bis N): Zähler wird auf `max(Zähler, N)` gesetzt, Audit. **[OFFEN F-09]**
- AK-R4: 50 parallele Finalisierungen über zwei Instanzen ergeben 50 verschiedene lückenlose Nummern; Fehlerfall ohne Lücke.

## 5. PDF-Rendering und Layouts im Hub (Entscheidung F-08 neu bewertet)

Anforderung: Der Hub rendert selbst, Linux-tauglich, ohne App. `TaxlabRender` nutzt CoreGraphics/CoreText/PDFKit (taxlab `RENDERER.md`) und läuft nicht auf Linux (Annahme, im Spike prüfen). Ziel bleibt Treue zu Totals-/Designer-Layouts (taxlab `docs/IMPORT-ADAPTER.md`, `docs/LAYOUT-DESIGNER.md`, `tools/layoutcheck`).

| Option | Beschreibung | Vorteile | Nachteile |
| --- | --- | --- | --- |
| a Swift-Portierung | `TaxlabLayout`/`TaxlabRender` auf Linux: Layout-Engine bleibt, Zeichnen/Schrift über Swift-PDF-Bibliothek bzw. eigenen PDF-Writer, Schriftmetriken über FreeType/HarfBuzz | gleiche Layoutlogik wie App (höchste Treue, ein Layoutmodell), kein Browser im Image | Portierungsaufwand, PDF/A-3 selbst zu liefern |
| b HTML/CSS + headless Chromium | Layoutmodell → HTML/CSS → PDF im Worker-Container | etabliert, gute Typografie | große Images, Abweichungen zur App, Determinismus/Seitenumbruch schwer |
| c Typst-Pipeline | Layoutmodell → Typst → PDF per Binary im Worker | schnell, deterministisch, kleines Image | zweite Layoutsprache, Treue zu Totals-Layouts über Übersetzer; Lizenz/PDF-A-Unterstützung zu verifizieren |

Entscheidung per Spike WP-R6a (`ROADMAP.md`), Ergebnis als ADR 0008. Tendenz [Annahme]: a, falls der Linux-Build gelingt, sonst b. Regeln unabhängig von der Option: Rendering als Worker-Job mit Lease; das PDF eines finalen Belegs ist das zum Finalisierungszeitpunkt erzeugte Artefakt (`invoice_render_states`: Layoutversion, Inhalt-Hash, `file_id`) und wird nie neu erzeugt; Layouts sind versionierte Mandantendaten (`invoice_layouts`); Import vorhandener Layouts nach dem Importformat der Taxlab-Doku (nur synthetische Fixtures in Tests). Die App behält ihren eigenen Renderer für Offline-Betrieb; Abweichungen zwischen App- und Hub-PDF sind erwartbar und werden im Konformitätstest quantifiziert. Layout-Designer in der PWA: `FRONTEND.md` Abschnitt 13.

## 6. E-Rechnung

taxlab `EINVOICE.md`: XRechnung 3.0.x, ZUGFeRD/Factur-X, Validierung (KoSIT-Validator/Schematron als Referenz), Eingang (Einlesen). Vorschlag:
- **Erzeugung** (CII-XML) aus dem finalen Beleg: Logik liegt in `TaxlabEInvoice` (hängt laut Doku von `TaxlabRender` ab → Trennung nötig, Teile ohne Rendering Linux-fähig machen; zu verifizieren) oder Neuimplementierung gegen dieselben Testvektoren. Einbettung in PDF/A-3 setzt PDF-Erzeugung voraus (siehe 5).
- **Validierung** serverseitig: Referenzvalidator ist Java (KoSIT); Betrieb als Sidecar-Container oder nur als CI-/Testwerkzeug **[OFFEN F-26]**.
- **Eingang**: E-Rechnungs-Anhänge (XML in PDF oder reines XML) liefert das DMS ein (`MODUL-DMS.md` Abschnitt 11); das Rechnungsmodul bietet daraus „Eingangsrechnung als Entwurf anlegen“ (nach Nutzeraktion).
- Aufbewahrung: XML und PDF als zusammengehörige unveränderliche Dateien (Kern `files`), Hash im Beleg.
- Rechtlicher Rahmen (Pflichten ab 2025/2027/2028 in Deutschland) wird in taxlab-Doku geführt; hier nicht wiederholen.

## 7. EÜR/USt-Berichte (Phase 2)

Berichtslogik (`EUER.md`, `Packages/TaxlabReports`) bleibt Fachkern; serverseitig als Berichtsdienst `GET …/reports/euer?year=`, `…/reports/vat?period=` mit gleicher Rechenbibliothek (Abschnitt 3). Ergebnisse sind Berechnungen aus Daten (reproduzierbar), kein gespeicherter Zustand; Export CSV/PDF nach Renderer-Entscheidung. Steuerberater-Export: Belegliste + verknüpfte Dokumente (`MODUL-DMS.md` Abschnitt 11). Fachliche Freigabe durch Steuerberater offen (taxlab).

## 8. Migration/Import aus Taxlab-Export

- Quelle: Export-/Backup-Format der App (taxlab `BERICHTE-CSV-BACKUP.md`, `IMPORT-ADAPTER.md`, `PERSISTENZ.md`); das App-Backup ist verschlüsselt (AES-256-GCM) → Import nimmt entweder den **entschlüsselten Export** oder entschlüsselt mit Nutzerpasswort im Client. Welches Format kanonisch ist: **[OFFEN F-09]** (Vorschlag: definierter JSON-Export `taxlab-export/v1` mit Dezimal-Strings, Anhänge als Dateien + SHA-256).
- Ablauf: Trockenlauf mit Bericht → Import in einer Transaktion je Mandant → Zähler auf Maximum setzen → Anhänge in `files`/DMS (Rechnungs-PDFs als Dokumente Typ „Ausgangsrechnung“, optional) → Abschlussbericht. Idempotent über `origin_ref = taxlab:<uuid>`.
- Finale Belege werden **unverändert** (Nummer, Summen, Zeitstempel, Render-Artefakt) übernommen, nicht neu berechnet; Abweichung zwischen gespeicherter und neu berechneter Summe wird gemeldet (Konformitätsprüfung mit `TaxlabCore`).
- Totals-Import (Altsystem) bleibt App-Funktion (`IMPORTPLAN.md`); der Hub importiert nur das Taxlab-Format.
- Rückweg: Export `taxlab-export/v1` aus dem Hub (Pflicht für „Wechsel nie still“).
- Akzeptanz: synthetische Export-Fixture (aus der App erzeugt, **ohne** echte Kundendaten) importiert; Summen/Nummern identisch; zweiter Import ändert nichts; Fixture für Mehrmandanten.

## 9. Verknüpfung mit dem DMS

- Ausgangsrechnung finalisiert → Event `invoice.document.finalized` → DMS legt PDF (+XML) als Dokument Typ „Ausgangsrechnung“ ab (wenn `dms` aktiv; `enhances`), setzt `retention_until`, verknüpft per `links(kind=attachment, source=rule)`.
- Eingangsrechnung: DMS-Dokument mit Feldern aus Text/E-Rechnung → Vorschlag „Ausgabe anlegen“ (`suggestion kind=link`) → nach Bestätigung Entwurf in `invoice_expenses` + Link `evidence`.
- Zahlung: Beleg (Quittung/Kontoauszugsseite) → `payment_proof`.
- Alle Verknüpfungen mit Quelle, umkehrbar, auditiert; finale Belege behalten Verweis auf Dokument-ID **und** Hash, damit ein nachträgliches Löschen im DMS blockiert wird (MODUL-DMS Abschnitt 8).
- Akzeptanz: Finalisieren mit DMS aus → kein Fehler, kein Link; mit DMS an → genau ein Dokument, Wiederholung erzeugt kein zweites.

## 10. API-Entwurf (Auszug)

Basis `/api/v1/tenants/{t}/invoice`: `contacts` (Kern, nicht hier), `items`, `series`, `documents` (CRUD, `POST /{id}/finalize`, `POST /{id}/cancel`, `POST /{id}/convert`, `GET /{id}/pdf`, `GET /{id}/einvoice`), `payments`, `expenses`, `reports/euer`, `reports/vat`, `imports/taxlab`, `exports/taxlab`. Berechtigungen `invoice.*` (`document.read|write|finalize|cancel`, `payment.write`, `report.read`, `import.run`). Fehlercodes u. a. `document_final_immutable`, `number_conflict`, `series_not_found`.

## 11. Meilensteine

| M | Inhalt | WP |
| --- | --- | --- |
| R0 | Spike: Linux-Build `TaxlabCore`/`TaxlabModel`, Testvektoren | WP-R0 |
| R1 | Stammdaten: Einstellungen, Serien, Artikel, Belegtypen | WP-R1 |
| R2 | Belege (Entwurf), Positionen, Berechnung, Zustandsautomat, Finalisieren mit Hub-Zähler | WP-R2 |
| R3 | Zahlungen, Gutschrift/Umwandlung, Verknüpfungen Beleg↔Beleg | WP-R3 |
| R4 | Import/Export Taxlab-Format | WP-R4 |
| R5 | E-Rechnung Erzeugung (Server) | WP-R5 |
| R6 | Renderer-Spike, Server-Renderer und Layout-Engine (Pflicht) | WP-R6a, WP-R6 |
| R7 | Ausgaben, EÜR/USt-Berichte | WP-R7 |
| R8 | DMS-Verknüpfung | WP-X1 |

## 12. R0 – Spike-Ergebnis Linux-Rechenkern (WP-R0, 01.11.2026)

**Ergebnis: Ja für `TaxlabCore`, `TaxlabModel` (inkl. Nummernformat) und den Daten-/CSV-Teil von `TaxlabReports`; teilweise für `TaxlabEInvoice`; Nein für `TaxlabLayout`/`TaxlabRender` ohne Portierung (Renderer-Frage gehört zu WP-R6a).**

Methode: taxlab-Quellen (nur `*.swift` und `Package.swift`, keine Daten) wurden schreibgeschützt in einen Scratch-Ordner kopiert und in `swift:6.2` (Swift 6.2.4, Linux aarch64) gebaut und getestet. Das taxlab-Repo wurde weder verändert noch dort gebaut. Befehle (Platzhalter `<dir>` = Ordner, der `Packages/` aus `../taxlab` als gefilterte Kopie enthält und für Docker lesbar gemountet ist):

```
scripts/spike-r0/linux-build.sh <dir> "TaxlabCore TaxlabModel"          # unverändert
scripts/spike-r0/linux-build.sh <dir> "TaxlabLayout TaxlabStorage"      # zeigt die Hindernisse
scripts/spike-r0/linux-patched.sh <dir>                                  # Reports/EInvoice minimal angepasst
scripts/spike-r0/linux-patched-einvoice.sh <dir>                         # explorativ: EInvoice samt Builder
scripts/spike-r0/generate-vectors.sh <dir> backend/Tests/Fixtures/taxlab-vectors
```

| Paket | Linux-Stand | Änderungen nötig | Tests (Linux) |
| --- | --- | --- | --- |
| `TaxlabCore` (7 Dateien, ~800 Zeilen) | baut und testet **unverändert** | keine; `platforms: [.macOS(.v26), .iOS(.v26)]` ist unter Linux wirkungslos, nur Foundation | 53 Tests grün |
| `TaxlabModel` (28 Dateien, ~4300 Zeilen; Nummernformat `NumberFormat`) | baut und testet **unverändert** | keine | 135 Tests in 27 Suites grün |
| `TaxlabReports` (9 Dateien) | baut nach Abtrennen des PDF-Exports | `ReportPDF.swift` (1 Quelldatei, braucht `TaxlabRender`/`TaxlabDesigner`), Paketabhängigkeiten und `linkedFramework`-Einträge; 1 Testdatei `ReportPDFTests.swift`; in `ReportEngineTests.swift` 2 Zeilen mit `criteriaText` (liegt in `ReportPDF.swift`) | 101 Tests grün (ohne PDF) |
| `TaxlabEInvoice` (7 Dateien, ~1060 Zeilen) | Bibliothek (Writer, Validator, Reader ohne PDF) baut nach Anpassung; Tests **nicht** auf Linux gelaufen | `PDFA3Embedder.swift` (CoreGraphics/PDFKit; PDF/A-3 braucht Linux-Ersatz), `CIIReader.swift` (Teil `PDFEmbeddedXML` mit CoreGraphics entfernen; `XMLParser` braucht `import FoundationXML` unter `#if canImport`), `EInvoiceBuilder.make(from: RenderData)` hängt an `TaxlabRender`; Tests nutzen `RenderData` (`Support.swift`) und sind daher nicht ausführbar, solange `RenderData` in `TaxlabRender` liegt | nicht ausgeführt |
| `TaxlabLayout` (9 Dateien) | scheitert unverändert | `TotalsLayoutParser.swift`: `CFGetTypeID`/`CFBooleanGetTypeID`/`CFNumberIsFloatType` (CoreFoundation); mit `NSNumber.objCType` ersetzt baut das Target | Tests nicht ausgeführt |
| `TaxlabRender` (8 Dateien) | scheitert | `PDFRenderer.swift` (587 Zeilen, CoreGraphics/CoreText/PDFKit) und `RichTextConversion.swift` Apple-only; `TemplateFormat.swift` braucht `FoundationXML`; `RichRTF.swift` Zeile 124 läuft in Type-Check-Timeout; Aufwand = Renderer-Portierung (WP-R6a) | nicht ausgeführt |
| `TaxlabStorage` (über `TaxlabDesigner` Abhängigkeit von Reports) | scheitert | `CryptoKit` nicht unter Linux; für den Hub irrelevant | nicht ausgeführt |

Eingriffe für den Hub-relevanten Kern: Core/Model 0 Dateien; Reports 1 Quell- und 2 Testdateien plus `Package.swift`; E-Rechnung 3 Quelldateien (`PDFA3Embedder`, `CIIReader`, `EInvoiceBuilder`) plus `Package.swift`; die Plattformdeklaration ist unkritisch. Eigentliches Abhängigkeitshindernis ist `RenderData` in `TaxlabRender`: Für E-Rechnung und PDF-Berichte muss das reine Datenmodell vom Renderer getrennt werden.

Auffälligkeiten:
- Skonto ist weder in `TaxlabCore` noch in `TaxlabModel` implementiert (keine Fundstelle); die Quelle der Skonto-Regeln für R3 bleibt zu klären.
- `Decimal.description` liefert Werte ohne Nachkomma-Nullen (`"291.9"`). Hub-Tests vergleichen numerisch (Dezimalparse), nicht als String.
- Tests nutzen Swift Testing (`import Testing`), läuft unter `swift:6.2`.

**Testvektoren:** `backend/Tests/Fixtures/taxlab-vectors/` (`rounding.json` 14, `document-totals.json` 16, `number-format.json` 15, `balances.json` 5 = 50 Vektoren). Eingaben synthetisch, alle Beträge, Mengen und Sätze als Dezimal-Strings (per Skript auf Gleitkomma geprüft). Erwartungswerte stammen aus der Referenzimplementierung (taxlab-Code unter Linux) und decken die in den taxlab-Tests geprüften Regeln ab (Rundung nur je Steuersatz auf Dokumentebene, Netto-/Brutto-Modus, Positions-/Dokumentrabatt, Zusatzkosten, Gutschrift, Rundungsmodi, Nummernformat-Token und Fehlerfälle, Salden). Regenerierung: `scripts/spike-r0/generate-vectors.sh`.

**Empfehlung (Nutzerentscheidung F-27 steht aus):**
1. **Option A (gemeinsames SwiftPM-Repo) für `TaxlabCore` + `TaxlabModel`**: technisch belegt, keine Quelländerung nötig; Eingriff beschränkt auf Repo-Struktur (Pfadabhängigkeiten auf URL/Tag, Linux-CI-Job `swift:6.2`, Vektortests in beiden Repos). Aufwand ca. S (1–2 Sessions) plus Abstimmung im taxlab-Repo (Eingriff nur nach Absprache). Risiko: `TaxlabModel` ist groß (~4300 Zeilen, vieles app-spezifisch); entweder komplett binden oder ein schlankes Paket (Totals, Rounding, NumberFormat, Balances) herauslösen.
2. **`TaxlabReports`**: PDF-Export als eigenes Target abtrennen (S).
3. **E-Rechnung**: `RenderData` in ein renderfreies Paket verschieben, `PDFA3Embedder` getrennt halten, Linux-PDF/A-3 in WP-R5/R6a entscheiden (M). Alternative: Writer/Validator übernehmen, Builder im Hub gegen das Hub-Belegmodell neu schreiben.
4. **Renderer** (`TaxlabLayout`/`TaxlabRender`): nicht Teil dieser Empfehlung, Entscheidung über WP-R6a (F-08).
5. **Fallback B** (Neuimplementierung gegen die Vektoren): Totals, Rundung, Nummernformat und Salden ca. 400 Zeilen Swift, Aufwand S–M (2–3 Sessions inkl. Vektortests); sinnvoll, falls kein Eingriff ins taxlab-Repo gewünscht ist. Die Vektoren gelten für beide Wege und sind in R2 als Konformitätstest einzubinden.

Gesamtschätzung A (Core/Model + Reports ohne PDF + E-Rechnung-Trennung): M (4–6 Sessions); nur Core/Model: S. Schätzungen, keine Zusage.

**Offen:** E-Rechnung-Tests unter Linux (nach Trennung von `RenderData`), Linux-Lauf der `TaxlabLayout`-Tests nach CF-Fix, Skonto-Quelle, Auslagerungsumfang `TaxlabModel`.
