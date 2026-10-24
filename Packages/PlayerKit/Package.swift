// swift-tools-version: 6.0
import PackageDescription

// PlaybackEngine protocol, AVEngine (Apple only), subtitle parsers, progress and coordination logic.
// Imports AVFoundation only, never UIKit, so it builds and tests on macOS; pure logic also builds on Linux.
let package = Package(
    name: "PlayerKit",
    platforms: [.iOS("26.0"), .macOS(.v14)],
    products: [
        .library(name: "PlayerKit", targets: ["PlayerKit"]),
        // MockEngine for test targets of this and other packages. Never linked into the app.
        .library(name: "PlayerKitTestSupport", targets: ["PlayerKitTestSupport"]),
    ],
    dependencies: [
        .package(path: "../StremioKit"),
    ],
    targets: [
        .target(name: "PlayerKit", dependencies: ["StremioKit"]),
        .target(name: "PlayerKitTestSupport", dependencies: ["PlayerKit"]),
        .testTarget(
            name: "PlayerKitTests",
            dependencies: ["PlayerKit", "PlayerKitTestSupport", .product(name: "StremioKitTestSupport", package: "StremioKit")]
        ),
    ],
    swiftLanguageModes: [.v6]
)
