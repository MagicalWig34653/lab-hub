# Frontend (PWA) – Entwurf

Status: Entwurf, Stand 01.11.2026. Entscheidung Stack: ADR 0002 (entschieden) und ADR 0007 (Details, vorgeschlagen). `pwa/` enthält seit WP-F1 das Gerüst (Login/Passkey, Guard, API-Client, i18n, Mock-Backend). Vorbild: `timetrack-pwa` (Nachbar-Checkout `../timetrack-pwa`) (gelesen: `package.json`, `AGENTS.md`, `vite.config.ts`, `components.json`, `playwright*.ts`, `src/`-Struktur, `src/lib/modules/map.ts`, `src/lib/i18n/index.ts`, `src/routes/(app)/+layout.ts`, `src/service-worker.ts`). Nicht gelesen: Komponentenquellen im Detail.

## 1. Ziele

0. Alle Funktionen des Hubs sind ohne Swift-App über die PWA erreichbar (Grundsatz, `ARCHITEKTUR.md`).
1. Eine PWA für alle Module; Menü und Routen folgen der Modulaktivierung des Backends (`ARCHITEKTUR.md` Abschnitt 3).
2. Statisch gebaut, vom Backend ausgeliefert (gleicher Origin → Cookie-Sitzung, Passkey-RP-ID = Host; Vorbild `PWAStaticMiddleware.swift` im timetrack-backend).
3. Installierbar, Shell offline verfügbar; Schreibzugriffe nur online (V1), Lesen zuletzt geladener Listen/Dokumente optional offline (Abschnitt 7).
4. Deutsch und Englisch, barrierefrei, hell/dunkel.

## 2. Was von timetrack-pwa übernommen wird

| Muster | Fundstelle im Vorbild | Übernahme im Hub |
| --- | --- | --- |
| SvelteKit 3 + Svelte 5 (Runes erzwungen) + `adapter-static` mit `fallback: index.html` | `vite.config.ts`, `package.json` | ja, gleiche Hauptversionen als Startpunkt (aktuelle Patch-Versionen beim Anlegen prüfen) |
| Tailwind 4 (`@tailwindcss/vite`), `tw-animate-css`, `tailwind-variants` | `package.json` | ja |
| shadcn-svelte (Style „nova“, Basisfarbe neutral, lucide-Icons), Komponenten unter `src/lib/components/ui` | `components.json` | ja; Registry-Komponenten nur nach Bedarf hinzufügen; `SHADCN-LICENSE.md` übernehmen |
| Import-Aliase `#lib`, `#lib/*` | `package.json` `imports` | ja |
| Eigene App-Komponenten `src/lib/components/app` (PageHeader, EmptyState, ConfirmDialog, Toast, StatusChip, FilterBar, ModuleDisabled, ErrorPage …) | dort | als Startmenge der geteilten UI-Bibliothek (Abschnitt 6) nachbauen, nicht kopieren |
| API-Client zentral mit Fehlerklasse `ApiError`, Fehlercode → Text-Mapping | `src/lib/api/client.ts`, `errors.ts`, `i18n/index.ts` (`errorMessage`) | ja, mit RFC-9457-`code` aus `ARCHITEKTUR.md` Abschnitt 5 |
| API-Versionsabgleich Client/Server | `src/lib/api/api-version.ts` | ja |
| Modul-Store + **Routenklassifikation mit Test**, der fehlschlägt, wenn eine Seite keinem Modul zugeordnet ist (ADR-0012) | `src/lib/modules/map.ts`, `store.svelte.ts`, `modules.test.ts` | ja, erweitert um Manifest (Abschnitt 4) |
| Route-Gruppen `(app)` (Login-Pflicht, Guard in `+layout.ts`) und `(public)` | `src/routes/` | ja |
| Service Worker mit Precache (Build-Assets + Shell), Cache-first für gehashte Assets, Navigationsfallback `offline.html`, Update-Policy | `src/service-worker.ts`, `src/lib/pwa/*`, `static/offline.html` | ja, Strategie dokumentiert in ADR 0007 |
| Theming (`theme.svelte.ts`, Akzent), a11y-Helfer (focus-trap, menu-nav) | `src/lib/theme`, `src/lib/a11y` | ja |
| Tests: Vitest (jsdom, `@testing-library/svelte`), Playwright E2E gegen echtes Backend, Mock-Backend für schnelle UI-Tests, Playwright-PWA-Lauf, axe-a11y | `vitest-setup.ts`, `playwright*.config.ts`, `e2e*/`, `mock/` | ja (Abschnitt 11) |
| Lizenz-Hinweise im Build erzeugen (`scripts/generate-licenses.mjs`) | `package.json` `build` | ja (AGPL, Drittlizenzen) |
| `static/manifest.webmanifest`, Icons per Skript | `static/`, `scripts/generate-icons.mjs` | ja |

Abweichungen (bewusst):
- **i18n de/en**: timetrack ist nur Deutsch mit typisierten Schlüsseln (`i18n/de*.ts`, `t(key)`). Hub braucht zusätzlich Englisch; Schlüssel bleiben englisch, `de.ts` ist die Referenz, `en.ts` muss denselben Typ erfüllen (Compile-Fehler bei fehlendem Schlüssel).
- **Module als Pakete**: Texte und Routen je Modul in eigenen Verzeichnissen, nicht flach in `lib/i18n`.
- Passkey-Login wie Vorbild (`src/lib/webauthn.ts`, nicht gelesen → zu verifizieren), aber Mandantenwechsel im UI.

## 3. Verzeichnislayout `pwa/` (Ziel)

```
pwa/
  package.json  svelte.config.js  vite.config.ts  tsconfig*.json  components.json
  playwright.config.ts  playwright.mock.config.ts  vitest-setup.ts
  static/                      manifest.webmanifest, offline.html, icons/, robots.txt
  scripts/                     generate-icons.mjs, generate-licenses.mjs, build-info.ts
  mock/                        Mock-API (Vite-Plugin) für UI-Tests ohne Backend
  e2e/  e2e-mock/              Playwright-Specs
  src/
    app.html  app.d.ts  hooks.client.ts  service-worker.ts
    routes/
      layout.css
      (public)/login  invite  recover
      (app)/+layout.ts  +layout.svelte    Guard, Shell, dynamische Navigation
      (app)/                  dashboard (Kern), settings/, admin/
      (app)/m/dms/…           Routen des Moduls DMS
      (app)/m/invoice/…       Routen des Moduls Rechnung
      offline/
    lib/
      api/                    client.ts, errors.ts, types.ts (generiert aus OpenAPI), api-version.ts
      session.svelte.ts  tenant.svelte.ts  (aktueller Mandant)
      modules/                manifest.ts (Typen), registry.ts, store.svelte.ts, map-check.test.ts
      ui/                     geteilte UI-Bibliothek: shadcn-Komponenten (ui/), app-Komponenten (app/)
      i18n/                   index.ts, de.ts, en.ts, core/*.ts
      pwa/  theme/  a11y/  errors/  utils.ts
      modules-impl/
        dms/                  manifest.ts, api.ts, components/, i18n/{de,en}.ts, stores
        invoice/              dito
```

Route-Präfix `/m/<modulkey>/…` (Vorschlag): macht Zuordnung Route→Modul trivial prüfbar und verhindert Kollisionen. Alternative ohne Präfix (`/dms`, `/invoice`) ist ebenso möglich; Entscheidung bei WP-F1, Test gilt für beide.

## 4. Modul-Manifest und dynamische Navigation

Backend: `GET /api/v1/tenants/{t}/modules` liefert je aktivem Modul `{ key, version, navigation: [{ id, labelKey, icon, path, requires: [permission], order }], permissions: [...] }` (Quelle: `HubModule.navigation`, ARCHITEKTUR 3.1). Frontend:

```ts
// lib/modules/manifest.ts
export interface ModuleManifest {
  key: string;                       // identisch mit Backend-Modulschlüssel
  routePrefix: string;               // '/m/dms'
  messages: { de: Record<string,string>; en: Record<string,string> };
  navigation?: never;                // kommt vom Backend, Frontend ergänzt nur Icons/Komponenten
  widgets?: DashboardWidget[];       // Dashboard-Karten (lazy import)
  searchProviders?: SearchProvider[];// Anzeige von Treffertypen in der globalen Suche
}
```

- `registry.ts` kennt alle eingebauten Manifeste (statisch importiert, Code-Splitting per Route). Ein im Backend aktives Modul **ohne** Frontend-Manifest erscheint als „Modul nur über API/App verfügbar“; ein Frontend-Manifest ohne aktives Backend-Modul wird ausgeblendet.
- Navigation = Schnittmenge aus Backend-Navigation, Berechtigung des Nutzers (`requires`) und vorhandenem Manifest. Reihenfolge `order`.
- Direktaufruf einer Route eines deaktivierten Moduls zeigt `ModuleDisabled` (wie timetrack) und entspricht dem 404 `module_disabled` des Backends.
- Routenklassifikation wie `map.ts`: Test iteriert alle `src/routes/**/+page.svelte` und schlägt fehl, wenn die Route weder Kern noch exakt einem Modulpräfix zugeordnet ist.
- **Umsetzung WP-F2 (Stand 07.11.2026):** Der Vertrag liefert `navigation: [{module, key, label_key, path}]` (kein `icon`/`order`/`requires`; die Berechtigungsfilterung nach Rolle macht das Backend, die Reihenfolge ist die Backend-Reihenfolge). Icon und Modultexte liegen im Manifest (`lib/modules-impl/<modul>/manifest.ts`, Typ `lib/modules/manifest.ts`), Registrierung in `lib/modules/registry.ts` (registriert auch die Modultexte über `registerMessages`; dynamische Schlüssel wie `label_key` löst `tx()` auf). **Routen ohne `/m/`-Präfix**: das Backend liefert `path: "/dms"`; jedes Modul hat genau ein `routePrefix` (`/dms`). Kernrouten: `dashboard`, `settings`, `login`, `setup`, `invite`, `recover` (`lib/modules/routes.ts`). `lib/workspace.svelte.ts` hält aktiven Mandanten, Berechtigungen (`GET /tenants/{t}`) und Module (`GET /tenants/{t}/modules`); Mandantenwechsel ersetzt alles in einem Schritt, die Seitenleiste lädt Module bei Navigation und bei `visibilitychange` neu (kein Push-Event im Backend). `ModuleGate` zeigt `ModuleDisabled`, wenn das Modul im aktiven Mandanten nicht wirksam ist. Platzhalterroute `/dms` ohne Funktionalität; WP-F4 ersetzt sie.
- Akzeptanz (WP-F2): AK-F2-1 Menü zeigt nur aktive Module; AK-F2-2 Moduländerung im Backend wirkt nach Neuladen/Event ohne Neubau; AK-F2-3 Route-Klassifikationstest grün.

## 5. Auth und Mandant

- Login per Passkey (WebAuthn), Einladung, Recovery wie Vorbild (`routes/(public)/login|invite|recover`, `(app)/setup`, `recover`). Sitzung per HttpOnly-Cookie, Guard in `(app)/+layout.ts`: `sessionStore.refresh()` → Redirect auf `/login?next=…`.
- Mandantenwechsel: `tenant.svelte.ts` hält aktiven Mandanten (URL-unabhängig im Speicher + `localStorage` als Komfort, mit try/catch), alle API-Aufrufe tragen den Mandanten im Pfad. Wechsel leert modulbezogene Caches.
- Rollen steuern nur Sichtbarkeit; Autorisierung ist ausschließlich im Backend.
- CSRF: `SameSite=Lax` + Header-Prüfung bei mutierenden Anfragen (`Origin`-Check im Backend) **[Annahme]**.

## 6. Geteilte UI-Bibliothek

`lib/ui` ist die einzige Quelle für Bausteine; Module bauen nur daraus (keine eigenen Buttons/Dialoge).
- `ui/` = shadcn-svelte (CLI-erzeugt, nicht von Hand ändern ohne Vermerk).
- `app/` = zusammengesetzte Bausteine: `PageHeader`, `DataTable` (Cursor-Pagination, Sortierung, Spaltenwahl, Tastaturbedienung), `FilterBar`, `EmptyState`, `ConfirmDialog`, `Toast`, `FileDropzone` (Upload mit Fortschritt, Wiederaufnahme), `DocumentPreview` (PDF/Bild, `pdfjs-dist`), `MoneyInput`/`MoneyText` (Dezimal-String, locale-formatiert, kein `Number`), `StatusChip`, `ContactPicker`, `CommandPalette` (⌘K, globale Suche), `ErrorPage`, `ModuleDisabled`.
- Geldbeträge im Frontend: Strings; Berechnungen nur mit Dezimalbibliothek (z. B. `decimal.js`, Lizenz prüfen) und nur zur Anzeige/Vorschau; maßgeblich ist der Server.
- Design: eigene Designsprache, kein Paperless-Layout; Tokens (Farben, Radius, Abstände) zentral in `layout.css`, Akzentfarbe wählbar (Vorbild `theme/accent.ts`), `prefers-color-scheme` + manueller Schalter.

## 7. Offline und Service Worker

Vorbild `src/service-worker.ts` (Precache aus `$app/manifest` + static, Cache-first für gehashte Assets, Navigationsanfragen → SPA-Shell, Fallback `offline.html`, Cache-Name mit Version, alte Caches löschen, `isUsableAssetResponse` gegen HTML-statt-JS, Push-Handler). Hub-Regeln:
1. **API-Antworten werden nicht vom Service Worker gecacht** (V1); Sicherheit (Mandanten-/Rechtewechsel) vor Komfort.
2. Offline: Shell + Fehlermeldung „Keine Verbindung“, Entwurfstexte in `localStorage`/IndexedDB (per Nutzer, mit try/catch, nur Komfort).
3. Uploads offline: **V1 nein** (Fehlermeldung). Später: Warteschlange in IndexedDB mit Wiederaufnahme (Share-Target für Dokumente via `manifest.share_target`, Phase später).
4. Update-Policy wie Vorbild (`update-policy.ts`): neue Version erkennen, Hinweis „Neu laden“, kein erzwungenes Neuladen bei ungespeicherter Eingabe.
- Akzeptanz (WP-F3): Playwright-PWA-Lauf (Service Worker aktiv): erster Besuch cached Shell; offline geladene App zeigt Offline-Hinweis, keine API-Daten aus fremder Sitzung; nach Abmelden keine privaten Daten im Cache (Test).

## 8. DMS-UI (Bedienkonzept, Skizze)

Eigenes Konzept; Seiten: Eingang/Prüfen (Warteschlange mit Fehlern und Vorschlägen: annehmen/ablehnen per Tastatur), Dokumente (Liste + Facetten + Suche, Vorschau rechts), Dokument-Detail (Metadaten, Text, Verknüpfungen, Verlauf/Audit), Upload (Drag&Drop, Kamera/Scan auf Mobilgeräten), Stammdaten (Typen, Tags mit Gruppen und Merge, Pfade, Felder), Regeln (Trockenlauf), Quellen, Papierkorb, Export. Details und Akzeptanz: `MODUL-DMS.md`; UI-Akzeptanz je WP in `ROADMAP.md`.

**Umsetzung WP-F4 (Stand 07.11.2026):** Routen `/dms` (Upload, Suche, Filter, Liste) und `/dms/[id]` (Vorschau, Metadaten, Aktionen); Code in `lib/modules-impl/dms/` (`DmsBrowser`, `DocumentDetail`, `UploadPanel`, `upload.svelte.ts` Warteschlange, `snippet.ts`, `masters.ts`), Texte im Manifest (`dms.*`, Test `messages.test.ts` prüft de/en und ungenutzte Schlüssel). Festlegungen:
- **Zustand in der URL** (`q`, `type`, `corr`, `tags`, `from`, `to`, `trash`): Neuladen, Zurück-Taste, Lesezeichen. Seit WP-F4b läuft alles außer dem Papierkorb über `GET …/dms/search`: ein leerer Suchbegriff durchsucht ohne Suchbegriff (neueste Eingänge zuerst, `snippet` ist `null`), Datumsfilter, Facetten und mehrere Tags gelten in beiden Fällen. Nur die Papierkorb-Ansicht nutzt `GET …/dms/documents?trashed=true` (Suche schließt den Papierkorb aus; dort nur Typ, Korrespondent, erster Tag). Cursor-Pagination mit „Mehr laden“ (25 je Seite).
- **Snippet:** `parseSnippet` zerlegt an U+E000/U+E001 in Textteile; Treffer erscheinen als `<mark>{text}</mark>`, nie als HTML (Test mit eingeschleustem `<script>`).
- **Upload:** ein Aufruf je Datei (Roh-Body, `Idempotency-Key` je Datei, bei „Erneut versuchen“ derselbe Schlüssel), XHR wegen Fortschritt, zwei parallel. Die Upload-Antwort enthält `ingest_item_id`; danach wird `GET …/documents/{id}/processing` gepollt (1 s, nach 30 Abfragen alle 3 s) bis `phase` `done`, `none` oder `failed` ist. Zustände: wartet, lädt, verarbeitet (`queued`/`processing`/`retrying`), fertig, Duplikat, Quarantäne (`phase=failed`, Grund aus `error_code`, Aktion „Verarbeitung erneut starten“ = `POST …/processing/retry`, Recht `dms.document.update`), Fehler: 415 nicht unterstützt, 413 `payload_too_large` zu groß, 413 `storage_quota_exceeded` Speicher des Mandanten voll (eigener Text, kein Wiederholen-Knopf), 409 `upload_interrupted` wird bis zu dreimal automatisch mit demselben Idempotency-Key wiederholt, sonst übersetzter Fehlertext. Die Detailseite zeigt dieselbe Phase, pollt bis zum Ende, lädt dann die Dateien neu (Archivversion für die Vorschau) und bietet bei Quarantäne dieselbe Wiederholen-Aktion. In der Liste zeigen kürzlich eingegangene, nicht archivierte Zeilen Verarbeitung/Quarantäne aus `…/processing`.
- **Vorschau und Auslieferung:** Datei per `fetch` (Cookie) als Blob, Anzeige als `<img>` bzw. `<iframe>` mit `blob:`-URL (die Download-Route sendet CSP `sandbox` und `nosniff`; ein direkter Frame auf die Route würde im Chrome-PDF-Viewer scheitern). Vorschauquelle: Archivversion, sonst Original nur mit `dms.document.download_original`, sonst Thumbnail. Download-Link nur mit diesem Recht. **Für eine spätere Content-Security-Policy der PWA nötig:** `img-src blob:`, `frame-src blob:`.
- **Tastatur:** Liste mit Roving-Tabindex (ein Tabstopp), Pfeil auf/ab oder J/K, Home/End, Enter öffnet; „/“ springt zur Suche. Alle Aktionen sind Schaltflächen/Formularelemente.
- **A11y:** axe (`@axe-core/playwright`, Stufen serious/critical) auf Suchergebnis, Fehlerzuständen, Detail (de/en) und Papierkorb im Mock-E2E.
- **Mock** (`pwa/mock/dms.ts`) bildet `…/processing`, `…/processing/retry`, leere Suche, `storage_quota_exceeded` und `upload_interrupted` nach (Marker im Dateiinhalt, siehe Kopfkommentar); die frühere Mock-Erweiterung `ingest_state` ist entfallen.

**Umsetzung WP-F5 (Stand 08.11.2026):** Unterseiten des Moduls unter `/dms/review`, `/dms/rules`, `/dms/duplicates`, `/dms/masters`, `/dms/trash`, `/dms/integrity`, `/dms/exports` (Routen unter `src/routes/(app)/dms/`, Code in `lib/modules-impl/dms/`, Teilnavigation `DmsNav` im Layout `dms/+layout.svelte`; ein Eintrag erscheint nur mit der passenden Berechtigung, `DmsPage` zeigt sonst „Berechtigung fehlt“; die Autorisierung bleibt im Backend). API-Client `dmsAdminApi` in `lib/api/client.ts`, Texte in `messages-admin.ts` (in das Manifest eingemischt; `messages.test.ts` prüft jetzt alle Quelldateien des Moduls auf fehlende und tote Schlüssel). Festlegungen:
- **Prüf-Warteschlange** (`ReviewQueue`, `SuggestionCard`): offene Vorschläge über alle Dokumente (`GET …/suggestions`, Filter Art), je Vorschlag der Wert **mit Namen** (Typ/Tag/Pfad/Kontakt aus den Stammdaten), die **Begründung der Regel im Klartext** (`reason`), Sicherheit und Regelname. Tastatur: Roving-Tabindex (ein Tabstopp), Pfeile/J/K/Home/End bewegen, **A** nimmt an, **R** lehnt ab, **E** öffnet das Dokument zum Ändern („Ändern“ = im Dokument editieren; das Backend kennt keine Änderung des Vorschlagswerts); nach der Entscheidung rückt der Fokus nach, eine Live-Region meldet das Ergebnis. **Veraltet:** fehlt das Ziel (Typ/Tag/Pfad gelöscht) oder antwortet das Backend mit 409 `suggestion_stale`, zeigt die Karte den Hinweis, „Annehmen“ ist gesperrt, „Ablehnen“ bleibt möglich; `suggestion_decided` (409) entfernt die Zeile. Dasselbe je Dokument im Detail (`DocumentSuggestions`).
- **Regeln** (`RulesPage`, `RuleEditor`, `rule-draft.ts`): Liste mit Priorität, Modus, Version und Bilanz (vorgeschlagen/offen/angenommen/abgelehnt/automatisch); Editor mit Bedingungen (6 Arten, `all`/`any`), Aktionen (Korrespondent, Typ, Tags, Pfad, Datum `extracted`/fest, Titelvorlage), Priorität, Sicherheit, Modus `suggest|auto`. **Trockenlauf** (`POST …/rules/preview`) mit Trefferliste (Fundstelle, entstehende Vorschläge), Regex-Abbrüchen (`timed_out`, Warntext) und `truncated`; **Regeln im Modus `auto` lassen sich nur speichern, wenn der Trockenlauf genau dieser Fassung gelaufen ist** (jede Änderung macht ihn „veraltet“). Feldfehler des Backends (422 `errors[]`, z. B. `invalid_regex`) werden mit Feld und Code gezeigt. Löschen mit Bestätigungsdialog.
- **Duplikate** (`DuplicatesPage`): Liste (Standard offen), Gegenüberstellung (Titel, Datum, Typ, ASN, Eingang, Datei, SHA-256 beider Dokumente), Entscheidung „Ist ein Duplikat“/„Kein Duplikat“ (nur Vermerk, nichts wird gelöscht oder zusammengeführt).
- **Stammdaten** (`MastersPage`): Typen (mit Aufbewahrung in Jahren = Fristen je Dokumenttyp), Tag-Gruppen, Tags, Ablagepfade, eigene Felder; anlegen, **umbenennen/ändern** (Kennung und Datentyp eines Felds sind unveränderlich, Eingabe entfällt), löschen (409 → „wird verwendet“). **Tag-Merge:** das Backend hat keine Route (`POST /tags/{id}/merge` steht nur im Konzept); die Seite sagt das ausdrücklich.
- **Papierkorb/Löschkonzept** (`TrashPage`, `ConfirmDialog`): Liste der Papierkorb-Dokumente mit Fristende und Herkunft der Frist, Löschsperre (setzen/aufheben, Recht `dms.document.retention`), Frist verlängern (nur verlängern), **Hinderungsgründe** (`blockers`) im Klartext, Wiederherstellen. **Endgültig löschen** nur mit Recht `dms.document.purge` (Owner) und nur wenn `can_purge`; Bestätigungsdialog (natives `<dialog>`, Fokus auf „Abbrechen“, Esc bricht ab) mit ausdrücklicher Bestätigung (Kontrollkästchen); 409 des Backends wird übersetzt angezeigt und der Zustand neu geladen. Darunter das **Löschprotokoll** (Prüfsumme, Größe, ASN, Zeitpunkt; kein Titel). Hinweis „GoBD-orientiert, keine Rechtsberatung“ (F-24), keine Konformitätsaussage.
- **Integrität** (`IntegrityPage`): Lauf starten (202), Liste der Läufe (Polling bis `passed|failed|error`), Bericht (Funde mit Art, Ketten-Ergebnis mit Befund), **Kopf-Hash** der Kette mit Hinweis, ihn außerhalb zu verankern. **Export** (`ExportsPage`): Job mit Zeitraum und Dokumenttyp starten, Status (Polling), Prüfsummen, Download-Link (`GET …/exports/{id}/file`), Fehlertexte für `integrity_failed`/`export_too_large`/`export_failed`. Auswahl einzelner Dokumente (`document_ids`) bietet die Oberfläche nicht an.
- **Nicht gebaut:** Quellen-Verwaltung (siehe WP-F5b unten). **Fehlende Backend-Routen:** Tag-Merge, Neu-Klassifikation bestehender Dokumente, Änderung des Vorschlagswerts, Zeitplan für Prüfläufe (siehe `docs/handoff/WP-F5.md`).
- **Mock** (`pwa/mock/dms-admin.ts`, Kopfkommentar): bildet die Routen von D3/D5 und die Stammdatenpflege nach; Regeln wirken beim Upload (Vorschlag oder `auto`), Marker `(a+)+$` (Zeitlimit), `MOCK-TAMPER` (Prüflauf/Export scheitern), Seed-Hilfe `POST /api/__mock/dms/seed` mit `trashed`, `doc_date`, `title`, `tamper`.
- **Tests:** Mock-E2E `e2e-mock/dms-admin.spec.ts` (Prüf-Workflow mit Tastatur und Stale-Hinweis, Regel mit Trockenlauf/Regex-Fehler/Zeitlimit/`auto`-Sperre, Papierkorb/Purge-Bestätigung/Löschprotokoll/Owner-Grenze, Export, Integrität, Duplikate, Stammdaten, Englisch), axe serious/critical = 0 auf allen neuen Seiten und im Purge-Dialog.

**Umsetzung WP-F5b (Stand 08.11.2026):** Routen `/dms/sources`, `/dms/tokens`, `/dms/scanner` (Teilnavigation `DmsNav`), Code in `lib/modules-impl/dms/` (`SourcesPage`, `SourceEditor`, `sources.ts`, `TokensPage`, `ScannerPage`, `ProcessingCard`), Texte in `messages-sources.ts` (im Manifest zusammengeführt, de/en).
- **Quellen** (Recht `dms.source.read`, ändern mit `dms.source.manage`): Liste mit Art, Zusammenfassung, aktiv/deaktiviert, letztem Lauf, Status, Zählern (`last_stats`), Fehlercode als Klartext (`dms.sources.error.<code>`: `imap_connect_failed`, `imap_tls_failed`, `imap_auth_failed`, `imap_mailbox_not_found`, `imap_timeout`, `secret_key_missing`, `secret_unreadable`, `secret_missing`, `folder_not_found`, `folder_root_missing`, `storage_quota_exceeded` …; unbekannte Codes zeigen den Code). Aktionen: Verbindung testen (nur Mail; Ordnerquellen gibt es dafür nicht, die Seite sagt es), Jetzt ausführen (Lauf wird eingeplant, Ergebnis nach „Aktualisieren“), Aktivieren/Deaktivieren, Bearbeiten, Löschen mit `ConfirmDialog`. Formular Mail: Name, Host, Port (993), Benutzer, Passwort, Ordner, Ordner für verarbeitete Nachrichten, Filter Absender/Betreff, Mailtext als PDF, Abstand, Höchstzahl; Konsumordner: relativer Unterordner (Vorschau `<Konsumordner>/<Mandant>/<Pfad>`), Abstand, Stabilitätszeit. **Das Passwort ist nur schreibend:** nie angezeigt, beim Bearbeiten bleibt das Feld leer (leer = unverändert), nach dem Speichern wird es aus dem Zustand gelöscht. 422 mit Feldfehler (`config.host` = ungültig oder vom Betreiber nicht erlaubt, `password` + `secret_key_missing`), 409 = Name vergeben.
- **API-Tokens** (`/dms/tokens`): Erstellen mit Name, Scope `dms.upload`, Ablauf in Tagen (1 bis 730); der Klartext steht nur im Zustand der Seite (nie in Liste, URL oder Speicher), mit „Kopieren“, und verschwindet mit „Fertig“ oder beim Verlassen der Seite; Liste mit Erstellt/Läuft ab/Zuletzt benutzt/Status; Widerruf mit Bestätigung.
- **Scanner/Teilen-Menü** (`/dms/scanner`): Endpunkt (`POST …/dms/share`), Kopfzeile `Authorization: Bearer lhp_…`, Inhalt, optionale Parameter, curl-Beispiel mit Platzhalter `hub.example.org`, Hinweise zu Geräten, Antwortcodes.
- **Dashboard-Karte „Verarbeitung“** (`ProcessingCard`, Kernseite `/dashboard`, nur bei wirksamem Modul und Leserecht): Dokumente in Verarbeitung und zu prüfen (`GET …/documents?status=…&count=true`), offene Vorschläge, Quellen mit Fehler. **Dauerhaft fehlgeschlagene Verarbeitung (Quarantäne) ist nicht zählbar** (keine Backend-Route), sie steckt in „In Verarbeitung“; die Karte sagt das.
- **Mock** (`pwa/mock/dms-sources.ts`, Kopfkommentar): Quellen und Tokens; Ergebnis von Test/Lauf steuert die Konfiguration (Host `tls-fail`, `slow`, Benutzer `wrong`, Postfach `MISSING`, Pfad `missing`; Host `blocked.example.org` und Passwort `no-key` für die 422).
- **Tests:** Vitest `sources.test.ts`; Mock-E2E `e2e-mock/dms-sources.spec.ts` (Quelle anlegen/testen/bearbeiten/ausführen/deaktivieren/löschen, Fehlerdarstellung, Token einmalig/kopieren/widerrufen, Scanner-Seite, Tastatur, Karte, Englisch), axe serious/critical = 0 auf allen neuen Seiten und Dialogen; echter E2E `e2e/dms.spec.ts` um Schritt 10/11 erweitert (Mail-Quelle mit verweigerter Verbindung, Token -> `curl` -> Dokument -> Widerruf -> 401); das Backend braucht dafür `SECRET_KEY`.

**Umsetzung WP-F4c (Stand 08.11.2026):** Dokumentübersicht, Eingang und gegliederte Seitenleiste (Handoff `docs/handoff/WP-F4c.md`). Ersetzt `DmsBrowser`/`DmsNav`, keine Funktion entfällt.
- **Seitenleiste (ganze Shell):** Gruppen mit Überschrift, einklappbar (Zustand in `localStorage`, Gruppe der aktuellen Seite immer offen), Icons, aktiver Eintrag, unter `lg` als Schublade (Menüknopf in der Kopfleiste, Esc/Hintergrund schließen, `inert` solange zu). Aufbau in `lib/modules/sidebar.ts` (reine Logik, Test): Start, danach die **Gruppen jedes wirksamen Moduls aus dem Manifest** (`ModuleManifest.navigation`, Einträge mit `permission`; ohne `navigation` fällt die Shell auf den einen Backend-Eintrag zurück), zuletzt „Einstellungen“ (`lib/core-nav.ts`, ersetzt die Reiter). DMS (`modules-impl/dms/navigation.ts`): Gruppe „Dokumente“ (Übersicht `nav-dms`, Eingang, Prüfen, Duplikate, Papierkorb) und „Verwaltung“ (Regeln, Stammdaten, Quellen, API-Tokens, Scanner, Integrität, Export). Der F2-Mechanismus (Backend-Navigation × wirksame Module × Manifest) bleibt. Pfeiltasten/Home/End in der Leiste.
- **Übersicht `/dms`** (`DocumentOverview`): Tabelle mit Art (Badge, „?“ bei unsicherer Art), Titel/Absender, Datum, Betrag mit Währung (`Intl`, Dezimalstring), Fälligkeit (überfällig hervorgehoben), Referenz, Status (Verarbeitung, Quarantäne, offene Vorschläge). Zeitbereich-Presets (Heute, 7 Tage, Monat, Jahr, Alle), Filter Art, Betrag von/bis, Fälligkeit (überfällig, 7 Tage, fällig/überfällig), Sortierung (Spaltenköpfe und Auswahl), weitere Filter (Typ, Absender, Währung, Datum von/bis, Tags, „nur mit offenen Vorschlägen“, Papierkorb). Alles in der URL. **Zwei Routen:** Standard und Volltextsuche laufen über `…/search` (Snippets, Facetten, mehrere Tags, Zeitraum = `doc_date`); sobald Art-/Betrags-/Fälligkeitsfilter, eine andere Sortierung als „Eingang“ oder der Papierkorb aktiv sind, läuft die Liste über `…/documents` (nur dort gibt es diese Filter; Zeitraum = erkanntes Belegdatum, Suchfeld = nur Titel, nur erster Tag, keine Facetten) und die Seite sagt das. In Suchtreffern fehlen Art/Betrag/Fälligkeit im Vertrag (`DmsSearchHit`); sie werden je Zeile über `GET …/documents/{id}` nachgeladen (höchstens 4 parallel). Offene Vorschläge je Dokument aus `…/suggestions` (bis 1000), der Filter wirkt auf der Client-Seite. **Keine Summenzeile:** das Backend liefert keine Summe über den gefilterten Betragsbereich; sie wird nicht berechnet oder erfunden.
- **Eingang `/dms/inbox`** (`InboxPage`): „Braucht Aufmerksamkeit“ (offene Vorschläge mit Annehmen/Ablehnen, Dokumente mit fehlgeschlagener Verarbeitung mit Neustart, Quellen mit Fehler, Fälligkeiten der nächsten 7 Tage samt überfälliger) und „Neu eingegangen“; aus bestehenden Routen.
- **Detail:** Art-Badge, Panel „Erkannte Fakten“ (`FactsPanel`: Art mit Wahrscheinlichkeit und Gründen, je Fakt Wert, Konfidenz, Begründung, Fundstelle als Text; „Erkennung neu ausführen“ = `POST …/extraction/run`), Kandidaten annehmen/ablehnen über die vorhandenen Vorschlagsrouten (Quelle „Erkennung“), Verknüpfungen Mail↔Anhang (`LinksPanel`, `GET …/links`, Recht `contact.link.read`), Mail-Vorschau: der geschützte HTML-Teil im `<iframe sandbox="">` direkt von der Datei-Route (`role=derivative`, CSP `default-src 'none'; sandbox`, nosniff), nie per `innerHTML`. Metadaten bearbeiten wie bisher.
- **Mock:** `mock/dms.ts` bildet Extraktion (kleiner Platzhalter-Extraktor: Betrag/Fälligkeit/Nummer aus Beschriftungen im Text), Listenfilter und -sortierung des Vertrags, `…/extraction(/run)`, `…/links`, Mail-Derivat nach; `seed` kennt `extraction`, `suggest`, `mail`, `type_name`.
- **Tests:** Vitest `overview.test.ts`, `sidebar.test.ts`; Mock-E2E `e2e-mock/dms-overview.spec.ts` (Filter, Sortierung, Suche, Presets, Fakten, Mail-iframe, Eingang, Tastatur, Seitenleiste, Mobil ohne horizontalen Scroll), axe serious/critical = 0; echter E2E `e2e/dms.spec.ts` Schritt 12 (synthetische Rechnung -> Art „Rechnung“ und Betrag -> Betragsfilter).

## 9. i18n

- Schlüssel englisch gepunktet (`dms.document.title`), `t(key, params)` mit `{name}`-Platzhaltern, Plural per `Intl.PluralRules` (Hilfsfunktion `tn`), Zahlen/Datum/Währung per `Intl` mit Mandanten-Locale.
- `de.ts` definiert `MessageKey`; `en.ts: Record<MessageKey,string>` erzwingt Vollständigkeit zur Compile-Zeit; Test prüft Platzhalter-Übereinstimmung de/en.
- Fehlercodes des Backends → `error.<code>` (Fallback `error.status_<n>`), Muster `errorMessage()` im Vorbild.
- Keine Nutzertexte in Komponenten (Regel aus timetrack-pwa `AGENTS.md`); Lint-Test sucht Textknoten mit Buchstaben in `.svelte` außerhalb von `t()` (heuristisch).
- Sprachwahl: Nutzerprofil > Browser > `de`. Dokumentation und Backend-Meldungen bleiben Deutsch (Backend sendet Codes + deutsche Meldung).

## 10. Barrierefreiheit

WCAG 2.2 AA als Ziel (Annahme): Tastaturbedienung aller Funktionen, sichtbarer Fokus, Fokusfalle in Dialogen (`a11y/focus-trap`), ARIA-Rollen über shadcn/bits-ui, Kontrast in beiden Themes, `prefers-reduced-motion`, Live-Region für Toasts und Upload-Fortschritt, Tabellen mit korrekter Semantik. Test: `@axe-core/playwright` auf jeder Hauptseite (Vorbild `e2e-mock/accessibility.spec.ts`), keine Verstöße der Stufen serious/critical.

## 11. Tests

| Ebene | Werkzeug | Inhalt |
| --- | --- | --- |
| Unit | Vitest + jsdom | Stores, Formatierer, Geld, Manifest-Logik, i18n-Vollständigkeit, SW-Kernfunktionen (`pwa/core.ts`-Muster) |
| Komponente | `@testing-library/svelte`, `user-event` | geteilte UI, Formulare |
| E2E mit Mock | Playwright (`VITE_MOCK=1`) | schnelle UI-Abläufe, a11y |
| E2E real | Playwright gegen Swift-Backend mit Postgres (Port per `E2E_PORT`) | Passkey (virtueller Authenticator über CDP), Upload→OCR→Suche, Mandanten, Moduleschalter |
| PWA | Playwright mit Service Worker | Installierbarkeit, Offline-Shell, Update |
| Typen | `svelte-check`, `tsc` | `npm run check` |

Befehle (festgeschrieben mit WP-F1, alle im Verzeichnis `pwa/`; `test:e2e:pwa` folgt mit WP-F3; `test:e2e:dms` seit WP-F4b):
- Installation: `npm ci`
- Prüfung: `npm run check` (svelte-check plus Aktualität von `src/lib/api/types.ts`), `npm test` (Vitest)
- Build: `npm run build` (Ausgabe `pwa/build/`)
- Entwicklung: `npm run dev` (Proxy `/api` auf `BACKEND_URL`, Standard `http://127.0.0.1:8080`), `npm run dev:mock` (Mock-API im Vite-Server)
- Vertragstypen neu erzeugen: `npm run gen:api`
- E2E gegen Mock-Backend: `npm run test:e2e:mock` (baut und startet `mock/server.ts` auf `localhost:4173`)
- E2E gegen echtes Backend: `E2E_BACKEND_URL=http://127.0.0.1:<port> E2E_SETUP_TOKEN=<token> npm run test:e2e` (frische Datenbank, Backend mit `SETUP_TOKEN`, `PUBLIC_URL=http://localhost:5173`, `WEBAUTHN_RP_ID=localhost`)
- E2E DMS gegen echtes Backend **mit OCR-Worker** (WP-F4b): `E2E_PORT=5174 E2E_BACKEND_URL=http://127.0.0.1:<port> E2E_SETUP_TOKEN=<token> npm run test:e2e:dms`. Eigene frische Datenbank (die Bootstrap-Anmeldung ist einmalig; `test:e2e` und `test:e2e:dms` brauchen je eine), `PUBLIC_URL` und `E2E_PORT` stimmen überein (`http://localhost:<E2E_PORT>`), Backend und `App worker --kinds dms.ocr,dms.verify,dms.export` (Image `Dockerfile.worker`, Ziel `worker`, bei macOS im Container mit `--network host`) auf dieselbe Datenbank. Ablauf: Bootstrap, Einladung (Rolle Buchhaltung), Passkey, **(WP-F5) Dokumenttyp „Rechnung“ und Regel mit Trockenlauf anlegen**, synthetisches Scan-PDF (nur Bild, im Browser gezeichnet, `e2e/scan-pdf.ts`), OCR, Treffer mit Snippet, Durchsuchen ohne Suchbegriff, Vorschau/Archiv/Original, **(WP-F5) Vorschlag der Regel in der Prüf-Warteschlange, per Taste annehmen, Typ am Dokument, Integritätsprüfung, Export mit Download**, Papierkorb, **Papierkorbseite mit Hinderungsgrund**. Ohne `E2E_DMS` wird der Test übersprungen.

## 12. Build und Auslieferung

`npm run build` → `pwa/build/` (statisch, `index.html`-Fallback, `version.json`). Das Docker-Image kopiert `pwa/build` in das Backend-Image (Mehrstufiger Build); Backend liefert Dateien unter `/` aus, API unter `/api`. Dev: Vite-Proxy auf `BACKEND_URL` (Vorbild `vite.config.ts`). `OpenAPI → types.ts` per Generator (F-17), generierte Datei wird committet und per CI-Check auf Aktualität geprüft.

## 13. Layout-Verwaltung und Designer in der PWA (Entwurf, offen F-31)

Da der Hub ohne App nutzbar sein muss, braucht die PWA Layouts für Belege. Stufen:
1. **V1 (WP-F6):** Standardlayouts wählen, Parameter (Logo-Upload, Farben, Schrift aus freigegebener Liste, Kopf-/Fußtexte, Platzhalter-Vorschau); PDF-Vorschau kommt vom Server-Renderer (`invoice.render`), nicht aus dem Browser.
2. **WP-F7a:** Layoutliste, Versionen, Import vorhandener Layouts (Taxlab-/Totals-Importformat), Zuordnung je Belegtyp/Serie, Vorschau mit Beispieldaten.
3. **WP-F7b:** Grafischer Designer (Elemente, Ebenen, Seiten, Inspector, Tastatur) nach dem Konzept der App (taxlab `docs/LAYOUT-DESIGNER.md`, `docs/DESIGNER.md`); gemeinsames Layoutmodell mit Server-Renderer, Canvas-Vorschau nur zur Bearbeitung, maßgeblich ist das Serverergebnis.
Akzeptanz F7: Layout-Roundtrip (speichern, laden, rendern) ohne Verlust; a11y der Bedienelemente (Tastaturalternative zu Drag&Drop); Mandantentrennung der Layouts.
