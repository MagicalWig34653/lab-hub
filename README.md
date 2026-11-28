# LAB hub

Selbst hostbares Backend mit PWA für eine Familie modularer Produkte. Jedes Produkt ist ein Modul (ein-/ausschaltbar je Betreiber und Mandant); mit Backend arbeiten alle Module über einen gemeinsamen Kern (Mandanten, Nutzer, Rechte, Kontakte, Dateien, Zähler, Suche, Audit, Events). Der Hub ist vollständig ohne Swift-App nutzbar (Backend + PWA); die Swift-Apps (je Modul) sind optionale Clients und laufen weiterhin eigenständig ohne Backend.

Geplante Module: **Rechnung** (Nachfolge einer bestehenden Rechnungs-App) und **DMS** (Dokumentenmanagement, Grundidee Paperless-ngx, neu gedacht). Später Steuer, Zeit, Projekte.

## Status (01.11.2026)

- **Vorhanden (Code):** Swift/Vapor-Gerüst in `backend/` mit `migrate` (Advisory Lock), Nummernzähler, Idempotency, Jobs mit Lease, `/health`, `/ready`, Konfiguration über Env/`_FILE`; Deploy-Skripte (Compose real getestet, Swarm ungetestet).
- **Vorhanden (Planung):** Architektur, Modulentwürfe, Roadmap mit Arbeitspaketen, offene Fragen, ADRs. **Noch kein Feature-Code**, `pwa/` ist leer.
- Entscheidungen: ADR 0001–0003 und 0008 entschieden; 0004–0007 vorgeschlagen.
- Namen (Nutzer 25.11.2026): PWA „LAB hub“, Module „docs“, „invoice“ usw.; je Modul eine eigene native App, die an den Hub angebunden werden kann. Marken-, Domain- und Bundle-ID-Prüfung offen.
- Lizenz AGPL-3.0-only, öffentliches Repository. Stand zur gebündelten BoringSSL-Kopie: `docs/LIZENZEN.md`, `docs/OFFENE-FRAGEN.md` F-03 (keine Rechtsberatung).

## Dokumentenindex

| Dokument | Inhalt |
| --- | --- |
| `AGENTS.md` / `CLAUDE.md` | Arbeitsregeln für Coding-Agents: Lesereihenfolge, Build/Test, Stateless, Datenschutz, Git, Definition of Done |
| `docs/ROADMAP.md` | Phasen und Arbeitspakete (WP) mit Abhängigkeiten, Akzeptanzkriterien, Teststrategie |
| `docs/ARCHITEKTUR-ABGLEICH-TIMETRACK.md` | Struktur-Abgleich mit Timetrack/Chronolog, Umbau-WPs (Planung) |
| `docs/SCAN-BRIDGE.md` | Netzwerkscanner über SANE als eigener Dienst, F-22, Lizenzen (Planung) |
| `docs/APP-DMS.md` | Native App „docs“ (DMS-Modul) für Apple-Geräte, gemeinsame App-Grundlage, Integrationen, Meilensteine (Planung) |
| `docs/PAPERLESS-ABLOESUNG.md` | Was zur Ablösung von paperless-ngx fehlt, Reihenfolge, Probelauf |
| `docs/ANLEITUNG-ZIELRECHNER.md` | Anleitung Zielrechner für den Probelauf (Docker, Bau, Einrichtung, erste Anmeldung, Sicherung und Restore, Platzbedarf, gemessene Zeiten) |
| `docs/ANLEITUNG-PA3-PAPERLESS-PROBELAUF.md` | Anleitung für den Probelauf des Paperless-Imports (Benutzer, Netz, interne Ziele und Allowlist, Aufräumen) |
| `docs/ARCHITEKTUR.md` | Schichten, Modul-System, gemeinsamer Kern, API-Stil, Sync-Entwurf, Datenschutz, Betrieb |
| `docs/MODUL-DMS.md` | Paperless-Analyse, Problem/Lösung, Datenmodell, Ingest, OCR, Suche, Revisionssicherheit, API, Import |
| `docs/MODUL-RECHNUNG.md` | Umfang des Rechnungsmoduls, Renderer-Frage, E-Rechnung, Übernahme aus der bisherigen App |
| `docs/FRONTEND.md` | PWA-Architektur, Modul-Manifest, i18n, Offline, Tests, Verzeichnislayout |
| `docs/OFFENE-FRAGEN.md` | Entscheidungen des Nutzers mit Empfehlung |
| `docs/decisions/` | ADRs 0001–0008 |
| `docs/PLATTFORM-VISION.md` | Ursprüngliche Vision (Hintergrund; teils überholt) |
| `deploy/README.md` | Betrieb: Compose, Swarm, Setup/Update-Skripte |

## Verzeichnisse

`backend/` (Swift), `pwa/` (SvelteKit, folgt), `contracts/` (OpenAPI, folgt), `deploy/`, `docs/`.

## Entwickeln

Build-Artefakte immer außerhalb des Repos (Scratch-Pfad), siehe `AGENTS.md` Abschnitt 3.

```
export LH_SCRATCH="${TMPDIR:-/tmp}/labhub-build"
docker compose up -d db
cd backend
swift test --scratch-path "$LH_SCRATCH"
swift run --scratch-path "$LH_SCRATCH" App serve
curl http://127.0.0.1:8080/health
```

Baseline (WP-K0, 01.11.2026): `scripts/ci.sh` (shellcheck, Build, Tests) läuft grün; 11 Tests, davon 6 gegen Postgres, ohne `--build-system native`. Lizenzbefund BoringSSL offen: `docs/LIZENZEN.md`.

Nächster Schritt: Kern laut `docs/ROADMAP.md` (K1, K4, K6, D1 u. a.).
