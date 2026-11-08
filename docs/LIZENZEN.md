# Lizenzen und Abhängigkeitsprüfung

Stand: 01.11.2026. Das vollständige Inventar mit SPDX-Einträgen und SBOM entsteht in WP-H1; dieses Dokument enthält vorerst den Prüfbefund aus WP-K0. Keine Rechtsberatung; die Rechtsfrage ist **nicht abschließend geklärt**.

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

Schluss BoringSSL: Der Befund ist **nicht erledigt**. Rückfalloption (1) aus F-03 („neuere `swift-nio-ssl`-Version“) entfällt, weil 2.37.5 bereits die neueste Version ist. Offen bleiben (2) TLS nur am Reverse Proxy und BoringSSL-freier Build (Machbarkeit zu verifizieren; Vapor/NIO ziehen `swift-nio-ssl` transitiv) und (3) AGPL-§7-Zusatzerlaubnis der Urheber mit juristischer Prüfung. Entscheidung durch den Nutzer; bis dahin keine Aussage in Doku/Releases, dass der Befund erledigt ist.

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

**Keine neue Abhängigkeit.** Der IMAP-Client (`Modules/DMS/Sources/IMAPClient.swift`) und der MIME-Parser (`MailMessage.swift`) sind Eigenentwicklung auf `swift-nio` (Apache-2.0) und `swift-nio-ssl` (Apache-2.0, bündelt BoringSSL; Prüfauftrag F-03 unverändert offen), beide ohnehin Abhängigkeiten von Vapor/Fluent. Die Verschlüsselung der Zugangsdaten nutzt `swift-crypto` (Apache-2.0), das bereits eingebunden ist. Begründung gegen eine IMAP-Bibliothek: Der Hub braucht nur LOGIN/AUTHENTICATE PLAIN, SELECT, UID SEARCH/FETCH/STORE/COPY/MOVE und LOGOUT (rund 300 Zeilen); eine zusätzliche Bibliothek hätte Lizenz-, Wartungs- und Sicherheitsfläche (TLS-Voreinstellungen, Größenlimits, Zeitlimits) ohne Gewinn. Getestet wird gegen **GreenMail** (`greenmail/standalone`, Apache-2.0) als Docker-Image **nur in den Tests**, nicht im Produkt oder in Images.

