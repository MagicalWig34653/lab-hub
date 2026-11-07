#!/usr/bin/env bash
# Interaktive Ersteinrichtung von LAB hub: stellt Fragen, erzeugt Passwörter und Schlüssel, schreibt deploy/.env,
# legt Docker-Secrets an und startet auf Wunsch den Betrieb.
#
# Betriebsarten:
#   1  Docker Swarm, PostgreSQL im Stack (ein Knoten mit Label labhub-db=true)
#   2  Docker Swarm, externe PostgreSQL-Datenbank
#   3  Einzelner Docker-Host (Compose), PostgreSQL im Compose-Projekt
#
# Aufruf: deploy/setup.sh [--dry-run] [--non-interactive] [--save-generated DIR]
#   --dry-run          nichts schreiben, keine Docker-Aufrufe; zeigt nur den Plan (Passwörter werden nie ausgegeben)
#   --non-interactive  keine Fragen; Werte aus Umgebungsvariablen LH_* (siehe unten), fehlende Pflichtwerte sind ein Fehler
#   --save-generated   erzeugte Geheimnisse zusätzlich in dieses Verzeichnis schreiben (Modus 0600), z. B. für den Passwortmanager
#
# Umgebungsvariablen für --non-interactive: LH_MODE (1|2|3), LH_STACK, LH_IMAGE, LH_DOMAIN, LH_HTTPS (yes|no),
#   LH_REPLICAS, LH_DB_HOST, LH_DB_PORT, LH_DB_NAME, LH_DB_USER, LH_DB_TLS (require|disable), LH_DB_PASSWORD_FILE (externe DB),
#   LH_BACKEND_PORT, LH_BACKEND_BIND (nur Betriebsart 3: lokaler Port/Adresse des Backends), LH_START (yes|no).
# Geheimnisse werden nie ausgegeben und nie als Kommandozeilenargument übergeben; Docker-Secrets laufen über stdin.
set -euo pipefail
umask 077

DRY=0; NONINT=0; SAVE_DIR=""
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY=1; shift ;;
    --non-interactive) NONINT=1; shift ;;
    --save-generated) SAVE_DIR="${2:?Wert für --save-generated fehlt}"; shift 2 ;;
    -h|--help) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unbekannte Option: $1 (siehe --help)" >&2; exit 64 ;;
  esac
done

HERE="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="$HERE/.env"
die() { echo "Fehler: $*" >&2; exit 1; }
say() { printf '%s\n' "$*"; }
need() { command -v "$1" >/dev/null 2>&1 || die "$1 wird benötigt"; }
[ "$DRY" = 1 ] || need docker
need openssl

# ask VAR "Frage" "Standard" [LH_NAME]: Wert aus LH_NAME, sonst Frage, sonst Standard
ask() {
  local var="$1" prompt="$2" default="${3:-}" envname="${4:-}" value=""
  if [ -n "$envname" ] && [ -n "${!envname:-}" ]; then value="${!envname}"
  elif [ "$NONINT" = 1 ]; then value="$default"
  else
    read -r -p "$prompt${default:+ [$default]}: " value || true
    value="${value:-$default}"
  fi
  printf -v "$var" '%s' "$value"
}
confirm() { # confirm "Frage" default(y|n) [LH_NAME]
  local answer="" default="${2:-n}" envname="${3:-}"
  if [ -n "$envname" ] && [ -n "${!envname:-}" ]; then answer="${!envname}"
  elif [ "$NONINT" = 1 ]; then answer="$default"
  else read -r -p "$1 [$( [ "$default" = y ] && echo J/n || echo j/N )]: " answer || true; fi
  case "${answer:-$default}" in j|J|y|Y|yes|ja|Ja) return 0 ;; n|N|no|nein) return 1 ;; *) [ "$default" = y ] ;; esac
}
validate_name() { [[ "$2" =~ ^[A-Za-z0-9_.-]+$ ]] || die "$1: nur Buchstaben, Ziffern, _ . - erlaubt"; }
random_password() { openssl rand -base64 36 | tr -d '/+=\n' | cut -c1-40; }

say "LAB hub – Einrichtung"
say "----------------------"
say "1) Docker Swarm, PostgreSQL im Stack"
say "2) Docker Swarm, externe PostgreSQL"
say "3) Einzelner Docker-Host (Compose), PostgreSQL im Compose-Projekt"
ask MODE "Betriebsart" "3" LH_MODE
case "$MODE" in 1|2|3) ;; *) die "Betriebsart muss 1, 2 oder 3 sein" ;; esac

ask STACK "Name des Stacks/Projekts" "labhub" LH_STACK; validate_name "Stackname" "$STACK"
ask IMAGE "Container-Image des Backends (z. B. ghcr.io/ORG/lab-hub:latest)" "" LH_IMAGE
[ -n "$IMAGE" ] || die "Image fehlt (noch kein Registry-Image? dann lokal bauen und hier den lokalen Namen angeben)"
ask DOMAIN "Öffentliche Domain (z. B. hub.example.org, ohne https://)" "localhost" LH_DOMAIN
[[ "$DOMAIN" =~ ^[A-Za-z0-9.-]+$ ]] || die "Domain ungültig"
if [ "$DOMAIN" = "localhost" ]; then HTTPS_DEFAULT=n; else HTTPS_DEFAULT=y; fi
if confirm "Wird die Domain über HTTPS (Reverse Proxy mit TLS) erreicht?" "$HTTPS_DEFAULT" LH_HTTPS; then SCHEME=https; else SCHEME=http; fi
PUBLIC_URL="$SCHEME://$DOMAIN"
WEBAUTHN_RP_ID="$DOMAIN"
say "  Hinweis: Die Passkey-Domain ($WEBAUTHN_RP_ID) lässt sich später nicht ändern, ohne alle Passkeys zu entwerten."

REPLICAS=1
if [ "$MODE" != 3 ]; then ask REPLICAS "Anzahl Backend-Repliken" "2" LH_REPLICAS; [[ "$REPLICAS" =~ ^[0-9]+$ ]] || die "Repliken: Zahl"; fi

DB_NAME=labhub; DB_USER=labhub; DB_PORT=5432; DB_TLS=disable; DB_HOST=db; EXT_DB_PASSWORD_FILE=""
ask DB_NAME "Datenbankname" "$DB_NAME" LH_DB_NAME; validate_name "Datenbankname" "$DB_NAME"
ask DB_USER "Datenbankbenutzer" "$DB_USER" LH_DB_USER; validate_name "Datenbankbenutzer" "$DB_USER"
if [ "$MODE" = 2 ]; then
  ask DB_HOST "Host der externen Datenbank" "" LH_DB_HOST; [ -n "$DB_HOST" ] || die "Datenbank-Host fehlt"
  ask DB_PORT "Port" "5432" LH_DB_PORT; [[ "$DB_PORT" =~ ^[0-9]+$ ]] || die "Port: Zahl"
  ask DB_TLS "TLS zur Datenbank (require|disable)" "require" LH_DB_TLS
  case "$DB_TLS" in require|disable) ;; *) die "TLS: require oder disable" ;; esac
  ask EXT_DB_PASSWORD_FILE "Datei mit dem vorhandenen DB-Passwort (leer = neues Passwort erzeugen)" "" LH_DB_PASSWORD_FILE
fi

BACKEND_PORT=8080; BACKEND_BIND=127.0.0.1
if [ "$MODE" = 3 ]; then
  ask BACKEND_PORT "Lokaler Port des Backends" "$BACKEND_PORT" LH_BACKEND_PORT; [[ "$BACKEND_PORT" =~ ^[0-9]+$ ]] || die "Port: Zahl"
  ask BACKEND_BIND "Lokale Adresse des Backends" "$BACKEND_BIND" LH_BACKEND_BIND; [[ "$BACKEND_BIND" =~ ^[0-9A-Za-z.:-]+$ ]] || die "Adresse ungültig"
fi

DB_PASSWORD_SOURCE="erzeugt"
if [ -n "$EXT_DB_PASSWORD_FILE" ]; then [ -f "$EXT_DB_PASSWORD_FILE" ] || die "Passwortdatei nicht gefunden"; DB_PASSWORD_SOURCE="aus Datei"; fi

say ""
say "Zusammenfassung"
say "  Betriebsart:      $MODE   Stack: $STACK   Image: $IMAGE"
say "  Adresse:          $PUBLIC_URL   (Passkey-Domain: $WEBAUTHN_RP_ID)"
say "  Repliken:         $REPLICAS"
say "  Datenbank:        $DB_USER@$DB_HOST:$DB_PORT/$DB_NAME   TLS: $DB_TLS   Passwort: $DB_PASSWORD_SOURCE"
say "  Dateien:          $ENV_FILE$( [ "$MODE" = 3 ] && echo ", $HERE/compose/secrets/" || echo ", Docker-Secrets lh_db_password und lh_secret_key" )"
[ "$DRY" = 1 ] && { say ""; say "Trockenlauf: nichts geschrieben, nichts gestartet."; exit 0; }
[ ! -e "$ENV_FILE" ] || die "$ENV_FILE existiert bereits; bitte prüfen oder verschieben (setup.sh überschreibt nichts)"
confirm "Fortfahren?" y LH_PROCEED || die "Abgebrochen"

# Geheimnisse erzeugen (nie ausgeben)
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
if [ -n "$EXT_DB_PASSWORD_FILE" ]; then tr -d '\n' < "$EXT_DB_PASSWORD_FILE" > "$TMP/lh_db_password"; else random_password | tr -d '\n' > "$TMP/lh_db_password"; fi
openssl rand -base64 32 | tr -d '\n' > "$TMP/lh_secret_key"

if [ -n "$SAVE_DIR" ]; then
  mkdir -p "$SAVE_DIR"; chmod 700 "$SAVE_DIR"
  for f in lh_db_password lh_secret_key; do [ ! -e "$SAVE_DIR/$f" ] || die "$SAVE_DIR/$f existiert bereits"; cp "$TMP/$f" "$SAVE_DIR/$f"; chmod 600 "$SAVE_DIR/$f"; done
  say "Geheimnisse gespeichert in $SAVE_DIR (Modus 0600). Docker zeigt Secrets später nicht mehr an."
else
  say "Hinweis: Ohne --save-generated sind erzeugte Geheimnisse später nicht mehr lesbar. Für Datenbank-Backups und Wiederherstellung unbedingt sichern."
fi

if [ "$MODE" = 3 ]; then
  mkdir -p "$HERE/compose/secrets"; chmod 700 "$HERE/compose/secrets"
  for f in lh_db_password lh_secret_key; do [ ! -e "$HERE/compose/secrets/$f" ] || die "compose/secrets/$f existiert bereits"; cp "$TMP/$f" "$HERE/compose/secrets/$f"; chmod 600 "$HERE/compose/secrets/$f"; done
else
  docker info 2>/dev/null | grep -q 'Swarm: active' || die "Docker Swarm ist nicht aktiv (docker swarm init)"
  for f in lh_db_password lh_secret_key; do
    docker secret inspect "$f" >/dev/null 2>&1 && die "Docker-Secret $f existiert bereits"
    docker secret create "$f" - < "$TMP/$f" >/dev/null
  done
  say "Docker-Secrets angelegt."
fi

cat > "$ENV_FILE" <<EOF
# Von deploy/setup.sh erzeugt. Enthält keine Passwörter (die liegen in Docker-Secrets bzw. compose/secrets/).
LABHUB_MODE=$MODE
LABHUB_STACK=$STACK
LABHUB_IMAGE=$IMAGE
PUBLIC_URL=$PUBLIC_URL
WEBAUTHN_RP_ID=$WEBAUTHN_RP_ID
BACKEND_REPLICAS=$REPLICAS
DB_HOST=$DB_HOST
DB_PORT=$DB_PORT
DB_NAME=$DB_NAME
DB_USER=$DB_USER
DB_TLS=$DB_TLS
$( [ "$MODE" = 3 ] && printf 'BACKEND_BIND=%s\nBACKEND_PORT=%s' "$BACKEND_BIND" "$BACKEND_PORT" )
EOF
chmod 600 "$ENV_FILE"
say "Konfiguration geschrieben: $ENV_FILE"

if [ "$MODE" = 2 ] && [ -z "$EXT_DB_PASSWORD_FILE" ]; then
  say ""
  say "Externe Datenbank: Benutzer und Datenbank müssen existieren. Beispiel (Passwort aus der gesicherten Datei einsetzen):"
  say "  CREATE ROLE $DB_USER LOGIN PASSWORD '<aus lh_db_password>';"
  say "  CREATE DATABASE $DB_NAME OWNER $DB_USER;"
fi

confirm "Jetzt starten?" y LH_START || { say "Später starten: siehe deploy/README.md"; exit 0; }
set -a
# shellcheck disable=SC1090
. "$ENV_FILE"
set +a
case "$MODE" in
  3)
    docker compose --env-file "$ENV_FILE" -f "$HERE/compose/compose.yaml" up -d
    say "Gestartet: $PUBLIC_URL (lokal ${BACKEND_BIND:-127.0.0.1}:${BACKEND_PORT:-8080}); Reverse Proxy mit TLS davorschalten." ;;
  1|2)
    FILES=(-c "$HERE/swarm/stack.yaml"); [ "$MODE" = 1 ] && FILES+=(-c "$HERE/swarm/stack.db.yaml")
    [ "$MODE" = 1 ] && say "Hinweis: Der Datenbankdienst braucht einen Knoten mit Label: docker node update --label-add labhub-db=true <knoten>"
    # Erst-Deploy: Backend mit 0 Repliken, Migration abwarten, dann hochskalieren
    BACKEND_REPLICAS=0 WORKER_REPLICAS=0 docker stack deploy --with-registry-auth "${FILES[@]}" "$STACK"
    say "Warte auf den Migrationsjob …"
    for _ in $(seq 1 60); do
      state="$(docker service ps "${STACK}_migrate" --format '{{.CurrentState}}' 2>/dev/null | head -n1 || true)"
      case "$state" in Complete*) break ;; Failed*|Rejected*) die "Migration fehlgeschlagen: docker service logs ${STACK}_migrate" ;; esac
      sleep 5
    done
    case "${state:-}" in Complete*) ;; *) die "Migration nicht abgeschlossen (Zeitüberschreitung): docker service logs ${STACK}_migrate" ;; esac
    docker service scale "${STACK}_backend=$REPLICAS" "${STACK}_worker=${WORKER_REPLICAS:-1}"
    say "Gestartet: $PUBLIC_URL (Reverse Proxy auf Port 8080 eines Knotens richten)." ;;
esac
