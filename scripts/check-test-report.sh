#!/usr/bin/env bash
# WP-ST1 (AK-ST1-1): Wertet das Protokoll von `swift test` aus (XCTest auf macOS oder Linux).
# Listet alle übersprungenen Tests (auch in $GITHUB_STEP_SUMMARY) und schlägt fehl, wenn der Lauf nicht vollständig war,
# ein Test fehlschlug oder Datenbanktests fehlten. Aufruf: scripts/check-test-report.sh <Protokolldatei>
set -euo pipefail

log="${1:?Aufruf: check-test-report.sh <Protokolldatei>}"
[ -s "$log" ] || { echo "FEHLER: Testprotokoll fehlt oder ist leer: $log" >&2; exit 1; }
fail=0
err() { echo "FEHLER: $*" >&2; fail=1; }

# "Test Case '-[HubKitTests.Klasse testX]' passed" (macOS) bzw. "Test Case 'Klasse.testX' passed" (Linux)
cases() { sed -n "s/^Test Case '\(.*\)' $1 (.*/\1/p" "$log"; }
passed=$(cases passed | wc -l | tr -d ' ')
skipped=$(cases skipped | wc -l | tr -d ' ')
reasons=$(sed -n 's/^.*:[0-9][0-9]*: \(.*Test skipped.*\)$/\1/p' "$log")

summary() {
  echo "Backend-Tests: $passed bestanden, $skipped übersprungen"
  if [ "$skipped" != 0 ]; then
    echo
    echo "Übersprungene Tests:"
    cases skipped | sed 's/^/- /'
    echo
    echo "Begründungen:"
    printf '%s\n' "$reasons" | sed '/^$/d; s/^/- /'
  fi
}
summary
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then summary >> "$GITHUB_STEP_SUMMARY"; fi
if [ -n "${GITHUB_ACTIONS:-}" ] && [ "$skipped" != 0 ]; then echo "::warning title=Übersprungene Tests::$skipped Tests übersprungen (Liste in der Zusammenfassung)"; fi

grep -Eq "Executed [0-9]+ tests?," "$log" || err "keine Abschlusszeile: Testlauf unvollständig"
[ -z "$(cases failed)" ] || err "fehlgeschlagene Tests im Protokoll"
if grep -Eq "Test skipped.*(Keine Postgres-Datenbank erreichbar|CREATEROLE)" "$log"; then err "Datenbanktests wurden übersprungen (Datenbank oder Rechte fehlen)"; fi
# ohne -q: grep liest alles, sonst beendet SIGPIPE bei langen Protokollen die Pipe (pipefail)
cases passed | grep -E '(^|\.)PostgresTests[ .]' > /dev/null || err "kein Datenbanktest (PostgresTests) bestanden: Lauf ohne Datenbanktests"

[ "$fail" = 0 ] && echo "check-test-report: ok"
exit "$fail"
