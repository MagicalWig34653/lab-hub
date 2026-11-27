# Third-party notices / Drittanbieterhinweise

lab-hub (AGPL-3.0-only) is shipped with statically linked third-party code. This file and the
`third-party/` directory travel with every release image (`/usr/share/doc/lab-hub/legal/`).
Stand: 27.11.2026. Keine Rechtsberatung.

## BoringSSL (statically linked via `swift-nio-ssl`)

| Item | Value |
| --- | --- |
| Carrier package | `swift-nio-ssl` 2.37.6, revision `15e0b9e495786807272dd4891fa4bac76aa43034` (`backend/Package.resolved`) |
| Bundled source | `Sources/CNIOBoringSSL`, "derived from BoringSSL ... at revision `8eb25be6fa18d475291122887a7bccd3762ff236`" (`hash.txt`) |
| Upstream license | Apache License 2.0 (BoringSSL `LICENSE` at that revision, verbatim in `third-party/boringssl/LICENSE`, SHA-256 `827c8d8fc207c2392794eef9e00fe246f9f61fdcc132556c275be3dd8c3cd97f`) |
| Source of the license text | `https://boringssl.googlesource.com/boringssl/+/8eb25be6fa18d475291122887a7bccd3762ff236/LICENSE` |

The `LICENSE` file of BoringSSL also contains a "Licenses for support code" section (Go license,
Copyright (c) 2009 The Go Authors). Per upstream it covers parts of the TLS test suite that are not
part of libcrypto/libssl when compiled; it is reproduced because the file is shipped unchanged.

### Findings in the bundled sources (swift-nio-ssl 2.37.6)

Counted over `*.c *.cc *.h *.S *.inc` in `Sources/CNIOBoringSSL` (666 files):

- 0 files carry the old header "Licensed under the OpenSSL license" (2.37.5 / BoringSSL `817ab07e`: 323).
- 534 files carry the Apache-2.0 header. The remaining 132 files are generated assembly,
  generated tables and small headers without a license header; they are part of BoringSSL and fall
  under its `LICENSE` (Apache-2.0).
- One file (`crypto/poly1305/poly1305_arm_asm.S`) states that it was taken from the public-domain
  NEON2 implementation of SUPERCOP by D. J. Bernstein and Peter Schwabe.
- Copyright holders named in the headers (Apache-2.0 files, count of occurrences): The OpenSSL
  Project Authors (322), The BoringSSL Authors (206), Oracle and/or its affiliates (28), Nokia (14),
  Intel Corporation / Intel Inc (5), Amazon (3), the HRSS authors, Robert Nagy, RTFM Inc,
  Network Resonance Inc, Brian Smith, Arm Ltd, Apple Inc (one each).

### Stale license reference in the upstream NOTICE (explained, not changed)

`third-party/swift-nio-ssl/NOTICE.txt` is the unmodified upstream file. It still says that the
BoringSSL code is under a "Combination ISC and OpenSSL license". That reference is outdated:
BoringSSL switched its license to Apache-2.0 (upstream commit
`33d1049b1f730d2725bb09b2256fd5fe4c46b17e`, "Switch the license to Apache 2.0, matching OpenSSL
upstream"), and the code bundled in swift-nio-ssl 2.37.6 carries the Apache-2.0 headers
(see counts above). swift-nio-ssl has not updated this sentence of its NOTICE. We keep the upstream
file byte-identical and document the discrepancy here; the authoritative text for the bundled
BoringSSL revision is `third-party/boringssl/LICENSE`.

## swift-nio-ssl itself

Apache License 2.0: `third-party/swift-nio-ssl/LICENSE.txt` (verbatim) and
`third-party/swift-nio-ssl/NOTICE.txt` (verbatim, see above).

## Render tools in the worker image (WP-R6b, ADR 0008)

Only the worker image (`Dockerfile.worker`, stages `worker-tools`, `worker`, `worker-test`) carries these tools; the API image does not. They run as separate
processes and are never linked.

| Item | Value |
| --- | --- |
| Typst 0.15.1 | Apache-2.0. Static binary from `ghcr.io/typst/typst:0.15.1@sha256:032e292249bcd378480cc7c142cfa324b63ef8aadeb88d7e7230320c4c9c422f`. `third-party/typst/LICENSE` and `NOTICE` are the files of the release archive, verbatim (the NOTICE lists third-party code, e.g. MIT and the LLVM exception). |
| typst-assets 0.15.1 | Fonts and ICC profiles embedded in the Typst binary: Libertinus Serif (OFL-1.1), New Computer Modern (GUST Font License), DejaVu Sans Mono (Bitstream Vera / public domain), ICC profiles (CC0-1.0). `third-party/typst-assets/LICENSE` and `NOTICE`, verbatim from the tag `v0.15.1`. Embedded fonts stay enabled; system fonts are ignored. |
| Inter 4.1 | OFL-1.1 (SIL Open Font License). `Inter-Regular.ttf` and `Inter-Bold.ttf` from `https://github.com/rsms/inter/releases/download/v4.1/Inter-4.1.zip` (SHA-256 `9883fdd4a49d4fb66bd8177ba6625ef9a64aa45899767dde3d36aa425756b11e`); `third-party/inter/LICENSE.txt` verbatim. The font names are unchanged; the font files are embedded (subset) in generated PDFs. |
| qpdf 11.9, poppler-utils | Distribution packages (Apache-2.0, GPL), see `docs/LIZENZEN.md` (WP-O2). |

## Other dependencies

The complete inventory with SPDX identifiers and an SBOM is tracked in WP-H1 (`docs/LIZENZEN.md`);
this directory covers the BoringSSL / swift-nio-ssl finding F-03 and the render tools above.

## Verification

`scripts/check-third-party-notices.sh` checks that the pinned `swift-nio-ssl` version is at least
2.37.6, that the files in `third-party/` match the checked-out package (NOTICE, LICENSE) and the
recorded checksums, and that the bundled BoringSSL sources contain no OpenSSL-license headers.
