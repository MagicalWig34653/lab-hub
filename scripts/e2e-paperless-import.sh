#!/usr/bin/env bash
# WP-PA1: E2E des Paperless-Imports gegen eine ECHTE, lokal gestartete paperless-ngx-Instanz (Container, nur 127.0.0.1) mit ERFUNDENEN Dokumenten.
# Keine Mocks: echte Instanz (Version festgehalten, siehe PAPERLESS_IMAGE), echte Datenbank, zwei Hub-Instanzen (`App serve`) und zwei Worker-Prozesse (`App worker`),
# Aufrufe über HTTP. Geprüft werden Import aus Export-Verzeichnis (`document_exporter` der Instanz) UND über die REST-API: Anzahlen und Hashes gegen die Instanz selbst,
# Benutzer mit nur Leserechten und ohne Rechte, feste API-Version, Token nach dem Lauf gelöscht, SSRF-Sperren, kein Token in Datenbank oder Logs.
# Keine Verbindung zu einer echten Paperless-Instanz, keine echten Dokumente: alles entsteht in `scripts/paperless-e2e/seed.py`. Voraussetzungen:
#   - Docker (zwei Container + ein Netz, alles mit Namen labhub-pa1-e2e-<pid>, wird am Ende entfernt), jq, python3, ca. 1,5 GiB freier Speicher für Paperless
#   - lokaler Postgres-Container (Standard labhub-pg-h10b, Port 15432; E2E_DB_CONTAINER, TEST_DB_PORT, TEST_DB_USER, TEST_DB_PASSWORD)
#   - gebautes Binary: swift build --product App --scratch-path "$LH_SCRATCH" (Standard LH_SCRATCH=$TMPDIR/labhub-build), baut hier nichts
# Aufruf: scripts/e2e-paperless-import.sh      Es entsteht eine frische Datenbank labhub_e2e_pa1_<pid>, sie wird am Ende gelöscht.
# shellcheck disable=SC2154 # T_export, T_admin, T_reader, T_negative entstehen weiter unten per printf -v
set -euo pipefail
cd "$(dirname "$0")/.."

PAPERLESS_IMAGE="${PAPERLESS_IMAGE:-ghcr.io/paperless-ngx/paperless-ngx:3.5.1}"   # geprüfte Version (API-Version 10)
REDIS_IMAGE="${REDIS_IMAGE:-redis:7-alpine}"
PA_PORT="${E2E_PAPERLESS_PORT:-18100}"
CONTAINER="${E2E_DB_CONTAINER:-labhub-pg-h10b}"
DB_PORT="${TEST_DB_PORT:-15432}"
DB_USER="${TEST_DB_USER:-labhub}"
DB_PASSWORD="${TEST_DB_PASSWORD:-devtest-pw}"   # synthetisches Entwicklungspasswort des lokalen Test-Containers
SCRATCH="${LH_SCRATCH:-${TMPDIR:-/tmp}/labhub-build}"
APP="${E2E_APP_BIN:-$SCRATCH/debug/App}"
PORT_A="${E2E_BACKEND_PORT:-8096}"
PORT_B="${E2E_BACKEND_PORT_B:-8097}"
PORT_C="${E2E_BACKEND_PORT_C:-8098}"
PORT_D="${E2E_BACKEND_PORT_D:-8099}"             # Abschnitt 8: Betriebsrichtlinie mit Schalter und Allowlist
PROXY_PORT="${E2E_PROXY_PORT:-18101}"           # Abschnitt 6b: gebremste Leitung zu Paperless
DB="labhub_e2e_pa1_$$"
NAME="labhub-pa1-e2e-$$"
PA="http://127.0.0.1:$PA_PORT"
SESSION="$(openssl rand -base64 32 | tr '+/' '-_' | tr -d '=\n')"   # nur für diese Datenbank
PA_ADMIN_USER=pa1admin
PA_ADMIN_PASS="pa1-$(openssl rand -hex 8)"                          # nur für diesen Wegwerf-Container

[ -x "$APP" ] || { echo "FEHLER: Binary fehlt: $APP (swift build --product App --scratch-path \"$SCRATCH\")" >&2; exit 2; }
for tool in jq python3 docker openssl; do command -v "$tool" > /dev/null || { echo "FEHLER: $tool fehlt" >&2; exit 2; }; done
psql_db() { docker exec -i "$CONTAINER" psql -U "$DB_USER" -d "$1" -Atq -v ON_ERROR_STOP=1; }
echo 'SELECT 1' | psql_db postgres > /dev/null || { echo "FEHLER: Datenbank-Container $CONTAINER nicht erreichbar" >&2; exit 2; }

pids=()
dev_workers=()
workdir="$(mktemp -d "${TMPDIR:-/tmp}/labhub-e2e-pa1.XXXXXX")"
cleanup() {
  for p in "${pids[@]}"; do kill "$p" 2> /dev/null || true; done
  docker rm -fv "$NAME-paperless" "$NAME-redis" > /dev/null 2>&1 || true
  docker network rm "$NAME-net" > /dev/null 2>&1 || true
  echo "DROP DATABASE IF EXISTS $DB WITH (FORCE)" | psql_db postgres > /dev/null 2>&1 || true
  [ -n "${E2E_KEEP_LOGS:-}" ] && { echo "Logs bleiben: $workdir"; return; }
  rm -rf "$workdir"
}
trap cleanup EXIT
fail=0
ok() { echo "ok   $1"; }
bad() { echo "FEHL $1" >&2; fail=1; }
check() { # Beschreibung Ist Soll
  if [ "$2" = "$3" ]; then ok "$1 ($2)"; else bad "$1: ist '$2', erwartet '$3'"; fi
}

# 1. Paperless starten (Version festgehalten) und mit erfundenen Daten befüllen
docker network create "$NAME-net" > /dev/null
docker run -d --name "$NAME-redis" --network "$NAME-net" "$REDIS_IMAGE" > /dev/null
docker run -d --name "$NAME-paperless" --network "$NAME-net" -p "127.0.0.1:$PA_PORT:8000" \
  -e "PAPERLESS_REDIS=redis://$NAME-redis:6379" -e "PAPERLESS_ADMIN_USER=$PA_ADMIN_USER" -e "PAPERLESS_ADMIN_PASSWORD=$PA_ADMIN_PASS" \
  -e "PAPERLESS_SECRET_KEY=pa1-$(openssl rand -hex 16)" -e PAPERLESS_TASK_WORKERS=1 -e PAPERLESS_THREADS_PER_WORKER=1 -e PAPERLESS_WEBSERVER_WORKERS=1 \
  -e PAPERLESS_OCR_LANGUAGE=eng -e "PAPERLESS_URL=$PA" "$PAPERLESS_IMAGE" > /dev/null
echo "Paperless startet (Image $PAPERLESS_IMAGE) ..."
for _ in $(seq 1 120); do
  if python3 -I -c "
import urllib.request, base64, sys
r = urllib.request.Request('$PA/api/documents/', headers={'Authorization': 'Basic ' + base64.b64encode(b'$PA_ADMIN_USER:$PA_ADMIN_PASS').decode()})
urllib.request.urlopen(r, timeout=5)" 2> /dev/null; then break; fi
  sleep 3
done
PA_ADMIN="$PA_ADMIN_USER" PA_PASS="$PA_ADMIN_PASS" PA_URL="$PA" python3 -I scripts/paperless-e2e/seed.py > "$workdir/seed.json" || { echo "FEHLER: Seed fehlgeschlagen" >&2; docker logs --tail 30 "$NAME-paperless" >&2; exit 3; }
ADMIN_TOKEN="$(jq -r .admin_token "$workdir/seed.json")"; READER_TOKEN="$(jq -r .reader_token "$workdir/seed.json")"; NOPERM_TOKEN="$(jq -r .noperm_token "$workdir/seed.json")"
PA_VERSION="$(python3 -I -c "
import urllib.request
r = urllib.request.Request('$PA/api/documents/', headers={'Authorization': 'Token $ADMIN_TOKEN', 'Accept': 'application/json; version=10'})
print(urllib.request.urlopen(r).headers.get('X-Version'))")"
echo "Paperless-ngx $PA_VERSION läuft lokal, Seed fertig ($(jq '.docs | length' "$workdir/seed.json") Dokumente)"

pl() { # Token Pfad: GET gegen Paperless, feste API-Version
  python3 -I -c "
import sys, urllib.request
r = urllib.request.Request('$PA' + sys.argv[2], headers={'Authorization': 'Token ' + sys.argv[1], 'Accept': 'application/json; version=10'})
sys.stdout.write(urllib.request.urlopen(r, timeout=60).read().decode())" "$1" "$2"
}
pl_status() { # Token Pfad Accept: nur der Statuscode
  python3 -I -c "
import sys, urllib.request, urllib.error
r = urllib.request.Request('$PA' + sys.argv[2], headers={'Authorization': 'Token ' + sys.argv[1], 'Accept': sys.argv[3]})
try: print(urllib.request.urlopen(r, timeout=60).status)
except urllib.error.HTTPError as e: print(e.code)" "$1" "$2" "$3"
}

# Wahrheit aus der Instanz selbst: je sichtbarem Dokument ID, Titel, SHA-256 des Originals (neueste Fassung) und des Archivs
truth() { # Token Datei
  local token="$1" out="$2"
  : > "$out"
  for id in $(pl "$token" '/api/documents/?page_size=100&ordering=id' | jq -r '.results[].id'); do
    meta="$(pl "$token" "/api/documents/$id/metadata/")"
    doc="$(pl "$token" "/api/documents/$id/")"
    printf '%s\t%s\t%s\t%s\n' "$id" "$(printf '%s' "$meta" | jq -r .original_checksum)" "$(printf '%s' "$meta" | jq -r '.archive_checksum // "-"')" \
      "$(printf '%s' "$doc" | jq -r '.title')" >> "$out"
  done
}
truth "$ADMIN_TOKEN" "$workdir/truth-admin.tsv"; truth "$READER_TOKEN" "$workdir/truth-reader.tsv"
N_ADMIN="$(wc -l < "$workdir/truth-admin.tsv" | tr -d ' ')"; N_READER="$(wc -l < "$workdir/truth-reader.tsv" | tr -d ' ')"
N_ARCHIVES="$(awk -F'\t' '$3 != "-"' "$workdir/truth-admin.tsv" | wc -l | tr -d ' ')"
N_NOTES="$(pl "$ADMIN_TOKEN" '/api/documents/?page_size=100' | jq '[.results[].notes | length] | add')"
check "Instanz: Dokumente des Administrators" "$N_ADMIN" 10
check "Instanz: Dokumente des Lese-Benutzers (nur Sichtbares)" "$N_READER" 8
VERSIONS="$(pl "$ADMIN_TOKEN" '/api/documents/?page_size=100' | jq '[.results[] | select((.versions | length) > 1)] | length')"
check "Instanz: Dokumente mit mehreren Fassungen" "$VERSIONS" 1

# Export mit dem Werkzeug der Instanz (Verzeichnis liegt unter <Wurzel>/<mandant>/paperless-export)
docker exec "$NAME-paperless" document_exporter ../export --no-progress-bar > /dev/null 2>&1 || { echo "FEHLER: document_exporter fehlgeschlagen" >&2; exit 3; }

# 2. Hub: Datenbank, zwei Instanzen, zwei Worker
echo "CREATE DATABASE $DB" | psql_db postgres > /dev/null
export DB_HOST=127.0.0.1 DB_PORT="$DB_PORT" DB_NAME="$DB" DB_USER DB_PASSWORD DB_TLS=disable
export PUBLIC_URL="http://localhost:$PORT_A" WEBAUTHN_RP_ID=localhost DMS_OCR_ENABLED=false OBJECT_STORE=db
SECRET_KEY="$(openssl rand -base64 32)"; export SECRET_KEY
export DMS_IMPORT_ROOT="$workdir/import-root"
mkdir -p "$DMS_IMPORT_ROOT"
start() { # Port AUTO_MIGRATE [weitere Umgebung]
  local port="$1" migrate="$2"; shift 2
  env AUTO_MIGRATE="$migrate" DMS_IMPORT_INSECURE_DEV=true "$@" "$APP" serve --hostname 127.0.0.1 --port "$port" > "$workdir/serve-$port.log" 2>&1 &
  pids+=($!)
  for _ in $(seq 1 90); do
    python3 -I -c "import urllib.request; urllib.request.urlopen('http://127.0.0.1:$port/ready', timeout=2)" 2> /dev/null && return 0
    kill -0 "${pids[-1]}" 2> /dev/null || { echo "FEHLER: Backend beendet, Log: $workdir/serve-$port.log" >&2; tail -20 "$workdir/serve-$port.log" >&2; exit 3; }
    sleep 1
  done
  echo "FEHLER: Backend nicht bereit (Port $port)" >&2; exit 3
}
start "$PORT_A" true
start "$PORT_B" false
start "$PORT_C" false DMS_IMPORT_INSECURE_DEV=false          # ohne Entwicklungsschalter: Richtlinie wie im Betrieb
for n in 1 2; do
  DMS_IMPORT_INSECURE_DEV=true AUTO_MIGRATE=false "$APP" worker --kinds dms.import.paperless --poll-ms 200 > "$workdir/worker-$n.log" 2>&1 &
  pids+=($!); dev_workers+=($!)
done

A="http://127.0.0.1:$PORT_A/api/v1"
B="http://127.0.0.1:$PORT_B/api/v1"
C="http://127.0.0.1:$PORT_C/api/v1"
# request <Basis> <Methode> <Pfad> [Body-Datei]: setzt $status und $body (Sitzung des Nutzers)
request() {
  local base="$1" method="$2" path="$3" file="${4:-}"
  status="$(python3 -I - "$base$path" "$method" "$file" << 'PY'
import os, sys, urllib.request, urllib.error
url, method, file = sys.argv[1], sys.argv[2], sys.argv[3]
data = open(file, 'rb').read() if file else None
req = urllib.request.Request(url, data=data, method=method, headers={'Authorization': 'Bearer ' + os.environ['E2E_SESSION'], **({'Content-Type': 'application/json'} if data else {})})
try:
    r = urllib.request.urlopen(req, timeout=60); code, body = r.status, r.read()
except urllib.error.HTTPError as e:
    code, body = e.code, e.read()
open(os.environ['E2E_BODY'], 'wb').write(body); print(code)
PY
)"
  body="$(cat "$workdir/body")"
}
export E2E_SESSION="$SESSION" E2E_BODY="$workdir/body"

lc() { tr '[:upper:]' '[:lower:]'; }
USER_ID="$(uuidgen | lc)"; SESSION_HASH="$(printf '%s' "$SESSION" | shasum -a 256 | cut -d' ' -f1)"
psql_db "$DB" << SQL
INSERT INTO users (id, handle, display_name) VALUES ('$USER_ID', 'e2e', 'E2E Synthetic');
INSERT INTO sessions (user_id, token_hash, kind, expires_at) VALUES ('$USER_ID', '$SESSION_HASH', 'normal', now() + interval '1 day');
SQL
for t in export admin reader negative large; do
  printf -v "T_$t" %s "$(uuidgen | lc)"; tid="$(eval echo "\$T_$t")"
  psql_db "$DB" << SQL
INSERT INTO tenants (id, name) VALUES ('$tid', 'E2E $t');
INSERT INTO memberships (tenant_id, user_id, role) VALUES ('$tid', '$USER_ID', 'owner');
SQL
  request "$A" PUT "/tenants/$tid/modules/dms" <(printf '{"enabled":true}'); check "DMS einschalten ($t)" "$status" 200
done
mkdir -p "$DMS_IMPORT_ROOT/$T_export"
docker cp "$NAME-paperless:/usr/src/paperless/export" "$DMS_IMPORT_ROOT/$T_export/paperless-export" > /dev/null

body_file() { printf '%s' "$1" > "$workdir/req.json"; echo "$workdir/req.json"; }
# run <Mandant> <Modus> <Quelle-JSON>: legt den Lauf an (Instanz A), wartet über Instanz B auf das Ende; setzt $RUN und $REPORT (Datei)
run() {
  local tenant="$1" mode="$2" source="$3" state=""
  request "$A" POST "/tenants/$tenant/dms/imports" "$(body_file "{\"mode\":\"$mode\",\"source\":$source}")"
  [ "$status" = 202 ] || { bad "Lauf anlegen: Status $status: $body"; RUN=""; return 1; }
  RUN="$(printf '%s' "$body" | jq -r .id)"
  for _ in $(seq 1 "${RUN_WAIT:-240}"); do
    request "$B" GET "/tenants/$tenant/dms/imports/$RUN"
    state="$(printf '%s' "$body" | jq -r .state)"
    [ "$state" != queued ] && [ "$state" != running ] && break
    sleep 1
  done
  request "$B" GET "/tenants/$tenant/dms/imports/$RUN/report"; REPORT="$body"
  RUN_STATE="$state"
}
rj() { printf '%s' "$REPORT" | jq -r "$1"; }
hub_hashes() { # Mandant Rolle -> "ID<TAB>sha256" sortiert
  echo "SELECT replace(i.origin_ref, 'paperless:', '') || chr(9) || f.sha256 FROM dms_document_files f JOIN dms_ingest_items i ON i.document_id = f.document_id AND i.tenant_id = f.tenant_id WHERE f.tenant_id = '$1' AND f.role = '$2' ORDER BY 1" | psql_db "$DB" | sort
}
truth_hashes() { awk -F'\t' -v col="$2" '$col != "-" {print $1 "\t" $col}' "$1" | sort; }
has_secret() { echo "SELECT count(*) FROM dms_imports WHERE id = '$1' AND secret_enc IS NOT NULL" | psql_db "$DB"; }

verify_import() { # Beschreibung Mandant Wahrheitsdatei Anzahl
  local what="$1" tenant="$2" truthfile="$3" n="$4"
  check "$what: Dokumente übernommen (Bericht)" "$(rj '.counts.documents_imported')" "$n"
  check "$what: Dokumente in der Datenbank" "$(echo "SELECT count(*) FROM dms_documents WHERE tenant_id = '$tenant'" | psql_db "$DB")" "$n"
  if [ "$(hub_hashes "$tenant" original)" = "$(truth_hashes "$truthfile" 2)" ]; then ok "$what: SHA-256 aller Originale gleich der Instanz"; else bad "$what: Hashes der Originale weichen ab"; diff <(hub_hashes "$tenant" original) <(truth_hashes "$truthfile" 2) >&2 || true; fi
  if [ "$(hub_hashes "$tenant" archive)" = "$(truth_hashes "$truthfile" 3)" ]; then ok "$what: SHA-256 aller Archivdateien gleich der Instanz"; else bad "$what: Hashes der Archive weichen ab"; diff <(hub_hashes "$tenant" archive) <(truth_hashes "$truthfile" 3) >&2 || true; fi
  titles="$(echo "SELECT title FROM dms_documents WHERE tenant_id = '$tenant'" | psql_db "$DB" | LC_ALL=C sort)"
  check "$what: Titel (auch Umlaute) gleich" "$titles" "$(cut -f4 "$truthfile" | LC_ALL=C sort)"
}

# 3. Export-Verzeichnis: Trockenlauf, Import, Wiederholung
EXPORT_SRC='{"kind":"export","path":"paperless-export"}'
run "$T_export" dry_run "$EXPORT_SRC"; check "Export Trockenlauf beendet" "$RUN_STATE" "done"
check "Export Trockenlauf: Dokumente gesehen (Fassung ist kein eigenes Dokument)" "$(rj '.counts.documents_seen')" "$N_ADMIN"
check "Export Trockenlauf schreibt nichts" "$(echo "SELECT count(*) FROM dms_documents WHERE tenant_id = '$T_export'" | psql_db "$DB")" 0
run "$T_export" import "$EXPORT_SRC"; check "Export Import beendet" "$RUN_STATE" "done"
verify_import "Export" "$T_export" "$workdir/truth-admin.tsv" "$N_ADMIN"
check "Export: Fassungen im Bericht gezählt" "$(rj '.counts.versions_skipped')" "$VERSIONS"
check "Export: Notizen" "$(rj '.counts.notes_imported')" "$N_NOTES"
check "Export: Dokument im Papierkorb übersprungen und gezählt" "$(rj '.counts.documents_in_trash')" 1
check "Export: Befund nennt das Dokument im Papierkorb" "$(rj '.findings.document_in_trash_skipped.items[0].ref')" "document:$(jq -r .trashed "$workdir/seed.json")"
check "Export: Prüfsummen aus dem Manifest geprüft" "$(rj '.counts.files_checksum_verified')" "$((N_ADMIN + N_ARCHIVES))"
run "$T_export" import "$EXPORT_SRC"; check "Export Wiederholung: nichts doppelt" "$(rj '.counts.documents_imported')" 0

# 4. REST-API mit Administrator-Token (feste API-Version, Prüfsummen über die API)
api_source() { printf '{"kind":"api","base_url":"%s","token":"%s"}' "$PA" "$1"; }
run "$T_admin" dry_run "$(api_source "$ADMIN_TOKEN")"; check "API Trockenlauf beendet" "$RUN_STATE" "done"
check "API Trockenlauf: Dokumente gesehen" "$(rj '.counts.documents_seen')" "$N_ADMIN"
check "API Trockenlauf: Token danach gelöscht" "$(has_secret "$RUN")" 0
run "$T_admin" import "$(api_source "$ADMIN_TOKEN")"; check "API Import beendet" "$RUN_STATE" "done"
verify_import "API" "$T_admin" "$workdir/truth-admin.tsv" "$N_ADMIN"
check "API: Fassungen im Bericht gezählt" "$(rj '.counts.versions_skipped')" "$VERSIONS"
check "API: Notizen" "$(rj '.counts.notes_imported')" "$N_NOTES"
check "API: alle Prüfsummen über die API belegt (keine ohne)" "$(rj '.counts.files_without_checksum // 0')" 0
check "API: Prüfsummen geprüft" "$(rj '.counts.files_checksum_verified')" "$((N_ADMIN + N_ARCHIVES))"
check "API: Token nach dem Lauf gelöscht" "$(has_secret "$RUN")" 0
# Export und API liefern dasselbe
check "Export und API: gleiche Originale" "$(hub_hashes "$T_export" original | shasum | cut -d' ' -f1)" "$(hub_hashes "$T_admin" original | shasum | cut -d' ' -f1)"
check "Export und API: gleiche Anzahl Tags und Felder" \
  "$(echo "SELECT (SELECT count(*) FROM dms_tags WHERE tenant_id = '$T_export') || '/' || (SELECT count(*) FROM dms_custom_fields WHERE tenant_id = '$T_export') || '/' || (SELECT count(*) FROM dms_document_fields WHERE tenant_id = '$T_export')" | psql_db "$DB")" \
  "$(echo "SELECT (SELECT count(*) FROM dms_tags WHERE tenant_id = '$T_admin') || '/' || (SELECT count(*) FROM dms_custom_fields WHERE tenant_id = '$T_admin') || '/' || (SELECT count(*) FROM dms_document_fields WHERE tenant_id = '$T_admin')" | psql_db "$DB")"

# 5. Benutzer nur mit Leserechten: sieht nur das für ihn Freigegebene, Stammdaten fehlen -> klarer Befund
run "$T_reader" import "$(api_source "$READER_TOKEN")"; check "Leser-Import beendet" "$RUN_STATE" "done"
check "Leser: Dokumente gesehen = für ihn sichtbare" "$(rj '.counts.documents_seen')" "$N_READER"
verify_import "Leser" "$T_reader" "$workdir/truth-reader.tsv" "$N_READER"
if [ "$(rj '.findings.reference_not_visible.total // 0')" -gt 0 ]; then ok "Leser: nicht sichtbare Stammdaten als Befund reference_not_visible ($(rj '.findings.reference_not_visible.total'))"; else bad "Leser: kein Befund reference_not_visible"; fi
check "Leser: Bericht nennt die Sicht des Token-Benutzers" "$(rj '.rights.visibility_note_code')" api_visible_to_token_user_only
check "Leser: Token nach dem Lauf gelöscht" "$(has_secret "$RUN")" 0

# 6. Fehlende Rechte, falsches Token, ungültige API-Version
run "$T_negative" dry_run "$(api_source "$NOPERM_TOKEN")"; check "ohne Rechte: Lauf fehlgeschlagen" "$RUN_STATE" "failed"
check "ohne Rechte: Fehlercode" "$(rj '.error_code')" source_permission_denied
check "ohne Rechte: Token gelöscht" "$(has_secret "$RUN")" 0
run "$T_negative" dry_run "$(api_source "falsch$ADMIN_TOKEN")"; check "falsches Token: Lauf fehlgeschlagen" "$RUN_STATE" "failed"
check "falsches Token: Fehlercode" "$(rj '.error_code')" source_auth_failed
check "falsches Token: Token gelöscht" "$(has_secret "$RUN")" 0
check "Instanz lehnt eine andere API-Version ab (406): die feste Angabe des Hub ist nötig" "$(pl_status "$ADMIN_TOKEN" /api/documents/ 'application/json; version=99')" 406
check "Instanz akzeptiert die vom Hub gesendete Version 10" "$(pl_status "$ADMIN_TOKEN" /api/documents/ 'application/json; version=10')" 200

# 6b. WP-PA3V: große Datei über eine langsame Leitung. Vermutung aus dem PA1-Review: die Anfragefrist (120 s) schneide den Download großer Dateien ab. Eine große erfundene Datei
# liegt in der Instanz; eine Weiterleitung bremst die Antworten auf eine feste Rate, sodass der Download der Originals länger als 120 s dauert (gemessen, nicht angenommen).
LARGE_MB="${E2E_LARGE_MB:-36}"
if [ "$LARGE_MB" -gt 0 ]; then
  LARGE="$(PA_ADMIN="$PA_ADMIN_USER" PA_PASS="$PA_ADMIN_PASS" PA_URL="$PA" PA_LARGE_MB="$LARGE_MB" python3 -I scripts/paperless-e2e/large.py)" || { echo "FEHLER: große Datei nicht aufgenommen" >&2; docker logs --tail 30 "$NAME-paperless" >&2; exit 3; }
  LARGE_BYTES="$(printf '%s' "$LARGE" | jq -r .bytes)"
  truth "$ADMIN_TOKEN" "$workdir/truth-large.tsv"
  check "Große Datei: in der Instanz aufgenommen (Dokumente jetzt)" "$(wc -l < "$workdir/truth-large.tsv" | tr -d ' ')" "$((N_ADMIN + 1))"
  RATE="${E2E_LARGE_RATE:-300000}"        # Bytes je Sekunde: 36 MiB brauchen so über 120 s
  python3 -I scripts/paperless-e2e/slowproxy.py "$PROXY_PORT" "$PA_PORT" "$RATE" > "$workdir/slowproxy.log" 2>&1 &
  pids+=($!)
  sleep 1
  started="$(date +%s)"
  RUN_WAIT=1500 run "$T_large" import "$(printf '{"kind":"api","base_url":"http://127.0.0.1:%s","token":"%s"}' "$PROXY_PORT" "$ADMIN_TOKEN")"
  elapsed="$(( $(date +%s) - started ))"
  echo "Große Datei: $LARGE_BYTES Bytes über $RATE B/s, Lauf dauerte $elapsed s"
  check "Große Datei: Import über die langsame Leitung beendet" "$RUN_STATE" "done"
  check "Große Datei: Lauf dauerte länger als die Anfragefrist von 120 s" "$([ "$elapsed" -gt 120 ] && echo ja || echo nein)" ja
  check "Große Datei: kein Dokument wegen Verbindungsabbruch übersprungen" "$(rj '.counts.documents_skipped // 0')" 0
  verify_import "Große Datei" "$T_large" "$workdir/truth-large.tsv" "$((N_ADMIN + 1))"
  check "Große Datei: Größe des Originals in der Datenbank" "$(echo "SELECT max(f.size_bytes) FROM dms_document_files f WHERE f.tenant_id = '$T_large' AND f.role = 'original'" | psql_db "$DB")" "$LARGE_BYTES"
  check "Große Datei: Token nach dem Lauf gelöscht" "$(has_secret "$RUN")" 0
fi

# 7. Sicherheit am echten System
request "$C" POST "/tenants/$T_negative/dms/imports" "$(body_file "{\"mode\":\"dry_run\",\"source\":{\"kind\":\"api\",\"base_url\":\"$PA\",\"token\":\"x\"}}")"
check "SSRF: http ohne Entwicklungsschalter abgelehnt (422)" "$status" 422
check "SSRF: Grund scheme_not_allowed" "$(printf '%s' "$body" | grep -c scheme_not_allowed)" 1
# WP-PA1R: Schreibweisen, bei denen Prüfung und HTTP-Client verschiedene Hosts sahen (Prozentzeichen im Host: der Client verband zu 127.0.0.1), und nicht kanonische IPv4
for url in "https://127.0.0.1:$PA_PORT" "https://localhost" "https://169.254.169.254" "https://[::1]" "https://127.0.0.1%3A$PA_PORT%2F.import.example.org" "https://x%40127.0.0.1:$PA_PORT" "https://0127.0.0.1:$PA_PORT"; do
  request "$C" POST "/tenants/$T_negative/dms/imports" "$(body_file "{\"mode\":\"dry_run\",\"source\":{\"kind\":\"api\",\"base_url\":\"$url\",\"token\":\"x\"}}")"
  check "SSRF: internes Ziel $url abgelehnt (422)" "$status" 422
done
request "$A" POST "/tenants/$T_negative/dms/imports" "$(body_file "{\"mode\":\"dry_run\",\"source\":{\"kind\":\"export\",\"path\":\"../../etc\"}}")"
check "Pfad: Export-Pfad mit .. abgelehnt (422)" "$status" 422
check "Token nirgends im Klartext in der Datenbank" "$(docker exec "$CONTAINER" pg_dump -U "$DB_USER" -d "$DB" | grep -c -e "$ADMIN_TOKEN" -e "$READER_TOKEN" -e "$NOPERM_TOKEN" || true)" 0
check "Token in keinem Log (Hub, Worker)" "$(cat "$workdir"/serve-*.log "$workdir"/worker-*.log | grep -c -e "$ADMIN_TOKEN" -e "$READER_TOKEN" -e "$NOPERM_TOKEN" || true)" 0
check "Kein Lauf behielt ein Token" "$(echo "SELECT count(*) FROM dms_imports WHERE secret_enc IS NOT NULL" | psql_db "$DB")" 0
check "Jeder Lauf genau einmal (zwei Worker): Läufe ohne Job-Wiederholung" "$(echo "SELECT count(*) FROM jobs WHERE kind = 'dms.import.paperless' AND attempts > 1" | psql_db "$DB")" 0

# 8. Interne Ziele nur mit Schalter UND Allowlist (Anleitung `docs/ANLEITUNG-PA3-PAPERLESS-PROBELAUF.md`, Abschnitt 3). Die zwei Worker mit Entwicklungsschalter werden beendet; ein Backend und
# ein Worker mit der Betriebsrichtlinie (kein Entwicklungsschalter, Schalter an, Allowlist auf genau diesen Host mit Port) übernehmen. `localhost` ist ein interner Name; Paperless spricht hier
# nur http, also scheitert der Lauf NACH der Zielprüfung an TLS, nicht mit `host_not_allowed`.
for p in "${dev_workers[@]}"; do kill "$p" 2> /dev/null || true; done
sleep 2
POLICY_ENV=(DMS_IMPORT_INSECURE_DEV=false DMS_ALLOW_INTERNAL_TARGETS=true "DMS_IMPORT_HOST_ALLOWLIST=localhost:$PA_PORT")
start "$PORT_D" false "${POLICY_ENV[@]}"
env AUTO_MIGRATE=false "${POLICY_ENV[@]}" "$APP" worker --kinds dms.import.paperless --poll-ms 200 > "$workdir/worker-policy.log" 2>&1 &
pids+=($!)
D="http://127.0.0.1:$PORT_D/api/v1"
src_for() { printf '{"mode":"dry_run","source":{"kind":"api","base_url":"%s","token":"platzhalter-token"}}' "$1"; }
request "$C" POST "/tenants/$T_negative/dms/imports" "$(body_file "$(src_for "https://localhost:$PA_PORT")")"
check "Ohne Schalter: https://localhost:$PA_PORT abgelehnt (422)" "$status" 422
request "$D" POST "/tenants/$T_negative/dms/imports" "$(body_file "$(src_for "https://localhost:$((PA_PORT + 1))")")"
check "Schalter an, Allowlist mit Port: anderer Port abgelehnt (422)" "$status" 422
request "$D" POST "/tenants/$T_negative/dms/imports" "$(body_file "$(src_for "https://nas.home.arpa")")"
check "Schalter an, Host nicht in der Allowlist: abgelehnt (422)" "$status" 422
request "$D" POST "/tenants/$T_negative/dms/imports" "$(body_file "$(src_for "https://localhost:$PA_PORT")")"
check "Schalter an und Host in der Allowlist: Lauf angelegt (202)" "$status" 202
POLICY_RUN="$(printf '%s' "$body" | jq -r .id)"
for _ in $(seq 1 60); do
  request "$D" GET "/tenants/$T_negative/dms/imports/$POLICY_RUN"; state="$(printf '%s' "$body" | jq -r .state)"
  [ "$state" != queued ] && [ "$state" != running ] && break
  sleep 1
done
request "$D" GET "/tenants/$T_negative/dms/imports/$POLICY_RUN/report"
check "Betriebsrichtlinie: Lauf endete als failed (Paperless spricht hier kein TLS)" "$state" failed
if [ "$(printf '%s' "$body" | jq -r .error_code)" != host_not_allowed ] && [ -n "$(printf '%s' "$body" | jq -r '.error_code // empty')" ]; then ok "Betriebsrichtlinie: Zielprüfung bestanden, Fehler erst beim Verbinden ($(printf '%s' "$body" | jq -r .error_code))"; else bad "Betriebsrichtlinie: Lauf scheiterte an der Zielprüfung oder ohne Code ($(printf '%s' "$body" | jq -r .error_code))"; fi
check "Betriebsrichtlinie: Platzhalter-Token nach dem Lauf gelöscht" "$(has_secret "$POLICY_RUN")" 0

if [ "$fail" = 0 ]; then echo "E2E Paperless-Import: alles ok"; else echo "E2E Paperless-Import: FEHLER" >&2; exit 1; fi
