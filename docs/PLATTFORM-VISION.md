# Plattform-Vision: LAB-Produktfamilie (Entwurf)

> **Hinweis (01.11.2026):** Hintergrunddokument. Maßgeblich sind `ARCHITEKTUR.md`, `ROADMAP.md`, `OFFENE-FRAGEN.md` und die ADRs. Überholt: die Datenbankentscheidung in 6/6.1 (MariaDB als Arbeitsstand; entschieden ist PostgreSQL, ADR 0001). Abschnitt 8 und 9 sind in `ARCHITEKTUR.md` konsolidiert, hier bleibt der ausführliche Datenschutzentwurf.

Stand: 28.10.2026 (überarbeitet nach den Nutzerentscheidungen vom selben Tag). **Nicht Teil von Version 1.** Entscheidungen des Nutzers stehen in Abschnitt 6, alles andere sind Vorschläge.

## 1. Grundidee (Nutzer)

- Eine komplette Unternehmensorganisation soll abbildbar sein, aufgeteilt in eigenständige Produkte.
- Das bisherige Taxlab (Rechnungen, Angebote, EÜR, Layout-Designer, Totals-Grundlage) wird das **Invoice-Ninja-Äquivalent** und bekommt einen neuen Namen (Arbeitstitel „LAB rev“ oder „LAB income“; Name nicht final).
- Ein **DMS** (Dokumentenmanagement) mit den Funktionen von Paperless-ngx.
- Später ein **„LAB tax“** als vereinfachter Steuerprofi-Klon (der Name „LAB tax“ wird heute noch vom Rechnungsprogramm als Anzeigename genutzt und wird dann frei).
- Ein **Backend**, das alle Plattformen zusammenführt und die Daten aller Produkte hält. Jedes Produkt ist dort ein **Modul**, das sich aktivieren und deaktivieren lässt.
- Ein **PWA-Frontend**, das alle Produkte bedient.
- Je Produkt eine **Swift-App**, die komplett eigenständig (lokal, optional iCloud) oder mit Backend laufen kann.

## 2. Was dafür schon da ist

Die Architektur von Taxlab trennt bereits Fachkern und Infrastruktur (siehe `STORAGE-SCHNITTSTELLEN.md`, `SYNC.md`):

- `DocumentStore`, `AttachmentStore`, `NumberAllocator` und `SyncTransport` sind Protokolle. Ein Server-Backend wäre eine weitere Implementierung neben SQLite und CloudKit.
- Fachkern (`TaxlabCore`, `TaxlabModel`) ohne Persistenz- oder CloudKit-Abhängigkeit.
- Mandantentrennung (Unternehmen) und Zähler-Untergrenzen existieren; ein Berechtigungsmodell (Rollen, später Kundenzugang) ist noch nicht gebaut.
- Der zentrale Nummernzähler ist heute CloudKit (CAS). Im Backend wäre er ein atomarer Datenbankzähler je Unternehmen und Serie.

## 3. Zielbild (Vorschlag)

```
        PWA (alle Module)        Swift-Apps (je Produkt)
               │                    │            │
               │     eigenständig: lokal / iCloud │
               ▼                    ▼ mit Backend ▼
        ┌──────────────── LAB Hub (Backend) ───────────────┐
        │ Identität/Mandanten │ Rechte │ Sync-API │ Dateien │
        │ Zähler │ Ereignisse │ Suche │ Aufgaben/Webhooks  │
        ├──────────┬──────────┬──────────┬─────────────────┤
        │ Modul    │ Modul    │ Modul    │ Modul …         │
        │ Rechnung │ DMS      │ Steuer   │                 │
        └──────────┴──────────┴──────────┴─────────────────┘
```

Gemeinsame Bausteine über alle Produkte (eigene Swift-Pakete bzw. Backend-Dienste):

1. **Mandanten und Identität**: Ein Nutzer, mehrere Unternehmen, später Rollen (Inhaber, Buchhaltung, Steuerberater, Kunde mit Lesezugriff).
2. **Stammdaten gemeinsam**: Kontakte/Firmen sind produktübergreifend, damit ein Kunde in Rechnung, DMS und Steuer derselbe ist.
3. **Dokumente und Anhänge**: Ein Dateispeicher mit Prüfsumme (heute SHA-256 im Anhangsspeicher), Rechnungs-PDFs landen automatisch im DMS.
4. **Verknüpfungen statt Kopien**: Beleg im DMS ↔ Ausgabe ↔ Bankbuchung ↔ Rechnung als Links mit Quelle.
5. **Ereignisse**: Module melden Ereignisse („Rechnung finalisiert“, „Beleg eingegangen“); andere Module reagieren. Das hält Module entkoppelt.
6. **Design-System** (heute `DesignKit`/`Theme`) als gemeinsames Paket, damit alle Apps gleich wirken.

Betriebsarten je Produkt: (a) komplett lokal, (b) lokal plus iCloud (heute), (c) Backend. Wichtig: Der Wechsel zwischen den Betriebsarten ist ein Export/Import mit definierter Migration, kein stilles Umschalten (Lehre aus dem Sync-Fehlerbild: Nummernzähler und Sync-Zustand dürfen nie still wechseln).

## 4. Produkte und Namen (Vorschlag, ohne Markenprüfung)

Familienmarke „LAB“ bleibt. Die Namen sind Ideen; **Marken- und Domainprüfung wurde nicht durchgeführt**, „Lab“ ist generisch.

| Aufgabe | Namensideen |
| --- | --- |
| Rechnungen, Angebote, EÜR (heute Taxlab) | LAB rev, LAB income, LAB bill, LAB invoice, LAB ledger |
| DMS (Paperless-ngx-Äquivalent) | LAB docs, LAB archive, LAB vault, LAB shelf, LAB paper |
| Steuer (vereinfachter Steuerprofi) | LAB tax |
| Backend/Zentrale | LAB hub, LAB core, LAB base |
| Kontakte/CRM | LAB crm, LAB people, LAB contacts |
| Bank/Liquidität | LAB cash, LAB bank, LAB flow |
| Belege/Spesen | LAB spend, LAB receipts |
| Zeiterfassung | LAB time, LAB clock |
| Projekte/Aufgaben | LAB projects, LAB tasks, LAB board |
| Lager/Inventar | LAB stock, LAB inventory |
| Verträge/Signatur | LAB contracts, LAB sign |
| Lohn/Personal | LAB payroll, LAB team |
| Auswertungen | LAB insight, LAB reports |
| Mail/Postausgang | LAB mail, LAB post |

Empfehlung: Produktnamen nach dem Nutzen benennen („income“, „docs“, „tax“), den Kernnamen nicht doppelt belegen („tax“ nicht für Rechnungen und Steuer). Bundle-IDs, Domains und App-Store-Namen früh prüfen.

## 5. Module (Vorschlag für die Reihenfolge)

1. **Rechnung** (heute Taxlab): Version 1 stabilisieren, dann Umbenennung.
2. **DMS**: Import (Ordner, E-Mail, Scan, Teilen-Menü), OCR (Apple Vision lokal), Tags, Korrespondenten, Dokumenttypen, Speicherpfade, Regeln/automatische Zuordnung, Volltextsuche, Aufbewahrungsfristen, Papierkorb mit Wiederherstellung, Verknüpfung mit Belegen/Ausgaben. Die Funktionsliste lehnt sich an Paperless-ngx an; **Code von Paperless-ngx (GPL-3.0) wird nicht übernommen**, nur Funktionen sind Vorbild.
3. **Backend-Kern** mit Sync-API, Dateispeicher, Zähler, Rechte.
4. **PWA** zuerst für Rechnung und DMS (Erfassung, Liste, PDF, Upload), später alle Module.
5. **LAB tax** (Steuer), danach Bank, Zeit, Projekte.

## 6. Entscheidungen des Nutzers (28.10.2026)

| Thema | Entscheidung |
| --- | --- |
| Zusammenspiel | Alle Module sollen mit Backend „perfekt miteinander arbeiten“ (siehe Abschnitt 8). |
| Backend | Swift. Vorbild: `timetrack-backend` (Vapor, Fluent, `TimetrackKit`, OpenAPI-Vertrag, MCP, Passkey/OIDC/OAuth, Modul-Registry). |
| Frontend | PWA mit Svelte + shadcn-svelte (SvelteKit, Tailwind, statische Auslieferung durch das Backend). Vorbild: `timetrack-pwa`. |
| Datenbank | Arbeitsstand MariaDB, SQLite für Einzelinstanzen (wie in `timetrack-backend`). PostgreSQL hat für DMS-Suche und Invarianten Vorteile (6.1a); Entscheidung nach Suchspike. |
| Betrieb | Selbst hostbar (Docker Compose, später Swarm). Je Kunde ein eigener Server beziehungsweise eigene Datenbank. |
| Lizenz | AGPL-3.0-only, Open Source. Einnahmen nur über Betreuung und Dienstleistungen, nicht über Softwarepreise. |
| Umbenennung | Bundle-IDs und iCloud-Container werden bei Bedarf geändert; Daten werden vorher exportiert und danach importiert. Nur zwei Tester betroffen. |
| Steuer-App | Später. Zuerst DMS (Paperless-Klon) und das heutige Taxlab abschließen. |
| Datenschutz | Konzept in Abschnitt 9, Nutzer prüft. |

### 6.1 Warum MariaDB als Arbeitsstand?

Mein erster Vorschlag (PostgreSQL) war nicht an deinen Stack angepasst. `timetrack-backend` nutzt `fluent-mysql-driver` und SQLite, hat Migrationen, Compose-Dateien und Betriebswissen für MariaDB (12.3), und seine Docs lassen PostgreSQL ausdrücklich entfallen (für dieses Projekt; für den Hub offen, siehe 6.1a). Die Gründe für MariaDB hier:

- Gemeinsamer Code und gleiche Migrationen/Betriebsabläufe wie `timetrack-backend`; ein Treiber, ein Backup-Verfahren.
- Pro Kunde ein eigener Server heißt: Mandantenisolierung über Zeilenrechte (Row Level Security, eine Stärke von PostgreSQL) wird nicht gebraucht.
- Die wichtigen Anforderungen sind mit MariaDB erfüllbar: Transaktionen, Zeilensperren (`SELECT … FOR UPDATE`) für den atomaren Nummernzähler, Volltextindex (InnoDB FULLTEXT) für die DMS-Suche, JSON-Spalten.

### 6.1a Vorteile von PostgreSQL für dieses Vorhaben

Technischer Vergleich aus meinem Wissen, **nicht per Prototyp belegt** (Versionsstände einzeln prüfen). „Relevanz“ bezieht sich auf LAB.

| Thema | PostgreSQL | MariaDB (12.x) | Relevanz für LAB |
| --- | --- | --- | --- |
| Volltextsuche | `tsvector` mit Sprachwörterbuch (deutsche Wortstämme), Ranking, `unaccent`, Ähnlichkeitssuche mit `pg_trgm` (Tippfehler) | InnoDB-FULLTEXT ohne Wortstämme, schwächeres Ranking | **Hoch für DMS** (OCR-Text, „Rechnung“ findet „Rechnungen“) |
| Vektorsuche (KI) | Erweiterung `pgvector` | Vektortyp seit 11.7 vorhanden (neuer, weniger verbreitet) | Mittel, wenn später lokale Einbettungen für „ähnliche Dokumente“ |
| Teil-Indizes | `UNIQUE … WHERE status = 'final'` direkt | nicht vorhanden, Umweg über generierte Spalten | **Hoch**: Invarianten wie „Rechnungsnummer je Serie nur einmal unter finalen Belegen“ |
| JSON | `jsonb` mit GIN-Index, Abfragen in den Datensätzen | JSON ist Text mit Funktionen, Index über generierte Spalten | Mittel: Taxlab speichert Fachobjekte als JSON-Dokumente |
| Migrationen | DDL ist transaktional (Fehler rollt alles zurück) | DDL committet implizit | Mittel (sicherere Updates beim Kunden) |
| Isolation | echte Serializable-Isolation (SSI) | Serializable über Sperren | Mittel für Zähler und Zahlungssalden |
| Sperren | Advisory Locks, `SKIP LOCKED` | `GET_LOCK`, `FOR UPDATE`, `SKIP LOCKED` | Gleichwertig für den Nummernzähler |
| Zeilenrechte | Row Level Security | nicht vorhanden | Gering (Server je Kunde), nützlich als zweite Schutzschicht bei mehreren Unternehmen je Server |
| Backup | WAL-Archiv, Point-in-Time-Recovery, `pg_basebackup` | `mariabackup`, Binlog | Gleichwertig |
| Swift-Treiber | `fluent-postgres-driver` (PostgresNIO), in der Vapor-Welt am häufigsten genutzt | `fluent-mysql-driver` (MySQLNIO) | Mittel: Reife und Pflege des Treibers (Einschätzung, nicht geprüft) |
| Betrieb/Wissen | zweite Datenbank neben MariaDB | bereits vorhanden, `timetrack-backend` nutzt sie | **Gegenargument**: ein Motor weniger, gemeinsamer Code |

**Einschätzung.** Für Rechnungen allein macht Postgres keinen entscheidenden Unterschied. Beim **DMS** hat es spürbare Vorteile (deutsche Volltextsuche, Tippfehler-Toleranz, später Vektorsuche) und bei den **Invarianten** (Teil-Indizes, transaktionale Migrationen). MariaDB spricht für **Wiederverwendung** von `timetrack-backend` und weniger Betriebsaufwand.

Optionen:
1. **MariaDB + separater Suchindex** für das DMS (z. B. Meilisearch oder SQLite FTS5 in Einzelinstanzen). Ein DB-Motor, gute Suche, ein Dienst mehr.
2. **PostgreSQL für den neuen Hub.** Beste Suche und Constraints in einem System. Preis: `timetrack-backend` bliebe auf MariaDB, der gemeinsame Kern müsste mit zwei Treibern laufen (doppelte Tests) oder `timetrack` zieht später um.
3. **Beide unterstützen** (Fluent abstrahiert, aber Teil-Indizes, JSON und Suche sind motorspezifisch): höchster Aufwand, nicht empfohlen.

Vorschlag: Entscheidung per kleinem Spike vor dem Hub-Beginn: dieselben 200 synthetischen OCR-Texte (deutsch) gegen MariaDB-FULLTEXT und PostgreSQL-`tsvector` suchen und die Treffer vergleichen. Wenn MariaDB reicht (oder Option 1 genügt), bleibt es bei MariaDB. Reicht sie nicht, ist Postgres für den Hub gerechtfertigt. Bis dahin ist MariaDB der Arbeitsstand.

### 6.2 Kein Selbstzweck: Basis aus `timetrack-backend`?

Ich habe `timetrack-backend` nur im Aufbau gesichtet (Paket, Modul-Registry, Compose, Architekturdokument), nicht im Detail geprüft. Es gibt bereits ein Modulsystem (Server- und Konto-Ebene, Audit), Authentifizierung (Passkey, OIDC, OAuth), MCP und Einladungen. Offene Entscheidung: Hub aus `TimetrackKit` herauslösen und gemeinsam nutzen (ein Kern, Zeiterfassung wird Modul „LAB time“) oder ein eigenes Hub-Repo beginnen, das nur Muster und Pakete übernimmt. Vorschlag: gemeinsamen Kern als Swift-Paket herauslösen (Auth, Modul-Registry, Konfiguration, Mail, Wartung), Produkte als Module daran hängen. Das ist ein Architekturschritt mit Aufwand und braucht einen Spike.

Hinweis aus `timetrack-backend/docs/LIZENZEN.md`: Das eingebettete BoringSSL in `swift-nio-ssl` steht unter einer alten OpenSSL-Lizenz, die mit der AGPL kollidieren kann (offener Befund vor einem Release). Das gilt auch für den gemeinsamen Hub und braucht vor der Veröffentlichung eine Lösung.

## 7. Weitere offene Fragen

1. Hub-Repo: gemeinsamer Kern mit `timetrack-backend` oder neues Repo (siehe 6.2)?
2. Soll ein Kunde mehrere Unternehmen auf seinem Server haben (wie heute in der App) oder ein Server je Unternehmen? Die Ein-Server-pro-Kunde-Entscheidung lässt beides zu; Vorschlag: mehrere Unternehmen je Server, Mandantentrennung im Datenmodell beibehalten.
3. Dienstleistungsmodell (Betreuung, Hosting, Einrichtung): Haftung und Auftragsverarbeitung klären, sobald fremde Daten gehostet werden.
4. Rechtliches der Steuer-App später: fachliche Freigabe durch Steuerberater.

## 8. Zusammenspiel der Module („perfekt zusammenarbeiten“)

Ziel: Mit Backend wirken die Module wie ein System. Dafür feste Regeln statt loser Integrationen:

1. **Ein Datenbestand, ein Kernmodell.** Mandant (Unternehmen), Kontakt, Dokument/Anhang, Nutzer/Rolle, Projekt, Zahlungsmittel liegen im Hub-Kern. Module besitzen nur ihre Fachdaten und verweisen auf Kernobjekte per ID.
2. **Verknüpfungen als Daten.** Eine Tabelle `links` (von, nach, Art, Quelle, Zeitpunkt): Beleg im DMS ↔ Ausgabe ↔ Bankbuchung ↔ Rechnung ↔ Projekt ↔ Zeiteintrag. Jede Verknüpfung nennt ihre Quelle (manuell, Regel, KI-Vorschlag) und ist umkehrbar. Nichts wird still verknüpft (gleiche Regel wie bei Zahlungszuordnung heute).
3. **Ereignisse.** Module veröffentlichen unveränderliche Ereignisse mit Version („invoice.finalized“, „document.received“, „timeentry.approved“). Andere Module abonnieren per Registry; nur aktive Module bekommen Ereignisse. Zustellung mindestens einmal, Empfänger idempotent. Das gleiche System dient Webhooks und MCP.
4. **Beispielabläufe.** Rechnung finalisiert → PDF im DMS (Typ „Ausgangsrechnung“, Aufbewahrungsfrist). Beleg im DMS erkannt → Ausgabe als Entwurf im Rechnungsmodul (Prüfung durch Nutzer). Zeiteinträge freigegeben → Rechnungsentwurf mit Positionen (nach ausdrücklicher Aktion). Bankbuchung ↔ Rechnung ↔ Beleg in einer Ansicht.
5. **Abhängigkeiten zwischen Modulen** deklarieren: `requires`/`enhances`. Deaktiviertes Modul blendet seine UI aus, Daten bleiben erhalten und werden nicht gelöscht; abhängige Funktionen melden „Modul nicht aktiv“ statt zu brechen (so macht es die Registry in `timetrack-backend`).
6. **Eine API-Fläche.** Je Modul ein OpenAPI-Abschnitt in einem gemeinsamen Vertrag, daraus TypeScript-Client (PWA) und Swift-Client (Apps) erzeugt; MCP als Adapter derselben Dienste, keine zweite Geschäftslogik.
7. **Gemeinsame Suche.** Ein Index über alle Module (Dokumente, Kontakte, Belege, Zeiten) mit Rechteprüfung je Treffer. Die Befehlspalette der App (⌘K) ist die Vorlage.
8. **Gemeinsame Rechte.** Rollen im Kern (Inhaber, Buchhaltung, Mitarbeiter, Steuerberater, Kunde lesend), Berechtigungen je Modul und Unternehmen.
9. **Eigenständige Apps bleiben gleichwertig.** Jede App nutzt dieselben Fachkern-Pakete lokal; mit Backend wechselt nur die Implementierung hinter den Protokollen (Speicher, Sync, Zähler, Anhänge). Ein Austausch läuft über Export/Import, nicht still.

## 9. Datenschutz- und Sicherheitskonzept (Entwurf zur Prüfung)

Ausgangslage (Nutzer): Pro Kunde ein eigener Server beziehungsweise eigene Datenbank. Das ist die stärkste Trennung und vereinfacht vieles. Alles Folgende ist ein Entwurf, **keine Rechtsberatung**, und braucht vor produktivem Einsatz mit fremden Daten eine Prüfung (Auftragsverarbeitung, TOMs, Verzeichnis).

**Rollen.** Betreiben Kunden selbst (Open Source, selbst gehostet): Kunde ist Verantwortlicher, du lieferst Software. Hostest oder betreust du: Du bist Auftragsverarbeiter und brauchst Verträge (AVV) und Technisch-organisatorische Maßnahmen.

**Isolation.**
- Ein Server/Container-Stack und eine Datenbank je Kunde; keine gemeinsame Datenbank, keine gemeinsamen Schlüssel, keine gemeinsamen Dateispeicher.
- Innerhalb eines Kunden Mandantentrennung je Unternehmen im Datenmodell und in der API (`tenant_id` in jeder Abfrage, Tests dagegen).

**Daten und Verschlüsselung.**
- Transport: TLS am Reverse Proxy (vorhanden); interne Verbindungen Hub ↔ DB nur im privaten Netz.
- Ruhende Daten: Festplatten-/Volume-Verschlüsselung des Hosts als Pflicht; Dateispeicher (Anhänge, DMS-Dokumente) optional zusätzlich anwendungsseitig verschlüsselt (Schlüssel je Kunde, nicht im Repository, Rotation beschreiben).
- Backups verschlüsselt (wie die heutigen App-Backups: AES-256-GCM, Schlüsselableitung mit hoher Iterationszahl), Wiederherstellung regelmäßig getestet; Aufbewahrung und Löschfristen dokumentiert.
- Geheimnisse (DB-Passwort, Mail, OIDC) nur als Docker-Secrets/Umgebung, nie im Image oder Git.

**Zugriff.**
- Anmeldung mit Passkey oder OIDC, Passwort nur als Notfall (wie in `timetrack-backend`), Rate Limits, Sitzungsverwaltung, Abmelden aller Geräte.
- Rechte rollenbasiert je Modul und Unternehmen, Prinzip der geringsten Rechte; Kundenzugang nur lesend und nur auf freigegebene Objekte.
- Audit-Log für sicherheitsrelevante Aktionen (Anmeldung, Rechteänderung, Modul an/aus, Export, Löschen); Log enthält keine Belegdaten, nur IDs und Zeiten.

**Minimierung und KI.**
- Keine Telemetrie an Dritte; Fehlerberichte nur lokal oder ausdrücklich freigegeben.
- OCR/KI im DMS standardmäßig lokal (Apple Vision auf dem Mac, lokale Modelle auf dem Server). Externe KI-Dienste nur je Kunde ausdrücklich eingeschaltet, mit Hinweis, welche Daten gesendet werden, und deaktivierbar. Entspricht der Regel aus `AGENTS.md` (externe Verarbeitung nur mit Freigabe).
- MCP-Zugriff nur über OAuth mit eingeschränkten Scopes.

**Betroffenenrechte und Löschung.**
- Auskunft/Export je Kontakt und je Unternehmen (maschinenlesbar), Löschung mit Prüfung gesetzlicher Aufbewahrungsfristen (Rechnungen und Buchungsbelege bis zu 8–10 Jahre; als Hinweis, nicht als Rechtsberatung). Gelöschte Datensätze verschwinden auch aus Suchindex und Backups nach definierter Frist.
- Unveränderlichkeit finalisierter Belege (heute schon umgesetzt) gilt auch im Backend; Löschung nur über dokumentierten Ablauf.

**Betrieb.**
- Updates mit Migrationsjob und Rollback-Plan; Sicherheitsupdates für Basis-Images; Abhängigkeits-Lizenzen und bekannte Schwachstellen im CI prüfen.
- Dokumentation für Kunden: Verarbeitungsverzeichnis-Vorlage, TOM-Liste, Löschkonzept, Wiederherstellungsablauf.

**Offene Datenschutzpunkte für dich:** Willst du ausschließlich selbst gehostete Installationen unterstützen oder auch Hosting anbieten (dann AVV)? Welche Aufbewahrungsfristen setzt die Software standardmäßig? Wer hat im Betreuungsfall Zugriff auf Kundenserver (Support-Zugang nur befristet und protokolliert)?

## 10. Nächste Schritte (Vorschlag)

1. Taxlab Version 1 fertig testen (Geräteabnahme, Sync läuft seit 28.10.).
2. DMS-Prototyp als eigene Swift-App mit lokalem Speicher und OCR (Dokument rein, Text suchbar, Tag/Korrespondent/Typ).
3. Spike: Hub-Kern aus `TimetrackKit` herauslösen oder neues Hub-Repo (Entscheidung 6.2) mit zwei Modulen (Rechnung, DMS) und der Ereignis-/Link-Tabelle.
4. Server-Implementierungen von `DocumentStore`, `AttachmentStore`, `NumberAllocator`, `SyncTransport` gegen die vorhandenen Protokolltests.
5. PWA (Svelte + shadcn) für Rechnung und DMS, dann weitere Module.
