# lab-hub – Einstieg für Coding-Agents

Das Repository ist das Projektgedächtnis. Zuerst `README.md`, `docs/PLATTFORM-VISION.md`, `docs/decisions/` lesen.

- Keine Kundendaten, keine Zugangsdaten, keine Geheimnisse im Repo oder in Ausgaben. Nur synthetische Testdaten.
- Test zuerst, kleine Schritte, Beträge nur mit Dezimalarithmetik (nie Gleitkomma).
- Module sind über den Kern gekoppelt (Mandant, Kontakt, Dokument, Verknüpfung, Ereignis), nicht untereinander direkt.
- Entscheidungen als Datei in `docs/decisions/` (ADR) festhalten.
- Externe Dienste/KI nur mit ausdrücklicher Freigabe je Kunde.
- Quelle der Fachlogik für Rechnungen ist das Repo `taxlab` (Swift-Pakete); Wiederverwendung statt Neuschreiben.
