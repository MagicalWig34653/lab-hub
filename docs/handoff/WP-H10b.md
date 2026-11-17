# Übergabe WP-H10b (API-Token an Mandanten binden, Befund 5 aus WP-H10)

Stand 17.11.2026, Branch `wp-H10b`, Test-DB `labhub_h10b`.

## Umgesetzt
- Migration `dms_026_api_token_tenant` (`CreateDMSApiTokenTenant`, DMS-Modulmigration, `schema_version` unverändert): `api_tokens.tenant_id` nullable mit FK, Teilindex; Backfill für Nutzer mit genau einer Mitgliedschaft. Revert entfernt Index und Spalte.
- `ApiTokens.authenticate` liefert die Bindung; `ApiTokenModuleGuard` prüft sie bei jeder Nutzung (anderer Mandant 404 `not_found`; ungebunden 401 `api_token_unbound`, fail-closed).
- `POST /auth/api-tokens`: optional `tenant_id` (fremd 404, ungültig 422; ohne Angabe nur bei genau einem Mandanten, sonst 422); `ApiToken.tenant_id` in der Antwort.
- Vertrag (`contracts/openapi.yaml`, Code `api_token_unbound`), `pwa/src/lib/api/types.ts` regeneriert, i18n `error.api_token_unbound` de/en.

## Tests (`ApiTokenTests`, DMSSourcesTests.swift)
- `testAKH10b_1`: Token gilt nur im gebundenen Mandanten, beide Instanzen, Inhaber in zwei Mandanten Mitglied (erlaubt/verboten).
- `testAKH10b_2`: Erstellen mit/ohne `tenant_id`, Mitgliedschaft, Mehrdeutigkeit.
- `testAKH10b_3`: Migration, Backfill, ungebundene Tokens 401, Revert/Reapply.
- Bestehende Migrations-Revert-Tests um `CreateDMSApiTokenTenant` ergänzt (nicht abgeschwächt).

## Offen
- Contract-Schritt (NOT NULL, Altbestände entfernen) in einem späteren WP.
- PWA: Token-Erstellung sendet noch kein `tenant_id` (Server nimmt bei einem Mandanten den einzigen); Mehrmandanten-Auswahl und Anzeige gehören zu F4d.
