# Handoff WP-R6a – Spike Server-Renderer

Stand 27.11.2026. Status: Spike abgeschlossen, F-08 entschieden (Nutzer, 27.11.2026: Typst). Bericht `docs/spikes/WP-R6a/BERICHT.md`, ADR 0008.

## Ergebnis
- Verglichen: Typst 0.15.1, WeasyPrint 70.0, Chromium 156 (+ Ghostscript 10.05.1 für PDF/A), je im Container mit read-only Root.
- Alle drei liefern die synthetische Musterrechnung (48 Positionen, 3 Seiten, Umlaute, Logo, Fußzeile „Seite x von y“) korrekt; Text identisch extrahierbar.
- PDF/A-3b (veraPDF 1.30.4): Typst und WeasyPrint nativ PASS, Chromium erst nach Ghostscript.
- Factur-X-XMP: WeasyPrint nativ; Typst braucht einen Nachbearbeitungsschritt (im Spike belegt, PASS).
- Laufzeit warm (3 Seiten): Typst 0,04 s, Chromium 0,34 s, WeasyPrint 0,45 s. Image komprimiert: 29 / 333 / 76 MB.
- Determinismus: Typst byte-identisch (auch amd64 = arm64), WeasyPrint mit `SOURCE_DATE_EPOCH`, Chromium nicht.
- Empfehlung: Typst, Rückfall WeasyPrint.

## Nicht gemacht / offen
- Option (a) Swift-Portierung nur auf dem Papier (App-Quelltext nicht verwendet).
- Kein Vergleich gegen Referenz-PDFs der App; keine Textpositions-Toleranz.
- WeasyPrint auf amd64 nicht geprüft; Factur-X-XML nicht schema-validiert (R5, F-26).
- Prototyp, Container und Images entfernt; kein Produktivcode.

## Nächster Schritt
- WP-R6b nach `docs/handoff/WP-R6-PLAN.md`.
