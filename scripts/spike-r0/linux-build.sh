#!/usr/bin/env bash
# WP-R0 spike: build and test selected taxlab packages on Linux (Docker swift image).
# The taxlab repo is mounted READ-ONLY; sources are copied into the container, nothing is written there.
# Usage: scripts/spike-r0/linux-build.sh <path-to-taxlab-repo> "<Package> [<Package> ...]" [image]
#   e.g. scripts/spike-r0/linux-build.sh ../taxlab "TaxlabCore TaxlabModel" swift:6.2
# Packages are copied (without .build) to /work inside the container; test runs the LAST package listed
# plus its path dependencies (so list dependencies first, tested package last).
set -euo pipefail
TAXLAB="${1:?path to taxlab repo}"
PKGS="${2:?packages}"
IMAGE="${3:-swift:6.2}"
docker run --rm -v "$TAXLAB/Packages:/src:ro" -e PKGS="$PKGS" "$IMAGE" bash -c '
  set -e
  mkdir -p /work
  for p in $PKGS; do cp -r /src/$p /work/; rm -rf /work/$p/.build; done
  swift --version
  for p in $PKGS; do
    echo "=== build+test $p"
    cd /work/$p
    swift build 2>&1 | tail -40 || true
    swift test 2>&1 | tail -40 || true
  done
'
