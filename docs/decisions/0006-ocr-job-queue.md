# ADR 0006: OCR als Job-Queue mit Lease

Status: vorgeschlagen (01.11.2026). Baut auf ADR 0003 Nr. 4 auf.

**Kontext.** OCR ist rechenintensiv und darf weder Anfragen blockieren noch Zustand in einer Instanz halten. Paperless-ngx betreibt Worker und Broker im selben Container (Celery/Redis – zu verifizieren), was Skalierung und Ausfallsicherheit begrenzt.

**Entscheidung.**
1. OCR-Aufträge sind Zeilen in `jobs` (`kind=dms.ocr`), abgeholt per `JobService.claim` (`FOR UPDATE SKIP LOCKED`, Lease, Zeiten aus der Datenbank). Der Worker erneuert die Lease (`renew`), schließt nur als Besitzer ab (`complete`), gibt sie beim SIGTERM frei (`release`).
2. Worker = dieselbe Codebasis, Befehl `App worker --kinds dms.ocr,…`, eigener Service/Image mit OCR-Werkzeugen (Engine: OFFENE-FRAGEN F-07). API-Image bleibt ohne OCR-Abhängigkeiten.
3. Arbeitsdateien nur auf `tmpfs`; Ergebnis (Text, Archivversion) wird in einer Transaktion gespeichert, Schritte sind idempotent.
4. Retry mit Backoff, nach 3 Versuchen Quarantäne (`failed_permanent`); `jobs` bekommt eine `priority`-Spalte (Expand-Migration).
5. Original wird nie verändert; OCR erzeugt nur abgeleitete Dateien.

**Folgen.** Kein Redis, keine Pflicht-Broker. Durchsatz skaliert mit Worker-Repliken; Lease-Länge muss größer als Erneuerungsintervall sein (Test). Lange Aufträge brauchen Fortschrittsnachweis über `renew`. Tests: Absturz-Übernahme, Doppelaufruf, Poison-Job (WP-O1/O2).
