# Handoff WP-R6b – Render-Werkzeugkette und Standardlayout 1

Stand 27.11.2026. Status: **fertig** (Code und Tests); kein Deploy, keine Image-Veröffentlichung. Grundlage: `docs/handoff/WP-R6-PLAN.md`, ADR 0008.

## Umgesetzt
- `backend/Sources/HubModuleInvoice/Render/`: `InvoiceRenderer` (eingefrorene Belegdaten als JSON wie `InvoiceDocuments.fetch` → PDF/A-3b; Arbeitsverzeichnis unter `/tmp`, `--root` darauf, `--ignore-system-fonts`, `--creation-timestamp` = `finalized_at`, Zeit- und Speicherlimit, Umgebung nur `PATH`/`HOME`/`LC_ALL`), `InvoiceRenderData` (Aufbereitung mit `Decimal`), `InvoiceStandardLayout` (Layout `standard`, Version 1, fünf Belegarten, Lieferschein ohne Preise), `FacturXMetadata` (`fx:`-Schema in die vorhandene `pdfaExtension`-Liste).
- Anhang optional (`factur-x.xml`, `AFRelationship=Alternative`), nur bei Rechnung und Gutschrift; ohne XML kein `fx:`-Eintrag. XML-Erzeugung ist WP-R5.
- Nutzerdaten gehen nur als `data.json` an die Vorlage; keine Paketimporte, Paketverzeichnisse zeigen ins Leere. Ligaturen und `calt` sind aus, damit Text Zeichen für Zeichen erscheint.
- `OCRProcess` heißt jetzt `ToolProcess` und liegt in `HubCore` (beide Module nutzen ihn); neu: `inheritEnvironment: false`.
- `Dockerfile.worker`: Typst 0.15.1 per Digest, Inter 4.1 mit `--checksum`, neue Stufe `worker-tools` (Basis von `worker`); `worker-test` ebenso. API-Image unverändert.
- Lizenzen: `legal/third-party/{typst,typst-assets,inter}/`, `legal/THIRD-PARTY-NOTICES.md`, `docs/LIZENZEN.md`; `scripts/check-third-party-notices.sh` prüft Pins, Prüfsummen und Inhalt.
- CI: Job `backend` (amd64, volle Suite) prüft zusätzlich veraPDF und das Laufzeit-Image; neuer Job `render-arm64` (Render- und Datenbanktests, veraPDF, Rauchtest).

## Belegte Annahme
`qpdf --update-from-json` (qpdf 11.9 aus Ubuntu 24.04) genügt für den Metadatenschritt; ein eigener PDF-Schreiber ist nicht nötig. Zwei Bedingungen: `--newline-before-endstream` (ohne: veraPDF FAIL, ISO 19005-3 6.1.7.1) und die Update-Datei ohne maskierte Schrägstriche (qpdf liest Stromdaten sonst nicht). `--deterministic-id` hält die Bytes gleich.

## Akzeptanz
| AK | Test (`InvoiceRenderTests.swift`) |
| --- | --- |
| R6b-1 | `testAKR6b_1_referenceCasesMatchPagesAndText` (Referenzen `Tests/Fixtures/invoice-render/*.txt`: Seitenzahl und Text), `testAKR6b_1_referenceCasesCoverLayoutBlocks`, Aufbereitungstests `testAKR6b_1_*` |
| R6b-2 | `testAKR6b_2_*` und `scripts/verapdf-check.sh` (5 Referenzfälle, 2 mit XML, 1 E2E-Beleg = 8 PDF), in der CI auf amd64 und arm64 |
| R6b-3 | `testAKR6b_3_sameInputSameBytesAcrossRunsAndArchitectures`: zwei Läufe mit Pause und Vergleich mit `Tests/Fixtures/invoice-render/checksums.sha256`; dieselbe Datei gilt für CI amd64 und arm64 |
| R6b-4 | `testAKR6b_4_typstSyntaxInUserTextIsPrintedLiterally`, `testAKR6b_4_timeoutKillsRenderer` (Prozess nachweislich beendet), `testAKR6b_4_timeoutAlsoStopsTypst`, `testAKR6b_4_templateImportsNothingAndEvaluatesNothing` |
| R6b-5 | `scripts/check-third-party-notices.sh` (rot vor dem Ablegen der Texte, danach grün) |

E2E: `testE2E_finalizedDocumentFromApiRendersToPDF` (Beleg über die API anlegen und finalisieren, gelieferte Daten rendern, Text und Summen prüfen). Ein E2E mit Worker folgt mit R6c (AK-R6c-6).

Tests zuerst rot: Commit `58c1d62` (18 von 21 fehlgeschlagen, 3 ohne qpdf/Datenbank übersprungen).

## Gegenlesen (eigener Durchgang, 4 Befunde, alle behoben, Tests vorher rot)
- Summenblock war nicht umbrechbar und lief bei vielen Zusatzkosten über Fußzeile und Seitenrand → bricht um, sobald er höher als 120 mm ist (`testLongSummaryStaysOnThePage`).
- Gerundete Positionswerte konnten von der je Steuersatz gerundeten Summe abweichen, ohne dass das PDF es zeigt → Zeile „Rundungsdifferenz“ (Wortlaut: F-38).
- „innerhalb von 1 Tagen“ / „0 Tagen“ → eigene Formulierungen.
- Verweise auf nicht vorhandene Dateien berichtigt.

## Grenzen und offen
- Noch kein Job, keine Datenbank, keine Route, kein PDF-Download (R6c).
- Das eingebettete XML wird nicht geprüft; die Test-XML ist ein Platzhalter. Factur-X-Konformität des XML kommt mit R5; `ConformanceLevel` ist Standard `EN 16931`.
- F-38: Wortlaut der Hinweiszeilen fachlich prüfen. F-37: Reihenfolge zu R5.
- Eingebettete Typst-Schriften bleiben als Rückfall aktiv; fehlt ein Zeichen in allen Schriften, schlägt das Rendern fehl (PDF/A verbietet fehlende Glyphen). R6c muss diesen Fehler dem Nutzer verständlich melden. `InvoiceRenderError.failed.diagnostics` kann Belegtext enthalten und gehört nicht ins Log.
- Das Speicherlimit (1 GiB Adressraum) wirkt nur unter Linux.
- Neue Typst-, Schrift- oder Layoutversion ändert die Bytes: Referenzen mit `LH_RENDER_UPDATE=1` neu schreiben, bei sichtbarer Änderung `InvoiceStandardLayout.version` erhöhen.

## Nächster Schritt
WP-R6c (Render-Job, Speicherung, Download) nach `docs/handoff/WP-R6-PLAN.md`.
