#!/usr/bin/env bash
# Lokale Baseline-Prüfung (WP-K0, H7): shellcheck, OpenAPI-YAML und PWA (Node), Build, Tests. Build-Artefakte außerhalb des Repos.
# LH_CI_PWA=1 erzwingt die Node-Schritte (fehlt node: Fehler), LH_CI_PWA=0 lässt sie aus; ohne Angabe laufen sie, wenn node vorhanden ist.
set -euo pipefail
cd "$(dirname "$0")/.."
export LH_SCRATCH="${LH_SCRATCH:-${TMPDIR:-/tmp}/labhub-build}"

shellcheck deploy/*.sh scripts/*.sh docker-entrypoint.sh
scripts/test-ci-gates.sh   # WP-ST1: Prüfungen der GitHub-CI (Testprotokoll, Workflow-Regeln)
scripts/check-env-docs.sh   # WP-H9: jede gelesene Umgebungsvariable ist dokumentiert
scripts/backup-restore-test.sh   # WP-H2: Backup/Restore mit Hash-Prüfung (Wegwerf-Datenbanken, Postgres wie für die Tests)

case "${LH_CI_PWA:-auto}" in
    0) echo "ci: Node-Schritte (OpenAPI-YAML, PWA) ausgelassen (LH_CI_PWA=0)" ;;
    1 | auto)
        if command -v node > /dev/null 2>&1 && command -v npm > /dev/null 2>&1; then
            npm --prefix pwa ci
            node scripts/check-openapi-yaml.mjs
            npm --prefix pwa run check   # enthält die Prüfung, dass src/lib/api/types.ts zum Vertrag passt
            npm --prefix pwa test
        elif [ "${LH_CI_PWA:-auto}" = 1 ]; then
            echo "ci: LH_CI_PWA=1, aber node/npm fehlt" >&2
            exit 1
        else
            echo "ci: node/npm nicht vorhanden, OpenAPI-YAML- und PWA-Prüfung ÜBERSPRUNGEN" >&2
        fi
        ;;
    *) echo "ci: LH_CI_PWA muss 0 oder 1 sein" >&2; exit 1 ;;
esac

cd backend
# WP-ST3 (AK-ST3-2): ein Import eines nicht deklarierten Targets (z. B. Modul → Modul) bricht den Build ab
swift build --scratch-path "$LH_SCRATCH" --explicit-target-dependency-import-check=error
swift test --scratch-path "$LH_SCRATCH" --explicit-target-dependency-import-check=error
cd ..
scripts/check-third-party-notices.sh "$LH_SCRATCH/checkouts/swift-nio-ssl"
# WP-H1: SBOM/SPDX-Inventar reproduzierbar und vollständig (Quelle: Package.resolved, package-lock.json, Checkouts des Builds)
if command -v node >/dev/null 2>&1; then
    LH_SCRATCH="$LH_SCRATCH" node scripts/generate-sbom.mjs --check
else
    echo "ci: node fehlt, SBOM-Prüfung übersprungen" >&2
fi
