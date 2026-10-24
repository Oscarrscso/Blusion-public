// swift-tools-version: 6.0
import PackageDescription

// OPT-IN (ADR-006). Not part of the default app build: `scripts/enable-fallback.sh` adds it to the generated Xcode project.
// Keeping the third-party binary dependencies (MPVKit, AetherEngine) out of the default build means a version or API mismatch here can never break the main app.
let package = Package(
    name: "FallbackPlayer",
    platforms: [.iOS("26.0")],
    products: [
        .library(name: "FallbackPlayer", targets: ["FallbackPlayer"]),
    ],
    dependencies: [
        .package(path: "../PlayerKit"),
        .package(path: "../StremioKit"),
        // The LGPL build of MPVKit. Built and run on device with 0.41.0 (Package.resolved); MPVBackend uses mpv 0.40 options.
        .package(url: "https://github.com/mpvkit/MPVKit", from: "0.40.0"),
        // AetherEngine, wrapped in its own dynamic framework (see Packages/AetherPlayer/Package.swift for why).
        .package(path: "../AetherPlayer"),
    ],
    targets: [
        .target(
            name: "FallbackPlayer",
            dependencies: ["PlayerKit", .product(name: "StremioKit", package: "StremioKit"), .product(name: "MPVKit", package: "MPVKit"),
                           .product(name: "AetherPlayer", package: "AetherPlayer")]
        ),
    ],
    swiftLanguageModes: [.v6]
)
