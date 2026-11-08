# Übergabe WP-D8 (weitere Dokumentarten im Extraktor)

Stand 08.11.2026, Branch `wp-D8` (auf `main`, Commit ea09a5f = bis D7). Test-DB `labhub_d8`. Implementierung und Tests aus derselben Session; kein Reviewer-Lauf (empfohlen: Regex-Laufzeit der neuen Detektoren, Vorzeichenlogik bei Salden/Erstattungen).

Nutzerentscheidung 08.11.2026: Vertrag, Versicherung, Steuer/Behörde, Kontoauszug und Kassenbon bekommen echte Detektoren mit eigenen Fakten. Faktentypen je Art: `docs/MODUL-DMS.md` Abschnitt 5.3a „Dokumentarten und Fakten“.

## Umgesetzt (`Modules/DMS/Extraction/`)
- Neue Detektoren: `ContractDetector`, `InsuranceDetector` (`ContractInsuranceDetectors.swift`), `AuthorityDetector` (je eine Instanz für `tax_notice` und `letter`), `BankStatementDetector`, `ReceiptDetector` (`StatementReceiptDetectors.swift`); gemeinsame Bausteine `ExtractionKindSupport.swift`, Parser `ExtractionParsersKinds.swift` (ISO-Zeitspannen `P3M`/`P4W`/`P30D`/`P1Y`, Zahlweise, Steuer-ID-Prüfziffer ISO 7064, Steuernummer-Format, Vorzeichen Soll/Haben/Minus). Die alten Stichwort-Detektoren dieser Arten entfallen.
- Keine Schemaänderung, keine Migration. `FactType` um 23 Typen erweitert (Liste erweiterbar; Wert immer Zeichenkette), `ExtractionResult.version` 2, `KindScore.primary` (Art hat eigenes Strukturmerkmal). `contracts/openapi.yaml`: nur das Enum der Faktentypen; `pwa/src/lib/api/types.ts` regeneriert (`npm --prefix pwa run gen:api`); keine neuen Problem-Codes, keine i18n-Zeilen.
- **Artwahl:** Score je Detektor, Schwellen 0,60 sicher / 0,35 unsicher / sonst `other` (unverändert). **Keine-Falschpositive-Regel:** Art ohne eigenes Strukturmerkmal (Überschrift oder Kennung; Behörde zusätzlich Behörde im Briefkopf/Absender) wird auf 0,45 gedeckelt (Behörde ohne Briefkopf 0,3; Kontoauszug ohne Saldo/Buchungszeilen 0,3). Konfliktregeln in `DocumentExtractor.resolve` (Begründung je Deckelung): Mahnung deckelt Rechnung; Behördenschreiben deckelt Mahnung (0,5) und Rechnung (0,3); Kassenbon/Kontoauszug mit Überschrift deckeln Rechnung ohne Rechnungsnummer; sichere Rechnung/Mahnung drückt Arten ohne eigene Struktur; Versicherungsschein deckelt Vertrag.
- **Übersichtsspalten je Art** (`DMSExtraction.summary`): Betrag = Rechnung Brutto / Vertrag `recurring_amount` / Versicherung `premium` / Behörde `settlement_amount` (negativ = Erstattung) / Kontoauszug `balance_closing` / Kassenbon Summe; Fälligkeit/Frist = Rechnung und Versicherung `due_date`, Vertrag `period_end`, Behörde früheste von `due_date`, `objection_deadline`, `deadline`; Referenz = Nummer/Aktenzeichen, beim Kontoauszug IBAN. Damit finden `due_from/due_to/sort=due_date` Fristen aller Arten.
- Robustheit: ein bereits in D7 vorhandenes quadratisches Regex-Verhalten (`InvoiceDetector.titleLine` mit `\s*` bei sehr vielen Leerzeilen) auf `[ \t]*` umgestellt, Ergebnis unverändert; die neuen Detektoren suchen Werte in begrenzten Fenstern (nicht bis zum Textende), `testHugeInputIsBounded` (D7, unverändert) und ein neuer Test mit feindlichen Eingaben bleiben im Limit.

## Akzeptanzkriterien und Tests
| AK | Inhalt | Test |
| --- | --- | --- |
| AK-D8-1…5 | je Art (Vertrag, Versicherung, Behörde/Steuer, Kontoauszug, Kassenbon): >= 6 Positiv- und >= 4 Negativ-/Grenzfälle im Entwicklungskorpus (zusammen mit Holdout je Art >= 9 Positiv, >= 8 Negativ), Precision 1,0, Recall/Art-Genauigkeit/Feld-Trefferquote >= 0,95 | `ExtractionKindsTests.testAKD8_dev_corpusSizes`, `testAKD8_dev_qualityPerKind` |
| AK-D8-6 | Konflikte Rechnung/Mahnung/Vertrag/Behörde, Rechnung bleibt Precision 1,0 und Recall 1,0 über D7- und D8-Korpus | `testAKD8_conflictsDoNotOverrideEachOther`, `testAKD8_authorityReminder…`, `testAKD8_invoiceStillPerfectAcrossBothCorpora`, `ExtractionTests` (D7, unverändert) |
| AK-D8-7 | deterministisch, jeder Fakt mit Begründung, Fundstelle im Text, Beträge als Dezimalzeichenkette | `testAKD8_deterministicAndExplainableForEveryCase`, `testAKD8_explainableWithFundstelle…` |
| AK-D8-8 | Neu-Lauf-Route für alle Arten, idempotent (zwei Instanzen), kein zweites Ereignis | `DMSKindsApiTests.testAKD8_8_10_…` |
| AK-D8-9 | Holdout-Korpus (nach dem Einfrieren geschrieben), Schwellen: Precision 1,0, Recall >= 0,75, Art >= 0,8, Felder >= 0,75 | `testAKD8_holdout_qualityPerKind` |
| AK-D8-10 | Fristen in der Fälligkeitsspalte, Filter `due_from/due_to`, Sortierung; Summen/Referenz je Art | `DMSKindsApiTests`, `ExtractionKindsTests` (Übersicht) |
| AK-D8-11 | Parser/Validierung: Zeitspannen, Zahlweise, Steuer-ID-Prüfziffer, Steuernummer, Vorzeichen, ungültige IBAN/Steuer-ID ergeben keinen Fakt, Erweiterbarkeit | `testAKD8_durationsAndDateMath`, `…intervals`, `…taxIDAndTaxNumberValidation`, `…signedAmounts…`, `…receiptTaxShares…`, `…kindsAreExtensible…`, `…hugeAndHostile…` |

## Qualität (gemessen am 08.11.2026, Entwicklung und Holdout getrennt)
**Entwicklungskorpus** (`ExtractionCorpusKinds.swift`, 64 Fälle; Regeln wurden daran geschärft, Zahlen daher optimistisch): Precision 1,0 und Recall 1,0 und Art-Genauigkeit 1,0 in allen fünf Gruppen (Vertrag 15 Fälle, Versicherung 12, Behörde/Steuer 13, Kontoauszug 12, Kassenbon 12); Feld-Trefferquote 55/55 (Vertrag), 42/42, 53/53, 38/38, 35/35.

**Holdout** (`ExtractionCorpusHoldout.swift`, 35 Fälle = 35 % aller 99 Fälle; geschrieben nach dem Freeze-Commit fdf60e6, Regeln danach nicht mehr verändert): Precision 1,0, Recall 1,0, Art-Genauigkeit 1,0 in allen Gruppen (je 7 Fälle, Kontoauszug 5 echte Positive); Feld-Trefferquote Vertrag 23/25, Versicherung 20/20, Behörde/Steuer 20/21, Kontoauszug 22/22, Kassenbon 19/19 (gesamt 104/107 = 0,97). Gefundene Lücken (nicht behoben, um den Holdout nicht zu verbrauchen): Kündigungsfrist im Satz „mit einer Frist von 4 Wochen gekündigt“ (Verb steht hinter der Frist), Laufzeit im englischen Satz „runs for 24 months“, Aktenzeichen mit Leerzeichen (`12 C 345/26`).

**Ehrlich:** Beide Korpora hat derselbe Autor in derselben Session geschrieben (Holdout nur zeitlich getrennt, nicht von einer zweiten Person); Texte sind kurz und sauber, ohne OCR-Rauschen, Mehrseitigkeit oder echte Layouts. Die 1,0-Werte sagen nichts über echte Belege. Messung an echten, anonymisierten Dokumenten steht aus (keine Bestandsdaten gelesen).

## Offen / Annahmen
- Fristen werden nur aus beschrifteten Daten oder „Bescheid + Dauer“ abgeleitet (Konfidenz 0,5, Hinweis „ohne Bekanntgabefiktion“); keine Fristberechnung nach Recht, keine Rechtsberatung.
- `notice_type` nur aus Überschrift/Betreff/Briefkopf. Mehrere Beträge je Art: höchster Rang der Beschriftung, bei Gleichstand der erste (Kassenbon: letzter) Treffer; Buchungszeilen des Kontoauszugs werden gezählt, aber nicht als Fakten gespeichert.
- Der Dokumenttyp-Vorschlag setzt wie in D7 einen passenden Typ im Mandanten voraus (`typeNames`); Behörde/Steuer map auf `tax_notice`/`letter`.
- Bestand: Massen-Neu-Lauf nach Versionssprung 1 -> 2 fehlt weiter (Einzel-Neu-Lauf per Route).
- Sprachen nur de/en. Die PWA zeigt die neuen Fakten noch nicht (UI-WP).
- D7-Regex `InvoiceDetector` hat weitere unbegrenzte `\s*`-Muster; nicht verändert, soweit der Test sie nicht traf.

## Ergebnisse (tatsächlich ausgeführt)
`LH_SCRATCH=/tmp/labhub-build-d8 TEST_DB_NAME=labhub_d8 scripts/ci.sh` (shellcheck, OpenAPI-YAML, PWA-Prüfung und -Tests, Swift-Build, `swift test`): Exit 0, **343 Tests, 14 übersprungen (die bekannten ocrmypdf-Werkzeugtests, keine neuen Skips), 0 Fehler**. Davor mehrere Teilläufe (`--filter`), die echte Fehler fanden (Versicherer-Regex ohne Groß-/Kleinschreibung, Kreditkarten-Phishing-Muster traf „Kreditkartenabrechnung“, Trailing-Minus-Vorzeichen, quadratische Fenstersuche bei sehr langen Zeilen) und behoben wurden. Nicht ausgeführt: `scripts/ocr-container-test.sh`.
