#!/bin/sh
# Für jede Variable NAME_FILE den Dateiinhalt (Docker-Secret) als NAME exportieren; Werte werden nie ausgegeben.
set -eu
for var in $(env | sed -n 's/^\([A-Za-z0-9_]*\)_FILE=.*/\1/p'); do
  file="$(printenv "${var}_FILE")"
  [ -r "$file" ] || { echo "Secret-Datei für $var nicht lesbar" >&2; exit 1; }
  export "$var=$(cat "$file")"
done
exec /usr/local/bin/lab-hub "$@"
