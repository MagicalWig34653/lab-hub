# Übergabe WP-F4d (PWA an D8/D9 angepasst)

Stand 17.11.2026, Branch `wp-F4d` (auf Commit 31d51c8 von `main`, enthält D8, D9, H10). Nur `pwa/**`, `docs/FRONTEND.md` (Abschnitt „Umsetzung WP-F4d“), eine Zeile in `docs/ROADMAP.md`, dieses Dokument. Kein Backend-, Vertrags- oder Migrationsänderung; `types.ts` unverändert (D9 hatte sie schon regeneriert).

## Umgesetzt
- **Summenzeile je Währung** in der Dokumentliste (`dms-totals`): `GET documents?totals=true&limit=1` mit denselben Filtern wie die Tabelle (`toTotalsQuery`), also über die ganze gefilterte Menge, nicht über die geladenen Zeilen. Währungen getrennt, Betrag ohne Währung eigene Gruppe. Mit Suchbegriff keine Summe (Suchroute liefert keine), Hinweis statt Zahl.
- **Quelle:** Spalte (ab `xl`) und Filter `source` (URL-Parameter), Anzeige auch bei Suchtreffern.
- **Eine Route:** Suche nimmt jetzt Art-/Betrags-/Fälligkeitsfilter, Quelle, `has_open_suggestions` und Sortierung; Treffer tragen `extraction`, `source`, `open_suggestions` (Art und Betrag in der Zeile). Nur der Papierkorb bleibt auf `…/documents`. Entfallen: Einzelabrufe je Treffer, Laden/Client-Filtern der Vorschläge samt 1000er-Kappung, Hinweise `listRoute`/`listRouteQ`/`openCapped`.
- **Dashboard-Karte:** Zähler aus `GET dms/stats` (in Verarbeitung, Quarantäne, offene Vorschläge, überfällig, neu in 7 Tagen, `today` = lokaler Tag), dazu „Zu prüfen“ und „Quellen mit Fehler“ wie bisher; Karten verlinken in die gefilterte Übersicht. Die Quarantäne ist jetzt zählbar (Hinweistext entfallen).
- **Fakten je Art** (Vertrag, Versicherung, Behörde/Steuer, Kontoauszug, Kassenbon): Beschriftungen aller 23 neuen Faktentypen, lesbare Werte (`factValue`): Beträge mit Vorzeichen, ISO-Zeitspannen über `Intl` („3 Monate“), unbefristet, Zahlweise, Art des Schreibens, Zahlart, Ja/Nein, IBAN gruppiert; Unbekanntes unverändert.
- **i18n:** neue Schlüssel de/en in `messages-overview.ts`/`messages-sources.ts`; `messages.test.ts` unverändert (Vollständigkeit, Platzhalter, keine toten Schlüssel).
- **Mock:** `source`, `open_suggestions`, `totals`, `dms/stats`, Filter und Sortierung an der Suche, Seed-Optionen `source`, `suggestions`, `created_days_ago`, `extraction.facts`.

## Tests
Vitest `overview.test.ts` erweitert (Test „extraction filters … list route“ ersetzt durch die D9-Regel „nur Papierkorb = Listenroute“, weil sich das Verhalten bewusst geändert hat; alle anderen Fälle unverändert). Mock-E2E neu `e2e-mock/dms-d9.spec.ts` (Summen/Quelle/Suche, Vorschlagsfilter, Dashboard-Zähler, Fakten je Art); in `dms-overview.spec.ts` ein Satz angepasst (Art-Filter plus Suche bleibt auf der Suchroute, kein Routenhinweis mehr).

## Offen
- Zeitbereich: Tabelle (Suche) = `doc_date`, Summe (Liste) = erkanntes Belegdatum (`extracted_*`); beide Filter werden mit demselben Wert gesetzt, Abweichungen möglich (Lücke 6 aus F4c, Backend unverändert).
- Keine Summe bei Suchbegriff (nur Hinweis).
- Echter E2E gegen Backend (`test:e2e:dms`) nicht ausgeführt.

## Ergebnisse (tatsächlich ausgeführt, 17.11.2026)
- `npm run check`: grün. `npm test`: 104 Tests grün.
- `npm run test:e2e:mock`: erster Lauf 22 Timeouts bei Systemlast (Load 48 bis 100, auch unveränderte Specs); Wiederholung 55 von 57 grün, die 2 Fehler waren echt und in `dms-d9.spec.ts` behoben (Quellfilter liegt unter dem eingeklappten „Weitere Filter“; Fälligkeitsfilter der Liste findet auch das Vertragsende, daher 3 statt 2 Zeilen, der Zähler `overdue` zählt Verträge nicht). Danach `dms-d9.spec.ts` einzeln 4 von 4 grün. Der Gesamtlauf mit den Korrekturen wurde nicht wiederholt.
- `TEST_DB_NAME=labhub_f4d scripts/ci.sh`: shellcheck, OpenAPI, PWA-Prüfung, Build ok; Swift 379 Tests, 14 übersprungen, 1 Fehler: `ExtractionTests.testHugeInputIsBounded` (Backend, unverändert; 10-s-Laufzeitgrenze bei Load ~100, Ergebnis `other` statt `invoice`). Einzelwiederholung `--filter ExtractionTests`: 22 Tests, 0 Fehler. Das Gate endete damit formal mit Exit 1; ein sauberer Gesamtlauf bei normaler Last steht aus.
