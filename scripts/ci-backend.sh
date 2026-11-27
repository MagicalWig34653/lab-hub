#!/usr/bin/env bash
# WP-ST1: Backend-Tests wie in der GitHub-CI: volle Suite unter Linux im Worker-Test-Image (Swift 6.2 plus OCR-Werkzeuge)
# gegen eine laufende Postgres-17-Datenbank im Host-Netz, danach Auswertung (übersprungene Tests sichtbar, ohne Datenbanktests rot).
# Variablen: TEST_DB_HOST/PORT/NAME/USER/PASSWORD (wie die Swift-Tests), LH_CI_BUILD_VOLUME (Build-Volume).
# Das Übersetzen der Tests braucht mehrere GB freien Speicher in der Docker-VM.
# Unter Linux wird Docker in den Container durchgereicht, damit die Mail-Tests (GreenMail) laufen.
# WP-R6b: Die Render-Tests schreiben ihre PDFs nach /build/render-out; danach prüft veraPDF sie (PDF/A-3b, scripts/verapdf-check.sh).
# LH_CI_TEST_FILTER begrenzt den Lauf (z. B. "InvoiceRender|PostgresTests" im arm64-Job); ohne Angabe läuft die ganze Suite.
set -euo pipefail
cd "$(dirname "$0")/.."

IMAGE="${LH_CI_TEST_IMAGE:-lab-hub-worker-test}"
VOLUME="${LH_CI_BUILD_VOLUME:-labhub-ci-build}"
LOG="${LH_CI_TEST_LOG:-${TMPDIR:-/tmp}/labhub-ci-test.log}"
FILTER="${LH_CI_TEST_FILTER:-}"

docker build -f Dockerfile.worker --target worker-test -t "$IMAGE" .

docker_args=()
if [ "$(uname -s)" = Linux ]; then
  docker_args=(-v /var/run/docker.sock:/var/run/docker.sock -v "$(command -v docker):/usr/local/bin/docker:ro")
fi

status=0
# ${docker_args[@]+...}: leeres Array unter `set -u` auch mit Bash 3.2
docker run --rm --network host ${docker_args[@]+"${docker_args[@]}"} \
  -e TEST_DB_HOST -e TEST_DB_PORT -e TEST_DB_NAME -e TEST_DB_USER -e TEST_DB_PASSWORD \
  -e LH_RENDER_OUT=/build/render-out \
  -v "$PWD:/repo:ro" -v "$VOLUME:/build" \
  "$IMAGE" sh -c 'rm -rf /build/src /build/render-out && mkdir -p /build/src && cp -R /repo/backend /repo/contracts /repo/scripts /repo/Dockerfile /repo/Dockerfile.worker /build/src/ && cd /build/src/backend \
    && swift test --force-resolved-versions --explicit-target-dependency-import-check=error --scratch-path /build/scratch --cache-path /build/cache ${1:+--filter "$1"} 2>&1' sh "$FILTER" | tee "$LOG" || status=$?

scripts/check-test-report.sh "$LOG" || status=1

# AK-R6b-2: fünf Referenzfälle, zwei mit eingebettetem XML und der E2E-Beleg
pdfs=$(mktemp -d)
helper=$(docker create -v "$VOLUME:/build" "$IMAGE")
docker cp "$helper:/build/render-out/." "$pdfs" || echo "FEHLER: keine gerenderten PDFs im Testlauf" >&2
docker rm "$helper" > /dev/null
scripts/verapdf-check.sh "$pdfs" 8 || status=1
rm -rf "$pdfs"
exit "$status"
