#!/usr/bin/env bash
# WP-R0: regenerate the synthetic conformance vectors with the taxlab reference implementation (Linux, Docker).
# Usage: scripts/spike-r0/generate-vectors.sh <dir containing Packages/> <output dir>
# The taxlab sources are mounted read-only; output dir must be writable and mountable by Docker.
set -euo pipefail
TAXLAB="${1:?dir containing Packages/ (taxlab, read-only)}"
OUT="${2:?output dir}"
HERE="$(cd "$(dirname "$0")" && pwd)"
IMAGE="${3:-swift:6.2}"
mkdir -p "$OUT"
docker run --rm -v "$TAXLAB/Packages:/src:ro" -v "$HERE/vector-gen:/gen:ro" -v "$OUT:/out" "$IMAGE" bash -c '
  set -e
  mkdir -p /work && cp -r /src/TaxlabCore /src/TaxlabModel /work/ && rm -rf /work/*/.build
  cp -r /gen /work/vectorgen
  cd /work/vectorgen && swift run vectorgen /out
'
