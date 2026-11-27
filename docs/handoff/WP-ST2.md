# WP-ST2: Kern vom DMS-Modul entkoppelt

Stand 27.11.2026, direkt auf `main` ab `1275fef`. Nur Backend und Dokumente; PWA, Vertrag (`contracts/openapi.yaml`) und Deploy unverändert.

## Umgesetzt

| AK | Ergebnis |
| --- | --- |
| ST2-1 | `HubModule.jobHandlers(environment:)` und `workerPreflight(kinds:environment:)`. `WorkerHandlers` baut die Registry aus den installierten Modulen (fremde oder doppelte Job-Art ist ein Startfehler); selbst kennt der Kern nur `worker.selftest`. Die sechs DMS-Arten und die OCR-Vorabprüfung stehen in `Modules/DMS/DMSModuleHooks.swift`. |
| ST2-2 | `HubModule.tokenScopes` (`<key>.<name>`, von `ModuleRegistry` geprüft). `ApiTokens` vergibt nur deklarierte Scopes; `onToken` verlangt einen Scope des eigenen Moduls. DMS deklariert `dms.upload`. |
| ST2-3 | `HubModule.linkVisibility` und `guardLinkEnds` mit `LinkEnd`/`LinkVisibility`. `LinkService.Origin.external` trägt Modulliste und Rolle statt zweier DMS-Rechte. Die Regeln aus WP-H14 liegen unverändert im DMS-Modul. |
| ST2-4 | `ArchitectureTests`: Bezeichner mit `DMS`/`Invoice` nur unter `Sources/HubKit/Modules/<Name>/` und in `Modules/InstalledModules.swift` (Modulliste, aus `HubModule.swift` herausgezogen). Eigener kleiner Lexer: Code und Interpolationen zählen, Kommentare und Zeichenketten nicht. |
| Fehlertyp | `HubError.invalid(field, code)` im Kern; `DMSError.invalid` ruft ihn auf. |

### Zusätzlich gefunden und behoben

Die Spalte `api_tokens.tenant_id` (Kerntabelle) kam aus der **DMS-Modulmigration** `dms_026_api_token_tenant`. Ohne installiertes DMS scheiterte jede Token-Anlage mit 500; der Architekturtest sieht so etwas nicht. Die Migration steht jetzt als `CreateApiTokenTenant` in den Kernmigrationen (`Auth/ApiTokenTenantMigration.swift`). Der **gespeicherte Name bleibt**, Bestandsdatenbanken führen nichts erneut aus; `schema_version` unverändert.

## Belege (lokal, macOS, eigener Postgres-17-Container)

- Rot zuerst: Commit `e21a3ab` (nur `ArchitectureTests`; Lauf mit 27 Fundstellen in `ApiTokens`, `LinkService`, `WorkerCommand`, `HubModule`). `ModuleHookTests` vor der Umsetzung rot (Haken fehlen, Kompilierfehler); der Token-Test ohne DMS-Modul rot, solange die Migration beim Modul lag.
- Volle Suite: **460 Tests, 0 Fehler, 14 übersprungen** (12 ohne OCR-Werkzeuge, 1 nur Linux, 1 Antwortzeit-Messung; die CI führt die OCR-Tests im Worker-Image unter Linux aus). Danach nur zwei Test-Härtungen (Lexer-Endzustand, Pipe schließen); betroffene Suiten erneut grün (21 Tests).
- E2E mit echten Prozessen: `WorkerProcessTests.testAKST2_1_*` (Route reiht `dms.verify` ein, `App worker` bekommt den Handler vom Modul; unbekannte Art und fehlgeschlagene Vorabprüfung beenden mit Status 1) und `scripts/e2e-dms-ocr-failure.sh` (Backend, Postgres, `dms.ocr`-Worker, Browser): 1/1.
- Upgrade: Stand `1275fef` migriert eine leere Datenbank, der neue Stand läuft darüber (`_fluent_migrations` unverändert), `/ready` 200 mit neuem und danach mit altem Binary (Rücknahme möglich).
- GitHub-CI: Ergebnis steht am Commit auf `main`.

## Verhalten und angepasste Tests

- Verhalten mit der Modulliste `InstalledModules.all` unverändert.
- `ContactTests` installiert jetzt `DMSModule()`: der `dms.*`-Link-Schutz war vorher auch ohne Modul fest im Kern, jetzt kommt er vom Modul. Folge: Verknüpfungstypen eines **nicht installierten** Moduls schützt niemand (bei fester Modulliste im Betrieb nicht erreichbar).
- `AuthTests`, `DMSSourcesTests`, `ObjectStoreTests`: nur der neue Name der Migrationsklasse.

## Offen

- Nicht Teil von ST2, für ST3 (Swift-Targets) vormerken: `NetworkTargetPolicy` im Kern liest die Variable `DMS_ALLOW_INTERNAL_TARGETS` (Zeichenkette, vom Test bewusst nicht erfasst); `ContactMatchIndex`/Kommentare nennen DMS als Nutzer; der Architekturtest prüft Namen, nicht Typabhängigkeiten ohne `DMS`/`Invoice` im Namen. Erst getrennte Targets erzwingen die Richtung.
- `DMSModule` liest Handler-Einstellungen aus der Umgebung des Workers (wie bisher), nicht aus den Initialisierer-Werten des Moduls.
- Nächster Schritt laut Roadmap: ST3, BR1 oder AB1.
