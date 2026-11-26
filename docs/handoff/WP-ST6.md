# WP-ST6: PWA-Namen „LAB hub“, Module „docs“ und „invoice“

Stand 25.11.2026, direkt auf `main` ab `23bdcb5`. Nutzerentscheidung 25.11.2026 (`docs/OFFENE-FRAGEN.md`, „Entschieden“).

## Umgesetzt

- Titel, App-Name (`app.name`), Titelzeile der Recovery-Datei: „LAB hub“.
- Modul `dms` heißt in der Oberfläche „docs“ (de und en): Seitenleisten-Gruppe, Überschrift der Übersicht, Seitentitel, Modulliste. `invoice` erscheint als „invoice“.
- Anzeigename im Passkey-Dialog (`rp.name`): „LAB hub“. Die Passkey-Bindung (`rp.id`) ist unverändert, bestehende Passkeys gelten weiter.
- Unverändert: Modulschlüssel, Routen, Rechte, Dateiname `lab-hub-recovery-codes.txt`, Image- und Paketnamen. Die Gruppenüberschriften der Seitenleiste werden wie bisher in Großbuchstaben dargestellt („DOCS“).
- Nebenbei: Testhelfer `call` serialisiert JSON mit sortierten Schlüsseln. Vorher konnte dieselbe Eingabe in zufälliger Reihenfolge andere Bytes ergeben; eine Wiederholung mit `Idempotency-Key` galt dann als anderer Inhalt (`InvoiceLinkTests.testAKR3_8_ConvertAndLinks` einmal rot).

## Tests

Zuerst rot: `pwa/src/lib/names.test.ts` (2/2), `e2e-mock/names.spec.ts` (Titel „lab-hub“), `AuthTests.testAKST6_1_PasskeyDialogShowsProductName` („lab-hub“). Danach grün; Zahlen im Abschnitt „Ergebnis“.

## Ergebnis

Lokal am 25.11.2026 (macOS, Wegwerf-Postgres 17):

- Backend: 449 Tests, 14 übersprungen (OCR-/Container-Voraussetzungen), 0 Fehler. Erster Gesamtlauf: 1 Fehler (`testAKR3_8_ConvertAndLinks`, Ursache oben, behoben).
- PWA: `npm run check` ohne Fehler, 106 Unit-Tests, Mock-E2E 59/59.
- Echtes E2E (`e2e/auth.spec.ts`: echtes Backend, Postgres, Browser, ohne Mocks) inklusive der Namensprüfung für `dms` und `invoice`: grün. Ein erster Lauf bei sehr hoher Systemlast lief in das 5-s-Zeitlimit; unter ebenso hoher Last schlugen zuvor zwei Läufe an je einer Stelle in `dms-admin.spec.ts` fehl, die im späteren Gesamtlauf grün war.
- Bilder hell und dunkel der Übersicht angesehen; `shellcheck`, Vertrags- und Env-Doku-Prüfung grün. Keine GitHub-Workflows (WP-ST1).

## Offen

- Dunkelmodus schaltet die App noch nicht selbst (WP-ST4); die dunklen Bilder entstanden mit gesetzter Klasse `dark`.
- PWA-Manifest mit dem Namen folgt mit WP-F3.
- Nächster Schritt laut Roadmap: ST1, dann PA1 und ST4.
