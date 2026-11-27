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

# 3. WP-R6b (AK-R6b-5): Typst im Worker-Image, in Typst eingebettete Schriften und die eigene Schrift Inter. Die Fassungen gehören zu den Pins in
#    Dockerfile.worker; ein neuer Pin ist ein Fehler, bis legal/, docs/LIZENZEN.md und diese Werte nachgezogen sind.
TYPST_PIN="ghcr.io/typst/typst:0.15.1@sha256:032e292249bcd378480cc7c142cfa324b63ef8aadeb88d7e7230320c4c9c422f"
INTER_URL="https://github.com/rsms/inter/releases/download/v4.1/Inter-4.1.zip"
INTER_SHA="9883fdd4a49d4fb66bd8177ba6625ef9a64aa45899767dde3d36aa425756b11e"
grep -qF "FROM $TYPST_PIN AS typst" Dockerfile.worker || err "Dockerfile.worker: Typst-Pin weicht ab (Lizenzstand neu prüfen)"
grep -qF -- "--checksum=sha256:$INTER_SHA $INTER_URL" Dockerfile.worker || err "Dockerfile.worker: Schrift-Pin weicht ab (Lizenzstand neu prüfen)"
while read -r sum f; do
  if [ ! -s "$f" ]; then err "fehlt oder leer: $f"
  elif [ "$(sha256 "$f")" != "$sum" ]; then err "$f weicht von der geprüften Fassung ab"
  fi
done <<'SUMS'
62c7a1e35f56406896d7aa7ca52d0cc0d272ac022b5d2796e7d6905db8a3636a legal/third-party/typst/LICENSE
1778244777547c281b6f5fa9fc0c18ab21f8d4491c803f64e09046800f5fcb26 legal/third-party/typst/NOTICE
62c7a1e35f56406896d7aa7ca52d0cc0d272ac022b5d2796e7d6905db8a3636a legal/third-party/typst-assets/LICENSE
80ac46fb7d70f1c30bf0c14d3408e6a6f0f9cc9997a00b592aa0d2c8a5243a9d legal/third-party/typst-assets/NOTICE
262481e844521b326f5ecd053e59b98c8b2da78c8ee1bdbb6e8174305e54935a legal/third-party/inter/LICENSE.txt
SUMS
grep -q "Apache License" legal/third-party/typst/LICENSE 2>/dev/null || err "Typst-LICENSE ohne Apache-Text"
for word in "Libertinus" "NewComputerModern" "DejaVu" "SIL OPEN FONT LICENSE" "GUST Font License" "Bitstream Vera"; do
  grep -qi "$word" legal/third-party/typst-assets/NOTICE 2>/dev/null || err "Schriftlizenzen von Typst ohne $word"
done
grep -qi "SIL OPEN FONT LICENSE" legal/third-party/inter/LICENSE.txt 2>/dev/null || err "Inter-Lizenz ohne OFL-Text"
for word in "Typst 0.15.1" "Inter 4.1" "typst-assets"; do
  grep -qF "$word" docs/LIZENZEN.md || err "docs/LIZENZEN.md ohne Eintrag: $word"
  grep -qF "$word" legal/THIRD-PARTY-NOTICES.md || err "legal/THIRD-PARTY-NOTICES.md ohne Eintrag: $word"
done

# 4. Gegen den ausgecheckten Quellstand prüfen (wenn vorhanden)
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
