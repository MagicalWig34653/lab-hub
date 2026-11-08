# Übergabe WP-H9: PWA-Auslieferung und Deployment-Gesamtlauf

Stand 08.11.2026, Branch `wp-H9`.

## Umgesetzt
- `Dockerfile`: Stufe `pwa` (node:24-bookworm-slim, `npm ci`, `npm run build`), Ausgabe nach `/usr/share/lab-hub/pwa` (`PWA_DIR`), read-only Root bleibt. `.dockerignore` ergänzt.
- `backend/Sources/HubKit/Middleware/PWAStaticMiddleware.swift` (`PWAConfig`: `PWA_DIR`, `PWA_ENABLED`, `PWA_HSTS_MAX_AGE`), in `configure()` nach den Routen eingehängt. Deep-Link-Fallback nur für GET/HEAD ohne Dateiendung und nie unter `/api`, `/health`, `/ready`; Cache-Header (immutable / no-cache, ETag für index.html); CSP mit Hash des Start-Inline-Skripts (kein Nonce, kein unsafe-eval), nosniff, Referrer-Policy, Permissions-Policy, HSTS optional. Traversal (`..`, `%2e%2e`, doppelt kodiert, `\`, Symlinks, versteckte Dateien) abgewiesen.
- `ObjectStoreConfig.validate()` wird in `configure()` aufgerufen (Fehler brechen den Start ab, Warnungen ins Log).
- `scripts/check-env-docs.sh` (in `scripts/ci.sh`), `.env.example` und `deploy/README.md` ergänzt, Compose-/Swarm-Dateien reichen `SETUP_TOKEN`, `PWA_*`, `OBJECT_STORE`, `HUB_REPLICAS`, `DMS_MAX_UPLOAD_BYTES`, `DMS_DEFAULT_RETENTION_YEARS` an das Backend.
- PWA-Tests nur Konfiguration: `pwa/playwright.stack.config.ts`, `npm run test:e2e:stack`, `npm run test:e2e:stack-restart`, `e2e/stack-restart.spec.ts`.
- Tests: `PWAStaticTests` (9 Tests).

## Tests
- `TEST_DB_NAME=labhub_h9 scripts/ci.sh`: grün, 352 Tests, 14 übersprungen, 0 Fehler (vor Rebase).
- Gesamtlauf (real, Docker/colima): Images lokal gebaut (Backend mit PWA 426 MB, Worker 809 MB), `deploy/setup.sh --non-interactive` (Betriebsart 3, Projekt `labhubh9`, Port 18109/18110), db + migrate + backend + worker mit allen sechs Job-Arten, `/ready` 200, `/` und `/dms/inbox` liefern index.html mit CSP, `/api/v1/nope` 404 problem+json.
  - Browser-E2E `test:e2e:stack` (Bootstrap, Einladung, Passkey, Scan-Upload, OCR, Treffer, Vorschau, Regeln, Quellen, Token/curl, Papierkorb): grün, einmal direkt gegen das Backend (22 s), einmal über nginx mit **zwei Backend-Repliken** (20 s, Lastverteilung abwechselnd belegt).
  - Neustart beider Backend-Container während einer Sitzung (`test:e2e:stack-restart`): Sitzung bleibt gültig, grün.
- Swarm: nur `docker compose config` (Syntax, nur Swarm-Warnungen); weiterhin ungetestet.

## Aufgeräumt
Stack `labhubh9` mit Volumes (`down -v`), Replik- und Proxy-Container, Images `lab-hub-h9:test(-worker)`, `deploy/.env`, `deploy/compose/secrets/`, Test-DB `labhub_h9`. Heruntergeladene Basisimages (swift, node, ubuntu, nginx) und Build-Cache bleiben lokal. `deploy/compose/secrets/` steht jetzt in `.gitignore`.

## Offen
- Zweite Replik im Test war ein manuell gestarteter Container (kein Compose-Dienst); `docker compose --scale` geht wegen des festen Host-Ports nicht. Kein Proxy-Dienst im Repo.
- Getrennte Migrationsrolle in `setup.sh`/Compose nicht umgesetzt (dokumentiert).
- Swarm real ungetestet. HSTS/Proxy-Header hinter echtem TLS-Proxy nicht geprüft.
- Service-Worker-Verhalten im Stack nicht separat geprüft (CSP erlaubt `worker-src 'self'`).
