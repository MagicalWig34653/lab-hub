# WP-H13: Codex-Befunde 5 und 6 (Auth-Races)

- Befund 5 (Recovery-Codes): `generateRecoveryCodes` sperrt die Nutzerzeile (`SELECT ... FOR UPDATE`) vor DELETE+INSERT; parallele Erzeugung hinterlaesst genau einen Satz (10 Zeilen).
- Befund 6 (Passkey-Login): `finishLogin` liest die Credential-Zeile mit `FOR UPDATE OF p`; parallele Assertions werden serialisiert, der Zaehler faellt nie zurueck (die niedrigere Assertion scheitert mit `login_failed`).
- Tests: `AK-H13-1` und `AK-H13-2` in `backend/Tests/HubKitTests/Auth/AuthTests.swift` (zwei Instanzen, je mehrere Runden). Vor dem Fix rot (Recovery: 20 statt 10 Zeilen; Zaehler 13/19/21/27 statt 14/20/22/28), danach gruen.
- Keine Migration, kein Vertrag.
