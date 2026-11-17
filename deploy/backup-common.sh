#!/usr/bin/env bash
# Gemeinsame Funktionen für backup.sh und restore.sh (WP-H2). Wird nur eingebunden (source), nicht direkt aufgerufen.
# Konfiguration nur über Umgebung: DB_HOST, DB_PORT, DB_USER, DB_PASSWORD oder DB_PASSWORD_FILE (wie das Backend);
# LH_PG_CONTAINER (optional): Name eines Docker-Containers, in dem pg_dump/pg_restore/psql ausgeführt werden
# (wenn auf dem Host kein PostgreSQL-Client installiert ist; dann entfallen -h/-p, der Container verbindet lokal).
# Das Passwort wird nur als Umgebungsvariable PGPASSWORD weitergereicht, nie als Argument, nie ausgegeben.

lh_die() { echo "FEHLER: $*" >&2; exit 1; }
lh_info() { echo "$*" >&2; }

lh_db_init() {
  PG_HOST="${DB_HOST:-127.0.0.1}"; PG_PORT="${DB_PORT:-5432}"; PG_USER="${DB_USER:-labhub}"
  if [ -n "${DB_PASSWORD_FILE:-}" ]; then
    [ -r "$DB_PASSWORD_FILE" ] || lh_die "DB_PASSWORD_FILE nicht lesbar"
    PGPASSWORD="$(tr -d '\r\n' < "$DB_PASSWORD_FILE")"
  elif [ -n "${DB_PASSWORD:-}" ]; then
    PGPASSWORD="$DB_PASSWORD"
  else
    PGPASSWORD=""
  fi
  export PGPASSWORD
}

# lh_pg <werkzeug> <argumente...>: führt pg_dump, pg_restore oder psql mit Verbindungsangaben aus (stdin/stdout durchgereicht).
lh_pg() {
  local tool="$1"; shift
  if [ -n "${LH_PG_CONTAINER:-}" ]; then
    docker exec -i -e PGPASSWORD "$LH_PG_CONTAINER" "$tool" -U "$PG_USER" "$@"
  else
    command -v "$tool" > /dev/null 2>&1 || lh_die "$tool nicht gefunden (PostgreSQL-Client installieren oder LH_PG_CONTAINER setzen)"
    "$tool" -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" "$@"
  fi
}

# lh_sql <datenbank> <sql>: eine Abfrage, Ausgabe ohne Spaltenköpfe und Ausrichtung.
lh_sql() { lh_pg psql -X -A -t -v ON_ERROR_STOP=1 -d "$1" -c "$2"; }

# SHA-256 einer Datei (nur der Hex-Wert).
lh_hash() {
  if command -v sha256sum > /dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1
  elif command -v shasum > /dev/null 2>&1; then shasum -a 256 "$1" | cut -d' ' -f1
  else lh_die "weder sha256sum noch shasum gefunden"; fi
}

# Datenbanknamen nur in einfacher Form zulassen (gehen in SQL-Bezeichner).
lh_check_ident() {
  case "$1" in
    "" | *[!A-Za-z0-9_]* ) lh_die "ungültiger Datenbankname (nur A-Z a-z 0-9 _ erlaubt)" ;;
  esac
}
