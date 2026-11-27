# Scan-Bridge: Netzwerkscanner über SANE (eSCL/WSD)

Status, Stand 27.11.2026: **Hub-Seite (WP-BR1) umgesetzt** (Abschnitt 3 ist jetzt Teil von `contracts/openapi.yaml`, Belege `docs/handoff/WP-BR1.md`); Bridge-Dienst, PWA und Betrieb (BR2–BR4) sind Planung, noch kein Code. Arbeitspakete in `ROADMAP.md`, Phase 8.

## 1. Ziel und Abgrenzung

- Ein Nutzer wählt in der **PWA oder in der App** einen Scanner, startet den Scan, und das Dokument erscheint im DMS.
- Die Anbindung läuft nativ über **SANE** mit dem Backend **sane-airscan** (eSCL/„AirScan“ und WSD).
- Die Bridge ist ein **eigener Dienst im Heimnetz** (neben dem Scanner), nicht Teil des Hubs. Der Hub braucht weder SANE noch Zugriff auf das Heimnetz.
- Der Hub bleibt **zustandslos** (ADR 0003): Geräte, Aufträge und Leases liegen in PostgreSQL.
- Nicht-Ziele: Scanner-Treiber im Hub, eingehende Ports im Heimnetz, SMB/FTP-Server im Hub.

## 2. Aufbau

```
PWA / DMS-App ──HTTPS──▶ Hub (Repliken) ──▶ PostgreSQL
                              ▲
                              │ nur ausgehende HTTPS-Verbindungen der Bridge (API-Token)
                     Scan-Bridge (Heimnetz)
                              │ scanimage (eigener Prozess)
                     SANE + sane-airscan ──eSCL/WSD──▶ Netzwerkscanner
```

**Entscheidung (Vorschlag): Der Hub vermittelt, die Bridge fragt ab.** Verworfen: Der Browser spricht die Bridge direkt an. Das bräuchte TLS-Zertifikate im Heimnetz, CORS und Zugriff aus einer HTTPS-Seite auf private Adressen (von Browsern eingeschränkt), und die App bräuchte einen zweiten Weg. Mit der Vermittlung funktionieren PWA und App gleich, auch wenn der Hub woanders läuft; unterwegs lässt sich der Scan nur starten, wenn der Nutzer das Papier vorher eingelegt hat.

Abfrage: kurzes Polling (Vorschlag 3 s, bei Leerlauf bis 15 s). Kein Long-Polling in V1, kein Zustand in einer Hub-Instanz.

## 3. Schnittstelle (umgesetzt in WP-BR1, maßgeblich ist `contracts/openapi.yaml`)

Alle Pfade unter `/api/v1/tenants/{tenant}/dms/scan`.

**Bridge (ein an den Mandanten gebundenes API-Token mit dem Scope `dms.scan.bridge` für diese Routen und `dms.upload` für das Ergebnis; die Rolle des Token-Inhabers braucht `dms.source.manage`, also Owner oder Buchhaltung, geprüft bei jedem Aufruf):**

| Route | Zweck |
| --- | --- |
| `PUT bridge` | Lebenszeichen, Version, vollständige Geräteliste mit Fähigkeiten (ersetzt die bisherige Liste) |
| `POST bridge/claim` | nächsten Auftrag der eigenen Geräte mit Lease übernehmen (`204`, wenn keiner da ist) |
| `PUT bridge/jobs/{job}` | Zustand, Seitenzahl, Fehlercode, Lease verlängern, `document_id` melden; Antwort nennt Nutzerbefehle (`next_page`, `finish`, `cancel`) |

**Ergebnis:** über die **vorhandene Scan-API** `POST /api/v1/tenants/{tenant}/dms/share` (Scope `dms.upload`, Roh-Body, Query `filename`, `title`, `doc_date`, `document_type_id`, `archive`) mit `Idempotency-Key: scan-<job-id>`. Die Route bleibt unverändert; Wiederholungen erzeugen kein zweites Dokument. Die Antwort enthält das Dokument, dessen ID die Bridge am Auftrag meldet.

**Nutzer (Sitzung; Berechtigung `dms.scan.use` für Owner, Buchhaltung und Mitglied; ein App-Token für diese Routen kommt mit WP-AB1):** `GET devices`, `POST jobs`, `GET jobs/{job}`, `POST jobs/{job}/next-page`, `…/finish`, `…/cancel`.

### Festlegungen der Umsetzung (WP-BR1)

- **Eine Bridge je Token** (`dms_scan_bridges.token_id` eindeutig). `PUT bridge` legt sie beim ersten Aufruf an und ersetzt die Geräteliste; fehlende Geräte werden inaktiv (`active = false`), ihre ID bleibt gültig, wiederkehrende behalten sie. `key` ist ein SHA-256-Hash (64 Hex-Zeichen), nie eine IP oder URL; die Datenbank prüft das ebenfalls. Höchstens 16 Geräte, je Fähigkeitsliste 1 bis 8 Einträge.
- **Positivlisten:** Quelle `flatbed`, `adf`, `adf_duplex`; Farbe `color`, `gray`, `bw`; Format `a4`, `letter`; Auflösung 50 bis 1200 dpi. Ein Auftrag darf nur Werte verlangen, die das Gerät meldet; fehlende Werte kommen aus den Fähigkeiten (flatbed, 300 dpi, color, a4, sonst der erste Wert). Optional `title`, `document_type_id`, `archive` für das Dokument.
- **Online:** Eine Bridge gilt als online, wenn ihr letzter Aufruf höchstens 60 s her ist (Datenbankzeit); für eine offline Bridge wird kein Auftrag angelegt (`409 scan_bridge_offline`), damit kein Scan überraschend später startet.
- **Lease** 60 s ab Datenbank-`now()`; jeder Aufruf der Bridge und der Nutzerrouten beendet abgelaufene Leases (`failed`/`bridge_lost`, mit Abbruchwunsch `cancelled`) und nicht abgeholte Aufträge nach 300 s (`failed`/`expired`). Übernehmen: `FOR UPDATE SKIP LOCKED`, genau ein Aufrufer gewinnt. Eine verlorene Antwort des Übernehmens wird nicht wiederholt, sondern endet über die Lease.
- **Befehle des Nutzers** (`next_page`, `finish`, `cancel`) stehen am Auftrag, bis die Bridge den Zustand wechselt (`next_page` bis `scanning`, `finish` bis `uploading`, `cancel` bis `cancelled`); die Antwort der Bridge nennt sie in `commands`. Abbrechen: nicht abgeholt sofort `cancelled`, ab `uploading` nicht mehr möglich.
- **Ergebnis:** Die Bridge lädt über `POST dms/share` mit `Idempotency-Key: scan-<job>` hoch und meldet die Dokument-ID; der Hub nimmt nur ein Dokument an, das der Upload dieses Tokens mit genau diesem Schlüssel war (gespeicherte Antwort des Schlüssels im selben Mandanten, Eingangsvorgang `share_ext` mit dem Token als Herkunft, nicht im Papierkorb). Ein vorab über die Oberfläche unter diesem Schlüssel angelegtes Dokument wird abgewiesen; wer den Schlüssel vorab belegt, kann den Scan nur verhindern (der Auftrag endet dann über Abbruch oder Fehler), nicht umlenken. Ein spätes Ergebnis nach `bridge_lost` setzt denselben Auftrag derselben Bridge auf `done`.
- **Befehle und Abbruch:** Liegt ein Abbruchwunsch vor, darf die Bridge nur noch `cancelled` oder `failed` melden. `done`, `cancelled` und `failed` (gleicher Code) sind wiederholbar.
- **Vertrauensgrenze:** Die Bridge handelt mit der Rolle ihres Token-Inhabers (Owner oder Buchhaltung); Titel, Typ und Archivierung des Dokuments setzt sie nach den Parametern des Auftrags, der Hub vergleicht sie nicht. Jeder Nutzer mit `dms.scan.use` darf alle Aufträge des Mandanten sehen und steuern (gemeinsame Scanner; Entscheidung dieser Umsetzung, protokolliert in `docs/handoff/WP-BR1.md`). Pro Token läuft eine Bridge-Instanz; zwei Prozesse mit demselben Token überschreiben einander die Geräteliste.
- **Audit:** zusätzlich `dms.scan.job.command` (Befehl des Nutzers).
- **Audit:** `dms.scan.bridge.registered`, `dms.scan.job.created`, `.done`, `.failed`, `.cancelled` (nur IDs und Fehlercodes, keine Namen oder Adressen).
- **Offen für BR2/BR3:** Aufräumen alter Aufträge (heute bleiben sie als Verlauf), Listenroute für Aufträge, Verwaltung (Löschen) einer Bridge.

### Datenmodell

| Tabelle | Inhalt |
| --- | --- |
| `dms_scan_bridges` | Mandant, Token-ID, Name, Version, `last_seen_at` |
| `dms_scan_devices` | Bridge, `device_key` (Hash, **keine IP/URL** im Hub), Anzeigename, Fähigkeiten (Quellen, Auflösungen, Farbmodi, Formate), `seen_at` |
| `dms_scan_jobs` | Mandant, Gerät, Parameter, Zustand, `lease_until`, Seiten, `document_id`, `error_code`, Auftraggeber, Zeiten |

### Zustände

`queued → claimed → scanning → (waiting_for_page ↔ scanning) → uploading → done`; Seitenwege `failed`, `cancelled`.

- Lease und Ablauf über DB `now()`. Je Gerät höchstens ein aktiver Auftrag (Constraint).
- Läuft eine Lease ab, wird der Auftrag **`failed` (`bridge_lost`)** und **nicht** automatisch wiederholt: Ein zweiter Einzug könnte Papier doppelt oder falsch verarbeiten. Lädt dieselbe Bridge später doch noch hoch, darf sie den Auftrag auf `done` setzen (der Idempotency-Key verhindert Doppel).
- Nicht abgeholte Aufträge verfallen (Vorschlag 5 Minuten), damit kein Scan überraschend startet.

## 4. Der Bridge-Dienst

- Eigenes Swift-Paket `bridge/` im Repo (gleicher Stack, AGPL-3.0-only), keine Abhängigkeit von `HubKit`, kein Link gegen `libsane`.
- Ruft **`scanimage`** als eigenen Prozess mit Argumentliste auf (nie über eine Shell): Geräteliste, Optionen je Gerät, Seiten als Bilddateien (`--batch`). Die genauen Optionsnamen und Exit-Codes je Gerät werden in BR2 an den installierten Versionen geprüft, nicht angenommen.
- Parameter kommen nur aus einer Positivliste, abgeglichen mit den gemeldeten Fähigkeiten (Quelle Flachbett/Einzug/Duplex, Auflösung, Farbe/Grau/Schwarzweiß, A4/Letter).
- Seiten werden zu **einem PDF** zusammengefügt (Vorschlag `img2pdf` als weiterer eigener Prozess; Lizenz in BR2 prüfen). OCR macht wie bisher der Hub-Worker.
- Grenzen: Seiten je Auftrag, Gesamtgröße ≤ `DMS_MAX_UPLOAD_BYTES` (Standard 100 MiB), Zeitlimit je Scan, temporäre Dateien in `tmpfs`.
- Ist der Hub beim Upload nicht erreichbar, bleibt das PDF in einem Zwischenablage-Volume (Zustand ist **in der Bridge** erlaubt) mit Wiederholung und Löschfrist (Vorschlag 24 h); danach `failed`.
- Konfiguration nur über Umgebung: `HUB_URL`, `HUB_TOKEN_FILE`, `BRIDGE_NAME`, Grenzen, Poll-Intervall. Keine eigene Weboberfläche, kein offener Port außer optional lokalem Healthcheck.
- Der Dienst läuft ohne Root; `https` zum Hub ist Pflicht (Ausnahme nur ausdrücklich für lokale Tests).

### Geräte finden

sane-airscan sucht über DNS-SD (Avahi) und WS-Discovery. In Containern braucht das Multicast im Heimnetz:

| Variante | Vorgehen | Bewertung |
| --- | --- | --- |
| A (zuverlässig) | feste Einträge in `airscan.conf`, Abschnitt `[devices]` (`Name = URL, eSCL|WSD`), `discovery = disable` | Standard in der Doku |
| B (automatisch) | Container mit Host-Netz und Avahi des Hosts | nur Linux; auf Docker Desktop nicht zu erwarten (zu prüfen) |
| C | Bridge als Systemdienst direkt auf Raspberry Pi/NAS | später, falls Container stören |

USB-Scanner sind über andere SANE-Backends möglich (Geräte durchreichen), aber kein Ziel von V1. `saned` (Netzprotokoll von SANE) wird nicht benötigt.

### Images

Multi-Arch `linux/amd64` und `linux/arm64`. Ein **neues Image-Ziel in einer Registry legt nur der Nutzer fest**; bis dahin wird lokal gebaut.

## 5. Einordnung F-22 (Mail-Eingang und Scanner-Brücke)

F-22 betrifft Wege, bei denen **das Gerät sendet** (Scan-to-Mail, Scan-to-SMB/FTP). Umgesetzt (Annahme aus D4): IMAP-Polling, Share-/Scan-API, Konsumordner im Worker-Volume. Die Scan-Bridge ergänzt den Weg, bei dem **der Nutzer den Scan anstößt**; sie ersetzt die Push-Wege nicht, denn die Gerätetaste „Scan an …“ lässt sich über SANE nicht empfangen.

**Vorschlag zu F-22 (nicht entschieden):** Kein SMB-/FTP-Server im Hub. Wer Scan-to-SMB nutzt, betreibt die Freigabe im Heimnetz; die Bridge kann sie optional überwachen (BR4: Ordner → Scan-API, erst nach stabiler Dateigröße, nach Erfolg verschieben). Scan-to-Mail bleibt wie umgesetzt.

## 6. Scannen aus der DMS-App

| Plattform | Weg 1: Bridge (über den Hub) | Weg 2: direkt am Gerät |
| --- | --- | --- |
| iPhone, iPad, Vision Pro | ja (gleiche Nutzer-Routen wie die PWA) | **nicht** mit ImageCaptureCore: `ICScannerDevice` ist im iOS-SDK 27.2 als `IC_UNAVAILABLE(ios)` markiert, die Apple-Dokumentation nennt nur macOS. Optional später ein eigener eSCL-Client (Bonjour, lokale Netzwerkfreigabe), `APP-DMS.md` APP-M7 |
| Mac | ja | **ja**, `ICDeviceBrowser` + `ICScannerDevice` (nur native macOS-App, nicht Mac Catalyst) |
| Watch | nur „fertig“-Meldungen | nein |

Direkt gescannte Seiten gehen über den normalen Upload der App; die Bridge ist daran nicht beteiligt. Im eigenständigen Modus ohne Hub ist Weg 2 (Mac) bzw. die Kamera der einzige Weg.

## 7. Lizenzen

Quellen am 25.11.2026 gelesen: `LICENSE` von sane-backends (gitlab.com/sane-project/backends) und von sane-airscan (github.com/alexpevzner/sane-airscan). **Keine Rechtsberatung.**

| Bestandteil | Lizenz laut Quelle | Folge |
| --- | --- | --- |
| SANE-Frontends (`scanimage`) | GNU GPL (Version je Dateikopf in BR2 festhalten) | nur als eigener Prozess starten |
| SANE-Backend-Bibliotheken | GPL mit SANE-Linking-Ausnahme; laut `LICENSE` **nicht alle** Backends mit Ausnahme, einige mit Zusatzbedingungen | werden nur von `scanimage` geladen, nie von unserem Prozess |
| SANE-API/-Protokoll | gemeinfrei erklärt | – |
| sane-airscan | GPL-2.0-oder-später mit Linking-Ausnahme | wie oben |
| `img2pdf`, Avahi, Bildbibliotheken | noch zu prüfen | in BR2 in `docs/LIZENZEN.md` und SBOM |
| Bridge-Code | AGPL-3.0-only | wie der Hub |

- **Einordnung:** Die Bridge spricht mit den GPL-Programmen nur über Programmaufruf, Argumente und Dateien. Nach üblicher Lesart sind das getrennte Werke; das gemeinsame Verteilen in einem Image ist „bloße Zusammenstellung“ (GPLv2 Abschnitt 2). Die FAQ der FSF dazu konnte am 25.11. nicht abgerufen werden (HTTP 403) und ist damit nicht belegt.
- **Beim Weitergeben eines Images** entstehen für die enthaltenen GPL-Programme Pflichten (Lizenztexte beilegen, Quellen bereitstellen bzw. benennen; wie beim Worker-Image: Distributionspakete mit Versionsliste). Das wird Teil von BR4 und vor einer Veröffentlichung vom Nutzer bestätigt.

## 8. Tests

- **E2E ohne Hardware:** SANE bringt ein virtuelles Backend `test` mit (`sane-test`). Lauf: Postgres + Hub + Bridge-Container mit `test`-Gerät → Auftrag über PWA (Playwright) → Dokument im DMS mit erwarteter Seitenzahl. Verfügbarkeit im gewählten Distributionspaket ist in BR2 als erster Schritt zu belegen.
- **eSCL-Pfad:** kleiner eSCL-Attrappen-Server in den Tests, in `airscan.conf` fest eingetragen. Echtgeräte-Probe macht der Nutzer.
- **Hub:** Zwei-Instanzen-Test (zwei Bridges/Verbindungen übernehmen denselben Auftrag nur einmal), Lease-Ablauf, Mandantentrennung, Rechte je Route, Token ohne Scope.
- **Sicherheit:** manipulierte Parameter/Gerätenamen, zu große Seitenzahl, abgebrochener Upload.

## 9. Arbeitspakete

| WP | Inhalt | Abh. |
| --- | --- | --- |
| BR1 | Hub: Tabellen, Routen, Scope `dms.scan.bridge`, Berechtigung `dms.scan.use`, Vertrag (**fertig 27.11.2026**) | ST2 |
| BR2 | Bridge-Dienst mit SANE, Container, E2E mit `test`-Backend, Lizenzeintrag | BR1 |
| BR3 | PWA: Scanner wählen, Scan starten, nächste Seite/Fertig/Abbrechen, Status; hell und dunkel | BR2, ST4 |
| BR4 | Betrieb: Anleitung, `airscan.conf`, SBOM/Hinweise, optionaler Ordner-Eingang (F-22) | BR2 |

## 10. Offen

Welches Scanner-Modell steht zur Verfügung (eSCL, WSD, USB)? Auf welcher Hardware läuft die Bridge? Image-Ziel? Direkter eSCL-Client auf iOS gewünscht? Alles Entscheidungen des Nutzers (`OFFENE-FRAGEN.md` F-35).
