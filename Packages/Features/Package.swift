// swift-tools-version: 6.0
import PackageDescription

// Board, Discover, Search, Detail, StreamPicker, Player, Addons, Settings.
// View models (`@Observable`, no SwiftUI import) build and test everywhere; the SwiftUI views are iOS-only and sit behind
// `#if canImport(UIKit)`, so `swift test` on a Mac or Linux host builds the view models without them.
let package = Package(
    name: "Features",
    platforms: [.iOS("26.0"), .macOS(.v14)],
    products: [
        .library(name: "Features", targets: ["Features"]),
    ],
    dependencies: [
        .package(path: "../StremioKit"),
        .package(path: "../PlayerKit"),
        .package(path: "../Persistence"),
    ],
    targets: [
        .target(name: "Features", dependencies: ["StremioKit", "PlayerKit", "Persistence"]),
        .testTarget(
            name: "FeaturesTests",
            dependencies: [
                "Features",
                .product(name: "StremioKitTestSupport", package: "StremioKit"),
                .product(name: "PlayerKitTestSupport", package: "PlayerKit"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
