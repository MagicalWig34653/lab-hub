# Anleitung: Zielrechner für den Probelauf aufsetzen (WP-PA7, Teil 1)

Stand 28.11.2026. Gehört zu WP-PA7 (`docs/ROADMAP.md`, AK-PA7-1 und AK-PA7-2) und zu `docs/PAPERLESS-ABLOESUNG.md`, Abschnitt 4, Schritt 3. Der Nutzer richtet den Rechner selbst ein; Agents deployen nichts. Ergebnis: Der Hub läuft auf einem eigenen Rechner (Docker, Betriebsart 3 aus `deploy/README.md`), Sicherung und Wiederherstellung sind mit einem großen Bestand erprobt, danach kann der Probelauf PA3 (`docs/ANLEITUNG-PA3-PAPERLESS-PROBELAUF.md`) beginnen.

**Geprüft auf:** frische VM mit Ubuntu 24.04.5 LTS (arm64, 6 CPU, 8 GiB RAM, 50 GiB Platte, nur Basissystem), Docker 29.1.3 und Compose 2.40.3 aus den Ubuntu-Paketen. Jeder Schritt unten wurde dort in dieser Reihenfolge ausgeführt; Abweichungen und Fehler sind in Abschnitt 9 aufgeführt. Nicht geprüft: x86-64-Hardware (die Images sind für die Architektur zu bauen, auf der sie laufen; Bau-Dauer dort unbekannt), Docker Desktop oder Colima auf macOS (früher in WP-H9 benutzt), Docker Swarm, ein Reverse Proxy mit echtem Zertifikat.

Ausgeführt wurde ohne `sudo` außer für die Paketinstallation und ohne jede echte Instanz: alle Daten sind erfunden. Die Beispielwerte unten (Stackname `labhub`, Port `18480`, Image `lab-hub:probe`) sind frei wählbar.

## 1. Voraussetzungen und Platzbedarf

| | Mindestens | Empfohlen für den Probelauf |
| --- | --- | --- |
| Betriebssystem | Linux mit Docker Engine (geprüft: Ubuntu 24.04) | wie geprüft |
| CPU | 2 Kerne | 4 bis 6 Kerne (Bau der Images, OCR) |
| Arbeitsspeicher | 4 GiB (OCR-Worker darf bis 6 GiB, `OCR_WORKER_MEMORY`) | 8 GiB |
| Netz | Zugriff auf Docker-Registry, GitHub, Paketquellen beim Aufsetzen | zusätzlich: Weg zur Paperless-Instanz (Abschnitt 3 der PA3-Anleitung) |

**Platzbedarf** (gemessen in Abschnitt 8, hier die Planungsregeln; „Nutzbytes“ = Summe der Dateigrößen im Archiv):

| Posten | Bedarf | Gemessen |
| --- | --- | --- |
| System und Docker-Basis | ca. 3 GiB | Ubuntu 24.04 mit Docker: 2,5 GiB belegt |
| Bau der Images (nur einmal, danach aufräumen) | ca. 14 GiB zusätzlich (Build-Cache und Basis-Images) | Cache 15,3 GiB nach beiden Builds; `docker builder prune -af` gab 14,1 GiB frei (belegt vorher 19,2, danach 5,1 GiB) |
| Fertige Images | ca. 2 GiB | Backend 442 MB, Worker 899 MB, Postgres 17 696 MB |
| Datenbank samt Dateien (`OBJECT_STORE=db`, Standard) | ca. 1,06 × Nutzbytes plus rund 1 GiB Journal (WAL) | 0,96 GiB Nutzbytes: Datenbank 1,02 GiB, Datenverzeichnis 2,05 GiB; 4,84 GiB: 5,11 GiB und 6,13 GiB |
| Eine Sicherung | ca. 1,14 × Nutzbytes (Scans lassen sich nicht komprimieren) | 1,10 GiB bzw. 5,53 GiB |
| Test-Restore (`--verify-only`) | vorübergehend noch einmal die Datenbankgröße (ca. 1,06 × Nutzbytes) | Spitze bei 4,84 GiB Nutzbytes: Datenverzeichnis 6,13 + Sicherung 5,53 + Wegwerf-Datenbank 5,11 = 16,8 GiB |

Faustformel für die Platte: **freier Platz ≥ 3,5 × Nutzbytes + 20 GiB** (Datenbank mit Journal, eine Sicherung, ein Test-Restore nebeneinander, dazu System, Images und den Bau; ohne Bau reichen 3,5 × Nutzbytes + 6 GiB). Die Sicherung gehört zusätzlich auf einen anderen Datenträger oder Rechner (Abschnitt 7).

## 2. Docker installieren

Ubuntu/Debian, mit den Paketen der Distribution (`docker-buildx` ist nötig, das Worker-Image benutzt BuildKit-Funktionen; Compose ist das Plug-in `docker compose`):

```
sudo apt-get update
sudo apt-get install -y docker.io docker-compose-v2 docker-buildx git curl postgresql-client
sudo usermod -aG docker "$USER"
```

**Danach einmal abmelden und wieder anmelden** (oder den Rechner neu starten): Die neue Gruppe gilt erst für neue Anmeldungen, sonst endet jeder `docker`-Aufruf mit `permission denied while trying to connect to the docker API`. Prüfen:

```
docker ps && docker compose version && docker buildx version
```

`postgresql-client` ist nur für Abschnitt 7 nötig, wenn Backup und Restore mit dem Client des Rechners laufen sollen; ohne ihn führt `LH_PG_CONTAINER` die Werkzeuge im Datenbank-Container aus (so ist es unten beschrieben, dann entfällt das Paket).

## 3. Hub holen und Images bauen

Es gibt noch kein veröffentlichtes Image; beide Images werden auf dem Rechner gebaut (für die Architektur des Rechners). Das Repository ist öffentlich.

```
git clone https://github.com/MagicalWig34653/lab-hub.git
cd lab-hub
git log --oneline -1                      # Stand notieren

docker build -t lab-hub:probe .                                    # Backend mit PWA
docker build -f Dockerfile.worker --target worker -t lab-hub:probe-worker .    # Worker mit OCR und Beleg-Renderer
```

Der Name des Worker-Images muss `<Backend-Image>-worker` heißen (`LABHUB_WORKER_IMAGE` überschreibt das). Gemessene Bauzeit (6 Kerne, 8 GiB): Backend 4:00 min, Worker 5:06 min; weniger Kerne bauen entsprechend länger. Danach den Cache entfernen, er braucht den meisten Platz:

```
docker builder prune -af && docker image prune -af
docker images
```

## 4. Einrichten (`deploy/setup.sh`)

`setup.sh` stellt die Fragen, erzeugt Datenbankpasswort und Schlüssel und schreibt `deploy/.env` (ohne Passwörter) und `deploy/compose/secrets/`. Erst ansehen, dann ausführen:

```
deploy/setup.sh --dry-run                                    # nur den Plan zeigen
deploy/setup.sh --save-generated ~/labhub-secrets            # interaktiv; erzeugte Geheimnisse zusätzlich ablegen
```

Ohne Fragen (so wurde es geprüft):

```
LH_MODE=3 LH_STACK=labhub LH_IMAGE=lab-hub:probe LH_DOMAIN=localhost LH_HTTPS=no \
LH_BACKEND_PORT=18480 LH_START=no LH_PROCEED=y \
  deploy/setup.sh --non-interactive --save-generated ~/labhub-secrets
```

- **Betriebsart 3** (ein Docker-Host, Compose). `LH_START=no` richtet nur ein; gestartet wird in Abschnitt 5.
- **Adresse und Passkey:** Die Anmeldung läuft per Passkey; er gilt nur für die eingetragene Herkunft (`PUBLIC_URL`) und lässt sich später nicht ändern, ohne alle Passkeys zu entwerten. Für den Probelauf entweder `localhost` (Weg A in Abschnitt 5) oder die künftige Domain mit HTTPS (Weg B). Bei `localhost` schreibt `setup.sh` den Port in `PUBLIC_URL` (`http://localhost:18480`), hinter einem TLS-Proxy mit Domain nicht.
- **Geheimnisse sichern:** `~/labhub-secrets/lh_secret_key` (Schlüssel, der die Passwörter der Mail-Quellen und Import-Tokens verschlüsselt) gehört nicht in die Sicherung, geht er verloren, sind diese Werte unlesbar. Die Dateien in `deploy/compose/secrets/` sind absichtlich `0644` in einem `0700`-Verzeichnis: die Container laufen als Nutzer 10001 und müssten sonst Dateien des Hostnutzers lesen können. Deshalb darf auf dem Rechner kein fremder Nutzer Zutritt zum Hostverzeichnis haben; das Verzeichnis selbst bleibt dem Besitzer vorbehalten.
- `deploy/.env` ist nicht im Git (`.gitignore`). `setup.sh` überschreibt nichts; ein zweiter Lauf bricht mit dem Hinweis ab, dass die Datei existiert.

## 5. Starten und erste Anmeldung

Die Ersteinrichtung braucht ein einmaliges `SETUP_TOKEN` (nur für das Anlegen des ersten Nutzers; danach entfernen):

```
echo "SETUP_TOKEN=$(openssl rand -hex 16)" >> deploy/.env
grep SETUP_TOKEN deploy/.env                                   # für den Browser
docker compose --env-file deploy/.env -f deploy/compose/compose.yaml up -d
docker compose --env-file deploy/.env -f deploy/compose/compose.yaml ps
curl -fsS http://127.0.0.1:18480/ready                        # 200, sobald die Migration durch ist
```

Es laufen vier Dienste: `db` (Postgres 17), `migrate` (läuft einmal und endet mit Exit 0), `backend` (liefert API und PWA auf Port 8080 im Container, lokal `127.0.0.1:18480`) und `worker` (OCR, Prüflauf, Export, Mail, Konsumordner, Paperless-Import, Belege).

**Pflege ohne Hand (WP-PA7):** Der Worker prüft den Bestand jedes Mandanten selbst (`dms.verify`): zum ersten Mal, sobald es Dokumente gibt und er gerade nichts anderes zu tun hat, danach spätestens alle 7 Tage. Export-ZIPs entfernt er 30 Tage nach der Fertigstellung; bei Bedarf wird der Export neu erzeugt. Einstellbar sind `DMS_VERIFY_INTERVAL_HOURS` und `DMS_EXPORT_RETENTION_DAYS` in `deploy/.env` (`deploy/README.md`; `0` schaltet ab). **Der Hub verschickt keine Meldung:** Ob die Läufe bestehen, steht unter docs → Integrität. Die **Sicherung läuft weiterhin nicht von selbst** (Abschnitt 7).

**Weg A, ohne Proxy (empfohlen für den Probelauf):** Der Browser öffnet `http://localhost:18480`. Läuft der Browser nicht auf dem Zielrechner, per SSH-Tunnel: `ssh -L 18480:127.0.0.1:18480 <benutzer>@<zielrechner>` und dann am eigenen Rechner `http://localhost:18480` öffnen (Passkeys gelten auf `localhost` auch ohne HTTPS). So wurde geprüft: der Browser auf dem Mac sprach über die weitergeleitete Adresse mit dem Stack in der VM.

**Weg B, mit Domain und HTTPS (für den späteren Dauerbetrieb):** `LH_DOMAIN=hub.example.org LH_HTTPS=yes` bei `setup.sh`, davor ein Reverse Proxy mit gültigem Zertifikat, der auf `127.0.0.1:<Port>` weiterreicht, z. B. mit Caddy

```
hub.example.org {
    reverse_proxy 127.0.0.1:18480
}
```

und `TRUSTED_PROXIES` in `deploy/.env` auf die Adresse des Proxys (siehe `deploy/README.md`, Abschnitt Härtung). **Dieser Weg ist in der Prüfung nicht ausgeführt** (er braucht eine echte Domain und ein Zertifikat).

**Erster Nutzer:** `/setup` im Browser, Setup-Token aus `deploy/.env`, Kennung, Anzeigename, „Passkey anlegen und starten“. Danach unter Einstellungen → Module das DMS einschalten (Menüpunkt docs). **Dann das Token entfernen** und das Backend neu erstellen:

```
sed -i '/^SETUP_TOKEN=/d' deploy/.env
docker compose --env-file deploy/.env -f deploy/compose/compose.yaml up -d backend
```

**Funktionsprobe** (Entwicklerweg, benötigt Node im Repository, Playwright und Chromium am Rechner, von dem aus der Browser läuft): `cd pwa && npm ci && E2E_PORT=18480 E2E_SETUP_TOKEN=<token> npm run test:e2e:stack` richtet einen frischen Stack komplett per Passkey ein, lädt ein erfundenes Scan-PDF hoch, wartet auf die Texterkennung, sucht, öffnet Vorschau und Papierkorb. Er braucht einen Stack ohne bereits angelegten Nutzer (nur eine Einrichtung je Datenbank) und das Setup-Token aus Schritt 5. Für den Probelauf des Nutzers genügt von Hand: ein PDF unter docs hochladen und nach einem Wort daraus suchen.

## 6. Einstellungen für den Paperless-Probelauf

Die Netzvoraussetzungen (öffentlicher Name, Zertifikat, interne Ziele mit Allowlist, danach wieder abschalten) stehen in `docs/ANLEITUNG-PA3-PAPERLESS-PROBELAUF.md`, Abschnitte 2 und 3. Für diesen Rechner gilt: die Variablen kommen in `deploy/.env`, danach `docker compose … up -d backend worker`.

## 7. Sicherung und Wiederherstellung

Die Skripte `deploy/backup.sh` und `deploy/restore.sh` (WP-H2) sichern Datenbank und Objekte als ein Paar mit SHA-256-Manifest. Im Standard (`OBJECT_STORE=db`) liegen alle Dateien in der Datenbank; die Sicherung besteht dann aus `db.dump` und dem Manifest. Ohne Postgres-Client am Rechner führt `LH_PG_CONTAINER` die Werkzeuge im Datenbank-Container aus. **Die Variablen nur in einer Unterschale setzen** (Klammern): In der Shell exportiert, überstimmen sie die `deploy/.env` von Compose, und ein späteres `docker compose up` sucht die Datenbank unter `DB_HOST=127.0.0.1` (`migrate` scheitert mit „Connection refused“).

```
mkdir -p /pfad/zur/sicherung
(
  export DB_HOST=127.0.0.1 DB_NAME=labhub DB_USER=labhub
  DB_PASSWORD="$(cat deploy/compose/secrets/lh_db_password)"; export DB_PASSWORD
  LH_PG_CONTAINER="$(docker compose --env-file deploy/.env -f deploy/compose/compose.yaml ps -q db)"; export LH_PG_CONTAINER
  deploy/backup.sh --out /pfad/zur/sicherung/labhub-$(date +%F)       # letzte Zeile der Ausgabe: Manifest-Hash, notieren
  deploy/restore.sh /pfad/zur/sicherung/labhub-$(date +%F) --verify-only --expect-manifest-hash <Hash>   # Test-Restore in Wegwerf-Datenbank
)
```

- Das Sicherungsverzeichnis wie die Daten behandeln (Rechte 700, anderer Datenträger oder Rechner, verschlüsselt). Der Schlüssel `lh_secret_key` gehört **nicht** hinein und wird getrennt aufbewahrt (Abschnitt 4).
- **Wiederherstellen auf einem neuen Rechner** (Datenbank leer, Schlüssel derselbe): Abschnitte 2 bis 4 ausführen, dabei **vor dem ersten Start** die gesicherte `lh_secret_key` nach `deploy/compose/secrets/` kopieren, dann **nur `db` starten** (nicht `migrate`; die Migration füllt die Datenbank, und `restore.sh` verlangt eine leere):

  ```
  docker compose --env-file deploy/.env -f deploy/compose/compose.yaml up -d db
  (
    export DB_HOST=127.0.0.1 DB_NAME=labhub DB_USER=labhub
    DB_PASSWORD="$(cat deploy/compose/secrets/lh_db_password)"; export DB_PASSWORD
    LH_PG_CONTAINER="$(docker compose --env-file deploy/.env -f deploy/compose/compose.yaml ps -q db)"; export LH_PG_CONTAINER
    deploy/restore.sh /pfad/zur/sicherung/labhub-<Datum> --db labhub --expect-manifest-hash <Hash>
  )
  docker compose --env-file deploy/.env -f deploy/compose/compose.yaml up -d
  ```

  `migrate` wendet danach nur noch an, was dem Image gegenüber der Sicherung fehlt. Geprüft (Abschnitt 8): Restore von 5,5 GiB in 80 s, vom `up -d` bis `/ready` 3 s, danach Prüflauf `dms.verify` mit 0 Abweichungen.
- **Restore-Probe mit großem erfundenem Bestand:** `scripts/pa7-restore-probe.sh` erzeugt auf dem laufenden Stack einen eigenen Messmandanten mit erfundenen PDFs (über die Upload-Route, `scripts/pa7-synth-bestand.py`), misst Größen und Zeiten, sichert, macht den Test-Restore, stellt in eine neue Datenbank her, vergleicht Zeilenzahlen und Fingerabdruck, berechnet SHA-256 und Größe **jedes Objekts neu aus den wiederhergestellten Bytes** und startet danach Backend und Worker auf der wiederhergestellten Datenbank, um den Prüflauf `dms.verify` der Anwendung auszuführen (muss `passed` mit 0 Abweichungen und intakter Audit-Kette melden). **Texterkennung vorher ausschalten**, sonst entsteht für jedes erfundene PDF ein Auftrag, der endgültig scheitert (die Probe bricht ohne diese Einstellung ab): `DMS_OCR_ENABLED=false` in `deploy/.env`, `docker compose --env-file deploy/.env -f deploy/compose/compose.yaml up -d backend worker`, nach der Messung die Zeile wieder entfernen (oder auf `true`). Aufruf auf dem Rechner, vom Repository aus: `scripts/pa7-restore-probe.sh --mix 8000:200K,800:2M,50:16M` (ca. 4 GiB, 8 850 Dokumente; mit dem Standard-Mix rund 9 Minuten). Der Messmandant und die Messdatenbank bleiben im Hub zurück (Mandant „PA7 Messung …“); sie lassen sich über `docker compose … down -v` mit dem ganzen Stack entfernen oder im Probelauf ignorieren. Die Probe verändert keine bestehenden Mandanten.

## 8. Messung: Backup und Restore mit großem synthetischem Bestand

Alle Zahlen stammen aus `scripts/pa7-restore-probe.sh` auf einem frisch eingerichteten Stack (Abschnitte 2 bis 5, `OBJECT_STORE=db`, Texterkennung aus) in derselben VM wie oben (6 CPU, 8 GiB, virtuelle Platte auf einem Mac mit SSD, **kein** Server-Datenträger). Der Bestand ist erfunden: Dokumente mit Zufallsbytes hinter einem PDF-Kopf (nicht komprimierbar wie echte Scans), 90 % je rund 200 KiB, 9 % je rund 2 MiB, 1 % je rund 16 MiB, hochgeladen über die echte Upload-Route mit 6 parallelen Verbindungen. Die Stufen sind kumulativ (Stufe 2 liegt auf Stufe 1 und dem Bestand der Funktionsprobe aus Abschnitt 5).

| Messwert | Stufe 1 | Stufe 2 |
| --- | --- | --- |
| Dateien im Hub (Dokumente) | 2 224 (2 220) | 11 074 (11 070) |
| Nutzbytes (Summe der Dateigrößen) | 984 MiB (0,96 GiB) | 4 959 MiB (4,84 GiB) |
| Erzeugung des Zuwachses (Upload) | 2 212 Dokumente in 12 s | 8 850 Dokumente in 56 s (158 Dokumente/s, 71 MiB/s) |
| Größe der Datenbank (`pg_database_size`) | 1 049 MiB (1,066 × Nutzbytes) | 5 230 MiB (1,055 ×) |
| Datenverzeichnis des Datenbank-Containers (mit Journal) | 2 096 MiB | 6 277 MiB (Datenbank + rund 1 047 MiB Journal in beiden Stufen) |
| **Backup** (`backup.sh`, online, `pg_dump -Fc` und SHA-256) | **48 s** (20 MiB/s Nutzbytes) | **281 s** (17,7 MiB/s); nach Abschnitt 7 mit demselben Bestand erneut: 310 s |
| Größe der Sicherung | 1 124 MiB (1,14 ×) | 5 664 MiB (1,14 ×) |
| **Test-Restore** (`restore.sh --verify-only`: prüfen, Wegwerf-Datenbank, vergleichen, aufräumen) | **17 s** | **86 s** |
| **Restore** in eine neue leere Datenbank | **15,5 s** (63 MiB/s) | **83 s** (60 MiB/s); auf einem frischen zweiten Stack: 80 s |
| Vergleich nach dem Restore: Zeilenzahlen, Fingerabdruck über (Mandant, SHA-256, Größe) und Chunk-Zahl | gleich | gleich |
| **SHA-256 und Größe jedes Objekts aus den wiederhergestellten Bytes neu berechnet** (alle Mandanten) | 2 224 Objekte, **0 Abweichungen**, 0,8 s | 11 074 Objekte, **0 Abweichungen**, 6,4 s |
| **Prüflauf `dms.verify` der Anwendung** auf der wiederhergestellten Datenbank (Messmandant) | `passed`, 2 212 Dateien, 0 Abweichungen, Audit-Kette ok, 3 s | `passed`, 8 850 Dateien, 0 Abweichungen, Audit-Kette ok, 13 s |
| Manifest-Hash der Sicherung | `eb56b2b5…7fdc8` | `10d9748a…013a7` |

**Wiederherstellung auf einem neuen Rechner** (Abschnitt 7, zweiter Stack mit frischem Datenbankpasswort, übernommenem `lh_secret_key`, nur `db` gestartet): Restore von 5,5 GiB in 80 s, Start der übrigen Dienste bis `/ready` in 3 s (`migrate`: „Migration abgeschlossen“), Prüflauf der Anwendung `passed` mit 8 850 Dateien, 0 Abweichungen und intakter Audit-Kette. Nicht geprüft: Lesbarkeit eines verschlüsselten Mail-Passworts mit dem übernommenen Schlüssel (kein Mail-Konto in der Messung).

**Aufwand für das Aufsetzen** (frische VM, Abschnitte 2 bis 5): Docker und Pakete 17 s, `git clone` 2 s, Bau Backend 4:00 min, Bau Worker 5:06 min (6 Kerne), `setup.sh` unter 1 s, Start bis `/ready` etwa 10 s, Stack-E2E (Passkey-Einrichtung, Upload, OCR, Suche, Vorschau, Papierkorb) 20 s.

**Hochrechnung (nicht gemessen, linear aus Stufe 2, auf dieser Hardware):**

| Nutzbytes | Datenbank (ca.) | eine Sicherung | Backup | Restore | Test-Restore |
| --- | --- | --- | --- | --- | --- |
| 10 GiB | 10,5 GiB + 1 GiB Journal | 11,4 GiB | 10 min | 3 min | 3 min |
| 50 GiB | 53 GiB + 1 GiB | 57 GiB | 48 min | 14 min | 15 min |
| 100 GiB | 106 GiB + 1 GiB | 114 GiB | 97 min | 29 min | 30 min |

Das Backup ist der langsamste Schritt (Textform der Binärdaten im Dump, Kompression, Hash über jede Datei, Datenstrom durch `docker exec`); es läuft online und sperrt den Betrieb nicht, belastet aber CPU und Platte. Echte Server-Hardware, ein anderer Datenträger oder ein Postgres-Client auf dem Host (statt `docker exec`) ändern die Zeiten; die Größen-Verhältnisse (1,06 ×, 1,14 ×, 1 GiB Journal) hängen nicht von der Hardware ab, wohl aber vom Inhalt: echte PDFs mit viel Text lassen sich teilweise komprimieren, die Sicherung wird dann kleiner. **Vor dem Vollimport (PA8) mit dem echten Bestand wiederholen** (Abschnitt 6 der Ablösungsplanung, Punkt 5): `scripts/pa7-restore-probe.sh` misst dann den Messbestand zusätzlich zum echten, `deploy/restore.sh --verify-only` auf der echten Sicherung ist der eigentliche Beleg.

## 9. Stolpersteine, die beim Prüfen auftraten

| Symptom | Ursache | Lösung |
| --- | --- | --- |
| `permission denied while trying to connect to the docker API` nach `usermod -aG docker` | Gruppe gilt erst für neue Anmeldungen | abmelden und neu anmelden (Abschnitt 2) |
| `migrate` endet mit `Secret-Datei für DB_PASSWORD nicht lesbar`, `backend` und `worker` starten nicht | Auf Linux behalten die Secret-Dateien Besitzer und Modus des Hostnutzers; die Container laufen als UID 10001. `setup.sh` legte sie bis WP-PA7 mit `0600` an (behoben: `0644` im `0700`-Verzeichnis) | bei einer älteren Einrichtung `chmod 644 deploy/compose/secrets/*` |
| Passkey lässt sich im Browser nicht anlegen, Fehler zur Herkunft | `PUBLIC_URL` stimmt nicht mit der Adresse im Browser überein (Schema, Name, Port). `setup.sh` ließ bis WP-PA7 bei `localhost` den Port weg (behoben) | `PUBLIC_URL` in `deploy/.env` auf genau die Adresse der Adresszeile setzen, `up -d backend` |
| `migrate` scheitert mit „Connection refused“ auf `127.0.0.1:5432`, nachdem Backup oder Restore in derselben Shell liefen | `DB_HOST=127.0.0.1` und weitere Variablen waren exportiert und überstimmen die `deploy/.env` | Variablen nur in einer Unterschale setzen (Abschnitt 7); in der Shell `unset DB_HOST DB_NAME DB_USER DB_PASSWORD LH_PG_CONTAINER` |
| `pa7-restore-probe.sh` bricht mit „Texterkennung ist eingeschaltet“ ab | Absicht: erfundene Zufalls-PDFs würden tausende fehlschlagende OCR-Aufträge erzeugen | `DMS_OCR_ENABLED=false` setzen (Abschnitt 7) |
| `restore.sh`: „Ziel-Datenbank ist nicht leer“ | `migrate` lief schon und hat die Tabellen angelegt | wie in Abschnitt 7: erst nur `db` starten, restaurieren, dann den Rest |
| Platte voll beim Bau | Build-Cache (ca. 14 GiB) | `docker builder prune -af`, Platzbedarf Abschnitt 1 |
| Der Prüflauf (Abschnitt 7) meldet nach dem Restore Verschlüsselungsfehler an Quellen | Schlüssel der Sicherung stimmt nicht mit dem laufenden überein | denselben `lh_secret_key` verwenden |

## 10. Abbau

Zum Entfernen des Probestacks mit allen Daten: `docker compose --env-file deploy/.env -f deploy/compose/compose.yaml down -v`, dann `deploy/.env` und `deploy/compose/secrets/` löschen (und `~/labhub-secrets`, falls kein Betrieb folgt). Sicherungen separat löschen.
