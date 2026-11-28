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
- Dateisystem-Speicher ohne Zeilensperre: vor dem Entfernen wird die Datei in den Staging-Ordner umbenannt und ihr Alter erneut geprüft; hat ein Dedup-`put` sie inzwischen aufgefrischt, kommt sie zurück, ein späterer `put` findet keine Datei und legt sie neu ab.
- `put` hängt länger als die Schonfrist und sein Staging wird weggeräumt: das Hochstufen verlangt den vollständigen Teilesatz, der Upload scheitert sichtbar (kein unvollständiges Objekt unter dem Hash).
- Rolling Update: ältere Instanzen frischen beim Dedup nicht auf. Bestandszeilen gelten ab der Migration als jung, in den ersten 24 h wird also nichts Altes gelöscht; alte Instanzen innerhalb dieser Zeit ersetzen.
- Der Staging-Ordner des Dateisystem-Speichers ist mandantenübergreifend; alte Teile entfernt jeder Lauf.

## Tests
`backend/Tests/HubKitTests/Modules/DMSRevisionTests.swift`, Klasse `DMSOrphanSweepTests` (HTTP über zwei App-Instanzen, echter Worker, echtes Postgres):
- `testOrphanSweep_removesStaleOrphansKeepsReferencedAndYoung`: alter verwaister Blob und alter `tmp:`-Teil weg; referenzierter Blob (48 h alt), junger Blob (23 h) und junger `tmp:`-Teil bleiben; Dokument weiter abrufbar; zweiter Lauf zählt nur noch den jungen Blob; kein Inhalt im Audit.
- `testOrphanSweep_twoInstancesConcurrentUploadSurvives`: Instanz 1 streamt einen Upload (> 1 MiB, Staging-Teil geschrieben, Strom angehalten), Instanz 2 räumt auf und entfernt dabei einen alten verwaisten Blob, der laufende Upload bleibt; nach `put` ohne `files`-Zeile bleibt er wieder; danach registriert und bytegleich lesbar.
- `testOrphanSweep_dedupOnStaleOrphanRefreshesAge`: Dedup auf einen 72 h alten verwaisten Blob über die zweite Instanz frischt die Zeit auf, Blob bleibt.
- `testOrphanSweep_onlyTouchesOwnTenant`: verwaiste Objekte eines anderen Mandanten bleiben unberührt.
- `testOrphanSweep_filesystemStore`: dieselben Regeln für den Dateisystem-Speicher (Änderungszeit, Staging-Ordner, Dedup frischt auf).
- `testOrphanSweep_stalledUploadFailsInsteadOfStoringATruncatedObject`: ein hängender `put`, dessen Staging weggeräumt wurde, scheitert und hinterlässt nichts.
- `testOrphanSweep_filesystemDedupDuringRemovalKeepsTheObject`: Dedup-`put` zwischen Altersprüfung und Entfernen (Testnaht `beforeSweepRemoval`), Datei bleibt.
- Migrationslisten ergänzt: `MigrationNamesTests`, `ObjectStoreTests.testFilesTableDedupAndMigrationRevert`.

Rot zuerst (28.11. ca. 01:50, lokal gegen eigenen Postgres-Container, Aufräumlauf noch als leerer Platzhalter): 4 von 5 neuen Tests rot, 11 Fehlschläge (Blobs und Staging blieben, Zähler 0); `testOrphanSweep_onlyTouchesOwnTenant` war erwartungsgemäß schon grün. Nach der Umsetzung grün: `DMSOrphanSweepTests`, `DMSIntegrityTests`, `ObjectStoreTests`, `MigrationNamesTests` (25 Tests).

Zweite Runde beim Selbst-Gegenlesen (28.11. 02:08): die beiden letzten Tests oben rot (4 Fehlschläge; der hängende Upload speicherte tatsächlich ein unvollständiges Objekt), nach der Korrektur grün.

## Belege
- Commits auf `main`: 85a6f66 (Aufräumlauf, Migration, Vertrag, Übergabe), 36f4220 (hängender Upload, Dateisystem-Rennen).
- GitHub-CI: Lauf 46090156150 (85a6f66) grün, Lauf 46092430280 (36f4220) grün, alle drei Jobs; Backend unter Linux mit Postgres 17: 575 Tests, 2 übersprungen, 0 Fehler, alle 7 `DMSOrphanSweepTests` bestanden.
- Lokal (`scripts/ci.sh`, eigener Postgres-17-Container): am Stand 36f4220 575 Tests, 27 übersprungen (Werkzeuge nur im Worker-Image), 0 Fehler. Im ersten Lauf (85a6f66, Maschinenlast um 260) riss ein 2-s-Zeitlimit in `ExtractionRedosTests`; einzeln wiederholt grün.

## Offen
- ~~PWA-Prüfseite zeigt `report.orphans` noch nicht an~~ erledigt 28.11.2026 mit WP-PA2 (`docs/handoff/WP-PA2.md`).
- Zeitplaner für `dms.verify` fehlt weiterhin (Auslösung über die Route, wie in WP-D5).
- S3-Speicher ist noch nicht implementiert; ein künftiger S3-Speicher braucht `OrphanSweepableStore` (sonst fehlt `orphans` im Bericht).
