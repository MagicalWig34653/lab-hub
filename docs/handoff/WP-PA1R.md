# Bericht WP-PA1R: unabhängiger Sicherheits-Review des Paperless-Imports (vor PA3)

Stand 27.11.2026, am damaligen `origin/main` (7bad475; Import-Code seit bac77a2 unverändert, die Änderungen seither betreffen Rechnung, Renderer und Images). Ein Reviewer mit frischem Kontext: nichts aus `docs/handoff/WP-PA1.md` (Abschnitt „Sicherheitsprüfung D6“) wurde übernommen, ohne es am Code, an einem Test oder an einer Probe nachzuweisen. Geprüft nur mit erfundenen Daten, lokal: eigener Postgres-Container, lokale paperless-ngx-3.5.1-Instanz (Wegwerf-Container), Listener und Testserver auf 127.0.0.1. Keine echte Instanz, kein Token von Lino, kein Deploy.

## Ergebnis in Kürze
- **Zwei bestätigte Befunde, beide behoben** (Test zuerst rot, dann Fix), beide **mittel**: (1) SSRF-Zielprüfung und HTTP-Client lesen verschiedene Hosts (ausnutzbar, wo der Resolver die Namen auflöst, etwa auf dem Mac; im Linux-Betrieb verhindert es heute nur die Strenge von `getaddrinfo`), (2) Token bleibt nach Absturzschleife des Workers gespeichert, Quelle blockiert.
- Ein kleiner Befund (niedrig, behoben): Der bestehende TLS-Test bestand ohne Zertifikatsprüfung (Server lud den Schlüssel nicht).
- Drei weitere kleine Punkte als Karten auf dem Board (siehe unten).
- 65 oder 67 Prüfungen: **67** (Lauf unten).
- Für PA3 gilt jetzt: Import-Code ist nach den Fixes nicht mehr der Grund, PA3 zu verschieben; Voraussetzungen für den Betrieb stehen unter „Für PA3“.

## 65 oder 67 E2E-Prüfungen
`scripts/e2e-paperless-import.sh` gegen paperless-ngx 3.5.1 (frisch gezogenes Image, lokal): **67 `ok`-Zeilen, 0 `FEHL`**, Ausgabe „E2E Paperless-Import: alles ok“. Die Übergabe nennt 65. Der Unterschied sind die zwei Prüfungen zu Befund 8 der Übergabe (Papierkorb: „Dokument im Papierkorb übersprungen und gezählt“ und „Befund nennt das Dokument im Papierkorb“), die erst bei der Behebung dazukamen; eine Zählung davor ergibt 65. Aus der Git-Historie allein ist das nicht belegbar (die Datei hat nur einen Commit), die Zählung des Laufs ist es. Nach den Fixes dieses Reviews kommen drei Prüfungen zu SSRF-Schreibweisen hinzu (siehe Befund 1), also jetzt **70** (Lauf siehe „Belege“).

## Ergebnis je Prüffeld

### SSRF (Zieladresse, Weiterleitung, `next`)
| Prüfung | Ergebnis | Datei:Zeile |
| --- | --- | --- |
| Sperrliste (Loopback, privat, Link-Local, Metadaten, ULA, IPv4-in-IPv6, 6to4, NAT64, alle IP-Schreibweisen) | in Ordnung | `HubCore/Network/NetworkTarget.swift:75-109` (Sperrliste), `:59-71` (Literale über `inet_aton`/`inet_pton`) |
| Auflösung vor dem Lauf, **alle** Adressen geprüft, geprüfte IP festgelegt, TLS-Name bleibt der Host | in Ordnung (Rebinding-Schutz); Nachweis des Verbindungspfads in `AsyncHTTPClient` 1.36.2 (`ConnectionPool.swift:92-103`, `applyDNSOverride`: neuer Connect-Host, `serverNameIndicatorOverride` = Originalhost) | `NetworkTarget.swift:122-135`, `Import/PaperlessAPISource.swift:71-79` (`vetTarget`), `:100` (`dnsOverride`); Aufruf im Worker `DMSPaperlessImport.swift:208-209` |
| **Der geprüfte Host ist der Host, zu dem verbunden wird** | **Befund 1 (mittel), behoben** | `PaperlessAPISource.swift:41-65` (neuer `parse`) |
| Weiterleitungen | in Ordnung: `redirectConfiguration: .disallow`, jede 3xx-Antwort endet in `source_http_error`; das Token geht nur an den eingetragenen Host | `PaperlessAPISource.swift:98`, Statusabbildung `:128-135`; Test `testAKD9_apiImportMatchesExportImport` |
| `next` der Seitenabfrage | in Ordnung, jetzt **mit eigenem Test**: nur `null`/nicht `null` wird gelesen, die Seitennummer bildet der Hub selbst; ein `next` auf einen fremden Host erzeugt keine Verbindung | `PaperlessAPISource.swift:150-163`; Test `testAKPA1R_4_nextLinkIsNeverFollowed` |
| Allowlist gilt auch im Worker | in Ordnung | `DMSPaperlessImport.swift:208` (zweite `parse`), `PaperlessAPISource.swift:60` |
| Nur GET, nur lesend | in Ordnung | `PaperlessAPISource.swift:109-111` (`req.method = .GET`) |

**Befund 1 – mittel, bestätigt: Zielprüfung und HTTP-Client lesen verschiedene Hosts (SSRF-Umgehung der Zielprüfung).**
- Der alte `parse` zerlegte die Adresse mit `URLComponents` und prüfte `c.host`. `URLComponents` **dekodiert Prozentzeichen im Host**: `https://127.0.0.1%2F.import.example.org` hat für die Prüfung den Host `127.0.0.1/.import.example.org` (kein IP-Literal, nicht intern), aus dem Host baut der Hub die Anfrage-Adresse `https://127.0.0.1/.import.example.org/api/…`, und der Client verbindet zu **127.0.0.1**. Ebenso `%23`, `%3F`, `%3A…%2F` (Port im Host), `%40` (`x%40127.0.0.1`), Vollbreiten-Ziffern. Die Festlegung der IP (`dnsOverride`) greift nur für den Schlüssel `host`, nicht für das, was der Client tatsächlich verwendet.
- Zweite Schreibweise: **IPv4 mit führenden Nullen** (`0127.0.0.1`): `inet_aton` liest oktal (87.0.0.1, öffentlich, besteht die Prüfung), der Client verbindet auf macOS zu 127.0.0.1 (dezimal).
- **Gemessen (27.11.2026, gleiches Skript auf macOS und im Container `swift:6.4-noble`):** Die Umlenkung der Adresse (Host wird zu Loopback) geschieht auf beiden Plattformen. Ob daraus eine Verbindung wird, entscheidet die Namensauflösung der Prüfung (`vetTarget`) für den **falschen** Namen: macOS-`getaddrinfo` löst `127.0.0.1#.localtest.me` u. ä. auf, glibc im Linux-Container nicht (`unresolvable`, ebenso `a/b`, `a@b`, `a?b`, `ä.…`). Im Linux-Betrieb scheitert der Lauf deshalb heute bei `vetTarget` mit `source_unreachable`, bevor ein Paket den Zielhost erreicht. Das ist Zufall der Resolver-Strenge, keine Absicht der Prüfung: der Schutz hing an einer Eigenschaft von glibc. Daher **mittel**, nicht hoch.
- Auswirkung, wo die Auflösung gelingt (Hub auf dem Mac, anderer Resolver, spätere Resolver-Änderung): Wer `dms.import.manage` hat (Buchhaltung, Owner), bringt Hub oder Worker zu einem GET (mit Token im Header) gegen Loopback, Link-Local/Metadaten oder interne Dienste; Antworten erscheinen nur als Fehlercode, es ist ein blindes SSRF mit Portscan-Wirkung. Voraussetzung: angemeldeter Nutzer mit Importrecht.
- Beleg rot: `testAKPA1R_1_noConnectionToLoopbackPastTheTargetCheck` startet einen Zähler-Listener auf 127.0.0.1 und einen Resolver, der jeden Namen auf eine öffentliche Adresse legt (modelliert die Auflösung, die auf dem Mac gelingt): **3 echte Verbindungen** (`%2F`-Host, `%40`-Host, `0127.0.0.1`), dazu `testAKPA1R_1_ambiguousHostsAreRejected` (27 Fehler) und `…acceptedURLsKeepTheCheckedHost` (Punycode-Eingabe wurde zu Unicode umgeschrieben). Lauf: `scratchpad/red2.log`, „Executed 6 tests, with 41 failures“.
- Fix: eigener strenger Parser (`PaperlessAPISource.swift:41-65`). Host nur ASCII (`[A-Za-z0-9_.-]`, bei IPv6 in Klammern), **kein** Prozentzeichen, `@`, `?`, `#` im Host; Pfad nur aus `[A-Za-z0-9._~-]`-Segmenten ohne `.`/`..`; IPv4 nur kanonisch (`a.b.c.d` ohne führende Nullen); interne Ziele melden weiter `host_not_allowed`, nicht kanonische öffentliche Schreibweisen `invalid_url`. Beleg grün: alle drei Tests, dazu der echte E2E (neue Zeilen 57–67 des Skripts, SSRF-Schreibweisen gegen den Hub ohne Entwicklungsschalter).

### TLS
| Prüfung | Ergebnis | Datei:Zeile |
| --- | --- | --- |
| Vollständige Zertifikatsprüfung, TLS ab 1.2 | in Ordnung | `PaperlessAPISource.swift:96-97` |
| Namensprüfung gegen den eingetragenen Namen, auch wenn die IP festgelegt ist | **jetzt am Netz bewiesen**: Test-Zertifizierungsstelle, Server auf 127.0.0.1: passender Name gelingt, anderer Name scheitert, unbekannte Stelle scheitert | Test `testAKPA1R_2_pinnedConnectVerifiesTheConfiguredName`; Einstellungen aus `clientConfiguration` (`PaperlessAPISource.swift:93-101`), derselbe Code wie im Betrieb |
| Keine eigene CA einstellbar, kein „Zertifikat ignorieren“-Schalter | in Ordnung (Nutzerentscheidung 27.11.2026); im Code kein Pfad dafür, der Test hängt die Test-CA nur an die Konfiguration im Test | `PaperlessAPISource.swift:92-102` |
| CA-Bündel im Image | in Ordnung | `Dockerfile:18` (`ca-certificates`), `Dockerfile.worker:9` |
| Fehlerklassifikation (`source_tls_failed`) | in Ordnung, nur Code, nie Servertext | `PaperlessAPISource.swift:116-125` |

**Befund 3 – niedrig, bestätigt, behoben: der bestehende TLS-Test prüfte nichts.** `testAKD9_tlsCertificateIsVerified` (und der Mock `TLSMock`) lud den Serverschlüssel über `.file(...)`; mit dem hier installierten openssl 4 meldet Vapor `Could not configure TLS: failedToLoadPrivateKey`, der Server bricht jeden Handshake ab (`EOF during handshake`), und der Client meldet `source_tls_failed` – **auch ohne Zertifikatsprüfung**. Beleg: `scratchpad/g1.log` (Meldung, acht Mal) und der Fehlertext im ersten Lauf von `…pinnedConnectVerifiesTheConfiguredName`. Fix: Schlüssel über `NIOSSLPrivateKey(file:format:)` laden (`DMSImportTests.swift`, `TLSMock.make`); der Test gelingt jetzt nur, wenn der Handshake wirklich zustande kommt und die Prüfung das selbstsignierte Zertifikat ablehnt.

Offen aus der Übergabe, weiterhin offen: ein Handshake gegen die **echte** Instanz hinter öffentlichem Zertifikat (erst PA3; nicht Teil dieses Reviews).

### Pfade (Export-Verzeichnis, Dateien, temporäre Dateien)
| Prüfung | Ergebnis | Datei:Zeile |
| --- | --- | --- |
| Pfadsyntax (relativ, kein `..`, kein führender Punkt je Segment, einfache Zeichen) | in Ordnung | `PaperlessExportSource.swift:22-25`; Anlegen: `DMSPaperlessImport.swift:57-60`; Worker prüft erneut `:200-202` |
| Mandantenwurzel, Auflösen von Links | in Ordnung (Wurzel und Ziel werden aufgelöst, Präfixvergleich mit `/`) | `DMSFolderScan.swift:52-58` |
| Manifest ohne Symlink-Race (`O_NOFOLLOW`, Prüfung am Deskriptor, Größe vor dem Lesen) | in Ordnung | `PaperlessExportSource.swift:31-37`, `:174-181` |
| Dateien: relativ, kein `..`/`.`, `lstat` regulär, `realpath` im Verzeichnis, dann `O_NOFOLLOW` und Prüfung am Deskriptor | in Ordnung | `:153-160`, `LocalFile.measure(… within:)` `PaperlessModel.swift:107-123` |
| Austausch der Datei nach dem Messen (erneutes Öffnen per Pfad beim Hochladen) | in Ordnung: `store.put(…, expectedSHA256:)` bricht ab, wenn der Inhalt vom gemessenen Hash abweicht | `DMSImportRunner.swift:372-376` |
| Benutzer-/Gruppeneinträge (Kennwort-Hashes) nie gelesen | in Ordnung | `PaperlessExportSource.swift:49-50`; Kanarientest `testAKD9_fullImportCountsHashesRelationsAndIdempotentRepeat` |
| Temporäre Dateien der API-Quelle: Name aus UUID (kein Name der Quelle), Rechte 0600, bei Fehler gelöscht, nach dem Dokument gelöscht | in Ordnung | `PaperlessAPISource.swift:243-262`, `DMSImportRunner.swift:321`, `:351` |
| Größen: JSON 32 MiB, Datei `maxUploadBytes` (Header und gezähltes Lesen), Manifest 128 MiB | in Ordnung | `PaperlessAPISource.swift:104`, `:242`, `:251`; `PaperlessExportSource.swift:10`, `:35` |
| Namen aus der Quelle (Titel, Dateiname) landen nie in Pfaden | in Ordnung: `DMSSourceIngest.cleanName`, Speicherschlüssel aus dem Hash | `DMSImportRunner.swift:381` |

Der Manifest-Vollzugriff (kein Stream-Parser) bleibt bekannte Grenze der Übergabe, kein neuer Befund.

### Transaktion und Idempotenz
| Prüfung | Ergebnis | Datei:Zeile |
| --- | --- | --- |
| Je Dokument eine Transaktion: Idempotenz-Eintrag, Dokument, Dateien, Tags, Felder, Verweis, Notizen, Text, Ingest-Zustand | in Ordnung; `DMSDocuments.create` läuft in derselben Transaktion (Fluent führt verschachtelte `transaction`-Aufrufe in der äußeren aus) | `DMSImportRunner.swift:384-437` |
| Fehler mitten in der Transaktion hinterlässt nichts Halbes (auch nicht den Idempotenz-Eintrag) | belegt: Quota-Fehler nach dem `claim` → Anzahl Dokumente = Dateien = Items = Ingest-Vorgänge | `testAKD9_quotaStopsRunConsistently` |
| Zwei Worker, genau ein Lauf; Abbruch; Fortsetzung nach Lease-Ablauf | in Ordnung | `testAKD9_twoWorkersRunEachImportExactlyOnce`, `…cancelThenResume`, `…leaseExpiryResumesRun`; E2E „Jeder Lauf genau einmal“ |
| Zwei Läufe gleichzeitig gegen dieselbe Quelle | in Ordnung (Advisory-Lock + Prüfung offener Läufe) | `DMSPaperlessImport.swift:76-79` |
| Blob wird vor der Transaktion geschrieben; Fehler/Verlust des `claim` → Blob verworfen, wenn unreferenziert (unter Blob-Sperre) | in Ordnung; bei Prozessabsturz zwischen `put` und Commit bleibt ein unreferenzierter Blob (nur Speicher, kein Datenverlust) → Karte | `DMSImportRunner.swift:372-376`, `:438-453`, `DMSUpload.swift:143-155` |
| Archivnummer: Zähler wird je Seite vorab angehoben (eigene Transaktion), Kollision wird in der Dokument-Transaktion erneut geprüft | in Ordnung (keine doppelte Nummer, schlimmstenfalls Lücken) | `DMSImportRunner.swift:69-72`, `:395-396` |
| Ende des Laufs: Zustand, Bericht, Audit, `secret_enc = NULL` in einer Transaktion, nur aus `running` | in Ordnung | `DMSImportRunner.swift:498-508` |
| **Lauf, dessen Job endgültig gescheitert ist (Absturzschleife)** | **Befund 2 (mittel), behoben** | `DMSPaperlessImport.swift:148-163` |

**Befund 2 – mittel, bestätigt: Lauf und Token bleiben nach Absturzschleife des Workers hängen.**
- Stirbt der Worker (OOM, SIGKILL) während des Laufs dreimal, setzt `JobService.claim` den Job auf `failed_permanent` (`JobService`: „Absturzschleife“), ohne dass der Import-Handler noch läuft. Der Lauf in `dms_imports` blieb `running`: **das verschlüsselte Token blieb in `secret_enc`** (die Übergabe verspricht „gelöscht, sobald der Lauf endet“), es gab weder Bericht noch Audit-Eintrag, und jeder neue Lauf gegen dieselbe Quelle scheiterte für immer mit `409 import_already_open`.
- Beleg rot: `testAKPA1R_3_runOfACrashLoopedJobIsClosedAndTokenRemoved` (Zustand nach drei Abstürzen nachgebaut: `running|-|true|false` statt `failed|worker_lost|false|true`, Bericht 404, neuer Lauf 409; Timeout „verwaister Lauf beendet“) und `…cancelledOrphanAndHealthyRunsAreTreatedCorrectly`; `scratchpad/red2.log`.
- Fix: Aufräumschritt des Moduls (`DMSImport.sweepOrphans`), den jeder Worker im Leerlauf aufruft (neue Haken `HubModule.jobSweeps`, `JobWorker(… sweeps:)`): Läufe in `queued`/`running`, deren Job `failed_permanent` ist, enden als `failed` mit `worker_lost` (bei gewünschtem Abbruch als `cancelled`), das Token wird gelöscht, Bericht und Audit entstehen, ein neuer Lauf ist möglich. Mehrere Worker gleichzeitig sind sicher (`finish` schreibt nur aus `running`, einmal); Läufe mit gültiger Lease oder verbleibenden Versuchen und wartende Läufe bleiben unberührt (Test). Der Fehlercode steht im Vertrag (`contracts/openapi.yaml`, `pwa/src/lib/api/types.ts`).

### Umgang mit dem Token
| Prüfung | Ergebnis | Datei:Zeile |
| --- | --- | --- |
| Verschlüsselung: AES-256-GCM, Schlüssel per HKDF aus `SECRET_KEY` (Mindestlänge, kein Rückfall auf schwachen Schlüssel), zufälliger Nonce, AAD bindet Mandant und Lauf | in Ordnung | `Sources/SecretBox.swift:21-47` |
| Nie im Klartext: Datenbank (`pg_dump` im E2E, plus `databaseDumpContains`), Logs (Hub und Worker), Audit, Antworten (`has_secret` nur als Bool, `config` nur `base_url`) | in Ordnung | `DMSPaperlessImport.swift:96`, E2E-Zeilen „Token nirgends im Klartext“, „in keinem Log“ |
| Lebensdauer: gelöscht bei Ende (fertig/fehlgeschlagen/abgebrochen), bei Abbruch eines wartenden Laufs und (neu) bei verwaistem Lauf; während des Laufs bleibt es für die Fortsetzung nach Worker-Absturz | in Ordnung nach Fix | `DMSImportRunner.swift:500`, `DMSPaperlessImport.swift:131`, `:148-163` |
| Token geht nur an den eingetragenen Host (keine Weiterleitung, `next` ignoriert), nur im Header `Authorization`, nie in URL oder Query | in Ordnung | `PaperlessAPISource.swift:114`, `:98` |
| Fehler enthalten nie Token, URL oder Servertext (nur Codes); Klassifikation liest den Fehlertext nur lokal | in Ordnung | `PaperlessAPISource.swift:116-125` |
| Eingabe: Länge 1–500, keine Steuerzeichen, unbekannte Schlüssel 422 mit Feldname (nicht mit Wert) | in Ordnung | `DMSPaperlessImport.swift:35-40`, `:44`, `:66` |
| Rechte: Anlegen/Lesen/Abbrechen nur `dms.import.manage|read`, jede Abfrage mit `tenant_id` | in Ordnung | `Import/DMSImportRoutes.swift:31-55`, `DMSPaperlessImport.swift:110-121` |
| Request-Body-Größe der Anlageroute | in Ordnung (Vapor-Standard 16 KiB, Token höchstens 500 Zeichen) | keine Sonderkonfiguration im Backend |

Rest-Risiko, bewusst: Das Token liegt während eines laufenden Laufs verschlüsselt in der Datenbank; wer `SECRET_KEY` und die Datenbank hat, kann es lesen. Ein Lese-Token (nur eigener Paperless-Benutzer mit Leserechten, F-34) begrenzt den Schaden.

## Karten auf dem Lab-Hub-Board (kleinere Befunde, keine Fixes in diesem Schritt)
1. **PA3-Anleitung: interne Ziele und Allowlist.** Löst der öffentlich gültige Name der Paperless-Instanz (Entscheidung 27.11.2026) im Heimnetz auf eine private Adresse auf, lehnt der Hub ihn ohne `DMS_ALLOW_INTERNAL_TARGETS=true` mit `host_not_allowed` ab. Die Anleitung soll den Schalter nur zusammen mit `DMS_IMPORT_HOST_ALLOWLIST=<genau dieser Host>` nennen (Allowlist-Eintrag ohne Port erlaubt jeden Port) und danach wieder abschalten.
2. **Zeitlimit des Downloads prüfen.** `client.execute(req, timeout: .seconds(120))` (`PaperlessAPISource.swift`, `request`) begrenzt je Anfrage; ob das auch das Streamen großer Dateien (`maxUploadBytes`) abschneidet, ist nicht gemessen. Mit einer großen Datei gegen die lokale Instanz prüfen, sonst bricht PA3 bei großen Scans mit `source_unreachable` ab (Funktion, keine Sicherheit).
3. **Unreferenzierte Blobs nach Absturz zwischen `put` und Commit.** Nur Speicherverbrauch; prüfen, ob der Integritätsjob (WP-D5) solche Blobs findet, sonst dort melden.

## Belege (Läufe vom 27.11.2026)
- **Rot** vor den Fixes: `swift test --filter DMSImportReview`: 6 Tests, **41 Fehler** (3 echte Loopback-Verbindungen, Parser, Aufräumtests mit Timeout); Abschnitt „Befund 1/2“. Die Tests existierten nur mit leerem Aufräum-Haken und ohne Parser-Fix (Haken `jobSweeps` und die Naht `clientConfiguration` als Gerüst, ohne Wirkung).
- **Grün** nach den Fixes: `DMSImportReview*`: 7 Tests, 0 Fehler.
- **Volle Suite lokal** (`swift test`, eigener Postgres-Container): **565 Tests, 27 übersprungen, 0 Fehler** (übersprungen: 11 OCR-Werkzeugtests ohne `ocrmypdf`, 1 Messlauf, die übrigen Tests, die Linux-Werkzeuge oder Mail brauchen; sichtbar im Log).
- **E2E** `scripts/e2e-paperless-import.sh` gegen paperless-ngx 3.5.1 (lokal, erfundene Daten): vor den Fixes **67 ok, 0 Fehler**; nach den Fixes mit drei neuen SSRF-Zeilen (`%2F`-Host, `%40`-Host, `0127.0.0.1`, jeweils 422 am Hub ohne Entwicklungsschalter) **70 ok, 0 Fehler**. Die drei neuen Zeilen wurden erst nach dem Fix ergänzt (kein roter E2E-Lauf dazu; der rote Beleg ist der Verbindungstest oben).
- GitHub-CI zum Commit: siehe Commit-Nachricht und `docs/ROADMAP.md`.
- Die Probe zum Host-Unterschied (macOS und Linux-Container `swift:6.4-noble`) ist in Befund 1 mit ihren Ergebnissen beschrieben; das Skript lag im Scratchpad der Sitzung und ist nicht im Repo.

## Für PA3
- Reihenfolge unverändert: PA2 (PWA), dann PA3. Der Import-Code ist nach diesem Review für den Probelauf freigegeben, sobald die CI zum Commit dieses Berichts grün ist.
- Vorher in der Anleitung: Karte 1 (interne Ziele, Allowlist). Paperless-Version der echten Instanz gegen 3.5.1 abgleichen (aus der Übergabe).
