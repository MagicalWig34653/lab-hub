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

## Umsetzung WP-S1 und Messwerte (07.11.2026)

Status bleibt „vorgeschlagen“; die Umsetzung weicht in drei Punkten vom ursprünglichen Wortlaut ab (Details `docs/handoff/WP-S1.md`):

1. **Index auf dem Dokument statt auf dem Text.** `dms_document_texts` (Revisionen, höchste `version` gilt) trägt keine eigene `tsvector`-Spalte. Ein Trigger schreibt den Text-Vektor (Gewicht C) nach `dms_documents.body_tsv`, die generierte Spalte `dms_documents.search_tsv` setzt Titel (A) || Metadaten (B) || Text (C) zusammen, ein GIN-Index. Grund: Phrase und Ausschluss (`-wort`) müssen über Titel, Metadaten und Text zugleich gelten; getrennte Vektoren würden `Mietvertrag -Stuttgart` falsch auswerten.
2. **Konfigurationen `dms_german`/`dms_english`** (Kopie von `german`/`english`, `unaccent` vorgeschaltet) statt einer `unaccent()`-Hülle im Ausdruck (`unaccent` ist nicht `IMMUTABLE`). Titel werden mit beiden Konfigurationen indexiert, der Text mit der Sprache der Revision (`de`/`en`); die Anfrage wird mit beiden Konfigurationen gebaut und per ODER verknüpft **[Annahme]**.
3. **Metadaten** (Korrespondent, Typ, Tags, Dateiname des Originals) stehen als Text in `dms_documents.meta_text` und werden von Triggern nachgeführt (Tag setzen/entfernen, Korrespondent-Link, Umbenennen von Kontakt/Tag/Typ, Original-Upload). Der Tippfehler-Fallback (`pg_trgm`, `word_similarity`, Schwelle 0,35, GIN-Index auf `lower(title || ' ' || meta_text)`) gilt nur für Titel und Metadaten, nicht für den Volltext (Trigram über 100 000 Textkörper wäre unverhältnismäßig teuer; Tippfehler in OCR-Text bleiben offen). Operatoren in der Anfrage (Phrase, `-`, `or`) schalten den Fallback ab.

**Qualitätskorpus (AK-S1-6).** 200 deterministisch erzeugte deutsche Texte (12 Themen mit Beugungsformen, Füllwörter, Nummern, Rauschen: Trennstriche am Zeilenende, rund 6 % beschädigte Schlüsselwörter), 12 Wortstamm-Anfragen über den Text und 12 Anfragen mit Buchstabendreher gegen den Titel. Recall@10 = |Top10 ∩ relevant| / min(10, |relevant|). Schwellen im Test: Wortstamm >= 0,9 (Wert aus `MODUL-DMS.md` Abschnitt 6), Tippfehler/Titel >= 0,8. Gemessen: Recall@10 Wortstamm 1,00 (kleinster Einzelwert 1,00), Precision@10 1,00, Recall@10 Tippfehler/Titel 1,00 (n = 12). Einschränkung: Der Korpus ist synthetisch und mit höchstens 25 relevanten Dokumenten je Thema leicht; Komposita und OCR-Fehler im Text (Buchstabenvertauschung im Schlüsselwort) werden nicht gefunden und sind als beschädigte Schlüsselwörter im Korpus enthalten, fallen wegen der Deckelung `min(10, …)` aber nicht ins Gewicht. Ein härterer Korpus mit echten Scans wäre mit Nutzerdaten nötig und liegt außerhalb dieses WP.

**Antwortzeit (AK-S1-7, kein hartes Ziel).** Messlauf: `LH_SEARCH_PERF=1 TEST_DB_NAME=… swift test --filter testAKS1_7` (Anzahl per `LH_SEARCH_PERF_DOCS`, Standard 100 000; ohne die Variable wird der Test übersprungen). Umgebung: Entwickler-Mac (Apple Silicon), PostgreSQL 17.11 im Docker-Container ohne Tuning (Standardwerte, `shared_buffers` 128 MB), Debug-Build des Backends, Anfragen in-process über `app.test` (kein Netzwerk, TLS und Proxy fehlen), abwechselnd zwei App-Instanzen, 15 Wiederholungen je Fall nach dem Aufbau (warmer Cache), ein Mandant mit 100 000 Dokumenten, je Dokument ein Text mit 120 Wörtern (halb 20 Grundwörter, halb 30 000 seltene Wörter), 2 % englisch, ein Viertel mit Typ, rund 15 % mit Tag. Aufbau 47 s, Tabellen `dms_documents` + `dms_document_texts` zusammen 660 MB, Suchindizes (GIN Volltext + Trigram) 74 MB. Erste Seite = 50 Treffer.

| Fall | Median | p95 |
| --- | --- | --- |
| seltenes Wort | 32 ms | 40 ms |
| Wortstamm + Filter Typ/Datum | 78 ms | 92 ms |
| Ausschluss (`Mahnung -Frist`) | 85 ms | 95 ms |
| Phrase | 129 ms | 135 ms |
| Wortstamm + Tag-Filter | 130 ms | 134 ms |
| häufiger Wortstamm (`Rechnung`, tausende Treffer) | 227 ms | 271 ms |
| zwei Wörter | 232 ms | 252 ms |
| Tippfehler (Trigram auf Titel) | 246 ms | 301 ms |
| Wortstamm + Facetten + Gesamtzahl | 1134 ms | 1278 ms |

Einordnung: Treffermengen mit vielen tausend Dokumenten kosten Zeit, weil das Ranking (`ts_rank_cd`) alle Treffer bewertet, bevor die Seite geschnitten wird; Facetten und Gesamtzahl wiederholen die Treffermenge mehrfach und sind deshalb nur auf Wunsch (`facets=true`, `count=true`) aktiv. Mögliche Maßnahmen, falls die Werte nicht reichen (nicht umgesetzt, Messung H5 auf Zielhardware abwarten): Facetten mit Begrenzung der Treffermenge oder aus einer materialisierten Treffermenge, Ranking nur für die ersten N Treffer (z. B. nach Datum vorsortiert), Release-Build. Die Zahlen gelten nur für diese synthetische Last und diese Umgebung; Aussagen zur Produktion sind damit nicht möglich. Fazit: kein Grund, vom Entscheidungsvorschlag (Index in PostgreSQL) abzurücken; die Folge-ADR für einen separaten Suchdienst ist nach diesen Werten nicht ausgelöst.
