# Ablösung der paperless-ngx-Instanz: was fehlt, in welcher Reihenfolge

Status: Planung, Stand 25.11.2026, geprüft am Stand `main` 2938d2c (Dateien, Handoffs, Git). Nutzerauftrag 25.11.2026: Der Hub soll die vorhandene paperless-ngx-Instanz ersetzen. Es wurden **keine** Daten dieser Instanz gelesen (`AGENTS.md` Abschnitt 5).

## 1. Was schon da ist

Upload, Hash/Duplikate, OCR mit PDF/A-Archivfassung, Volltextsuche, Dokumentarten und Fakten, Regeln als Vorschläge, Kontakte, Mail-Eingang, Konsumordner, Share-/Scan-API, Löschkonzept/Prüflauf/Export, Backup/Restore mit Hash-Prüfung, DMS-Oberfläche, Paperless-Import (Export-Verzeichnis oder REST-API, Trockenlauf, Bericht, fortsetzbar).

## 2. Offene Branches

Geprüft mit `git branch --no-merged main`, `git cherry` und Vergleich der geänderten Zeilen (`backend`, `pwa`, `contracts`).

| Branch | Befund | Handlung |
| --- | --- | --- |
| `wp-H10b`, `wp-H12`, `wp-H14`, `wp-H16` | geänderte Zeilen identisch mit 6b5d93e, d12d546, f644e78, 0e902d1 auf `main` (nur Rebase) | nichts zu mergen |
| `wp-H11`, `wp-H13`, `wp-H15`, `wp-H2`, `wp-R1`, `review-codex` | laut `git cherry` inhaltsgleich auf `main` | nichts zu mergen |
| `wp-D6x` | enthält nur ein **Revert** des Paperless-Imports (370937e) | **nie mergen** |
| `origin` | nur `main` | – |

Ergebnis: **Kein offener Branch enthält fehlenden Produktcode.** Die Branches bleiben liegen; Löschen entscheidet der Nutzer.

Board-Abweichung: Die Karten „Codex 6“, „Codex 7“, „Codex 10“ und „Lastempfindliche Tests stabilisieren“ standen am 25.11. noch offen, obwohl die zugehörigen Commits (c9f222c, d12d546, 0e902d1) auf `main` liegen. Abschluss nach Prüfung, nicht Teil dieser Planung.

## 3. Offene DMS-Punkte

Einstufung: **B** blockiert die Ablösung, **P** hängt vom Probelauf ab, **S** später.

| Punkt | Quelle | Stufe | WP |
| --- | --- | --- | --- |
| ~~Manifest- und API-Format des Imports nie gegen eine echte Instanz geprüft~~ **erledigt 27.11.2026 (PA1):** gegen paperless-ngx 3.5.1 (API-Version 10) im lokalen Container mit erfundenen Daten, Export und API; acht Abweichungen behoben (darunter: der Export enthielt gelöschte Dokumente) (`docs/handoff/WP-PA1.md`) | Handoff D6 | erledigt | PA1 |
| **Sicherheitsprüfung 27.11.2026 (PA1)** durch den umsetzenden Agenten: Befunde und Belege in `docs/handoff/WP-PA1.md` Abschnitt „Sicherheitsprüfung“; offen: unabhängiger Reviewer-Lauf und TLS gegen eine Instanz mit eigener Zertifizierungsstelle (heute nicht einstellbar) | Handoff D6, H10, Code | erledigt, Rest P | PA1, PA3 |
| ~~Token der REST-Quelle bleibt nach dem Lauf stehen~~ **behoben (PA1, AK-PA1-7):** wird beim Ende des Laufs (fertig, fehlgeschlagen, abgebrochen) und beim Abbruch eines wartenden Laufs gelöscht | Code | erledigt | PA1 |
| ~~Import fragt keine feste API-Version an~~ **behoben (PA1, AK-PA1-5):** `Accept: application/json; version=10` (paperless-ngx 3.5.1); Antwort 406 -> `source_api_version_unsupported` | Code, Paperless-API-Doku | erledigt | PA1 |
| ~~Mehrere Dateifassungen je Dokument nicht berücksichtigt~~ **behoben (PA1, AK-PA1-8):** übernommen wird die neueste Fassung (wie Paperless sie anzeigt), ältere zählt der Bericht (`versions_skipped`, Befund `document_versions_skipped`); die älteren Fassungen selbst werden nicht importiert (Entscheidung für PA3/PA6 offen) | Paperless-API-Doku, Code (Annahme) | erledigt, Rest P | PA1, PA6 |
| Keine Import-Seiten in der PWA (nur API); Notizen nur lesbar | Handoff D6 | B | PA2 |
| Export-Manifest wird komplett geladen (Grenze 128 MiB). Messung PA1 (136 KB Manifest, 10 Dokumente und eine Fassung, fast ohne Text): Dokumenteintrag ca. 1,1 KiB, mit Feldwerten, Notizen und Protokolleinträgen (`auditlog.logentry`, ca. 0,9 KiB je Eintrag) ca. 9 KiB je Dokument; mit OCR-Text grob 10 000–14 000 Dokumente bis zur Grenze (Hochrechnung, nicht an einem großen Bestand gemessen) | D6, Code | P | PA6 |
| ~~REST-Quelle liefert keine Prüfsummen~~ **widerlegt (PA1, AK-PA1-6):** `versions[].checksum` (SHA-256 des Originals je Fassung) und `metadata.archive_checksum`; der Import prüft jede Datei, der Bericht zählt `files_checksum_verified`. Ältere Stände ohne Prüfsummen: `files_without_checksum` | D6 | erledigt | PA1 |
| Besitzer/Rechte nicht übernommen (F-23), Regeln nur als Vorschläge, `documentlink`-Felder nicht unterstützt, Währung in Geldfeldern geht verloren | MODUL-DMS 10 | P | PA3 Bericht → PA6 |
| Nur PDF, PNG, JPEG, TIFF, WebP; keine Office-/ZIP-Dateien | Handoff D2/D4 | P | PA6 |
| Digital signierte und passwortgeschützte PDFs scheitern bei OCR; Textschicht-PDFs ohne PDF/A | Handoff O2 | P | PA6 |
| Keine Miniaturen | Handoff O2 | B (Alltag) | PA4 |
| Keine gespeicherten Ansichten, keine Massenbearbeitung/Mehrfachauswahl | Code, Handoff F4 | B (Alltag, Annahme) | PA5 |
| Mail: nur ungelesene Mails, nur App-Passwörter (kein OAuth2) | Handoff D4/F5b | P | PA3 Inventur |
| Scanner, die per SMB/FTP liefern (F-22) | OFFENE-FRAGEN | P | BR4 |
| Prüflauf ohne Zeitplaner; alte Export-ZIPs bleiben und zählen zur Quota | Handoff D5 | B (Betrieb) | PA7 |
| Betrieb: echter Swarm ungetestet (H4, nur falls Swarm), TLS-Proxy/HSTS ungeprüft, getrennte Migrationsrolle nur dokumentiert | Handoff H9 | B (Betrieb) | PA7, H4 |
| PWA nicht installierbar (WP-F3), nie dunkel | Struktur-Abgleich | B (Alltag, Annahme) | F3, ST4 |
| S3-Backend fehlt (F-06) | Handoff D1 | S | – |
| Ereignisse/Webhooks (K7), globale Suche (S2), Dokumentversionen, Freigabelinks, Objektrechte je Dokument, ASN-Barcode-Trennblätter | Code/Roadmap | S, sofern der Probelauf nichts anderes zeigt | K7, S2 |
| Aufbewahrung/GoBD fachlich ungeprüft (F-24) | OFFENE-FRAGEN | Nutzerentscheidung | – |

## 4. Reihenfolge

| Schritt | WP | Wer | Fertig, wenn |
| --- | --- | --- | --- |
| 0 | ST1 CI | Agent | Prüfungen laufen auf GitHub |
| 1 | PA1 Import gegen **echte paperless-ngx im lokalen Container mit erfundenen Dokumenten** (Export und API) + Sicherheitsprüfung | Agent | Abweichungen behoben; geprüfte Paperless-Version dokumentiert (**erledigt 27.11.2026: paperless-ngx 3.5.1, API-Version 10**, `docs/handoff/WP-PA1.md`) |
| 2 | PA2 Import in der PWA | Agent | Trockenlauf und Bericht ohne Kommandozeile |
| 3 | PA7 Betrieb (Teil Probelauf: Zielrechner, Backup, Speicherbedarf) | Agent bereitet vor, **Nutzer setzt auf** | Hub läuft beim Nutzer, Restore erprobt |
| 4 | **PA3 Probelauf** (Trockenlauf gegen die echte Instanz per API-Lese-Token, erst nach PA1 und PA2) + Inventur der Eingangswege | **Nutzer** | Bericht mit Anzahlen liegt vor; Lückenliste bewertet |
| 5 | PA4, PA5, PA6, F3, ST4 | Agent | Lücken der Stufe B/P geschlossen |
| 6 | PA7 Rest | Agent/Nutzer | Zeitplan für Prüflauf, Aufräumen, Aktualisierung erprobt |
| 7 | **PA8** Vollimport, Parallelbetrieb, Umschalten | **Nutzer** | Abnahme unten erfüllt |

Scan-Bridge (BR1–BR4) und App (APP-M0 ff.) sind **nicht** Voraussetzung, außer die Inventur zeigt, dass ein Eingangsweg ohne sie wegfällt.

## 5. Probelauf (PA3)

**Entschieden (Nutzer, 25.11.2026, F-34):** API-Token nur zum Lesen, **vom Nutzer selbst direkt im Hub eingetragen**. Start erst nach PA1 und PA2 (die Eingabeseite entsteht mit PA2; heute gibt es dafür nur die API-Route). Der Export mit `document_exporter` bleibt möglich, etwa zur Gegenprüfung von Prüfsummen, ist aber nicht der gewählte Weg.

Ablauf (die genaue Anleitung ist Teil von PA3, geprüft in PA1):

1. **In Paperless:** eigenen Benutzer anlegen, nur Leserechte (Dokumente, Korrespondenten, Dokumenttypen, Tags, Speicherpfade, Zusatzfelder, Notizen). Das Token hat keine eigenen Grenzen, es darf, was der Benutzer darf. Er sieht Objekte ohne Besitzer, eigene und ausdrücklich freigegebene; Dokumente anderer Besitzer müssen für ihn zum Lesen freigegeben sein, sonst fehlen sie im Lauf. Kein Administrator-Token.
2. **Am Hub:** `SECRET_KEY` gesetzt; die Paperless-Adresse muss `https` mit einem **öffentlich gültigen Zertifikat** sein (entschieden 27.11.2026: keine eigene Zertifizierungsstelle einstellbar; selbst ausgestellte Zertifikate scheitern mit `source_tls_failed`, siehe Anleitung PA3: Zertifikat einer öffentlichen Stelle, z. B. Let's Encrypt, oder Export mit `document_exporter`); `DMS_IMPORT_HOST_ALLOWLIST` auf diesen Host. Steht Paperless im Heimnetz, zusätzlich `DMS_ALLOW_INTERNAL_TARGETS=true` für Backend und Worker (gilt dann auch für Mail-Quellen).
3. Der Nutzer trägt Adresse und Token in der Hub-Oberfläche ein und startet `dry_run`.
4. Der Nutzer vergleicht die Anzahl der Dokumente mit Paperless und gibt nur Zahlen und Befundcodes weiter.
5. Token in Paperless widerrufen; für den Vollimport (PA8) ein neues erzeugen.

Lauf auf der Hardware des Nutzers. Agents erhalten **weder Token noch Dateien noch Titel/Namen**; das Token kommt nie in Chat, Board, Repository oder einen Befehl im Shell-Verlauf. Der Trockenlauf schreibt nichts ins DMS.

## 6. Abnahme zum Umschalten (PA8, Vorschlag)

1. Vollimport ohne ungeklärte Fehler; Anzahl Dokumente, Korrespondenten, Typen, Tags, Notizen entspricht der Quelle bzw. jede Abweichung ist erklärt.
2. Prüfsummen aller Originale stimmen (über die API nur, falls PA1 das belegt; sonst Gegenprüfung mit einem Export); Prüflauf grün; höchste ASN übernommen.
3. Stichprobe von 20 Dokumenten: finden, öffnen, Metadaten richtig.
4. Alle genutzten Eingangswege liefern in den Hub (mindestens zwei Wochen Parallelbetrieb).
5. Backup und Restore mit dem echten Bestand erprobt.
6. Danach Paperless nur noch lesend; **nicht löschen**, bis der Nutzer es entscheidet. Rückweg: Paperless wieder als Eingang, im Hub neu erfasste Dokumente per Export zurückholen.

**Zeitfenster:** Änderungen in Paperless nach dem Vollimport kommen nur durch einen weiteren Lauf an, und der ergänzt nur Fehlendes (keine geänderten Metadaten). Deshalb Eingangswege zum Stichtag umstellen.
