# Lizenzen und Abhängigkeitsprüfung

Stand: 27.11.2026 (Render-Werkzeuge WP-R6b; BoringSSL-Update 20.11.2026). Das SPDX-Inventar und die SBOM (WP-H1) stehen im Abschnitt „SPDX-Inventar und SBOM“ am Ende; die übrigen Abschnitte sind die Prüfbefunde der einzelnen WPs. Keine Rechtsberatung; die Rechtsfrage ist **nicht abschließend geklärt**.

## Befund BoringSSL in `swift-nio-ssl` (WP-K0, F-03)

- Aufgelöste Version: `swift-nio-ssl` 2.37.5 (Revision `322f3c2a4a21df31c84ca416bf65ee5e9059e440`, `backend/Package.resolved`). Das ist zugleich der neueste Tag (`git ls-remote --tags`, 01.11.2026).
- Gebündelte BoringSSL-Revision laut `Sources/CNIOBoringSSL/hash.txt`: `817ab07ebb53da35afea409ab9328f578492832d`.
- Quelldateien (`*.c *.cc *.h *.S *.inc`) in `Sources/CNIOBoringSSL`: **643**.
- Davon mit Header „Licensed under the OpenSSL license“: **323** (kritisch laut AGENTS.md; die Datei-Header der gebündelten Kopie tragen den Upstream-Stand vor der Apache-Umstellung bzw. wurden nicht umgestellt).
- Dateien mit „Licensed under the Apache“: **0**.
- Dateien mit ISC-Text („Permission to use, copy, modify“): 200 (unkritisch).
- Dateien mit „Eric Young“: 0; mit „SSLeay“ oder „Eric Young“ zusammen: 8 (Erwähnungen im Text, Einzelprüfung offen).
- Das Repo-`LICENSE.txt` von `swift-nio-ssl` ist Apache-2.0.

Befehle (Checkout im Scratch-Pfad, `D=…/checkouts/swift-nio-ssl/Sources/CNIOBoringSSL`):

```
find $D -type f \( -name '*.c' -o -name '*.h' -o -name '*.cc' -o -name '*.S' -o -name '*.inc' \) | wc -l
grep -rl "OpenSSL license" $D | wc -l
grep -rlE "Licensed under the Apache" $D | wc -l
grep -rlE "Permission to use, copy, modify" $D | wc -l
```

## Neue Abhängigkeiten WP-K1 (01.11.2026, geprüft anhand der Lizenzdateien der Checkouts, keine Rechtsberatung)

| Paket | Fixierung | Lizenz | Hinweis |
| --- | --- | --- | --- |
| `swift-server/webauthn-swift` | Commit `909cf4193cde7d64196553c4245ab647a68aaaca` (1.0.0-beta.1), `revision:`-Pin in `Package.swift` | Apache-2.0 (mit NOTICE) | Beta (F-04); nur über `PasskeyService` genutzt. Apache-2.0 ist mit AGPLv3 kompatibel. |
| `unrelentingtech/SwiftCBOR` | Commit `fd929a6d8f7651ce0f63fc99397fd5762358cc29` (0.6.0) | Unlicense (gemeinfrei) | Transitiv von webauthn-swift; direkt genutzt für die Bindung der attestierten Credential-ID. |
| `apple/swift-crypto` | Bereich `3.8.1..<5.0.0`, aufgelöst 4.5.2 (vorher transitiv 5.0.3) | Apache-2.0 | Direkte Abhängigkeit (SHA-256, Tests: P-256); webauthn-swift verlangt `<5.0.0`, daher Rückstufung von 5.0.3. |

Schluss BoringSSL (Stand 01.11.2026, historisch): Bei 2.37.5 war der Befund offen, weil 2.37.5 damals die neueste Version war. Er ist mit der Aktualisierung vom 20.11.2026 behoben (nächster Abschnitt).

## Update BoringSSL-Befund (WP-H1, 20.11.2026, Freigabe durch den Nutzer; keine Rechtsberatung)

- Pin: `swift-nio-ssl` **2.37.6** (Revision `15e0b9e495786807272dd4891fa4bac76aa43034`, `backend/Package.resolved`; nur diese Zeile des Lockfiles geändert, `swift package update swift-nio-ssl`). Beide Dockerfiles bauen mit `--force-resolved-versions`, das Lockfile ist damit für Images verbindlich.
- Gebündelte BoringSSL-Revision (`hash.txt`): `8eb25be6fa18d475291122887a7bccd3762ff236` (vorher `817ab07e`). Quelldateien: 666.
- Dateien mit Header „Licensed under the OpenSSL license“: **0** (vorher 323); mit Apache-2.0-Header: **534** (vorher 0). Die übrigen 132 Dateien (generierte Assembler-/Tabellendateien, kleine Header) tragen keinen Lizenzheader; eine Datei (`poly1305_arm_asm.S`) ist laut Kommentar gemeinfrei (D. J. Bernstein/P. Schwabe, SUPERCOP).
- Lizenztext von BoringSSL für diese Revision: Apache-2.0 (`LICENSE` upstream, verbatim in `legal/third-party/boringssl/LICENSE`, SHA-256 `827c8d8f…cd97f`). Upstream-`NOTICE.txt` und `LICENSE.txt` von `swift-nio-ssl` liegen unverändert unter `legal/third-party/swift-nio-ssl/`.
- **Veralteter Verweis:** Die unveränderte Upstream-`NOTICE.txt` nennt BoringSSL noch „Combination ISC and OpenSSL license“. Das ist überholt (BoringSSL steht unter Apache-2.0, siehe oben); die Erläuterung steht in `legal/THIRD-PARTY-NOTICES.md`, die Datei wird bewusst nicht verändert.
- Auslieferung: `legal/` wird in beide Images nach `/usr/share/doc/lab-hub/legal/` kopiert (`Dockerfile`, `Dockerfile.worker`). Prüfung: `scripts/check-third-party-notices.sh` (Teil von `scripts/ci.sh`): Lockfile-Version ≥ 2.37.6, Prüfsumme der BoringSSL-LICENSE, Upstream-Dateien byte-gleich zum Checkout, keine OpenSSL-Header.
- Nicht Teil dieses Updates: vollständiges SPDX-Inventar aller Abhängigkeiten und SBOM (bleiben in WP-H1 offen). Die Weitergabe von Images ist weiterhin nur nach Nutzerentscheidung vorgesehen; ein Deploy ist nicht erfolgt.

## Neue Abhängigkeiten WP-F1 (PWA, `pwa/package-lock.json`, geprüft anhand der Lizenzangaben im Lockfile, keine Rechtsberatung)

Direkte Abhängigkeiten (alle `devDependencies`, weil das Bundle statisch gebaut wird; ins Bundle gelangen nur Svelte-Laufzeit, bits-ui, clsx, tailwind-merge, tailwind-variants, lucide-Icons und die Inter-Schrift): `@sveltejs/kit`, `@sveltejs/adapter-static`, `@sveltejs/vite-plugin-svelte`, `svelte`, `svelte-check`, `vite`, `vitest`, `jsdom`, `tailwindcss`, `@tailwindcss/vite`, `tw-animate-css`, `tailwind-variants`, `tailwind-merge`, `clsx`, `bits-ui`, `shadcn-svelte` (CLI), `@testing-library/svelte`, `@testing-library/jest-dom`, `@types/node`, `openapi-typescript`: MIT. `@lucide/svelte`: ISC. `@playwright/test`, `typescript` (5.9, weil `openapi-typescript` 7 TypeScript ^5 verlangt): Apache-2.0. Die shadcn-svelte-Komponenten unter `src/lib/components/ui` sind MIT (`pwa/SHADCN-LICENSE.md`).

Lizenzverteilung im Lockfile (alle 241 Pakete, auch transitiv): MIT 197, Apache-2.0 13, ISC 6, BSD-2/3-Clause 4, MIT-0 2, 0BSD 1, CC0-1.0 1, BlueOak-1.0.0 1, (MIT OR CC0-1.0) 1; außerhalb der Vorgabe MIT/Apache/ISC/BSD:
- `@fontsource-variable/inter` 5.3.0: **OFL-1.1** (Schriftdateien der Inter-Schrift, wird mit ausgeliefert). OFL ist für eingebettete Schriften üblich und mit AGPL-Auslieferung des Programms vereinbar, der Schriftname bleibt unverändert; **Bestätigung durch den Nutzer offen** (Alternative: Systemschrift ohne Fontsource).
- `lightningcss` (+ 11 Plattformpakete) 1.x: **MPL-2.0**, transitiv von `tailwindcss`/`@tailwindcss/vite`, nur Build-Zeit, nicht im Bundle. Unverändert verwendet; Bestätigung offen.
- `argparse` (Python-2.0, nur Build-Zeit), `svelte-toolbelt` (Lockfile ohne Lizenzfeld; `LICENSE` im Paket ist MIT).

`npm run build` schreibt eine Lizenzliste aller gesperrten Pakete nach `pwa/build/licenses.json` (`scripts/generate-licenses.mjs`); das vollständige Inventar und die SBOM folgen mit WP-H1.

## Neue Abhängigkeiten WP-F4 (PWA, 07.11.2026, keine Rechtsberatung)

| Paket | Version | Lizenz | Hinweis |
| --- | --- | --- | --- |
| `@axe-core/playwright` (devDependency) | 4.14.0 | MPL-2.0 | Nur für die E2E-Tests (a11y), nicht im Bundle. |
| `axe-core` (transitiv) | 4.14.0 | MPL-2.0 | Wie oben; unverändert verwendet, nicht eingebunden oder modifiziert. MPL-2.0 ist mit AGPLv3 über die Sekundärlizenz-Regel (§ 3.3) vereinbar; Bestätigung durch den Nutzer wie bei `lightningcss` offen. |

Hinweis zur Installation: `npm install` ohne `--force`/`--legacy-peer-deps` scheitert im Repo an der Peer-Auflösung (`@sveltejs/kit` 3 mit `typescript` 5.9, wegen `openapi-typescript` 7); das Lockfile wurde mit `npm install -D @axe-core/playwright --force` ergänzt, `npm ci` läuft damit sauber. Dabei entfielen drei nur optional/extraneous eingetragene Pakete (nested `@sveltejs/kit` 2.x unter `bits-ui`/`svelte-toolbelt`, `@types/cookie`, `kleur`, `set-cookie-parser`).

## Worker-Image WP-O2 (`Dockerfile.worker`, OCR-Werkzeuge, Stand 07.11.2026, keine Rechtsberatung)

Geprüft anhand der Paketangaben (`dpkg-query`, `/usr/share/doc/<paket>/copyright`) im gebauten Image auf Ubuntu 24.04 (Kurzfassung der Hauptlizenzen; die Pakete enthalten weitere Teillizenzen, die vollständige Liste liefert WP-H1 mit der SBOM). Das **API-Image enthält nichts davon**; die Werkzeuge liegen nur im Worker-Image.

| Werkzeug (Paket, Version) | Hauptlizenz | Nutzung im Hub |
| --- | --- | --- |
| `ocrmypdf` 15.2.0 | MPL-2.0 (einzelne Teile Expat/MIT) | Eigener Prozess (`ocrmypdf …`), erzeugt Archiv-PDF (PDF/A-2b) und OCR-Textschicht |
| Tesseract `tesseract-ocr` 5.3.4, Sprachpakete `tesseract-ocr-deu`/`-eng` | Apache-2.0 | Von ocrmypdf als Prozess aufgerufen (Sprachen `deu+eng`) |
| Ghostscript `ghostscript` 10.02.1 | **AGPL-3.0-or-later** (Artifex) | Nur als **separates Programm** (Aufruf durch ocrmypdf für Rasterung/PDF-A-Erzeugung; Testdokumente werden damit erzeugt). **Keine Linkabhängigkeit**: weder das Swift-Backend noch der Worker binden `libgs` ein; es gibt keine Header, kein FFI, keine Swift-Paketabhängigkeit. Hub und Ghostscript sind beide AGPL-3.0, eine Kombination wäre daher lizenzrechtlich kein Hindernis; die Trennung bleibt Absicht, damit das Backend austauschbar bleibt |
| `poppler-utils` 24.02 (`pdftotext`, `pdfinfo`) | GPL-2.0-or-later / GPL-3.0-or-later | Nur als Programm aufgerufen (Textschicht lesen, Seitenzahl) |
| `qpdf` 11.9 | Apache-2.0 | Abhängigkeit von ocrmypdf/pikepdf (Prozess/Bibliothek innerhalb von ocrmypdf) |
| Python-Bibliotheken von ocrmypdf (u. a. `pikepdf` MPL-2.0, `img2pdf` LGPL-3.0-or-later, `Pillow` HPND, `pdfminer.six` MIT) | siehe links | Laufen im Python-Prozess von ocrmypdf; vom Hub nicht gelinkt |

Pflichten bei **Weitergabe** des Worker-Images (Registry): Ghostscript (AGPL-3.0), Poppler (GPL) und die übrigen Pakete werden als Binärpakete der Distribution ausgeliefert; die Quellen stammen aus den Ubuntu-Quellpaketen (`apt-get source <paket>`), der Lizenztext liegt im Image unter `/usr/share/doc/<paket>/copyright`. Bei eigenem Hosting ohne Weitergabe entsteht keine zusätzliche Pflicht über die AGPL-Netzwerkklausel des Hubs hinaus. **Offen:** Bestätigung durch den Nutzer/Juristen, SBOM mit WP-H1, Quellangebot-Text für ein veröffentlichtes Image.

## WP-D4 (Quellen: Mail-Ingest, Konsumordner, Share-API, 08.11.2026, keine Rechtsberatung)

**Keine neue Abhängigkeit.** Der IMAP-Client (`HubModuleDMS/Sources/IMAPClient.swift`) und der MIME-Parser (`MailMessage.swift`) sind Eigenentwicklung auf `swift-nio` (Apache-2.0) und `swift-nio-ssl` (Apache-2.0, bündelt BoringSSL; Prüfauftrag F-03 unverändert offen), beide ohnehin Abhängigkeiten von Vapor/Fluent. Die Verschlüsselung der Zugangsdaten nutzt `swift-crypto` (Apache-2.0), das bereits eingebunden ist. Begründung gegen eine IMAP-Bibliothek: Der Hub braucht nur LOGIN/AUTHENTICATE PLAIN, SELECT, UID SEARCH/FETCH/STORE/COPY/MOVE und LOGOUT (rund 300 Zeilen); eine zusätzliche Bibliothek hätte Lizenz-, Wartungs- und Sicherheitsfläche (TLS-Voreinstellungen, Größenlimits, Zeitlimits) ohne Gewinn. Getestet wird gegen **GreenMail** (`greenmail/standalone`, Apache-2.0) als Docker-Image **nur in den Tests**, nicht im Produkt oder in Images.


## WP-D6 (Paperless-Import, 08.11.2026, keine Rechtsberatung)

- Keine neue Paketabhängigkeit (`Package.swift` unverändert). Die REST-Quelle importiert `AsyncHTTPClient` (`swift-server/async-http-client` 1.36.2, Apache-2.0) und `NIOSSL` direkt; beide sind bereits transitiv über Vapor im Build. Soll das ausdrücklich in `Package.swift` stehen, ist das eine Entscheidung des Package-Besitzers (offen).
- **Paperless-ngx (GPL-3.0):** Es wurde kein Code, kein Text und keine Testdatei übernommen. Das Format von `manifest.json` und der REST-API ist aus der Funktionsbeschreibung abgeleitet, die Fixture (`backend/Tests/Fixtures/paperless-synthetic/`, `generate.py`) und der Mock-Server sind selbst geschrieben, alle Inhalte erfunden.

## WP-D7 (Dokumenterkennung, Mail-Original, HTML-Text, 08.11.2026, keine Rechtsberatung)

**Keine neue Abhängigkeit.** HTML-zu-Text (`HubModuleDMS/Sources/HTMLText.swift`) ist ein eigener, begrenzter Textextraktor (kein SwiftSoup, keine Parser-Bibliothek), der Extraktor (`HubModuleDMS/Extraction`) nutzt nur Foundation (`NSRegularExpression`, `Decimal`). Entscheidung gegen SwiftSoup (MIT): der Bedarf (Text, Tabellenzeilen, Entitäten) ist klein, ein Baum mit Selektoren wird nicht gebraucht, und die eigene Lösung hat feste Größen-/Tiefenlimits. Testdaten sind selbst erfunden (Firmen, example.org, IBANs aus dem Standard-Testbereich); GreenMail (Test-Container `greenmail/standalone`) steht unverändert wie in D4 nur in Tests.

## WP-F4c (Dokumentübersicht, Seitenleiste, 08.11.2026)

**Keine neue Abhängigkeit.** Die Seitenleiste folgt dem Aufbau der Projekte thermoctl und timetrack-pwa (gruppierte, einklappbare Navigation, Schublade auf Mobilgeräten, Seitenkopf-Typografie); es wurde nur das Muster nachgebaut, kein Code kopiert. Beide nutzen dieselben Bausteine wie der Hub (`@lucide/svelte` ISC, `bits-ui`, `tailwind-variants`, `clsx`, `tailwind-merge`: MIT), weitere Pakete werden nicht benötigt. Neue lucide-Icons (ISC) stammen aus dem vorhandenen Paket.

## Render-Werkzeuge im Worker-Image (WP-R6b, 27.11.2026, keine Rechtsberatung)

Nur das Worker-Image enthält sie (`Dockerfile.worker`, Stufen `worker-tools`, `worker`, `worker-test`); das API-Image bleibt ohne Typst und Schriften. Typst läuft als eigener Prozess (`typst compile`), nie gelinkt. Die Lizenztexte liegen unverändert in `legal/third-party/` und werden mit `legal/` in die Images kopiert; `scripts/check-third-party-notices.sh` prüft Pins, Prüfsummen und Inhalt (Teil von `scripts/ci.sh`).

| Komponente | Version / Pin | Lizenz | Hinweis |
| --- | --- | --- | --- |
| Typst 0.15.1 | Image `ghcr.io/typst/typst:0.15.1@sha256:032e2922…c422f` (Index-Digest amd64 und arm64); Binary `/bin/typst` | Apache-2.0 | Statisch gelinkt; `legal/third-party/typst/LICENSE` und `NOTICE` (Archiv der Version 0.15.1, wörtlich). Das NOTICE nennt Drittcode unter MIT und der LLVM-Ausnahme. Neue Typst-Version = neue PDF-Bytes: Referenzen und Pins gemeinsam ändern. |
| typst-assets 0.15.1 | im Typst-Binary eingebettet | Libertinus Serif OFL-1.1; New Computer Modern GUST Font License; DejaVu Sans Mono Bitstream Vera / gemeinfrei; ICC-Profile CC0-1.0 | `legal/third-party/typst-assets/LICENSE` und `NOTICE` (Tag v0.15.1, wörtlich). Eingebettete Schriften bleiben aktiv (Rückfallschriften für fehlende Zeichen); Systemschriften werden mit `--ignore-system-fonts` ignoriert. |
| Inter 4.1 | `Inter-4.1.zip` von `github.com/rsms/inter` (SHA-256 `9883fdd4…6b11e`, im Dockerfile mit `--checksum` geprüft); genutzt: `Inter-Regular.ttf`, `Inter-Bold.ttf` | OFL-1.1 | Eigene Schrift der Standardlayouts; in PDFs als Teilmenge eingebettet. Die OFL erlaubt Einbettung; der Schriftname bleibt unverändert, die Schrift wird nicht einzeln verkauft. `legal/third-party/inter/LICENSE.txt`. (Die PWA nutzt Inter über `@fontsource-variable/inter`, siehe WP-F1.) |
| qpdf 11.9 | Ubuntu-24.04-Paket (WP-O2) | Apache-2.0 | Neu genutzt für den Factur-X-Metadatenschritt (`--update-from-json`), weiter als eigener Prozess. |
| veraPDF 1.30.4 | Image `verapdf/cli:v1.30.4@sha256:3252b493…c28c0` | GPL-3.0+ / MPL-2.0 | Nur Prüfwerkzeug in Tests und CI (`scripts/verapdf-check.sh`), nicht im Produkt oder in einem Image des Hubs. |

Pflichten bei **Weitergabe** des Worker-Images: die Lizenztexte reisen mit (`/usr/share/doc/lab-hub/legal/`); Typst steht unter Apache-2.0 (kein Quellangebot nötig), die OFL-Schriften dürfen mit dem Programm weitergegeben werden. Offen wie bei WP-O2: Bestätigung durch den Nutzer/Juristen, SBOM-Erweiterung um Image-Pakete.

## SPDX-Inventar und SBOM (WP-H1, 20.11.2026; keine Rechtsberatung, keine rechtliche Freigabe)

- **Datei:** `legal/sbom/lab-hub.cdx.json` (CycloneDX 1.5, JSON, wird mit `legal/` in die Images kopiert). Je Komponente: `purl`, Version, SPDX-Lizenz (`licenses`), bei npm der SHA-512 aus dem Lockfile, bei SwiftPM die aufgelöste Revision.
- **Umfang (Stand `f8c212c`):** 272 Komponenten: SwiftPM 37 (`backend/Package.resolved`), npm 234 (`pwa/package-lock.json`, auch Dev-/Optional-Pakete, Eigenschaften `labhub:dev`/`labhub:optional`), BoringSSL als eingebettete Komponente von `swift-nio-ssl` (1). **Nicht enthalten:** Betriebssystem-/Toolchain-Pakete der Images (Ubuntu, OCR-Werkzeuge; siehe Abschnitt WP-O2).
- **Lizenzverteilung:** MIT 201, Apache-2.0 38, MPL-2.0 14, ISC 6, BSD-2-Clause 2, BSD-3-Clause 2, MIT-0 2, `(MIT OR CC0-1.0)` 1, 0BSD 1, BlueOak-1.0.0 1, CC0-1.0 1, OFL-1.1 1, Python-2.0 1, Unlicense 1. Außerhalb der üblichen Vorgabe: MPL-2.0 (axe-core, lightningcss, nur Build/Test) und OFL-1.1 (Inter-Schrift), vom Nutzer am 07.11.2026 bestätigt (`docs/OFFENE-FRAGEN.md`); Python-2.0 (argparse, nur Build-Zeit) ist nicht gesondert bestätigt.
- **Erzeugung:** `swift package resolve` oder ein Build (legt die Checkouts unter `$LH_SCRATCH/checkouts` an), dann `LH_SCRATCH=… node scripts/generate-sbom.mjs` (schreibt die Datei) bzw. `--check` (nur prüfen). Keine Zeitstempel/Zufalls-IDs, keine Netzwerkzugriffe, keine externen Dienste; zweimaliges Erzeugen liefert byte-gleiche Dateien.
- **Zuordnung SwiftPM:** Lizenz aus der LICENSE-/COPYING-/UNLICENSE-Datei im Checkout (Erkennung: Apache-2.0, MIT, BSD-2/3-Clause, ISC, Unlicense); der Checkout muss der Revision aus `Package.resolved` entsprechen. **npm:** `license`-Feld des Lockfiles.
- **Prüfung (`--check`, Teil von `scripts/ci.sh`):** Fehler bei fehlender/nicht zuordenbarer Lizenz, SPDX-Kennung außerhalb der Liste `KNOWN` im Skript (neue Kennung = bewusste Aufnahme), abweichender Checkout-Revision, nicht mehr benötigter Ausnahme und veralteter eingecheckter SBOM. Ausnahmen nur mit Begründung in `legal/sbom/license-overrides.json` (aktuell eine: `svelte-toolbelt`, Lockfile ohne Lizenzfeld, LICENSE im Paket ist MIT).
