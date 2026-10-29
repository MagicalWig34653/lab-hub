// swift-tools-version:6.0
import PackageDescription
let package = Package(
    name: "LabHub",
    platforms: [.macOS(.v14)],
    products: [.library(name: "HubKit", targets: ["HubKit"])],
    dependencies: [
        .package(url: "https://github.com/vapor/vapor.git", from: "4.121.4"),
        .package(url: "https://github.com/vapor/fluent.git", from: "4.13.0"),
        .package(url: "https://github.com/vapor/fluent-postgres-driver.git", from: "2.10.0")
    ],
    targets: [
        .target(name: "HubKit", dependencies: [
            .product(name: "Vapor", package: "vapor"),
            .product(name: "Fluent", package: "fluent"),
            .product(name: "FluentPostgresDriver", package: "fluent-postgres-driver")
        ]),
        .executableTarget(name: "App", dependencies: ["HubKit"]),
        .testTarget(name: "HubKitTests", dependencies: ["HubKit", .product(name: "XCTVapor", package: "vapor")])
    ]
)
