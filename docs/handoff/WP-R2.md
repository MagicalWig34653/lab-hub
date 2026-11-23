# Handoff WP-R2 – Belege, Berechnung, Finalisieren

Stand 23.11.2026, Branch `wp-R2` (Push per `git push origin HEAD:main`, kein Force). Abhängigkeiten R1 und K6 erfüllt. Umgesetzt von der Implementierungs-Session, die lab-hub-cc übernommen hat (Auftrag des Orchestrator-Brains).

## Umgesetzt
- `Modules/Invoice/InvoiceCalculator.swift`: Rechenkern (Rundung je Steuersatz auf Belegebene, Netto-/Brutto-Modus, Positions- und Belegrabatt, Zusatzkosten ohne Rabatt, drei Rundungsmodi, Zweitmenge), strenger Dezimal-Parser. Kein Gleitkomma, keine Datenbank, keine Uhr.
- `Modules/Invoice/InvoiceDocumentMigrations.swift`: Migration `invoice_028_documents` (Expand-only, Revert): `invoice_documents`, `invoice_lines`, `invoice_charges`, `invoice_tax_totals`, Trigger `invoice_documents_guard` und `invoice_children_guard`, CHECKs und Teilindex für eindeutige Nummern.
- `Modules/Invoice/InvoiceDocuments.swift`: Routen (Liste, Anlegen, Lesen, Ändern, Löschen, Finalisieren), Eingabeprüfung mit Feldfehlern wie `lines.0.quantity`, Neuberechnung bei jedem Speichern, Finalisieren in einer Transaktion.
- `InvoiceModule`: deklariert jetzt `invoice.document.read|create|update|finalize`; die vier Einträge sind aus dem Kernkatalog `Tenancy/Roles.swift` entfernt. `InvoiceIdempotency.run` hat einen Statusparameter (Finalisieren antwortet 200).
- Vertrag: 4 neue Pfade, Schemas `InvoiceDocument`/`InvoiceDocumentInput`, Fehlercodes `document_final_immutable`, `number_conflict`; `pwa/src/lib/api/types.ts` neu erzeugt (openapi-typescript 7.13.0), i18n de/en für beide Codes.
- Doku: `MODUL-RECHNUNG.md` Abschnitt 14, `ROADMAP.md`.

## Tests
`InvoiceCalculatorTests` (AK-R2-1…3: 14 Rundungs- und 16 Belegvektoren, strenge Dezimalschreibweise) und `InvoiceDocumentTests`:
AK-R2-4 Summen vom Server (Vektor `net-mixed-rates` 261.22 / 30.68 / 291.90), AK-R2-5 Ändern rechnet neu (Brutto, Belegrabatt, Zusatzkosten, Löschen), AK-R2-6 Rollenmatrix je Rolle und Aktion, AK-R2-7 Mandantentrennung (404 auf allen Beleg-Routen, fremde Kontakte/Serien/Typen 422, SQL über Mandantengrenze scheitert), AK-R2-8 Finalisieren (Nummer, Einfrieren, Hash, 409 beim zweiten Mal, Serie danach in Benutzung), AK-R2-9 Idempotenz mit Key (zwei Instanzen, 8 parallel, genau eine Nummer), AK-R2-10 unvollständige Belege verbrauchen keine Nummer, AK-R2-11 `number_conflict` rollt den Zähler zurück, AK-R2-12 Zähler je Jahr nach Belegdatum, AK-R2-13 Unveränderlichkeit per SQL (UPDATE/DELETE/INSERT an Beleg, Positionen, Zusatzkosten, Steuersummen), AK-R2-14 Migration Revert/Reapply, **AK-R4: 50 parallele Finalisierungen über zwei Instanzen = Nummern RE-0001…RE-0050 lückenlos und eindeutig, Zähler 50; 6 parallele Finalisierungen desselben Belegs = genau eine gewinnt.**
Mutationsbeweis: Trigger auf `invoice_lines` entfernt → AK-R2-13 rot (3 Fehler: UPDATE, DELETE, INSERT an Positionen gehen durch); Trigger wiederhergestellt → grün.

## Annahmen (zur Bestätigung durch Lino)
1. **Rollen:** Lesen accountant/member/tax_advisor/Owner; Anlegen und Ändern accountant/member/Owner; Finalisieren nur accountant/Owner (wie im bisherigen Kernkatalog).
2. **Zähler-Zeitraum** (Jahr/Monat bei Serien je Jahr/Monat) richtet sich nach dem **Belegdatum** (`issue_date`), nicht nach dem Tag des Finalisierens. Folge: Ein im Januar finalisierter Beleg mit Datum im Dezember zählt im alten Jahr weiter. Die Vorschau der Serie in R1 (`next_number_preview`) nutzt weiter den laufenden Zeitraum.
3. **Steuerregime** wird beim Finalisieren aus dem Steuerzeitraum zum Belegdatum festgehalten; ohne passenden Zeitraum `standard`.
4. **Nummernformat mit `{CLIENT}`/`{PROJECT}`** lässt sich noch nicht finalisieren (422), bis es Kundennummer/Projektcode gibt; `{ABBR}` braucht das Kürzel in den Einstellungen.
5. **Empfänger** ist ein Schnappschuss des Kontakts (Name, Firma, USt-IdNr., erste Adresse nach Position), **Absender** ein Schnappschuss der Einstellungen (ohne Zahlungsziel/Fußtext). Fußtext und Zahlungsziel werden noch nicht automatisch in den Beleg übernommen (UI/WP-R6).
6. **Beträge:** Summen auf 2 Stellen (Rundungsstellen sind noch nicht je Beleg einstellbar, nur der Modus), Zeilenwerte mit bis zu 4 Nachkommastellen, höchstens 14 Vorkommastellen; Summen ab 10^14 werden mit 422 `amount_too_large` abgelehnt. Obergrenzen 500 Positionen, 50 Zusatzkosten je Beleg.
7. **Stornierung/Gutschrift:** Status `cancelled` ist im Schema vorgesehen, aber noch keine Route; Korrekturen laufen später über WP-R3 (Gutschrift). Finale Belege können nicht gelöscht werden.
8. **Inhaltshash:** SHA-256 über den kanonischen Inhalt (jsonb-Text von Kopf, Positionen, Zusatzkosten, Steuersummen), Nummer, Zählerwert, Serie, Regime, Absender und Empfänger (je durch Zeilenumbruch getrennt). Prüfwerkzeug zum Nachrechnen kommt mit dem Export (R4/R5).
9. Liste ohne Cursor (höchstens 1000, neueste zuerst), wie bei den Stammdaten.

## Offen
- Kein Reviewer-Lauf. Nicht geprüft: Verhalten bei sehr vielen parallelen Finalisierungen derselben Serie über 50 hinaus (Zählerzeile ist der Engpass, wie gewollt), Wartezeit bei gesperrten Zeilen unter hoher Last.
- UI (F6) und Renderer (R6) bauen auf diesen Routen auf; PWA-Texte für `nav.invoice` fehlen weiter.
