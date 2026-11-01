# ADR 0007: Frontend-Stack und Offline-Strategie

Status: vorgeschlagen (01.11.2026). Konkretisiert ADR 0002 (SvelteKit + shadcn-svelte als PWA).

**Kontext.** Eine PWA bedient alle Module. Vorbild `timetrack-pwa` (SvelteKit, Svelte 5 Runes, Tailwind 4, shadcn-svelte „nova“, `adapter-static`, Service Worker, Vitest, Playwright).

**Entscheidung.**
1. Stack und Aliase wie `timetrack-pwa`; statischer Build, vom Backend ausgeliefert (ein Origin).
2. Modulares Frontend: Modul-Manifest je Modul, Navigation aus `/api/v1/…/modules` (Backend-Wahrheit), Route-Präfix `/m/<modul>`, Klassifikationstest für alle Routen. Details `FRONTEND.md`.
3. i18n de/en mit typisierten Schlüsseln (Compile-Zeit-Vollständigkeit); keine Nutzertexte in Komponenten.
4. Service Worker cached nur Shell und gehashte Assets, **keine API-Antworten** in V1; Uploads offline erst später.
5. Tests: Vitest, Playwright gegen Mock-Backend und echtes Backend, Playwright-PWA-Lauf, axe-Prüfung.
6. TypeScript-Typen aus dem OpenAPI-Vertrag generiert und committet (Generator: OFFENE-FRAGEN F-17).

**Folgen.** Kein SSR. Offline-Fähigkeit begrenzt (Sicherheit vor Komfort); Erweiterung per Folge-ADR. Geld im Frontend nur als Dezimal-String. Abhängigkeitslizenzen im Build erzeugen (`generate-licenses`).
