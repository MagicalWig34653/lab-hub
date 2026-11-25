# App „docs“ (DMS-Modul): Konzept und Meilensteine

Status: Planung, Stand 25.11.2026. Noch kein Code, kein Xcode-Projekt. Interne Bezeichner im Hub bleiben `dms`.

**Namen und Zuschnitt (Nutzer, 25.11.2026):** Die Web-PWA heißt „LAB hub“, die Module „docs“, „invoice“ usw. **Jedes Modul hat eine eigene native App**, die an den Hub angebunden werden kann – keine Sammel-App. Dieses Dokument beschreibt die App „docs“ und die Grundlage, die alle Modul-Apps teilen (Abschnitt 7). Offen (F-33, beim Anlegen in Xcode): Anzeigename im Store („docs“ oder „LAB docs“), Bundle-ID, Aufteilung der Repositories.

Vorgaben (Nutzer, 25.11.2026): eigenes, ausgefeiltes Konzept (**nicht** nach dem Vorbild Chronolog), alle Apple-Geräte, alle für ein DMS sinnvollen nativen Integrationen, Scanner wählen und Scan starten **auch in der App**. Grundsatz bleibt: Der Hub ist ohne App vollständig nutzbar (`AGENTS.md`); die App ist ein optionaler Client mit eigenständigem Modus.

## 1. Leitidee: vom Papier zur Antwort

Die App ist um drei Aufgaben gebaut, nicht um eine Menüstruktur:

| Aufgabe | Versprechen | Ort in der App |
| --- | --- | --- |
| **Erfassen** | Von überall in höchstens zwei Schritten; nichts geht verloren | Scannen-Knopf, Teilen, Ziehen, Sperrbildschirm → **Eingang** |
| **Klären** | Jeder Vorschlag ist am Blatt belegt und mit einem Griff bestätigt | **Klärstapel** |
| **Wiederfinden** | Eine Suche, die zur richtigen Seite springt | **Finden** (auch Spotlight, Siri) |

### 1.1 Eingang (eine Warteschlange für alle Wege)

Jede Erfassung wird zuerst ein lokales Eingangsobjekt mit sichtbarem Zustand: `lokal gesichert → wird übertragen → wird verarbeitet → zu klären → abgelegt` (Fehler mit Grund und „Erneut“). Jedes Objekt trägt seinen `Idempotency-Key` von Beginn an; Abbruch, Neustart oder doppeltes Antippen erzeugen kein zweites Dokument. Erst nach der Bestätigung des Hubs wird die lokale Kopie freigegeben.

### 1.2 Klärstapel

- Ein Dokument zur Zeit: Seite groß, daneben bzw. darunter die Vorschläge (Korrespondent, Typ, Datum, Betrag, Tags).
- **Belegstelle:** Die App sucht den vorgeschlagenen Wert mit der Texterkennung des Geräts auf der Seite und markiert ihn. Ohne Fundstelle steht dort „nicht am Blatt gefunden“. Dafür braucht der Hub nichts Neues.
- Annehmen, ändern, ablehnen; nie stille Zuordnung (wie im Hub). Tastatur: `↩` annehmen, `⇥` nächstes Feld, `⌘⌫` ablehnen; Touch: Wischen und große Knöpfe; jede Aktion rückgängig, solange der Hub-Stand (`rev`) passt, sonst Konfliktanzeige.
- Duplikat-Hinweise erscheinen als Gegenüberstellung zweier Seiten.

### 1.3 Finden

- Ein Suchfeld; erkannte Teile werden zu **Merkmalen** (Korrespondent, Typ, Zeitraum, Betrag, Tag), die man antippen und ändern kann.
- Treffer mit Textausschnitt, Sprung zur Fundseite und Markierung.
- Gespeicherte Suchen als Ansichten (Hub-Funktion fehlt noch, PA5).

### 1.4 Dokument-Arbeitsfläche

PDF mit Live Text (IBAN, Betrag, Adresse kopieren oder direkt nutzen), mehrere Dokumente nebeneinander in eigenen Fenstern, Teilen und Ziehen als Datei. Anmerkungen liegen als **eigene Fassung** neben dem Original; das Original bleibt unverändert.

Später, nur als Vorschlag mit Bestätigung: Fristen (z. B. Kündigungstermine) als Erinnerung. Der Hub erkennt dafür heute noch keine Vertragsfakten.

## 2. Plattformen

| Gerät | Rolle | Besonderheit | Ab |
| --- | --- | --- | --- |
| iPhone | Erfassen, Klären unterwegs, Finden | Kamera, Sperrbildschirm, Teilen | M1 |
| iPad | Klärstapel in zwei Spalten, Anmerken | Stage Manager, Pencil, Tastatur | M1 (Grundlayout), M2 |
| Mac | Arbeitsplatz: Massenklärung, Scanner am Mac, Finder | **native macOS-App, nicht Mac Catalyst** (`ICScannerDevice` gibt es nur für macOS) | M3 |
| Vision Pro | Lesen und Vergleichen in großen Fenstern | läuft als eigenes Fensterlayout; ob der Dokumentenscanner dort praktisch nutzbar ist, ist trotz gelisteter API zu prüfen | M7 |
| Watch | nur Hinweis „n Dokumente zu klären“ und Fertigmeldung eines Scans | keine Dokumentansicht; nur bauen, wenn der Nutzer es will | M7 (optional) |

Mindestsystem (Vorschlag): iOS, iPadOS, macOS, visionOS 26 (Dokumenterkennung, Foundation Models und PaperKit gibt es laut Apple-Dokumentation ab 26).

## 3. Mit Hub und eigenständig

Eine Bibliothek hat **genau ein** Ziel (wie `ARCHITEKTUR.md` Abschnitt 6): Hub **oder** eigenständig (lokal, optional iCloud). Die Oberfläche arbeitet gegen ein Protokoll `Library`.

| | Mit Hub | Eigenständig |
| --- | --- | --- |
| Wahrheit | Hub | Gerät, optional CloudKit (private Datenbank) |
| OCR | Hub-Worker | auf dem Gerät |
| Suche | Hub | lokaler Volltextindex + Spotlight |
| Offline | Metadaten-Zwischenstand, ausgewählte Dokumente, Eingang | alles |
| Vorschläge/Regeln | Hub | nur einfache Erkennung; keine Regeln in V1 |
| Revisionssicherheit | Löschkonzept und Prüfung des Hubs | **keine Zusage**; nur Hash und Export |

„Mit Hub verbinden“: einmalige Übertragung mit Hash-Abgleich, wiederholbar; die lokale Bibliothek bleibt, bis der Nutzer die Übernahme bestätigt.

Reihenfolge (Entscheidung dieses Plans, umkehrbar): **erst Hub-Modus** (M1–M5), eigenständig in M6. Das Datenprotokoll wird ab M1 so geschnitten, dass M6 nichts umbaut.

## 4. Scannen in der App

„Scannen“ öffnet eine Quellenauswahl; die letzte Wahl ist vorausgewählt.

| Gruppe | Quelle | Plattformen | Ab |
| --- | --- | --- | --- |
| Diese Kamera | VisionKit-Dokumentenscanner | iPhone, iPad (Vision Pro prüfen) | M1 |
| Scanner über den Hub | Scan-Bridge (`SCAN-BRIDGE.md`): Gerät, Quelle, Auflösung, Farbe wählen, starten, nächste Seite, fertig, abbrechen | alle außer Watch | M2 |
| Scanner an diesem Mac | ImageCaptureCore (`ICDeviceBrowser`, `ICScannerDevice`): Netz- und USB-Scanner, Seiten vor dem Upload sortieren, drehen, löschen | **nur macOS** | M3 |
| iPhone als Kamera | Continuity Camera („Vom iPhone importieren“) | macOS | M3 |
| Scanner direkt (optional) | eigener eSCL-Client im lokalen Netz | iPhone, iPad, Vision Pro | M7 |

**ImageCaptureCore auf iPhone/iPad:** Das Framework gibt es dort, die Scanner-Klasse aber nicht. Beleg: Header `ICScannerDevice.h` im iOS-SDK 27.2 (`IC_AVAILABLE(macos(10.4)) IC_UNAVAILABLE(ios)`); die Apple-Dokumentation nennt für `ICScannerDevice` nur macOS. Auf diesen Geräten läuft Netzwerkscannen daher über die Bridge (oder später den eigenen eSCL-Client). Rechte und Entitlements für die Mac-Sandbox werden in M3 am laufenden Programm geprüft.

Bei Bridge-Scans entstehen die Seiten in der Bridge; Sortieren oder Löschen von Seiten vor dem Upload ist dort in V1 nicht möglich (Seitenbearbeitung im Hub fehlt).

## 5. Native Integrationen

Mindestversionen laut Apple-Dokumentation, abgerufen am 25.11.2026; „–“ = nicht einzeln abgerufen, im Meilenstein prüfen. Gelistete API heißt noch nicht, dass die Funktion auf jedem Gerät sinnvoll arbeitet.

| Integration | Nutzen im DMS | Plattformen (ab) | M |
| --- | --- | --- | --- |
| Dokumentenscanner (`VNDocumentCameraViewController`) | Papier in Sekunden, Entzerrung, mehrseitig | iOS/iPadOS 13, visionOS 1 | M1 |
| Share Extension | PDF/Bild aus jeder App in den Eingang | iOS/iPadOS M1, macOS M3, visionOS M7 (–) | M1 |
| Passkey-Anmeldung und Face ID/Touch ID (`ASWebAuthenticationSession`, `LAContext`) | sichere Anmeldung, App-Sperre | iOS 12/8, macOS 10.15/10.10, visionOS 1 | M1 |
| Hintergrund-Uploads (`URLSession` background, `BGContinuedProcessingTask`) | Eingang überträgt weiter, große Stapel | iOS 8 bzw. 26; macOS (background-Sitzung) 10.10 | M1 |
| Barrierefreiheit, dynamische Schrift, Kontrast, Tastatur | für alle bedienbar; Klärstapel ohne Maus | alle | M1, Abnahme in **jedem** M |
| Drag and Drop (`Transferable`) | Dateien aus Mail, Finder, Safari hinein und heraus | iOS 16, macOS 13, visionOS 1 | M2 |
| Mail-Anhänge (Teilen oder Ziehen aus Mail, ohne eigene Mail-Erweiterung) | Rechnung aus der Mail direkt in den Eingang; Postfächer holt weiterhin der Mail-Eingang des Hubs | über Share Extension und `Transferable`: iPhone/iPad M1, Mac M2–M3 (–) | M1 |
| Mehrfenster/Stage Manager (`openWindow`) | vergleichen, nebenher klären | iOS 16, macOS 13, visionOS 1 | M2 |
| Live Text (`ImageAnalyzer`) | Text markieren, IBAN/Betrag nutzen | iOS 16, macOS 13, visionOS 1 | M2 |
| Texterkennung am Gerät (Vision; Dokumenterkennung ab 26) | Belegstellen im Klärstapel; eigenständig OCR | iOS 18/26, macOS 15/26, visionOS 2/26 | M2, M6 |
| ImageCaptureCore | Netz-/USB-Scanner am Mac | macOS 10.4 | M3 |
| Continuity Camera (`ImportFromDevicesCommands`) | iPhone als Scanner für den Mac | macOS 12 (Gerätetyp 14) | M3 |
| Action Extension | „Als Dokument ablegen“ mit Typ/Tags direkt aus dem Teilen-Dialog | iOS, iPadOS, macOS (–) | M3 |
| macOS-Dienste und Schnellaktionen | Rechtsklick im Finder → in den Eingang | macOS (–) | M3 |
| Core Spotlight + `IndexedEntity` | Systemsuche findet Dokumente (abschaltbar, Löschen räumt den Index) | iOS 9/18, macOS 10.11/15, visionOS 1/2 | M3 |
| App Intents, Kurzbefehle, Siri, Apple Intelligence | „Scanne“, „Zeig die letzte Stromrechnung“, Automationen | iOS 16, macOS 13, watchOS 9 (visionOS laut Doku ohne Versionsangabe) | M3 |
| Widgets | Zahl zu klären, zuletzt abgelegt, Scannen | iOS 14, macOS 11, visionOS 1, watchOS 9 | M4 |
| Steuerelemente (`ControlWidget`) | Scannen aus Kontrollzentrum/Aktionstaste | iOS 18, macOS 26, watchOS 26 | M4 |
| Sperrbildschirm-Aufnahme (`LockedCameraCapture`) | scannen ohne Entsperren; Upload erst nach Entsperren | iOS/iPadOS 18 | M4 |
| Live Activities | Fortschritt eines Scan- oder Upload-Stapels | iOS 16.1 (macOS laut Doku erst 27.3 Beta) | M4 |
| Benachrichtigungen (lokal) | Stapel fertig, Fehler im Eingang | alle | M4 |
| Handoff (`NSUserActivity`) | Dokument am anderen Gerät weiterlesen | alle | M4 |
| Dateien-App/Finder (File Provider) | Dokumente in jedem Dateidialog; Hineinlegen = Eingang; zuerst nur lesen | iOS 16, macOS 11, visionOS 1 | M5 |
| Quick Look und Thumbnail-Erweiterung | Vorschau und Miniaturen in Dateien/Finder | `QLThumbnailProvider` iOS 11, macOS 10.15; `QLPreviewProvider` macOS 12 | M5 |
| „Drucken in den Hub“ (PDF-Dienst) | aus jedem Druckdialog ablegen | macOS; Verträglichkeit mit der Sandbox **offen** (–) | M5 |
| iCloud/CloudKit (`CKSyncEngine`) | Abgleich nur im eigenständigen Modus | iOS 17, macOS 14, watchOS 10 | M6 |
| Pencil und Anmerkungen (PencilKit, PDFKit, PaperKit) | unterschreiben, markieren, als eigene Fassung | PencilKit iOS 13, PaperKit iOS/macOS/visionOS 26 | M6 |
| Foundation Models (auf dem Gerät) | Titelvorschlag, Frage in Suchmerkmale übersetzen; **Opt-in**, abschaltbar, nichts verlässt das Gerät | iOS, macOS, visionOS 26 | M7 |
| Push-Mitteilungen | „neue Dokumente zu klären“ ohne offene App; braucht APNs-Schlüssel des Betreibers | alle | M7 |
| Eigener eSCL-Client (`NWBrowser`) | Scannen ohne Bridge und ohne Hub | iOS 13+ | M7 |
| Watch-Komplikation | Zahl zu klären | watchOS | M7 |

**Bewusst nicht geplant:** MailKit-Erweiterung (nur macOS; Anhänge kommen über Teilen/Ziehen und den Mail-Eingang des Hubs), Finder-Sync-Erweiterung (File Provider deckt es ab), Visual Intelligence (wenig Nutzen).

## 6. Anmeldung und Datenschutz

- Anmeldung über den System-Browser mit dem Passkey des Hubs, danach ein widerrufbares **Gerätetoken** im Schlüsselbund (Hub-Funktion fehlt: AB1). Grund: Die native Passkey-Schnittstelle braucht eine beim Bauen feste, verknüpfte Domain; selbst gehostete Hubs haben je eigene.
- Erweiterungen nutzen App Group und gemeinsame Schlüsselbundgruppe; sie legen nur in den Eingang.
- Jede Modul-App meldet sich selbst an und erhält ein **eigenes Token, begrenzt auf ihr Modul** (AB1); Widerruf je App und Gerät. Eine zwischen den Apps geteilte Anmeldung (gemeinsame Schlüsselbundgruppe) ist höchstens eine spätere Komfortfunktion.
- App-Sperre, Dateien mit Datenschutzklasse, Spotlight und Widgets ohne Inhalte bei gesperrtem Gerät, keine Telemetrie, keine externen Dienste.

## 7. Aufbau (Vorschlag)

| Paket/Ziel | Für | Inhalt |
| --- | --- | --- |
| `LabHubClient` | alle Modul-Apps | Hub-Adresse, Anmeldung, Gerätetoken, Versions- und Modulprüfung, Fehler und Grundlagen des API-Zugriffs |
| `LabHubDesign` | alle Modul-Apps | Farben, Typografie, Bausteine, hell/dunkel |
| `DocsCore` | „docs“ | Modelle und API-Aufrufe des Moduls passend zum Vertrag |
| `DocsLibrary` | „docs“ | Protokoll `Library`, `HubLibrary`, später `LocalLibrary`, Zwischenstand, Eingang |
| `DocsCapture` | „docs“ | `ScanSource` mit Adaptern Kamera, Bridge, ImageCaptureCore, Continuity, später eSCL |
| App-Ziel(e) | „docs“ | gemeinsame SwiftUI-App mit eigenem Mac-Layout; Erweiterungen je Meilenstein |

Die App „invoice“ nutzt dieselben `LabHubClient`/`LabHubDesign` (WP-APP-I0; Annahme: das ist die vorhandene Rechnungs-App). Vorschlag zur Ablage: **ein Repository für alle nativen Apps** mit den gemeinsamen Paketen und je App eigenem Ziel; Alternative je App ein Repository und ein Paket-Repository. Entscheidung des Nutzers beim Anlegen (APP-M0). Die gemeinsamen Pakete werden ab M1 ohne DMS-Bezug geschnitten. Code Englisch, Texte Deutsch. Tests: Paket-Tests, Integration gegen einen lokalen Hub mit Wegwerf-Postgres, UI-Durchlauf im Simulator, Bilder hell und dunkel.

## 8. Voraussetzungen im Hub

| WP | Lücke heute | Braucht |
| --- | --- | --- |
| AB1 Geräteanmeldung | API-Tokens kennen nur `dms.upload`; kein Weg, wie eine App ein Sitzungs- oder Gerätetoken erhält | M1 |
| AB2 Änderungs-Feed | kein „Änderungen seit“ für den Zwischenstand | M2 |
| PA4 Miniaturen | Rolle `thumbnail` vorgesehen, nichts erzeugt sie | M2, M5 |
| BR1–BR2 Scan-Bridge | – | M2 |
| PA5 Ansichten/Massenbearbeitung | fehlt | M2 (Ansichten) |
| AB3 Fassungen/Anmerkungen | kein Weg, eine abgeleitete Datei zu ergänzen | M6 |

## 9. Meilensteine

| M | Inhalt | Fertig, wenn | Abh. |
| --- | --- | --- | --- |
| APP-M0 | Anzeigename, Bundle-ID, Xcode-Projekt (Nutzer), gemeinsame und eigene Pakete, CI | leere App „docs“ baut auf iOS und macOS; Entscheidungen dokumentiert | F-33 (Rest) |
| APP-M1 | iPhone/iPad: Anmeldung, App-Sperre, Dokumentenscanner, Share Extension, Eingang mit Hintergrund-Upload | Scan und geteiltes PDF landen genau einmal im Hub, auch nach Abbruch (E2E im Simulator) | M0, AB1 |
| APP-M2 | Finden, Dokumentansicht, Klärstapel mit Belegstellen, Live Text, Drag and Drop, Mehrfenster, Scan über Bridge | Scan per Bridge-`test`-Gerät gestartet, geklärt, gefunden; Konfliktfall getestet | M1, AB2, BR2, PA4 |
| APP-M3 | native Mac-App, ImageCaptureCore, Continuity Camera, Dienste, Action Extension, Spotlight, App Intents | Scan am Mac mit echtem Gerät (Nutzerprobe) und über Bridge; Spotlight findet, Löschen räumt auf | M2 |
| APP-M4 | Widgets, Steuerelemente, Sperrbildschirm-Aufnahme, Live Activities, Mitteilungen, Handoff | je Funktion Gerätebeleg hell/dunkel | M2 |
| APP-M5 | File Provider, Quick Look, Miniaturen, Drucken in den Hub | Dokument aus fremdem Dateidialog öffnen und ablegen | M3, PA4 |
| APP-M6 | eigenständiger Modus, OCR am Gerät, CloudKit, Verbinden mit Hub, Anmerkungen | ohne Hub erfassen und finden; Übernahme ohne Doppel | M3, AB3 |
| APP-M7 | Foundation Models, Vision Pro, Watch, Push, eSCL direkt | je Punkt Nutzerentscheidung vor Beginn | M4–M6 |

Für die Paperless-Ablösung ist die App **nicht** Voraussetzung (`PAPERLESS-ABLOESUNG.md`).
