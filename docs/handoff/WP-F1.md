# Übergabe WP-F1 (PWA-Gerüst)

Stand 07.11.2026, Branch `wp-F1` (auf `main` 8dbdb3d). Status: AK-F1-1…4 umgesetzt und getestet, Gate (`npm ci && npm run check && npm test && npm run build`) grün. Test und Implementierung entstanden in derselben Session (kein belegter Rot-Lauf vor der Umsetzung).

## Umgesetzt (alles unter `pwa/`)
- SvelteKit 3 + Svelte 5 (Runes erzwungen), `adapter-static` mit `fallback: index.html`, Tailwind 4, shadcn-svelte (Stil „nova“; `button`, `input`, `label`, `card`, `alert` per CLI erzeugt), `SHADCN-LICENSE.md`. Ausgabe `pwa/build/` inkl. `version.json` und `licenses.json`. SPA-Modus (`ssr = false`), kein SSR.
- Auth gegen die K1-Routen laut Vertrag: `(public)/setup` (Bootstrap per Setup-Token), `(public)/invite/[token]` (Einladung annehmen; Link-Format `/invite/<token>` entspricht dem `link` der Backend-Antwort), `(public)/login` (Passkey), `(public)/recover` (Recovery-Code, Notfall-Sitzung), Abmelden in der Shell. Nach Recovery zeigt das Dashboard einen Hinweis und legt einen neuen Passkey an (`/me/passkeys/*`), der die Sitzung hochstuft.
- Guard `(app)/+layout.ts`: Sitzung lesen, sonst Redirect `/login?next=…` (`safeNext` verhindert offene Redirects); `(app)/+layout.svelte` verlässt still, wenn die Sitzung verschwindet (401 → `session_ended`).
- API-Client `src/lib/api/client.ts` (schlank, `fetch`, Cookie-Sitzung, `X-CSRF-Token` aus `csrf_token` bei schreibenden Aufrufen), Typen aus dem Vertrag: `npm run gen:api` (openapi-typescript) → `src/lib/api/types.ts` (committet); `npm run check` prüft per `scripts/check-api-types.mjs`, dass die Datei aktuell ist (F-17). Problem Details → `ApiError(status, code, …)`; `errorMessage()` bildet `error.<code>` → `error.status_<n>` → `error.generic` ab.
- i18n de/en: `de.ts` ist Referenz (`MessageKey`), `en: Record<MessageKey,string>` erzwingt Vollständigkeit zur Compile-Zeit. Sprachwahl: gespeicherte Wahl > Browser > de, Umschalter in Shell und Public-Layout.
- Mock-Backend `mock/api.ts` (synthetische Fixtures, prüft Challenge-ID, Setup-Token, Einladung einmalig, Cookie, CSRF, Recovery-Code; keine WebAuthn-Signaturprüfung), als Vite-Plugin (`dev:mock`) und als Server `mock/server.ts` (statische Auslieferung von `build/` mit Deep-Link-Fallback, wie das Backend es tun soll).

## Tests (Name nennt das AK)
- AK-F1-1: `npm run check` (0 Fehler, 0 Warnungen, Typen aktuell), `npm test` (Vitest, 4 Dateien, 24 Tests: API-Client inkl. Problem Details/CSRF/`session_ended`, `safeNext`, WebAuthn-Helfer, i18n).
- AK-F1-4: `src/lib/i18n/i18n.test.ts` (gleiche Schlüssel de/en, gleiche Platzhalter, jeder `Problem.code` aus `contracts/openapi.yaml` hat `error.<code>` in beiden Sprachen, heuristischer Test „kein Text in `.svelte` außerhalb von `t()`“).
- AK-F1-3: `npm run build` erzeugt `build/index.html` (SPA-Fallback), `build/_app/…`, `version.json`; der E2E-Test „F1-3 deep links“ lädt `/recover` über den Fallback mit HTTP 200.
- AK-F1-2 (Mock): `npm run test:e2e:mock` (Playwright/Chromium, virtueller Authenticator per CDP, 7 Tests: Einladung → Passkey → Dashboard, Abmelden, Passkey-Login, Einladung nur einmal, Guard mit `next`, Bootstrap, Recovery-Upgrade, Sprachumschaltung).
- AK-F1-2 (echtes Backend): `E2E_BACKEND_URL=… E2E_SETUP_TOKEN=… npm run test:e2e` lief grün gegen das Swift-Backend (Debug-Build von `wp-F1`/`main`, eigene Datenbank auf dem Test-Postgres `127.0.0.1:15432`, danach gelöscht; Backend mit `SETUP_TOKEN`, `PUBLIC_URL=http://localhost:5173`, `WEBAUTHN_RP_ID=localhost`): Bootstrap → Einladung per API → Einladung annehmen mit Passkey → Dashboard → Abmelden → Passkey-Login → zweite Nutzung der Einladung wird abgelehnt. Die PWA lief dabei auf dem Vite-Dev-Server (Proxy `/api`), nicht vom Backend ausgeliefert (siehe offene Punkte).

## Entscheidungen und Annahmen (bitte bestätigen)
- Routen: `/setup` für den Bootstrap, `/invite/[token]` (Pfadparameter, wie der Link des Backends), `/dashboard` als Kern-Startseite, `/` leitet dorthin um. Route-Präfix `/m/<modul>` wird erst mit WP-F2 relevant.
- `#lib` wird als Vite-`resolve.alias` plus tsconfig-`paths` ohne Dateiendung aufgelöst (SvelteKit-`alias` ist deprecated; `package.json` `imports` bleibt für die shadcn-CLI).
- TypeScript 5.9 statt 6: `openapi-typescript` 7 verlangt TypeScript ^5 (Peer-Konflikt mit 6.x).
- Der Vertrag typisiert `PasskeyVerifyRequest.credential` als freies Objekt (generiert `Record<string, never>`); der Client verwendet dafür einen schmalen Wrapper-Typ. Vorschlag für K4/Vertrag: `additionalProperties: true` setzen.
- Mock-Backend ist ein Node-Server (`node mock/server.ts`, Node ≥ 22.18 wegen Type-Stripping), kein Vite-Plugin, damit der gebaute Bundle getestet wird. Playwright-Browser müssen lokal installiert sein (`npx playwright install chromium`).
- Lizenzen: Inter-Schrift (OFL-1.1) und `lightningcss` (MPL-2.0, nur Build-Zeit) liegen außerhalb der Vorgabe MIT/Apache/ISC/BSD, siehe `docs/LIZENZEN.md`; Bestätigung offen.

## Vorschlag Auslieferung durch das Backend (NICHT umgesetzt, nicht Besitzbereich)
1. Dockerfile: zusätzliche Stufe `FROM node:24-bookworm-slim AS pwa` (`WORKDIR /src/pwa`, `COPY pwa/package*.json ./`, `RUN npm ci`, `COPY pwa/ ./`, `COPY contracts/ /src/contracts/`, `RUN npm run build`); im Laufzeit-Image `COPY --from=pwa /src/pwa/build /usr/share/lab-hub/pwa` (read-only, schreibt nichts zur Laufzeit). Der Typ-Check braucht `contracts/`, der Build selbst nicht.
2. Backend: Middleware nach den API-Routen, die `GET`/`HEAD` auf Dateien unter `PWA_DIR` (Standard `/usr/share/lab-hub/pwa`) ausliefert, nie unter `/api`, `/health`, `/ready`; unbekannte Pfade ohne Dateiendung → `index.html` (Deep-Link-Fallback, wie `mock/server.ts`). Nicht gefundene `/api/…`-Pfade bleiben 404 `application/problem+json`. Cache: `_app/immutable/*` mit `Cache-Control: public, max-age=31536000, immutable`; `index.html`, `version.json` mit `no-cache`. Vorbild: `PWAStaticMiddleware.swift` im timetrack-backend.
3. Vertragstest AK-K4-1 betrifft nur `/api`-Routen; die Dateiauslieferung muss ihn ausnehmen. Test: `GET /` → 200 HTML, `GET /invite/x` → 200 `index.html`, `GET /api/v1/unbekannt` → 404 Problem, `GET /_app/…` → Datei.
4. CI (`scripts/ci.sh` unverändert): optional `cd pwa && npm ci && npm run check && npm test && npm run build`.

## Offen / Folge-WPs
- **AK-F1-3 zweiter Halbsatz „Backend liefert `/` und Deep-Link-Fallback“** ist erst nach der Backend-Änderung oben belegbar; hier nur durch `mock/server.ts` nachgebildet.
- Service Worker, Manifest, Icons, Offline-Seite: WP-F3 (`serviceWorker.register` ist aus). `index.html` setzt nur `theme-color`.
- Modulnavigation, Mandantenwechsel, Einstellungen (Passkeys, Sitzungen, Recovery-Codes anzeigen/erzeugen): WP-F2. Recovery-Codes werden nach dem Bootstrap noch nirgends angezeigt (die Routen existieren im Vertrag, UI fehlt) — vor produktivem Einsatz nachziehen, sonst ist Recovery nicht nutzbar.
- axe-Prüfung (`@axe-core/playwright`) und Playwright-PWA-Lauf sind nicht Teil von F1; Formulare sind mit Labels, Fokus-Reihenfolge und `role="alert"` für Fehler gebaut, aber nicht automatisch geprüft.
- Reale WebAuthn-Hardware (Touch ID, Sicherheitsschlüssel) nicht getestet, nur der virtuelle CTAP2-Authenticator von Chromium.
- Nächster Schritt: Backend-Auslieferung + Dockerfile-Stufe (Vorschlag oben) als eigenes kleines WP, danach WP-F2.
