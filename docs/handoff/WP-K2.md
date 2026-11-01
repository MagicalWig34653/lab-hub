# Übergabe WP-K2 (Mandanten und Rechte)

Stand 01.11.2026, Branch `wp-K2` (aufgesetzt auf lokalen `main`, Commit 4ee9d63 = WP-K1). `scripts/ci.sh` lief grün mit `TEST_DB_NAME=labhub_k2`: 90 Tests, 0 Fehler (78 aus K1 und früher, 12 neu in `Tests/HubKitTests/Tenancy/TenantTests.swift`). Test und Implementierung entstanden in derselben Session (kein separat belegter Rot-Lauf).

## Umgesetzt (`backend/Sources/HubKit/Tenancy/`)
- `Roles.swift`: feste Standardrollen `owner, accountant, member, tax_advisor, customer_viewer` (F-12) und Berechtigungskatalog `<modul>.<ressource>.<aktion>` mit Zuordnung Rolle -> Berechtigungen. Der Kern deklariert vorerst auch die absehbaren Modul-Berechtigungen (dms, invoice, contact); mit WP-K3 deklarieren Module selbst. `customer_viewer` hat nur `tenant.tenant.read` (Objekt-Freigaben `grants` kommen mit dem ersten Modul, die Tabelle ist bewusst noch nicht angelegt).
- `TenancyMigrations.swift`: `013_tenants` (`tenants`, `memberships`, `users.is_operator`, `invitations.tenant_id/role`), `schema_version` 12 -> 13, Revert vorhanden (stellt `is_admin` aus `is_operator` wieder her). Bestand aus K1 wird übernommen: Mandant "Hauptmandant", ehemalige Admins -> Owner und Betreiber, übrige -> Member, offene Einladungen -> Member.
- `TenantGuard.swift`: `TenantGuard` (Mitgliedschaft und Berechtigung bei jeder Anfrage frisch aus der DB, kein Cache) und `TenantRouteBuilder`: Mandantenrouten entstehen nur zusammen mit ihrer Berechtigung und stehen in `app.tenantRoutes` (Quelle der generierten Matrix). Kein Mitglied, unbekannter, ungültiger oder deaktivierter Mandant: 404; Mitglied ohne Berechtigung: 403. `req.require("…")` für feinere Prüfungen in Handlern.
- `TenancyService.swift`, `TenancyRoutes.swift`: `GET/POST /tenants`, `GET /tenants/{tenant}`, `GET /tenants/{tenant}/members`, `PATCH|DELETE /tenants/{tenant}/members/{user}`, `POST /tenants/{tenant}/invitations`. Rollenänderung/Entfernen sperrt die Mandantenzeile (`FOR UPDATE`), prüft die Akteursberechtigung erneut und schützt den letzten Owner (409 `last_owner`), mit Audit-Eintrag.
- Geändert in K1-Dateien: `AuthCore` (`isOperator` statt `isAdmin`, `RequireSession(operator:)`), `AuthService` (Bootstrap legt ersten Mandanten an, Registrierung legt Mitgliedschaft laut Einladung an, `createInvitation(tenant:role:)`, optional `tenant_name` beim Bootstrap), `AuthRoutes` (Session-Antwort mit `is_operator` und `memberships`; `POST /invitations` entfällt zugunsten der Mandantenroute), `Routes.swift`, `Migrations.swift`, `API/Problem.swift` (Code `last_owner`), `contracts/openapi.yaml`.

## Entscheidung (bitte bestätigen): Ablösung von `users.is_admin`
Der Bootstrap-Nutzer wird **Betreiber (`users.is_operator`) und Owner des ersten Mandanten**. Begründung: Ein Nutzer ohne Betreiberflag könnte keinen zweiten Mandanten anlegen (F-28: mehrere Unternehmen je Server), und Mandanten-Owner sollen nicht automatisch Server-Weites tun dürfen. Das Betreiberflag hat genau ein Recht (`POST /tenants`); alles andere läuft über Mandantenrollen. Einladen kann nur, wer im Mandanten `tenant.member.invite` hat (Owner). Die Spalte `users.is_admin` bleibt als toter Expand-Rest bestehen (wird nicht gelesen/geschrieben) und fällt in einer späteren Contract-Migration (014), sobald kein Server mehr mit K1-Code läuft.

## Tests (Name nennt die AK-ID)
AK-K2-1: Katalogkonsistenz; Matrix Rolle x Route (5 Rollen x 5 Mandantenrouten, abwechselnd auf zwei Instanzen, Erfolgsstatus bzw. 403 `forbidden`; die Route-Liste kommt aus der Registry, eine Route ohne Probe lässt den Test scheitern). AK-K2-2: Mandantentrennung mit zwei Mandanten und fremden Nutzer-IDs (alle Routen 404, keine Nebenwirkung in DB), unbekannte/ungültige/deaktivierte Mandanten 404, Listen nur eigene. Zwei-Instanzen-Test für Mitgliedschaftsänderung (Herabstufen, Hochstufen, Entfernen wirken sofort auf der anderen Instanz); letzter Owner inkl. paralleler gegenseitiger Herabstufung; Notfall-Sitzung bleibt ausgeschlossen; Einladung bindet Mandant/Rolle; Migration (Version 13, Revert, Backfill, Revert mit Daten); DB-Constraints.

## Änderungen an bestehenden Tests (nicht abgeschwächt)
- `AuthTests`: `is_admin`-Prüfungen ersetzt durch `is_operator` plus Rolle in `memberships` (stärker); Migrationstest Version 12 -> 13 und Revert/Prepare von `CreateTenants` ergänzt.
- `AuthPermissionTests`: Matrix um die neuen Routen erweitert (`.tenant`: anonym 401, Notfall 403, fremder Mandant 404; `.operator` statt `.admin`); Einladungsprüfungen laufen über die Mandantenroute.
- `AuthTestSupport`: `HubTestDB.tables` enthält `memberships`, `tenants`; `invite(...)` lädt in einen Mandanten ein. `ObjectStoreTests.testFilesTableDedupAndMigrationRevert`: `CreateTenants` in der Rücknahmeliste ergänzt.

## Offen
- AK-K2-3 (Postgres Row Level Security, F-15) nicht durchgeführt: Spike offen, nicht Voraussetzung. Mandantenfilter bleibt in der Anwendungsschicht.
- Bestehende Nutzer einem weiteren Mandanten hinzufügen (Einladung gilt nur für neue Nutzer), Mandant umbenennen/deaktivieren per API, Nutzer deaktivieren: nicht Teil dieses WP.
- Objekt-Freigaben (`grants`) für Kunden/Steuerberater folgen mit dem ersten Fachmodul.
- Mitgliederliste ohne Cursor-Pagination (kleine Mengen); bei Bedarf auf `PageEnvelope` umstellen.
- Kein Reviewer-Lauf; empfohlen (Schwerpunkte: Guard-Reihenfolge 404/403, letzter-Owner-Sperre).
- Nächster Schritt: WP-K3 (Modul-System) nutzt `TenantRouteBuilder`/`Permissions`; WP-F1 nutzt `memberships` der Session-Antwort.
