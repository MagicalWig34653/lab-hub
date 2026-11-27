#!/usr/bin/env bash
# WP-R6b (AK-R6b-2): Prüft alle PDFs eines Verzeichnisses mit veraPDF (PDF/A-3b, Image per Digest gepinnt, ohne Netz).
# Aufruf: scripts/verapdf-check.sh <Verzeichnis> [Mindestzahl]   Die Dateien werden mit `docker cp` übergeben (keine Host-Mounts nötig).
set -euo pipefail

IMAGE="verapdf/cli:v1.30.4@sha256:3252b49319482369382ab44bcc661d5f7ac6f14d0d5d84a62df2d89b936c28c0"
dir="${1:?Aufruf: verapdf-check.sh <Verzeichnis> [Mindestzahl]}"
minimum="${2:-1}"

shopt -s nullglob
files=("$dir"/*.pdf)
if [ "${#files[@]}" -lt "$minimum" ]; then echo "FEHLER: ${#files[@]} PDF in $dir, erwartet mindestens $minimum" >&2; exit 1; fi

args=()
for f in "${files[@]}"; do args+=("/tmp/check/$(basename "$f")"); done
container=$(docker create --network none "$IMAGE" --flavour 3b --format text "${args[@]}")
trap 'docker rm -f "$container" >/dev/null' EXIT
docker cp "$dir/." "$container:/tmp/check"
status=0
report=$(docker start -a "$container") || status=$?
printf '%s\n' "$report"
passed=$(grep -c '^PASS ' <<< "$report" || true)
if [ "$status" != 0 ] || [ "$passed" != "${#files[@]}" ]; then
  echo "FEHLER: veraPDF 3b: $passed von ${#files[@]} bestanden (Exit $status)" >&2
  exit 1
fi
echo "verapdf-check: ok ($passed PDF, PDF/A-3b)"
