# pwa/ – Frontend (WP-F1: Gerüst)

SvelteKit (Svelte 5, Runes) + Tailwind 4 + shadcn-svelte, als PWA statisch gebaut (`adapter-static`, Fallback `index.html`) und vom Backend ausgeliefert. Architektur, Modul-Manifest, i18n, Offline und Tests: `../docs/FRONTEND.md`; Entscheidung: `../docs/decisions/0007-frontend-stack.md`. Befehle: `../docs/FRONTEND.md` Abschnitt 11.

Stand WP-F1:

```
pwa/
  package.json  vite.config.ts  components.json  playwright.config.ts  playwright.mock.config.ts
  scripts/   generate-licenses.mjs  check-api-types.mjs  build-info.ts
  mock/      api.ts (Mock-API, synthetisch)  server.ts (statisch + Mock)  vite-plugin.ts
  e2e/       Specs gegen echtes Backend, virtual-authenticator.ts
  e2e-mock/  Specs gegen das Mock-Backend
  src/
    routes/  (public)/ login, setup, invite/[token], recover   (app)/ Guard + Shell, dashboard
    lib/     api/ (client, errors, types.ts generiert)  i18n/ (de, en)  components/{ui,app}  session.svelte.ts  webauthn.ts
```

Regeln: Nutzertexte nur über i18n (de/en, Test prüft Vollständigkeit und Fehlercodes des Vertrags); `src/lib/api/types.ts` ist aus `../contracts/openapi.yaml` erzeugt und wird per `npm run check` auf Aktualität geprüft; keine API-Antworten im Service-Worker-Cache; Geld nur als Dezimal-String. Keine `node_modules`/`build` committen.
