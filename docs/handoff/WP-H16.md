# WP-H16: Lastempfindliche Tests stabilisieren

Stand 17.11.2026, Branch `wp-H16`. Nur Tests und Doku geändert, kein Produktcode.

## Ursachen (belegt durch Reproduktion mit 16 parallelen `yes`-Schleifen)

- `ApiPostgresTests.testIdempotencyMiddlewareParallelRunsWorkOnce`: HTTP 500 mit `PSQLError 42703 column "locked_at" does not exist` im Takeover-`UPDATE` von `replayOrTakeover` (WP-H12). Die Test-Fixture (`setUp`) legte `idempotency_keys` per Hand-`CREATE TABLE IF NOT EXISTS` ohne `locked_at` an. Der Pfad wird nur erreicht, wenn ein Request den `INSERT` verliert und die Zeile noch `in_progress` ist; unter Last passiert das häufig, im Einzellauf selten. Kein Pool-Timeout, kein Deadlock, kein Fehler der Takeover-Logik: Produktcode korrekt.
- `ExtractionTests.testHugeInputIsBounded`: Die harte Wanduhrfrist (Standard 5 s, `DMS_EXTRACT_TIMEOUT_MS`) lief unter Last ab; Ergebnis `other` (`extraction_timeout`) statt `invoice`. Unter Last in 5 von 6 Läufen reproduziert.

## Fix

- AK-H16-2: `setUp` führt `migrateWithLock(app)` aus (echtes Schema statt Hand-Tabelle). Aussage "Arbeit läuft genau einmal" und Statuscodes 201/409 unverändert.
- AK-H16-1: `testHugeInputIsBounded` ruft `extract(..., timeout: 120)` und prüft deterministisch: Normalisierung überschreitet `maxChars`, kein Timeout, Art `invoice`, Fakten vorhanden, alle Fundstellen innerhalb `maxChars`. Die Wanduhr-Assertion entfällt (ersetzt durch das Zeichenbudget). Produktfrist unverändert; ihr Verhalten prüft `ExtractionRedosTests`.

## Hinweis

Test-Datenbanken, die vor diesem WP von der alten Fixture angelegt wurden (Tabelle ohne `locked_at`, ohne Migrationseintrag), müssen neu angelegt werden.
