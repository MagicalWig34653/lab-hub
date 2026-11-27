# ADR 0008: Server-Renderer für Belege

Status: entschieden (Nutzer, 27.11.2026, F-08): Typst mit kleinem Schritt für die Factur-X-Metadaten. Grundlage: Spike WP-R6a, `docs/spikes/WP-R6a/BERICHT.md`.

**Kontext.** Der Hub muss Belege ohne Swift-App als PDF erzeugen (Linux, Container, Swarm), PDF/A-3 mit eingebettetem E-Rechnungs-XML liefern (Factur-X/ZUGFeRD) und das PDF eines finalen Belegs reproduzierbar mit Inhalt-Hash ablegen (`MODUL-RECHNUNG.md` Abschnitt 5). Verglichen wurden Typst, WeasyPrint (HTML/CSS) und headless Chromium (HTML/CSS) + Ghostscript an einer synthetischen dreiseitigen Musterrechnung; die Swift-Portierung nur auf dem Papier.

**Entscheidung.**
1. Renderer ist **Typst** (Apache-2.0), als Binary im Worker-Image, aufgerufen vom Worker-Job `invoice.render` (Lease nach ADR 0006). Daten gehen als JSON an eine Typst-Vorlage, die aus dem versionierten Layoutmodell erzeugt wird.
2. Ausgabe immer `--pdf-standard a-3b` mit festem `--creation-timestamp` (Finalisierungszeitpunkt); E-Rechnungs-XML per `pdf.attach` mit `AFRelationship=Alternative`.
3. Die Factur-X-XMP-Einträge (`fx:`-Schema) ergänzt ein Nachbearbeitungsschritt im Worker, der das `fx:`-Schema in die vorhandene `pdfaExtension`-Liste einfügt; Ergebnis wird in Tests mit veraPDF (PDF/A-3b) geprüft.
4. Schriften liegen versioniert im Image bzw. als Mandantendaten, nie aus dem System des Basis-Images.
5. WeasyPrint (BSD-3-Clause) bleibt die geprüfte Alternative; ein Wechsel braucht eine neue ADR. Chromium und eine Swift-Eigenentwicklung werden nicht weiterverfolgt.

**Folgen.** Kleinstes Image und schnellster Lauf (≈ 0,04 s für drei Seiten), byte-identische PDFs auf amd64 und arm64. Typst ist eine zweite Layoutsprache neben dem Layoutmodell; Seitenumbrüche entsprechen nicht der App, Konformität wird gegen eigene Referenz-PDFs gemessen. Der XMP-Schritt ist eigener Code mit eigenem Test. Typst-Versionen werden fest gepinnt, weil ein Update das Ergebnis ändern kann. Das Typst-Binary bringt eigene Schriften mit, deren Lizenztexte in `legal/` gehören. Umsetzung in WP-R6b bis R6e (`docs/handoff/WP-R6-PLAN.md`).
