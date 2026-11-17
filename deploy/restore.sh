#!/usr/bin/env bash
# Wiederherstellung von LAB hub aus einer Sicherung von deploy/backup.sh (WP-H2), mit Hash-Prüfung.
#
# Aufruf: deploy/restore.sh BACKUP_DIR --db NAME --objects ZIEL [--expect-manifest-hash HASH]
#         deploy/restore.sh BACKUP_DIR --verify-only [--scratch-db NAME] [--expect-manifest-hash HASH]
#   BACKUP_DIR              Verzeichnis einer Sicherung (db.dump, objects/, manifest.sha256, manifest.hash)
#   --db NAME               Ziel-Datenbank: muss existieren und leer sein (keine Tabellen)
#   --objects ZIEL          Ziel-Verzeichnis für den Dateisystem-Speicher: neu oder leer (entfällt, wenn die Sicherung keine Objekte hat)
#   --verify-only           Test-Restore: Wiederherstellung in eine Wegwerf-Datenbank und ein temporäres Verzeichnis, danach Vergleich
#                           und Aufräumen. Braucht das Recht CREATE DATABASE. Verändert nichts Bestehendes.
#   --scratch-db NAME       Name der Wegwerf-Datenbank (Standard: <DB_NAME>_verify_<pid>); darf nicht existieren
#   --expect-manifest-hash  erwarteter Manifest-Hash (Ausgabe von backup.sh), sonst nur Abgleich mit manifest.hash
# Umgebung: DB_HOST, DB_PORT, DB_USER, DB_PASSWORD oder DB_PASSWORD_FILE, optional LH_PG_CONTAINER, DB_NAME (nur Vorgabe für --scratch-db).
#
# Ablauf: 1) Manifest und Hash jeder Datei prüfen, Abbruch bei jeder Abweichung (auch bei fehlenden oder zusätzlichen Dateien),
# bevor irgendetwas geschrieben wird  2) Ziel auf Leere prüfen  3) pg_restore (eine Transaktion)  4) Objekte kopieren
# 5) kopierte Objekte erneut gegen das Manifest prüfen.
# Der Schlüssel (SECRET_KEY / Master-Key) gehört nicht zur Sicherung: vor dem Start des Backends getrennt wieder bereitstellen.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=deploy/backup-common.sh
. "$HERE/backup-common.sh"

BACKUP=""; TARGET_DB=""; TARGET_OBJ=""; VERIFY=0; SCRATCH=""; EXPECT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --db) TARGET_DB="${2:?Wert für --db fehlt}"; shift 2 ;;
    --objects) TARGET_OBJ="${2:?Wert für --objects fehlt}"; shift 2 ;;
    --verify-only) VERIFY=1; shift ;;
    --scratch-db) SCRATCH="${2:?Wert für --scratch-db fehlt}"; shift 2 ;;
    --expect-manifest-hash) EXPECT="${2:?Wert für --expect-manifest-hash fehlt}"; shift 2 ;;
    -h|--help) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) echo "Unbekannte Option: $1 (siehe --help)" >&2; exit 64 ;;
    *) [ -z "$BACKUP" ] || { echo "Nur ein Sicherungsverzeichnis angeben" >&2; exit 64; }; BACKUP="$1"; shift ;;
  esac
done
[ -n "$BACKUP" ] || { echo "Sicherungsverzeichnis fehlt (siehe --help)" >&2; exit 64; }
[ -d "$BACKUP" ] || lh_die "Sicherungsverzeichnis nicht gefunden: $BACKUP"
BACKUP="$(cd "$BACKUP" && pwd)"
if [ "$VERIFY" -eq 1 ]; then
  { [ -z "$TARGET_DB" ] && [ -z "$TARGET_OBJ" ]; } || { echo "--verify-only nicht mit --db/--objects kombinieren" >&2; exit 64; }
else
  [ -n "$TARGET_DB" ] || { echo "--db fehlt (siehe --help)" >&2; exit 64; }
fi
lh_db_init

# ---- 1. Sicherung prüfen -------------------------------------------------
M="$BACKUP/manifest.sha256"
[ -f "$M" ] && [ -f "$BACKUP/manifest.hash" ] || lh_die "manifest.sha256 oder manifest.hash fehlt"
mh="$(lh_hash "$M")"
[ "$mh" = "$(tr -d '\r\n' < "$BACKUP/manifest.hash")" ] || lh_die "Manifest-Hash weicht von manifest.hash ab (Manifest verändert)"
if [ -n "$EXPECT" ] && [ "$mh" != "$EXPECT" ]; then lh_die "Manifest-Hash weicht vom erwarteten Wert ab"; fi

WORK="$(mktemp -d)"
TMP_OBJ=""; DROP_DB=""
cleanup() {
  rm -rf "$WORK"
  [ -z "$TMP_OBJ" ] || rm -rf "$TMP_OBJ"
  if [ -n "$DROP_DB" ]; then lh_sql postgres "DROP DATABASE IF EXISTS $DROP_DB" > /dev/null 2>&1 || true; fi
}
trap cleanup EXIT

HAS_OBJECTS=0; HAS_DUMP=0; bad=0; count=0
: > "$WORK/listed"
while IFS= read -r line || [ -n "$line" ]; do
  h="${line%%  *}"; p="${line#*  }"
  case "$p" in "" | /* | *..*) lh_die "unzulässiger Pfad im Manifest" ;; esac
  case "$h" in "" | *[!0-9a-f]*) lh_die "ungültiger Hash im Manifest" ;; esac
  [ "${#h}" -eq 64 ] || lh_die "ungültiger Hash im Manifest"
  case "$p" in db.dump) HAS_DUMP=1 ;; objects/*) HAS_OBJECTS=1 ;; *) lh_die "unerwarteter Eintrag im Manifest: $p" ;; esac
  if [ ! -f "$BACKUP/$p" ]; then echo "FEHLT: $p" >&2; bad=1
  elif [ "$(lh_hash "$BACKUP/$p")" != "$h" ]; then echo "ABWEICHUNG: $p" >&2; bad=1; fi
  echo "$p" >> "$WORK/listed"; count=$((count + 1))
done < "$M"
[ "$HAS_DUMP" -eq 1 ] || lh_die "Manifest enthält db.dump nicht"
# Zusätzliche, nicht im Manifest geführte Dateien sind ebenfalls ein Fehler.
(cd "$BACKUP" && find . -type f ! -name manifest.sha256 ! -name manifest.hash | sed 's|^\./||') | LC_ALL=C sort > "$WORK/actual"
LC_ALL=C sort "$WORK/listed" | diff -q - "$WORK/actual" > /dev/null || { echo "ABWEICHUNG: Dateien im Verzeichnis stimmen nicht mit dem Manifest überein" >&2; bad=1; }
[ "$bad" -eq 0 ] || lh_die "Prüfung der Sicherung fehlgeschlagen, nichts wurde wiederhergestellt"
lh_info "Sicherung geprüft: $count Dateien, Manifest-Hash $mh"

# ---- 2. Ziele bestimmen und prüfen ---------------------------------------
if [ "$VERIFY" -eq 1 ]; then
  SCRATCH="${SCRATCH:-${DB_NAME:-labhub}_verify_$$}"
  lh_check_ident "$SCRATCH"
  [ "$(lh_sql postgres "SELECT count(*) FROM pg_database WHERE datname = '$SCRATCH'")" = 0 ] || lh_die "Wegwerf-Datenbank existiert bereits: $SCRATCH"
  lh_sql postgres "CREATE DATABASE $SCRATCH" > /dev/null
  DROP_DB="$SCRATCH"; TARGET_DB="$SCRATCH"
  if [ "$HAS_OBJECTS" -eq 1 ]; then TMP_OBJ="$(mktemp -d)"; TARGET_OBJ="$TMP_OBJ/objects"; fi
else
  lh_check_ident "$TARGET_DB"
  [ "$(lh_sql postgres "SELECT count(*) FROM pg_database WHERE datname = '$TARGET_DB'")" = 1 ] || lh_die "Ziel-Datenbank existiert nicht (vorher leer anlegen): $TARGET_DB"
  if [ "$HAS_OBJECTS" -eq 1 ] && [ -z "$TARGET_OBJ" ]; then echo "--objects fehlt, die Sicherung enthält Objekte" >&2; exit 64; fi
fi
[ "$(lh_sql "$TARGET_DB" "SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace WHERE n.nspname NOT IN ('pg_catalog','information_schema','pg_toast') AND c.relkind IN ('r','p','v','m','S','f')")" = 0 ] \
  || lh_die "Ziel-Datenbank ist nicht leer: $TARGET_DB"
if [ "$HAS_OBJECTS" -eq 1 ] && [ -e "$TARGET_OBJ" ] && [ -n "$(ls -A "$TARGET_OBJ" 2> /dev/null)" ]; then
  lh_die "Ziel-Verzeichnis ist nicht leer: $TARGET_OBJ"
fi

# ---- 3. Datenbank --------------------------------------------------------
lh_info "Datenbank wiederherstellen in $TARGET_DB"
lh_pg pg_restore --no-owner --exit-on-error --single-transaction -d "$TARGET_DB" < "$BACKUP/db.dump" || lh_die "pg_restore fehlgeschlagen"

# ---- 4./5. Objekte -------------------------------------------------------
if [ "$HAS_OBJECTS" -eq 1 ]; then
  lh_info "Objekte nach $TARGET_OBJ kopieren"
  mkdir -p "$TARGET_OBJ"; chmod 700 "$TARGET_OBJ"
  grep '  objects/' "$M" > "$WORK/objs" || true
  while IFS= read -r line; do
    rel="${line#*  objects/}"
    mkdir -p "$TARGET_OBJ/$(dirname "$rel")"
    cp -p "$BACKUP/objects/$rel" "$TARGET_OBJ/$rel"
  done < "$WORK/objs"
  bad=0
  while IFS= read -r line; do
    h="${line%%  *}"; f="$TARGET_OBJ/${line#*  objects/}"
    if [ ! -f "$f" ] || [ "$(lh_hash "$f")" != "$h" ]; then echo "ABWEICHUNG nach Kopie: ${line#*  }" >&2; bad=1; fi
  done < "$WORK/objs"
  [ "$(find "$TARGET_OBJ" -type f | wc -l | tr -d ' ')" = "$(wc -l < "$WORK/objs" | tr -d ' ')" ] || { echo "ABWEICHUNG: Anzahl der Objekte im Ziel" >&2; bad=1; }
  [ "$bad" -eq 0 ] || lh_die "Hash-Vergleich der wiederhergestellten Objekte fehlgeschlagen"
  lh_info "Objekte geprüft: $(wc -l < "$WORK/objs" | tr -d ' ')"
fi

# Datenbank gegen den Dump gegenprüfen: jede Tabelle mit Daten im Dump muss wiederhergestellt sein.
dump_tables="$(lh_pg pg_restore --list < "$BACKUP/db.dump" | grep -c ' TABLE DATA ' || true)"
db_tables="$(lh_sql "$TARGET_DB" "SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace WHERE n.nspname NOT IN ('pg_catalog','information_schema','pg_toast') AND c.relkind IN ('r','p')")"
{ [ "$dump_tables" -gt 0 ] && [ "$dump_tables" -le "$db_tables" ]; } || lh_die "Tabellenzahl passt nicht zum Dump (Dump $dump_tables, Datenbank $db_tables)"
lh_info "Datenbank geprüft: $db_tables Tabellen (Dump: $dump_tables mit Daten)"

if [ "$VERIFY" -eq 1 ]; then
  lh_info "VERIFY OK: Test-Restore und Hash-Vergleich bestanden (Wegwerf-Datenbank wird entfernt)"
else
  lh_info "RESTORE OK. Vor dem Start des Backends SECRET_KEY / Master-Key aus der getrennten Sicherung bereitstellen"
  lh_info "(ohne ihn sind verschlüsselte Werte unlesbar) und OBJECT_STORE_FS_PATH auf das Ziel setzen."
fi
