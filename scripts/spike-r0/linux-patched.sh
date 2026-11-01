#!/usr/bin/env bash
# WP-R0 spike, step 2: build/test TaxlabReports and TaxlabEInvoice on Linux after the MINIMAL changes
# found necessary (applied only to a copy inside the container; the taxlab repo is mounted read-only).
# Changes: platforms declaration removed; Reports: drop ReportPDF.swift + Render/Designer deps + PDF test;
# EInvoice: drop PDF/Render-bound files (CIIReader PDF part, PDFA3Embedder, EInvoiceBuilder) and their tests.
# Usage: scripts/spike-r0/linux-patched.sh <dir containing Packages/> [image]
set -euo pipefail
TAXLAB="${1:?dir containing Packages/}"
IMAGE="${2:-swift:6.2}"
docker run --rm -v "$TAXLAB/Packages:/src:ro" "$IMAGE" bash -c '
  set -e
  mkdir -p /work && cd /src
  for p in TaxlabCore TaxlabModel TaxlabReports TaxlabEInvoice; do cp -r /src/$p /work/; rm -rf /work/$p/.build; done
  cd /work
  # --- Reports: remove PDF export and Render/Designer dependencies
  rm TaxlabReports/Sources/TaxlabReports/ReportPDF.swift TaxlabReports/Tests/TaxlabReportsTests/ReportPDFTests.swift
  cat > TaxlabReports/Package.swift <<EOF
// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "TaxlabReports",
    products: [.library(name: "TaxlabReports", targets: ["TaxlabReports"])],
    dependencies: [.package(path: "../TaxlabCore"), .package(path: "../TaxlabModel")],
    targets: [
        .target(name: "TaxlabReports", dependencies: ["TaxlabCore", "TaxlabModel"]),
        .testTarget(name: "TaxlabReportsTests", dependencies: ["TaxlabReports", "TaxlabModel", "TaxlabCore"]),
    ], swiftLanguageModes: [.v6])
EOF
  sed -i "/criteriaText/d" TaxlabReports/Tests/TaxlabReportsTests/ReportEngineTests.swift
  echo "=== Reports (patched)"; (cd TaxlabReports && swift build 2>&1 | grep -E "error|Build complete" | head -30; swift test 2>&1 | grep -E "error:|✘|Test run|Issue" | head -30)
  # --- EInvoice: keep Writer, Validator, Data, DecimalFormat
  cd TaxlabEInvoice
  rm Sources/TaxlabEInvoice/PDFA3Embedder.swift
  # CIIReader: cut the CoreGraphics-based PDFEmbeddedXML; EInvoiceBuilder: keep only the RenderData-free head (lines 1-72)
  sed -i "/^public enum PDFEmbeddedXML/,\$d; s/^import CoreGraphics/#if canImport(FoundationXML)\\nimport FoundationXML\\n#endif/" Sources/TaxlabEInvoice/CIIReader.swift
  sed -i "/^import TaxlabRender/d" Sources/TaxlabEInvoice/EInvoiceBuilder.swift
  head -72 Sources/TaxlabEInvoice/EInvoiceBuilder.swift > /tmp/b.swift && echo "}" >> /tmp/b.swift && mv /tmp/b.swift Sources/TaxlabEInvoice/EInvoiceBuilder.swift
  rm Tests/TaxlabEInvoiceTests/PDFA3Tests.swift Tests/TaxlabEInvoiceTests/SameSourceTests.swift Tests/TaxlabEInvoiceTests/BuilderTests.swift Tests/TaxlabEInvoiceTests/Support.swift
  cat > Package.swift <<EOF
// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "TaxlabEInvoice",
    products: [.library(name: "TaxlabEInvoice", targets: ["TaxlabEInvoice"])],
    dependencies: [.package(path: "../TaxlabCore"), .package(path: "../TaxlabModel")],
    targets: [
        .target(name: "TaxlabEInvoice", dependencies: ["TaxlabCore", "TaxlabModel"]),
        .testTarget(name: "TaxlabEInvoiceTests", dependencies: ["TaxlabEInvoice"])
    ], swiftLanguageModes: [.v6])
EOF
  echo "=== EInvoice (patched)"; swift build 2>&1 | grep -E "error|Build complete" | head -30; swift test 2>&1 | grep -E "error:|✘|Test run|Issue" | head -30
'
