# Handoff WP-K6 – Zähler-Erweiterung

Stand 01.11.2026. Status: umgesetzt, `scripts/ci.sh` lief grün (16 Tests, 0 Fehler; 11 Postgres-Tests gegen lokales Postgres, keine übersprungen).

## Umsetzung (`backend/Sources/HubKit/Services.swift`)
- `CounterService.next(tenant:key:on:)` (String- und `CounterKey`-Variante) läuft auf der übergebenen Transaktion; Rollback setzt den Zählerstand zurück. Ohne `on:` unverändert (eigene Verbindung).
- `CounterKey(space:name:)`: Schlüsselraum, Rohschlüssel `space:name`; `space` darf kein `:` enthalten. Alte String-API bleibt kompatibel (keine Migration).
- `ensureAtLeast(tenant:key:value:reason:on:)`: hebt nur an (`GREATEST`), nie ab; sperrt die Zeile (`FOR UPDATE`), liefert Stand danach.
- Audit-Schnittstelle: Protokoll `CounterAuditHook` (`counterRaised(_:on:)`), per `CounterService(db, auditHook:)`. Aufruf nur bei tatsächlicher Änderung, auf derselben Verbindung/Transaktion. Es gibt keine Audit-Tabelle; WP-K1 (`audit_log`) liefert die Hook-Implementierung.

## Tests (`PostgresTests.swift`)
AK-K6-1 `testNextOnForeignTransaction_AK_K6_1`; K6-2 `testRollbackReleasesNumber_AK_K6_2`; K6-3 `testEnsureAtLeastOnlyRaises_AK_K6_3` und `...CallsAuditHookOnlyOnChange_AK_K6_3`; K6-4 `testTwoConnectionsThousandNumbersNoGapNoDuplicate_AK_K6_4` (2 parallele Tasks, je 50 Transaktionen à 10 Nummern, genau 1…1000).

## Offen
- Audit-Hook-Implementierung gegen `audit_log` (WP-K1/R4 Import); `ensureAtLeast` ohne Hook schreibt kein Audit.
- Namensschema der Schlüsselräume (z. B. `invoice:2026`) mit WP-R2 abstimmen; lückenlose Belegnummern setzen voraus, dass `next(on:)` in derselben Transaktion wie das Finalisieren läuft.
