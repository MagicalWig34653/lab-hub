#!/usr/bin/env bash
# Update von LAB hub auf ein neues Image: Migration mit dem neuen Image, dann rollierend die Backend-Repliken.
#
# Aufruf: deploy/update.sh [Optionen]
#   --env-file DATEI   Konfiguration (Standard: deploy/.env, von setup.sh erzeugt)
#   --image IMAGE      neues Image (z. B. ghcr.io/ORG/lab-hub:1.2.0); ohne Angabe wird LABHUB_IMAGE aus der .env erneut gezogen
#   --dry-run          nur anzeigen, nichts ändern und keine Docker-Aufrufe
#   --force            (ohne Wirkung, Update läuft immer)
#   --yes              keine Rückfrage
#   --skip-backup-check  Rückfrage zur Datenbanksicherung überspringen (nicht empfohlen)
#
# Ablauf: 1) Voraussetzungen prüfen  2) Sicherungshinweis  3) Image ziehen  4) Migrationsjob mit neuem Image
#         5) Backend rollierend aktualisieren (Swarm: start-first, Rollback bei Fehler; Compose: neu erstellen)
#         6) Prüfen, dass /ready antwortet. Migrationen müssen zur vorherigen Version rückwärtskompatibel sein
#         (Expand/Contract), weil während des Rollouts alte und neue Repliken gleichzeitig laufen (ADR 0003).
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="$HERE/.env"; NEW_IMAGE=""; DRY=0; YES=0; BACKUP_CHECK=1; WAIT=300
while [ $# -gt 0 ]; do
  case "$1" in
    --env-file) ENV_FILE="${2:?Wert für --env-file fehlt}"; shift 2 ;;
    --image) NEW_IMAGE="${2:?Wert für --image fehlt}"; shift 2 ;;
    --dry-run) DRY=1; shift ;;
    --force) shift ;; # akzeptiert; Update läuft immer, die Option bleibt für Skripte kompatibel
    --yes|-y) YES=1; shift ;;
    --skip-backup-check) BACKUP_CHECK=0; shift ;;
    -h|--help) sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unbekannte Option: $1 (siehe --help)" >&2; exit 64 ;;
  esac
done

START=$(date +%s)
elapsed() { local t=$(( $(date +%s) - START )); printf '%02d:%02d' $((t / 60)) $((t % 60)); }
say() { printf '[%s] %s\n' "$(elapsed)" "$*"; }
die() { echo "[$(elapsed)] Fehler: $*" >&2; exit 1; }
[ "$DRY" = 1 ] || command -v docker >/dev/null 2>&1 || die "docker wird benötigt"
[ -f "$ENV_FILE" ] || die "Konfiguration nicht gefunden: $ENV_FILE (zuerst deploy/setup.sh ausführen)"

get() { sed -n "s/^$1=//p" "$ENV_FILE" | tail -n 1 | tr -d "\"'"; }
MODE="$(get LABHUB_MODE)"; STACK="$(get LABHUB_STACK)"; CURRENT="$(get LABHUB_IMAGE)"
BASE="$(get PUBLIC_BASE_URL)"
case "$MODE" in 1|2|3) ;; *) die "LABHUB_MODE in $ENV_FILE ungültig" ;; esac
[ -n "$STACK" ] && [ -n "$CURRENT" ] || die "LABHUB_STACK/LABHUB_IMAGE fehlen in $ENV_FILE"
TARGET="${NEW_IMAGE:-$CURRENT}"

say "Stack: $STACK (Betriebsart $MODE)"
say "Aktuelles Image: $CURRENT"
say "Ziel-Image:      $TARGET"
if [ "$TARGET" = "$CURRENT" ] && [ -z "$NEW_IMAGE" ]; then say "Hinweis: gleiches Image-Tag; es wird neu gezogen (z. B. bei :latest)."; fi
[ "$DRY" = 1 ] && { say "Trockenlauf: keine Änderung."; exit 0; }

if [ "$BACKUP_CHECK" = 1 ] && [ "$YES" = 0 ]; then
  say "Vor jedem Update die Datenbank sichern (pg_dump oder Volume-Snapshot) und den Wiederherstellungsweg kennen."
  read -r -p "Ist eine aktuelle Sicherung vorhanden? [j/N]: " a || true
  case "${a:-n}" in j|J|y|Y) ;; *) die "Abgebrochen: bitte zuerst sichern (oder --skip-backup-check)" ;; esac
fi
if [ "$YES" = 0 ]; then
  read -r -p "Update jetzt starten? [j/N]: " a || true
  case "${a:-n}" in j|J|y|Y) ;; *) die "Abgebrochen" ;; esac
fi

# Image in .env nachführen (Sicherung der alten Datei)
if [ "$TARGET" != "$CURRENT" ]; then
  cp -p "$ENV_FILE" "$ENV_FILE.bak"
  sed "s#^LABHUB_IMAGE=.*#LABHUB_IMAGE=$TARGET#" "$ENV_FILE.bak" > "$ENV_FILE"; chmod 600 "$ENV_FILE"
  say "LABHUB_IMAGE aktualisiert (alte Datei: $ENV_FILE.bak)"
fi
# shellcheck disable=SC1090
set -a; . "$ENV_FILE"; set +a

wait_ready() {
  local url="$1"
  [ -n "$url" ] || return 0
  command -v curl >/dev/null 2>&1 || { say "curl fehlt; /ready-Prüfung übersprungen"; return 0; }
  for _ in $(seq 1 60); do
    curl -fsS --max-time 3 "$url/ready" >/dev/null 2>&1 && { say "/ready antwortet"; return 0; }
    sleep 5
  done
  return 1
}

case "$MODE" in
  3)
    COMPOSE=(docker compose --env-file "$ENV_FILE" -f "$HERE/compose/compose.yaml")
    say "Image ziehen …"; "${COMPOSE[@]}" pull migrate backend
    say "Migration …"; "${COMPOSE[@]}" run --rm migrate || die "Migration fehlgeschlagen; Backend wurde nicht angefasst. Alte Version läuft weiter."
    say "Backend neu erstellen …"; "${COMPOSE[@]}" up -d --no-deps backend
    wait_ready "http://${BACKEND_BIND:-127.0.0.1}:${BACKEND_PORT:-8080}" || die "Backend meldet nicht /ready: ${COMPOSE[*]} logs backend"
    ;;
  1|2)
    FILES=(-c "$HERE/swarm/stack.yaml"); [ "$MODE" = 1 ] && FILES+=(-c "$HERE/swarm/stack.db.yaml")
    say "Migration mit dem neuen Image …"
    # Der Migrationsjob läuft erneut, wenn der Dienst aktualisiert wird; Backend bleibt dabei auf der alten Version.
    docker service update --with-registry-auth --force --image "$TARGET" "${STACK}_migrate" >/dev/null
    for _ in $(seq 1 $((WAIT / 5))); do
      state="$(docker service ps "${STACK}_migrate" --format '{{.CurrentState}}' 2>/dev/null | head -n1 || true)"
      case "$state" in Complete*) break ;; Failed*|Rejected*) die "Migration fehlgeschlagen (Backend unverändert): docker service logs ${STACK}_migrate" ;; esac
      sleep 5
    done
    case "${state:-}" in Complete*) say "Migration abgeschlossen" ;; *) die "Migration nicht abgeschlossen: docker service logs ${STACK}_migrate" ;; esac
    say "Backend rollierend aktualisieren (start-first, Rollback bei Fehler) …"
    docker service update --with-registry-auth --image "$TARGET" "${STACK}_backend" || die "Update fehlgeschlagen; Swarm hat ggf. zurückgerollt: docker service ps ${STACK}_backend"
    wait_ready "$BASE" || say "Hinweis: $BASE/ready nicht erreichbar (Reverse Proxy/DNS prüfen); Dienststatus: docker service ps ${STACK}_backend"
    ;;
esac
say "Fertig."
