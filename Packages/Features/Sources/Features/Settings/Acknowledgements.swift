import Foundation
import StremioKit

/// What the app ships and under which terms. The default build links no third-party code (ADR-001), so the list is short; the fallback
/// player's LGPL components appear only when that engine is built in (ADR-006, docs/licenses.md).
public struct Acknowledgement: Sendable, Equatable, Identifiable {
    public var id: String { name }
    public let name: String
    public let license: String
    public let detail: String
    public let sourceURL: URL?

    public init(name: String, license: String, detail: String, sourceURL: URL? = nil) {
        self.name = name
        self.license = license
        self.detail = detail
        self.sourceURL = sourceURL
    }

    public static func all(fallbackEngineLinked: Bool, aetherEngineLinked: Bool = false) -> [Acknowledgement] {
        var list = [
            Acknowledgement(name: "Apple frameworks", license: "Apple SDK terms",
                            detail: "SwiftUI, SwiftData, AVFoundation, AVKit and the Security framework come with iOS."),
            Acknowledgement(name: "TMDB", license: "TMDB API attribution",
                            detail: "This product uses the TMDB API but is not endorsed or certified by TMDB.",
                            sourceURL: URL(string: "https://www.themoviedb.org")),
            Acknowledgement(name: "IMDb", license: "IMDb non-commercial dataset terms",
                            detail: "\(IMDbAttribution.notice) \(IMDbAttribution.terms) The ratings file is downloaded to this device and not shared.",
                            sourceURL: IMDbAttribution.termsURL),
            Acknowledgement(name: "OpenSubtitles", license: "OpenSubtitles.com API terms",
                            detail: "Subtitles you search for in the player come from OpenSubtitles.com, through your own API key.",
                            sourceURL: URL(string: "https://www.opensubtitles.com")),
            Acknowledgement(name: "Review site icons", license: "Respective service trademarks",
                            detail: "IMDb, Letterboxd, Rotten Tomatoes, Metacritic and TMDB marks identify links to their services. "
                                + "Blusion is not affiliated with them."),
        ]
        if fallbackEngineLinked {
            list += [
                Acknowledgement(name: "MPVKit", license: "LGPL-3.0", detail: "Swift wrapper and prebuilt libmpv used by the optional fallback player.",
                                sourceURL: URL(string: "https://github.com/mpvkit/MPVKit")),
                Acknowledgement(name: "libmpv", license: "LGPL-2.1 or later (LGPL build)", detail: "Media player library used by the fallback player.",
                                sourceURL: URL(string: "https://github.com/mpv-player/mpv")),
                Acknowledgement(name: "FFmpeg", license: "LGPL-2.1 or later (LGPL build)", detail: "Demuxing and decoding libraries used by the fallback player.",
                                sourceURL: URL(string: "https://ffmpeg.org/")),
                Acknowledgement(name: "libplacebo", license: "LGPL-2.1 or later", detail: "Video rendering library used by the fallback player.",
                                sourceURL: URL(string: "https://code.videolan.org/videolan/libplacebo")),
                Acknowledgement(name: "libass", license: "ISC", detail: "Subtitle rendering used by the fallback player.",
                                sourceURL: URL(string: "https://github.com/libass/libass")),
                Acknowledgement(name: "MoltenVK", license: "Apache-2.0", detail: "Vulkan to Metal layer used by the fallback player.",
                                sourceURL: URL(string: "https://github.com/KhronosGroup/MoltenVK")),
                Acknowledgement(name: "libdovi", license: "MIT", detail: "Dolby Vision metadata parsing used by the fallback player's tone mapping.",
                                sourceURL: URL(string: "https://github.com/quietvoid/dovi_tool")),
                Acknowledgement(name: "dav1d", license: "BSD-2-Clause", detail: "AV1 software decoder used by the fallback player.",
                                sourceURL: URL(string: "https://code.videolan.org/videolan/dav1d")),
            ]
        }
        if aetherEngineLinked {
            list += [
                Acknowledgement(name: "AetherEngine", license: "LGPL-3.0 with an App Store exception",
                                detail: "Player engine for MKV, Dolby Vision (profile 7 FEL composition included) and Atmos, used by the fallback player.",
                                sourceURL: URL(string: "https://github.com/superuser404notfound/AetherEngine")),
                Acknowledgement(name: "FFmpegBuild (FFmpeg, dav1d, zimg, libzvbi)", license: "LGPL-2.1 (FFmpeg); BSD-2-Clause, WTFPL, LGPL-2.1+",
                                detail: "AetherEngine's own FFmpeg build, linked as dynamic frameworks.",
                                sourceURL: URL(string: "https://github.com/superuser404notfound/FFmpegBuild")),
                Acknowledgement(name: "LibDovi (dovi_tool)", license: "MIT", detail: "Dolby Vision metadata conversion used by AetherEngine.",
                                sourceURL: URL(string: "https://github.com/superuser404notfound/LibDovi")),
                Acknowledgement(name: "LibTrueHD (truehd)", license: "MIT; Apache-2.0 (truehd decoder)",
                                detail: "Dolby TrueHD and Atmos object decoding used by AetherEngine's spatial audio.",
                                sourceURL: URL(string: "https://github.com/superuser404notfound/LibTrueHD")),
            ]
        }
        return list
    }
}
