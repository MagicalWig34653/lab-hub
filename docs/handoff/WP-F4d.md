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

## Ergebnisse (tatsächlich ausgeführt, 17.11.2026, rebased auf main mit H10b/H11/H12, keine Konflikte, types.ts unverändert aktuell)
- `npm run check` grün, `npm test` 104 Tests grün.
- `npm run test:e2e:mock`: 57 von 57 grün. Frühere Timeouts bei Systemlast (Load 48 bis 100) und zwei echte Spec-Fehler in `dms-d9.spec.ts` (Quellfilter im eingeklappten Bereich; Listenfilter findet auch Vertragsende) sind behoben.
- `TEST_DB_NAME=labhub_f4d scripts/ci.sh`: Exit 0, 393 Tests, 14 übersprungen, 0 Fehler (letzter Lauf, Postgres lief). Zwei frühere Läufe waren nicht gültig: Lauf 1 scheiterte an `ExtractionTests.testHugeInputIsBounded` (Lasttest bei Load ~100; Einzelwiederholung 22 Tests grün, Test unverändert), Lauf 2 an `ApiPostgresTests.testIdempotencyMiddlewareParallelRunsWorkOnce` (Datenbank zeitweise aus; Einzelwiederholung 5 Tests grün).
