# Übergabe WP-F4 (DMS-UI in der PWA)

Stand 07.11.2026, Branch `wp-F4` (auf `main` 96cbed9, enthält F2, D2, S1, O1). Alles unter `pwa/` plus Doku. Test und Implementierung entstanden in derselben Session (kein belegter Rot-Lauf).

## Umgesetzt
- **Routen** `/dms` (Upload, Suche, Filter, Facetten, Liste, Papierkorb-Ansicht) und `/dms/[id]` (Vorschau, Metadaten bearbeiten, Archivieren/ASN, Papierkorb, Wiederherstellen). Ersetzt die F2-Platzhalterseite; Einhängen über das Manifest (`modules-impl/dms/manifest.ts`, Texte `dms.*` de/en).
- **Code:** `pwa/src/lib/modules-impl/dms/` (`DmsBrowser`, `DocumentDetail`, `UploadPanel`, `upload.svelte.ts`, `snippet.ts`, `masters.ts`), API-Client `dmsApi`/`contactApi` in `lib/api/client.ts`, `formatDate`/`formatBytes`, `types.ts` neu erzeugt (war nach S1 veraltet).
- **Upload:** mehrere Dateien, Dropzone plus Dateiwahl, Fortschritt je Datei (XHR), Idempotency-Key je Datei (Wiederholung mit demselben Schlüssel), Fehlerzustände unsupported (415), zu groß (413), Duplikat (Hinweis plus Link), Quarantäne, sonstige Fehler mit „Erneut versuchen“. Dokumente mit Status `processing` werden bis zum Abschluss gepollt und die Liste aktualisiert.
- **Suche/Filter:** Zustand in der URL. Mit Suchbegriff `search` (Snippets mit U+E000/U+E001 -> `<mark>`, nie HTML; Facetten Typ/Korrespondent/Tags/Jahr als umschaltbare Schaltflächen; Datum von/bis; mehrere Tags). Ohne Suchbegriff `documents`. Cursor-Pagination („Mehr laden“).
- **Detail:** Vorschau PDF/Bild über Blob-URL (Auslieferung der Route hat CSP `sandbox`), Original-Download-Link nur mit `dms.document.download_original` (sonst Hinweis, Vorschau über Archiv/Thumbnail oder „keine Vorschau“), Bearbeiten von Titel, Datum, Typ, Korrespondent (Kontaktliste, K5), Tags, benutzerdefinierten Feldern (string/int/decimal/date/bool/select) mit `If-Match`, Archivieren, Papierkorb mit Pflichtgrund, Wiederherstellen. Felder sind ohne `dms.document.update` gesperrt.
- **Mock** (`pwa/mock/dms.ts`, in `mock/api.ts` eingehängt): Upload mit Magic Bytes, Limit 1 MiB, Idempotenz, Duplikat über SHA-256, Verarbeitung nach 0,7 s, Suche mit Snippet und Facetten, Stammdaten, Kontakte, PATCH/Archiv/Papierkorb/Datei-Route, Berechtigungen je Rolle (customer_viewer: nur Lesen, kein Download). Testhelfer `POST /api/__mock/dms/seed`.

## Tests (alle ausgeführt, siehe Rückgabe)
- Vitest: `snippet.test.ts`, `upload.test.ts` (Warteschlange: mehrere Dateien, Polling, Duplikat/Quarantäne/415/413, Wiederholung mit gleichem Schlüssel), `messages.test.ts` (**i18n de/en vollständig**: gleiche Schlüssel und Platzhalter, jeder im Quelltext genutzte `dms.*`-Schlüssel existiert, keine toten Texte); der bestehende Heuristiktest „kein Text außerhalb von `t()`“ deckt die neuen Seiten ab.
- Playwright (Mock, `e2e-mock/dms.spec.ts`, 7 Tests): AK-F4-1 (Upload -> processing -> done -> Treffer mit `<mark>`, Skript im Dokumenttext bleibt Text), AK-F4-2 (axe, serious/critical = 0, auf Suchergebnis, Fehlerzuständen, Detail de und en, Papierkorb), AK-F4-3 (Tastatur: ein Tabstopp, Pfeile, J/K, Home/End, „/“, Enter, Paging über Cursor), AK-F4-4 (unsupported, zu groß, Duplikat, Quarantäne in Upload, Liste und Detail), Metadaten bearbeiten und Neuladen, PDF-Frame, Filter/Facetten, Papierkorb, Leser ohne Download-Recht.
- `shell.spec.ts`: Platzhalter-Prüfung auf das Suchfeld umgestellt (Test nicht abgeschwächt).

## Backend-Lücken (nicht erfunden)
1. **Verarbeitungs-/Quarantänestatus:** Der Vertrag hat keine Ingest-Route und keine `ingest_item_id`; `dms_documents.status` kennt nur `processing|needs_review|archived`. Die UI liest optional `ingest_state`/`ingest_error_code` am Dokument (nur im Mock vorhanden, in `mock/dms.ts` und `upload.svelte.ts` gekennzeichnet). Mit O2 braucht der Vertrag ein Feld oder eine Route; danach `isQuarantined` anpassen. Ohne das erscheint Quarantäne gegen das echte Backend nicht.
2. **Liste ohne Datum/Facetten, Suche nur mit `q`:** Durchsuchen mit Datumsfilter oder Facetten ohne Suchbegriff geht nicht (Datum und Facetten sind in der UI ohne Suchbegriff deaktiviert/ausgeblendet; ohne Suchbegriff gilt nur der erste Tag). Wunsch an Vertrag: `date_from/date_to` und `facets` an `listDmsDocuments` oder leeres `q` bei `search`.
3. **Duplikate beim Upload:** nur die Hinweisliste `duplicates` der Upload-Antwort; D3 (Duplikatstufen) fehlt.
4. **Kontakte lesen** braucht `contact.contact.read`; ohne dieses Recht sind Korrespondent-Auswahl und -Namen leer (kein Fehler). Contacts-Liste lädt höchstens 200; bei mehr braucht es eine Suche im Auswahlfeld.
5. **Dezimalfelder** werden als String gesendet, Ganzzahlen als Zahl; der Vertrag (`fields: additionalProperties`) legt das nicht fest.
6. Dokumenttypen/Tags/Felder sind nur lesbar (Stammdatenpflege = F5).

## Offen / nicht geprüft
- **E2E gegen das echte Backend nicht gelaufen** (Swift-Build und Postgres nicht gestartet); `npm run test:e2e` hat keine DMS-Tests. Upload/Download/Vorschau gegen das echte Backend, Streaming bei großen Dateien, das tatsächliche `Content-Length`-Verhalten des Roh-Uploads sind daher ungeprüft.
- PDF-Vorschau im headless Chromium nur bis zum `blob:`-Frame geprüft (der PDF-Viewer rendert dort nicht); Bildvorschau mit `naturalWidth` geprüft. TIFF hat keine Vorschau (Browser zeigt es nicht).
- Eine künftige CSP der PWA muss `img-src blob:` und `frame-src blob:` erlauben (derzeit setzt das Backend für die PWA keine CSP).
- Mehr-Datei-Upload per Ordner/Archiv, Kamera/Scan, Upload-Abbruch durch den Nutzer (nur beim Verlassen der Seite), Bulk-Aktionen und Mehrfachauswahl fehlen. Dunkles Theme nicht per axe geprüft.
- Neue Abhängigkeit `@axe-core/playwright` (MPL-2.0, nur Tests), Eintrag in `docs/LIZENZEN.md`; Lockfile mit `--force` ergänzt (`npm install` scheitert sonst an der Peer-Auflösung, siehe dort).
- Nächster Schritt: O2 (Ingest-Status im Vertrag), dann F4 an den echten Status anbinden und `test:e2e` für DMS ergänzen; F5 (Prüf-Warteschlange, Stammdaten).
