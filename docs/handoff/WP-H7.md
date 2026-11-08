# Übergabe WP-H7 (Flaky-Test und Vertrags-YAML-Prüfung)

Stand 08.11.2026, Branch `wp-H7` (auf `main`, Commit 931b374). Test-DB `labhub_h7`. Kein Reviewer-Lauf.

## Befund 1: `testTwoWorkersCompleteEachRunExactlyOnce` (echter Fehler, kein Hänger)
- Reproduziert: 2 von 6 isolierten Läufen scheiterten nach 60 s. Datenbankzustand danach: alle 8 Jobs `done`, aber ein Prüflauf `failed` mit Bericht `chain.problem = head_mismatch`; der Test wartet auf 8x `passed` und läuft daher in die Zeitüberschreitung. Worker, Lease und Wakeup sind unbeteiligt (jeder Job genau einmal, `attempts = 1`).
- Ursache: `DMSAuditChain.verify` las die Kettenglieder (Stapel) und danach den Kopf `dms_audit_heads` in getrennten Anweisungen (READ COMMITTED). Jeder abgeschlossene Prüflauf schreibt selbst ein Audit-Ereignis `dms.integrity.checked`, das Kette und Kopf im selben Commit fortschreibt. Committete ein paralleler Lauf zwischen beiden Lesevorgängen, war der Kopf neuer als die geprüfte Kette: falsches `head_mismatch`. Betrifft jede Prüfung neben schreibendem Betrieb, nicht nur den Test.
- Fix (`DMSAuditChain.swift`): Kopf zuerst lesen und die Glieder nur bis zu dessen Folgenummer prüfen (Kette und Kopf werden atomar fortgeschrieben, spätere Lesevorgänge sehen mindestens alle Glieder bis zum Kopf). Manipulationserkennung unverändert (Kürzen, Umbiegen, Kopf-Abweichung). Kein Timeout geändert.
- Neuer Regressionstest `testVerifyIsConsistentWhileChainGrows` (60 parallele Aufgaben: Schreiber und Prüfer über zwei Instanzen); ohne Fix 3 von 3 Läufen rot, mit Fix 5 von 5 grün.

## Befund 2: Vertrag
- Neu `scripts/check-openapi-yaml.mjs`: lädt `contracts/openapi.yaml` mit js-yaml (transitive Abhängigkeit von `openapi-typescript`, keine neue Abhängigkeit; doppelte Schlüssel sind Fehler) und verlangt `openapi` und `paths`. Fehlt `pwa/node_modules`: klare Meldung, Exit 2. Gegenprobe: die Vertragsdatei von Commit 677793e (unquotiertes `{"limit": n}`) wird mit Zeile 1880 abgelehnt.
- `scripts/ci.sh`: nach shellcheck `npm --prefix pwa ci`, YAML-Prüfung, `npm --prefix pwa run check` (enthält die Aktualitätsprüfung von `types.ts`), `npm --prefix pwa test`; `LH_CI_PWA=0` aus, `1` erzwingt, sonst automatisch bei vorhandenem `node`. Dokumentiert in `AGENTS.md` Abschnitt 3.

## Offen
- Ohne `node` überspringt `ci.sh` (ohne `LH_CI_PWA=1`) die Node-Schritte mit Warnung; CI sollte `LH_CI_PWA=1` setzen.
