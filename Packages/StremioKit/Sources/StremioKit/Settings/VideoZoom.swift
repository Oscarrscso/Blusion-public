import Foundation

/// Video › Zoom Mode: how the source content is cropped and scaled into the screen. One global setting, kept for every video.
public enum VideoZoomMode: String, Sendable, Equatable, Hashable, Codable, CaseIterable, Identifiable {
    /// Whole uncropped container frame, fitted inside the safe area clear of notch or Dynamic Island.
    case normal
    /// Whole uncropped container frame, fitted to the whole screen (iPhone/iPad only).
    case aspectFit
    /// Trims encoded black bars for the selected Aspect Ratio and fits the remaining movie proportionally without overshooting.
    case crop
    /// Proportionally scales until the picture covers every edge of the screen, intentionally sacrificing outer image content.
    case fill
    /// Fills the screen non-uniformly, distorting the visible picture to match the viewport.
    case stretch

    public var id: Self { self }

    public var label: String {
        switch self {
        case .normal: "Normal"
        case .aspectFit: "Aspect Fit"
        case .crop: "Crop"
        case .fill: "Fill"
        case .stretch: "Stretch"
        }
    }

    /// The modes this device offers, in menu and zoom-button order. Aspect Fit differs from Normal only beside a notch or Dynamic
    /// Island, so a Mac (whose window has neither) leaves it out, as Infuse does.
    public static var available: [VideoZoomMode] {
        #if os(iOS) && !targetEnvironment(macCatalyst)
        allCases
        #else
        allCases.filter { $0 != .aspectFit }
        #endif
    }

    /// The mode a tap on the zoom button moves to: the next one this device offers, round to the first.
    public var next: VideoZoomMode {
        let modes = Self.available
        guard let index = modes.firstIndex(of: self) else { return .normal }
        return modes[(index + 1) % modes.count]
    }

    /// A saved mode this device does not offer (Aspect Fit saved on an iPhone, read on a Mac) plays as Normal.
    public var onThisDevice: VideoZoomMode { Self.available.contains(self) ? self : .normal }
}

/// Centred crop of the original source frame, used to trim encoded black bars before fitting or filling the screen.
/// Selecting a ratio preserves the original picture's proportions. Kept per title: a film, or a TV season.
public enum AspectRatioChoice: String, Sendable, Equatable, Hashable, Codable, CaseIterable, Identifiable {
    case original, sdtv, hdtv16x10, hdtv16x9, widescreenA, widescreenB, anamorphicA, anamorphicB, anamorphicC, ultraWidescreen

    public var id: Self { self }

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        if raw == "auto" {
            self = .original
        } else {
            self = Self(rawValue: raw) ?? .original
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public var label: String {
        switch self {
        case .original: "Original"
        case .sdtv: "SDTV (4:3)"
        case .hdtv16x10: "HDTV (16:10)"
        case .hdtv16x9: "HDTV (16:9)"
        case .widescreenA: "Widescreen A (1.85:1)"
        case .widescreenB: "Widescreen B (2.00:1)"
        case .anamorphicA: "Anamorphic A (2.35:1)"
        case .anamorphicB: "Anamorphic B (2.39:1)"
        case .anamorphicC: "Anamorphic C (2.40:1)"
        case .ultraWidescreen: "Ultra-Widescreen (36:10)"
        }
    }

    /// Width over height of the area to keep; nil for Original, which keeps the full uncropped container frame.
    public var ratio: Double? {
        switch self {
        case .original: nil
        case .sdtv: 4.0 / 3.0
        case .hdtv16x10: 16.0 / 10.0
        case .hdtv16x9: 16.0 / 9.0
        case .widescreenA: 1.85
        case .widescreenB: 2.0
        case .anamorphicA: 2.35
        case .anamorphicB: 2.39
        case .anamorphicC: 2.40
        case .ultraWidescreen: 36.0 / 10.0
        }
    }

    public var crop: VideoCrop { ratio.map(VideoCrop.precise) ?? .off }

    /// Where the choice is kept: the film, or the series' season, so every episode of a season shares it.
    public static func titleKey(for request: StreamRequest) -> String {
        guard let season = request.season else { return request.id }
        let series = request.id.split(separator: ":").first.map(String.init) ?? request.id
        return "\(series):s\(season)"
    }
}

extension VideoLayout {
    /// Separates source bar cropping from display scaling:
    /// - `Normal` and `Aspect Fit` show the uncropped container frame (`crop: .off`), inside the safe area or across the screen.
    /// - `Crop` trims encoded bars for the chosen `aspectRatio` and fits the remaining picture proportionally (`fit: .fit`) without overshooting.
    /// - `Fill` intentionally scales to cover every edge of the viewport (`fit: .fill`), sacrificing outer image content when ratios differ.
    /// - `Stretch` trims encoded bars for the chosen `aspectRatio` and stretches non-uniformly to fill the viewport (`fit: .stretch`).
    public init(zoomMode: VideoZoomMode, aspectRatio: AspectRatioChoice, safeInset: Double = 0) {
        switch zoomMode.onThisDevice {
        case .normal: self.init(fit: .fit, inset: safeInset)
        case .aspectFit: self.init(fit: .fit)
        case .crop: self.init(fit: .fit, crop: aspectRatio.crop)
        case .fill: self.init(fit: .fill, crop: aspectRatio.crop)
        case .stretch: self.init(fit: .stretch, crop: aspectRatio.crop)
        }
    }
}
