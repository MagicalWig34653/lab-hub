# LAB hub (Arbeitsname)

Selbst hostbares Backend mit PWA für eine Familie modularer Produkte (Rechnungen, DMS, später Steuer, Zeit, Projekte …). Jedes Produkt ist ein Modul, das sich aktivieren und deaktivieren lässt; mit Backend arbeiten alle Module über einen gemeinsamen Kern zusammen. Die zugehörigen Swift-Apps laufen auch eigenständig ohne Backend.

Status: **Gerüst.** Entscheidungen und Zielbild: `docs/PLATTFORM-VISION.md` (Kopie aus dem Repo `taxlab`, dort fortgeschrieben), `docs/decisions/`.

- Backend: Swift 6, Vapor, Fluent, PostgreSQL (`backend/`)
- Frontend: SvelteKit + shadcn-svelte als PWA (`pwa/`, noch leer)
- Betrieb: Docker Compose, später Swarm; ein Stack je Kunde (`deploy/`)
- Lizenz: AGPL-3.0-only, Open Source. Einnahmen über Betreuung und Dienstleistungen.
- Name, Bundle-IDs und Domains sind vorläufig und werden später geändert.

## Entwickeln

```
docker compose up -d db
cd backend && swift run App serve
curl http://127.0.0.1:8080/health
```
