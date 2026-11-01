# Handoff WP-R0 – Spike Rechenkern unter Linux

Stand 01.11.2026. Status: Spike abgeschlossen, Ergebnis in `docs/MODUL-RECHNUNG.md` Abschnitt 12.

## Ergebnis
- `TaxlabCore` und `TaxlabModel` (inkl. Nummernformat) bauen und testen unter `swift:6.2` (Swift 6.2.4) ohne Änderung: 53 bzw. 135 Tests grün.
- `TaxlabReports` ohne PDF-Export: 101 Tests grün (1 Quelldatei, 2 Testdateien abgetrennt).
- `TaxlabEInvoice`: Bibliothek baut nach Abtrennen von PDF/A-3 und Reader-PDF-Teil plus `FoundationXML`-Import; Tests wegen `RenderData` (in `TaxlabRender`) nicht gelaufen.
- `TaxlabLayout` (CoreFoundation) und `TaxlabRender` (CoreGraphics) brauchen Portierung, Sache von WP-R6a.
- 50 synthetische Testvektoren (Dezimal-Strings) unter `backend/Tests/Fixtures/taxlab-vectors/`, erzeugt mit der taxlab-Referenz unter Linux.

## Ausgeführt
`scripts/spike-r0/linux-build.sh` (Core/Model grün; Layout/Storage unverändert Fehler wie dokumentiert), `linux-patched.sh` (Reports grün; EInvoice-Bibliothek baut, Tests ohne `RenderData` nicht ausführbar), `linux-patched-einvoice.sh` (Render-Build scheitert noch an `FoundationXML` und Type-Check), `generate-vectors.sh`. Docker-Image `swift:6.2`. taxlab nur lesend: gefilterte Kopie der `*.swift`/`Package.swift` außerhalb beider Repos; Docker (Colima) muss den Ordner mounten können (ein Ordner unter dem Home-Verzeichnis, nicht `/tmp`).

## Offen
- Entscheidung F-27 (Nutzer): Option A (gemeinsames Repo) vs. B (Neuimplementierung); Empfehlung A für Core/Model, siehe Abschnitt 12.
- Hub-Konformitätstest, der die Vektoren liest, entsteht in WP-R2 (R0 enthält keinen Hub-Code).
- Skonto-Regeln nicht im Rechenkern gefunden (R3).
