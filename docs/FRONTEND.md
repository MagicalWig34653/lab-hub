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

Befehle (festgeschrieben mit WP-F1, alle im Verzeichnis `pwa/`; `test:e2e:pwa` folgt mit WP-F3):
- Installation: `npm ci`
- Prüfung: `npm run check` (svelte-check plus Aktualität von `src/lib/api/types.ts`), `npm test` (Vitest)
- Build: `npm run build` (Ausgabe `pwa/build/`)
- Entwicklung: `npm run dev` (Proxy `/api` auf `BACKEND_URL`, Standard `http://127.0.0.1:8080`), `npm run dev:mock` (Mock-API im Vite-Server)
- Vertragstypen neu erzeugen: `npm run gen:api`
- E2E gegen Mock-Backend: `npm run test:e2e:mock` (baut und startet `mock/server.ts` auf `localhost:4173`)
- E2E gegen echtes Backend: `E2E_BACKEND_URL=http://127.0.0.1:<port> E2E_SETUP_TOKEN=<token> npm run test:e2e` (frische Datenbank, Backend mit `SETUP_TOKEN`, `PUBLIC_URL=http://localhost:5173`, `WEBAUTHN_RP_ID=localhost`)

## 12. Build und Auslieferung

`npm run build` → `pwa/build/` (statisch, `index.html`-Fallback, `version.json`). Das Docker-Image kopiert `pwa/build` in das Backend-Image (Mehrstufiger Build); Backend liefert Dateien unter `/` aus, API unter `/api`. Dev: Vite-Proxy auf `BACKEND_URL` (Vorbild `vite.config.ts`). `OpenAPI → types.ts` per Generator (F-17), generierte Datei wird committet und per CI-Check auf Aktualität geprüft.

## 13. Layout-Verwaltung und Designer in der PWA (Entwurf, offen F-31)

Da der Hub ohne App nutzbar sein muss, braucht die PWA Layouts für Belege. Stufen:
1. **V1 (WP-F6):** Standardlayouts wählen, Parameter (Logo-Upload, Farben, Schrift aus freigegebener Liste, Kopf-/Fußtexte, Platzhalter-Vorschau); PDF-Vorschau kommt vom Server-Renderer (`invoice.render`), nicht aus dem Browser.
2. **WP-F7a:** Layoutliste, Versionen, Import vorhandener Layouts (Taxlab-/Totals-Importformat), Zuordnung je Belegtyp/Serie, Vorschau mit Beispieldaten.
3. **WP-F7b:** Grafischer Designer (Elemente, Ebenen, Seiten, Inspector, Tastatur) nach dem Konzept der App (taxlab `docs/LAYOUT-DESIGNER.md`, `docs/DESIGNER.md`); gemeinsames Layoutmodell mit Server-Renderer, Canvas-Vorschau nur zur Bearbeitung, maßgeblich ist das Serverergebnis.
Akzeptanz F7: Layout-Roundtrip (speichern, laden, rendern) ohne Verlust; a11y der Bedienelemente (Tastaturalternative zu Drag&Drop); Mandantentrennung der Layouts.
