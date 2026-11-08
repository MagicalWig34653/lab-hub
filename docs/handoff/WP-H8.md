# Übergabe WP-H8 (Migrationen mit normaler Einzelrolle)

Stand 08.11.2026, Branch `wp-H8` (auf `main`, Commit 285fbba). Test-DB `labhub_h8`. Kein Reviewer-Lauf.

## Befund und Reproduktion
- Befund aus WP-F5: `dms_021_revision` scheitert mit `permission denied for table audit_log`, wenn die Datenbankrolle eine normale Einzelrolle ist (so legt `setup.sh`/Swarm sie an). Tests und Compose-Dev laufen als Superuser und merkten es nicht.
- Reproduziert (ausgeführt): Rolle `NOSUPERUSER NOCREATEDB NOCREATEROLE LOGIN` als Eigentümerin einer leeren Datenbank, `App migrate --yes` gegen Postgres 127.0.0.1:15432. Migrationen bis `dms_020` liefen, dann: `CREATE CONSTRAINT TRIGGER audit_log_dms_chain AFTER INSERT ON audit_log …` -> SQLSTATE 42501 `permission denied for table audit_log`.
- Ursache: `018_audit_hardening` (H6) macht `REVOKE ALL … FROM CURRENT_USER` und gibt nur SELECT, INSERT zurück. `CREATE TRIGGER` braucht das TRIGGER-Recht auf der Tabelle, auch für die Eigentümerin. Ein Superuser umgeht das.

## Lösung
- Neue Kernmigration `019_audit_trigger_privilege` (`RestoreAuditTriggerPrivilege`, `AuthMigrations.swift`): `GRANT TRIGGER ON audit_log TO CURRENT_USER`; Revert `REVOKE TRIGGER`. Keine `schema_version`-Änderung (nur Rechte, wie 016/018). 018 bleibt unverändert (ausgelieferter Name).
- Begründung der Variante (gegen „jede Migration vergibt/entzieht TRIGGER selbst"): Die Eigentümerin kann sich jedes Recht ohnehin per `GRANT` zurückholen und Trigger per `ALTER TABLE … DISABLE TRIGGER` abschalten; das TRIGGER-Recht war daher kein Schutz. Eine Folgemigration an einer Stelle deckt alle heutigen und künftigen Migrationen ab (kein Muster, das jede künftige Migration kennen muss) und repariert bestehende Installationen, die 018 schon angewandt haben (Kern-Migrationen laufen vor Modulmigrationen, 019 liegt vor `dms_021`). Die H6-Hürde gegen DML bleibt: UPDATE, DELETE, TRUNCATE sind weiter entzogen; die Trigger aus 011 bleiben zweite Schicht; echter Schutz weiter nur mit getrennten Rollen (`deploy/README.md`).
- Nummer 019 ist die nächste freie Kernnummer; D4 (`api_tokens`) kann kollidieren, beim Rebase die Nummer lösen (Name und Reihenfolge in `Migrations.swift` anpassen; der Test sucht die Migration über den Namen `019_audit_trigger_privilege`).

## Tests (neu: `MigrationRoleTests`, 4 Tests)
- Legt Rolle (zufälliger Name und Passwort, nicht privilegiert) und eigene leere Datenbank an und entfernt beides im `tearDown`; Skip mit klarer Meldung nur, wenn der Test-Benutzer weder Superuser noch CREATEROLE+CREATEDB hat.
- Frische Installation: komplette Migration mit der Einzelrolle, `schemaIsCurrent`, Rechte (kein UPDATE/DELETE/TRUNCATE, TRIGGER/INSERT/SELECT), Trigger `audit_log_no_change` und `audit_log_dms_chain` vorhanden, zweiter Lauf No-op.
- Bestehende Installation: Zustand nach 018 (nur Kernmigrationen bis 018, TRIGGER fehlt) -> volle Migration repariert.
- Revert von 019. Gegenprobe (ausgeführt): ohne 019 in der Liste schlägt der Volltest mit `permission denied for table audit_log` fehl.

## Offen
- Eine Installation, bei der `dms_021_revision` mit dem Fehler schon abgebrochen ist, hat die DDL teilweise angewandt (nicht transaktional): Wiederholung scheitert dann an `column "retention_until" … already exists` (beim Wiederholen der Reproduktion beobachtet). Eine robuste Variante (`dms_021` idempotent oder transaktional) gehört dem DMS-Besitz (D4/D5), hier nicht geändert; Hinweis in `deploy/README.md`.
- `deploy/setup.sh` unverändert (legt bereits eine normale Rolle an; nichts zu ändern).
