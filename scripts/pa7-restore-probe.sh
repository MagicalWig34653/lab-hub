#!/usr/bin/env bash
# WP-PA7 (AK-PA7-2): Backup und Restore mit großem synthetischem Bestand messen, auf einem laufenden Compose-Stack
# (Betriebsart 3, `deploy/setup.sh`). Nur erfundene Daten (scripts/pa7-synth-bestand.py), keine echte Instanz, kein Eingriff in
# bestehende Mandanten: es entsteht ein eigener Messmandant mit eigenem Nutzer. Der Stack sollte währenddessen sonst ruhen
# (Messwerte), nötig ist es nicht (Backup läuft online).
#
# Aufruf: scripts/pa7-restore-probe.sh [--mix 8000:200K,800:2M,50:16M] [--prefix lauf1] [--out DIR] [--keep]
#   --mix     Zusammensetzung des Bestands wie in pa7-synth-bestand.py (Standard: ca. 4 GiB, 8 850 Dokumente)
#   --prefix  Dateinamens-Präfix des Laufs (zwei Läufe mit verschiedenem Präfix addieren sich im Bestand)
#   --out     Verzeichnis für die Sicherung (Standard: ./pa7-backup-<Zeit>); muss neu oder leer sein
#   --keep    Sicherung und wiederhergestellte Datenbank am Ende NICHT entfernen
#   --allow-ocr  trotz eingeschalteter Texterkennung laufen (nicht sinnvoll: jedes erfundene PDF erzeugt einen Auftrag, der scheitert)
# Umgebung: LABHUB_ENV (Standard deploy/.env), LABHUB_STACK (Standard aus der Datei, sonst labhub); läuft auf dem Docker-Host.
#
# Ablauf: 1 Messmandant anlegen  2 Bestand über die Upload-Route erzeugen  3 Größen und Fingerabdruck messen
# 4 backup.sh  5 restore.sh --verify-only  6 restore.sh in eine neue Datenbank  7 Vergleich: Zeilenzahlen, Fingerabdruck und SHA-256
# jedes Objekts NEU aus den wiederhergestellten Bytes (nicht aus der Datenbankspalte)  8 Backend und Worker (gleiche Images, gleiche
# Secrets) auf der wiederhergestellten Datenbank starten und den Prüflauf `dms.verify` der Anwendung ausführen (SHA-256 und Größe
# jedes Objekts, Audit-Kette): er muss `passed` mit 0 Abweichungen melden  9 aufräumen.
# Ausgabe: Zeilen `MESSUNG <Name> <Wert>` (zum Abschreiben in die Übergabe) und am Ende `PROBE OK` oder `PROBE FEHLER`.
set -euo pipefail
cd "$(dirname "$0")/.."

MIX="8000:200K,800:2M,50:16M"; PREFIX="probe$(date +%H%M%S)"; OUT=""; KEEP=0; ALLOW_OCR=0
while [ $# -gt 0 ]; do
  case "$1" in
    --mix) MIX="${2:?Wert für --mix fehlt}"; shift 2 ;;
    --prefix) PREFIX="${2:?Wert für --prefix fehlt}"; shift 2 ;;
    --out) OUT="${2:?Wert für --out fehlt}"; shift 2 ;;
    --keep) KEEP=1; shift ;;
    --allow-ocr) ALLOW_OCR=1; shift ;;
    -h | --help) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unbekannte Option: $1 (siehe --help)" >&2; exit 64 ;;
  esac
done
for tool in docker python3 uuidgen shasum; do command -v "$tool" > /dev/null || { echo "FEHLER: $tool fehlt" >&2; exit 2; }; done

ENV_FILE="${LABHUB_ENV:-deploy/.env}"
[ -f "$ENV_FILE" ] || { echo "FEHLER: $ENV_FILE fehlt (zuerst deploy/setup.sh)" >&2; exit 2; }
set -a
# shellcheck disable=SC1090
. "$ENV_FILE"
set +a
STACK="${LABHUB_STACK:-labhub}"
DB_NAME="${DB_NAME:-labhub}"; DB_USER="${DB_USER:-labhub}"
PORT="${BACKEND_PORT:-8080}"; BIND="${BACKEND_BIND:-127.0.0.1}"
PWFILE="deploy/compose/secrets/lh_db_password"
[ -r "$PWFILE" ] || { echo "FEHLER: $PWFILE nicht lesbar (Betriebsart 3?)" >&2; exit 2; }
DB_CONTAINER="$(docker compose --env-file "$ENV_FILE" -f deploy/compose/compose.yaml ps -q db)"
[ -n "$DB_CONTAINER" ] || { echo "FEHLER: kein laufender db-Dienst im Stack $STACK" >&2; exit 2; }
BASE="http://$BIND:$PORT"
curl -fsS "$BASE/ready" > /dev/null || { echo "FEHLER: $BASE/ready antwortet nicht" >&2; exit 2; }
# Die erfundenen PDFs bestehen aus Zufallsbytes: mit eingeschalteter Texterkennung entstünde je Datei ein Auftrag, der endgültig scheitert.
BACKEND_ID="$(docker compose --env-file "$ENV_FILE" -f deploy/compose/compose.yaml ps -q backend)"
OCR_SETTING="$(docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$BACKEND_ID" | sed -n 's/^DMS_OCR_ENABLED=//p')"
if [ "$OCR_SETTING" != false ] && [ "$ALLOW_OCR" -eq 0 ]; then
  echo "FEHLER: Texterkennung ist eingeschaltet (DMS_OCR_ENABLED=${OCR_SETTING:-unbekannt}). Für die Messung in $ENV_FILE DMS_OCR_ENABLED=false setzen," >&2
  echo "        'docker compose --env-file $ENV_FILE -f deploy/compose/compose.yaml up -d backend worker' ausführen, danach wieder auf true zurück." >&2
  exit 2
fi

PGPASSWORD="$(tr -d '\r\n' < "$PWFILE")"; export PGPASSWORD
sql() { docker exec -i -e PGPASSWORD "$DB_CONTAINER" psql -X -A -t -v ON_ERROR_STOP=1 -U "$DB_USER" -d "$1"; }   # SQL über stdin
now() { python3 -I -c 'import time; print(f"{time.time():.3f}")'; }
secs() { python3 -I -c "print(f'{$2 - $1:.1f}')"; }
mib() { python3 -I -c "print(f'{$1 / 1048576:.1f}')"; }
measure() { echo "MESSUNG $1 $2"; }
fails=0
check() { if [ "$2" = "$3" ]; then echo "ok   $1 ($2)"; else echo "FEHL $1: $2 statt $3" >&2; fails=$((fails + 1)); fi; }

RESTORED="${DB_NAME}_pa7_restore"
[ -n "$OUT" ] || OUT="$PWD/pa7-backup-$(date +%Y%m%d-%H%M%S)"
RB="${STACK}-pa7-restore-backend"; RW="${STACK}-pa7-restore-worker"
cleanup() {
  docker rm -f "$RB" "$RW" > /dev/null 2>&1 || true
  if [ "$KEEP" -eq 0 ]; then
    echo "DROP DATABASE IF EXISTS $RESTORED" | sql postgres > /dev/null 2>&1 || true
    rm -rf "$OUT"
  fi
}
trap cleanup EXIT
[ "$(echo "SELECT count(*) FROM pg_database WHERE datname = '$RESTORED'" | sql postgres)" = 0 ] || { echo "FEHLER: Datenbank $RESTORED existiert (Rest eines früheren Laufs, von Hand entfernen)" >&2; exit 2; }

# ---- 1. Messmandant (eigener Nutzer, eigene Sitzung; nur Testdaten) ----
lc() { tr '[:upper:]' '[:lower:]'; }
USER_ID="$(uuidgen | lc)"; TENANT="$(uuidgen | lc)"
E2E_SESSION="$(python3 -I -c 'import secrets; print(secrets.token_urlsafe(32))')"; export E2E_SESSION
SESSION_HASH="$(printf '%s' "$E2E_SESSION" | shasum -a 256 | cut -d' ' -f1)"
sql "$DB_NAME" << SQL > /dev/null
INSERT INTO users (id, handle, display_name) VALUES ('$USER_ID', 'pa7-$PREFIX', 'PA7 Messung (erfunden)');
INSERT INTO tenants (id, name) VALUES ('$TENANT', 'PA7 Messung $PREFIX');
INSERT INTO memberships (tenant_id, user_id, role) VALUES ('$TENANT', '$USER_ID', 'owner');
INSERT INTO sessions (user_id, token_hash, kind, expires_at) VALUES ('$USER_ID', '$SESSION_HASH', 'normal', now() + interval '1 day');
SQL
code="$(curl -sS -o /dev/null -w '%{http_code}' -X PUT -H "Authorization: Bearer $E2E_SESSION" -H 'Content-Type: application/json' -d '{"enabled":true}' "$BASE/api/v1/tenants/$TENANT/modules/dms")"
check "DMS für den Messmandanten eingeschaltet" "$code" 200

# ---- 2. Bestand erzeugen ----
echo "== Bestand erzeugen ($MIX) =="
LOAD="$(python3 -I scripts/pa7-synth-bestand.py --base-url "$BASE" --tenant "$TENANT" --mix "$MIX" --prefix "$PREFIX")" || { echo "FEHLER: Erzeugung fehlgeschlagen: $LOAD" >&2; exit 3; }
echo "$LOAD"
N_DOCS="$(printf '%s' "$LOAD" | python3 -I -c 'import json,sys; print(json.load(sys.stdin)["documents"])')"
LOAD_BYTES="$(printf '%s' "$LOAD" | python3 -I -c 'import json,sys; print(json.load(sys.stdin)["bytes"])')"
LOAD_SECS="$(printf '%s' "$LOAD" | python3 -I -c 'import json,sys; print(json.load(sys.stdin)["seconds"])')"
measure Erzeugung_Dokumente "$N_DOCS"; measure Erzeugung_MiB "$(mib "$LOAD_BYTES")"; measure Erzeugung_Sekunden "$LOAD_SECS"

# ---- 3. Größen und Fingerabdruck der Quelle ----
fingerprint() { # <Datenbank> -> "Dateien|Summe Bytes|Chunks|Dokumente|Hash über (sha256, Größe)"
  echo "SELECT (SELECT count(*) FROM files) || '|' || (SELECT coalesce(sum(size_bytes), 0) FROM files) || '|' || (SELECT count(*) FROM object_chunks) || '|' || (SELECT count(*) FROM dms_documents) || '|' || (SELECT coalesce(md5(string_agg(tenant_id || sha256 || ':' || size_bytes, ',' ORDER BY tenant_id, sha256)), '-') FROM files)" | sql "$1"
}
SRC_FP="$(fingerprint "$DB_NAME")"
DB_BYTES="$(echo "SELECT pg_database_size('$DB_NAME')" | sql "$DB_NAME")"
VOL_KB="$(docker exec "$DB_CONTAINER" du -sk /var/lib/postgresql/data | cut -f1)"
RAW_BYTES="$(echo "SELECT coalesce(sum(size_bytes), 0) FROM files" | sql "$DB_NAME")"
measure Quelle_Dateien_Chunks_Dokumente "$SRC_FP"
measure Quelle_Nutzbytes_MiB "$(mib "$RAW_BYTES")"
measure Quelle_Datenbankgröße_MiB "$(mib "$DB_BYTES")"
measure Quelle_Datenverzeichnis_MiB "$(python3 -I -c "print(f'{$VOL_KB / 1024:.1f}')")"

# ---- 4. Backup ----
echo "== Backup =="
export DB_HOST=127.0.0.1 DB_NAME DB_USER LH_PG_CONTAINER="$DB_CONTAINER" DB_PASSWORD="$PGPASSWORD"
T0="$(now)"
MH="$(deploy/backup.sh --out "$OUT" | tail -1)"
T1="$(now)"
BK_BYTES="$(du -sk "$OUT" | cut -f1)"
measure Backup_Sekunden "$(secs "$T0" "$T1")"
measure Backup_Größe_MiB "$(python3 -I -c "print(f'{$BK_BYTES / 1024:.1f}')")"
measure Backup_Manifest_Hash "$MH"

# ---- 5. Test-Restore (Wegwerf-Datenbank) ----
echo "== Test-Restore (--verify-only) =="
T0="$(now)"
deploy/restore.sh "$OUT" --verify-only --expect-manifest-hash "$MH"
T1="$(now)"
measure Verify_Sekunden "$(secs "$T0" "$T1")"

# ---- 6. Restore in eine neue, leere Datenbank ----
echo "== Restore =="
echo "CREATE DATABASE $RESTORED" | sql postgres > /dev/null
T0="$(now)"
deploy/restore.sh "$OUT" --db "$RESTORED" --expect-manifest-hash "$MH"
T1="$(now)"
measure Restore_Sekunden "$(secs "$T0" "$T1")"
check "Restore ohne Objektverzeichnis (OBJECT_STORE=db: Bytes liegen in der Datenbank)" "$([ -d "$OUT/objects" ] && echo vorhanden || echo keines)" keines

# ---- 7. Vergleich ----
echo "== Vergleich =="
DST_FP="$(fingerprint "$RESTORED")"
check "Fingerabdruck (Dateien, Bytes, Chunks, Dokumente, Hash) gleich" "$DST_FP" "$SRC_FP"
T0="$(now)"
RESULT="$(sql "$RESTORED" << 'SQL'
SELECT count(*) || '|' || count(*) FILTER (WHERE encode(sha256(a.d), 'hex') <> f.sha256 OR octet_length(a.d) <> f.size_bytes) || '|' || count(*) FILTER (WHERE a.d IS NULL)
FROM files f
LEFT JOIN LATERAL (SELECT string_agg(c.data, ''::bytea ORDER BY c.seq) AS d FROM object_chunks c WHERE c.tenant_id = f.tenant_id AND c.sha256 = f.sha256) a ON true
SQL
)"
T1="$(now)"
measure Hashprüfung_Sekunden "$(secs "$T0" "$T1")"
check "SHA-256 und Größe jedes Objekts aus den wiederhergestellten Bytes neu berechnet (Objekte|abweichend|ohne Bytes)" "$RESULT" "${SRC_FP%%|*}|0|0"

# ---- 8. Anwendung auf der wiederhergestellten Datenbank: Prüflauf dms.verify ----
echo "== Prüflauf der Anwendung auf der wiederhergestellten Datenbank =="
IMAGE="${LABHUB_IMAGE:?LABHUB_IMAGE fehlt in $ENV_FILE}"; WIMAGE="${LABHUB_WORKER_IMAGE:-$IMAGE-worker}"
NET="$(docker inspect -f '{{range $k, $v := .NetworkSettings.Networks}}{{$k}}{{end}}' "$DB_CONTAINER")"
RPORT=$((PORT + 1))
renv=(-e DB_HOST=db -e DB_PORT=5432 -e "DB_NAME=$RESTORED" -e "DB_USER=$DB_USER" -e DB_PASSWORD_FILE=/run/secrets/lh_db_password -e DB_TLS=disable
  -e AUTO_MIGRATE=false -e DMS_OCR_ENABLED=false -e DMS_VERIFY_INTERVAL_HOURS=0 -e SECRET_KEY_FILE=/run/secrets/lh_secret_key -e "PUBLIC_URL=${PUBLIC_URL:-http://localhost}"
  -e "WEBAUTHN_RP_ID=${WEBAUTHN_RP_ID:-localhost}")
# Secrets einzeln einhängen wie Compose (das Verzeichnis ist 0700, der Container-Nutzer UID 10001 dürfte es nicht betreten)
rrun=(--network "$NET" -v "$PWD/deploy/compose/secrets/lh_db_password:/run/secrets/lh_db_password:ro" -v "$PWD/deploy/compose/secrets/lh_secret_key:/run/secrets/lh_secret_key:ro" --read-only --tmpfs /tmp --cap-drop ALL --security-opt no-new-privileges:true)
docker run -d --name "$RB" "${rrun[@]}" "${renv[@]}" -p "127.0.0.1:$RPORT:8080" "$IMAGE" serve --env production --hostname 0.0.0.0 --port 8080 > /dev/null
docker run -d --name "$RW" "${rrun[@]}" "${renv[@]}" "$WIMAGE" worker --kinds dms.verify > /dev/null
for _ in $(seq 1 60); do curl -fsS "http://127.0.0.1:$RPORT/ready" > /dev/null 2>&1 && break; sleep 1; done
curl -fsS "http://127.0.0.1:$RPORT/ready" > /dev/null || { echo "FEHLER: Backend auf der wiederhergestellten Datenbank wird nicht bereit" >&2; docker logs --tail 20 "$RB" >&2; exit 3; }
api() { curl -sS -H "Authorization: Bearer $E2E_SESSION" -H 'Content-Type: application/json' "$@"; }
T0="$(now)"
RUN="$(api -X POST "http://127.0.0.1:$RPORT/api/v1/tenants/$TENANT/dms/integrity-runs" -H "Idempotency-Key: $(uuidgen)" | python3 -I -c 'import json,sys; print(json.load(sys.stdin)["id"])')"
STATE=queued
for _ in $(seq 1 "${PROBE_VERIFY_WAIT:-1800}"); do
  RESP="$(api "http://127.0.0.1:$RPORT/api/v1/tenants/$TENANT/dms/integrity-runs/$RUN")"
  STATE="$(printf '%s' "$RESP" | python3 -I -c 'import json,sys; print(json.load(sys.stdin)["state"])')"
  [ "$STATE" != queued ] && [ "$STATE" != running ] && break
  sleep 1
done
T1="$(now)"
measure Prüflauf_Sekunden "$(secs "$T0" "$T1")"
SUMMARY="$(printf '%s' "$RESP" | python3 -I -c 'import json,sys; r=json.load(sys.stdin); print("%s|%s|%s|%s" % (r["state"], r["files_checked"], r["files_bad"], r["chain_ok"]))')"
measure Prüflauf_Zustand_Dateien_Abweichungen_Kette "$SUMMARY"
check "Prüflauf der Anwendung: Zustand" "$(printf '%s' "$SUMMARY" | cut -d'|' -f1)" passed
check "Prüflauf der Anwendung: Dateien mit Abweichung" "$(printf '%s' "$SUMMARY" | cut -d'|' -f3)" 0
check "Prüflauf der Anwendung: Audit-Kette in Ordnung" "$(printf '%s' "$SUMMARY" | cut -d'|' -f4)" True

if [ "$fails" -eq 0 ]; then echo "PROBE OK"; else echo "PROBE FEHLER ($fails)" >&2; exit 1; fi
