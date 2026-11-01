# ADR 0004: Modul-System

Status: vorgeschlagen (01.11.2026), Bestätigung durch den Nutzer offen.

**Kontext.** Rechnung, DMS und spätere Produkte sollen ein-/ausschaltbar sein und über einen gemeinsamen Kern zusammenarbeiten (`PLATTFORM-VISION.md` Abschnitt 8). Vorbild: `timetrack-backend` (`Modules/ModuleRegistry.swift`, ADR-0012: Server- und Kontoebene, `module_disabled`, Daten bleiben, Registry ohne Cache).

**Entscheidung.**
1. Jedes Modul implementiert das Protokoll `HubModule` (Schlüssel, `requires`/`enhances`, Berechtigungen, Migrationen, Navigation, Events, Job-Handler, Routen, `onActivate`). Details: `ARCHITEKTUR.md` Abschnitt 3.
2. Feste, zur Build-Zeit bekannte Modulliste; ein Image enthält alle Module; Aktivierung zur Laufzeit je Betreiber und je Mandant (`tenant_modules`), ohne Cache, zentraler `ModuleGuard`.
3. Migrationen aller Module laufen immer; deaktivierte Module behalten ihre Daten.
4. Module koppeln nur über Kernobjekte (Kontakt, Datei, `links`), Events und im Kern definierte Service-Protokolle, nie über Tabellen anderer Module.
5. Tabellenpräfix je Modul; Fremdschlüssel nur auf Kerntabellen.

**Folgen.** Kein dynamisches Plugin-Laden (AGPL, ein Image). Aufteilung in Swift-Targets (`HubCore`, `HubModule*`) empfohlen (OFFENE-FRAGEN F-14). Moduländerungen gehören ins Audit. Test: generischer Guard-Test über alle Routen jedes Moduls.

**Alternativen.** Separate Dienste je Modul (mehr Betrieb, schwächere Transaktionen); Plugins zur Laufzeit (Sicherheits- und Lizenzfragen).
