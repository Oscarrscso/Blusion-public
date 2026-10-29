// swift-tools-version: 6.0
import PackageDescription

// Value-only geometry shared with AetherPlayer's isolated dynamic framework.
let package = Package(
    name: "PlaybackGeometry",
    platforms: [.iOS("26.0"), .macOS(.v14)],
    products: [.library(name: "PlaybackGeometry", targets: ["PlaybackGeometry"])],
    targets: [
        .target(name: "PlaybackGeometry"),
        .testTarget(name: "PlaybackGeometryTests", dependencies: ["PlaybackGeometry"]),
    ],
    swiftLanguageModes: [.v6]
)
