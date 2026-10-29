# ADR 0003: Stateless Backend, Swarm-fähig mit Replicas

Status: entschieden (Nutzer, 28.10.2026). Vorbild: `timetrack-backend` (Migrationsjob, `/ready`, Secrets über `_FILE`, Job-Lease in der Datenbank).

**Regel.** Eine Backend-Instanz hält keinen Zustand, der für die Korrektheit gebraucht wird. Jede Replik kann jede Anfrage bedienen; Replikate lassen sich jederzeit starten, stoppen und neu verteilen.

**Folgen für den Entwurf.**
1. **Zustand nur in PostgreSQL oder im Objektspeicher.** Sitzungen, Tokens, Rate-Limit-Zähler, Jobs, Zähler (Rechnungsnummern) und Suchindex liegen in der Datenbank. Kein In-Memory-Cache als Wahrheit, keine Dateien im Container-Dateisystem (read-only Root, `tmpfs` für `/tmp`).
2. **Anhänge und DMS-Dateien** in einem S3-kompatiblen Objektspeicher (selbst gehostet, z. B. MinIO oder Garage) oder, für kleine Installationen, in Postgres (Large Objects/`bytea` mit Prüfsumme). Kein gemeinsames Dateisystem zwischen Repliken. Entscheidung über den Speicher als eigenes Protokoll (`AttachmentStore`), Implementierung je Betriebsart.
3. **Nummernzähler** atomar in der Datenbank (Zeilensperre oder `UPDATE … RETURNING` in einer Transaktion), nie im Speicher einer Instanz.
4. **Hintergrundarbeit** über Datenbank-Jobs mit Lease (`job_leases`, `FOR UPDATE SKIP LOCKED`); genau eine Instanz führt einen Job aus, Ausfall übernimmt eine andere. Kein Redis, kein eigener Worker-Pflichtprozess.
5. **Ereignisse zwischen Repliken** über PostgreSQL `LISTEN/NOTIFY` (Echtzeit-Updates für PWA) plus dauerhafte Ereignistabelle (Zustellung mindestens einmal, Empfänger idempotent). Kein Nachrichtenbroker als Pflicht.
6. **Migrationen nur im Migrationsjob** (`AUTO_MIGRATE=false` im Backend). Backend meldet `/ready` = 503, solange das Schema nicht passt; `/health` meldet nur Lebendigkeit. Updates: erst Job, dann rollierend die Repliken (Rückwärtskompatibilität einer Schemaversion zur vorherigen für die Dauer des Rollouts, Expand/Contract).
7. **Konfiguration und Geheimnisse** nur über Umgebung und Docker Secrets (`<NAME>_FILE`), nie im Image.
8. **Graceful Shutdown**: laufende Anfragen beenden, keine neuen annehmen, Lease freigeben.
9. **Idempotente Schreib-API** (Idempotency-Key bei finalisierenden Aktionen), weil Anfragen bei Replikawechsel wiederholt werden können.
10. **Uhren und Reihenfolge**: Zeit und Reihenfolge kommen von der Datenbank (`now()`, Sequenzen), nicht von der Instanzuhr.
11. **Sticky Sessions nicht nötig.** Der Reverse Proxy verteilt frei.

**Tests.** Mindestens: zwei Backend-Instanzen gegen eine Datenbank vergeben parallel Nummern ohne Doppelung oder Lücke (außer dokumentierter Freigabe), Job läuft genau einmal, Sitzung funktioniert auf beiden Instanzen, `/ready` schaltet bei Schemaabweichung.
