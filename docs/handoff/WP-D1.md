# Handoff WP-D1 ObjectStore

Stand 01.11.2026. Status: Protokoll, FS- und DB-Backend fertig; S3 offen.

## Geliefert
- `backend/Sources/HubKit/ObjectStore/`: `ObjectStore` (put/get/exists/delete, Streaming über `ByteStream`, SHA-256 inkrementell, Schlüssel `<tenant>/<sha[0:2]>/<sha>`), `FilesystemObjectStore` (Staging + atomares rename, POSIX-IO), `PostgresObjectStore` (1-MiB-`bytea`-Chunks in `object_chunks`, Staging-Hash, Promotion per UPDATE), `ObjectStoreConfig` (`OBJECT_STORE` fs|db|s3, `OBJECT_STORE_FS_PATH`, `HUB_REPLICAS`; `validate()` liefert Warnung bei fs und Repliken>1), `FileRecordService` (Tabelle `files`, idempotent je Mandant+Hash).
- Migration `005_files` (Tabellen `files`, `object_chunks`; `schema_version` 5; Revert getestet).
- Tests: `Tests/HubKitTests/ObjectStoreTests.swift` (AK-D1-1…4, FS und Postgres; Zwei-Instanzen-Parallel-Put; 1 GiB synthetisch, Speicherwachstum < 256 MiB).

## Offen
- **S3 nicht implementiert**: keine zusätzliche Abhängigkeit nötig (Vorbild timetrack `S3Client` nutzt SigV4 + Vapor-Client), aber der dortige Client puffert den Payload; für Streaming braucht es Multipart-Upload bzw. UNSIGNED-PAYLOAD/Chunk-Signing. Eigener Folgeschritt, Test gegen Garage/MinIO (F-06). `OBJECT_STORE=s3` meldet derzeit einen Konfigurationsfehler.
- `.env.example` / `deploy/README.md` um `OBJECT_STORE*`, `HUB_REPLICAS` ergänzen (nicht im Besitzbereich, Orchestrator).
- Konfigurationswarnung ist noch nicht an den Start (`configure`) verdrahtet (Routen/Bootstrapping nicht im Besitz).
- Referenzzählung/Löschjob (Hard-Delete nur nach Löschkonzept) folgt mit D2.
- Keine neuen Abhängigkeiten (`Crypto` kommt transitiv über Vapor; in `Package.swift` unverändert).
