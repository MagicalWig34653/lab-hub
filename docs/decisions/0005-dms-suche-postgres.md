# ADR 0005: DMS-Suche auf PostgreSQL

Status: vorgeschlagen (01.11.2026). Baut auf ADR 0001 auf.

**Kontext.** Das DMS braucht deutsche Volltextsuche über OCR-Text, Tippfehlertoleranz und Rechteprüfung je Treffer. Paperless-ngx nutzt einen separaten Index (Whoosh, ggf. Tantivy – zu verifizieren) neben der Datenbank; ein zweiter Zustand widerspricht ADR 0003 (Index muss in Postgres liegen oder reproduzierbar sein).

**Entscheidung.**
1. Index in PostgreSQL: generierte `tsvector`-Spalte (`german`, `unaccent`, Gewichte Titel/Korrespondent/Tags/Text), GIN-Index; Abfrage `websearch_to_tsquery` + `ts_rank_cd`.
2. Tippfehler/Komposita: `pg_trgm`-Fallback auf Titel, Korrespondent, Dateiname (und bei Bedarf Textfenster).
3. Rechte und Mandant werden im selben SQL-Statement geprüft.
4. Später optional `pgvector` (lokal) für „ähnliche Dokumente“; kein externer Suchdienst in V1.
5. Qualität wird mit synthetischem Korpus (200 deutsche Texte mit OCR-Rauschen) gemessen (WP-S1); Messwerte in diesem ADR nachtragen.

**Folgen.** Kein zusätzlicher Dienst, Backup deckt den Index ab, Reindex per Job möglich. Grenzen: deutsche Stemmer behandeln Komposita schwach; Ranking einfacher als bei Spezialengines; Index wächst mit Textmenge (Messung H5). Wird die Qualität verfehlt, ist ein separater Index (z. B. Meilisearch) als Folge-ADR zu prüfen.
