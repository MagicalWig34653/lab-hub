#!/usr/bin/env bash
# Sicherung von LAB hub (WP-H2): konsistentes Paar aus PostgreSQL-Dump und Objektspeicher mit Hash-Manifest.
#
# Aufruf: deploy/backup.sh --out VERZEICHNIS [--objects PFAD]
#   --out DIR       Zielverzeichnis der Sicherung; muss neu sein oder leer (es wird nie etwas überschrieben)
#   --objects PFAD  Dateisystem-Objektspeicher (Standard: OBJECT_STORE_FS_PATH). Ohne Pfad: reiner Datenbank-Dump
#                   (OBJECT_STORE=db: die Objekte stecken im Dump)
# Umgebung: DB_HOST, DB_PORT, DB_NAME, DB_USER, DB_PASSWORD oder DB_PASSWORD_FILE, optional LH_PG_CONTAINER (siehe deploy/README.md).
#
# Ergebnis in DIR: db.dump (pg_dump -Fc, ein konsistenter Snapshot), objects/ (Kopie des Dateisystem-Speichers),
# manifest.sha256 (SHA-256 je Datei) und manifest.hash (SHA-256 des Manifests; Wert zusätzlich auf der Standardausgabe).
# Reihenfolge: erst Datenbank, dann Objekte. Objekte sind unveränderlich und werden vor ihrer Datenbankzeile geschrieben,
# die Sicherung enthält daher alles, was der Dump referenziert (höchstens zusätzlich später hochgeladene, unreferenzierte Dateien).
# Nicht enthalten, bewusst: SECRET_KEY / Master-Key (SecretBox). Getrennt und an anderem Ort sichern, siehe Hinweis am Ende.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=deploy/backup-common.sh
. "$HERE/backup-common.sh"

OUT=""; OBJECTS="${OBJECT_STORE_FS_PATH:-}"
while [ $# -gt 0 ]; do
  case "$1" in
    --out) OUT="${2:?Wert für --out fehlt}"; shift 2 ;;
    --objects) OBJECTS="${2:?Wert für --objects fehlt}"; shift 2 ;;
    -h|--help) sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unbekannte Option: $1 (siehe --help)" >&2; exit 64 ;;
  esac
done
[ -n "$OUT" ] || { echo "--out fehlt (siehe --help)" >&2; exit 64; }
lh_check_ident "${DB_NAME:-}"
lh_db_init

if [ -e "$OUT" ] && [ -n "$(ls -A "$OUT" 2> /dev/null)" ]; then lh_die "Zielverzeichnis ist nicht leer: $OUT"; fi
if [ -n "$OBJECTS" ]; then
  [ -d "$OBJECTS" ] || lh_die "Objektspeicher-Pfad ist kein Verzeichnis: $OBJECTS"
  OBJECTS="$(cd "$OBJECTS" && pwd)"
fi
mkdir -p "$OUT"; chmod 700 "$OUT"
OUT="$(cd "$OUT" && pwd)"
if [ -n "$OBJECTS" ]; then
  case "$OUT/" in "$OBJECTS/"*) rm -rf "$OUT"; lh_die "Zielverzeichnis liegt im Objektspeicher" ;; esac
fi
ok=0
trap 'if [ "$ok" -ne 1 ]; then rm -rf "$OUT"; echo "FEHLER: Sicherung abgebrochen, unvollständiges Verzeichnis entfernt" >&2; fi' EXIT

lh_info "1/3 Datenbank $DB_NAME sichern (pg_dump, konsistenter Snapshot)"
lh_pg pg_dump -Fc --no-owner -d "$DB_NAME" > "$OUT/db.dump"
[ -s "$OUT/db.dump" ] || lh_die "Dump ist leer"

if [ -n "$OBJECTS" ]; then
  lh_info "2/3 Objekte aus $OBJECTS kopieren"
  mkdir -p "$OUT/objects"
  n=0
  while IFS= read -r -d '' f; do
    rel="${f#"$OBJECTS"/}"
    mkdir -p "$OUT/objects/$(dirname "$rel")"
    cp -p "$f" "$OUT/objects/$rel"
    n=$((n + 1))
  done < <(find "$OBJECTS" -path "$OBJECTS/.staging" -prune -o -type f -print0)
  lh_info "    $n Objekte"
else
  lh_info "2/3 kein Dateisystem-Speicher (Objekte, falls OBJECT_STORE=db, stecken im Dump)"
fi

lh_info "3/3 Manifest (SHA-256 je Objekt) schreiben"
{
  echo "$(lh_hash "$OUT/db.dump")  db.dump"
  if [ -d "$OUT/objects" ]; then
    while IFS= read -r p; do
      echo "$(lh_hash "$OUT/$p")  $p"
    done < <(cd "$OUT" && find objects -type f | LC_ALL=C sort)
  fi
} > "$OUT/manifest.sha256"
MANIFEST_HASH="$(lh_hash "$OUT/manifest.sha256")"
echo "$MANIFEST_HASH" > "$OUT/manifest.hash"
ok=1

lh_info "Sicherung fertig: $OUT"
lh_info "Manifest-Hash (getrennt vom Archiv notieren, schützt vor Austausch des Manifests):"
echo "$MANIFEST_HASH"
lh_info "WICHTIG: SECRET_KEY / Master-Key (SecretBox) ist NICHT in der Sicherung und gehört nie hinein. Ohne ihn sind"
lh_info "verschlüsselte Werte (Mail-Passwörter, Tokens) nach einem Restore unlesbar. Getrennt an einem anderen Ort sichern."
lh_info "Regelmäßig prüfen: deploy/restore.sh $OUT --verify-only"
