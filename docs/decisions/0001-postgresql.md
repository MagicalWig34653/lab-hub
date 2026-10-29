# ADR 0001: PostgreSQL als Datenbank

Status: entschieden (Nutzer, 28.10.2026).

**Kontext.** Das DMS braucht deutsche Volltextsuche, die Rechnungsfachlogik braucht Invarianten (eindeutige Nummer je Serie unter finalen Belegen, atomarer Zähler), Updates beim Kunden müssen sicher zurückrollen. `timetrack-backend` nutzt MariaDB.

**Entscheidung.** PostgreSQL für den Hub. Gründe: `tsvector`/`pg_trgm` für Suche, Teil-Indizes, transaktionale DDL, `jsonb`, `pgvector` für spätere lokale KI-Suche, Fluent-Postgres-Treiber.

**Folgen.** Zweiter Datenbankmotor neben `timetrack-backend` (MariaDB); gemeinsamer Kern darf nicht an einen Motor gebunden sein. Einzelinstanzen ohne Postgres sind nicht vorgesehen (kein SQLite-Modus im Hub). Selbst gehostete Kunden brauchen eine Postgres-Instanz (im Compose-Stack enthalten).

**Offen.** Vergleichstest der Suche mit synthetischen deutschen OCR-Texten bleibt als Qualitätsprüfung, ändert aber die Entscheidung nicht ohne neue Begründung.
