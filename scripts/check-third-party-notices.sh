#!/usr/bin/env bash
# WP-H1 / F-03: Prüft den BoringSSL-Lizenzstand (swift-nio-ssl >= 2.37.6) und die ausgelieferten Lizenzdateien in legal/.
# Aufruf: scripts/check-third-party-notices.sh [checkout-dir]   (Standard: $LH_SCRATCH/checkouts/swift-nio-ssl, nur wenn vorhanden)
set -euo pipefail
cd "$(dirname "$0")/.."

MIN_VERSION="2.37.6"
BORINGSSL_REV="8eb25be6fa18d475291122887a7bccd3762ff236"
LICENSE_SHA="827c8d8fc207c2392794eef9e00fe246f9f61fdcc132556c275be3dd8c3cd97f"
fail=0
err() { echo "FEHLER: $*" >&2; fail=1; }

sha256() { if command -v sha256sum >/dev/null; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi; }

# 1. Lockfile: Version >= MIN_VERSION
version=$(grep -A6 '"identity" : "swift-nio-ssl"' backend/Package.resolved | sed -n 's/.*"version" : "\(.*\)".*/\1/p' | head -1)
[ -n "$version" ] || err "swift-nio-ssl nicht in backend/Package.resolved"
if [ -n "$version" ] && [ "$(printf '%s\n%s\n' "$MIN_VERSION" "$version" | sort -V | head -1)" != "$MIN_VERSION" ]; then
  err "swift-nio-ssl $version < $MIN_VERSION (BoringSSL mit OpenSSL-Altlizenz)"
fi
echo "swift-nio-ssl (Lockfile): ${version:-?}"

# 2. Lizenzdateien vorhanden, BoringSSL-LICENSE mit bekannter Prüfsumme
for f in legal/THIRD-PARTY-NOTICES.md legal/third-party/boringssl/LICENSE legal/third-party/swift-nio-ssl/NOTICE.txt legal/third-party/swift-nio-ssl/LICENSE.txt; do
  [ -s "$f" ] || err "fehlt oder leer: $f"
done
if [ -s legal/third-party/boringssl/LICENSE ] && [ "$(sha256 legal/third-party/boringssl/LICENSE)" != "$LICENSE_SHA" ]; then
  err "legal/third-party/boringssl/LICENSE weicht von der geprüften Fassung ab"
fi
grep -q "Apache License" legal/third-party/boringssl/LICENSE || err "BoringSSL-LICENSE ohne Apache-Text"

# 3. Gegen den ausgecheckten Quellstand prüfen (wenn vorhanden)
checkout="${1:-${LH_SCRATCH:-${TMPDIR:-/tmp}/labhub-build}/checkouts/swift-nio-ssl}"
if [ -d "$checkout/Sources/CNIOBoringSSL" ]; then
  d="$checkout/Sources/CNIOBoringSSL"
  rev=$(sed -n 's/.*at revision \([0-9a-f]\{40\}\).*/\1/p' "$d/hash.txt" | head -1)
  [ "$rev" = "$BORINGSSL_REV" ] || err "BoringSSL-Revision im Checkout ist ${rev:-unbekannt}, erwartet $BORINGSSL_REV (legal/ neu prüfen)"
  cmp -s "$checkout/NOTICE.txt" legal/third-party/swift-nio-ssl/NOTICE.txt || err "NOTICE.txt weicht vom Upstream ab (muss unverändert bleiben)"
  cmp -s "$checkout/LICENSE.txt" legal/third-party/swift-nio-ssl/LICENSE.txt || err "LICENSE.txt weicht vom Upstream ab"
  old=$({ grep -rl "Licensed under the OpenSSL license" "$d" 2>/dev/null || true; } | wc -l | tr -d ' ')
  [ "$old" = "0" ] || err "$old Dateien mit OpenSSL-Lizenzheader in $d"
  apache=$({ grep -rl "Licensed under the Apache" "$d" 2>/dev/null || true; } | wc -l | tr -d ' ')
  echo "Checkout: BoringSSL $rev, OpenSSL-Header: $old, Apache-Header: $apache"
else
  echo "Hinweis: kein Checkout unter $checkout, Quellprüfung übersprungen"
fi

[ "$fail" = 0 ] && echo "check-third-party-notices: ok"
exit "$fail"
