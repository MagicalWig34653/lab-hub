#!/usr/bin/env bash
# WP-H9: Jede im Backend gelesene Umgebungsvariable muss in .env.example oder deploy/README.md erwähnt sein.
# Gesucht werden Zeichenketten-Literale der Form "NAME_MIT_UNTERSTRICH" in backend/Sources (HubConfig.value("X", env), env["X"], ...).
# Variablen, die nur an Werkzeug-Kindprozesse weitergereicht werden (kein Konfigurationswert des Hubs), stehen in IGNORE.
set -euo pipefail
cd "$(dirname "$0")/.."

IGNORE=" LC_ALL OMP_THREAD_LIMIT XDG_CACHE_HOME XDG_CONFIG_HOME "
docs=".env.example deploy/README.md"

names="$(grep -rhoE '"[A-Z][A-Z0-9]*_[A-Z0-9_]+"' backend/Sources | tr -d '"' | sort -u)"
missing=0
count=0
for n in $names; do
    case "$IGNORE" in *" $n "*) continue ;; esac
    count=$((count + 1))
    # shellcheck disable=SC2086
    if ! grep -qw -- "$n" $docs; then
        echo "check-env-docs: $n wird im Backend gelesen, steht aber weder in .env.example noch in deploy/README.md" >&2
        missing=1
    fi
done
if [ "$missing" -ne 0 ]; then exit 1; fi
echo "check-env-docs: $count Variablen dokumentiert"
