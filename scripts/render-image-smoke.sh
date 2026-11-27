#!/usr/bin/env bash
# WP-R6b: Rauchtest der Render-Werkzeuge im Laufzeit-Image (Stufe `worker-tools` von Dockerfile.worker, ohne Übersetzen der Anwendung):
# Nicht-Root, read-only Root, nur /tmp beschreibbar, kein Netz. Prüft Typst-Version, die gepinnten Schriften, PDF/A-3b und qpdf.
# Aufruf: scripts/render-image-smoke.sh   Variablen: LH_SMOKE_IMAGE (Name des gebauten Images).
set -euo pipefail
cd "$(dirname "$0")/.."

IMAGE="${LH_SMOKE_IMAGE:-lab-hub-worker-tools}"
docker build -f Dockerfile.worker --target worker-tools -t "$IMAGE" .

docker run --rm --user 10001 --read-only --tmpfs /tmp --network none -e HOME=/tmp "$IMAGE" sh -ceu '
  fonts=/usr/local/share/lab-hub/fonts
  typst --version | grep -q "^typst 0\.15\.1 "
  typst fonts --ignore-system-fonts --ignore-embedded-fonts --font-path "$fonts" | grep -qx Inter
  cd /tmp
  printf "#set document(title: \"Smoke\", date: auto)\n#set text(font: \"Inter\")\nSmoke\n" > smoke.typ
  typst compile --ignore-system-fonts --font-path "$fonts" --pdf-standard a-3b --creation-timestamp 0 smoke.typ smoke.pdf 2> warnings.txt
  [ ! -s warnings.txt ] || { cat warnings.txt >&2; exit 1; }
  pdftotext smoke.pdf - | grep -q Smoke
  qpdf --check smoke.pdf > /dev/null
  echo "render-image-smoke: ok ($(typst --version), $(qpdf --version | head -1))"
'
