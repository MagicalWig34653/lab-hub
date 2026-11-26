#!/usr/bin/env bash
# WP-ST1 (AK-ST1-3): Regeln für GitHub-Workflows: Actions auf Commit gepinnt, nur Leserechte, keine Secrets,
# kein Image-Push, kein Release. Aufruf: scripts/check-workflows.sh [Verzeichnis]   (Standard: .github/workflows)
set -euo pipefail
cd "$(dirname "$0")/.."

dir="${1:-.github/workflows}"
fail=0
err() { echo "FEHLER: $*" >&2; fail=1; }

shopt -s nullglob
files=("$dir"/*.yml "$dir"/*.yaml)
[ "${#files[@]}" -gt 0 ] || { echo "FEHLER: keine Workflow-Datei in $dir" >&2; exit 1; }

for f in "${files[@]}"; do
  code=$(sed 's/^[[:space:]]*#.*$//' "$f")   # reine Kommentarzeilen zählen nicht
  # jedes `uses:`, auch in Flow-Schreibweise `- { uses: ... }`
  unpinned=$(grep -E '(^|[[:space:]{,])uses:' <<< "$code" | grep -Ev 'uses:[[:space:]]+(\./|[^@[:space:]]+@[0-9a-f]{40}([[:space:],}]|$))' || true)
  [ -z "$unpinned" ] || err "$f: Action nicht auf Commit gepinnt:"$'\n'"$unpinned"
  { grep -Eq '^permissions:' <<< "$code" && grep -Eq '^[[:space:]]+contents:[[:space:]]*read' <<< "$code"; } || err "$f: permissions mit contents: read fehlt"
  ! grep -Eq ':[[:space:]]*write(-all)?([[:space:],}]|$)' <<< "$code" || err "$f: Schreibrecht"
  ! grep -Eq '(^|[^A-Za-z0-9_-])secrets([^A-Za-z0-9_-]|$)|github\.token' <<< "$code" || err "$f: Secret oder Token"
  ! grep -Eq 'docker[[:space:]]+(image[[:space:]]+|compose[[:space:]]+)?push|--push|push:[[:space:]]*true|docker/login-action' <<< "$code" || err "$f: Image-Push"
  ! grep -Eqi 'gh[[:space:]]+release|release-action|action-gh-release|create-release' <<< "$code" || err "$f: Release"
  ! grep -q 'pull_request_target' <<< "$code" || err "$f: pull_request_target"
done

[ "$fail" = 0 ] && echo "check-workflows: ok (${#files[@]} Datei(en))"
exit "$fail"
