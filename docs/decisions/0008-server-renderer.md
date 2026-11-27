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

**Nachtrag WP-R6d (27.11.2026, Entscheidung im WP, Nutzerbestätigung offen): Ablage und Ablauf der Vorschau.** Das API-Image hat kein Typst; die Vorschau eines Entwurfs läuft deshalb als Worker-Job `invoice.preview` (Lease nach ADR 0006). Die API friert die Eingabe ein (Entwurf ohne Nummer, `ENTWURF`, aktuelle Absender- und Empfängerdaten, gewählte oder zugeordnete Layoutversion) in `invoice_previews`; der Worker schreibt das PDF als `bytea` in dieselbe Zeile, nur als Lease-Besitzer und nur vor Ablauf.
1. **Ablage in der Datenbank, nicht im Objektspeicher:** Eine Vorschau ist kein Dokument. So entsteht keine `files`-Zeile, keine Speicherquote, kein inhaltsadressiertes Objekt mit eigenem Aufräumweg und keine Verwechslung mit einem Beleg-PDF; Instanzen bleiben zustandslos (ADR 0003), jede Instanz liefert jede Vorschau. Grenze: 20 MiB je PDF (CHECK), höchstens 20 gültige Vorschauen je Mandant (429).
2. **Ablauf 15 Minuten:** danach liefert `GET …/invoice/previews/{id}` 404. Gelöscht wird ohne eigenen Zeitplan: beim nächsten Anfordern im Mandanten (abgelaufene Zeilen des Mandanten) und mit jedem Vorschau-Job (alle Mandanten, eine Stunde nach Ablauf). Ein Entwurf, der gelöscht wird, nimmt seine Vorschauen mit (CASCADE).
3. **Kennzeichnung:** Jede Seite trägt „ENTWURF – Vorschau, kein gültiger Beleg“; `Cache-Control: private, no-store`.
Verworfen: Objektspeicher mit Ablaufliste (zweiter Aufräumweg neben dem DMS, Bytes ohne `files`-Zeile wären für die bestehenden Aufräumwege unsichtbar), synchrones Rendern in der API (Typst im API-Image, widerspricht R6b).

**Nachtrag WP-R6d: Layoutmodell.** Die Vorlage wird nicht pro Layout erzeugt: Standardlayout 1 liest die Parameter (Schema 1: Schrift aus der freigegebenen Liste, Akzent- und Textfarbe, Logo, Kopf-/Fußtext mit Platzhaltern) aus `data.json`; Platzhalter ersetzt Swift, nie Typst. Ohne Layout rendert die Vorlage bytegleich zu R6b. Der Designer (WP-F7b) führt ein neues `schema` im selben, versionierten Parameterdokument ein.
