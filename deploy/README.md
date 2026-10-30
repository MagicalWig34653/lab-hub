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

**Status:** Betriebsart 3 (Compose) am 2026-10-30 real mit Docker (colima) getestet: setup.sh non-interaktiv, Stack-Start (db, migrate, backend), `/health` und `/ready` 200, `update.sh` mit Image-Wechsel (Migration, Neuerstellung, `/ready`). Gefunden und behoben: lokales Image ohne Registry ließ `update.sh` am Pull scheitern (jetzt Rückfall auf lokales Image); Port/Adresse des Backends sind per `LH_BACKEND_PORT`/`LH_BACKEND_BIND` setzbar und stehen in `.env`. Swarm (Betriebsarten 1 und 2) ist weiterhin ungetestet (`docker swarm init` auf dem gemeinsam genutzten colima bewusst nicht ausgeführt). Skripte sind mit `shellcheck` geprüft. Das Image baut (`swift:6.2`), und `migrate` (Advisory Lock, Exit-Code 0/1), `DB_*`/`_FILE`, `/ready` sind lokal gegen Postgres 17 getestet (Docker, read-only Root, Secret-Datei). Variablen: DB_HOST, DB_PORT, DB_NAME, DB_USER, DB_PASSWORD(_FILE), DB_TLS (disable|require), SECRET_KEY(_FILE), AUTO_MIGRATE, PUBLIC_URL, WEBAUTHN_RP_ID.
