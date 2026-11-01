# Agent-Workflow (Orchestrator + Worker)

Stand 01.11.2026 (Nutzerwunsch: alles mit Agents, Hauptsession klein). Quellen: Anthropic Subagents-Doku (code.claude.com/docs/en/sub-agents), Engineering-Posts „Multi-Agent Research System“ und „Effective Harnesses for Long-Running Agents“.

## Rollen
- **Orchestrator (Hauptsession):** liest nur `docs/ROADMAP.md`, `docs/handoff/` und Kurzberichte; schreibt Briefings; startet, gated und mergt. Liest Code nur bei Eskalation.
- **Worker:** frischer Agent pro WP (kein Fork), `isolation: worktree`, Branch `wp-<ID>`. Liest zuerst `AGENTS.md` und den WP-Abschnitt.
- **Reviewer:** frischer, schreibgeschützter Agent für sicherheits-/datenrelevante WPs (Urteil pass/fail, max. 5 Befunde mit Datei:Zeile).

## Regeln
1. Ein Worker = ein WP, Dateibesitz als Pfad-Allowlist. Gemeinsame Dateien (`Package.swift`, Lockfiles, Migrationen, `contracts/openapi.yaml`, Routen-Registry) hat je Zeitraum genau ein Agent.
2. Parallel höchstens 2–3 WPs, nur mit erfüllten Abhängigkeiten und disjunktem Dateibesitz. Worker starten keine weiteren Agents.
3. Ergebnisse ins Repo: Code, Commits, `docs/handoff/WP-<ID>.md`, Statuszeile in der Roadmap. Rückgabe an den Orchestrator höchstens 10 Zeilen (Status, Branch+Commit, Testergebnis, offene Punkte).
4. Gate vor Merge: `scripts/ci.sh` grün (tatsächlich ausgeführt), Diffstat nur im Besitzbereich, Tests nie gelöscht/abgeschwächt; Reviewer, falls nötig. Max. 2 Fix-Runden, danach Eskalation an den Nutzer.
5. Merge sequenziell nach `main` (Rebase, Gate erneut). Konflikt → neuer Worker. Push nach jedem WP.
6. „Fertig“ ohne Gate gilt nicht. Bei Unklarheit nicht raten: `blocked` mit konkreter Frage.

## Briefing-Vorlage
```
Rolle: Implementierungs-Agent für WP-<ID>. Zuerst AGENTS.md und den WP-Abschnitt in docs/ROADMAP.md lesen.
Ziel: …
Akzeptanzkriterien: …
Dateibesitz: Darf ändern: <Pfade>. Nicht: alles andere (bes. Package.swift, Migrationen, openapi.yaml, ROADMAP außer eigener Statuszeile).
Regeln: Kein Secret, keine Nutzerdaten/privaten Bestandsdaten. Test zuerst, bestehende Tests nie abschwächen. Build/Test mit Scratch-Pfad.
Gate: scripts/ci.sh grün. Commit auf Branch wp-<ID>, Handoff in docs/handoff/WP-<ID>.md.
Rückgabe (max. 10 Zeilen): Status, Branch+Commit, Dateien, Testergebnis, offene Punkte.
```
