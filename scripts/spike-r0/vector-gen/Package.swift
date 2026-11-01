// swift-tools-version: 6.0
// WP-R0: generates synthetic conformance vectors (JSON, decimal strings) with the taxlab reference
// implementation. Expects ../TaxlabCore and ../TaxlabModel next to this package (see generate.sh).
import PackageDescription
let package = Package(
    name: "vectorgen",
    dependencies: [.package(path: "../TaxlabCore"), .package(path: "../TaxlabModel")],
    targets: [.executableTarget(name: "vectorgen", dependencies: ["TaxlabCore", "TaxlabModel"])],
    swiftLanguageModes: [.v6])
