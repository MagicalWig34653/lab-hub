# WP-H14 – Codex-Befunde 8 und 4

Stand: auf main (Befund 4 mit f644e78, Leseroute mit Nachtrag unten); Branch wp-H14 ist überholt.

## Befund 8 (OCR nach Absturzschleife unwiederholbar)
- Gewählte Variante: Retry-seitig statt Hook (kein Kern-zu-DMS-Hook, kein Zustand in `JobService`). `DMSOCR.retryPermanent` akzeptiert ein Item in `ocr_queued`, dessen Job `failed_permanent` ist (Zeilensperre `FOR UPDATE OF i`: ein paralleler Retry wirkt, der andere 409). `DMSOCR.status` zeigt dafür Phase `failed`, `error_code` `lease_expired`.
- Hinweis: Das Item bleibt in der Datenbank `ocr_queued`, bis jemand wiederholt; andere Leser von `dms_ingest_items.state` sehen es weiter als wartend.

## Befund 4 (generische Links umgehen DMS-Schutz)
- `LinkService.create/remove/restore` haben `origin: .internal` (Standard: Import, Vorschläge, Mail, DMS-PATCH) oder `.external` (generische Routen). Extern bei `dms.document`-Seite: Modul aus 404 `module_disabled`, fehlendes `dms.document.update` 403, unbekanntes Dokument 404, Papierkorb 409 `document_trashed`, Zeilensperre, `rev + 1`. Andere `dms.*`-Typen beim Anlegen: 422.
- Hinweis: Keine Standardrolle hat `contact.link.write` ohne `dms.document.update`; der 403-Pfad ist defensiv und ungetestet.
- Kein Vertrags-/OpenAPI-/i18n-Eingriff nötig (vorhandene Codes).

## Tests
`backend/Tests/HubKitTests/Modules/DMSH14Tests.swift`: AK-H14-1..3 (OCR), AK-H14-4..7 (Links). Vorher rot protokolliert (20 Fehlschläge), danach grün.

## Nachtrag Befund 4: Leseroute (24.11.2026)
- Lücke: `GET /links` kannte keine DMS-Regel; bei abgeschaltetem DMS lieferte sie `dms.document`-Verknüpfungen (Dokument-ID, Korrespondent) weiter aus, auch über die Kontaktsicht.
- Jetzt (`LinkService.list`, nur `Origin.external`): ohne aktives Modul oder ohne `dms.document.read` liefert eine `dms.*`-Abfrage 404 `module_disabled` bzw. 403, jede andere Abfrage lässt Verknüpfungen mit `dms.*`-Seite weg. Interne Aufrufer (DMS-PATCH, Vorschläge) unverändert. Kein Datenverlust: Modul wieder an = Links wieder sichtbar.
- Tests AK-H14-8 (Modul an/aus/an, Dokument- und Kontaktsicht, `include_removed`) und AK-H14-9 (Kontakt-zu-Kontakt bleibt sichtbar); AK-H14-8 war vorher rot (200 statt 404, 1 statt 0).
- Weiter ungetestet: der 403-Pfad ohne `dms.document.update` bzw. `dms.document.read` (keine Standardrolle hat `contact.link.*` ohne die DMS-Rechte).
