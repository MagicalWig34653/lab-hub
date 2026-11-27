// swift-tools-version:6.0
import PackageDescription

// WP-ST3 (F-14, ADR 0004): `HubCore` ist der Kern, je Modul ein Target `HubModule<Name>`, `HubKit` setzt zusammen.
// Abhängigkeitsrichtung: App → HubKit → Module → HubCore. Ein Modul nennt nie ein anderes Modul (geprüft von `TargetArchitectureTests`; Builds laufen
// mit `--explicit-target-dependency-import-check=error`).
let package = Package(
    name: "LabHub",
    platforms: [.macOS(.v14)],
    products: [.library(name: "HubKit", targets: ["HubKit"])],
    dependencies: [
        .package(url: "https://github.com/vapor/vapor.git", from: "4.121.4"),
        .package(url: "https://github.com/vapor/fluent.git", from: "4.13.0"),
        .package(url: "https://github.com/vapor/fluent-postgres-driver.git", from: "2.10.0"),
        // WP-K1 (F-04): Beta-Abhängigkeit auf exakten Commit gepinnt (1.0.0-beta.1), Zugriff nur über PasskeyService.
        .package(url: "https://github.com/swift-server/webauthn-swift.git", revision: "909cf4193cde7d64196553c4245ab647a68aaaca"),
        // Vom Wrapper direkt benutzt (Bindung der attestierten Credential-ID); gleicher Stand wie webauthn-swift.
        .package(url: "https://github.com/unrelentingtech/SwiftCBOR.git", revision: "fd929a6d8f7651ce0f63fc99397fd5762358cc29"),
        .package(url: "https://github.com/apple/swift-crypto.git", "3.8.1"..<"5.0.0")
    ],
    targets: [
        .target(name: "HubCore", dependencies: [
            .product(name: "Vapor", package: "vapor"),
            .product(name: "Fluent", package: "fluent"),
            .product(name: "FluentPostgresDriver", package: "fluent-postgres-driver"),
            .product(name: "WebAuthn", package: "webauthn-swift"),
            .product(name: "SwiftCBOR", package: "SwiftCBOR"),
            .product(name: "Crypto", package: "swift-crypto")
        ]),
        .target(name: "HubModuleDMS", dependencies: [
            "HubCore",
            .product(name: "Vapor", package: "vapor"),
            .product(name: "Fluent", package: "fluent"),
            .product(name: "Crypto", package: "swift-crypto")
        ]),
        .target(name: "HubModuleInvoice", dependencies: [
            "HubCore",
            .product(name: "Vapor", package: "vapor"),
            .product(name: "Fluent", package: "fluent"),
            .product(name: "Crypto", package: "swift-crypto")
        ]),
        .target(name: "HubKit", dependencies: [
            "HubCore", "HubModuleDMS", "HubModuleInvoice",
            .product(name: "Vapor", package: "vapor")
        ]),
        .executableTarget(name: "App", dependencies: ["HubKit"]),
        .testTarget(name: "HubKitTests", dependencies: [
            "HubCore", "HubModuleDMS", "HubModuleInvoice", "HubKit",
            .product(name: "XCTVapor", package: "vapor"),
            .product(name: "Crypto", package: "swift-crypto")
        ])
    ]
)
