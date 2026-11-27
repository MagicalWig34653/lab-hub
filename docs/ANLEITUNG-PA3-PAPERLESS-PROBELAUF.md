# Anleitung PA3: Probelauf des Paperless-Imports (Trockenlauf)

Stand 28.11.2026, geprüft gegen paperless-ngx 3.5.1 (API-Version 10) und den Hub-Stand nach WP-PA1R. Gehört zu WP-PA3 (`docs/ROADMAP.md`, Akzeptanz AK-PA3-1) und zu `docs/PAPERLESS-ABLOESUNG.md`, Abschnitt 5. Der Probelauf läuft auf der Hardware des Nutzers; weder Token noch Dateien, Titel oder Namen gehen an Agents, Board oder Repository. Der Trockenlauf (`dry_run`) schreibt nichts ins DMS; weitergegeben werden nur Zahlen und Befundcodes.

Diese Fassung enthält die Netzvoraussetzungen (öffentlicher Name, Zertifikat, **interne Ziele und Allowlist**) und das Aufräumen. Die Eingabeseite in der PWA entsteht mit WP-PA2; bis dahin gibt es dafür nur die API-Route (`POST /api/v1/tenants/{tenant}/dms/imports`, Recht `dms.import.manage`).

## 1. In Paperless: Benutzer nur mit Leserechten

Eigenen Benutzer anlegen, nur Leserechte auf Dokumente, Korrespondenten, Dokumenttypen, Tags, Speicherpfade, Zusatzfelder und Notizen; **kein** Administrator-Token. Das Token darf, was der Benutzer darf. Dokumente anderer Besitzer müssen für ihn zum Lesen freigegeben sein, sonst fehlen sie im Lauf (der Bericht nennt das als Befund `reference_not_visible` bzw. weist auf die Sicht des Token-Benutzers hin).

## 2. Voraussetzungen am Hub

- `SECRET_KEY` ist gesetzt (das Token liegt nur während des Laufs verschlüsselt in der Datenbank und wird beim Ende gelöscht).
- Die Paperless-Adresse ist `https://<öffentlich gültiger Name>` mit einem Zertifikat einer öffentlichen Stelle (z. B. Let's Encrypt). Eine eigene Zertifizierungsstelle lässt sich bewusst nicht einstellen (Entscheidung des Nutzers, 27.11.2026); ein selbst ausgestelltes Zertifikat endet mit `source_tls_failed`. Weg ohne Zertifikat: Export mit `document_exporter`.
- Die Adresse besteht aus einem ASCII-Hostnamen (oder IPv6 in Klammern), optional Port und einfachem Pfad; keine Prozentkodierung, kein `@`, `?`, `#` und keine IPv4 mit führenden Nullen (`invalid_url`). IP-Adressen als Ziel sind sinnlos: das Zertifikat gilt dem Namen.
- Der Worker braucht ausgehend nur den Paperless-Host.

## 3. Paperless im Heimnetz: interne Ziele und Allowlist

**Wann nötig.** Der öffentlich gültige Name der Instanz löst im Heimnetz auf eine private Adresse auf (Router-/DNS-Umschreibung, `192.168.x.x`, `10.x.x.x`, `172.16–31.x.x`, `100.64.x.x`, Loopback, Link-Local, ULA). Der Hub sperrt solche Ziele standardmäßig (Schutz vor Zugriffen auf das eigene Netz, WP-H10). Der Lauf endet dann als `failed` mit `host_not_allowed`: im Bericht des Laufs, nicht schon beim Anlegen, weil der Name erst im Worker aufgelöst wird. Heißt der Name auf `.local`, `.internal`, `.lan`, `.home.arpa`, `.intranet`, `.corp`, `.localdomain` oder ist er `localhost`, lehnt schon das Anlegen mit 422 ab.

**Was einzustellen ist, immer beides zusammen** (Datei `deploy/.env`, gilt für `backend` **und** `worker`; Compose und Swarm reichen beide Variablen an beide Dienste weiter):

```
DMS_IMPORT_HOST_ALLOWLIST=paperless.example.org
DMS_ALLOW_INTERNAL_TARGETS=true
```

- `DMS_ALLOW_INTERNAL_TARGETS` hebt die Sperre für **alle** Ziele auf, nicht nur für Paperless. Es zählt nur der genaue Wert `true` (Groß-/Kleinschreibung egal; `1` oder `yes` gelten nicht).
- Die Allowlist ist das Gegengewicht: Sie nennt **genau den einen Host** (`host` oder `host:port`, Kleinbuchstaben, mehrere kommagetrennt). Ein Eintrag **ohne Port erlaubt jeden Port** dieses Hosts; soll nur der HTTPS-Standardport gelten, `paperless.example.org:443` eintragen. Ist die Allowlist **leer** (Standard), gibt es **keine** Einschränkung: Schalter an und Allowlist leer erlaubt dem Import jedes interne Ziel. Den Schalter deshalb nie ohne Allowlist setzen.
- Die Allowlist prüft Backend (beim Anlegen) und Worker (vor dem Lauf, die Konfiguration kann sich ändern). Der Worker löst den Namen auf, prüft alle Adressen und verbindet nur zur geprüften Adresse; das Zertifikat wird weiter gegen den Namen geprüft.
- **Mail-Quellen** teilen sich den Schalter, haben aber eine eigene Liste: Solange er an ist, kann jemand mit dem Recht für Mail-Quellen einen internen IMAP-Host (Port 993, weitere Ports nur über `DMS_MAIL_PORT_ALLOWLIST`) eintragen. Deshalb `DMS_MAIL_HOST_ALLOWLIST` auf die tatsächlich genutzten Mailserver setzen oder in der Zeit keine Mail-Quelle anlegen oder ändern.
- Übernehmen: Dienste `backend` und `worker` neu erstellen, bei Compose `docker compose --env-file deploy/.env -f deploy/compose/compose.yaml up -d backend worker` (so ruft es auch `deploy/update.sh` auf). Unter Swarm gilt dasselbe über den Stack (nicht unter Swarm getestet). Der Betrieb am Live-System bleibt beim Nutzer.

**Danach wieder abschalten** (sobald der Trockenlauf beendet ist, nicht erst nach dem Vollimport):

1. `DMS_ALLOW_INTERNAL_TARGETS=false` (oder Zeile löschen) und, falls vorher leer, die Allowlist wieder leeren; `backend` und `worker` neu erstellen. Die Allowlist allein ist harmlos und darf stehen bleiben.
2. Kontrolle: Einen neuen Trockenlauf mit derselben Adresse und einem beliebigen Platzhalter als Token starten. Er muss als `failed` mit `host_not_allowed` enden (der Hub prüft das Ziel, bevor er verbindet; das Platzhalter-Token verlässt den Hub nicht und wird mit dem Lauf gelöscht).
3. Für den Vollimport (PA8) brauchst du den Schalter erneut, wieder mit Allowlist und wieder mit Abschalten danach.

## 4. Lauf und Zahlen

1. Adresse und Token trägt der Nutzer selbst im Hub ein (nie in Chat, Board, Repository oder Shell-Verlauf), Modus `dry_run`.
2. Der Bericht nennt Anzahlen (u. a. Dokumente gesehen, Notizen, Fassungen, Dokumente im Papierkorb) und Befundcodes. Dokumentenzahl mit der Anzeige in Paperless vergleichen; ältere Fassungen eines Dokuments zählt der Bericht (`versions_skipped`), übernommen wird die neueste.
3. Große Dateien: Ein Download wird nicht durch die Anfragefrist abgeschnitten (Messung WP-PA3V, `docs/handoff/WP-PA3V.md`). Der Lauf endet mit `source_unreachable` nur, wenn Paperless 60 Sekunden lang gar keine Daten mehr liefert. Eine Datei über `DMS_MAX_UPLOAD_BYTES` (Standard 100 MiB) wird übersprungen und als Befund `file_too_large` gezählt.
4. Nur Zahlen und Befundcodes weitergeben, keine Titel, Namen oder Dateien.

## 5. Aufräumen

1. Token in Paperless widerrufen (der Hub hat es schon gelöscht, auch nach einem Absturz des Workers).
2. Schalter zurücksetzen (Abschnitt 3).
3. Genutzte Eingangswege und Funktionen der Instanz auflisten (AK-PA3-3); Lücken werden in WP-PA6 eingestuft.
