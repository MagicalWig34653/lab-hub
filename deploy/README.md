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

## Quellen: Mail, Konsumordner, Share-/Scan-API (WP-D4)

Der Worker-Dienst startet `--kinds dms.ocr,dms.verify,dms.export,dms.mail.poll,dms.folder.scan` (Compose real getestet, Swarm nur Syntax). Quellen werden je Mandant über die API angelegt (`/api/v1/tenants/{tenant}/dms/sources`, Recht `dms.source.manage`, Buchhaltung/Owner); jede Quelle ist eine Kette aus Worker-Jobs mit Lease, kein Dauerprozess und kein offener Port.

- **Mail (IMAP, implizites TLS, Port 993).** Das Passwort wird mit AES-256-GCM verschlüsselt in der Datenbank abgelegt; der Schlüssel kommt aus `SECRET_KEY` bzw. dem Secret `lh_secret_key` (Compose/Swarm reichen es an Backend und Worker durch; mindestens 16 Zeichen). **Geht der Schlüssel verloren oder wechselt er, sind die Passwörter unlesbar** (Quelle meldet `secret_unreadable`) und müssen neu eingetragen werden (`PATCH …/sources/{id}` mit `password`). Backend (Verbindungstest, Anlegen) und Worker brauchen denselben Schlüssel. Ausgehend muss der Worker (und für „Verbindung testen“ das Backend) den IMAP-Host auf Port 993 erreichen; `DMS_MAIL_HOST_ALLOWLIST` (kommagetrennt) beschränkt die erlaubten Hosts, `DMS_MAIL_CA_PATH` (Pfad einer PEM-Datei im Container, bewusst nicht `…_FILE`: der Entrypoint würde diesen Namen als Secret-Datei lesen) trägt eine eigene CA für interne Server, `DMS_MAIL_TLS_VERIFY=false` schaltet die Zertifikatsprüfung ab (nur Labor; nie je Quelle). Verarbeitet werden **ungelesene** Nachrichten (`UNSEEN`; in einem Mailprogramm gelesene Mails werden nicht aufgenommen). Nach dem Commit werden sie als gelesen markiert und, falls `processed_mailbox` gesetzt ist, verschoben (`UID MOVE`, sonst `UID COPY`); nie gelöscht. Das Zielpostfach muss existieren.
- **Konsumordner.** Ein Volume nur am Worker (`DMS_FOLDER_SOURCE`, Standard benanntes Volume `labhub-consume`, oder ein absoluter Host-Pfad), im Container unter `/mnt/consume`. Der Ordner einer Quelle liegt unter `/mnt/consume/<mandanten-uuid>/<Pfad>` (Kleinbuchstaben-UUID; so erreicht ein Mandant nie den Ordner eines anderen; Symlinks werden nicht verfolgt). Der Nutzer des Workers (UID 10001) braucht Lese-/Schreibrecht, z. B. `install -d -o 10001 -g 10001 /srv/labhub/consume/<mandanten-uuid>/eingang`. Dateien werden erst nach zwei gleichen Messungen (Größe, mtime; plus `stable_seconds`) gelesen und danach nach `processed/` (oder `failed/` bei unbekanntem Typ/zu groß) im selben Ordner verschoben. Im Backend-Container ist der Ordner **nicht** eingebunden (ADR 0003). Swarm: Volume muss auf allen Knoten mit Worker-Replik dasselbe zeigen (NFS) oder die Replik wird an einen Knoten gebunden.
- **Share-/Scan-API.** `POST /api/v1/tenants/{tenant}/dms/share` mit `Authorization: Bearer lhp_…` (persönliches Token, Scope `dms.upload`, erzeugt über `POST /api/v1/auth/api-tokens` in einer Sitzung). Kein Idempotency-Key nötig. Minimalstand F-05: nur dieser Scope, Pflichtablauf (Standard 365 Tage), Widerruf sofort. Beispiel: `curl -H "Authorization: Bearer $TOKEN" --data-binary @scan.pdf "https://hub.example.org/api/v1/tenants/$TENANT/dms/share?filename=scan.pdf"`.
- Neue Verarbeitungs-Einstellungen am Worker: `DMS_TENANT_QUOTA_BYTES`, `DMS_DEFAULT_RETENTION_YEARS` (für den Export/Prüf-Job aus D5) und `DMS_MAX_UPLOAD_BYTES` gelten wie am Backend; für Quellen wird die Größe/Quota des Mandanten ebenso durchgesetzt.

## Härtung (WP-H6)

**Reverse Proxy und Rate-Limit (`TRUSTED_PROXIES`).** Das Rate-Limit der Anmelderouten zählt je Client-Adresse. Standard: keine vertrauten Proxys, dann zählt nur die Adresse der TCP-Verbindung und `X-Forwarded-For` wird ignoriert. Steht das Backend hinter einem Reverse Proxy (Ingress, Traefik, nginx), sehen alle Clients sonst wie der Proxy aus (ein gemeinsamer Zähler). Dann `TRUSTED_PROXIES` auf die Adressen oder Netze der Proxys setzen, kommagetrennt, IPv4/IPv6, optional mit Präfix, z. B. `TRUSTED_PROXIES=10.0.0.0/8,192.0.2.7,fd00::/8` (Beispielwerte). Nur Verbindungen von diesen Adressen werden bei `X-Forwarded-For` von rechts gelesen (der erste nicht vertraute Eintrag ist der Client). Ein ungültiger Eintrag lässt den Start scheitern. Der Proxy muss `X-Forwarded-For` anhängen oder setzen, nie ungeprüft durchreichen; im Swarm ist die Quelladresse hinter dem Ingress-Netz oft die Overlay-Adresse, nicht die des Proxys: Adresse mit einem Test prüfen.

**Speicherquota je Mandant (`DMS_TENANT_QUOTA_BYTES`).** Obergrenze für die Summe aller gespeicherten Dateien eines Mandanten (Originale und abgeleitete Dateien, gleiche Bytes zählen einmal). Standard 1099511627776 (1 TiB). Überschreitung: Upload 413 mit Code `storage_quota_exceeded`. Die Grenze gilt für Uploads; vom OCR-Worker erzeugte Archivdateien zählen mit, werden aber nicht abgelehnt.

**Datenbankrollen und Audit-Log.** Die Migration `018_audit_hardening` entzieht dem Anwendungsbenutzer und PUBLIC auf `audit_log` UPDATE, DELETE, TRUNCATE und TRIGGER (übrig: INSERT, SELECT); die Trigger aus `011_audit_log` bleiben als zweite Schicht. Seit WP-H8 gibt `019_audit_trigger_privilege` dem Eigentümer TRIGGER zurück (UPDATE, DELETE und TRUNCATE bleiben entzogen): Ohne dieses Recht scheiterte `dms_021_revision` (Trigger auf `audit_log`) mit `permission denied for table audit_log`, sobald die Datenbankrolle eine normale Einzelrolle war (`CREATE ROLE … LOGIN`, wie `setup.sh` sie anlegt; Compose-Dev und Tests laufen als Superuser und zeigten es nicht). Die Migrationen laufen damit vollständig mit einer nicht-privilegierten Eigentümerrolle (kein SUPERUSER, CREATEDB oder CREATEROLE nötig); abgesichert durch `MigrationRoleTests`. Bestehende Installationen, die 018 schon angewandt haben, migrieren beim nächsten `migrate` weiter. Eine Installation, bei der `dms_021_revision` bereits mit diesem Fehler abgebrochen ist, kann einen halb angewandten Schritt hinterlassen haben (DDL ohne Transaktion, Fehler `column … already exists` beim Wiederholen): dann die Datenbank aus der Sicherung wiederherstellen oder die in `dms_021_revision` angelegten Objekte von Hand entfernen. Mit **einer** Rolle, die zugleich Eigentümerin der Tabellen ist, ist das nur eine Hürde, kein Schutz: Eigentümer können per `GRANT` oder `ALTER TABLE audit_log DISABLE TRIGGER …` alles zurückholen. Empfehlung für den Betrieb (noch nicht von `setup.sh` umgesetzt): zwei Rollen. `labhub_owner` (Eigentümerin, nur für den Migrationsjob, `DB_USER` des Dienstes `migrate`) und `labhub_app` (Laufzeit von Backend und Worker, Mitglied von nichts, ohne Eigentum). Nach jeder Migration:

```
GRANT USAGE ON SCHEMA public TO labhub_app;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO labhub_app;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO labhub_app;
REVOKE UPDATE, DELETE, TRUNCATE ON audit_log FROM labhub_app;
```

Die Laufzeitrolle darf keine DDL-Rechte haben (`CREATE` im Schema entziehen) und kein Superuser sein. Offen bleibt, dass Tabellen ohne eigene Trigger (z. B. `dms_*`) für die Laufzeitrolle voll schreibbar sind; das ist gewollt. Superuser und Eigentümer umgehen jede dieser Maßnahmen.
