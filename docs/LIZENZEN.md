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

Schluss: Der Befund ist **nicht erledigt**. Rückfalloption (1) aus F-03 („neuere `swift-nio-ssl`-Version“) entfällt, weil 2.37.5 bereits die neueste Version ist. Offen bleiben (2) TLS nur am Reverse Proxy und BoringSSL-freier Build (Machbarkeit zu verifizieren; Vapor/NIO ziehen `swift-nio-ssl` transitiv) und (3) AGPL-§7-Zusatzerlaubnis der Urheber mit juristischer Prüfung. Entscheidung durch den Nutzer; bis dahin keine Aussage in Doku/Releases, dass der Befund erledigt ist.
