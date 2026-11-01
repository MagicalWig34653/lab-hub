#!/usr/bin/env bash
# WP-R0 spike, step 3 (exploratory): can TaxlabEInvoice incl. Builder and its tests run on Linux if
# TaxlabRender is cut down to its data types (RenderData etc.) without PDFRenderer/RichTextConversion?
# Works on a copy inside the container; taxlab mounted read-only.
# Usage: scripts/spike-r0/linux-patched-einvoice.sh <dir containing Packages/> [image]
set -euo pipefail
TAXLAB="${1:?dir containing Packages/}"
IMAGE="${2:-swift:6.2}"
docker run --rm -v "$TAXLAB/Packages:/src:ro" "$IMAGE" bash -c '
  set -e
  mkdir -p /work
  for p in TaxlabCore TaxlabModel TaxlabLayout TaxlabRender TaxlabEInvoice; do cp -r /src/$p /work/; rm -rf /work/$p/.build; done
  cd /work
  # Layout: CoreFoundation NSNumber type checks -> objCType based
  sed -i "s/CFGetTypeID(n) == CFBooleanGetTypeID()/String(cString: n.objCType) == \"c\"/; s/CFNumberIsFloatType(n)/(String(cString: n.objCType) == \"d\" || String(cString: n.objCType) == \"f\")/" TaxlabLayout/Sources/TaxlabLayout/TotalsLayoutParser.swift
  # Render: drop Apple-only renderer files and their tests, drop linker settings
  rm TaxlabRender/Sources/TaxlabRender/PDFRenderer.swift TaxlabRender/Sources/TaxlabRender/RichTextConversion.swift
  rm -f TaxlabRender/Tests/TaxlabRenderTests/*.swift
  cat > TaxlabRender/Package.swift <<EOF
// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "TaxlabRender",
    products: [.library(name: "TaxlabRender", targets: ["TaxlabRender"])],
    dependencies: [.package(path: "../TaxlabLayout"), .package(path: "../TaxlabModel"), .package(path: "../TaxlabCore")],
    targets: [.target(name: "TaxlabRender", dependencies: ["TaxlabLayout", "TaxlabModel", "TaxlabCore"])],
    swiftLanguageModes: [.v6])
EOF
  echo "=== Layout build"; (cd TaxlabLayout && swift build 2>&1 | grep -E "error:|Build complete" | sort -u | head -20)
  echo "=== Render build"; (cd TaxlabRender && swift build 2>&1 | grep -E "error:|Build complete" | sort -u | head -30)
  # EInvoice: only PDF-embedding files + tests removed
  cd TaxlabEInvoice
  rm Sources/TaxlabEInvoice/PDFA3Embedder.swift Tests/TaxlabEInvoiceTests/PDFA3Tests.swift Tests/TaxlabEInvoiceTests/SameSourceTests.swift
  sed -i "/^public enum PDFEmbeddedXML/,\$d; s/^import CoreGraphics/#if canImport(FoundationXML)\\nimport FoundationXML\\n#endif/" Sources/TaxlabEInvoice/CIIReader.swift
  cat > Package.swift <<EOF
// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "TaxlabEInvoice",
    products: [.library(name: "TaxlabEInvoice", targets: ["TaxlabEInvoice"])],
    dependencies: [.package(path: "../TaxlabCore"), .package(path: "../TaxlabModel"), .package(path: "../TaxlabRender")],
    targets: [
        .target(name: "TaxlabEInvoice", dependencies: ["TaxlabCore", "TaxlabModel", "TaxlabRender"]),
        .testTarget(name: "TaxlabEInvoiceTests", dependencies: ["TaxlabEInvoice"])
    ], swiftLanguageModes: [.v6])
EOF
  echo "=== EInvoice (with Builder) build+test"; swift build 2>&1 | grep -E "error:|Build complete" | sort -u | head -20
  swift test 2>&1 | grep -E "error:|✘|Test run" | sort -u | head -30
'
