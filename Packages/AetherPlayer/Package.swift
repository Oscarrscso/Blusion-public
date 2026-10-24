// swift-tools-version: 6.1
import PackageDescription

// The AetherEngine player (LGPL-3.0 with an App Store exception), opt-in like FallbackPlayer: only the fallback build links it.
//
// Two reasons for its own package. Its traits (TrueHD Atmos and DTS:X rendered to Apple's spatial audio, the Dolby Vision Profile 7 FEL
// composer) can only be switched on in a package manifest, as XcodeGen drops them. And it has to be a DYNAMIC framework: MPVKit links a
// static FFmpeg into the app, whose symbols would otherwise answer AetherEngine's FFmpeg calls (AetherEngine docs/api.md, "One FFmpeg").
// Linked here, its `_av*` references bind to its own AetherLib* frameworks. This package must therefore never depend on MPVKit, nor on
// PlayerKit (a second copy of PlayerKit's types would live in this framework): its API is plain Swift and Blusion adapts it in FallbackPlayer.
let package = Package(
    name: "AetherPlayer",
    platforms: [.iOS("26.0"), .macOS(.v15)],
    products: [
        .library(name: "AetherPlayer", type: .dynamic, targets: ["AetherPlayer"]),
    ],
    dependencies: [
        .package(url: "https://github.com/superuser404notfound/AetherEngine", .upToNextMinor(from: "7.47.0"),
                 traits: ["TrueHDObjectAudio", "DTSXObjectAudio", "DualLayerDolbyVision"]),
    ],
    targets: [
        .target(name: "AetherPlayer", dependencies: [.product(name: "AetherEngine", package: "AetherEngine")]),
    ],
    swiftLanguageModes: [.v6]
)
