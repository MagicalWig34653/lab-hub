# Übergabe WP-K4 (API-Vertrag)

Stand 01.11.2026, Branch `wp-K4`.

## Umgesetzt
- `contracts/openapi.yaml` (OpenAPI 3.1): `/health`, `/ready`, `/api/version`, Schemas `Problem`, `VersionInfo`, `PageEnvelope`, Parameter `limit`/`cursor`/`count`/`Idempotency-Key`.
- `API/Problem.swift`: `HubError`, `ProblemCatalog` (Code + deutsche Meldung), `ProblemMiddleware` (`application/problem+json`, 5xx ohne Details). `problem+json` ist als JSON-Decoder registriert.
- `API/RequestId.swift`: `X-Request-Id` (gültige eingehende ID übernommen, sonst UUID) in jeder Antwort.
- `API/Pagination.swift`: `PageCursor` (base64url, `(created_at, id)`), `HubPageRequest` (limit 1..200, Standard 50), `HubPage` (`items`, `next_cursor`, `total`). Typen heißen `Hub*`, weil `Page`/`PageRequest` mit Fluent kollidieren.
- `API/Version.swift`: `GET /api/version` (`server`, `api`, `schema`).
- `Middleware/IdempotencyMiddleware.swift`: erzwingt `Idempotency-Key`, Hash aus Methode+Pfad+Body, nutzt `IdempotencyService`; Mandant standardmäßig aus Pfadparameter `:tenant`.
- Registrierung in `Routes.swift` (Middleware-Reihenfolge RequestId, Problem; Versionsroute).

## Tests (Name nennt AK)
AK-K4-1 (Routen↔Vertrag, undokumentierte/fehlende Route erkannt), AK-K4-2 (Fehlerschema, Katalog = Vertrags-Enum), AK-K4-3 (10 000 Zeilen, parallele Einfügungen, keine Dubletten/Lücken; Seitenzahl), Idempotenz mit zwei Instanzen und parallel.

## Offen / für Folge-WPs
- Neue Routen müssen in `openapi.yaml` stehen, sonst schlägt AK-K4-1 fehl. Der Vertragsleser ist ein einfacher Zeilenparser (Pfade Einrückung 2, Methoden 4); bei Bedarf durch YAML-Bibliothek ersetzen (Package.swift gehört WP-D1).
- `IdempotencyMiddleware` speichert den Body als Text; beim Replay wird nur Content-Type gesetzt.
- Rate-Limit, ETag/If-Match, `X-Client-Api`, `Deprecation`-Header nicht umgesetzt (nicht Teil der AK).
- `HubVersion.server` ist fest "0.1.0".
