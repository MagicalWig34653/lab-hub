#!/usr/bin/env bash
# WP-PA2: E2E der Import-Seiten der PWA gegen das ECHTE Backend, einen echten Worker und eine ECHTE, lokal gestartete paperless-ngx-Instanz (Container, nur 127.0.0.1)
# mit ERFUNDENEN Dokumenten (scripts/paperless-e2e/seed.py). Keine Verbindung zu einer echten Instanz. Eigene Wegwerf-Container (Paperless, Redis, Postgres) mit dem
# Namen labhub-pa2-e2e-<pid>, sie werden am Ende entfernt. Eine Weiterleitung (slowproxy.py) verzögert die Anfragen, damit Fortschritt und Abbruch sichtbar sind.
# Voraussetzungen: Docker, jq, python3, openssl, node mit installierten PWA-Abhängigkeiten und Chromium (npx playwright install chromium), gebautes Binary
# (swift build --product App --scratch-path "$LH_SCRATCH"). Aufruf: scripts/e2e-paperless-pwa.sh
#   E2E_SCREENSHOT_DIR=<verzeichnis>  Bilder hell/dunkel, Computer/Handy    E2E_PWA_DIR=<pwa>  anderer PWA-Stand    E2E_KEEP_LOGS=1  Logs behalten
set -euo pipefail
cd "$(dirname "$0")/.."

PAPERLESS_IMAGE="${PAPERLESS_IMAGE:-ghcr.io/paperless-ngx/paperless-ngx:3.5.1}"
REDIS_IMAGE="${REDIS_IMAGE:-redis:7-alpine}"
POSTGRES_IMAGE="${POSTGRES_IMAGE:-postgres:17}"
PA_PORT="${E2E_PAPERLESS_PORT:-18110}"
SLOW_PORT="${E2E_PROXY_PORT:-18111}"
SLOW_DELAY="${E2E_PROXY_DELAY:-0.6}"        # Sekunden je Anfrage an Paperless über die Weiterleitung
DB_PORT_HOST="${E2E_DB_PORT:-15462}"
BACKEND_PORT="${E2E_BACKEND_PORT:-8196}"
PWA_PORT="${E2E_PORT:-5196}"
SCRATCH="${LH_SCRATCH:-${TMPDIR:-/tmp}/labhub-build}"
APP="${E2E_APP_BIN:-$SCRATCH/debug/App}"
PWA_DIR="${E2E_PWA_DIR:-pwa}"
NAME="labhub-pa2-e2e-$$"
PA="http://127.0.0.1:$PA_PORT"
PA_ADMIN_USER=pa2admin
PA_ADMIN_PASS="pa2-$(openssl rand -hex 8)"
DB_PASSWORD="pa2-$(openssl rand -hex 8)"; export DB_PASSWORD   # nur für diesen Wegwerf-Container

[ -x "$APP" ] || { echo "FEHLER: Binary fehlt: $APP (swift build --product App --scratch-path \"$SCRATCH\")" >&2; exit 2; }
for tool in jq python3 docker openssl npx; do command -v "$tool" > /dev/null || { echo "FEHLER: $tool fehlt" >&2; exit 2; }; done

pids=()
workdir="$(mktemp -d "${TMPDIR:-/tmp}/labhub-e2e-pa2.XXXXXX")"
# shellcheck disable=SC2317,SC2329 # via trap
cleanup() {
  for p in ${pids[@]+"${pids[@]}"}; do kill "$p" 2> /dev/null || true; done
  docker rm -fv "$NAME-paperless" "$NAME-redis" "$NAME-db" > /dev/null 2>&1 || true
  docker network rm "$NAME-net" > /dev/null 2>&1 || true
  [ -n "${E2E_KEEP_LOGS:-}" ] && { echo "Logs bleiben: $workdir"; return; }
  rm -rf "$workdir"
}
trap cleanup EXIT

docker network create "$NAME-net" > /dev/null
docker run -d --name "$NAME-db" -p "127.0.0.1:$DB_PORT_HOST:5432" -e POSTGRES_USER=labhub -e POSTGRES_PASSWORD="$DB_PASSWORD" -e POSTGRES_DB=labhub "$POSTGRES_IMAGE" > /dev/null
docker run -d --name "$NAME-redis" --network "$NAME-net" "$REDIS_IMAGE" > /dev/null
docker run -d --name "$NAME-paperless" --network "$NAME-net" -p "127.0.0.1:$PA_PORT:8000" \
  -e "PAPERLESS_REDIS=redis://$NAME-redis:6379" -e "PAPERLESS_ADMIN_USER=$PA_ADMIN_USER" -e "PAPERLESS_ADMIN_PASSWORD=$PA_ADMIN_PASS" \
  -e "PAPERLESS_SECRET_KEY=pa2-$(openssl rand -hex 16)" -e PAPERLESS_TASK_WORKERS=1 -e PAPERLESS_THREADS_PER_WORKER=1 -e PAPERLESS_WEBSERVER_WORKERS=1 \
  -e PAPERLESS_OCR_LANGUAGE=eng -e "PAPERLESS_URL=$PA" "$PAPERLESS_IMAGE" > /dev/null
echo "Paperless startet (Image $PAPERLESS_IMAGE) ..."
for _ in $(seq 1 120); do
  if PA_USER="$PA_ADMIN_USER" PA_PASS="$PA_ADMIN_PASS" python3 -I -c "
import urllib.request, base64, os
r = urllib.request.Request('$PA/api/documents/', headers={'Authorization': 'Basic ' + base64.b64encode((os.environ['PA_USER'] + ':' + os.environ['PA_PASS']).encode()).decode()})
urllib.request.urlopen(r, timeout=5)" 2> /dev/null; then break; fi
  sleep 3
done
PA_ADMIN="$PA_ADMIN_USER" PA_PASS="$PA_ADMIN_PASS" PA_URL="$PA" python3 -I scripts/paperless-e2e/seed.py > "$workdir/seed.json" || { echo "FEHLER: Seed fehlgeschlagen" >&2; docker logs --tail 30 "$NAME-paperless" >&2; exit 3; }
ADMIN_TOKEN="$(jq -r .admin_token "$workdir/seed.json")"
echo "Paperless läuft lokal, Seed fertig ($(jq '.docs | length' "$workdir/seed.json") Dokumente)"
docker exec "$NAME-paperless" document_exporter ../export --no-progress-bar > /dev/null 2>&1 || { echo "FEHLER: document_exporter fehlgeschlagen" >&2; exit 3; }

python3 -I scripts/paperless-e2e/slowproxy.py "$SLOW_PORT" "$PA_PORT" 0 "$SLOW_DELAY" > "$workdir/slowproxy.log" 2>&1 &
pids+=($!)

for _ in $(seq 1 60); do docker exec "$NAME-db" pg_isready -h 127.0.0.1 -U labhub -d labhub > /dev/null 2>&1 && break; sleep 1; done
export DB_HOST=127.0.0.1 DB_PORT="$DB_PORT_HOST" DB_NAME=labhub DB_USER=labhub DB_TLS=disable
export PUBLIC_URL="http://localhost:$PWA_PORT" WEBAUTHN_RP_ID=localhost DMS_OCR_ENABLED=false OBJECT_STORE=db DMS_IMPORT_INSECURE_DEV=true
SECRET_KEY="$(openssl rand -base64 32)"; export SECRET_KEY
SETUP_TOKEN="$(openssl rand -hex 24)"; export SETUP_TOKEN
export DMS_IMPORT_ROOT="$workdir/import-root"
mkdir -p "$DMS_IMPORT_ROOT"
AUTO_MIGRATE=true "$APP" serve --hostname 127.0.0.1 --port "$BACKEND_PORT" > "$workdir/serve.log" 2>&1 &
pids+=($!)
for _ in $(seq 1 90); do
  python3 -I -c "import urllib.request; urllib.request.urlopen('http://127.0.0.1:$BACKEND_PORT/ready', timeout=2)" 2> /dev/null && break
  kill -0 "${pids[${#pids[@]}-1]}" 2> /dev/null || { echo "FEHLER: Backend beendet" >&2; tail -20 "$workdir/serve.log" >&2; exit 3; }
  sleep 1
done
AUTO_MIGRATE=false "$APP" worker --kinds dms.import.paperless --poll-ms 200 > "$workdir/worker.log" 2>&1 &
pids+=($!)

status=0
(cd "$PWA_DIR" && E2E_IMPORT=1 E2E_PORT="$PWA_PORT" E2E_BACKEND_URL="http://127.0.0.1:$BACKEND_PORT" E2E_SETUP_TOKEN="$SETUP_TOKEN" \
  E2E_PAPERLESS_URL="$PA" E2E_PAPERLESS_SLOW_URL="http://127.0.0.1:$SLOW_PORT" E2E_PAPERLESS_TOKEN="$ADMIN_TOKEN" \
  E2E_PAPERLESS_CONTAINER="$NAME-paperless" E2E_IMPORT_ROOT="$DMS_IMPORT_ROOT" npx playwright test e2e/dms-import.spec.ts) || status=$?

# Das Token nirgends im Klartext: Datenbank, Logs von Backend, Worker und Weiterleitung; kein Lauf behält es verschlüsselt.
# Erst den Auszug schreiben (ein Fehler von pg_dump bricht ab) und mit der Gegenprobe belegen, dass er die Läufe enthält; sonst hiesse „0 Treffer“ nichts.
docker exec "$NAME-db" pg_dump -U labhub -d labhub > "$workdir/dump.sql" || { echo "FEHL pg_dump gescheitert" >&2; exit 1; }
grep -q 'public.dms_imports' "$workdir/dump.sql" || { echo "FEHL Datenbankauszug ohne dms_imports" >&2; exit 1; }
dump_hits="$(grep -c -e "$ADMIN_TOKEN" "$workdir/dump.sql" || true)"
log_hits="$(cat "$workdir"/*.log | grep -c -e "$ADMIN_TOKEN" || true)"
echo "Token in der Datenbank: $dump_hits Treffer, in den Logs: $log_hits Treffer"
[ "$dump_hits" = 0 ] && [ "$log_hits" = 0 ] || { echo "FEHL Token im Klartext gefunden" >&2; status=1; }
if [ "$status" = 0 ]; then
  kept="$(docker exec "$NAME-db" psql -U labhub -d labhub -Atqc "SELECT count(*) FROM dms_imports WHERE secret_enc IS NOT NULL")"
  runs="$(docker exec "$NAME-db" psql -U labhub -d labhub -Atqc "SELECT count(*) FROM dms_imports")"
  echo "Läufe: $runs, mit gespeichertem Token: $kept"
  [ "$kept" = 0 ] && [ "$runs" -eq 5 ] || { echo "FEHL Läufe/Token" >&2; status=1; }
fi
if [ "$status" = 0 ]; then echo "E2E Paperless-Import (PWA): alles ok"; else echo "E2E Paperless-Import (PWA): FEHLER" >&2; fi
exit "$status"
