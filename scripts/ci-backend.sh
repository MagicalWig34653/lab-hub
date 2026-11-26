#!/usr/bin/env bash
# WP-ST1: Backend-Tests wie in der GitHub-CI: volle Suite unter Linux im Worker-Test-Image (Swift 6.2 plus OCR-Werkzeuge)
# gegen eine laufende Postgres-17-Datenbank im Host-Netz, danach Auswertung (übersprungene Tests sichtbar, ohne Datenbanktests rot).
# Variablen: TEST_DB_HOST/PORT/NAME/USER/PASSWORD (wie die Swift-Tests), LH_CI_BUILD_VOLUME (Build-Volume).
# Das Übersetzen der Tests braucht mehrere GB freien Speicher in der Docker-VM.
# Unter Linux wird Docker in den Container durchgereicht, damit die Mail-Tests (GreenMail) laufen.
set -euo pipefail
cd "$(dirname "$0")/.."

IMAGE="${LH_CI_TEST_IMAGE:-lab-hub-worker-test}"
VOLUME="${LH_CI_BUILD_VOLUME:-labhub-ci-build}"
LOG="${LH_CI_TEST_LOG:-${TMPDIR:-/tmp}/labhub-ci-test.log}"

docker build -f Dockerfile.worker --target worker-test -t "$IMAGE" .

docker_args=()
if [ "$(uname -s)" = Linux ]; then
  docker_args=(-v /var/run/docker.sock:/var/run/docker.sock -v "$(command -v docker):/usr/local/bin/docker:ro")
fi

status=0
# ${docker_args[@]+...}: leeres Array unter `set -u` auch mit Bash 3.2
docker run --rm --network host ${docker_args[@]+"${docker_args[@]}"} \
  -e TEST_DB_HOST -e TEST_DB_PORT -e TEST_DB_NAME -e TEST_DB_USER -e TEST_DB_PASSWORD \
  -v "$PWD:/repo:ro" -v "$VOLUME:/build" \
  "$IMAGE" sh -c 'rm -rf /build/src && mkdir -p /build/src && cp -R /repo/backend /repo/contracts /build/src/ && cd /build/src/backend \
    && swift test --force-resolved-versions --scratch-path /build/scratch --cache-path /build/cache 2>&1' | tee "$LOG" || status=$?

scripts/check-test-report.sh "$LOG" || status=1
exit "$status"
