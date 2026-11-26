#!/usr/bin/env bash
# WP-ST1: Tests für die Prüfungen der GitHub-CI (scripts/check-test-report.sh, scripts/check-workflows.sh) mit synthetischen Eingaben.
# shellcheck disable=SC2016  # ${{ ... }} in den Workflow-Beispielen bleibt wörtlich
set -euo pipefail
cd "$(dirname "$0")/.."

W="$(mktemp -d)"
trap 'rm -rf "$W"' EXIT
fails=0
ok() { echo "ok   $*"; }
fail() { echo "FAIL $*" >&2; fails=$((fails + 1)); }
# expect <0|1> <Name> <Befehl...>
expect() {
  local want="$1" name="$2" got=0
  shift 2
  "$@" > "$W/out" 2>&1 || got=1
  if [ "$got" = "$want" ]; then ok "$name"; else fail "$name (erwartet $want, war $got)"; sed 's/^/     /' "$W/out" >&2; fi
}
contains() { if grep -qF -- "$1" "$W/out"; then ok "$2"; else fail "$2 (fehlt in der Ausgabe: $1)"; fi; }

# ---- AK-ST1-1: Testprotokoll ----
report() { GITHUB_STEP_SUMMARY="" scripts/check-test-report.sh "$1"; }

# macOS-Format (XCTest) und Linux-Format (swift-corelibs-xctest)
cat > "$W/mac.log" << 'EOF'
Test Case '-[HubKitTests.PostgresTests testReadyOnlyAfterMigration]' passed (0.100 seconds).
/x/DMSOCRToolTests.swift:17: -[HubKitTests.DMSOCRToolTests testScan] : Test skipped - OCR-Test übersprungen: tesseract nicht installiert
Test Case '-[HubKitTests.DMSOCRToolTests testScan]' skipped (0.001 seconds).
	 Executed 2 tests, with 1 test skipped and 0 failures (0 unexpected) in 0.101 (0.102) seconds
EOF
cat > "$W/linux.log" << 'EOF'
Test Case 'PostgresTests.testReadyOnlyAfterMigration' passed (0.1 seconds)
/x/DMSSearchTests.swift:482: DMSSearchTests.testPerf : Test skipped: AK-S1-7 Messlauf übersprungen
Test Case 'DMSSearchTests.testPerf' skipped (0.0 seconds)
	 Executed 2 tests, with 1 test skipped and 0 failures (0 unexpected) in 0.1 (0.1) seconds
EOF
expect 0 "AK-ST1-1 grünes Protokoll (macOS-Format)" report "$W/mac.log"
contains "tesseract nicht installiert" "AK-ST1-1 Übersprungene mit Grund sichtbar (macOS)"
expect 0 "AK-ST1-1 grünes Protokoll (Linux-Format)" report "$W/linux.log"
contains "DMSSearchTests.testPerf" "AK-ST1-1 Übersprungene mit Namen sichtbar (Linux)"

# großes Protokoll wie in der CI: ein früher Treffer darf die Auswertung nicht durch eine abgebrochene Pipe kippen
{ cat "$W/linux.log"; awk 'BEGIN { for (i = 0; i < 20000; i++) printf "Test Case %cHealthTests.testSynthetic%d%c passed (0.1 seconds)\n", 39, i, 39 }'; } > "$W/big.log"
expect 0 "AK-ST1-1 großes Protokoll bleibt grün" report "$W/big.log"

GITHUB_STEP_SUMMARY="$W/summary.md" scripts/check-test-report.sh "$W/linux.log" > "$W/out" 2>&1 || true
if grep -qF "DMSSearchTests.testPerf" "$W/summary.md" 2> /dev/null; then ok "AK-ST1-1 Übersprungene in der Lauf-Zusammenfassung"; else fail "AK-ST1-1 Übersprungene in der Lauf-Zusammenfassung"; fi

# eine einzige Datenbank-Klasse übersprungen, PostgresTests lief: trotzdem rot
{ cat "$W/linux.log"; echo "/x/AuthTestSupport.swift:124: AuthTests.testLogin : Test skipped: Keine Postgres-Datenbank erreichbar"; } > "$W/partial.log"
expect 1 "AK-ST1-1 einzelner Datenbank-Test übersprungen ist rot" report "$W/partial.log"
{ cat "$W/mac.log"; echo "/x/MigrationRoleTests.swift:34: -[HubKitTests.MigrationRoleTests testRoles] : Test skipped - Test-Benutzer darf keine Rollen/Datenbanken anlegen (CREATEROLE und CREATEDB nötig)"; } > "$W/role.log"
expect 1 "AK-ST1-1 fehlende Datenbankrechte sind rot" report "$W/role.log"
# keine Datenbank: alle Postgres-Tests übersprungen, ohne bekannten Begründungstext
cat > "$W/nodb.log" << 'EOF'
Test Case 'PostgresTests.testReadyOnlyAfterMigration' skipped (0.0 seconds)
Test Case 'HealthTests.testHealth' passed (0.1 seconds)
	 Executed 2 tests, with 1 test skipped and 0 failures (0 unexpected) in 0.1 (0.1) seconds
EOF
expect 1 "AK-ST1-1 Lauf ohne Datenbanktests ist rot" report "$W/nodb.log"
grep -v "Executed" "$W/linux.log" > "$W/abort.log"
expect 1 "AK-ST1-1 abgebrochener Lauf (ohne Abschlusszeile) ist rot" report "$W/abort.log"
{ cat "$W/linux.log"; echo "Test Case 'HealthTests.testHealth' failed (0.1 seconds)"; } > "$W/failed.log"
expect 1 "AK-ST1-1 fehlgeschlagener Test ist rot" report "$W/failed.log"
: > "$W/empty.log"
expect 1 "AK-ST1-1 leeres Protokoll ist rot" report "$W/empty.log"
expect 1 "AK-ST1-1 fehlendes Protokoll ist rot" report "$W/none.log"

# ---- AK-ST1-3: Workflow-Regeln ----
wf() { # wf <Verzeichnis> <zusätzliche Zeile>
  mkdir -p "$W/$1"
  {
    printf '%s\n' 'on: [push, pull_request]' 'permissions:' '  contents: read' 'jobs:' '  a:' '    runs-on: ubuntu-24.04' '    steps:'
    printf '%s\n' '      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1' "$2"
  } > "$W/$1/ci.yml"
}
wf good '      - run: echo ok'
wf tag '      - uses: actions/setup-node@v7'
wf secret '      - run: echo ${{ secrets.TOKEN }}'
wf push '      - run: docker push example/image'
wf bpush '      - run: docker buildx build --push .'
wf release '      - run: gh release create v1'
wf write '      - run: echo ok'
sed 's/contents: read/contents: write/' "$W/write/ci.yml" > "$W/write/w" && mv "$W/write/w" "$W/write/ci.yml"
wf noperm '      - run: echo ok'
grep -v -e '^permissions:' -e 'contents: read' "$W/noperm/ci.yml" > "$W/noperm/n" && mv "$W/noperm/n" "$W/noperm/ci.yml"
wf target '      - run: echo ok'
sed 's/pull_request]/pull_request_target]/' "$W/target/ci.yml" > "$W/target/t" && mv "$W/target/t" "$W/target/ci.yml"
mkdir -p "$W/leer"

expect 0 "AK-ST1-3 erlaubter Workflow" scripts/check-workflows.sh "$W/good"
expect 1 "AK-ST1-3 Action nur auf Tag gepinnt" scripts/check-workflows.sh "$W/tag"
expect 1 "AK-ST1-3 Secret" scripts/check-workflows.sh "$W/secret"
expect 1 "AK-ST1-3 Image-Push" scripts/check-workflows.sh "$W/push"
expect 1 "AK-ST1-3 Image-Push über buildx" scripts/check-workflows.sh "$W/bpush"
expect 1 "AK-ST1-3 Release" scripts/check-workflows.sh "$W/release"
expect 1 "AK-ST1-3 Schreibrecht" scripts/check-workflows.sh "$W/write"
expect 1 "AK-ST1-3 ohne permissions-Block" scripts/check-workflows.sh "$W/noperm"
expect 1 "AK-ST1-3 pull_request_target" scripts/check-workflows.sh "$W/target"
expect 1 "AK-ST1-3 keine Workflow-Datei ist rot" scripts/check-workflows.sh "$W/leer"
expect 0 "AK-ST1-3 Workflows dieses Repos" scripts/check-workflows.sh

if [ "$fails" != 0 ]; then echo "test-ci-gates: $fails Fehler" >&2; exit 1; fi
echo "test-ci-gates: ok"
