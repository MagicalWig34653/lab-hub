// WP-ST3: `HubKit` bleibt die Bibliothek nach außen. Wer sie importiert (`App`), sieht weiter die öffentliche Schnittstelle des Kerns
// (`HubModule`, `HubConfig`, `migrateWithLock` …).
@_exported import HubCore
