// swift-tools-version: 6.0
import PackageDescription

// Foundation plus Apple's own SQLite3 and Compression modules (IMDb ratings dataset); those files compile out elsewhere. Builds for iOS,
// macOS and Linux so `swift test` runs on the host (PLAN §1).
let package = Package(
    name: "StremioKit",
    platforms: [.iOS("26.0"), .macOS(.v14)],
    products: [
        .library(name: "StremioKit", targets: ["StremioKit"]),
        // Mock addon launcher, stub transport and sample addons for test targets of this and other packages. Never linked into the app.
        .library(name: "StremioKitTestSupport", targets: ["StremioKitTestSupport"]),
    ],
    targets: [
        .target(name: "StremioKit"),
        .target(name: "StremioKitTestSupport", dependencies: ["StremioKit"]),
        .testTarget(
            name: "StremioKitTests",
            dependencies: ["StremioKit", "StremioKitTestSupport"],
            resources: [.copy("Fixtures")]
        ),
    ],
    swiftLanguageModes: [.v6]
)
