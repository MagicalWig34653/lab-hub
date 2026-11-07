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

## OCR-Worker (WP-O2)

Der Worker (`App worker --kinds dms.ocr`) ist ein eigener Dienst mit eigenem Image: `Dockerfile.worker` (Ubuntu 24.04, ocrmypdf, Tesseract `deu`+`eng`, Ghostscript, poppler; Lizenzen `docs/LIZENZEN.md`). Das Backend-Image bleibt ohne OCR-Werkzeuge. Der Worker hat keinen Port, liest Aufträge per Lease aus der Datenbank und darf nur nach `/tmp` (tmpfs) schreiben (read-only Root); mehrere Worker sind sicher (jeder Auftrag wird genau einmal wirksam).

```
docker build -f Dockerfile -t ghcr.io/ORG/lab-hub:1.2.0 .          # Backend (wie bisher)
docker build -f Dockerfile.worker -t ghcr.io/ORG/lab-hub:1.2.0-worker .        # Worker; Standardname = <LABHUB_IMAGE>-worker, überschreibbar mit LABHUB_WORKER_IMAGE
```

Einstellungen (alle optional, als Umgebung des Dienstes): `OCR_TIMEOUT_SECONDS` (Gesamtzeit je Dokument, 600), `OCR_MEMORY_MB` (Adressraumlimit je Werkzeugprozess, 4096; Container-Limit zusätzlich `OCR_WORKER_MEMORY`, 6g), `OCR_MAX_PAGES` (300), `OCR_LANGUAGES` (`deu+eng`), `OCR_JOBS` (2), `OCR_DEHYPHENATE` (`false` schaltet die Silbentrennungs-Bereinigung ab), `DMS_OCR_ENABLED=false` am Backend (Uploads reihen dann keinen OCR-Job ein). Der Worker prüft beim Start Werkzeuge und Sprachpakete und beendet sich mit Fehlermeldung, wenn etwas fehlt. Objektspeicher: wie das Backend (`OBJECT_STORE*`); bei `OBJECT_STORE=fs` muss das Volume auch am Worker hängen (Compose-Datei nicht vorbereitet), sonst `db` oder später S3.

Stand: Compose-Datei real getestet (siehe `docs/handoff/WP-O2.md`); `swarm/stack.yaml` (Dienst `worker`, `WORKER_REPLICAS`) und die Swarm-Zweige in `setup.sh`/`update.sh` sind **nicht unter Swarm getestet** (nur Syntaxprüfung der Datei).
