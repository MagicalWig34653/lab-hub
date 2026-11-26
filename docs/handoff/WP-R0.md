# Handoff WP-R0 – Spike Rechenkern unter Linux

Stand 01.11.2026. Status: Spike abgeschlossen, Zusammenfassung in `docs/MODUL-RECHNUNG.md` Abschnitt 12.

## Ergebnis
- Geprüft wurde, ob der Rechenkern der bisherigen Rechnungs-App unter Linux (`swift:6.2`) nutzbar ist. Einzelheiten zum fremden Quellcode stehen nicht in diesem Repository.
- 50 synthetische Testvektoren (Dezimal-Strings) unter `backend/Tests/Fixtures/invoice-vectors/`.
- Die Hilfsskripte des Spikes gehören nicht mehr zum aktuellen Stand; sie setzten den Quellcode der App voraus.

## Entscheidung und offen
- F-27 (07.11.2026): Neuimplementierung im Hub gegen die Vektoren; Konformitätstest seit WP-R2.
- Skonto-Regeln nicht in der Referenz gefunden (F-32).
- Renderer-Frage: WP-R6a (F-08).
