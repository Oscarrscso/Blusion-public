import Foundation

/// Video › Zoom Mode: how the source content is cropped and scaled into the screen. One global setting, kept for every video.
public enum VideoZoomMode: String, Sendable, Equatable, Hashable, Codable, CaseIterable, Identifiable {
    /// Uncropped container frame (unless an explicit Aspect Ratio is chosen), fitted inside the safe area clear of notch or Dynamic Island.
    case normal
    /// Uncropped container frame (unless an explicit Aspect Ratio is chosen), fitted to the whole screen (iPhone/iPad only).
    case aspectFit
    /// Trims encoded black bars (detected automatically in Auto, or from the chosen Aspect Ratio) and fits the remaining movie proportionally without overshooting.
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

    /// Modes that automatically apply detected black-bar trimming when Aspect Ratio is Auto.
    public var trimsDetectedBars: Bool {
        switch self {
        case .normal, .aspectFit: false
        case .crop, .fill, .stretch: true
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

/// A centred crop of the original frame, used to trim encoded bars before fitting or filling the screen.
/// Selecting a ratio preserves the original picture's proportions. Kept per title: a film, or a TV season.
public enum AspectRatioChoice: String, Sendable, Equatable, Hashable, Codable, CaseIterable, Identifiable {
    case auto, sdtv, hdtv16x10, hdtv16x9, widescreenA, widescreenB, anamorphicA, anamorphicB, anamorphicC, ultraWidescreen

    public var id: Self { self }

    public var label: String {
        switch self {
        case .auto: "Auto"
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

    /// Width over height of the area to keep; nil for Auto, which uses detected bars in bar-trimming modes.
    public var ratio: Double? {
        switch self {
        case .auto: nil
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
    /// - Manual `aspectRatio` choices always take precedence over `detectedAspect`.
    /// - `Crop` trims encoded bars and proportionally fits the remaining picture (`fit: .fit`) without discarding movie content.
    /// - `Fill` intentionally scales to cover the entire viewport (`fit: .fill`), sacrificing outer edges when ratios differ.
    public init(zoomMode: VideoZoomMode, aspectRatio: AspectRatioChoice, detectedAspect: Double? = nil, safeInset: Double = 0) {
        let mode = zoomMode.onThisDevice
        let detected = detectedAspect.flatMap { $0.isFinite && (0.5...4).contains($0) ? VideoCrop.precise($0) : nil }
        let crop: VideoCrop = if aspectRatio != .auto {
            aspectRatio.crop
        } else if mode.trimsDetectedBars {
            detected ?? .off
        } else {
            .off
        }
        switch mode {
        case .normal: self.init(fit: .fit, crop: crop, inset: safeInset)
        case .aspectFit, .crop: self.init(fit: .fit, crop: crop)
        case .fill: self.init(fit: .fill, crop: crop)
        case .stretch: self.init(fit: .stretch, crop: crop)
        }
    }
}
