#!/usr/bin/env bash
# WP-O2: OCR-Tests mit echter Engine (ocrmypdf, Tesseract deu+eng, Ghostscript) im Worker-Test-Image.
# Der Container läuft mit read-only Root; beschreibbar sind nur /tmp (tmpfs) und das Build-Volume (AK-O2-5). Die Datenbank ist die lokale Test-Datenbank
# (docker compose up -d db), erreichbar über das Host-Netz. Aufruf: scripts/ocr-container-test.sh ["Testfilter"]   (Standard: DMSOCR|OCRUnit)
set -euo pipefail
cd "$(dirname "$0")/.."

IMAGE="${LH_OCR_TEST_IMAGE:-lab-hub-worker-test}"
VOLUME="${LH_OCR_BUILD_VOLUME:-labhub-ocr-build}"
FILTER="${1:-DMSOCR|OCRUnit}"

docker build -f Dockerfile.worker --target worker-test -t "$IMAGE" .
docker volume create "$VOLUME" >/dev/null

# Geschrieben wird nur unter /tmp (tmpfs mit exec: nur der Swift-Test-Build startet dort Hilfsprogramme, das Produktions-Image braucht kein exec) und /build (Volume).
# TEST_DB_* werden durchgereicht (Standard siehe AuthTestSupport).
docker run --rm --network host --read-only --tmpfs /tmp:size=2g,exec --tmpfs /run \
  -e LH_READONLY_ROOT=1 -e HOME=/tmp -e TMPDIR=/tmp \
  -e TEST_DB_HOST -e TEST_DB_PORT -e TEST_DB_NAME -e TEST_DB_USER -e TEST_DB_PASSWORD \
  -v "$PWD/backend:/src:ro" -v "$VOLUME:/build" \
  "$IMAGE" sh -c 'rm -rf /build/src && mkdir -p /build/src && cp -R /src/. /build/src/ && cd /build/src \
    && swift test --scratch-path /build/scratch --cache-path /build/cache --filter "$0"' "$FILTER"
