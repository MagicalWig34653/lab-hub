#!/usr/bin/env bash
# WP-H17: E2E "OCR-Job endgültig gescheitert -> sichtbarer, wiederholbarer Fehlerzustand" gegen ein ECHTES lokales Backend mit echter Datenbank
# und echtem Worker-Prozess (keine Mocks, keine neuen Dienste, kein Fenster: Playwright headless). Voraussetzungen:
#   - lokaler Postgres-Container (Standard labhub-pg-h10b, Port 15432), pdftotext/pdfinfo (poppler) auf dem Host
#   - gebautes Binary: swift build --product App --scratch-path "$LH_SCRATCH" (Standard LH_SCRATCH=$TMPDIR/labhub-build), baut hier nichts
#   - pwa/node_modules (npm ci) und Playwright-Chromium
# Aufruf: scripts/e2e-dms-ocr-failure.sh      Es entsteht eine frische Datenbank labhub_e2e_h17_<pid>, sie wird am Ende gelöscht.
set -euo pipefail
cd "$(dirname "$0")/.."

CONTAINER="${E2E_DB_CONTAINER:-labhub-pg-h10b}"
DB_PORT="${TEST_DB_PORT:-15432}"
DB_USER="${TEST_DB_USER:-labhub}"
DB_PASSWORD="${TEST_DB_PASSWORD:-devtest-pw}"   # synthetisches Entwicklungspasswort des lokalen Test-Containers
SCRATCH="${LH_SCRATCH:-${TMPDIR:-/tmp}/labhub-build}"
APP="${E2E_APP_BIN:-$SCRATCH/debug/App}"
BACKEND_PORT="${E2E_BACKEND_PORT:-8091}"
UI_PORT="${E2E_PORT:-5191}"
DB="labhub_e2e_h17_$$"
TOKEN="e2e-setup-$(date +%s)-$$"

[ -x "$APP" ] || { echo "FEHLER: Binary fehlt: $APP (swift build --product App --scratch-path \"$SCRATCH\")" >&2; exit 2; }
if ! command -v pdftotext >/dev/null || ! command -v pdfinfo >/dev/null; then echo "FEHLER: pdftotext/pdfinfo fehlen (poppler)" >&2; exit 2; fi
docker exec "$CONTAINER" psql -U "$DB_USER" -d postgres -Atc 'SELECT 1' >/dev/null || { echo "FEHLER: Datenbank-Container $CONTAINER nicht erreichbar" >&2; exit 2; }

serve_pid=""
cleanup() {
  [ -n "$serve_pid" ] && kill "$serve_pid" 2>/dev/null || true
  rm -rf "${SHIMS:-/nonexistent-shims}"
  [ -n "${E2E_KEEP_DB:-}" ] && { echo "Datenbank bleibt: $DB"; return; }
  docker exec "$CONTAINER" psql -U "$DB_USER" -d postgres -Atc "DROP DATABASE IF EXISTS $DB WITH (FORCE)" >/dev/null 2>&1 || true
}
trap cleanup EXIT

docker exec "$CONTAINER" psql -U "$DB_USER" -d postgres -Atc "CREATE DATABASE $DB" >/dev/null

export DB_HOST=127.0.0.1 DB_PORT="$DB_PORT" DB_NAME="$DB" DB_USER DB_PASSWORD DB_TLS=disable AUTO_MIGRATE=true
export SETUP_TOKEN="$TOKEN" PUBLIC_URL="http://localhost:$UI_PORT" WEBAUTHN_RP_ID=localhost
export OCR_TMPDIR="${TMPDIR:-/tmp}"

# Der Worker prüft beim Start nur per `--version`, ob ocrmypdf/tesseract/gs vorhanden sind (OCRToolEngine.preflight). Beide Szenarien dieses E2E
# rufen sie nie auf (Textschicht -> pdftotext, beschädigte Datei scheitert schon an pdfinfo). Fehlt ein Werkzeug auf dem Host, steht eine
# Preflight-Attrappe am ENDE des PATH (echte Werkzeuge haben Vorrang); jeder andere Aufruf der Attrappe scheitert laut mit Exit 99.
# Echte OCR (Scan-PDF) deckt scripts/ocr-container-test.sh bzw. pwa `npm run test:e2e:dms` mit Worker-Image ab.
SHIMS="$(mktemp -d "${TMPDIR:-/tmp}/labhub-e2e-shims.XXXXXX")"
shim() { # name, version-Ausgabe
  command -v "$1" >/dev/null 2>&1 && return 0
  # shellcheck disable=SC2016 # die Attrappe soll $1 selbst auswerten
  printf '#!/bin/sh\nif [ "$1" = "--version" ]; then echo "%s"; exit 0; fi\nif [ "$1" = "--list-langs" ]; then printf "List of available languages (2):\\ndeu\\neng\\n"; exit 0; fi\necho "%s: nur Preflight-Attrappe im E2E-Skript" >&2; exit 99\n' "$2" "$1" >"$SHIMS/$1"
  chmod +x "$SHIMS/$1"; echo "Hinweis: $1 fehlt auf dem Host, Preflight-Attrappe aktiv (wird nie fachlich genutzt)"
}
shim ocrmypdf 15.4.4; shim tesseract "tesseract 5.3.4"; shim gs 10.02.1
export PATH="$PATH:$SHIMS"

LOG="${TMPDIR:-/tmp}/labhub-e2e-h17-serve.log"
"$APP" serve --hostname 127.0.0.1 --port "$BACKEND_PORT" >"$LOG" 2>&1 &
serve_pid=$!
for _ in $(seq 1 60); do
  curl -fsS "http://127.0.0.1:$BACKEND_PORT/health" >/dev/null 2>&1 && break
  kill -0 "$serve_pid" 2>/dev/null || { echo "FEHLER: Backend beendet, Log: $LOG" >&2; tail -20 "$LOG" >&2; exit 3; }
  sleep 1
done

# Optional für die Gegenprobe: SQL nach den Migrationen (z. B. E2E_PRE_SQL='DROP TRIGGER dms_ocr_job_quarantined ON jobs' -> das E2E muss rot werden).
[ -n "${E2E_PRE_SQL:-}" ] && docker exec "$CONTAINER" psql -U "$DB_USER" -d "$DB" -Atc "$E2E_PRE_SQL"

cd pwa
E2E_PORT="$UI_PORT" E2E_BACKEND_URL="http://127.0.0.1:$BACKEND_PORT" E2E_SETUP_TOKEN="$TOKEN" E2E_DMS_FAILURE=1 \
E2E_WORKER_LOG="${TMPDIR:-/tmp}/labhub-e2e-h17-worker.log" E2E_APP_BIN="$APP" E2E_DB_CONTAINER="$CONTAINER" E2E_DB_NAME="$DB" \
  npx playwright test e2e/dms-ocr-failure.spec.ts
