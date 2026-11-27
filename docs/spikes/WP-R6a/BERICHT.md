# Spike WP-R6a – Server-Renderer für Belege (Entscheidungsgrundlage F-08)

Stand 27.11.2026. Wegwerf-Prototyp außerhalb des Repos (Container, Vorlagen, Messskripte sind entfernt). Im Repo liegen nur dieser Bericht und drei erzeugte Beispiel-PDFs. ADR 0008 (`docs/decisions/0008-server-renderer.md`). **Nachtrag:** F-08 ist am 27.11.2026 entschieden (Typst + Factur-X-Metadatenschritt); der Bericht gibt den Stand des Spikes wieder.

## 1. Kurzfassung

| | (c) **Typst** | (b′) **WeasyPrint** (HTML/CSS) | (b) **headless Chromium** (HTML/CSS) + Ghostscript |
| --- | --- | --- | --- |
| Ergebnis Musterrechnung (3 Seiten) | korrekt, angesehen | korrekt, angesehen | korrekt, angesehen |
| PDF/A-3b (veraPDF 1.30.4) | **PASS** nativ (`--pdf-standard a-3b`) | **PASS** nativ (`--pdf-variant pdf/a-3b`) | Rohausgabe **FAIL**; erst nach Ghostscript-Konvertierung PASS |
| XML-Anhang mit `AFRelationship=Alternative` | nativ (`pdf.attach`) | nativ (`-a … --attachment-relationship Alternative`) | nicht geprüft (nur per pdfmark/Zusatzwerkzeug) |
| Factur-X-XMP (`fx:`-Schema) | **fehlt**, Nachbearbeitung nötig (im Spike: PASS nach Einfügen) | nativ (`--xmp-metadata`) | nicht geprüft |
| Laufzeit je Beleg, warm (3 / 17 Seiten) | **0,03–0,04 s / 0,26 s** | 0,44–0,46 s / 1,58 s | 0,33–0,35 s / 0,51 s (+ 0,08 s Ghostscript bei 3 Seiten) |
| Speicher-Spitze im Container (3 / 17 Seiten) | 37 / 62 MiB | 67 / 111 MiB | 197 / 285 MiB |
| Image (komprimiert / entpackt, arm64) | **29 MB / 87 MB** (Alpine + statisches Binary 49 MB) | 76 MB / 345 MB | 333 MB / 1,23 GB (inkl. Ghostscript ≈ 25 MB) |
| Determinismus (gleiche Eingabe → gleiche Bytes) | **ja**, auch amd64 = arm64 (identischer SHA-256) | ja mit `SOURCE_DATE_EPOCH`, sonst Zeitstempel | nein (CreationDate/ModDate); Text und Rasterbild identisch |
| Read-only-Root + `tmpfs /tmp` (ADR 0003) | läuft | läuft (`XDG_CACHE_HOME=/tmp`) | läuft (`HOME=/tmp`, `--no-sandbox` als root nötig) |
| Lizenz | Apache-2.0 | BSD-3-Clause (Pango LGPL-2.1+) | Chromium BSD-3 u. v. a.; Ghostscript AGPL-3.0 |
| Aufwand bis R6 (Schätzung) | M: Layoutmodell → Typst-Vorlage, XMP-Schritt | M: Layoutmodell → HTML/CSS | M–L: wie b′ plus PDF/A-, Anhang- und XMP-Kette |

**Empfehlung: (c) Typst** als Server-Renderer im Worker, mit einem kleinen Nachbearbeitungsschritt für die Factur-X-XMP-Metadaten. Begründung: zehnmal schneller als die HTML-Varianten, kleinstes Image, byte-deterministisch ohne Zusatzschalter und über beide Architekturen gleich (passt zu „PDF eines finalen Belegs wird nie neu erzeugt“ und zum Inhalt-Hash), PDF/A-3b und Anhang nativ. **Rückfalloption: WeasyPrint**, falls die XMP-Nachbearbeitung oder Typst als zweite Layoutsprache nicht gewollt ist: deckt alle E-Rechnungs-Anforderungen ohne Nachbearbeitung ab, ist aber langsamer und bringt Python ins Image. **Chromium nicht empfohlen** (größtes Image, höchster Speicher, PDF/A nur über Ghostscript, Browser mit `--no-sandbox` im Worker). **(a) Swift-Portierung** wurde nicht prototypisiert (Abschnitt 6).

## 2. Testfall

Eine synthetische Musterrechnung (erfundene Firma „Muster Ingenieurbüro GmbH“, Kunde „Bäckerei Größenwahn & Söhne OHG“), die die fünf Layoutbausteine aus der Roadmap in einem Beleg vereint:

- **Briefkopf:** Absenderzeile, Anschriftenfeld, Logo als SVG (synthetisch), Metadatenblock (Nummer, Datum, Leistungszeitraum, Fälligkeit).
- **Positionstabelle:** 48 Positionen, Steuersätze 19 % und 7 %, eine Position mit fünfzeiligem Langtext, Kopfzeile wiederholt sich auf jeder Seite.
- **Mehrseitig:** 3 Seiten; zusätzlicher Lasttest mit 480 Positionen (17 Seiten).
- **Summenblock:** Netto, USt je Satz, Rechnungsbetrag; darf nicht umbrechen.
- **Fußzeile:** zweizeilige Bankverbindung/USt-IdNr. und „Seite x von y“ auf jeder Seite.
- **Sonderzeichen:** ä ö ü Ä Ö Ü ß, typografische Anführungszeichen „…“, Halbgeviertstrich, €.
- **E-Rechnung:** synthetisches CII-XML `factur-x.xml` (nur Struktur, nicht schema-validiert; XML-Erzeugung und Validierung sind WP-R5/F-26) als eingebetteter Anhang.
- **Schrift:** DejaVu Sans (freie Lizenz, Einbettung erlaubt) in allen Kandidaten, damit Unterschiede vom Renderer und nicht von der Schrift kommen.

Beträge im Generator mit `Decimal` (Netto 19.757,50 €, Brutto 23.400,13 €).

## 3. Ergebnisse im Detail

### 3.1 Treue und Text

Alle drei PDFs wurden als Seitenbilder gerendert und angesehen; `pdftotext` liefert bei allen identische Inhalte:

| Prüfung | Typst | WeasyPrint | Chromium (+gs) |
| --- | --- | --- | --- |
| Positionszeilen gefunden | 48 | 48 | 48 |
| Zeilen mit Umlauten (Erwartung 22) | 22 | 22 | 22 |
| „Größenordnung“ in typografischen Anführungszeichen | 10 | 10 | 10 |
| Langtext vollständig | ja | ja | ja |
| Rechnungsbetrag „23.400,13 €“ | ja | ja | ja |
| Positionen je Seite | 20 / 28 / 0 | 15 / 22 / 11 | 14 / 22 / 12 |
| Summenblock | Seite 3, nicht getrennt | Seite 3, nicht getrennt | Seite 3, nicht getrennt |
| Schriften eingebettet (Teilmenge) | ja | ja | ja |

Die Zeilenverteilung bei Typst weicht ab, weil die Typst-Vorlage enger gesetzt ist (Zeilenabstand, Zellabstand), nicht wegen des Renderers. Die beiden HTML-Renderer weichen trotz identischem HTML/CSS um eine Zeile je Seite voneinander ab: Seitenumbrüche sind zwischen Engines nicht übertragbar. Folge für R6: Konformität wird je Engine gegen eigene Referenz-PDFs gemessen, nicht gegen die App.

### 3.2 PDF/A-3 und Factur-X

Geprüft mit veraPDF 1.30.4 (`--flavour 3b`) und einer Strukturprüfung (pikepdf): Anhang, `AFRelationship`, XMP, OutputIntent, Schrifteinbettung.

- **Typst 0.15.1:** PDF/A-3b PASS, Anhang mit `/AF` und `Alternative`, sRGB-OutputIntent. Es gibt keinen Weg, eigene XMP-Einträge zu setzen; das von Factur-X/ZUGFeRD verlangte `fx:`-Schema fehlt. Im Spike wurde es nachträglich eingefügt: Der `fx:`-Eintrag muss in die **vorhandene** `pdfaExtension:schemas`-Liste von Typst, eine zweite Liste ist ungültig (veraPDF FAIL 6.6.2.1-4/-5, 6.6.4-1); danach PASS. Für R6: kleiner Schritt im Swift-Worker (Metadatenstrom ersetzen, z. B. per inkrementellem Update) oder ein Werkzeug wie `qpdf` (Apache-2.0); beides im Spike nicht gebaut.
- **WeasyPrint 70.0:** PDF/A-3b PASS, Anhang mit `Alternative`, `fx:`-Schema per `--xmp-metadata` – alles ohne Nachbearbeitung. Warnung im Lauf: ohne `libharfbuzz-subset` nutzt WeasyPrint fontTools für Schrift-Teilmengen (künftig nicht mehr unterstützt; im Image nachzuinstallieren).
- **Chromium 156:** Rohausgabe ist PDF 1.4 ohne PDF/A (FAIL). Ghostscript 10.05.1 (`-dPDFA=3`, sRGB-OutputIntent) macht daraus PDF/A-3b (PASS) und bettet die Schrift neu ein. Anhang und XMP über Ghostscript-pdfmark oder ein weiteres Werkzeug wären zusätzlich zu bauen; nicht geprüft.

Die Factur-X-Profilprüfung des XML (Schematron, Mustang/KoSIT) war nicht Teil des Spikes.

### 3.3 Laufzeit und Speicher

Gemessen im Container (`docker run --read-only --tmpfs /tmp`), Mittel aus 10 Läufen (17 Seiten: 5, Wiederholung Chromium: 10) nach einem Aufwärmlauf, je ein Prozess pro Beleg (wie ein Worker-Job, der das Werkzeug aufruft). Umgebung: Colima-VM, 2 vCPU, 4 GB RAM, arm64. Wo zwei Messreihen vorliegen (3 Seiten; Chromium auch 17 Seiten), ist die Spannweite angegeben. Speicher: `memory.peak` der Container-cgroup.

| Kandidat | 3 Seiten (48 Pos.) | 17 Seiten (480 Pos.) | Speicher 3 / 17 S. |
| --- | --- | --- | --- |
| Typst | 0,032–0,040 s | 0,262 s | 37 / 62 MiB |
| WeasyPrint | 0,444–0,460 s | 1,578 s | 67 / 111 MiB |
| Chromium | 0,334–0,347 s (Ausreißer der ersten Reihe 0,905 s verworfen) | 0,508–0,515 s | 197 / 285 MiB |
| Ghostscript PDF/A-Schritt | 0,084 s | – | 14 MiB |

Ein dauerhaft laufender Chromium (DevTools-Protokoll statt Prozess je Beleg) wäre schneller, bringt aber einen langlebigen Browserprozess in den Worker.

### 3.4 Determinismus

Je zwei Läufe, SHA-256 der PDFs verglichen:

- Typst mit `--creation-timestamp`: identisch; zusätzlich amd64 (Emulation) und arm64 byte-identisch.
- WeasyPrint mit `SOURCE_DATE_EPOCH`: identisch; ohne: verschieden (Zeitstempel). amd64 nicht geprüft.
- Chromium: verschieden (CreationDate/ModDate, Teilmengen-Präfixe); extrahierter Text und Rasterbild identisch. `SOURCE_DATE_EPOCH` wirkt nicht.

### 3.5 Betrieb im Container

- Alle drei laufen mit read-only Root und `tmpfs /tmp`, also nach ADR 0003. Ohne Netz (`--network none`) ist nur Typst geprüft (Nachtrag 27.11.2026).
- Typst ist ein statisches Binary (49 MB) und kann in das bestehende Worker-Image (`Dockerfile.worker`) kopiert werden; kein eigener Container nötig (Nachtrag 27.11.2026: in `ubuntu:24.04` als Nicht-Root auf arm64 geprüft). Offizielles Image für amd64 und arm64 vorhanden.
- WeasyPrint braucht Python, Pango und Schriften: eigener Worker-Container oder Python im Worker-Image (+≈ 76 MB komprimiert).
- Chromium braucht `--no-sandbox` (als root im Container) oder ein Seccomp-Profil, ≈ 200–300 MiB RAM je Lauf und das größte Image; Browser-Sicherheitsupdates werden zur Betriebspflicht.
- Schriften liegen im Image (oder als versionierte Mandantendaten); keine Systemschrift-Abhängigkeit, sonst ändert ein Basis-Image-Update die PDFs.

## 4. Lizenzen (Prüfung anhand der Projektangaben, keine Rechtsberatung)

| Komponente | Lizenz | Verträglich mit AGPL-3.0-only |
| --- | --- | --- |
| Typst 0.15.1 | Apache-2.0 | ja |
| WeasyPrint 70.0, pydyf, tinycss2, cssselect2 | BSD-3-Clause | ja |
| Pango, HarfBuzz | LGPL-2.1+, MIT („Old MIT“) | ja (dynamisch gelinkt) |
| Chromium | BSD-3-Clause plus zahlreiche Drittlizenzen | ja, Hinweispflichten umfangreich |
| Ghostscript 10.05 | AGPL-3.0 (kommerziell dual) | ja; eigene Quelltextpflichten bei Weitergabe des Images |
| DejaVu-Schriften | Bitstream-Vera-Lizenz / gemeinfrei (Änderungen) | ja, Einbettung erlaubt |
| veraPDF (nur Test) | GPL-3.0+/MPL-2.0 | nur Werkzeug, nicht im Produkt |
| pikepdf (nur Spike) | MPL-2.0 | nur Spike |

Neue Abhängigkeiten werden bei der Umsetzung (R6) in `docs/LIZENZEN.md` und `legal/` eingetragen.

## 5. Aufwand für R6 je Option

Gemeinsam für alle: Layoutmodell (versionierte Mandantendaten), Platzhalter, Worker-Job `invoice.render` mit Lease, Inhalt-Hash, Referenz-PDFs je Standardlayout, Import vorhandener Layouts (Format offen).

- **Typst:** Übersetzer Layoutmodell → Typst-Vorlage (Daten als JSON, Typst liest JSON nativ); XMP-Schritt in Swift; Binary ins Worker-Image. Für die PWA-Vorschau gibt es Typst als WebAssembly (`typst.ts`, Apache-2.0); nicht geprüft.
- **WeasyPrint:** Übersetzer Layoutmodell → HTML/CSS; Python im Worker; HarfBuzz-Subset nachrüsten. PWA-Vorschau kann dasselbe HTML zeigen, Seitenumbrüche im Browser weichen aber ab.
- **Chromium:** wie WeasyPrint plus PDF/A-, Anhang- und XMP-Kette über Ghostscript/weitere Werkzeuge.

## 6. Nicht prototypisiert: (a) Swift-Portierung

Bewertet nur auf dem Papier, weil (1) der Quellcode der bisherigen Rechnungs-App nach Projektregel nicht in den Kontext gehört und (2) unter Linux keine reife Swift-PDF-Bibliothek mit PDF/A-3 existiert. Der Renderer bräuchte einen eigenen PDF-Writer mit Schrift-Teilmengen, ToUnicode-Abbildung, Shaping (HarfBuzz), Zeilenumbruch, OutputIntent, XMP und Anhängen; PDF/A-Konformität müsste selbst erarbeitet werden. Schätzung L–XL, hohes Risiko. Der Vorteil „gleiche Layoutlogik wie die App“ entfällt teilweise, weil CoreText-Metriken unter Linux ohnehin nicht 1:1 nachgebaut werden. Bleibt als Option, falls Treue zur App später wichtiger wird als Aufwand.

## 7. Abweichungen von der Roadmap-Akzeptanz

- Statt fünf getrennter Layouts ein Beleg, der alle fünf Bausteine enthält, plus Lasttest mit 17 Seiten.
- Keine Referenz-PDFs der App (App nicht verwendet); Treue gemessen als Textgleichheit, Seitenverteilung und Sichtprüfung, nicht als Textposition ± Toleranz.
- Option (a) nur auf dem Papier (Abschnitt 6).
- Messungen auf einer arm64-VM mit 2 vCPU; Größenordnungen, keine Produktionswerte.

## 8. Beispiel-PDFs in diesem Ordner

| Datei | Erzeugt mit | veraPDF 3b |
| --- | --- | --- |
| `typst-pdfa3b-facturx.pdf` | Typst 0.15.1 + XMP-Nachbearbeitung (Spike) | PASS |
| `weasyprint-pdfa3b-facturx.pdf` | WeasyPrint 70.0, `SOURCE_DATE_EPOCH` nicht gesetzt | PASS |
| `chromium-ghostscript-pdfa3b.pdf` | Chromium 156 → Ghostscript 10.05.1 (ohne Anhang) | PASS |

Alle Inhalte synthetisch; PDFs auf lokale Pfade und Namen geprüft.

## 9. Befehle (zur Wiederholung)

```
typst compile --font-path fonts --pdf-standard a-3b --creation-timestamp <unix> invoice.typ out.pdf
weasyprint --pdf-variant pdf/a-3b -a factur-x.xml --attachment-relationship Alternative \
  --xmp-metadata factur-x-xmp.xml invoice.html out.pdf          # SOURCE_DATE_EPOCH für Determinismus
chromium --headless --no-sandbox --disable-gpu --no-pdf-header-footer --user-data-dir=/tmp/ud \
  --print-to-pdf=out.pdf file:///w/invoice.html
gs -dPDFA=3 -dBATCH -dNOPAUSE -sColorConversionStrategy=RGB -dPDFACompatibilityPolicy=1 \
  -sDEVICE=pdfwrite -sOutputFile=out-pdfa.pdf pdfa3.ps out.pdf  # pdfa3.ps: sRGB-OutputIntent per pdfmark
verapdf --flavour 3b --format text out.pdf
```

Container: `ghcr.io/typst/typst` (0.15.1, Alpine 3.24), `python:3.13-slim` + `weasyprint`, `debian:trixie-slim` + `chromium` + `ghostscript`, `verapdf/cli` 1.30.4. Alle Läufe mit `--read-only --tmpfs /tmp`.
