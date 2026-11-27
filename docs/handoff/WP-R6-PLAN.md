# Plan WP-R6 – Server-Renderer und Layout-Engine

Stand 27.11.2026. Status: **R6b umgesetzt** (`docs/handoff/WP-R6b.md`), R6c bis R6e Plan. Grundlage: F-08 entschieden (Typst + Factur-X-Metadatenschritt, ADR 0008), Spike `docs/spikes/WP-R6a/BERICHT.md`, `MODUL-RECHNUNG.md` Abschnitte 5 und 14, ADR 0003/0006.

WP-R6 (L) wird in vier Pakete geschnitten. Jedes ist einzeln testbar und pushbar.

| WP | Titel | Abh. | Größe |
| --- | --- | --- | --- |
| R6b | Render-Werkzeugkette und Standardlayout (ohne Datenbank) | R6a, R2 | M |
| R6c | Render-Job, Speicherung, PDF-Download | R6b | M |
| R6d | Layoutmodell V1, Parameter, Zuordnung, Vorschau | R6c | M |
| R6e | Import vorhandener Layouts | R6d, Importformat | M |

WP-F6 (Rechnungs-UI) braucht R6b–R6d; WP-F7a braucht zusätzlich R6e. Nächster Schritt: **R6c**.

## Ausgangslage im Code

- Finalisieren läuft in einer Transaktion und friert Absender, Empfänger, Nummer und Inhalt-Hash ein (`InvoiceDocuments.finalize`).
- Trigger verbieten jedes UPDATE eines finalen Belegs: Render-Ergebnisse brauchen eine eigene Tabelle.
- `JobService` (Lease, `SKIP LOCKED`), `HubModule.jobHandlers` und `FileRecordService` (je Mandant und SHA-256 eine Zeile) sind vorhanden.
- `Dockerfile.worker` basiert auf Ubuntu 24.04 und enthält bereits `qpdf`.

Am 27.11.2026 zusätzlich geprüft (arm64): Das Binary aus `ghcr.io/typst/typst:0.15.1` ist statisch gelinkt und übersetzt in `ubuntu:24.04` als Nicht-Root, mit read-only Root, `tmpfs /tmp` und `--network none` nach PDF/A-3b. Index-Digest des Images: `sha256:032e292249bcd378480cc7c142cfa324b63ef8aadeb88d7e7230320c4c9c422f` (amd64 und arm64).

## R6b – Render-Werkzeugkette und Standardlayout (fertig, 27.11.2026)

Umsetzung und Belege: `docs/handoff/WP-R6b.md`. Abweichungen vom Plan: Die Annahme `qpdf --update-from-json` hat sich bestätigt, braucht aber `--newline-before-endstream` (sonst verletzt der Strom PDF/A 6.1.7.1); der Prozess-Aufruf `OCRProcess` heißt jetzt `ToolProcess` und liegt im Kern.

Umfang:
- Typst 0.15.1 per Digest in die Stufen `worker` und `worker-test` von `Dockerfile.worker`; das API-Image bleibt ohne Typst.
- Schriften als gepinnter Download mit SHA-256 im Image, Aufruf immer mit `--ignore-system-fonts`.
- Renderfunktion: eingefrorene Belegdaten (JSON, Dezimal-Strings) → PDF-Bytes. Eigener Prozess mit Zeitlimit, `--root` auf das Arbeitsverzeichnis unter `/tmp`, `--creation-timestamp` = `finalized_at`.
- Nutzerdaten gehen **nur** als JSON-Datei an die Vorlage, nie als Typst-Quelltext. Keine Paketimporte.
- Factur-X-Metadatenschritt: `fx:`-Schema in die vorhandene `pdfaExtension`-Liste einfügen. **[Annahme, in R6b zu belegen]** `qpdf --update-from-json` (schon im Image); Rückfall: eigener inkrementeller Update-Schreiber in Swift.
- Anhang: Funktion nimmt optional ein E-Rechnungs-XML entgegen (`AFRelationship=Alternative`); ohne XML auch kein `fx:`-Eintrag. Die XML-Erzeugung ist WP-R5.
- Standardlayout 1 für alle fünf Belegarten (Lieferschein ohne Preise), Hinweiszeile je Steuerregime (Wortlaut fachlich zu prüfen).

Akzeptanz:
- AK-R6b-1: fünf synthetische Referenzfälle (Briefkopf, Positionstabelle, mehrseitig, Summenblock, Fußzeile): Seitenzahl und extrahierter Text gleich der Referenz.
- AK-R6b-2: veraPDF (`--flavour 3b`, per Digest gepinnt) besteht mit und ohne Anhang, auch in der CI; `fx:`-Metadaten vorhanden, wenn XML angehängt ist.
- AK-R6b-3: gleiche Eingabe ergibt gleiche Bytes (zwei Läufe; amd64 und arm64).
- AK-R6b-4: Typst-Syntax in Beschreibungen (z. B. `#read(…)`) erscheint wörtlich; Zeitlimit beendet den Prozess.
- AK-R6b-5: Lizenztexte für Typst, eingebettete Schriften und eigene Schriften in `legal/` und `docs/LIZENZEN.md`; `scripts/check-third-party-notices.sh` erweitert.

Tests mit Typst laufen im Worker-Test-Image (Muster `scripts/ocr-container-test.sh`); ohne Typst werden sie sichtbar übersprungen, in der CI nicht.

## R6c – Render-Job, Speicherung, Download

Umfang:
- Migration mit der nächsten freien Nummer (zuletzt `invoice_029`): `invoice_render_states` (`tenant_id`, `document_id` eindeutig, Layoutschlüssel, Layoutversion, Inhalt-Hash der Eingabe, SHA-256 des PDF, `file_id`, Renderer-Version, `created_at`), Trigger gegen UPDATE/DELETE. Testlisten für Tabellen und Reverts mitziehen.
- Finalisieren legt den Job `invoice.render` **in derselben Transaktion** an.
- Handler im Rechnungsmodul: nur aus eingefrorenen Daten rendern, Objekt speichern, `files` registrieren, Zustand mit `ON CONFLICT DO NOTHING` schreiben, Abschluss nur als Lease-Besitzer.
- `GET documents/{id}/pdf` (`invoice.document.read`): fertig, in Arbeit oder fehlgeschlagen (eigene Fehlercodes). `POST documents/{id}/render` (`invoice.document.finalize`): idempotent, für fehlgeschlagene Jobs und vor R6c finalisierte Belege; erzeugt nie ein zweites PDF.
- `invoice.render` in `--kinds` in Compose und Swarm, OpenAPI-Vertrag, `deploy/README.md`.

Akzeptanz:
- AK-R6c-1: zwei Worker erzeugen genau ein PDF und eine Zustandszeile je Beleg.
- AK-R6c-2: Rollback beim Finalisieren hinterlässt keinen Job.
- AK-R6c-3: ein fertiges PDF wird nie neu erzeugt oder geändert.
- AK-R6c-4: fremder Mandant 404, Rechte erlaubt/verboten.
- AK-R6c-5: kein Aufräum- oder Löschpfad (DMS, Objektspeicher) entfernt eine referenzierte Beleg-Datei.
- AK-R6c-6: E2E mit echtem Worker: Beleg anlegen → finalisieren → PDF laden.

## R6d – Layoutmodell V1

Umfang: `invoice_layouts` als versionierte Mandantendaten, Parameter (Logo, Farben, Schrift aus freigegebener Liste, Kopf-/Fußtexte, Platzhalter) nach `FRONTEND.md` Abschnitt 13 Stufe 1, Zuordnung je Belegart/Serie, Vorschau eines Entwurfs. Das Layoutmodell ist so zu entwerfen, dass der spätere Designer (F7b) es teilt.

Akzeptanz: Roundtrip speichern → laden → rendern ohne Verlust; finale Belege behalten ihre Layoutversion; Logo-Upload nur geprüfte Formate und Größen; Mandantentrennung.

Offen in R6d: Das API-Image hat kein Typst. Die Vorschau läuft deshalb über den Worker; wo ihr kurzlebiges Ergebnis liegt (Ablaufzeit, Aufräumen), wird im WP entschieden und im ADR nachgetragen.

## R6e – Import vorhandener Layouts

Dokumentiertes Importformat → Layoutmodell, nur synthetische Fixtures, Bericht über nicht übertragbare Elemente. Blockiert, bis das Importformat feststeht (F-09, F-31). Private Kundenlayouts werden nie gelesen.

## Offener Punkt für den Nutzer

- **F-37 Reihenfolge E-Rechnung:** Ein finales PDF wird nie neu erzeugt. Belege, die nach R6c, aber vor WP-R5 finalisiert werden, bleiben ohne eingebettetes XML. Empfehlung: R5 nach R6c und vor der ersten produktiven Rechnung im Hub. **[Annahme]** Der Hub stellt noch keine produktiven Rechnungen aus.

## Nicht Teil von R6

E-Rechnungs-XML und Validierung (R5, F-26), grafischer Designer (F7b), Treue-Vergleich mit PDFs der bisherigen App.
