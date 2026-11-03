import Foundation

/// How the app looks, as the listener sets it on Settings → Appearance: the accent colour, the page background, text size, font and
/// weight, card size, artwork corners and outline, spacing, phone grid columns, titles under posters, zoom transitions, the title page's
/// sections and spoilers, the iPhone's tab bar and the tab the app opens on.
///
/// Saved as one JSON string under `defaultsKey` in the standard defaults, so screens read it with `@AppStorage` and follow a change at
/// once. The root applies it (`appliesAppearance()`); cards and grids read it through `LayoutMetrics`. Every field decodes on its own, so
/// a value added later keeps older saves loading. The defaults live here and nowhere else, and they draw the app exactly as it was drawn
/// before these settings existed.
public struct AppearancePreferences: Sendable, Equatable, Codable {
    public static let defaultsKey = "settings.appearance"

    /// sRGB, 0…1.
    public struct RGB: Sendable, Equatable, Codable {
        public var red: Double
        public var green: Double
        public var blue: Double

        public init(red: Double, green: Double, blue: Double) {
            self.red = min(max(red, 0), 1)
            self.green = min(max(green, 0), 1)
            self.blue = min(max(blue, 0), 1)
        }
    }

    /// The tint of buttons, switches, the selected tab and links.
    public enum Accent: String, Sendable, Equatable, Codable, CaseIterable, Identifiable {
        /// The app's own accent, from the asset catalogue.
        case blusion
        case blue, indigo, purple, pink, red, orange, yellow, green, mint, teal, cyan, white
        /// `AppearancePreferences.customAccent`.
        case custom

        public var id: String { rawValue }

        public var label: String {
            switch self {
            case .blusion: "Blusion"
            case .custom: "Custom"
            default: rawValue.capitalized
            }
        }

        /// The preset's colour; nil for the custom accent, which is saved beside it.
        public var rgb: RGB? {
            switch self {
            case .blusion: RGB(red: 0.42, green: 0.51, blue: 1)
            case .blue: RGB(red: 0.04, green: 0.52, blue: 1)
            case .indigo: RGB(red: 0.37, green: 0.36, blue: 0.90)
            case .purple: RGB(red: 0.75, green: 0.35, blue: 0.95)
            case .pink: RGB(red: 1, green: 0.22, blue: 0.37)
            case .red: RGB(red: 1, green: 0.27, blue: 0.23)
            case .orange: RGB(red: 1, green: 0.62, blue: 0.04)
            case .yellow: RGB(red: 1, green: 0.84, blue: 0.04)
            case .green: RGB(red: 0.19, green: 0.82, blue: 0.35)
            case .mint: RGB(red: 0.39, green: 0.90, blue: 0.89)
            case .teal: RGB(red: 0.25, green: 0.78, blue: 0.88)
            case .cyan: RGB(red: 0.39, green: 0.82, blue: 1)
            case .white: RGB(red: 0.92, green: 0.92, blue: 0.94)
            case .custom: nil
            }
        }
    }

    /// The colour behind every page, and the colour hero artwork fades into.
    public enum Background: String, Sendable, Equatable, Codable, CaseIterable, Identifiable {
        case black, graphite, midnight
        /// A very dark shade of the accent.
        case tinted

        public var id: String { rawValue }
        public var label: String { rawValue.capitalized }
    }

    /// A fixed text size for the whole app, or the system's own.
    public enum TextSize: String, Sendable, Equatable, Codable, CaseIterable, Identifiable {
        case system, xSmall, small, medium, large, xLarge, xxLarge, xxxLarge

        public var id: String { rawValue }

        public var label: String {
            switch self {
            case .system: "System"
            case .xSmall: "Extra Small"
            case .small: "Small"
            case .medium: "Medium"
            case .large: "Large"
            case .xLarge: "Extra Large"
            case .xxLarge: "Huge"
            case .xxxLarge: "Largest"
            }
        }
    }

    /// The design of the system font throughout the app.
    public enum FontStyle: String, Sendable, Equatable, Codable, CaseIterable, Identifiable {
        case standard, rounded, serif, monospaced

        public var id: String { rawValue }
        public var label: String { self == .standard ? "Default" : rawValue.capitalized }
    }

    /// The width of every card in shelves and wide grids, as a share of the layout's own.
    public enum CardScale: String, Sendable, Equatable, Codable, CaseIterable, Identifiable {
        case small, standard, large, huge

        public var id: String { rawValue }
        public var label: String { self == .standard ? "Default" : rawValue.capitalized }

        public var factor: Double {
            switch self {
            case .small: 0.82
            case .standard: 1
            case .large: 1.2
            case .huge: 1.42
            }
        }
    }

    /// The roundness of posters, cards, tiles and stills, as a share of their own radius.
    public enum Corners: String, Sendable, Equatable, Codable, CaseIterable, Identifiable {
        case square, subtle, standard, round

        public var id: String { rawValue }
        public var label: String { self == .standard ? "Default" : rawValue.capitalized }

        public var factor: Double {
            switch self {
            case .square: 0
            case .subtle: 0.5
            case .standard: 1
            case .round: 1.8
            }
        }
    }

    /// The gaps between cards and between shelves, as a share of the layout's own.
    public enum Density: String, Sendable, Equatable, Codable, CaseIterable, Identifiable {
        case compact, standard, roomy

        public var id: String { rawValue }
        public var label: String { self == .standard ? "Default" : rawValue.capitalized }

        public var factor: Double {
            switch self {
            case .compact: 0.66
            case .standard: 1
            case .roomy: 1.35
            }
        }
    }

    /// The tab the app opens on when nothing else asks for one.
    public enum StartTab: String, Sendable, Equatable, Codable, CaseIterable, Identifiable {
        case home, discover, library, search

        public var id: String { rawValue }
        public var label: String { rawValue.capitalized }

        public var tab: LaunchRoute.Tab {
            switch self {
            case .home: .home
            case .discover: .discover
            case .library: .library
            case .search: .search
            }
        }
    }

    /// Ready-made looks. Applying one sets colour, text and cards together and leaves the rest (title pages, navigation) as it is.
    public enum Preset: String, Sendable, CaseIterable, Identifiable {
        case original, midnight, cinema, compact, bigScreen, paper, mono

        public var id: String { rawValue }

        public var label: String {
            switch self {
            case .original: "Original"
            case .midnight: "Midnight"
            case .cinema: "Cinema"
            case .compact: "Compact"
            case .bigScreen: "Big Screen"
            case .paper: "Paper"
            case .mono: "Mono"
            }
        }

        /// `appearance` with this preset's look.
        public func applied(to appearance: AppearancePreferences) -> AppearancePreferences {
            var look = AppearancePreferences()
            switch self {
            case .original:
                break
            case .midnight:
                look.accent = .indigo
                look.background = .midnight
                look.corners = .round
            case .cinema:
                look.accent = .red
                look.cardScale = .large
                look.density = .roomy
                look.corners = .subtle
                look.phoneGridColumns = 2
            case .compact:
                look.textSize = .small
                look.cardScale = .small
                look.density = .compact
                look.corners = .subtle
                look.phoneGridColumns = 4
                look.showsPosterTitles = true
            case .bigScreen:
                look.textSize = .xLarge
                look.boldText = true
                look.cardScale = .huge
                look.density = .roomy
                look.phoneGridColumns = 2
            case .paper:
                look.accent = .orange
                look.background = .tinted
                look.font = .serif
                look.corners = .round
                look.showsPosterTitles = true
            case .mono:
                look.accent = .white
                look.background = .graphite
                look.font = .monospaced
                look.corners = .square
                look.artworkOutline = false
            }
            var result = appearance
            result.accent = look.accent
            result.background = look.background
            result.textSize = look.textSize
            result.font = look.font
            result.boldText = look.boldText
            result.cardScale = look.cardScale
            result.corners = look.corners
            result.density = look.density
            result.phoneGridColumns = look.phoneGridColumns
            result.showsPosterTitles = look.showsPosterTitles
            result.artworkOutline = look.artworkOutline
            return result
        }
    }

    /// The column counts a phone's portrait poster grid offers. A wide window fits as many columns as the card size allows instead.
    public static let phoneGridColumnRange: ClosedRange<Int> = 2...5

    public var accent: Accent
    /// The accent when `accent` is `.custom`. Kept when another accent is chosen, so going back to Custom finds it again.
    public var customAccent: RGB
    public var background: Background
    public var textSize: TextSize
    public var font: FontStyle
    public var boldText: Bool
    public var cardScale: CardScale
    public var corners: Corners
    public var density: Density
    /// Poster columns of a grid (Library, Discover, See All) on a phone held upright.
    public var phoneGridColumns: Int
    /// Every poster carries its title and a grey line underneath, as landscape and square cards do.
    public var showsPosterTitles: Bool
    public var startTab: StartTab
    /// The hairline just inside every poster, card and still.
    public var artworkOutline: Bool
    /// A card zooms into the title it opens, and the title zooms back into it.
    public var zoomTransitions: Bool
    /// Unwatched episodes on a title page blur their still and synopsis until they have been started.
    public var hidesSpoilers: Bool
    /// The title page's sections below the episodes.
    public var showsReviews: Bool
    public var showsCast: Bool
    public var showsInformation: Bool
    public var showsRelated: Bool
    /// The iPhone's tab bar names its tabs under their icons.
    public var phoneTabTitles: Bool
    /// The iPhone's tab bar shrinks while a page scrolls down.
    public var minimisesTabBar: Bool
    /// The Continue Watching bar above the iPhone's tab bar.
    public var showsContinueBar: Bool

    public init(accent: Accent = .blusion, customAccent: RGB = RGB(red: 0.42, green: 0.51, blue: 1), background: Background = .black,
                textSize: TextSize = .system, font: FontStyle = .standard, boldText: Bool = false, cardScale: CardScale = .standard,
                corners: Corners = .standard, density: Density = .standard, phoneGridColumns: Int = 3, showsPosterTitles: Bool = false,
                startTab: StartTab = .home, artworkOutline: Bool = true, zoomTransitions: Bool = true, hidesSpoilers: Bool = false,
                showsReviews: Bool = true, showsCast: Bool = true, showsInformation: Bool = true, showsRelated: Bool = true,
                phoneTabTitles: Bool = false, minimisesTabBar: Bool = true, showsContinueBar: Bool = true) {
        self.accent = accent
        self.customAccent = customAccent
        self.background = background
        self.textSize = textSize
        self.font = font
        self.boldText = boldText
        self.cardScale = cardScale
        self.corners = corners
        self.density = density
        self.phoneGridColumns = min(max(phoneGridColumns, Self.phoneGridColumnRange.lowerBound), Self.phoneGridColumnRange.upperBound)
        self.showsPosterTitles = showsPosterTitles
        self.startTab = startTab
        self.artworkOutline = artworkOutline
        self.zoomTransitions = zoomTransitions
        self.hidesSpoilers = hidesSpoilers
        self.showsReviews = showsReviews
        self.showsCast = showsCast
        self.showsInformation = showsInformation
        self.showsRelated = showsRelated
        self.phoneTabTitles = phoneTabTitles
        self.minimisesTabBar = minimisesTabBar
        self.showsContinueBar = showsContinueBar
    }

    /// Written out, rather than synthesised, so that each field falls back to its default on its own, and so that the JSON coding never
    /// goes through `RawRepresentable`'s, which would call `rawValue`, which encodes again.
    public init(from decoder: Decoder) throws {
        let defaults = AppearancePreferences()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(accent: (try? container.decode(Accent.self, forKey: .accent)) ?? defaults.accent,
                  customAccent: (try? container.decode(RGB.self, forKey: .customAccent)) ?? defaults.customAccent,
                  background: (try? container.decode(Background.self, forKey: .background)) ?? defaults.background,
                  textSize: (try? container.decode(TextSize.self, forKey: .textSize)) ?? defaults.textSize,
                  font: (try? container.decode(FontStyle.self, forKey: .font)) ?? defaults.font,
                  boldText: (try? container.decode(Bool.self, forKey: .boldText)) ?? defaults.boldText,
                  cardScale: (try? container.decode(CardScale.self, forKey: .cardScale)) ?? defaults.cardScale,
                  corners: (try? container.decode(Corners.self, forKey: .corners)) ?? defaults.corners,
                  density: (try? container.decode(Density.self, forKey: .density)) ?? defaults.density,
                  phoneGridColumns: (try? container.decode(Int.self, forKey: .phoneGridColumns)) ?? defaults.phoneGridColumns,
                  showsPosterTitles: (try? container.decode(Bool.self, forKey: .showsPosterTitles)) ?? defaults.showsPosterTitles,
                  startTab: (try? container.decode(StartTab.self, forKey: .startTab)) ?? defaults.startTab,
                  artworkOutline: (try? container.decode(Bool.self, forKey: .artworkOutline)) ?? defaults.artworkOutline,
                  zoomTransitions: (try? container.decode(Bool.self, forKey: .zoomTransitions)) ?? defaults.zoomTransitions,
                  hidesSpoilers: (try? container.decode(Bool.self, forKey: .hidesSpoilers)) ?? defaults.hidesSpoilers,
                  showsReviews: (try? container.decode(Bool.self, forKey: .showsReviews)) ?? defaults.showsReviews,
                  showsCast: (try? container.decode(Bool.self, forKey: .showsCast)) ?? defaults.showsCast,
                  showsInformation: (try? container.decode(Bool.self, forKey: .showsInformation)) ?? defaults.showsInformation,
                  showsRelated: (try? container.decode(Bool.self, forKey: .showsRelated)) ?? defaults.showsRelated,
                  phoneTabTitles: (try? container.decode(Bool.self, forKey: .phoneTabTitles)) ?? defaults.phoneTabTitles,
                  minimisesTabBar: (try? container.decode(Bool.self, forKey: .minimisesTabBar)) ?? defaults.minimisesTabBar,
                  showsContinueBar: (try? container.decode(Bool.self, forKey: .showsContinueBar)) ?? defaults.showsContinueBar)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(accent, forKey: .accent)
        try container.encode(customAccent, forKey: .customAccent)
        try container.encode(background, forKey: .background)
        try container.encode(textSize, forKey: .textSize)
        try container.encode(font, forKey: .font)
        try container.encode(boldText, forKey: .boldText)
        try container.encode(cardScale, forKey: .cardScale)
        try container.encode(corners, forKey: .corners)
        try container.encode(density, forKey: .density)
        try container.encode(phoneGridColumns, forKey: .phoneGridColumns)
        try container.encode(showsPosterTitles, forKey: .showsPosterTitles)
        try container.encode(startTab, forKey: .startTab)
        try container.encode(artworkOutline, forKey: .artworkOutline)
        try container.encode(zoomTransitions, forKey: .zoomTransitions)
        try container.encode(hidesSpoilers, forKey: .hidesSpoilers)
        try container.encode(showsReviews, forKey: .showsReviews)
        try container.encode(showsCast, forKey: .showsCast)
        try container.encode(showsInformation, forKey: .showsInformation)
        try container.encode(showsRelated, forKey: .showsRelated)
        try container.encode(phoneTabTitles, forKey: .phoneTabTitles)
        try container.encode(minimisesTabBar, forKey: .minimisesTabBar)
        try container.encode(showsContinueBar, forKey: .showsContinueBar)
    }

    private enum CodingKeys: String, CodingKey {
        case accent, customAccent, background, textSize, font, boldText, cardScale, corners, density, phoneGridColumns, showsPosterTitles,
             startTab, artworkOutline, zoomTransitions, hidesSpoilers, showsReviews, showsCast, showsInformation, showsRelated,
             phoneTabTitles, minimisesTabBar, showsContinueBar
    }

    /// Field by field. Written out so that equality never falls to `RawRepresentable`'s, which would compare the JSON text.
    public static func == (lhs: AppearancePreferences, rhs: AppearancePreferences) -> Bool {
        let colours: Bool = lhs.accent == rhs.accent && lhs.customAccent == rhs.customAccent && lhs.background == rhs.background
        let text: Bool = lhs.textSize == rhs.textSize && lhs.font == rhs.font && lhs.boldText == rhs.boldText
        let cards: Bool = lhs.cardScale == rhs.cardScale && lhs.corners == rhs.corners && lhs.density == rhs.density
        let rest: Bool = lhs.phoneGridColumns == rhs.phoneGridColumns && lhs.showsPosterTitles == rhs.showsPosterTitles
            && lhs.startTab == rhs.startTab
        let motion: Bool = lhs.artworkOutline == rhs.artworkOutline && lhs.zoomTransitions == rhs.zoomTransitions
            && lhs.hidesSpoilers == rhs.hidesSpoilers
        let sections: Bool = lhs.showsReviews == rhs.showsReviews && lhs.showsCast == rhs.showsCast
            && lhs.showsInformation == rhs.showsInformation && lhs.showsRelated == rhs.showsRelated
        let tabs: Bool = lhs.phoneTabTitles == rhs.phoneTabTitles && lhs.minimisesTabBar == rhs.minimisesTabBar
            && lhs.showsContinueBar == rhs.showsContinueBar
        return colours && text && cards && rest && motion && sections && tabs
    }

    /// The preset this look is, if it is one.
    public var preset: Preset? {
        Preset.allCases.first { $0.applied(to: self) == self }
    }

    /// The accent's colour, the app's own included.
    public var accentRGB: RGB {
        accent == .custom ? customAccent : (accent.rgb ?? Accent.blusion.rgb ?? customAccent)
    }

    public var isDefault: Bool { self == AppearancePreferences() }

    /// What a card's height depends on besides its own shape, size and width: a shelf or grid that measured its cards measures again when
    /// this changes.
    public var layoutKey: String {
        [cardScale.rawValue, density.rawValue, corners.rawValue, textSize.rawValue, font.rawValue, "\(boldText)", "\(showsPosterTitles)",
         "\(phoneGridColumns)"].joined(separator: "|")
    }

    /// What is saved now, or the defaults.
    public static func saved(in defaults: UserDefaults = .standard) -> AppearancePreferences {
        defaults.string(forKey: defaultsKey).flatMap(AppearancePreferences.init(rawValue:)) ?? AppearancePreferences()
    }

    /// Back to the defaults (Settings → Clear data → Settings, and Appearance's Reset).
    public static func reset(in defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: defaultsKey)
    }
}

/// The JSON string `@AppStorage` keeps.
extension AppearancePreferences: RawRepresentable {
    public init?(rawValue: String) {
        guard let data = rawValue.data(using: .utf8), let value = try? JSONDecoder().decode(AppearancePreferences.self, from: data) else {
            return nil
        }
        self = value
    }

    public var rawValue: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        guard let data = try? encoder.encode(self), let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }
}
