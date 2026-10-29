# Betrieb

Alle Wege starten mit `deploy/setup.sh` (stellt Fragen, erzeugt Passwörter/Schlüssel, schreibt `deploy/.env` ohne Passwörter) und werden mit `deploy/update.sh` aktualisiert. Hintergrund: `docs/decisions/0003-stateless-und-swarm.md`.

| Betriebsart | Dateien |
| --- | --- |
| 1 Swarm, Postgres im Stack | `swarm/stack.yaml` + `swarm/stack.db.yaml` (Knoten-Label `labhub-db=true`) |
| 2 Swarm, externe Postgres | `swarm/stack.yaml` |
| 3 Einzelner Docker-Host | `compose/compose.yaml` |

```
deploy/setup.sh --dry-run            # nur Plan ansehen
deploy/setup.sh --save-generated ~/labhub-secrets   # erzeugte Geheimnisse zusätzlich sichern
deploy/update.sh --image ghcr.io/ORG/lab-hub:1.2.0
```

Backend ist stateless: mehrere Repliken, rollierendes Update (start-first), Migration nur im Migrationsjob, `/ready` = 503 bis das Schema passt. Vor jedem Update die Datenbank sichern.

**Status:** Skripte sind mit `shellcheck`, Trockenlauf und einem Schreibtest ohne Docker geprüft. Ein echter Lauf mit Docker/Swarm und ein Image-Build wurden noch nicht ausgeführt; das Dockerfile ist ein ungebauter Entwurf, und das Backend kennt `migrate`, `DB_*` und `_FILE`-Variablen noch nicht (Gerüst mit `/health` und `/ready`).
