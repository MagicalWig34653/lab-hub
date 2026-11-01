#!/usr/bin/env bash
# Lokale Baseline-Prüfung (WP-K0): shellcheck, Build, Tests. Build-Artefakte außerhalb des Repos.
set -euo pipefail
cd "$(dirname "$0")/.."
export LH_SCRATCH="${LH_SCRATCH:-${TMPDIR:-/tmp}/labhub-build}"

shellcheck deploy/*.sh scripts/*.sh docker-entrypoint.sh
cd backend
swift build --scratch-path "$LH_SCRATCH"
swift test --scratch-path "$LH_SCRATCH"
