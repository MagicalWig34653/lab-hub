# WP-ST3: Swift-Targets `HubCore` und Module (F-14)

Stand 27.11.2026, auf `main` ab `7f53cff`. Reiner Umbau im Backend: Verhalten, Vertrag (`contracts/openapi.yaml`), PWA, `Package.resolved`, `deploy/` und die in `_fluent_migrations` gespeicherten Namen sind unverändert. Kein Deploy, kein Image-Push.

## Targets

| Target | Inhalt | darf paketintern importieren |
| --- | --- | --- |
| `HubCore` | bisheriger Kern samt Konfiguration, Datenbank, Modulprotokoll | nichts |
| `HubModuleDMS` | `Modules/DMS/` | `HubCore` |
| `HubModuleInvoice` | `Modules/Invoice/` | `HubCore` |
| `HubKit` | `InstalledModules`, `Routes.swift` (`routes`, `configure`), `Exports.swift` | `HubCore`, beide Module |
| `App` | Executable | `HubKit` |

`HubKitTests` bleibt ein Test-Target und importiert die vier Bibliotheken.

## Akzeptanzkriterien

| AK | Beleg |
| --- | --- |
| ST3-1 Targets und Zusammenbau | `Package.swift`; `TargetArchitectureTests.testAKST3_1_*` |
| ST3-2 Module importieren einander nicht | Manifest ohne Modul-Abhängigkeit; Builds in `scripts/` und beiden Dockerfiles mit `--explicit-target-dependency-import-check=error`; `TargetArchitectureTests.testAKST3_2_*` (Manifest, `import`-Zeilen, Skripte, Kerntext). Gegenprobe: ein eingefügtes `import HubModuleDMS` im Rechnungsmodul brach den Build ab (`'HubModuleInvoice' is missing a dependency on 'HubModuleDMS'`), danach zurückgenommen |
| ST3-3 Images, SBOM, Tests grün | siehe Belege |

SwiftPM allein erzwingt die Trennung nicht: Ohne den Schalter kann ein nicht deklarierter Import durchgehen, wenn das Modul zufällig schon gebaut ist. Deshalb Schalter **und** Test.

## Eigene Entscheidungen (nur hier protokolliert, das Aufgabenboard war in dieser Sitzung nicht erreichbar)

1. Konfiguration und Datenbank liegen in `HubCore`, `HubKit` ist nur der Zusammenbau (der Vorschlag in `ARCHITEKTUR.md` hatte sie in `HubKit`; Module brauchen sie, und Module dürfen `HubKit` nicht kennen). Commit `c913d79`.
2. Von Modulen genutzte Kern-Deklarationen sind `package` (nur in diesem Paket sichtbar) statt `public`; bisheriges `public` blieb. Commit `c913d79`.
3. `HubKit` reicht `HubCore` mit `@_exported import` weiter, damit `App` unverändert bleibt. Das Attribut ist von Swift nicht offiziell zugesagt; Rückfall wäre ein `import HubCore` in `entrypoint.swift`. Commit `c913d79`.
4. Reste aus ST2: `DMS_ALLOW_INTERNAL_TARGETS` liest jetzt `HubModuleDMS` (`NetworkTargetSettings.swift`), die Zieladress-Prüfung bleibt im Kern. `SecretBox` zog ins DMS-Modul (einziger Nutzer, Ableitung nennt „dms-source-credentials“ und ist unverändert, gespeicherte Geheimnisse bleiben lesbar); im Kern bleibt nur die Mindestlänge `SecretKeyRule`. Der Kern nennt kein Modul mehr, auch nicht in Texten und Kommentaren; Ausnahme ist die Datei mit dem gespeicherten Namen `dms_026_api_token_tenant`. Commit `c913d79`.
5. `.gitleaksignore` und `gitleaks:allow` für einen Fehlalarm: der Migrationsname `021_idempotency_lease` in `MigrationNamesTests`. Commit `2ab5dc6`.

## Belege

- Rot zuerst: Commit `bc8def2` (nur Tests). Lauf: 8 Tests, 19 Fehlschläge (`TargetArchitectureTests`: Targets, Quellordner und Build-Schalter fehlen). `MigrationNamesTests` war dort bereits grün; er hält Namen und Reihenfolge der 36 Migrationen fest. Die Prüfung der Kerntexte war dort nur wegen des fehlenden Ordners rot; nach dem Verschieben meldete sie 11 Zeilen mit Modulnamen, danach grün.
- Volle Suite lokal (macOS, eigener Postgres-17-Container), Stand `c913d79`: 468 Tests, 14 übersprungen (OCR-Werkzeuge, nur Linux, Messlauf), **1 Fehlschlag** `ExtractionRedosTests.testAKH10_1_repeatedLabelsAndLongTokensStayFast` (2,11 s bei Grenze 2,0 s, Last der Maschine um 150). Einzeln wiederholt 7/7 grün. Wiederholung der vollen Suite auf `2ab5dc6`: erst 468 Tests mit 1 anderem Fehlschlag (`DMSImportExportTests.testAKD9_cancelThenResume`, `connectionRequestTimeout` beim Verbindungspool, Last um 150), danach bei fallender Last **468 Tests, 14 übersprungen, 0 Fehler**.
- GitHub-CI (Linux, Worker-Test-Image, Postgres 17) auf dem Prüf-Branch `st3-verify`, Lauf `45943156640` (Code von `c913d79`): Backend 468 Tests, 466 bestanden, 2 übersprungen (AK-O2-5, AK-S1-7), 0 Fehler; PWA-Job grün.
- Images, Lauf `45943156867` (derselbe Stand, nur Bau und Start, kein Push): grün auf `ubuntu-24.04` (amd64) und `ubuntu-24.04-arm` (arm64): API- und Worker-Image gebaut, `migrate`, `serve` mit read-only Root, `/health`, `/ready` und PWA 200, Worker läuft nach 15 s. Kein Multi-Arch-Manifest, kein Push
- SBOM: `node scripts/generate-sbom.mjs --check` ok (272 Komponenten, Datei unverändert); `check-third-party-notices.sh` mit Checkout ok; shellcheck, `test-ci-gates.sh`, `check-env-docs.sh`, `check-workflows.sh` ok.
- E2E mit echten Prozessen (neues Binary, echtes Backend, Postgres, Chromium): `scripts/e2e-dms-ocr-failure.sh` 1/1 (mit Worker-Prozess), PWA `e2e/auth.spec.ts` 1/1. `WorkerProcessTests` in der vollen Suite.
- Upgrade `7f53cff` → neuer Stand auf derselben Datenbank (altes und neues Binary): `_fluent_migrations` zeilengleich (Name, Batch, Zeitstempel, ID), `schema_version` 17, Schema-Dump identisch (4076 Zeilen), Zählerstand erhalten, `/ready` 200 vor und nach `migrate`, Rücknahme auf das alte Binary 200; Neuinstallation mit dem neuen Stand ergibt dieselben 36 Namen und dasselbe Schema.

## Verhalten

Unverändert bis auf zwei sichtbare Kleinigkeiten: Protokollzeilen nennen als Quelle das neue Target (`[HubCore]`, `[HubModuleDMS]`, `[HubModuleInvoice]`) statt `[HubKit]` (nichts im Repo wertet das aus), und der Hilfetext von `worker --kinds` nennt als Beispiel `worker.selftest` statt `dms.ocr`.

## Angepasste Tests

- 47 bestehende Testdateien und `MigrationNamesTests`: zusätzlich `@testable import HubCore`, `HubModuleDMS`, `HubModuleInvoice`; sonst inhaltlich unverändert.
- `ArchitectureTests` (ST2-4): neue Pfade (`HubModule<Name>/`, `HubKit/InstalledModules.swift`).
- `scripts/ci-backend.sh` kopiert zusätzlich `scripts/` und die Dockerfiles in den Test-Container, damit die Prüfung der Build-Schalter auch in der CI läuft.

## Offen

- `pwa/e2e/dms.spec.ts` legt eine Mail-Quelle mit Host `127.0.0.1` an; seit WP-H10 lehnt das Backend IP-Literale ab. Nur am Code gelesen, nicht ausgeführt; vorbestehend und nicht Teil der CI. `test:e2e:dms`/`:stack` deshalb hier nicht gelaufen. Eigenes kleines WP sinnvoll.
- Lastempfindlich bei sehr hoher Maschinenlast: `ExtractionRedosTests` (Wanduhr-Grenzen, bekannt seit WP-R3) und Tests, die an die 5-s-Frist des Verbindungspools stoßen.
- `DMSModule` liest Handler-Einstellungen weiter aus der Umgebung des Workers (wie in ST2 vermerkt).
- Neues Modul: Target `HubModule<Name>` im Manifest, Eintrag in `InstalledModules`, Zeile in `TargetArchitectureTests.modules` und `MigrationNamesTests`.
- Nächster Schritt laut Roadmap: ST5, BR1 oder AB1.

## Lehre

- Die Sichtbarkeit beim Target-Schnitt kostet die meiste Zeit; ein kleines Skript, das `package` aus den Compilerfehlern ergänzt, war nach wenigen Runden fertig (nächstes Mal gleich so, nicht vorab alles heben: der erste pauschale Durchlauf musste verworfen werden).
- Secret-Scan nie in eine Pipe vor dem Push hängen: Der Exit-Code ging verloren, der Prüf-Branch war trotz Treffer schon gepusht (Treffer war ein Fehlalarm).
