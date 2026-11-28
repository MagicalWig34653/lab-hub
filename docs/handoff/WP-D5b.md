# Übergabe WP-D5b: Aufräumlauf für verwaiste Blobs und Staging-Teile

Stand 28.11.2026, am Stand `origin/main` 35a4d4f. Befund aus `docs/handoff/WP-PA3V.md` (Abschnitt „Karte 3“): Ein Absturz zwischen `put` und Commit (Upload, Import, Quelle, OCR, Export) lässt einen Blob ohne `files`-Zeile zurück, ein Absturz mitten in `put` `tmp:`-Staging-Teile; `dms.verify` sah beides nicht. Nur lokale Container mit erfundenen Bytes, kein Deploy.

## Ergebnis in Kürze
- `dms.verify` räumt je Mandant auf: Blobs ohne `files`-Zeile und Staging-Teile, deren letztes Schreiben länger als **24 h (DB-Zeit)** zurückliegt, werden gelöscht. Der Bericht enthält `report.orphans` mit `blobs_removed`, `staging_removed` und `pending` (Objekte ohne `files`-Zeile innerhalb der Schonfrist, z. B. laufende Uploads). Audit `dms.integrity.checked` trägt `orphans_removed` (nur Zahl, nie Inhalte).
- Verwaiste Objekte machen den Lauf **nicht** `failed` (kein Datenverlust, nur Speicher).
- Nie gelöscht wird ein Objekt, auf das eine `files`-Zeile zeigt (gleich welches Modul, auch Beleg-PDFs und Logos) oder das jünger als die Schonfrist ist.

## Umsetzung
- Migration `023_object_chunk_age` (Kern, expand-only): `object_chunks.created_at timestamptz NOT NULL DEFAULT now()`. Bestehende Zeilen erhalten den Migrationszeitpunkt; die Schonfrist beginnt für sie mit der Migration. Revert: Spalte entfernen. `schema_version` unverändert (wie 020–022). Ältere Instanzen schreiben die Spalte über die Vorgabe mit (Rolling Update).
- `PostgresObjectStore.put`: Hochstufen des Staging setzt `created_at = now()`; ein Dedup-Treffer frischt `created_at` des vorhandenen Objekts auf (`UPDATE … RETURNING`). Findet das UPDATE keine Zeile mehr (Aufräumlauf hat gelöscht), legt der Upload die Bytes neu ab.
- `FilesystemObjectStore.put`: Dedup frischt die Änderungszeit auf (`utimes`); fehlt die Datei inzwischen, wird neu abgelegt. Alter = Änderungszeit gegen DB-Zeit verglichen.
- `backend/Sources/HubCore/ObjectStore/OrphanSweep.swift`: Protokoll `OrphanSweepableStore` (finden, `deleteIfStale`, `sweepStaging`) für DB- und Dateisystem-Speicher.
- `backend/Sources/HubModuleDMS/Integrity/DMSOrphanSweep.swift`: je Kandidat eine kurze Transaktion mit `DMSUpload.lockBlob` (dieselbe Sperre wie beim Anlegen der `files`-Zeile, Reihenfolge `dms-blob:` dann `file-blob:`), erneute Prüfung „keine `files`-Zeile“, dann `deleteIfStale` (DB: Zeilensperre `FOR UPDATE` auf Teil 0, Alter erneut geprüft). Aufruf am Ende der Dateiprüfung in `DMSIntegrity.process`; Fehler laufen durch dieselbe Wiederholung wie Speicherfehler.
- Vertrag: `DmsIntegrityRun.report.orphans` (`contracts/openapi.yaml`), `pwa/src/lib/api/types.ts` mit `npm run gen:api` neu erzeugt. Die PWA-Seite zeigt die Zahlen noch nicht (keine sichtbare Änderung).

## Nebenläufigkeit (zwei Instanzen)
- Laufender Upload schreibt Staging-Teile: jünger als die Schonfrist, bleibt (Staging zählt nach dem jüngsten Teil).
- `put` fertig, Commit offen: der Blob ist jung, bleibt; die Registrierung prüft die Bytes unter der Blob-Sperre (`verifyBlob` bei Upload, Quelle, Import; Logo prüft `exists`).
- Upload trifft per Dedup einen alten verwaisten Blob: `put` frischt die Zeit auf, der Aufräumlauf sieht ihn als jung. Läuft das Löschen gerade, wartet das Auffrischen auf die Zeilensperre und legt danach neu ab.
- Restfenster nur beim Dateisystem-Speicher (keine Zeilensperre zwischen Prüfen und Löschen): ein Dedup im selben Augenblick führt bei Upload/Quelle/Import zu `upload_interrupted` (sichtbar, kein stiller Verlust). Der Dateisystem-Speicher ist ohnehin nur für einen einzelnen Host gedacht.
- Der Staging-Ordner des Dateisystem-Speichers ist mandantenübergreifend; alte Teile entfernt jeder Lauf.

## Tests
`backend/Tests/HubKitTests/Modules/DMSRevisionTests.swift`, Klasse `DMSOrphanSweepTests` (HTTP über zwei App-Instanzen, echter Worker, echtes Postgres):
- `testOrphanSweep_removesStaleOrphansKeepsReferencedAndYoung`: alter verwaister Blob und alter `tmp:`-Teil weg; referenzierter Blob (48 h alt), junger Blob (23 h) und junger `tmp:`-Teil bleiben; Dokument weiter abrufbar; zweiter Lauf zählt nur noch den jungen Blob; kein Inhalt im Audit.
- `testOrphanSweep_twoInstancesConcurrentUploadSurvives`: Instanz 1 streamt einen Upload (> 1 MiB, Staging-Teil geschrieben, Strom angehalten), Instanz 2 räumt auf und entfernt dabei einen alten verwaisten Blob, der laufende Upload bleibt; nach `put` ohne `files`-Zeile bleibt er wieder; danach registriert und bytegleich lesbar.
- `testOrphanSweep_dedupOnStaleOrphanRefreshesAge`: Dedup auf einen 72 h alten verwaisten Blob über die zweite Instanz frischt die Zeit auf, Blob bleibt.
- `testOrphanSweep_onlyTouchesOwnTenant`: verwaiste Objekte eines anderen Mandanten bleiben unberührt.
- `testOrphanSweep_filesystemStore`: dieselben Regeln für den Dateisystem-Speicher (Änderungszeit, Staging-Ordner, Dedup frischt auf).
- Migrationslisten ergänzt: `MigrationNamesTests`, `ObjectStoreTests.testFilesTableDedupAndMigrationRevert`.

Rot zuerst (28.11. ca. 01:50, lokal gegen eigenen Postgres-Container, Aufräumlauf noch als leerer Platzhalter): 4 von 5 neuen Tests rot, 11 Fehlschläge (Blobs und Staging blieben, Zähler 0); `testOrphanSweep_onlyTouchesOwnTenant` war erwartungsgemäß schon grün. Nach der Umsetzung grün: `DMSOrphanSweepTests`, `DMSIntegrityTests`, `ObjectStoreTests`, `MigrationNamesTests` (25 Tests).

## Belege
- Commit und CI-Lauf: siehe Nachtrag unten.

## Offen
- PWA-Prüfseite zeigt `report.orphans` noch nicht an (eigene Karte, mit Bildern hell/dunkel).
- Zeitplaner für `dms.verify` fehlt weiterhin (Auslösung über die Route, wie in WP-D5).
- S3-Speicher ist noch nicht implementiert; ein künftiger S3-Speicher braucht `OrphanSweepableStore` (sonst fehlt `orphans` im Bericht).
