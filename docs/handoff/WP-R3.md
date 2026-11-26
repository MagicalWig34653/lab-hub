# Handoff WP-R3 – Zahlungen, Skonto, Gutschrift, Umwandlung, Verknüpfungen

Stand 25.11.2026, direkt auf `main` ab `2b6c4c7`. Abhängigkeit R2 erfüllt. Karte B8C3AF35 (Todolino).

## Umgesetzt
- Migration `invoice_029_payments` (`Modules/Invoice/InvoicePaymentMigrations.swift`, Expand-only, Revert vorhanden, `schema_version` unverändert wie bei den Modulmigrationen davor): Spalten `skonto_percent`/`skonto_days` am Beleg; Tabellen `invoice_payments`, `invoice_payment_allocations`, `invoice_document_links`; drei Trigger.
- `Modules/Invoice/InvoicePayments.swift`: Zahlungen (anlegen, lesen, Liste, Storno), Vorschläge (nur Lesen), ausdrückliche Zuordnung und Rücknahme, Saldo.
- `Modules/Invoice/InvoiceLinks.swift`: Umwandlung, Gutschrift, Verknüpfungen, Prüfungen beim Finalisieren einer Gutschrift.
- `InvoiceDocuments`: Skontobedingung am Beleg (nur gemeinsam; im Inhaltshash nur, wenn gesetzt, damit Hashes aus R2 nachrechenbar bleiben), Belegart erzeugter Entwürfe gesperrt.
- Berechtigungen `invoice.payment.read` (accountant, member, tax_advisor, Owner) und `invoice.payment.write` (accountant, Owner); 13 neue Routen; Fehlercodes `document_not_final`, `document_link_locked`, `payment_voided`, `payment_allocated` (Backend und PWA de/en); Vertrag und `pwa/src/lib/api/types.ts`.
- Details und Routen: `MODUL-RECHNUNG.md` Abschnitt 15.

## Tests
Zuerst rot: `lab-hub-postgres.sh --filter 'InvoicePaymentTests|InvoiceLinkTests'` vor der Umsetzung, 11 Tests, 235 Fehler. Danach grün.

- `InvoicePaymentTests`: AK-R3-1 alle 5 Salden-Vektoren Ende-zu-Ende, AK-R3-2 Zuordnung nie still, AK-R3-3 Skonto, AK-R3-4 Grenzen und Storno, AK-R3-5 parallel über zwei Instanzen (Zahlung, Rechnung, zwei Gutschriften), AK-R3-6 Datenbank-Invarianten per SQL, AK-R3-10 Migration Revert/Reapply.
- `InvoiceLinkTests`: AK-R3-7 Gutschrift, AK-R3-8 Umwandlung und Verknüpfungen, AK-R3-9 Rechtematrix und Mandantentrennung, **AK-R3-11 durchgehender Weg über echten HTTP-Server gegen Postgres** (Angebot → Rechnung → Zahlung → Vorschlag → bestätigte Zuordnung mit Skonto → Teilgutschrift → Saldo).
- Angepasst: Revert-Tests AK-R1-12 und AK-R2-14 bauen `invoice_029_payments` zuerst zurück; Tabellenliste der Testdatenbank ergänzt.

## Annahmen (zur Bestätigung durch den Nutzer)
1. **Skonto (`OFFENE-FRAGEN.md` F-32):** In der bisherigen App gibt es keine Rechenregel (R0-Befund). Angenommen: eine Stufe (Satz und Frist in Tagen ab **Belegdatum**), Frist gilt für das **Zahldatum** der ausgleichenden Zahlung, höchstens Satz × (Brutto − Gutschriften), kaufmännisch auf Cent, nur wenn der Rest damit vollständig ausgeglichen ist. Keine Kulanz über Frist oder Satz hinaus. Keine USt-Korrekturbuchung (gehört zu R7).
2. **Zuordnung:** auch bei eindeutigem Treffer nie automatisch; `confirmed: true` plus Beleg und Betrag aus der Anfrage. Nur auf finale Rechnungen gleicher Währung. Je Zahlung und Beleg höchstens eine aktive Zuordnung.
3. **Rechte:** Erfassen, Zuordnen und Stornieren nur Buchhaltung und Owner (wie Finalisieren).
4. **Gutschrift:** Entwurf mit negierten Mengen; beim Finalisieren negativ, gleicher Kontakt, gleiche Währung, in Summe nie mehr als die Rechnung. Eine Gutschrift ohne Verknüpfung (von Hand angelegt) bleibt möglich und wirkt auf keinen Saldo.
5. **Umwandlungswege:** Angebot → Auftragsbestätigung, Lieferschein, Rechnung; Auftragsbestätigung → Lieferschein, Rechnung; Lieferschein → Rechnung. Ein Beleg kann mehrfach umgewandelt werden (Teilrechnungen ohne Mengenabgleich). Fälligkeit wird nicht übernommen.
6. **Gutschrift nach Zahlung:** Wird eine Gutschrift nach vollständiger Zahlung finalisiert, zeigt der Saldo `overpaid` (Erstattung fällig). Die Datenbankregel „Zuordnungen ≤ Rechnung abzüglich Gutschriften“ gilt beim Zuordnen.
7. **Storno von Belegen:** Status `cancelled` bleibt ohne Route; Korrektur läuft über die Gutschrift.

## Offen
- Kein Reviewer-Lauf.
- Obergrenze „Gutschriften ≤ Rechnung“ prüft der Dienst unter Zeilensperre, kein eigener Datenbank-Trigger.
- Listen ohne Cursor (höchstens 1000).
- UI (F6), Berichte (R7), Bankimport (R3b) bauen auf diesen Routen auf.
