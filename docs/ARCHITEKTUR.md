# Architektur LAB hub (Entwurf)

Status: Entwurf, Stand 01.11.2026. Entschieden sind nur ADR 0001–0003 (PostgreSQL, Stack/Betrieb/Lizenz, stateless). Alles andere ist Vorschlag (ADR 0004–0007 „vorgeschlagen“) und mit **[Annahme]** oder Verweis auf `OFFENE-FRAGEN.md` (F-xx) markiert. Zielbild und Produktfamilie: `PLATTFORM-VISION.md`. Dieses Dokument konsolidiert dessen Abschnitte 8 und 9 und ersetzt sie bei Widerspruch (dort steht noch „MariaDB als Arbeitsstand“, überholt durch ADR 0001).

## 1. Begriffe

| Begriff | Bedeutung |
| --- | --- |
| Installation | Ein Stack beim Kunden (eine Datenbank, ein Objektspeicher, n Backend-Repliken). ADR 0002: ein Stack je Kunde |
| Mandant (`tenant`) | Ein Unternehmen innerhalb einer Installation. Entspricht `Organization` in Taxlab (`taxlab/docs/FACHMODELL.md`). Spalte `tenant_id` in allen Fachtabellen (vorhanden in `counters`, `idempotency_keys`) |
| Nutzer (`user`) | Person der Installation; über `memberships` mehreren Mandanten mit je einer Rolle zugeordnet |
| Modul | Fachpaket (`rechnung`, `dms`, später `steuer` …), implementiert `HubModule` (Abschnitt 3) |
| Kern | Immer aktive Bausteine ohne Fachlogik (Abschnitt 4) |

## 2. Schichten

```
Clients:  PWA (pwa/)   Swift-Apps (Taxlab …)   MCP-Clients   Webhooks (aus)
              │ REST/JSON + OpenAPI (/api/v1)        │
Backend:  ┌───▼──────────────────────────────────────▼───┐
          │ HTTP-Schicht: Middleware (Auth, Mandant, Modul-Guard, Idempotency, Fehlerformat, Rate-Limit)
          ├──────────────────────────────────────────────┤
          │ Module (HubModule): Routen · Services · Migrationen · Jobs · Events
          ├──────────────────────────────────────────────┤
          │ Kern: Org/Auth · Rechte · Kontakte · Dokumente/Dateien · Zähler · Suche · Audit · Events/Outbox · Webhooks · Jobs
          ├──────────────────────────────────────────────┤
          │ Infrastruktur: Fluent/SQLKit · ObjectStore (FS/S3) · Mail · OCR-Runner
          └───┬──────────────────────────────┬───────────┘
          PostgreSQL                    Objektspeicher (S3/Dateisystem)
```

Regeln:
1. Abhängigkeitsrichtung: HTTP → Module → Kern → Infrastruktur. Kern kennt keine Module; Module kennen nur den Kern und deklarierte Fremdmodule (`requires`).
2. Module sprechen nicht direkt miteinander, sondern über Kernobjekte (Kontakt-ID, Dokument-ID, `links`) und Events. Ausnahme: ein Modul darf die **öffentliche Service-Schnittstelle** eines `requires`-Moduls nutzen (Protokoll im Kern-Target, Implementierung austauschbar).
3. MCP und Webhooks sind Adapter derselben Services; keine zweite Geschäftslogik (Vorbild `timetrack-backend`: `Sources/TimetrackKit/MCP`).
4. Stateless nach ADR 0003 in jeder Schicht.

Swift-Targets (Vorschlag **[Annahme]**, ADR 0004): `HubCore` (Kern, Protokolle), `HubKit` (heutiges Target; Konfiguration, Datenbank, Bootstrapping, Zusammenbau), je Modul ein Target `HubModuleDMS`, `HubModuleInvoice`, `App` (Executable, registriert alle Module). Einschalten erfolgt zur Laufzeit (Abschnitt 3.3), nicht per Build, damit ein Image alle Module enthält. Offen: Aufteilung in Targets erst bei Bedarf (F-14).

## 3. Modul-System (ADR 0004)

Vorbild: `../timetrack-backend/Sources/TimetrackKit/Modules/ModuleRegistry.swift` und `docs/decisions/ADR-0012-modulschalter.md` (serverweit + je Konto, Operator-Override per `MODULES_DISABLED`, Routen liefern 404 `module_disabled`, Daten bleiben erhalten, Registry bewusst ohne Cache, Änderungen im Audit).

### 3.1 Protokoll

```swift
public protocol HubModule: Sendable {
    static var key: ModuleKey { get }                     // "invoice", "dms"; stabil, nie umbenennen
    static var requires: [ModuleKey] { get }              // harte Abhängigkeit, Aktivierung scheitert ohne
    static var enhances: [ModuleKey] { get }              // optionale Zusatzfunktion, wenn aktiv
    var permissions: [PermissionDefinition] { get }       // z. B. "dms.document.read"
    var migrations: [any Migration] { get }               // Präfix der Tabellen = key
    var navigation: [NavigationItem] { get }              // an /api/modules, Frontend baut Menü
    var eventTypes: [EventTypeDefinition] { get }         // veröffentlicht (Name, Version, Schema)
    var subscriptions: [EventSubscription] { get }        // abonniert (idempotenter Handler)
    var jobKinds: [JobHandlerDefinition] { get }          // Handler für jobs.kind
    func registerRoutes(_ routes: any RoutesBuilder, context: ModuleContext) throws
    func onActivate(tenant: Tenant.ID, context: ModuleContext) async throws   // idempotent, z. B. Standard-Serien
}
```

Das Protokoll ist Entwurf; Signaturen werden in WP-K3 per Test festgelegt. Akzeptanzkriterien siehe unten.

### 3.2 Registrierung und Migrationen

- `App` baut eine feste Liste `[any HubModule]` (kein dynamisches Laden von Plugins in V1; **[Annahme]** AGPL + ein Image).
- Migrationen aller Module laufen **immer** (auch für deaktivierte Module), nur im Migrationsjob (ADR 0003 Nr. 6). Grund: Wieder-Aktivierung ohne Schemaänderung, einheitlicher Schemastand. Migrationsnamen `<modulkey>_<nnn>_<name>`, `schema_version` wird je Modul in `module_schema_versions(module_key, version)` geführt, `schema_version` bleibt globaler Kernstand. `/ready` prüft Kern und alle Module.
- Tabellenpräfix je Modul (`dms_documents`, `invoice_documents`); Kerntabellen ohne Präfix. Fremdschlüssel nur auf Kerntabellen, nie auf Tabellen eines anderen Moduls (Verknüpfung über `links`).

### 3.3 Aktivierung

- Zwei Ebenen wie ADR-0012 von timetrack: **Betreiber** (Installation, `MODULES_DISABLED` oder Admin-UI) und **Mandant** (`tenant_modules(tenant_id, module_key, enabled, updated_by, updated_at)`). Wirksam = Installation an **und** Mandant an **und** alle `requires` wirksam. [Annahme] Anders als timetrack ist die Konto-Ebene hier der Mandant, nicht der Nutzer; ein persönlicher Schalter je Nutzer entfällt (F-13).
- Zentraler `ModuleGuard`-Middleware je Routengruppe, nicht je Route. Deaktiviert: 404 `module_disabled`, Navigation fehlt in `/api/modules`, Jobs des Moduls werden nicht abgeholt (sie bleiben `queued`), Events werden nicht zugestellt, aber in der Outbox gehalten, Daten bleiben.
- Deaktivieren eines Moduls, von dem ein aktives anderes `requires`, wird mit 409 `module_required_by` abgelehnt.
- Änderungen schreiben Audit (`module.enabled`/`module.disabled`).

### 3.4 Abhängigkeiten und Zusammenspiel

| Beziehung | Mechanismus | Beispiel |
| --- | --- | --- |
| `requires` | harte Voraussetzung | Modul `tax` requires `invoice` |
| `enhances` | Feature erscheint, wenn beide aktiv | `invoice` enhances `dms` (Beleganhang aus dem DMS wählen) |
| Event | asynchron, entkoppelt | `invoice.document.finalized` → DMS archiviert PDF |
| `links` | Daten-Verknüpfung | Eingangsrechnung ↔ Dokument |
| Service-Protokoll | synchron, im Kern definiert | `DocumentStoring` (Kern), von beiden Modulen genutzt |

### 3.5 Akzeptanzkriterien Modul-System (WP-K3)

- AK-K3-1: Modul ohne Aktivierung liefert 404 `module_disabled` für alle seine Routen (Test je Modul, generisch über alle registrierten Routen).
- AK-K3-2: `GET /api/v1/modules` listet Status und Navigationseinträge je Mandant; deaktivierte fehlen in `navigation`.
- AK-K3-3: Aktivierung scheitert bei fehlender `requires`-Abhängigkeit (409), Deaktivierung bei Abhängigem (409).
- AK-K3-4: Deaktiviertes Modul verliert keine Daten; Reaktivierung stellt Sicht wieder her.
- AK-K3-5: Zwei Instanzen sehen eine Aktivierungsänderung sofort (kein Cache).
- AK-K3-6: Migrationen eines deaktivierten Moduls laufen; `/ready` = 503 bei fehlender Modul-Migration.

## 4. Gemeinsamer Kern

| Baustein | Inhalt (Tabellen, Kürzel) | Stand |
| --- | --- | --- |
| Installation/Konfiguration | `HubConfig` (Env + `_FILE`), `schema_version` | vorhanden |
| Mandanten | `tenants`, `memberships(user, tenant, role)`, `tenant_modules` | WP-K2 |
| Nutzer & Auth | `users`, `passkey_credentials`, `sessions`, `invitations`, `recovery_codes`, `audit`-Ereignisse | WP-K1 |
| Rechte | `roles`, `permissions`, `role_permissions` (Code liefert Standardrollen) | WP-K2 |
| Kontakte | `contacts`, `contact_addresses`, `contact_persons`, `contact_bank_accounts` | WP-K5 |
| Dokumente/Dateien | `files` (Binärobjekt, Hash, Speicherschlüssel), `file_revisions` | WP-D1 (Details `MODUL-DMS.md`) |
| Zähler | `counters` (vorhanden), `CounterService.next` | vorhanden; Erweiterung in WP-K6 |
| Verknüpfungen | `links(from_type, from_id, to_type, to_id, kind, source, created_by, created_at)` | WP-K5 |
| Suche | `search_documents` (siehe 4.7) | WP-S1 |
| Audit | `audit_log` (append-only) | WP-K1 |
| Events | `events` (Outbox), `event_deliveries` | WP-K7 |
| Webhooks | `webhook_endpoints`, Zustellung als Job | WP-K7 |
| Jobs | `jobs` (vorhanden, Lease), `JobService` | vorhanden |
| Idempotency | `idempotency_keys` (vorhanden), `IdempotencyService` | vorhanden |

### 4.1 Auth (Passkeys/WebAuthn, WP-K1)

Vorbild `../timetrack-backend`: `Sources/TimetrackKit/Passkey.swift`, `WebAuthnService.swift`, `WebAuthnChallenge.swift`, `Session.swift`, `SessionService.swift`, `RecoveryService.swift`, `FallbackPassword.swift`, `Invitation*.swift`; Paket `swift-server/webauthn-swift` (1.0.0-beta.1, Beta: Stabilität prüfen, F-04). Übernehmen: Passkey als Standard, Einladung statt offener Registrierung, Recovery-Codes, optionales Passwort (Argon2) nur als Notfall, Rate-Limits, Sitzungsliste und „alle Geräte abmelden“, `WEBAUTHN_RP_ID`/`PUBLIC_URL` aus Env (vorhanden in `HubConfig`). Nicht übernehmen ohne Entscheidung: OIDC, OAuth-Server für MCP (F-05: spätere Pakete).
- Challenges, Sitzungen, Rate-Limit-Zähler in der Datenbank (ADR 0003 Nr. 1), nie im Speicher.
- Sitzungstoken: zufällig, nur Hash in der DB; Cookie `HttpOnly; Secure; SameSite=Lax` für PWA, `Authorization: Bearer` für Apps/API-Tokens (persönliche Zugangs-Tokens mit Scopes).
- AK-K1-*: Registrierung und Anmeldung mit Testauthenticator (virtuell), Sitzung funktioniert auf zwei Instanzen, Rate-Limit greift instanzübergreifend, Recovery-Code einmalig verwendbar, erster Nutzer nur über Setup-Token aus Env/Secret (kein offenes Bootstrap-Fenster).

### 4.2 Rollen und Berechtigungen (WP-K2)

Rollen (Vorschlag aus `PLATTFORM-VISION.md` 8.8): `owner`, `accountant`, `member`, `tax_advisor` (extern, begrenzt), `customer_viewer` (lesend, nur freigegebene Objekte). Berechtigungen als Strings `<modul>.<ressource>.<aktion>` (`dms.document.read`, `invoice.document.finalize`), von Modulen deklariert. Rolle = Menge von Berechtigungen **je Mandant**; Standardrollen im Code, Anpassung später (F-12). Prüfung zentral: `try await ctx.require("dms.document.read")`; Objekt-Freigaben (Kunde, Steuerberater) über `grants(subject, object_type, object_id, permission)`. Jeder Zugriff prüft Mandant und Berechtigung; Verweigerung auf fremde Mandanten-Objekte = 404.
- AK-K2-1: Matrix-Test Rolle × Berechtigung × Route (generiert aus `permissions`), erwartet 200/403/404.
- AK-K2-2: Nutzer ohne Mitgliedschaft im Mandanten erhält 404 auf dessen Objekte.
- AK-K2-3: Postgres Row Level Security als zweite Schutzschicht **optional** prüfen (`SET LOCAL app.tenant_id`); Entscheidung nach Spike (F-15), nicht Voraussetzung.

### 4.3 Kontakte (WP-K5)

Ein Kontakt gehört einem Mandanten und ist modulübergreifend (Kunde, Lieferant, Korrespondent im DMS). Felder und Regeln aus Taxlab nachlesen, nicht kopieren: `taxlab/docs/FACHMODELL.md` (`Contact`, `Address`, `ContactPerson`, `BankAccount`, `ContactDefaults`). Der Kern speichert Stammdaten (Name, Anschriften, Ansprechpartner, USt-ID, IBAN, Rollenkennzeichen `is_customer/is_supplier/is_correspondent`); modulspezifische Vorgaben (Zahlungsziel, Standardserie) liegen im Modul (`invoice_contact_settings(contact_id …)`). Dubletten: Hinweis bei gleicher USt-ID/IBAN, nie stilles Zusammenführen; Zusammenführen erzeugt Audit-Eintrag und schreibt `links`/Fremdschlüssel um.

### 4.4 Dokumente und Dateien

Kern speichert Dateien (Bytes, Hash, Größe, Typ, Speicherschlüssel) hinter `ObjectStore` (Abschnitt 4.5); fachliche Dokumente (Metadaten, OCR, Klassifikation) gehört dem Modul `dms`; andere Module hängen Dateien über `files` an ihre Objekte (z. B. `invoice_documents.pdf_file_id`) und dürfen sie auf Wunsch ins DMS „einliefern“ (Event, `MODUL-DMS.md` Abschnitt 11).

### 4.5 Objektspeicher

Protokoll `ObjectStore` (ADR 0003 Nr. 2 nannte `AttachmentStore`; hier vereinheitlicht): `put(stream, expectedSHA256) -> key`, `get(key) -> stream`, `exists`, `delete` (nur Hard-Delete nach Löschkonzept), `presignedGet` optional. Implementierungen: `S3ObjectStore` (S3-kompatibel, selbst gehostet, z. B. Garage/MinIO; Vorbild `Storage/S3Client.swift`), `FilesystemObjectStore` (Volume, nur Einzelhost, **kein** Swarm mit Repliken auf mehreren Knoten), `PostgresObjectStore` (Large Objects/`bytea`, Kleinstinstallation; Vorbild `DBBackend` in `Storage/StorageBackends.swift`). Schlüsselschema inhaltsadressiert: `<tenant>/<sha256[0:2]>/<sha256>` (Duplikate teilen Bytes; Löschung per Referenzzählung/Job). Anwendungsseitige Verschlüsselung optional (Vorbild `StorageCrypto.swift`). Entscheidung Standard-Backend: F-06.
- AK-K4s-1 (WP-D1): `put` mit falschem Hash scheitert; `get` liefert identische Bytes; Contract-Test läuft gegen alle Implementierungen.

### 4.6 Zähler

`CounterService.next(tenant:key:)` ist ein atomarer Upsert (vorhanden, getestet). Der Hub-Zähler vergibt Rechnungsnummern **und** DMS-Archiv-Seriennummern (`dms.asn`) über denselben Dienst mit unterschiedlichem `key`. Lücken-/Freigaberegeln der Rechnungsnummern: `taxlab/docs/NUMMERNVERGABE.md`; Erweiterung (Nummernformat mit Jahr/Serie, Nummernlücke dokumentiert freigeben, Untergrenzen) in WP-K6.

### 4.7 Suche

Ein Kernindex `search_documents(tenant_id, entity_type, entity_id, title, body, tsv tsvector, acl_hint, updated_at)` mit GIN-Index; Module schreiben Einträge über `SearchIndexing`-Protokoll bei Änderung (im selben Transaktionsschritt oder per Job). Abfrage prüft Mandant und `dms.document.read`/Modulberechtigung je Treffer. Details der Postgres-Strategie für das DMS: ADR 0005, `MODUL-DMS.md` Abschnitt 6.

### 4.8 Audit

`audit_log(id, tenant_id, at, actor_user_id, actor_type, action, object_type, object_id, ip_hash?, details jsonb)`, nur INSERT (Rolle der Anwendung hat kein UPDATE/DELETE auf die Tabelle; Test). Log enthält IDs, Zeiten, Aktionen, **keine** Belegtexte oder Beträge (`PLATTFORM-VISION.md` Abschnitt 9). Hash-Kette (`prev_hash`, `hash`) für Manipulationsnachweis ist Vorschlag (F-16), gedacht für DMS/Rechnung (GoBD-orientiert, keine Rechtsberatung).

### 4.9 Events und Webhooks (WP-K7)

- **Outbox**: `events(id, tenant_id, type, version, payload jsonb, occurred_at, source_module)`, geschrieben in derselben Transaktion wie die Fachänderung. Zustellung mindestens einmal; Empfänger idempotent über `event_id`.
- Zustellung an Module: Job-Handler `event.deliver` liest per `FOR UPDATE SKIP LOCKED`; `LISTEN/NOTIFY` weckt Instanzen und PWA-Live-Updates (ADR 0003 Nr. 5), Notify ist nur Hinweis, Wahrheit ist die Tabelle.
- Webhooks: `webhook_endpoints(url, secret_ref, event_types)`, Signatur HMAC-SHA256 im Header, Retry mit Backoff als Job, SSRF-Schutz (keine privaten Zieladressen ohne Konfiguration). Standard aus; je Kunde freigegeben.
- Ereignisnamen: `<modul>.<objekt>.<verb>` in Vergangenheit (`invoice.document.finalized`, `dms.document.received`), Versionsnummer im Schema.
- AK-K7-1: Fachänderung und Event atomar (Rollback verwirft beide); AK-K7-2: Event wird bei Absturz der zustellenden Instanz von einer anderen zugestellt; AK-K7-3: Handler doppelt aufgerufen = ein Effekt.

## 5. API-Stil (WP-K4)

- REST/JSON unter `/api/v1`, OpenAPI 3.1 in `contracts/openapi.yaml` (Vorbild `../timetrack-backend/contracts/openapi.yaml` samt Vertragstest „Routen ↔ Vertrag“ in `Tests/.../Contract/`). Der Vertrag ist Quelle für TypeScript-Client (PWA) und Swift-Client; Generator-Wahl offen (F-17).
- Mandantenkontext: Header `X-Tenant: <uuid>` **[Annahme]** oder Pfad `/api/v1/tenants/{tenant}/…`; Vorschlag Pfad (explizit, cachebar, testbar). Sitzung/Token legt Zugriffsrecht fest, Pfad wählt Mandant.
- Versionierung: Major im Pfad (`/v1`); innerhalb einer Major nur additive Änderungen; `GET /api/version` liefert Server-, Schema- und API-Version, Client sendet `X-Client-Api` (Vorbild PWA `src/lib/api/api-version.ts`). Veraltete Felder per `Deprecation`-Header.
- Idempotenz: `Idempotency-Key` Pflicht bei finalisierenden/nicht-idempotenten POSTs (Rechnung finalisieren, Zahlung buchen, Import, Upload-Abschluss); gleicher Key + gleicher Request-Hash = gespeicherte Antwort, anderer Hash = 422 `idempotency_key_reused` (vorhanden in `IdempotencyService`).
- Pagination: cursor-basiert `?limit=50&cursor=<opaque>`; Antwort `{ "items": [...], "next_cursor": "…"|null }`; stabile Sortierung (`created_at, id`). Gesamtzahl nur auf Anforderung (`?count=true`), da teuer.
- Filter/Sortierung: dokumentierte Query-Parameter je Liste; keine freie SQL-Filtersprache.
- Optimistische Nebenläufigkeit: `ETag`/`If-Match` auf veränderbaren Objekten, 412 bei Konflikt.
- Fehlerformat (RFC 9457 Problem Details, Content-Type `application/problem+json`): `{ "type": "https://hub.example.org/errors/module_disabled", "title": "…", "status": 404, "code": "module_disabled", "detail": "…", "request_id": "…", "errors": [{"field":"…","code":"…"}] }`. `code` ist stabil und maschinenlesbar; die PWA mappt `code` auf i18n-Text (Vorbild `src/lib/errors`, `src/lib/i18n/de-errors.ts`).
- Uploads: `POST /files` mit `Content-Length`, Streaming in den ObjectStore (kein Vollpuffern), maximale Größe konfigurierbar; große Dateien optional per presigned URL (F-18).
- Zeit: RFC 3339 UTC; Beträge als Dezimal-String (`"19.90"`) plus `currency`; nie JSON-Number für Geld.
- Rate-Limit und `request_id` in jeder Antwort; Logs ohne Nutzdaten.
- AK-K4-1: Vertragstest schlägt fehl, wenn eine Route fehlt oder undokumentiert ist; AK-K4-2: jede Fehlerantwort entspricht dem Schema; AK-K4-3: Cursor-Pagination durchläuft 10 000 synthetische Zeilen ohne Doppel/Lücke bei parallelen Einfügungen.

## 6. Sync mit den Swift-Apps (Entwurf, offen)

Ausgangslage: Taxlab arbeitet lokal (SQLite) mit CloudKit-Sync und zentralem Nummernzähler (CloudKit-CAS), siehe `taxlab/docs/SYNC.md`, `STORAGE-SCHNITTSTELLEN.md` (Protokolle `DocumentStore`, `AttachmentStore`, `NumberAllocator`, `SyncTransport`). Leitregel aus `PLATTFORM-VISION.md` 3: Wechsel der Betriebsart (lokal / iCloud / Hub) ist **Export/Import mit definierter Migration, nie stilles Umschalten**.

Stufen (Vorschlag):
1. **Stufe 0 – Import/Export (V1 des Hubs).** Taxlab-Export (Format: F-09) wird im Rechnungsmodul importiert (`MODUL-RECHNUNG.md` Abschnitt 8); Gegenrichtung als Export. Kein laufender Abgleich.
2. **Stufe 1 – Hub-Modus der App.** Die App implementiert hinter den Protokollen eine `HubDocumentStore`/`HubNumberAllocator`/`HubAttachmentStore`-Variante (REST). Quelle der Wahrheit ist der Hub; Offline-Betrieb mit lokaler Warteschlange, Nummern nur online finalisierbar (Nutzerentscheidung Nummernvergabe: Finalisieren nur online, zentraler atomarer Zähler).
3. **Stufe 2 – Zwei-Wege-Sync** (nur wenn Bedarf): Änderungs-Feed `GET /changes?since=<cursor>` pro Mandant, Delta mit Tombstones.

Konfliktregeln (Entwurf):
- Finalisierte Belege sind unveränderlich; kein Konflikt möglich, nur Neuanlage (Storno/Gutschrift).
- Entwürfe und Stammdaten: Revisionsnummer je Objekt (`rev`), `If-Match`; bei Konflikt 412 und Client entscheidet („meins/seins/zusammenführen“, nie Last-Writer-Wins für Geldbeträge). Feldweise Zusammenführung nur für unkritische Felder (Notizen, Tags).
- Zähler: serverseitig; Client darf keine Nummer lokal vergeben, sobald Hub-Modus aktiv ist.
- Löschen: Tombstone; Löschung finalisierter oder aufbewahrungspflichtiger Objekte verboten.

Offene Fragen: Wer ist Quelle der Wahrheit beim ersten Hub-Verbinden (Übernahme lokaler Nummernkreise, F-09)? Ob CloudKit parallel weiterläuft (nein, empfohlen: pro Mandant exakt ein Sync-Ziel, F-10)? Auth der Apps (Passkey im System-Browser + Token oder Geräte-Token, F-05)? Format für Anhänge und Layouts (Layout-Designer-Daten gehören zur App, `LAYOUT-DESIGNER.md` in taxlab)?

## 7. Datenschutz und Sicherheit

Konsolidiert aus `PLATTFORM-VISION.md` Abschnitt 9 (dort bleibt der ausführliche Entwurf; hier die technisch prüfbaren Anforderungen). **Keine Rechtsberatung**; AVV, TOMs, Verzeichnis sind vor Betrieb mit fremden Daten zu prüfen (F-19).

| Anforderung | Umsetzung / Test |
| --- | --- |
| Trennung Kunde | Stack + DB je Kunde (ADR 0002); keine gemeinsamen Schlüssel/Speicher |
| Trennung Mandant | `tenant_id` in jeder Abfrage; Mandantentrennungs-Tests je Route; optional RLS (F-15) |
| Transport | TLS am Reverse Proxy; `DB_TLS=require` als Standard (vorhanden) |
| Ruhende Daten | Volume-Verschlüsselung Pflicht (Betriebsdoku); optionale App-Verschlüsselung der Dateien, Schlüssel nur per Secret (`_FILE`) |
| Geheimnisse | nur Env/Docker-Secrets; Werte nie in Logs/Fehlern (vorhanden in `HubConfig`) |
| Zugriff | Passkey, Rate-Limits, Sitzungsverwaltung, Rollen/Berechtigungen, Audit |
| KI/Extern | Standard lokal; extern nur Opt-in je Kunde, protokolliert (`MODUL-DMS.md` Abschnitt 5.4) |
| Telemetrie | keine |
| Löschung/Aufbewahrung | Aufbewahrungsfristen als Regel je Dokumenttyp; Löschkonzept `MODUL-DMS.md` Abschnitt 8; Löschung entfernt auch Suchindex; Backups laufen nach Aufbewahrungsfrist aus |
| Auskunft/Export | Export je Kontakt und Mandant maschinenlesbar (WP-H3) |
| Support-Zugang | befristet, protokolliert (organisatorisch, F-19) |

## 8. Betrieb

Siehe `deploy/README.md`. Ergänzungen für Module:
- Image enthält Backend, PWA-Build (statisch ausgeliefert, Vorbild `PWAStaticMiddleware.swift`) und – wenn OCR serverseitig (F-07) – ein **eigenes** Worker-Image/-Service `ocr` (gleiche Codebasis, Befehl `App worker --kinds ocr`), damit OCR unabhängig skalierbar ist und das API-Image klein bleibt. Worker holen Jobs per Lease (ADR 0006); sie sind stateless (Arbeitsverzeichnis `tmpfs`).
- Services: `backend` (n Repliken), `worker` (n Repliken), `migrate` (Job), `db` (Postgres), optional `objectstore` (Garage/MinIO), optional `mail-ingest` als Teil des Workers.
- Backup: `pg_dump`/WAL + Objektspeicher-Snapshot **zusammen** konsistent (Datenbank verweist auf Hashes); Restore-Test mit Hash-Verifikation aller Dateien (WP-H2). Update-Test mit Swarm real (WP-H4).
- Observability: Health `/health`, Ready `/ready`, strukturierte Logs ohne Nutzdaten, Metriken optional (Prometheus-Endpunkt hinter Auth, F-20).
- Konfiguration neu: `OBJECT_STORE` (`s3|fs|db`), `S3_*` (mit `_FILE`), `MODULES_DISABLED`, `OCR_*`, `MAIL_INGEST_*`; jede neue Variable in `deploy/README.md` und `.env.example` dokumentieren.
