# Übergabe WP-D9 (Backend-Lücken der Dokumentübersicht)

Stand 08.11.2026, Branch `wp-D9` (auf `main`, Commit 869696a = bis D8). Test-DB `labhub_d9`. Implementierung und Tests aus derselben Session; kein Reviewer-Lauf. Schließt die Lücken 1 bis 5 aus `docs/handoff/WP-F4c.md` (Abschnitt „Lücken im Backend“). Beschreibung: `docs/MODUL-DMS.md` Abschnitt 6.1.

## Umgesetzt (`Modules/DMS/`)
- **Summe je Währung:** `GET documents?totals=true` -> `totals: [{currency, sum, count}]` (Decimal-Strings aus `numeric`, über die gesamte gefilterte Menge, Papierkorb nur mit `trashed=true`, Betrag ohne Währung = Gruppe `currency: null`). Dieselbe WHERE-Klausel wie die Liste (`listConditions`).
- **Quelle:** Spalte `dms_documents.source` (`upload|mail|folder|share|import|api|unknown`), Filter `source=`, Feld am Dokument und am Suchtreffer. `share` = Share-/Scan-API (im Briefing „scanner/share“). Gesetzt in `DMSDocuments.create` (aus dem Eingangsvorgang; der Paperless-Import setzt `import`). Migration `dms_025_document_source` (expand-only, `schema_version` unverändert, Revert vorhanden) mit Backfill: frühester Eingangsvorgang (`api` + Herkunft `paperless:` = `import`), danach `mail_attachment`-Verknüpfung = `mail`, sonst `unknown`.
- **Suche:** Treffer tragen `source`, `open_suggestions`, `extraction` (Übersichtswerte); alle Extraktionsfilter, `source`, `has_open_suggestions`, `sort`/`order` wie `/documents` (gemeinsame Funktion `DMSDocuments.extractionConditions`, `DMSExtractionQuery.apply`). `sort=relevance` bleibt Standard (Cursor Score); mit anderem `sort` gilt der Cursor des Sortierwerts wie in der Liste.
- **Offene Vorschläge:** `open_suggestions` je Dokument (Liste, Detail, Suche), Filter `has_open_suggestions=true|false`, serverseitig.
- **Zähler:** `GET dms/stats` (Recht `dms.document.read`): `queued`, `failed`, `open_suggestions`, `overdue`, `new_last_7_days`; optional `today=YYYY-MM-DD` (lokaler Tag des Clients, sonst Datenbankdatum).
- Vertrag `contracts/openapi.yaml` (Parameter, Schemas `DmsDocumentSource`, `DmsCurrencyTotal`, `DmsStats`, Route `getDmsStats`), `pwa/src/lib/api/types.ts` regeneriert. Keine neuen Problem-Codes (Validierung: 422 `validation_failed` mit Feldname), daher keine i18n-Zeilen.

## Annahmen und Entscheidungen
- `source` und `open_suggestions` sind im OpenAPI-Schema **nicht** Pflicht (der Server liefert sie immer): Testdaten der PWA (`upload.test.ts`) bauen `DmsDocument` ohne die neuen Felder und `npm run check` bräche sonst; PWA-Dateien gehören nicht zu D9.
- „überfällig“ zählt `due_date < today` über alle Arten außer `contract` (dort ist `due_date` das Vertragsende, D8). „In Warteschlange“ = Eingangsvorgang nicht `done`/`failed_permanent` (`failed_retryable` läuft noch). Je Dokument einmal gezählt.
- `total` (`count=true`) der Liste zählt weiter nur nach Papierkorb (unverändertes Verhalten); `totals` beachtet alle Filter.
- Suche: Quelle `unknown` für Bestand ohne Herkunft ist filterbar.

## Akzeptanzkriterien und Tests (`DMSOverviewTests`)
| AK | Inhalt | Test |
| --- | --- | --- |
| AK-D9-1 | Summen stimmen mit Filter (0,10 + 0,20 = 0,30), mehrere Währungen getrennt, Papierkorb und fremder Mandant ausgeschlossen, Summe über alle Seiten, kein Feld ohne Parameter | `testAKD9_1_totalsPerCurrency` |
| AK-D9-2 | Quelle durch Upload, Share-API, Mail, Konsumordner gesetzt; Filter und 422; Backfill (Ingest, Import, Mail-Verknüpfung, unknown, späterer Vorgang ändert nichts); Indizes | `testAKD9_2_sourceFilledByPathsAndFilter`, `testAKD9_2_backfill` (Import: siehe unten) |
| AK-D9-3 | Suche ohne q = gleiche Menge wie Liste bei 15 Filtern; Sortierung (4 Schlüssel, 2 Richtungen) gleich der Liste, auch über Cursor-Seiten; Trefferfelder; Relevanz bleibt Standard, kombinierbar; 422; Papierkorb, Mandant | `testAKD9_3_searchMatchesListFiltersAndSort` |
| AK-D9-4 | Filter true/false, Zählung (offen/angenommen/abgelehnt), Annahme verringert, Mandantentrennung | `testAKD9_4_openSuggestionsFilterAndCount` |
| AK-D9-5 | Zähler korrekt (Papierkorb, Vertrag, Wiederholung, Alter), Mandant B getrennt, Rechte (tax_advisor ok, customer_viewer 403, anonym 401, fremder Mandant 404), zwei Instanzen gleich, `today` | `testAKD9_5_statsAndPermissions` |
| AK-D9-6 | EXPLAIN der neuen Filter auf 20 000 Dokumenten dokumentiert (kein hartes Ziel) | `testAKD9_6_explainOn20kDocuments` |
Migrationstests (`DMSTests.testMigrationRevertAndReapply`, `ObjectStoreTests`) um `CreateDMSDocumentSource` erweitert (nicht abgeschwächt). Import-Pfad: `DMSImportRunner` übergibt `documentSource: .import`; Abdeckung im Backfill-Test über die Herkunft `paperless:`, ein End-to-End-Import mit Prüfung des Feldes ist nicht ergänzt (offen).

## Performance (EXPLAIN ANALYZE, 20 000 synthetische Dokumente, 1 Mandant, 08.11.2026 lokal, `ANALYZE` vorher)
- `source=mail` (Seite von 51): Index Only Scan `dms_documents_source`, Extraktion über Primärschlüssel; 0,25 ms.
- `has_open_suggestions=true` (2 000 Dokumente mit offenem Vorschlag): `dms_documents_list` + hashed Semi-Join auf `dms_suggestions` (Seq Scan bei 10 % Treffern, der Planer wählt das bewusst); 0,6 ms.
- `currency=EUR&amount 10..50` (Seite von 51): Scan über `dms_documents_list` mit Nested Loop auf Extraktion, 13,6 ms (der Betragsindex liegt auf `dms_extractions`; bei sehr selektiven Filtern über viele Dokumente ist ein Join in der Gegenrichtung denkbar, nicht nötig gemessen).
- `GET stats`: 28 ms gesamt (fünf Zählungen).
- Kein N+1: Liste und Suche holen Extraktion, Quelle und Zählung in einer Abfrage je Seite (korrelierte Unterabfrage nur für die Zeilen der Seite); `totals` ist eine zusätzliche Aggregation.

## Offen
- Keine PWA-Anpassung (Summenzeile, Quellenspalte, Dashboard-Karten, Wegfall der Client-Filterung): eigenes UI-WP; die Notlösungen aus F4c bleiben bis dahin.
- `total` der Liste ignoriert weiterhin Filter; Lücke 6 (Zeitbereich Beleg- vs. Dokumentdatum) unverändert.
- Bestand: Dokumente ohne Herkunft bleiben `unknown`.

## Ergebnisse (tatsächlich ausgeführt)
`LH_SCRATCH=/tmp/labhub-build-d9 TEST_DB_NAME=labhub_d9 scripts/ci.sh` (shellcheck, OpenAPI-YAML, PWA-Prüfung und -Tests, Swift-Build, `swift test`): Exit 0, **350 Tests, 14 übersprungen (bekannte ocrmypdf-Werkzeugtests, keine neuen Skips), 0 Fehler**. Davor Teilläufe, die Fehler in den eigenen Tests fanden (Rechte-Matrix um `GET stats` ergänzt, Ablehnung statt Annahme im Zähltest). Nicht ausgeführt: `scripts/ocr-container-test.sh`. Rebase auf `main`: main unverändert (869696a), keine Konflikte; H9/H10 noch nicht auf main.
