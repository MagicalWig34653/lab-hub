# WP-BR1: Scan-Bridge, Hub-Seite

Stand 27.11.2026, auf `main`. Nur Backend und Vertrag: Tabellen, Bridge- und Nutzerrouten, Lease, Scope `dms.scan.bridge`, Recht `dms.scan.use`. **Keine Änderung der PWA-Oberfläche** (nur Typen aus dem Vertrag neu erzeugt und je ein Text pro neuem Fehlercode in `de.ts`/`en.ts`, weil der i18n-Test das verlangt). Kein Deploy, kein Image-Push. Entwurf und Festlegungen: `docs/SCAN-BRIDGE.md` Abschnitt 3.

## Commits

| Commit | Inhalt |
| --- | --- |
| `db1a402` | `pwa/e2e/dms.spec.ts`: Mail-Quelle mit `imap.example.invalid` und Port 993 statt `127.0.0.1` (WP-H10 lehnt IP-Literale und andere Ports ab; Schutz unverändert, Test angepasst) |
| `38207e8` | rote Tests zu AK-BR1-1 bis BR1-4 |
| `fa2707f` | Umsetzung samt Befunden der Prüfung durch eine nicht bauende Sitzung |
| danach | E2E-Skript, diese Übergabe, ROADMAP |

## Was gebaut ist

- Migration `dms_028_scan_bridge`: `dms_scan_bridges` (ein Token = eine Bridge), `dms_scan_devices` (Gerätekennung ist ein SHA-256-Hex, nie IP oder URL), `dms_scan_jobs` (Zustand, Lease, Befehl, Ergebnis). Teilindex `dms_scan_jobs_open_device`: höchstens ein offener Auftrag je Gerät.
- Bridge-Routen (API-Token, Scope `dms.scan.bridge`, Rolle mit `dms.source.manage`): `PUT scan/bridge` (Registrieren, Geräteliste ersetzen), `POST scan/bridge/claim` (genau einmal übernehmen, `FOR UPDATE SKIP LOCKED`), `PUT scan/bridge/jobs/{job}` (Zustand, Lebenszeichen, Ergebnis; Antwort nennt Befehle des Nutzers). Das Ergebnis lädt die Bridge über die bestehende Scan-API (`POST share`, Scope `dms.upload`) mit `Idempotency-Key: scan-<job>` hoch.
- Nutzerrouten (Sitzung, Recht `dms.scan.use`, Rollen Buchhaltung und Mitglied, Eigentümer immer): `GET scan/devices`, `POST scan/jobs`, `GET scan/jobs/{job}`, `POST scan/jobs/{job}/next-page|finish|cancel`.
- Zustände: `queued → claimed → scanning ↔ waiting_for_page → uploading → done`; `failed`, `cancelled`. Lease 60 s ab `now()` der Datenbank, nie Instanzzeit. Lease abgelaufen ⇒ `failed`/`bridge_lost` (bei Abbruchwunsch `cancelled`), **nie automatische Wiederholung**; nie abgeholt nach 300 s ⇒ `failed`/`expired`. Ein spätes Ergebnis derselben Bridge macht `failed/bridge_lost` zu `done`. Der Ablauf wird bei jedem Aufruf der Routen geprüft (kein Hintergrundprozess, zustandslos nach ADR 0003).
- Vier neue Fehlercodes: `scan_device_busy`, `scan_bridge_offline`, `scan_command_invalid`, `scan_transition_invalid` (Katalog und Vertrag gleich, `ContractTests`).
- Scope-Format im Kern auf zwei bis drei Teile erweitert (`<modul>.<bereich>.<name>`), nötig für `dms.scan.bridge`.

## Akzeptanzkriterien und Belege

| AK | Beleg |
| --- | --- |
| BR1-1 Tabellen, Routen, Vertrag | Migration `dms_028_scan_bridge`; neun Operationen in `contracts/openapi.yaml` (Abschnitt „WP-BR1“); `ContractTests`, `MigrationNamesTests`, `DMSScanTests` (`DMSScanDeviceTests`, `DMSScanJobTests`) |
| BR1-2 genau einmal übernehmen, Lease, Ablauf, spätes Ergebnis | `DMSScanJobTests` (parallele Übernahme über `app1`/`app2`, Lease-Ablauf über `lease_until` in der Datenbank, kein Wiederholen, spätes `done`); E2E-Skript (zwei echte `App serve`-Prozesse) |
| BR1-3 Mandantentrennung, Rechte, Scope | `DMSScanAccessTests` (fremder Mandant 404, Rollenmatrix, Token ohne Scope 401, Sitzung statt Token und umgekehrt), Berechtigungsmatrix in `DMSTests` um alle Scan-Routen erweitert |
| BR1-4 Upload mit `scan-<job>` ergibt ein Dokument | `DMSScanResultTests` (gleichzeitige Wiederholungen über beide Instanzen: ein Dokument, Quelle `share_ext`, Herkunft Token, anderer Inhalt unter gleichem Schlüssel 422); E2E-Skript |

- **Rot zuerst:** Commit `38207e8` (nur Tests). Läufe: erster Satz 3 Tests, 34 Fehlschläge (`br1-red2`), vollständiger Satz 27 Tests, 272 Fehlschläge, 14 unerwartet (`br1-red4`; die übrigen Fehlschläge sind Folgefehler der Hilfsfunktionen). Die Tests der Prüfung (`DMSScanReviewTests`) liefen vor der Korrektur rot (`br1-rev1`: u. a. `testReview1`, `testReview2` rot) und danach grün (`br1-rev2`: 23 Tests, 0 Fehler).
- **Volle Suite lokal** (macOS, eigener Postgres-17-Container, Stand `fa2707f`): 491 Tests, 14 übersprungen (OCR-Werkzeuge, nur Linux, Messlauf), **0 Fehler**. Zwei Instanzen gegen dieselbe Datenbank in jeder Scan-Probe.
- **PWA:** `npm run gen:api` ohne Rest-Unterschied, `svelte-check` 0 Fehler, Unit-Tests 116 grün.
- **E2E mit echten Prozessen:** `scripts/e2e-scan-bridge.sh` (zwei `App serve` auf einer frischen Datenbank, curl, echte Zeit der Datenbank; Prüfungen: Registrieren über B, Geräteliste über A, Anlegen, zweiter Auftrag 409, Übernehmen genau einmal, Seiten und Befehle, Upload zweimal über A und B ergibt ein Dokument, `done`, Lease-Ablauf ⇒ `failed/bridge_lost` ohne Wiederholung, Abbrechen, fremder Mandant 404, URL als Gerätekennung 422). Alle bestanden. Es gibt keinen Browser-Teil, weil die Oberfläche erst mit WP-BR3 kommt, und keinen Scanner, weil die Bridge erst mit WP-BR2 kommt.
- **Linux:** kommt aus der GitHub-CI (der lokale Docker-VM-Speicher reicht für den Linux-Testbau nicht).
- `pwa/e2e/dms.spec.ts` läuft wieder grün (Commit `db1a402`); der Schutz aus WP-H10 ist unverändert.

## Prüfung durch eine nicht bauende Sitzung (Sicherheitsteile)

Geprüft: Bridge-Anmeldung, Mandantentrennung, Rechte, Zustandsmaschine, Eingaben. Befunde und Ergebnis (je ein Test in `DMSScanReviewTests`):

| Nr. | Befund | Ergebnis |
| --- | --- | --- |
| 1 | Eingabeprüfung stimmte nicht mit den CHECK-Bedingungen der Datenbank überein (Zeilenumbruch am Ende, Kombinationszeichen, unsichtbare Format- und Trennzeichen ⇒ 500 statt 422) | behoben: Prüfung nach Unicode-Codepunkten, verbotene Skalare (Steuer-, Format-, Trenn-, Ersatz-, private und nicht zugewiesene Zeichen), Hex und Codes ohne Regex-`$` von Hand geprüft. Der behauptete `$`-Fehler ließ sich in Swift nicht nachstellen; die Skalarprüfung gilt trotzdem |
| 2 | Als Ergebnis konnte ein beliebiges Dokument gemeldet werden | behoben: nur ein Dokument, das die Bridge selbst (ihr Token) unter `scan-<Auftrag>` hochgeladen hat, im selben Mandanten, nicht im Papierkorb |
| 5 | Wiederholte `failed`-Meldung (verlorene Antwort) wurde abgewiesen | behoben: gleicher Code ist unschädlich, anderer Code 409 |
| 6 | Bridge konnte mit Abbruchwunsch weiterarbeiten | behoben: dann nur `cancelled` oder `failed` |
| 7 | Nutzerbefehle nicht im Protokoll | behoben: `dms.scan.job.command` (Befehl und Auftrag, keine Nutzdaten), einmal je neuem Befehl |
| 9 | Lebenszeichen nach abgelaufener Lease; inaktive Geräte | behoben: belebt nicht mehr; inaktive Geräte erhalten keine Übernahme, ein laufender Auftrag darf fertig werden |
| 10 | Rolle des Token-Inhabers | bestätigt und durch Test festgehalten: Herabstufung 403, Entfernung 404 bei jedem Aufruf |

Außerdem aus der Prüfung: Aufräumen sperrt in fester Reihenfolge (`ORDER BY id FOR UPDATE`), Anlegen sperrt die Gerätezeile; beide Maßnahmen gegen Überholen bei zwei Instanzen.

## Eigene Entscheidungen (nur hier protokolliert; das Aufgabenboard war in dieser Sitzung nicht erreichbar)

1. Scope `dms.scan.bridge` hat drei Teile; das Scope-Format im Kern wurde auf zwei bis drei Teile erweitert statt einen Namen mit zwei Teilen zu wählen (Commit `fa2707f`).
2. Das Bridge-Token braucht zusätzlich `dms.upload` für das Hochladen und die Rolle des Inhabers `dms.source.manage`; eine eigene Hub-Route für den Upload gibt es nicht, die bestehende Scan-API wird wiederverwendet (Idempotenz dort schon belegt).
3. Nie automatische Wiederholung nach Lease-Verlust (Papier könnte doppelt oder falsch eingezogen werden); der Nutzer startet neu. Ein spätes Ergebnis derselben Bridge wird angenommen.
4. Aufträge sind für alle Nutzer des Mandanten mit Recht `dms.scan.use` sichtbar (kein Besitzer-Filter), weil ein Scanner im Büro geteilt wird. **Entscheidung für Lino, falls pro Nutzer getrennt werden soll** (kleine Änderung: Filter auf `created_by`).
5. Ablauf ohne Hintergrunddienst: bei jedem Aufruf der Scan-Routen (zustandslos, mit Zeilensperren, Audit genau einmal).
6. Die alte, gesperrte Arbeitskopie `.claude/worktrees/agent-a38210f588a358242` (Zweig `wp-R1`, Inhalt schon als anderer Commit in `main`) wurde entfernt.

## Offen

- BR2 (Bridge-Dienst), BR3 (PWA Scannen, wartet auf die Abnahme von ST7), BR4 (Betrieb) laut ROADMAP.
- Linux-Lauf aus der CI nach dem Push (siehe `docs/ROADMAP.md`/CI-Lauf in der Abschlussmeldung).
- Lastempfindlich bei hoher Maschinenlast: `ExtractionRedosTests` und Tests an der 5-s-Frist des Verbindungspools (bekannt).

## Lehre

Wer ein Feld mit einer Datenbank-CHECK-Bedingung und einer Eingabeprüfung in der Anwendung doppelt hält, muss beide mit denselben Zeichenregeln testen (Codepunkte, Format- und Trennzeichen); sonst endet Eingabe in 500 statt 422. Neue Migrationen verlangen gleich die Listen in `MigrationNamesTests`, `HubTestDB.tables` und alle Revert-Listen, in denen ein Fremdschlüssel auf `api_tokens` zeigt.

## Nächster Schritt

BR2 (Bridge-Dienst) kann auf diesen Routen und dem Vertrag aufsetzen; BR3 nach der Abnahme von ST7.
