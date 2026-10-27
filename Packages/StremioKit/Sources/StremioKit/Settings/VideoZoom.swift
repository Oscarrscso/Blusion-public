import Foundation

/// Video › Zoom Mode, as in Infuse: how the picture is scaled into the screen. One global setting, kept for every video.
public enum VideoZoomMode: String, Sendable, Equatable, Hashable, Codable, CaseIterable, Identifiable {
    /// The whole picture, fitted inside the safe area: clear of an iPhone's notch or Dynamic Island.
    case normal
    /// The whole picture, fitted to the whole screen, notch side included (iPhone only, as in Infuse).
    case aspectFit
    /// Fills the screen, cropping the overflow. A chosen Aspect Ratio is the shape it fills with.
    case crop
    /// Fills the screen exactly, the shape distorted to fit. A chosen Aspect Ratio is the shape it stretches.
    case stretch

    public var id: Self { self }

    public var label: String {
        switch self {
        case .normal: "Normal"
        case .aspectFit: "Aspect Fit"
        case .crop: "Crop"
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

/// Video › Aspect Ratio, as in Infuse: the shape of the film inside the frame. Crop and Stretch use it in place of the frame's own shape,
/// so the frame's baked-in black bars are cropped off (a 1.85:1 film in a 16:9 file, cropped to 1.85:1). Normal and Aspect Fit show the
/// whole frame and do not use it. It never squeezes the picture. Kept per title: a film, or a TV season.
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

    /// Width over height of the picture kept; nil for Auto, the frame's own shape.
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

    /// The crop it sets in Crop and Stretch; nil for Auto.
    public var crop: VideoCrop? { ratio.map { .precise($0) } }

    /// Where the choice is kept: the film, or the series' season, so every episode of a season shares it.
    public static func titleKey(for request: StreamRequest) -> String {
        guard let season = request.season else { return request.id }
        let series = request.id.split(separator: ":").first.map(String.init) ?? request.id
        return "\(series):s\(season)"
    }
}

extension VideoLayout {
    /// The picture for a Zoom Mode and Aspect Ratio. `safeInset` is how far the safe area keeps the picture from each side (points):
    /// Normal fits inside it, the other modes use the whole screen. The display aspect is the file's own and nothing is zoomed.
    public init(zoomMode: VideoZoomMode, aspectRatio: AspectRatioChoice, safeInset: Double = 0) {
        switch zoomMode.onThisDevice {
        case .normal: self.init(fit: .fit, inset: safeInset)
        case .aspectFit: self.init(fit: .fit)
        case .crop: self.init(fit: .fill, crop: aspectRatio.crop ?? .off)
        case .stretch: self.init(fit: .stretch, crop: aspectRatio.crop ?? .off)
        }
    }
}
