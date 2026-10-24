import Foundation

// Plain value types for Blusion's adapter (FallbackPlayer's AetherBackend). This framework links neither PlayerKit nor any other Blusion
// package (see Package.swift), so nothing AetherEngine-specific leaks out and nothing of Blusion's is duplicated in here.

public struct AetherTrack: Sendable, Equatable {
    /// AetherEngine's stream index (or synthetic id for files and native-route tracks).
    public let id: Int
    public let name: String
    /// libavcodec spelling: "eac3", "truehd", "hdmv_pgs_subtitle".
    public let codec: String
    public let language: String?
    public let channels: Int
    public let isDefault: Bool
    public let isForced: Bool
    public let isHearingImpaired: Bool
    public let isCommentary: Bool
    public let isAtmos: Bool
    public let isDTSX: Bool
    public let isExternal: Bool

    public init(id: Int, name: String, codec: String, language: String?, channels: Int, isDefault: Bool, isForced: Bool,
                isHearingImpaired: Bool, isCommentary: Bool, isAtmos: Bool, isDTSX: Bool, isExternal: Bool) {
        self.id = id
        self.name = name
        self.codec = codec
        self.language = language
        self.channels = channels
        self.isDefault = isDefault
        self.isForced = isForced
        self.isHearingImpaired = isHearingImpaired
        self.isCommentary = isCommentary
        self.isAtmos = isAtmos
        self.isDTSX = isDTSX
        self.isExternal = isExternal
    }
}

public struct AetherChapter: Sendable, Equatable {
    public let title: String
    public let start: TimeInterval
}

public struct AetherFailure: Error, Sendable, Equatable {
    public enum Kind: Sendable, Equatable { case network, format, unauthorized, notFound, other }
    public let kind: Kind
    public let message: String
}

public enum AetherEvent: Sendable, Equatable {
    case loaded(duration: TimeInterval?, audio: [AetherTrack], subtitles: [AetherTrack], selectedAudio: Int?, selectedSubtitle: Int?)
    case position(TimeInterval)
    case buffered(TimeInterval)
    case paused(Bool)
    case buffering(Bool)
    case tracks(audio: [AetherTrack], subtitles: [AetherTrack], selectedAudio: Int?, selectedSubtitle: Int?)
    case chapters([AetherChapter])
    case ended
    case failed(AetherFailure)
}

public struct AetherOptions: Sendable, Equatable {
    /// Dolby Vision profile 7 FEL: decode both layers and compose them on the GPU (with per-frame Dolby Vision metadata), instead of
    /// converting to single-layer profile 8.1 and dropping the enhancement layer.
    public var composesFEL: Bool
    /// TrueHD Atmos and DTS:X: render the objects (heights included) into a 7.1.4 bed delivered as Apple spatial audio (APAC),
    /// instead of the lossless channel bed alone.
    public var rendersObjectAudio: Bool
    public var preferredAudioLanguages: [String]
    /// Off presents the HDR10 / HLG base layer of a Dolby Vision stream instead.
    public var dolbyVision: Bool

    public init(composesFEL: Bool = true, rendersObjectAudio: Bool = true, preferredAudioLanguages: [String] = [], dolbyVision: Bool = true) {
        self.composesFEL = composesFEL
        self.rendersObjectAudio = rendersObjectAudio
        self.preferredAudioLanguages = preferredAudioLanguages
        self.dolbyVision = dolbyVision
    }
}

public struct AetherSubtitleStyle: Sendable, Equatable {
    /// 1 is the default size.
    public var scale: Double
    /// 0...1 each.
    public var red: Double
    public var green: Double
    public var blue: Double
    /// A dark box behind the text, rather than an outline.
    public var boxed: Bool
    /// Distance of the bottom line from the bottom of the picture, in percent of its height.
    public var bottomMarginPercent: Double
    /// Ignore the colours and fonts the subtitle file sets.
    public var overridesFileStyles: Bool

    public init(scale: Double = 1, red: Double = 1, green: Double = 1, blue: Double = 1, boxed: Bool = false,
                bottomMarginPercent: Double = 5, overridesFileStyles: Bool = false) {
        self.scale = scale
        self.red = red
        self.green = green
        self.blue = blue
        self.boxed = boxed
        self.bottomMarginPercent = bottomMarginPercent
        self.overridesFileStyles = overridesFileStyles
    }
}

public enum AetherFit: Sendable, Equatable { case fit, fill, stretch }

/// What is playing, for Blusion's statistics panel. Strings are ready to show; nil when the engine cannot tell.
public struct AetherStatistics: Sendable, Equatable {
    public var engine: String
    public var decoder: String?
    public var videoCodec: String?
    public var width: Int?
    public var height: Int?
    public var frameRate: Double?
    public var videoBitrate: Double?
    public var audioBitrate: Double?
    public var bufferedAhead: TimeInterval?
    public var sourceColour: String?
    public var dolbyVision: String?
    public var outputColour: String?
    public var audioCodec: String?
    public var audioChannels: String?
    public var audioOutput: String?
    public var notes: [String] = []

    public init(engine: String) { self.engine = engine }
}
