#!/usr/bin/env bash
# WP-BR1: E2E der Hub-Seite der Scan-Bridge gegen ECHTE Prozesse: zwei Hub-Instanzen (zwei `App serve`) auf derselben echten Postgres-Datenbank, Aufrufe über HTTP mit curl
# (Bridge mit API-Token, Nutzer mit Sitzung), echte Lease-Zeit aus der Datenbank. Keine Mocks, kein Worker, kein Browser (die PWA-Oberfläche folgt mit WP-BR3, die
# echte Bridge mit WP-BR2). Voraussetzungen:
#   - lokaler Postgres-Container (Standard labhub-pg-h10b, Port 15432; E2E_DB_CONTAINER, TEST_DB_PORT, TEST_DB_USER, TEST_DB_PASSWORD), curl, jq
#   - gebautes Binary: swift build --product App --scratch-path "$LH_SCRATCH" (Standard LH_SCRATCH=$TMPDIR/labhub-build), baut hier nichts
# Aufruf: scripts/e2e-scan-bridge.sh      Es entsteht eine frische Datenbank labhub_e2e_br1_<pid>, sie wird am Ende gelöscht. Nur synthetische Daten.
set -euo pipefail
cd "$(dirname "$0")/.."

CONTAINER="${E2E_DB_CONTAINER:-labhub-pg-h10b}"
DB_PORT="${TEST_DB_PORT:-15432}"
DB_USER="${TEST_DB_USER:-labhub}"
DB_PASSWORD="${TEST_DB_PASSWORD:-devtest-pw}"   # synthetisches Entwicklungspasswort des lokalen Test-Containers
SCRATCH="${LH_SCRATCH:-${TMPDIR:-/tmp}/labhub-build}"
APP="${E2E_APP_BIN:-$SCRATCH/debug/App}"
PORT_A="${E2E_BACKEND_PORT:-8094}"
PORT_B="${E2E_BACKEND_PORT_B:-8095}"
DB="labhub_e2e_br1_$$"
SESSION="$(openssl rand -base64 32 | tr '+/' '-_' | tr -d '=\n')"   # 43 Zeichen wie ein echtes Sitzungstoken, nur für diese Datenbank

[ -x "$APP" ] || { echo "FEHLER: Binary fehlt: $APP (swift build --product App --scratch-path \"$SCRATCH\")" >&2; exit 2; }
command -v jq > /dev/null || { echo "FEHLER: jq fehlt" >&2; exit 2; }
psql_db() { docker exec -i "$CONTAINER" psql -U "$DB_USER" -d "$1" -Atq -v ON_ERROR_STOP=1; }
echo 'SELECT 1' | psql_db postgres > /dev/null || { echo "FEHLER: Datenbank-Container $CONTAINER nicht erreichbar" >&2; exit 2; }

pids=()
workdir="$(mktemp -d "${TMPDIR:-/tmp}/labhub-e2e-br1.XXXXXX")"
cleanup() {
  for p in "${pids[@]}"; do kill "$p" 2> /dev/null || true; done
  rm -rf "$workdir"
  echo "DROP DATABASE IF EXISTS $DB WITH (FORCE)" | psql_db postgres > /dev/null 2>&1 || true
}
trap cleanup EXIT
echo "CREATE DATABASE $DB" | psql_db postgres > /dev/null

export DB_HOST=127.0.0.1 DB_PORT="$DB_PORT" DB_NAME="$DB" DB_USER DB_PASSWORD DB_TLS=disable
export PUBLIC_URL="http://localhost:$PORT_A" WEBAUTHN_RP_ID=localhost DMS_OCR_ENABLED=false
start() { # Port, AUTO_MIGRATE
  AUTO_MIGRATE="$2" "$APP" serve --hostname 127.0.0.1 --port "$1" > "$workdir/serve-$1.log" 2>&1 &
  pids+=($!)
  for _ in $(seq 1 90); do
    curl -fsS "http://127.0.0.1:$1/ready" > /dev/null 2>&1 && return 0
    kill -0 "${pids[-1]}" 2> /dev/null || { echo "FEHLER: Backend beendet, Log: $workdir/serve-$1.log" >&2; tail -20 "$workdir/serve-$1.log" >&2; exit 3; }
    sleep 1
  done
  echo "FEHLER: Backend nicht bereit (Port $1)" >&2; exit 3
}
start "$PORT_A" true
start "$PORT_B" false

A="http://127.0.0.1:$PORT_A/api/v1"
B="http://127.0.0.1:$PORT_B/api/v1"
fail=0
# request <Basis> <Token> <Methode> <Pfad> [Body]: setzt $status und $body
request() {
  local base="$1" token="$2" method="$3" path="$4" data="${5:-}" args=()
  [ -n "$data" ] && args=(-H 'Content-Type: application/json' --data "$data")
  status="$(curl -sS -o "$workdir/body" -w '%{http_code}' -X "$method" "$base$path" -H "Authorization: Bearer $token" "${args[@]}")"
  body="$(cat "$workdir/body")"
}
expect() { # Beschreibung Soll-Status
  if [ "$status" = "$2" ]; then echo "ok   $1 ($status)"; else echo "FEHL $1: Status $status, erwartet $2: $body" >&2; fail=1; fi
}
expect_json() { # Beschreibung jq-Ausdruck Soll
  local got; got="$(printf '%s' "$body" | jq -r "$2")"
  if [ "$got" = "$3" ]; then echo "ok   $1 ($2 = $3)"; else echo "FEHL $1: $2 = '$got', erwartet '$3': $body" >&2; fail=1; fi
}

# Nutzer, Mandant, Sitzung (nur Testdaten; Anmeldung per Passkey deckt auth.spec.ts ab)
lc() { tr '[:upper:]' '[:lower:]'; }
USER_ID="$(uuidgen | lc)"; TENANT="$(uuidgen | lc)"
SESSION_HASH="$(printf '%s' "$SESSION" | shasum -a 256 | cut -d' ' -f1)"
psql_db "$DB" << SQL
INSERT INTO users (id, handle, display_name) VALUES ('$USER_ID', 'e2e', 'E2E Synthetic');
INSERT INTO tenants (id, name) VALUES ('$TENANT', 'E2E Mandant');
INSERT INTO memberships (tenant_id, user_id, role) VALUES ('$TENANT', '$USER_ID', 'owner');
INSERT INTO sessions (user_id, token_hash, kind, expires_at) VALUES ('$USER_ID', '$SESSION_HASH', 'normal', now() + interval '1 day');
SQL
SCAN="/tenants/$TENANT/dms/scan"

request "$A" "$SESSION" PUT "/tenants/$TENANT/modules/dms" '{"enabled":true}'; expect "DMS einschalten" 200
request "$A" "$SESSION" POST /auth/api-tokens "{\"name\":\"E2E Bridge\",\"scopes\":[\"dms.scan.bridge\",\"dms.upload\"],\"tenant_id\":\"$TENANT\"}"; expect "Bridge-Token anlegen" 201
BRIDGE="$(printf '%s' "$body" | jq -r .token)"

# 1. Registrierung über Instanz B, Geräteliste über Instanz A sichtbar
KEY="$(printf 'e2e-device-1' | shasum -a 256 | cut -d' ' -f1)"
DEVICE="{\"key\":\"$KEY\",\"name\":\"E2E-Scanner\",\"capabilities\":{\"sources\":[\"flatbed\",\"adf\"],\"resolutions\":[150,300],\"color_modes\":[\"color\",\"gray\"],\"formats\":[\"a4\"]}}"
request "$B" "$BRIDGE" PUT "$SCAN/bridge" "{\"name\":\"E2E Bridge\",\"version\":\"0.0.1\",\"devices\":[$DEVICE]}"; expect "Bridge registrieren (Instanz B)" 200
request "$A" "$SESSION" GET "$SCAN/devices"; expect "Geräte (Instanz A)" 200
expect_json "genau ein Gerät" '.items | length' 1
expect_json "Gerät online" '.items[0].online' true
DEV_ID="$(printf '%s' "$body" | jq -r '.items[0].id')"
request "$A" "$BRIDGE" GET "$SCAN/devices"; expect "Bridge-Token ist keine Sitzung" 401

# 2. Auftrag anlegen (A), übernehmen genau einmal (B und A)
request "$A" "$SESSION" POST "$SCAN/jobs" "{\"device_id\":\"$DEV_ID\",\"source\":\"adf\",\"resolution\":300,\"color\":\"gray\"}"; expect "Auftrag anlegen" 201
JOB="$(printf '%s' "$body" | jq -r .id)"
request "$A" "$SESSION" POST "$SCAN/jobs" "{\"device_id\":\"$DEV_ID\"}"; expect "zweiter Auftrag für dasselbe Gerät" 409
expect_json "Fehlercode" .code scan_device_busy
request "$B" "$BRIDGE" POST "$SCAN/bridge/claim"; expect "übernehmen (Instanz B)" 200
expect_json "Gerätekennung der Bridge" .device_key "$KEY"
expect_json "Parameter" .params.source adf
request "$A" "$BRIDGE" POST "$SCAN/bridge/claim"; expect "zweites Übernehmen (Instanz A)" 204

# 3. Seiten und Befehle
request "$B" "$BRIDGE" PUT "$SCAN/bridge/jobs/$JOB" '{"state":"scanning","pages":0}'; expect "scanning" 200
request "$B" "$BRIDGE" PUT "$SCAN/bridge/jobs/$JOB" '{"state":"waiting_for_page","pages":1}'; expect "waiting_for_page" 200
request "$A" "$SESSION" POST "$SCAN/jobs/$JOB/next-page"; expect "nächste Seite (Nutzer)" 200
request "$B" "$BRIDGE" PUT "$SCAN/bridge/jobs/$JOB" '{}'; expect "Lebenszeichen" 200
expect_json "Befehl bei der Bridge" '.commands[0]' next_page
request "$B" "$BRIDGE" PUT "$SCAN/bridge/jobs/$JOB" '{"state":"scanning","pages":1}'; expect "scanning (nächste Seite)" 200
request "$B" "$BRIDGE" PUT "$SCAN/bridge/jobs/$JOB" '{"state":"uploading","pages":2}'; expect "uploading" 200

# 4. Ergebnis: Scan-API mit Idempotency-Key scan-<job>, zweimal über beide Instanzen genau ein Dokument
printf '%%PDF-1.4\n%% synthetic e2e scan\n1 0 obj\n<< /Type /Catalog >>\nendobj\ntrailer\n<< /Root 1 0 R >>\n%%%%EOF\n' > "$workdir/scan.pdf"
upload() { # Basis
  status="$(curl -sS -o "$workdir/body" -w '%{http_code}' -X POST "$1/tenants/$TENANT/dms/share?filename=Scan.pdf&title=E2E%20Scan" -H "Authorization: Bearer $BRIDGE" \
    -H 'Content-Type: application/octet-stream' -H "Idempotency-Key: scan-$JOB" --data-binary "@$workdir/scan.pdf")"
  body="$(cat "$workdir/body")"
}
upload "$B"; expect "Ergebnis hochladen (Instanz B)" 201
DOC="$(printf '%s' "$body" | jq -r .id)"
upload "$A"; expect "Wiederholung (Instanz A)" 201
expect_json "dasselbe Dokument" .id "$DOC"
request "$B" "$BRIDGE" PUT "$SCAN/bridge/jobs/$JOB" "{\"state\":\"done\",\"document_id\":\"$DOC\",\"pages\":2}"; expect "done mit Dokument" 200
request "$A" "$SESSION" GET "$SCAN/jobs/$JOB"; expect "Auftrag lesen" 200
expect_json "Zustand done" .state "done"
expect_json "Seiten" .pages 2
expect_json "Dokument am Auftrag" '.document_id | ascii_downcase' "$(printf '%s' "$DOC" | lc)"
request "$B" "$SESSION" GET "/tenants/$TENANT/dms/documents/$DOC"; expect "Dokument über Instanz B lesbar" 200
expect_json "Titel" .title "E2E Scan"
docs="$(echo "SELECT count(*) FROM dms_documents" | psql_db "$DB")"
if [ "$docs" = 1 ]; then echo "ok   genau ein Dokument in der Datenbank"; else echo "FEHL Dokumente: $docs" >&2; fail=1; fi

# 5. Lease-Ablauf mit der Zeit der Datenbank: kein Wiederholen, spätes Ergebnis möglich
request "$A" "$SESSION" POST "$SCAN/jobs" "{\"device_id\":\"$DEV_ID\"}"; expect "zweiter Auftrag" 201
JOB2="$(printf '%s' "$body" | jq -r .id)"
request "$B" "$BRIDGE" POST "$SCAN/bridge/claim"; expect "übernehmen" 200
echo "UPDATE dms_scan_jobs SET lease_until = now() - interval '1 second' WHERE id = '$JOB2'" | psql_db "$DB" > /dev/null
request "$A" "$BRIDGE" POST "$SCAN/bridge/claim"; expect "nach Lease-Ablauf: kein Auftrag, keine Wiederholung" 204
request "$A" "$SESSION" GET "$SCAN/jobs/$JOB2"; expect "Auftrag lesen" 200
expect_json "Zustand failed" .state failed
expect_json "Fehlercode bridge_lost" .error_code bridge_lost
request "$B" "$BRIDGE" PUT "$SCAN/bridge/jobs/$JOB2" '{"state":"scanning"}'; expect "verlorene Bridge kann nicht weiterscannen" 409

# 6. Abbrechen, Mandantentrennung und Rechte
request "$A" "$SESSION" POST "$SCAN/jobs" "{\"device_id\":\"$DEV_ID\"}"; expect "dritter Auftrag" 201
JOB3="$(printf '%s' "$body" | jq -r .id)"
request "$B" "$SESSION" POST "$SCAN/jobs/$JOB3/cancel"; expect "nicht abgeholt: abbrechen" 200
expect_json "Zustand cancelled" .state cancelled
OTHER="$(uuidgen | lc)"
request "$A" "$SESSION" GET "/tenants/$OTHER/dms/scan/devices"; expect "fremder Mandant: 404" 404
request "$A" "$BRIDGE" PUT "/tenants/$OTHER/dms/scan/bridge" "{\"name\":\"x\",\"version\":\"1\",\"devices\":[]}"; expect "Bridge-Token im fremden Mandanten: 404" 404
request "$A" "$BRIDGE" PUT "$SCAN/bridge" '{"name":"x","version":"1","devices":[{"key":"http://192.168.1.5/escl","name":"x","capabilities":{}}]}'; expect "URL als Gerätekennung: 422" 422

if [ "$fail" = 0 ]; then echo "E2E Scan-Bridge (Hub-Seite): alle Prüfungen bestanden"; else echo "E2E Scan-Bridge (Hub-Seite): FEHLER" >&2; exit 1; fi
