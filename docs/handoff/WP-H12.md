# WP-H12 – Übergabe (Codex-Befunde 7 und 10)

Stand 17.11.2026, Branch `wp-H12`. Befund 8 (OCR-Quarantäne) bewusst nicht angefasst.

## Befund 7: Idempotency-Key
- Migration `021_idempotency_lease` (Expand-only): `idempotency_keys.locked_at` (Standard `now()`, vorhandene Zeilen = `created_at`), Index auf `created_at`. Revert vorhanden. `schema_version` unverändert (wie 020; Tests prüfen 17).
- `IdempotencyService(db, leaseSeconds: 300)`: `in_progress` ist eine Lease. Nach Ablauf übernimmt die Wiederholung mit gleichem Hash per `UPDATE ... RETURNING` (genau ein Gewinner, DB-Zeit); frische Lease liefert `inProgress`; abweichender Hash bleibt `keyReusedWithDifferentRequest`.
- `executeAtomic`: Fachänderung, Key und `done` in einer Transaktion (Absturz/Fehler rollt alles zurück). Noch von keinem Aufrufer genutzt (DMSUpload/Middleware außerhalb des Dateibesitzes); mit `execute` muss `work` nach Absturz wiederholbar sein.
- `purgeExpired(retentionSeconds: 7 Tage, limit: 500)`: läuft nebenbei bei etwa jedem 50. Anlegen eines Keys. Ein eigener periodischer Job ist offen (Wunsch an den Orchestrator).
- Grenze: dauert `work` länger als die Lease (300 s), kann eine Wiederholung parallel übernehmen; kein Heartbeat.

## Befund 10: Quellen nach DMS-Wiedereinschalten
- `DMSModule.onActivate`: für jede `enabled` Quelle des Mandanten `DMSSources.schedule(...)` (legt nur an, wenn kein queued/running Job existiert).

## Tests (backend/Tests/HubKitTests/H12Tests.swift)
AK-H12-1..5 (Takeover, frisch/Hash, zwei Instanzen, atomar, Purge), AK-H12-6 (Reaktivierung, genau ein Job je aktive Quelle, zweiter Aufruf ohne Effekt).
