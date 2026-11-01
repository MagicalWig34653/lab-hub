# Übergabe WP-K1 (Auth)

Stand 01.11.2026, Branch `wp-K1`. Status: AK-K1-1…8 umgesetzt und getestet. `scripts/ci.sh` lief grün (78 Tests, 0 Fehler, 0 übersprungen; davon 31 neu in `Tests/HubKitTests/Auth/`). Der Lauf erfolgte mit `TEST_DB_NAME=labhub_k1` (eigene Datenbank auf dem Test-Postgres), weil parallele Agents dieselbe Datenbank `labhub` zurücksetzen und sich sonst gegenseitig stören. Test und Implementierung entstanden in derselben Session (kein belegter Rot-Lauf vor der Umsetzung).

## Umgesetzt (alles unter `backend/Sources/HubKit/Auth/`)
- `PasskeyService.swift`: Wrapper-Protokoll `PasskeyService` (JSON-Ebene, keine Bibliothekstypen nach außen) und `WebAuthnPasskeyService` (webauthn-swift, UV Pflicht, Resident Key, Cross-Origin abgelehnt, attestierte Credential-ID per SwiftCBOR an die Hülle gebunden). Nur hier wird `WebAuthn` importiert (F-04).
- `AuthMigrations.swift`: `006_users`, `007_passkey_credentials`, `008_sessions`, `009_invitations`, `010_recovery_codes`, `011_audit_log`, `012_auth_support` (`auth_challenges`, `rate_limit_events`). Nur neue Tabellen (Expand), `schema_version` 5 → 12, jeder Revert setzt die Version zurück (Test `testMigrationsSetSchemaVersionAndRevert`). `audit_log`: Trigger verweigern UPDATE/DELETE/TRUNCATE.
- `AuthService.swift`: Bootstrap (Advisory-Lock, genau ein erster Nutzer), Registrierung per Einladung (atomares Einlösen), Passkey-Login, Sitzungen (nur Hash in der DB, Ablauf/Challenges/Rate-Limit mit DB-`now()`), Recovery-Codes (SHA-256-Hash je Nutzer, einmalig), Notfall-Sitzung (30 min, nur Session lesen/abmelden/Passkey anlegen; Anlegen stuft zur normalen Sitzung hoch), Passkey-Liste/Widerruf (letzter bleibt).
- `AuthCore.swift`: `AuthSettings` (aus `PUBLIC_URL`, `WEBAUTHN_RP_ID`, `SETUP_TOKEN`), `SessionMiddleware` (Bearer oder Cookie `lh_session`, CSRF-Header bei Cookie + schreibender Methode), `RequireSession` (Default-Deny für Notfall-Sitzungen, `admin:`), DB-Rate-Limit mit Advisory-Lock je Schlüssel.
- `Audit.swift`: `AuditLog.record`, `AuditEvent` (Meta nur Zahlen/Kennzeichen `[A-Za-z0-9_.:-]{1,64}`, sonst `invalid`), `AuditLogCounterHook` (implementiert `CounterAuditHook` aus WP-K6 gegen `audit_log`, gleiche Transaktion).
- `AuthRoutes.swift`: 19 Operationen unter `/api/v1` (siehe `contracts/openapi.yaml`). Offene Routen (`auth/bootstrap|register|login|recovery`) laufen durch das Rate-Limit.
- Geändert außerhalb `Auth/`: `Config.swift` (`SETUP_TOKEN`), `Routes.swift` (Registrierung, `authSettings`), `API/Problem.swift` (neue Codes, 429, `HubError.headers`), `Migrations.swift` (Liste, `run` nicht mehr private), `Package.swift`/`Package.resolved`, `contracts/openapi.yaml`, `docs/LIZENZEN.md`.

## Tests (Name nennt die AK-ID)
AK-K1-1 (Token, kein Fenster danach, ohne Token 404, parallel genau ein Nutzer), K1-2 (Login, fremder Schlüssel, Replay, Zähler-Regression, falscher userHandle, Challenge-Ablauf per DB-Zeit, Challenge auf Instanz 1/Prüfung auf Instanz 2, Passkey hinzufügen/widerrufen), K1-3 (Einmal-Link, Ablauf, Ablauf zwischen Schritten, zwei parallele Registrierungen, Handle-Konflikt verbraucht Einladung nicht), K1-4 (Codes nur als Hash, einmalig, Ersetzen, Notfall-Sitzung), K1-5 (Sitzung auf Instanz 2, Logout global, Ablauf per DB-Zeit, Cookie/CSRF), K1-6 (Limit über zwei Instanzen, 20 parallele Anfragen → genau 5 erlaubt, Fenster per gealterten DB-Zeilen), K1-7 (alle Geräte, nur eigener Nutzer, einzelne Sitzung, fremde ID 404), K1-8 (kein Handle/Name/Token/Code/IP im Audit, UPDATE/DELETE/TRUNCATE scheitern, Counter-Hook inkl. Rollback). `AuthPermissionTests`: Matrix muss alle `/api/v1`-Routen abdecken; anonym 401, normaler Nutzer auf Admin-Route 403, Notfall-Sitzung 403 außer Allow-Liste, fremde Objekte 404, 503 ohne Konfiguration. Virtueller Authenticator: `Tests/HubKitTests/Auth/AuthTestSupport.swift` (ES256, eigene Umsetzung nach Vorbild `timetrack-backend/Tests/.../SoftwareAuthenticator.swift`).

## Änderungen an bestehenden Tests (nicht abgeschwächt)
- `PostgresTests`/`ObjectStoreTests`: Aufräumliste ist jetzt `HubTestDB.tables` (enthält die Auth-Tabellen; sonst scheitert `CREATE TABLE users` im nächsten Lauf).
- `ObjectStoreTests.testFilesTableDedupAndMigrationRevert` (WP-D1): nimmt vor der Prüfung „Version 5“ die Auth-Migrationen zurück und wendet sie am Ende wieder an (Aussage über `files` unverändert). Beim Merge mit `wp-D1` ggf. Konflikt in dieser Datei.
- `ContractTests.testAKK4_1_MissingRouteIsDetected`: „actual“ ist nun der dokumentierte Vertragsstand statt einer festen Dreierliste (Aussage unverändert: erfundene Route wird als fehlend im Server erkannt).

## Entscheidungen und Annahmen (bitte bestätigen)
- `users.is_admin` ist ein Übergang: der Bootstrap-Nutzer ist Admin und darf Einladungen erzeugen. WP-K2 ersetzt das durch Rollen/Mandanten; Nutzer sind global, `tenant_id` fehlt hier bewusst (Mandantenfilter ab K2).
- Einladung kennt noch keine Rolle/Mandant (kommt mit K2). E-Mail wird nicht erfasst (nicht benötigt).
- Sitzungs-TTL 30 Tage, Notfall-Sitzung 30 min, Einladung 7 Tage (1–720 h wählbar), Challenge 5 min, Rate-Limit 20 Anfragen/60 s je Client-Adresse (alle in `AuthSettings`).
- Token im Body nur bei `X-Auth-Transport: bearer` (Apps), sonst HttpOnly-Cookie; `Secure` nur bei `https://` in `PUBLIC_URL`.
- `swift-crypto` wurde von 5.0.3 auf 4.5.2 zurückgestuft (webauthn-swift verlangt `<5.0.0`). swift-crypto bündelt unter Linux eine eigene BoringSSL-Kopie; für F-03 (Lizenzbefund) mitprüfen.
- Docker-Test-Postgres wird parallel von mehreren Agents genutzt; eigene Datenbank pro Lauf (`TEST_DB_NAME`) empfohlen.

## Offen / Folge-WPs
- Optionales Notfall-Passwort (Argon2) und persönliche API-Tokens mit Scopes (F-05) nicht umgesetzt; ebenso E-Mail-Recovery, OIDC, OAuth-Server.
- Rate-Limit nutzt `remoteAddress`; Vertrauen in `X-Forwarded-For` hinter Reverse Proxy (Trusted-Proxy-Liste) fehlt. Hinter einem Proxy teilen sonst alle Clients einen Zähler.
- Alte Zeilen in `auth_challenges`, `rate_limit_events`, abgelaufene Sitzungen werden nicht aufgeräumt (Job später, z. B. mit WP-O1).
- Deploy: `SETUP_TOKEN`, `PUBLIC_URL`, `WEBAUTHN_RP_ID` in `deploy/` und `.env.example` dokumentieren (nicht Teil des Besitzbereichs). `AUTO_MIGRATE=false` bleibt: Migrationen 006–012 per `App migrate`.
- Kein Reviewer-Lauf; für ein sicherheitsrelevantes WP empfohlen (Schwerpunkte: Bootstrap-Race, Recovery-Session-Allow-Liste, Challenge-Bindung).
- Nächster Schritt: WP-K2 (Mandanten/Rollen) ersetzt `is_admin`; WP-F1 nutzt die Routen (`contracts/openapi.yaml`).
