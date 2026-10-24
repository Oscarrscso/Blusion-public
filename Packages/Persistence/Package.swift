// swift-tools-version: 6.0
import PackageDescription

// SwiftData metadata store and Keychain secret store. Apple-only code is behind `#if canImport(...)`,
// so the package still builds (as an empty module) on Linux. See ADR-002.
let package = Package(
    name: "Persistence",
    platforms: [.iOS("26.0"), .macOS(.v14)],
    products: [
        .library(name: "Persistence", targets: ["Persistence"]),
    ],
    dependencies: [
        .package(path: "../StremioKit"),
        .package(path: "../PlayerKit"),
    ],
    targets: [
        .target(name: "Persistence", dependencies: ["StremioKit", "PlayerKit"]),
        .testTarget(
            name: "PersistenceTests",
            dependencies: [
                "Persistence",
                .product(name: "StremioKit", package: "StremioKit"),
                .product(name: "PlayerKit", package: "PlayerKit"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
