# pwa/ – Frontend (noch ohne Code)

SvelteKit + shadcn-svelte als PWA, statisch gebaut und vom Backend ausgeliefert. Vorbild: `timetrack-pwa`. Architektur, Modul-Manifest, i18n, Offline und Tests: `../docs/FRONTEND.md`; Entscheidung: `../docs/decisions/0007-frontend-stack.md`. Anlegen im WP-F1 (`../docs/ROADMAP.md`).

Zielstruktur (Kurzfassung):

```
pwa/
  package.json  svelte.config.js  vite.config.ts  components.json  playwright*.config.ts
  static/  scripts/  mock/  e2e/  e2e-mock/
  src/
    routes/   (public)/ login, invite, recover   (app)/ Shell, dashboard, settings, admin, m/<modul>/…
    lib/      api/ modules/ ui/ i18n/ pwa/ theme/ a11y/ modules-impl/{dms,invoice}/
    service-worker.ts
```

Regeln: Nutzertexte nur über i18n (de/en); jede Route ist Kern oder genau einem Modul zugeordnet (Test); keine API-Antworten im Service-Worker-Cache; Geld nur als Dezimal-String. Keine `node_modules`/`build` committen.
