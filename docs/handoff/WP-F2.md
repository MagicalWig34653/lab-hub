# Übergabe WP-F2 (Modulnavigation, Einstellungen)

Stand 07.11.2026, Branch `wp-F2` (auf `main` d356350, enthält F1, K3, D2). Status: AK-F2-1…3 umgesetzt und getestet. Test und Implementierung entstanden in derselben Session (kein belegter Rot-Lauf vor der Umsetzung).

## Umgesetzt (alles unter `pwa/`)
- **Modul-Manifest-Mechanik:** `src/lib/modules/{manifest,registry,resolve,routes}.ts`, DMS-Hook-in `src/lib/modules-impl/dms/manifest.ts` (Icon, Texte de/en, `routePrefix: '/dms'`). Neues Modul = Manifest anlegen, in `registry.ts` eintragen, Routen unter dem Präfix anlegen, Seiten in `ModuleGate` einbetten. Platzhalterseite `src/routes/(app)/dms/+page.svelte` (ohne Funktionalität).
- **Navigation** (`resolveNavigation`): Schnittmenge aus Backend-Navigation (`GET /tenants/{t}/modules`, vom Backend nach Rolle gefiltert), wirksamen Modulen und vorhandenem Manifest; Pfad außerhalb des Modulpräfixes wird verworfen; wirksames Modul ohne Manifest erscheint unter Einstellungen > Module als „nur über API/App“.
- **Workspace-Store** (`src/lib/workspace.svelte.ts`): aktiver Mandant (aus `session.memberships`, Wahl in `localStorage` mit try/catch, nur wenn noch Mitglied), `GET /tenants/{t}` (Rolle, Berechtigungen), Module. Wechsel leert alles in einem Schritt, veraltete Antworten werden verworfen (Sequenzzähler), Inhaltsbereich wird per `{#key}` neu aufgebaut. Notfall-Sitzung lädt keinen Mandanten und zeigt keine Seitenleiste.
- **Shell** (`(app)/+layout.svelte`): Seitenleiste (`nav`-Landmark, `aria-current`), Mandantenwahl (nur bei mehr als einer Mitgliedschaft), Sprache, Abmelden; auf kleinen Breiten wird die Leiste zur horizontalen Zeile. Module werden bei Navigation und bei `visibilitychange` neu gelesen (AK-F2-2; das Backend hat kein Push-Event).
- **Einstellungen** `/settings/{profile,security,sessions,modules,members}` (`/settings` leitet auf `profile`): Profil (Name, Kennung, Rolle, Sprache); Passkeys (Liste, hinzufügen, entfernen; letzter bleibt, Button gesperrt plus Backend-409 übersetzt); Recovery-Codes; Sitzungen (Liste, einzelne beenden, „Auf allen Geräten abmelden“ mit Bestätigung); Module (nur mit `tenant.module.manage`, Tab sonst unsichtbar, Direktaufruf zeigt „keine Berechtigung“; Schalter lädt danach immer neu, auch bei 409 `module_requires`/`module_required_by`); Mitglieder (Lesen mit `tenant.member.read`, Rolle ändern/entfernen mit `…manage`, Einladung mit `…invite`, Link nur einmal sichtbar, Kopieren).
- **Recovery-Codes (UI-Lücke aus F1):** `RecoveryCodes.svelte` in Passkey-Einstellungen. Erzeugen (bei vorhandenen Codes zweiter Klick „alte ersetzen“), Anzeige einmalig im Komponentenzustand (nie gespeichert), Kopieren (Fehlerhinweis falls Zwischenablage gesperrt), Download als Textdatei, Schließen erst nach Häkchen „sicher gespeichert“. Dashboard zeigt Hinweis, wenn weniger als 3 unbenutzte Codes übrig sind (Link zur Einstellung).
- Geändert/Ergänzt: API-Client (`meApi`, erweitertes `tenantApi`, Typen aus dem Vertrag), `session.logoutAll()`, i18n (`registerMessages`, `tx`, ca. 90 neue Schlüssel de/en), Mock-Backend (zwei Mandanten pro Nutzer, Modulschalter, Mitglieder, Einladungen, Passkey-/Sitzungsliste, Recovery-Codes, `recovery_session_restricted`).
- **Reparatur aus D2:** `src/lib/api/types.ts` war nach dem Vertragsstand von D2 veraltet (`npm run check` schlug fehl) und `error.document_trashed`/`error.unsupported_media_type` fehlten (i18n-Test rot). Types neu erzeugt, beide Texte ergänzt.

## Tests
- `npm run check` (0 Fehler, Typen aktuell), `npm test` (Vitest, 48 Tests; neu: `modules/modules.test.ts` = AK-F2-1 Navigation, Registry, **AK-F2-3** Routenklassifikation über alle `+page.svelte`; `workspace.test.ts` = Mandantenwechsel, Verwerfen veralteter Antworten, AK-F2-2 Nachladen, Notfall-Sitzung; `format.test.ts`), `npm run build`, `npm run test:e2e:mock` (16 Tests, 9 neue in `e2e-mock/shell.spec.ts`: Modulschalter an/aus inkl. Neuladen und `ModuleDisabled` (AK-F2-1/2), Nachladen bei `visibilitychange` (AK-F2-2), Mandantenwechsel mit Rollen-/Berechtigungswechsel, Recovery-Codes (Hinweis, einmalige Anzeige, Kopieren, Download, danach weg), Recovery-Code-Anmeldung, Passkeys, Sitzungen, Mitglieder/Einladung/`last_owner`, Englisch).
- Heuristischer Test „kein Text in `.svelte` außerhalb von `t()`“ deckt die neuen Seiten ab; i18n-Vollständigkeit de/en per Typ und Test.

## Entscheidungen und Annahmen (bitte bestätigen)
- Routen ohne `/m/`-Präfix (Backend liefert `/dms`); Test erzwingt Zuordnung Kern/Modul (FRONTEND.md Abschnitt 4 angepasst).
- Der Vertrag liefert keine `icon`/`order`/`requires` in der Navigation; Icon liegt im Manifest, Reihenfolge ist die des Backends, Berechtigungsfilter ausschließlich Backend. Falls eine Reihenfolge gewünscht ist, braucht der Vertrag `order`.
- Kein Backend-Event für Modulwechsel; Aktualisierung bei Navigation und beim Wiedersichtbarwerden des Tabs.
- Mock stellt jedem neuen Nutzer einen vorbelegten Recovery-Code (nur für den Recovery-Login-Test), das echte Backend vergibt keine bis zur Erzeugung.

## Offen / nicht umgesetzt
- Keine fehlenden Backend-Routen für die geforderten Features festgestellt (Passkey-Liste, Sitzungsliste, `logout-all`, Mitglieder, Einladungen sind im Vertrag). Nicht vorhanden und daher nicht gebaut: ausstehende Einladungen listen/widerrufen, Mandantenname ändern, Betreiber-Modulschalter (`PUT /modules/{module}`) und Mandant anlegen (`POST /tenants`) in der UI (nur Betreiber; Folge-WP).
- Gegen das echte Backend nicht erneut gelaufen (nur Mock-E2E); die Routen der Einstellungsseiten folgen dem Vertrag, `npm run test:e2e` deckt sie noch nicht ab.
- Keine axe-Prüfung (Folge-WP bzw. F4), kein Komponententest per Testing Library, kein Mobil-Screenshot-Test; Sitzungen werden ohne Gerätenamen angezeigt (Vertrag liefert keinen).
- Keine neuen Abhängigkeiten, `docs/LIZENZEN.md` unverändert.
- Nächster Schritt: WP-F4 (DMS-UI) hängt sich über das Manifest und `src/routes/(app)/dms/` ein.
