#!/usr/bin/env bash
# WP-H2: automatischer Test für deploy/backup.sh und deploy/restore.sh mit synthetischen Daten.
# Braucht PostgreSQL mit dem Recht CREATE DATABASE (Standard: 127.0.0.1:15432, Benutzer labhub, siehe Variablen unten) und entweder
# einen PostgreSQL-Client (pg_dump, pg_restore, psql) auf dem Host oder LH_PG_CONTAINER=<Container> (Standard: labhub-pg-h10b,
# wenn auf dem Host kein psql vorhanden ist). Legt die Wegwerf-Datenbanken ${TEST_DB_NAME:-labhub_h2}_src und _restore an und entfernt sie wieder.
# Variablen: TEST_DB_HOST, TEST_DB_PORT, TEST_DB_USER, TEST_DB_PASSWORD (wie die Swift-Tests).
# shellcheck disable=SC2015  # "A && ok || fail" ist hier gewollt (ok/fail enden immer mit 0)
set -euo pipefail
cd "$(dirname "$0")/.."

export DB_HOST="${TEST_DB_HOST:-127.0.0.1}" DB_PORT="${TEST_DB_PORT:-15432}" DB_USER="${TEST_DB_USER:-labhub}"
export DB_PASSWORD="${TEST_DB_PASSWORD:-devtest-pw}"
if [ -z "${LH_PG_CONTAINER:-}" ] && ! command -v psql > /dev/null 2>&1; then export LH_PG_CONTAINER="labhub-pg-h10b"; fi
# shellcheck source=deploy/backup-common.sh
. deploy/backup-common.sh
lh_db_init

BASE="${TEST_DB_NAME:-labhub_h2}"
SRC="${BASE}_src"
DST="${BASE}_restore"
W="$(mktemp -d)"
fails=0
cleanup() {
  lh_sql postgres "DROP DATABASE IF EXISTS $SRC" > /dev/null 2>&1 || true
  lh_sql postgres "DROP DATABASE IF EXISTS $DST" > /dev/null 2>&1 || true
  rm -rf "$W"
}
trap cleanup EXIT

ok() { echo "ok   $*"; }
fail() { echo "FAIL $*" >&2; fails=$((fails + 1)); }
# expect_fail <name> <befehl...>: der Befehl muss mit Fehler enden
expect_fail() { local n="$1"; shift; if "$@" > "$W/out" 2>&1; then fail "$n (Befehl war erfolgreich)"; else ok "$n"; fi; }
expect_ok() { local n="$1"; shift; if "$@" > "$W/out" 2>&1; then ok "$n"; else fail "$n"; sed 's/^/     /' "$W/out" >&2; fi; }
fresh_db() { lh_sql postgres "DROP DATABASE IF EXISTS $1" > /dev/null; lh_sql postgres "CREATE DATABASE $1" > /dev/null; }
db_exists() { [ "$(lh_sql postgres "SELECT count(*) FROM pg_database WHERE datname = '$1'")" = 1 ]; }

# ---- synthetische Quelle ----
fresh_db "$SRC"
lh_sql "$SRC" "CREATE TABLE documents (id serial PRIMARY KEY, sha256 text NOT NULL, title text); CREATE TABLE notes (id serial PRIMARY KEY, body text); CREATE TABLE empty_t (id int)" > /dev/null
lh_sql "$SRC" "INSERT INTO documents(sha256, title) SELECT md5(g::text) || md5((g+1)::text), 'doc ' || g FROM generate_series(1, 250) g; INSERT INTO notes(body) SELECT repeat('x', 100) FROM generate_series(1, 40)" > /dev/null
OBJ="$W/store"
mkdir -p "$OBJ/.staging" "$OBJ/t1/ab" "$OBJ/t1/cd" "$OBJ/t2/ef"
echo "staging-file" > "$OBJ/.staging/ignored"
for i in 1 2 3 4 5; do head -c $((i * 1000)) /dev/urandom > "$OBJ/t1/ab/obj$i"; done
echo "synthetic pdf bytes" > "$OBJ/t1/cd/obj6"
head -c 5000 /dev/urandom > "$OBJ/t2/ef/obj7"

export DB_NAME="$SRC"
SENTINEL="sentinel-master-key-0123456789"
BK="$W/backup"
echo "== Backup =="
SECRET_KEY="$SENTINEL" expect_ok "backup laeuft durch" deploy/backup.sh --out "$BK" --objects "$OBJ"
MH="$(tr -d '\r\n' < "$BK/manifest.hash")"
[ "${#MH}" -eq 64 ] && ok "manifest.hash ist ein SHA-256" || fail "manifest.hash"
[ "$(wc -l < "$BK/manifest.sha256" | tr -d ' ')" = 8 ] && ok "Manifest: db.dump + 7 Objekte" || fail "Manifest-Zeilen"
[ ! -e "$BK/objects/.staging" ] && ok ".staging nicht gesichert" || fail ".staging gesichert"
if grep -rq "$SENTINEL" "$BK"; then fail "Schluessel im Archiv"; else ok "Schluessel nicht im Archiv"; fi
expect_fail "backup in nicht leeres Ziel wird abgelehnt" deploy/backup.sh --out "$BK" --objects "$OBJ"

echo "== Restore (leeres Ziel) =="
fresh_db "$DST"
RO="$W/restored"
expect_ok "restore laeuft durch" deploy/restore.sh "$BK" --db "$DST" --objects "$RO" --expect-manifest-hash "$MH"
if diff -r -x .staging "$OBJ" "$RO" > /dev/null; then ok "Objektbaum identisch (diff -r)"; else fail "Objektbaum weicht ab"; fi
for t in documents notes empty_t; do
  a="$(lh_sql "$SRC" "SELECT count(*) FROM $t")"; b="$(lh_sql "$DST" "SELECT count(*) FROM $t")"
  [ "$a" = "$b" ] && ok "Zeilenzahl $t gleich ($a)" || fail "Zeilenzahl $t: $a gegen $b"
done
a="$(lh_sql "$SRC" "SELECT md5(string_agg(sha256 || title, ',' ORDER BY id)) FROM documents")"
b="$(lh_sql "$DST" "SELECT md5(string_agg(sha256 || title, ',' ORDER BY id)) FROM documents")"
[ "$a" = "$b" ] && ok "Inhalts-Hash documents gleich" || fail "Inhalts-Hash documents"

echo "== Leeres Ziel ist Pflicht =="
expect_fail "restore in nicht leere Datenbank" deploy/restore.sh "$BK" --db "$DST" --objects "$W/other"
fresh_db "$DST"
expect_fail "restore in nicht leeres Verzeichnis" deploy/restore.sh "$BK" --db "$DST" --objects "$RO"
[ "$(lh_sql "$DST" "SELECT count(*) FROM pg_tables WHERE schemaname = 'public'")" = 0 ] && ok "Datenbank blieb unberuehrt" || fail "Datenbank veraendert"
expect_fail "falscher erwarteter Manifest-Hash" deploy/restore.sh "$BK" --db "$DST" --objects "$W/o2" --expect-manifest-hash "$(printf '0%.0s' $(seq 64))"

echo "== Test-Restore (--verify-only) =="
expect_ok "verify-only erfolgreich" env DB_NAME="$DST" deploy/restore.sh "$BK" --verify-only --scratch-db "${BASE}_verify"
db_exists "${BASE}_verify" && fail "Wegwerf-Datenbank nicht entfernt" || ok "Wegwerf-Datenbank entfernt"

echo "== Manipulation fuehrt zum Abbruch =="
A64="$(printf 'a%.0s' $(seq 64))"
tamper() { rm -rf "$W/bad"; cp -Rp "$BK" "$W/bad"; }
tamper; echo "x" >> "$W/bad/objects/t1/ab/obj1"
expect_fail "manipulierte Objektdatei: restore" deploy/restore.sh "$W/bad" --db "$DST" --objects "$W/o3"
[ ! -e "$W/o3" ] && [ "$(lh_sql "$DST" "SELECT count(*) FROM pg_tables WHERE schemaname = 'public'")" = 0 ] && ok "nichts wurde wiederhergestellt" || fail "Teilrestore trotz Abweichung"
expect_fail "manipulierte Objektdatei: verify-only" env DB_NAME="$DST" deploy/restore.sh "$W/bad" --verify-only --scratch-db "${BASE}_verify"
tamper; rm "$W/bad/objects/t2/ef/obj7"
expect_fail "fehlende Objektdatei" deploy/restore.sh "$W/bad" --db "$DST" --objects "$W/o3"
tamper; echo "extra" > "$W/bad/objects/t2/ef/extra"
expect_fail "zusaetzliche Datei" deploy/restore.sh "$W/bad" --db "$DST" --objects "$W/o3"
tamper; echo "x" >> "$W/bad/db.dump"
expect_fail "manipulierter Dump" deploy/restore.sh "$W/bad" --db "$DST" --objects "$W/o3"
tamper; sed "2s/^[0-9a-f]\{64\}/$A64/" "$W/bad/manifest.sha256" > "$W/m" && cp "$W/m" "$W/bad/manifest.sha256"
expect_fail "manipuliertes Manifest" deploy/restore.sh "$W/bad" --db "$DST" --objects "$W/o3"
tamper; sed "2s/^[0-9a-f]\{64\}/$A64/" "$W/bad/manifest.sha256" > "$W/m" && cp "$W/m" "$W/bad/manifest.sha256"
(cd "$W/bad" && if command -v sha256sum > /dev/null 2>&1; then sha256sum manifest.sha256; else shasum -a 256 manifest.sha256; fi) | cut -d' ' -f1 > "$W/bad/manifest.hash"
expect_fail "Manifest samt manifest.hash ausgetauscht (erwarteter Hash greift)" deploy/restore.sh "$W/bad" --db "$DST" --objects "$W/o3" --expect-manifest-hash "$MH"
db_exists "${BASE}_verify" && fail "Wegwerf-Datenbank uebrig" || ok "keine Wegwerf-Datenbank uebrig"

echo
if [ "$fails" -ne 0 ]; then echo "backup-restore-test: $fails FEHLER" >&2; exit 1; fi
echo "backup-restore-test: alle Pruefungen bestanden"
