# WP-ST7 PWA-Redesign nach Vorbild TimeTrack, Akzentfarbe je Benutzer (26.11.2026)

Todolino-Karte 2DCA188B. Enthält WP-ST4 (System/Hell/Dunkel). Kein Deploy.

## Stand

- **Akzentfarbe je Benutzer:** Migration `022_user_accent` (Spalte `users.accent`, Expand-only, Revert vorhanden, `schema_version` bleibt wie bei 020/021 unverändert), `GET`/`PUT /api/v1/me/preferences` (nur normale Sitzung), Vertrag und Typen ergänzt. Keine Mandantendaten: die Route liest und schreibt nur das eigene Konto.
- **PWA:** Designsprache siehe `docs/FRONTEND.md` Abschnitt 6; Darstellungsseite `/settings/appearance`; `static/theme-init.js` gegen Farbflackern.
- **Bilder:** `docs/screenshots/redesign/` (hell/dunkel, 1440×900 und 390×844, nur erfundene Daten; Ausschnitt des Fensters, nicht die ganze Seite). Neu erzeugen: `VITE_MOCK=1 npm run build && SCREENSHOT_DIR=../docs/screenshots/redesign npx playwright test -c playwright.mock.config.ts e2e-mock/screenshots.spec.ts`.

## Tests (erst rot, dann grün)

| Was | Roter Stand | Umsetzung |
| --- | --- | --- |
| Backend AK-ST7-1/2 (`PreferencesTests`, 404 statt 200/422) | `5b951ea` | `0b6a690` |
| PWA AK-ST7-3…6, ST4-1…3 (`accent.test.ts`, `theme.test.ts`, `appearance.spec.ts`, 4/4 E2E rot) | `843099c` | `488f6f6` |
| Befunde der Vorprüfung (`redesign-review.spec.ts` 6/6 rot, 2 Unit-Tests rot) | `ff0285c` | `188eb88`, `76c8b2f` |
| Reste der Nachprüfung und Kopfzeilen-Fund (4 Tests in `redesign-review.spec.ts`, jeweils vor der Behebung rot gesehen) | `3c29345` | Folge-Commit |

Nachträge in `188eb88`, jeweils vorher rot gesehen: Handy-Kopfzeile zweizeilig (105 px), Vorschlagskarte im Eingang am Handy 32 px Textbreite.

Ein älterer Test wurde geändert: `dms-admin.spec.ts` AK-F5-1 verlangte, dass nach dem Löschen eines Tags **jede** Zeile der Prüfliste veraltet ist. Die Zahl wurde vor dem Laden der Liste gelesen, die Prüfung war also leer oder vom Zeitablauf abhängig; tatsächlich werden nur Vorschläge mit dem gelöschten Tag veraltet (2 Zeilen, 1 veraltet). Jetzt: mindestens eine veraltete Zeile ist sichtbar (6/6 Wiederholungen grün).

### Letzter lokaler Lauf (27.11.2026)

- Swift: 453 Tests, 14 übersprungen, 0 Fehler; Lizenzhinweise und SBOM geprüft.
- Skript-Prüfungen aus `scripts/ci.sh` (shellcheck, CI-Gates, Umgebungsvariablen, Backup/Restore), OpenAPI-YAML, `svelte-check` (0 Fehler), Vitest 116/116: grün.
- Mock-E2E: 74 bestanden, 4 übersprungen (Bild-Läufe ohne `SCREENSHOT_DIR`); Bild-Läufe 4/4.
- Unter hoher Rechnerlast scheiterten in drei früheren Gesamtläufen wechselnde Swift-Tests (Zeitüberschreitung bzw. `ConnectionPoolTimeoutError`, 5 s Verbindungsaufbau); keiner davon im letzten Lauf. Einmal brach `npm ci` an einer vom Finder angelegten `.DS_Store` ab.

## Unabhängige Vorprüfung gegen TimeTrack

Eigene Sitzung (T3-Delegat, Claude Sonnet 5.5, Effort medium, ohne Verlauf der bauenden Sitzung, nur lesend). Maßstab: TimeTracks `DESIGN.md` und dessen Bilder in allen vier Varianten (aus einer Scratch-Kopie mit Mock-Backend erzeugt). Geprüft am Stand `488f6f6`, 22 Bilder.

Befunde und Behebung:

| Nr. | Schwere | Befund | Behebung |
| --- | --- | --- | --- |
| 1 | hoch | docs-Übersicht wie ein Grundgerüst | Seitenkopf mit Erklärzeile, Upload- und Listenkarte, „Dateien auswählen“ als Hauptaktion, Summe unter der Liste |
| 2 | hoch | Handy: Filter verdrängen die Liste, Chip-Umbruch, Tabellen | Filter hinter „Filter (n)“, Zeitraum als eine Leiste, Tabellen als Kartenliste |
| 3 | mittel | Dashboard-Listen ungestaltet | ganze Zeilen als Link mit Trennern, Zähler und Pfeil; zwei Karten nebeneinander |
| 4 | mittel | Recovery-Hinweis gequetscht | Banner mit Symbol und Knopf, neuer Titel, Einzahlform |
| 5 | mittel | Touch-Ziele unter 40 px | unter 1024 px überall mindestens 40 px (per Test gemessen auf sechs Seiten) |
| 6 | mittel | Handy-Menü unvollständig | Schließen-Knopf, Fokus hin und zurück, Inhalt `inert`, Einstellungen fest unten |
| 7 | mittel | Seitenleiste weicht ab | Hub-Eintrag heißt „Start“, Einstellungen am unteren Ende |
| 8 | mittel | falscher Seitenkopf der Einstellungen | eigener Titel und Erklärzeile je Unterseite, keine Lücke mehr |
| 9 | mittel | docs-Unterseiten ohne Muster | gemeinsamer `PageHeader`, `panel`-Karten, ein Titelstil |
| 10 | niedrig | Handy-Kopfzeile | Seitenname, Menüknopf ohne Rahmen, schmale Mandantenwahl |
| 11 | niedrig | Desktop-Kopfzeile überladen | Auswahlfelder ohne Rahmen, Beschriftung nur für Vorleser |
| 12 | niedrig | dunkle Akzente schwach | Fläche wird bei Bedarf aufgehellt/abgedunkelt, bis 3:1 gegen die Seite (Test) |
| 13 | niedrig | Einzahlform, blaues Chip, Login | Einzahlformen, Rechnungs-Chip neutral, Login-Karte und -Knopf größer |

Eigene Funde beim Ansehen der neuen Bilder (behoben): Vorschlagskarte im Eingang am Handy buchstabenweise umbrochen; leerer Streifen in Mitglieder/Profil; leere Zeilen in der Stammdaten-Kartenliste; fehlendes Leerzeichen vor „(überfällig)“.

## Unabhängige Nachprüfung

Zweite eigene Sitzung (gleiche Bedingungen), Stand `76c8b2f`, 42 Bilder (38 neue, 4 von TimeTrack). Ergebnis: 12 Befunde behoben, Befund 9 teilweise; die vier benannten Abweichungen vertretbar; kein schwerer Darstellungsfehler. Sieben Restpunkte:

| Nr. | Schwere | Rest | Behebung |
| --- | --- | --- | --- |
| R1 | mittel | aktiver Einstellungseintrag in der Seitenleiste nicht sichtbar | wird in den sichtbaren Bereich gescrollt (Test) |
| R2 | mittel | Unterseiten ohne gemeinsames Kartenmuster (Rest von Befund 9) | Listen, Leerzustände und Scanner in `panel`-Karten, „Neu anlegen“ im Seitenkopf, Reiter als Leiste (Test) |
| R3 | niedrig | doppelte Linien in den Handy-Kartenlisten | eine Linie zwischen Karten (Test) |
| R4 | niedrig | Stammdaten-Karte am Handy ohne Titel | erste Spalte als Titel (Test) |
| R5 | niedrig | Links im Eingang nicht erkennbar, „Alle anzeigen“ bricht um | Akzentfarbe, kein Umbruch (Test) |
| R6 | niedrig | Mandantenname trotz Platz abgeschnitten | breitere Auswahl (Test) |
| R7 | niedrig | Farbfeld Graphit auf dunklem Grund schwach | hellerer Ring im dunklen Modus |

Danach eigener Fund beim Ansehen: Durch R6 war am Handy der Seitenname in der Kopfzeile abgeschnitten („Stammd…“). Das Darstellungs-Symbol entfällt unter 640 px (Weg über Menü → Einstellungen, per Test), die Mandantenwahl ist 148 px breit.

**Ehrliche Einschränkung:** Die Behebung von R1–R7 und der Kopfzeilen-Fund sind nur durch Tests und die bauende Sitzung (Bilder angesehen) belegt, nicht durch eine dritte unabhängige Sichtung.

## Entscheidungen dieser Sitzung (ohne Rückfrage, bitte bei der Abnahme prüfen)

1. Titel der docs-Übersicht bleibt „docs“ (WP-ST6, Nutzer 25.11.2026), der Vorschlag „Dokumente“ wurde nicht übernommen.
2. Keine Einstellungssuche, Hilfe oder Statuszeile in der Seitenleiste: dafür gibt es noch keine Funktion.
3. Sprachwahl bleibt am Computer in der Kopfzeile.
4. Einstellungen bleiben eine einklappbare Gruppe (unten), am Handy zusätzlich fester Knopf.
5. Der Hub-Eintrag der Seitenleiste heißt „Start“ (vorher zweimal „Übersicht“).
6. Zwölf Farbvorgaben plus freie Farbe; das Konto speichert nur den Hex-Wert. Kein Leuchteffekt wie bei TimeTrack.
7. Hell/Dunkel bleibt je Gerät (AK-ST4-1), nur die Akzentfarbe liegt im Konto.
8. Am Handy steht in der Kopfzeile kein Darstellungs-Symbol, damit Seitenname und Mandant lesbar bleiben.

## Offen

- Abnahme durch das Brain, danach Sichtprüfung durch den Nutzer.
- Nicht per Bild geprüft: Rückfall ohne Transparenz, 200-%-Zoom; die Seiten Prüfen, Duplikate, Papierkorb, Quellen, Tokens, Scanner, Integrität, Export und Dokument-Detail haben keine eigenen Bilder.
- Todolino war aus dieser Sitzung nicht erreichbar (Anmeldung nötig); Fortschritt und Befundliste stehen hier und müssen auf die Karte übertragen werden.

## Lehre

- Eigenes Ansehen der Bilder nach jeder Korrektur lohnt: Eine Behebung (breitere Mandantenwahl) hat den Seitennamen abgeschnitten, kein Test hatte das gemessen.
- Den vollen Swift-Lauf nicht neben anderen schweren Läufen starten (Docker-VM mit 2 Kernen); Befehle vor einem Commit mit `&&` verketten, nie mit `;`.
