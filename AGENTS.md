# lab-hub – Einstieg für Coding-Agents (Claude Code, Codex)

Das Repository ist das Projektgedächtnis. Sessions sind wegwerfbar: Stand, Entscheidungen und nächste Schritte gehören in die Dateien, nicht in den Chat.

## 1. Lesereihenfolge

1. `README.md` (Status, Dokumentenindex)
2. `docs/ROADMAP.md` (Arbeitspakete WP, Abhängigkeiten) – daraus das nächste offene WP wählen
3. `docs/ARCHITEKTUR.md`, dann das Moduldokument des WP (`docs/MODUL-DMS.md`, `docs/MODUL-RECHNUNG.md`, `docs/FRONTEND.md`)
4. `docs/decisions/` (ADR 0001–0003 entschieden, 0004–0007 vorgeschlagen)
5. `docs/OFFENE-FRAGEN.md` – nicht entschiedene Punkte nie still entscheiden; Annahme kennzeichnen und im WP vermerken
6. `docs/PLATTFORM-VISION.md` nur als Hintergrund (Teile veraltet, siehe Kopfzeile dort)
7. `deploy/README.md` bei Betriebs-/Image-Themen

## Grundsatz: Hub ohne Swift-App nutzbar

Der Hub muss **vollständig ohne Swift-App** funktionieren: Alles, was die Apps können (Rechnungsmodul: Belege erstellen, bearbeiten, finalisieren, Nummernvergabe, PDF, E-Rechnung, Zahlungen, Berichte; DMS), muss über Backend + PWA möglich sein. Swift-Apps sind optionale Clients mit Offline-/Eigenständigkeit. Kein WP darf eine App voraussetzen (Entscheidungsvorschlag, `docs/OFFENE-FRAGEN.md` F-08/F-27/F-31).

## 2. Stack und Verzeichnislayout

| Pfad | Inhalt |
| --- | --- |
| `backend/` | Swift 6, Vapor, Fluent, PostgreSQL. Ziele: `HubKit` (Bibliothek), `App` (Executable), `HubKitTests` |
| `backend/Sources/HubKit/` | Kern (Config, Database, Migrations, Services, Routes). Module später unter `Sources/HubKit/Modules/<Name>/` bzw. als eigene Targets (ADR 0004) |
| `backend/Tests/` | XCTest/XCTVapor, Postgres-Tests gegen echte Datenbank |
| `pwa/` | SvelteKit + shadcn-svelte (Zielstruktur `docs/FRONTEND.md`, noch ohne Code) |
| `contracts/` | OpenAPI-Vertrag (entsteht mit WP-K4) |
| `deploy/` | `setup.sh`, `update.sh`, Compose-/Swarm-Dateien |
| `docs/` | Konzept, Module, Roadmap, ADRs |

Sprache: Code, Kommentare, Tests, Bezeichner, Commit-Betreff Englisch; Nutzertexte (UI, menschenlesbare Fehlermeldungen) und alle Dokumente Deutsch. Vorbilder: `../timetrack-backend`, `../timetrack-pwa` (nur lesen).

## 3. Build und Test

Build-Artefakte liegen nie im Repo (Dokumente-Ordner, Codesign-Xattrs). Immer Scratch-Pfad außerhalb setzen:

```
export LH_SCRATCH="${TMPDIR:-/tmp}/labhub-build"
docker compose up -d db                              # Postgres für Tests und Dev
cd backend
swift build --scratch-path "$LH_SCRATCH"
swift test  --scratch-path "$LH_SCRATCH"
swift run --scratch-path "$LH_SCRATCH" App serve     # /health, /ready
```

- `timetrack-backend` braucht `--build-system native` wegen Codesign-Xattrs (`../timetrack-backend/EINRICHTUNG.md`). Für den Hub zu verifizieren; tritt der Fehler auf, Flag hier eintragen.
- Datenbankzugang nur über Umgebung (`DB_HOST`, `DB_PASSWORD(_FILE)` …, siehe `deploy/README.md`). Tests ohne Datenbank dürfen Datenbank-Tests überspringen, müssen das aber ausgeben.
- PWA (ab WP-F1): `cd pwa && npm ci && npm run check && npm test`, E2E `npm run test:e2e`. Befehle werden mit WP-F1 festgeschrieben, bis dahin nicht behaupten.
- Nur Befehle als „ausgeführt“ melden, die wirklich liefen. Nicht ausgeführte Prüfungen im Übergabevermerk als offen führen.

## 4. Stateless-Regeln (ADR 0003, verbindlich)

Eine Instanz hält keinen korrektheitsrelevanten Zustand. Verboten: In-Memory-Cache als Wahrheit, Dateien im Container-Dateisystem (read-only Root, `tmpfs` für /tmp), Instanzuhr für Reihenfolge/Lease (stattdessen DB `now()`), Zähler im Speicher, Migrationen beim Start (`AUTO_MIGRATE=false`), Sticky-Session-Annahmen. Jedes Feature, das Zustand, Dateien, Jobs, Zähler oder Ereignisse berührt, braucht einen Test mit zwei Instanzen/Verbindungen (Muster: `backend/Tests/HubKitTests/PostgresTests.swift`).

## 5. Datenschutz und Sicherheit

- Keine Kundendaten, Zugangsdaten, Tokens, echten Belege im Repo, in Tests, Logs oder Ausgaben. Nur synthetische Testdaten. `.env` nie committen, nur `.env.example` mit Platzhaltern.
- Keine privaten Pfade, Hostnamen, IPs, Domains oder E-Mail-Adressen in Dateien (Platzhalter `hub.example.org`).
- Private Bestandsdaten (Paperless-Archive, Taxlab-Datenbanken, Kundenlayouts) nie lesen oder in den Modellkontext bringen; Import-Code nur mit synthetischen Fixtures entwickeln.
- Externe Dienste und KI nur mit ausdrücklicher Freigabe je Kunde (Opt-in, protokolliert, deaktivierbar). Standard: lokal. Keine Telemetrie.
- Jede Abfrage mandantengefiltert (`tenant_id`); jedes Modul liefert Mandantentrennungs-Tests (fremde ID liefert 404).
- Geldbeträge: Dezimalarithmetik (`Decimal`/`numeric`), nie Gleitkomma.

## 6. Git, Commit, Push

- Remote: privates GitHub-Repo `MagicalWig34653/lab-hub`, Branch `main`. Sichtbarkeit nie ändern.
- Vor Commit `git status` und `git diff --cached --stat` prüfen. Keine Binärdateien, Archive, Builds, `.env`, Schlüssel, Kundendateien.
- Commit-Nachricht: kurzer englischer Betreff mit WP-ID (z. B. `WP-K2: tenants and roles`). Nach jedem abgeschlossenen WP `git push origin main`. Nie `--force`.
- Lizenz AGPL-3.0-only. Neue Abhängigkeiten: Lizenz prüfen und in `docs/LIZENZEN.md` (entsteht mit WP-H1) eintragen. **Lizenzprüfung BoringSSL (WP-K0, Rechtsfrage nicht abschließend geklärt):** BoringSSL steht upstream seit dem Commit „Switch the license to Apache 2.0, matching OpenSSL upstream“ (`boringssl.googlesource.com/boringssl/+/33d1049b1f730d2725bb09b2256fd5fe4c46b17e`) unter Apache-2.0, das mit AGPLv3 kompatibel ist. Offen ist, ob die in `swift-nio-ssl` gebündelte Kopie (`CNIOBoringSSL`) der im Hub aufgelösten Version diesen Stand hat (ältere Checkouts tragen noch den Header „Licensed under the OpenSSL license“). Prüfauftrag und Rückfalloptionen: `docs/OFFENE-FRAGEN.md` F-03. Bis zum Prüfergebnis keine Annahmen in Doku/Releases, dass der Befund erledigt ist.
- Paperless-ngx steht unter GPL-3.0: keinen Code, keine Texte, keine Testdaten übernehmen; nur Funktionen sind Vorbild.

## 7. Arbeitsweise und TDD

1. WP aus `docs/ROADMAP.md` wählen (Abhängigkeiten erfüllt, nicht von anderem Agent bearbeitet; Status im WP-Eintrag pflegen).
2. Test zuerst (rot), minimale Umsetzung (grün), Refactor. Tests nennen das Akzeptanzkriterium (`AK-<WP>-<n>`).
3. Kleine Schritte; nur Code für das gewählte WP. Keine Vorratsabstraktion.
4. Entscheidungen als ADR (Status „vorgeschlagen“, bis der Nutzer bestätigt). Getroffene Nutzerentscheidungen mit Datum in `docs/OFFENE-FRAGEN.md` nachtragen.
5. Parallele Agents: Dateibesitz trennen; Migrationen und OpenAPI-Vertrag nur von einem Agent gleichzeitig ändern.
6. Fragen an den Nutzer gesammelt im Chat; offene Entscheidungen zusätzlich in `docs/OFFENE-FRAGEN.md`.

## 8. Definition of Done (je WP)

- [ ] Alle Akzeptanzkriterien des WP durch automatische Tests belegt; `swift test` (bzw. `npm test`) grün und tatsächlich ausgeführt.
- [ ] Stateless-Test (zwei Instanzen/Verbindungen) für alles mit Zustand.
- [ ] Mandantentrennungs- und Berechtigungstest (erlaubt/verboten) für jede neue Route.
- [ ] Migration vorwärtskompatibel (Expand/Contract), `schema_version` erhöht, Revert vorhanden oder begründet entfallen.
- [ ] OpenAPI-Vertrag aktualisiert, Vertragstest grün (ab WP-K4).
- [ ] Nutzertexte nur über i18n (PWA) bzw. Fehlercodes mit deutscher Meldung (Backend).
- [ ] Doku im selben Schritt: WP-Status in `docs/ROADMAP.md`, betroffene Moduldokumente, ADR falls Entscheidung.
- [ ] Keine Secrets/Nutzerdaten im Diff; Lizenzen neuer Abhängigkeiten geprüft.
- [ ] Commit und Push erfolgt; Übergabevermerk (Stand, Tests, offene Punkte, nächster Schritt) im WP-Eintrag.
