import Foundation

/// How the picture fills the screen.
public enum VideoFit: String, Sendable, Equatable, Hashable, Codable, CaseIterable {
    /// The whole picture, letterboxed.
    case fit
    /// Fills the screen, cropping the edges.
    case fill
    /// Fills the screen, distorting the picture.
    case stretch

    public var label: String {
        switch self {
        case .fit: "Fit"
        case .fill: "Fill"
        case .stretch: "Stretch"
        }
    }
}

/// A display aspect ratio that replaces the one the file states: for a file whose shape is wrong (an anamorphic DVD shown squeezed,
/// a 4:3 TV rip flagged 16:9). Every engine applies it to the visible picture.
public enum AspectOverride: String, Sendable, Equatable, Hashable, Codable, CaseIterable {
    case source
    case ratio1x1 = "1:1"
    case ratio5x4 = "5:4"
    case ratio4x3 = "4:3"
    case ratio3x2 = "3:2"
    case ratio166 = "1.66:1"
    case ratio16x10 = "16:10"
    case ratio16x9 = "16:9"
    case ratio185 = "1.85:1"
    case ratio190 = "1.90:1"
    case ratio2x1 = "2:1"
    case ratio220 = "2.20:1"
    case ratio235 = "2.35:1"
    case ratio239 = "2.39:1"
    case ratio240 = "2.40:1"
    case ratio255 = "2.55:1"
    case ratio276 = "2.76:1"
    case ratio36x10 = "36:10"

    public var label: String { self == .source ? "Original" : rawValue }

    /// Width over height; nil keeps the file's own.
    public var ratio: Double? { self == .source ? nil : PictureRatio.parse(rawValue) }
}

/// Crops the picture to a shape, centred: takes off black bars that are part of the video itself (a 2.39:1 film in a 16:9 file, a
/// 4:3 show pillarboxed in 16:9), so Fit fills the screen with the picture alone and Fill crops less. The shape is the picture's as
/// encoded in the original source, before any aspect override. Coded as the old raw strings ("4:3", "off") so saved layouts from
/// earlier versions still load, and as a decimal for custom ratios.
public struct VideoCrop: Sendable, Equatable, Hashable, Codable {
    /// Width over height of what is kept; nil keeps the whole picture.
    public var ratio: Double?
    public var label: String

    private init(ratio: Double?, label: String) {
        self.ratio = ratio
        self.label = label
    }

    public static let off = VideoCrop(ratio: nil, label: "No Crop")
    public static let ratio4x3 = VideoCrop(ratio: 4.0 / 3.0, label: "4:3")
    public static let ratio3x2 = VideoCrop(ratio: 3.0 / 2.0, label: "3:2")
    public static let ratio166 = VideoCrop(ratio: 1.66, label: "1.66:1")
    public static let ratio16x9 = VideoCrop(ratio: 16.0 / 9.0, label: "16:9")
    public static let ratio185 = VideoCrop(ratio: 1.85, label: "1.85:1")
    public static let ratio190 = VideoCrop(ratio: 1.90, label: "1.90:1")
    public static let ratio2x1 = VideoCrop(ratio: 2.0, label: "2:1")
    public static let ratio220 = VideoCrop(ratio: 2.20, label: "2.20:1")
    public static let ratio235 = VideoCrop(ratio: 2.35, label: "2.35:1")
    public static let ratio239 = VideoCrop(ratio: 2.39, label: "2.39:1")
    public static let ratio240 = VideoCrop(ratio: 2.40, label: "2.40:1")
    public static let ratio276 = VideoCrop(ratio: 2.76, label: "2.76:1")

    /// Every shape the crop panel offers, in that order.
    public static let allCases: [VideoCrop] = [.off, .ratio4x3, .ratio3x2, .ratio166, .ratio16x9, .ratio185, .ratio190, .ratio2x1,
                                               .ratio220, .ratio235, .ratio239, .ratio240, .ratio276]

    /// Resolves a numeric crop ratio to a named preset when matching, or a formatted ratio otherwise.
    public static func precise(_ ratio: Double) -> VideoCrop {
        if let named = allCases.first(where: { abs(($0.ratio ?? -1) - ratio) < 0.0005 }) { return named }
        return VideoCrop(ratio: ratio, label: String(format: "%.2f:1", ratio))
    }

    /// Codec of the saved choice: the raw string an earlier version kept.
    private static let named: [String: Double] = ["4:3": 4.0 / 3.0, "3:2": 3.0 / 2.0, "1.66:1": 1.66, "16:9": 16.0 / 9.0,
                                                  "1.85:1": 1.85, "1.90:1": 1.90, "2:1": 2.0, "2.20:1": 2.20, "2.35:1": 2.35,
                                                  "2.39:1": 2.39, "2.40:1": 2.40, "2.76:1": 2.76]

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        if let ratio = Self.named[raw] {
            self = .precise(ratio)
        } else if let ratio = Double(raw), ratio > 0 {
            self = .precise(ratio)
        } else {
            self = .off
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        if let ratio = ratio, let raw = Self.named.first(where: { abs($0.value - ratio) < 0.0005 })?.key {
            try container.encode(raw)
        } else if let ratio = ratio {
            try container.encode(String(format: "%.4f", ratio))
        } else {
            try container.encode("off")
        }
    }
}

extension VideoCrop: CustomStringConvertible {
    public var description: String { label }
}

enum PictureRatio {
    /// "16:9" → 1.777…, "2.39:1" → 2.39.
    static func parse(_ text: String) -> Double? {
        let parts = text.split(separator: ":").compactMap { Double($0) }
        guard parts.count == 2, parts[1] > 0 else { return nil }
        return parts[0] / parts[1]
    }
}

public struct VideoLayout: Sendable, Equatable, Hashable, Codable {
    public static let zoomRange: ClosedRange<Double> = 1...3

    public var fit: VideoFit
    /// 1 is no zoom.
    public var zoom: Double
    public var aspect: AspectOverride
    public var crop: VideoCrop
    /// Points kept clear on the left and the right, where Fit sizes the picture: the safe area beside a notch (Zoom Mode's Normal). The
    /// picture stays centred on the whole view. Belongs to the screen it is on, so it is never saved.
    public var inset: Double

    public init(fit: VideoFit = .fit, zoom: Double = 1, aspect: AspectOverride = .source, crop: VideoCrop = .off, inset: Double = 0) {
        self.fit = fit
        self.zoom = min(Self.zoomRange.upperBound, max(Self.zoomRange.lowerBound, zoom))
        self.aspect = aspect
        self.crop = crop
        self.inset = max(0, inset)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(fit: (try? container.decode(VideoFit.self, forKey: .fit)) ?? .fit,
                  zoom: (try? container.decode(Double.self, forKey: .zoom)) ?? 1,
                  aspect: (try? container.decode(AspectOverride.self, forKey: .aspect)) ?? .source,
                  crop: (try? container.decode(VideoCrop.self, forKey: .crop)) ?? .off)
    }

    private enum CodingKeys: String, CodingKey {
        case fit, zoom, aspect, crop
    }
}

public enum DeinterlaceMode: String, Sendable, Equatable, Hashable, Codable, CaseIterable {
    /// Only frames the file marks as interlaced.
    case auto, off, on

    public var label: String {
        switch self {
        case .auto: "Automatic"
        case .off: "Off"
        case .on: "Always"
        }
    }
}

/// The curve that maps HDR brightness onto a display that cannot show all of it (libplacebo's names).
public enum ToneMappingCurve: String, Sendable, Equatable, Hashable, Codable, CaseIterable {
    case auto, bt2390 = "bt.2390", bt2446a = "bt.2446a", spline, hable, mobius, clip

    public var label: String {
        switch self {
        case .auto: "Automatic"
        case .bt2390: "BT.2390"
        case .bt2446a: "BT.2446a"
        case .spline: "Spline"
        case .hable: "Hable (filmic)"
        case .mobius: "Möbius"
        case .clip: "Clip"
        }
    }
}

public enum HDROutputMode: String, Sendable, Equatable, Hashable, Codable, CaseIterable {
    /// HDR on a display that can show it, tone-mapped to SDR otherwise.
    case auto
    /// Always tone-mapped to SDR (saves battery, avoids a dim UI around bright video).
    case sdr

    public var label: String { self == .auto ? "HDR when supported" : "Always SDR" }
}

public enum UpscalingMode: String, Sendable, Equatable, Hashable, Codable, CaseIterable {
    case off
    /// A sharper conventional scaler. Not machine learning.
    case quality
    /// Machine-learning super resolution on the device, where the chip and the video allow it; otherwise `quality`.
    case ai

    public var label: String {
        switch self {
        case .off: "Standard"
        case .quality: "High quality"
        case .ai: "AI super resolution"
        }
    }
}

public struct VideoProcessing: Sendable, Equatable, Hashable, Codable {
    public var deinterlace: DeinterlaceMode
    public var toneMapping: ToneMappingCurve
    public var hdrOutput: HDROutputMode
    public var upscaling: UpscalingMode
    /// Dolby Vision where the stream has it. Off plays the HDR10 (or HLG) picture underneath instead: for a release whose Dolby Vision
    /// looks wrong (a green or purple cast, crushed shadows). A profile 5 stream has no such picture and keeps its Dolby Vision.
    /// AetherEngine and mpv apply it; AVPlayer always shows Dolby Vision.
    public var dolbyVision: Bool

    public init(deinterlace: DeinterlaceMode = .auto, toneMapping: ToneMappingCurve = .auto, hdrOutput: HDROutputMode = .auto,
                upscaling: UpscalingMode = .off, dolbyVision: Bool = true) {
        self.deinterlace = deinterlace
        self.toneMapping = toneMapping
        self.hdrOutput = hdrOutput
        self.upscaling = upscaling
        self.dolbyVision = dolbyVision
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(deinterlace: (try? container.decode(DeinterlaceMode.self, forKey: .deinterlace)) ?? .auto,
                  toneMapping: (try? container.decode(ToneMappingCurve.self, forKey: .toneMapping)) ?? .auto,
                  hdrOutput: (try? container.decode(HDROutputMode.self, forKey: .hdrOutput)) ?? .auto,
                  upscaling: (try? container.decode(UpscalingMode.self, forKey: .upscaling)) ?? .off,
                  dolbyVision: (try? container.decode(Bool.self, forKey: .dolbyVision)) ?? true)
    }
}

public enum SubtitleColour: String, Sendable, Equatable, Hashable, Codable, CaseIterable {
    case white, yellow, cyan, green

    public var label: String { rawValue.capitalized }

    /// sRGB, 0…1.
    public var rgb: (red: Double, green: Double, blue: Double) {
        switch self {
        case .white: (1, 1, 1)
        case .yellow: (1, 0.92, 0.23)
        case .cyan: (0.4, 0.92, 1)
        case .green: (0.5, 1, 0.5)
        }
    }
}

public enum SubtitleBackground: String, Sendable, Equatable, Hashable, Codable, CaseIterable {
    /// An outline and a drop shadow.
    case outline
    /// A translucent box behind each line.
    case box

    public var label: String { self == .outline ? "Outline" : "Box" }
}

/// How subtitles look. Applies to the app's own subtitle drawing and, through the engine, to text subtitles the engine draws.
public struct SubtitleStyle: Sendable, Equatable, Hashable, Codable {
    public static let scaleRange: ClosedRange<Double> = 0.5...2
    public static let positionRange: ClosedRange<Double> = 0...40
    public static let hdrPeakRange: ClosedRange<Int> = 80...1000

    /// 1 is the default size.
    public var scale: Double
    public var colour: SubtitleColour
    public var background: SubtitleBackground
    /// Lift above the bottom edge, as a percentage of the picture height.
    public var bottomMargin: Double
    /// Replace the styles an ASS/SSA file brings with the ones above. Off keeps the file's fonts, colours and positions.
    public var overridesFileStyles: Bool
    /// Brightness of white subtitle text over HDR video, in nits. 203 is the reference white of BT.2408.
    public var hdrPeakNits: Int

    public init(scale: Double = 1, colour: SubtitleColour = .white, background: SubtitleBackground = .outline, bottomMargin: Double = 4,
                overridesFileStyles: Bool = false, hdrPeakNits: Int = 203) {
        self.scale = min(Self.scaleRange.upperBound, max(Self.scaleRange.lowerBound, scale))
        self.colour = colour
        self.background = background
        self.bottomMargin = min(Self.positionRange.upperBound, max(Self.positionRange.lowerBound, bottomMargin))
        self.overridesFileStyles = overridesFileStyles
        self.hdrPeakNits = min(Self.hdrPeakRange.upperBound, max(Self.hdrPeakRange.lowerBound, hdrPeakNits))
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(scale: (try? container.decode(Double.self, forKey: .scale)) ?? 1,
                  colour: (try? container.decode(SubtitleColour.self, forKey: .colour)) ?? .white,
                  background: (try? container.decode(SubtitleBackground.self, forKey: .background)) ?? .outline,
                  bottomMargin: (try? container.decode(Double.self, forKey: .bottomMargin)) ?? 4,
                  overridesFileStyles: (try? container.decode(Bool.self, forKey: .overridesFileStyles)) ?? false,
                  hdrPeakNits: (try? container.decode(Int.self, forKey: .hdrPeakNits)) ?? 203)
    }
}

/// When subtitles come on by themselves.
public enum SubtitleMode: String, Sendable, Equatable, Hashable, Codable, CaseIterable {
    /// Never by themselves.
    case off
    /// Only forced subtitles (signs, foreign-language lines) in the preferred language.
    case forcedOnly
    /// Full subtitles in the preferred language, forced ones when only those exist.
    case always

    public var label: String {
        switch self {
        case .off: "Off"
        case .forcedOnly: "Forced only"
        case .always: "Always"
        }
    }
}

/// The engine for streams the built-in player cannot play natively. AetherEngine plays Dolby Vision natively, composes profile 7 FEL and
/// renders TrueHD/DTS:X objects to spatial audio. mpv draws subtitles with full ASS styling and has audio files, deinterlacing and
/// tone-mapping controls.
public enum AdvancedEngine: String, Sendable, Equatable, Hashable, Codable, CaseIterable {
    case aether, mpv
}

/// Player behaviour the user sets once in Settings. Stored as one JSON value, so new fields fall back to defaults.
public struct PlayerPreferences: Sendable, Equatable, Hashable, Codable {
    public var subtitleMode: SubtitleMode
    /// Prefer subtitles for the deaf and hard of hearing (SDH/CC) when both kinds exist.
    public var prefersSDH: Bool
    public var subtitleStyle: SubtitleStyle
    /// Preferred audio language (ISO 639-2 or 639-1). nil means English (`defaultAudioLanguage`), whatever track the file marks as its
    /// default.
    public var audioLanguage: String?
    /// The audio language the player picks when none is set: English.
    public static let defaultAudioLanguage = "eng"
    /// Fit or Fill from before Zoom Mode; read once, to start Zoom Mode from it (Fill → Crop).
    public var videoLayout: VideoLayout
    /// Video › Zoom Mode, for every video (as in Infuse).
    public var zoomMode: VideoZoomMode
    /// Video › Aspect Ratio per title (`AspectRatioChoice.titleKey`); a title with none plays at Original.
    public var aspectRatios: [String: AspectRatioChoice]
    public var processing: VideoProcessing
    /// Shows Skip Intro / Skip Recap / Skip Credits when the media marks them.
    public var showsSkipButtons: Bool
    /// Skips marked intros and recaps without asking.
    public var skipsIntrosAutomatically: Bool
    /// Vertical swipes on the left and right of the picture change brightness and volume (iPhone and iPad).
    public var swipeGestures: Bool
    /// A soft glow of the picture's colours around letterboxed video.
    public var ambientMode: Bool
    /// The engine for files the built-in player cannot play natively (see `AdvancedEngine`).
    public var advancedEngine: AdvancedEngine
    /// AetherEngine composes Dolby Vision profile 7 FEL pictures: both layers decoded and joined on the GPU every frame, on its software
    /// path. Off by default since 25 October 2026: on a phone a UHD remux could stutter there, and that path has no AVPlayer, so ambient mode,
    /// AI upscaling and Picture in Picture cannot work. Off plays the same stream on AVPlayer's hardware route (Dolby Vision 8.1).
    public var composesDolbyVisionFEL: Bool
    /// AetherEngine renders TrueHD and DTS:X object audio as spatial audio.
    public var rendersObjectAudio: Bool

    public init(subtitleMode: SubtitleMode = .always, prefersSDH: Bool = false, subtitleStyle: SubtitleStyle = SubtitleStyle(),
                audioLanguage: String? = nil, videoLayout: VideoLayout = VideoLayout(), zoomMode: VideoZoomMode = .normal,
                aspectRatios: [String: AspectRatioChoice] = [:], processing: VideoProcessing = VideoProcessing(),
                showsSkipButtons: Bool = true, skipsIntrosAutomatically: Bool = false, swipeGestures: Bool = true, ambientMode: Bool = false,
                advancedEngine: AdvancedEngine = .aether, composesDolbyVisionFEL: Bool = false, rendersObjectAudio: Bool = true) {
        self.subtitleMode = subtitleMode
        self.prefersSDH = prefersSDH
        self.subtitleStyle = subtitleStyle
        self.audioLanguage = audioLanguage
        self.videoLayout = videoLayout
        self.zoomMode = zoomMode
        self.aspectRatios = aspectRatios.filter { $0.value != .original }
        self.processing = processing
        self.showsSkipButtons = showsSkipButtons
        self.skipsIntrosAutomatically = skipsIntrosAutomatically
        self.swipeGestures = swipeGestures
        self.ambientMode = ambientMode
        self.advancedEngine = advancedEngine
        self.composesDolbyVisionFEL = composesDolbyVisionFEL
        self.rendersObjectAudio = rendersObjectAudio
    }

    public init(from decoder: Decoder) throws {
        let defaults = PlayerPreferences()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(subtitleMode: (try? container.decode(SubtitleMode.self, forKey: .subtitleMode)) ?? defaults.subtitleMode,
                  prefersSDH: (try? container.decode(Bool.self, forKey: .prefersSDH)) ?? defaults.prefersSDH,
                  subtitleStyle: (try? container.decode(SubtitleStyle.self, forKey: .subtitleStyle)) ?? defaults.subtitleStyle,
                  audioLanguage: try? container.decodeIfPresent(String.self, forKey: .audioLanguage),
                  videoLayout: (try? container.decode(VideoLayout.self, forKey: .videoLayout)) ?? defaults.videoLayout,
                  zoomMode: (try? container.decode(VideoZoomMode.self, forKey: .zoomMode))
                      ?? ((try? container.decode(VideoLayout.self, forKey: .videoLayout))?.fit == .fill ? .crop : .normal),
                  aspectRatios: (try? container.decode([String: AspectRatioChoice].self, forKey: .aspectRatios)) ?? [:],
                  processing: (try? container.decode(VideoProcessing.self, forKey: .processing)) ?? defaults.processing,
                  showsSkipButtons: (try? container.decode(Bool.self, forKey: .showsSkipButtons)) ?? defaults.showsSkipButtons,
                  skipsIntrosAutomatically: (try? container.decode(Bool.self, forKey: .skipsIntrosAutomatically)) ?? defaults.skipsIntrosAutomatically,
                  swipeGestures: (try? container.decode(Bool.self, forKey: .swipeGestures)) ?? defaults.swipeGestures,
                  ambientMode: (try? container.decode(Bool.self, forKey: .ambientMode)) ?? defaults.ambientMode,
                  advancedEngine: (try? container.decode(AdvancedEngine.self, forKey: .advancedEngine)) ?? defaults.advancedEngine,
                  composesDolbyVisionFEL: (try? container.decode(Bool.self, forKey: .composesDolbyVisionFEL)) ?? defaults.composesDolbyVisionFEL,
                  rendersObjectAudio: (try? container.decode(Bool.self, forKey: .rendersObjectAudio)) ?? defaults.rendersObjectAudio)
    }

    /// The FEL choice is saved under a new name: the old one held the old default (on), which nobody chose, so every saved copy starts
    /// with the new default (off) once.
    private enum CodingKeys: String, CodingKey {
        case subtitleMode, prefersSDH, subtitleStyle, audioLanguage, videoLayout, zoomMode, aspectRatios, processing, showsSkipButtons, skipsIntrosAutomatically,
             swipeGestures, ambientMode, advancedEngine, rendersObjectAudio
        case composesDolbyVisionFEL = "composesDolbyVisionFEL2"
    }
}
