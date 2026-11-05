import Foundation

/// How the app looks, as the listener sets it on Settings → Appearance: colour (accent, page background), text (size, font, width,
/// weight, slant, spacing, and a style of its own for headings), cards (size, corners, spacing, columns, captions, outline, artwork tone,
/// progress bars), Home's spotlight, title pages (sections, their order, spoilers) and motion and navigation (start tab, transitions,
/// animation speed, the iPhone's tab bar).
///
/// Saved as one JSON string under `defaultsKey` in the standard defaults, so screens read it with `@AppStorage` and follow a change at
/// once. The root applies it (`appliesAppearance()`); cards and grids read it through `LayoutMetrics`. Every field decodes on its own, so
/// a value added later keeps older saves loading, and the fields that used to be fixed steps (card size, corners, spacing, the outline
/// switch) read the old steps into the new values. The defaults live here and nowhere else, and they draw the app exactly as it was drawn
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

        func scaled(by factor: Double) -> RGB { RGB(red: red * factor, green: green * factor, blue: blue * factor) }
    }

    // MARK: - Colour

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
        case black, graphite, slate, midnight, plum, forest, cocoa
        /// A very dark shade of the accent, as dark as `tintStrength` says.
        case tinted
        /// `AppearancePreferences.customBackground`.
        case custom

        public var id: String { rawValue }
        public var label: String { rawValue.capitalized }

        /// The fixed backgrounds' colour; nil for Tinted and Custom, which come from other fields.
        public var rgb: RGB? {
            switch self {
            case .black: RGB(red: 0, green: 0, blue: 0)
            case .graphite: RGB(red: 0.075, green: 0.075, blue: 0.075)
            case .slate: RGB(red: 0.055, green: 0.067, blue: 0.085)
            case .midnight: RGB(red: 0.02, green: 0.035, blue: 0.085)
            case .plum: RGB(red: 0.075, green: 0.03, blue: 0.08)
            case .forest: RGB(red: 0.025, green: 0.06, blue: 0.04)
            case .cocoa: RGB(red: 0.08, green: 0.055, blue: 0.035)
            case .tinted, .custom: nil
            }
        }
    }

    // MARK: - Text

    /// A fixed text size for the whole app, or the system's own. The accessibility sizes go past the largest ordinary size.
    public enum TextSize: String, Sendable, Equatable, Codable, CaseIterable, Identifiable {
        case system, xSmall, small, medium, large, xLarge, xxLarge, xxxLarge
        case accessibility1, accessibility2, accessibility3, accessibility4, accessibility5

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
            case .accessibility1: "Accessibility 1"
            case .accessibility2: "Accessibility 2"
            case .accessibility3: "Accessibility 3"
            case .accessibility4: "Accessibility 4"
            case .accessibility5: "Accessibility 5"
            }
        }
    }

    /// The design of the system font throughout the app.
    public enum FontStyle: String, Sendable, Equatable, Codable, CaseIterable, Identifiable {
        case standard, rounded, serif, monospaced

        public var id: String { rawValue }
        public var label: String { self == .standard ? "Default" : rawValue.capitalized }
    }

    /// How wide the system font's letters are.
    public enum FontWidth: String, Sendable, Equatable, Codable, CaseIterable, Identifiable {
        case compressed, condensed, standard, expanded

        public var id: String { rawValue }
        public var label: String { self == .standard ? "Default" : rawValue.capitalized }
    }

    /// Extra space between letters, in points.
    public enum LetterSpacing: String, Sendable, Equatable, Codable, CaseIterable, Identifiable {
        case tight, standard, wide, wider

        public var id: String { rawValue }
        public var label: String { self == .standard ? "Default" : rawValue.capitalized }

        public var points: Double {
            switch self {
            case .tight: -0.5
            case .standard: 0
            case .wide: 0.8
            case .wider: 2
            }
        }
    }

    /// Extra space between the lines of text that wraps, in points.
    public enum LineSpacing: String, Sendable, Equatable, Codable, CaseIterable, Identifiable {
        case standard, relaxed, airy

        public var id: String { rawValue }
        public var label: String { self == .standard ? "Default" : rawValue.capitalized }

        public var points: Double {
            switch self {
            case .standard: 0
            case .relaxed: 3
            case .airy: 7
            }
        }
    }

    /// The design of shelf and section headings ("Continue Watching", "TMDb Reviews"): the text's own, or one of their own.
    public enum HeadingFont: String, Sendable, Equatable, Codable, CaseIterable, Identifiable {
        case matchText, standard, rounded, serif, monospaced

        public var id: String { rawValue }

        public var label: String {
            switch self {
            case .matchText: "Same as Text"
            case .standard: "Default"
            default: rawValue.capitalized
            }
        }

        /// The design, or nil to follow the text's.
        public var font: FontStyle? {
            switch self {
            case .matchText: nil
            case .standard: .standard
            case .rounded: .rounded
            case .serif: .serif
            case .monospaced: .monospaced
            }
        }
    }

    public enum HeadingWeight: String, Sendable, Equatable, Codable, CaseIterable, Identifiable {
        case regular, medium, semibold, bold, heavy, black

        public var id: String { rawValue }
        public var label: String { rawValue.capitalized }
    }

    /// The heading's text style: Title 3, Title 2 (the app's own), Title, Large Title.
    public enum HeadingSize: String, Sendable, Equatable, Codable, CaseIterable, Identifiable {
        case small, standard, large, huge

        public var id: String { rawValue }
        public var label: String { self == .standard ? "Default" : rawValue.capitalized }
    }

    // MARK: - Cards

    public enum CornerGroup: String, Sendable, Codable, CaseIterable, Identifiable {
        case artwork, playButton, actionButtons, filters, reviews, panels, playerControls, settingsPreview, settingsRows

        public var id: String { rawValue }
        public var label: String {
            switch self {
            case .artwork: "Artwork"
            case .playButton: "Play Button"
            case .actionButtons: "Action Buttons"
            case .filters: "Filters & Badges"
            case .reviews: "Reviews"
            case .panels: "Panels"
            case .playerControls: "Player Controls"
            case .settingsPreview: "Settings Preview"
            case .settingsRows: "Settings Rows"
            }
        }
    }

    /// The hairline just inside every poster, card and still.
    public enum Outline: String, Sendable, Equatable, Codable, CaseIterable, Identifiable {
        case off, faint, standard, strong

        public var id: String { rawValue }
        public var label: String { self == .standard ? "Default" : rawValue.capitalized }

        /// The hairline's white, as an opacity. The default is `Theme.artworkBorder`'s.
        public var opacity: Double {
            switch self {
            case .off: 0
            case .faint: 0.1
            case .standard: 0.22
            case .strong: 0.5
            }
        }

        /// The hairline's width in pixels.
        public var pixels: Double { self == .strong ? 2 : 1 }
    }

    /// The colour of the artwork on posters, cards, tiles and stills. Full-screen hero artwork keeps its own.
    public enum ArtworkTone: String, Sendable, Equatable, Codable, CaseIterable, Identifiable {
        case natural, vivid, muted, dim, mono

        public var id: String { rawValue }

        public var label: String {
            switch self {
            case .natural: "Natural"
            case .mono: "Black & White"
            default: rawValue.capitalized
            }
        }

        public var saturation: Double {
            switch self {
            case .natural, .dim: 1
            case .vivid: 1.35
            case .muted: 0.55
            case .mono: 0
            }
        }

        public var brightness: Double { self == .dim ? -0.14 : 0 }
        public var contrast: Double { self == .vivid || self == .mono ? 1.06 : 1 }
    }

    /// The colour of the progress line on Continue cards.
    public enum ProgressColour: String, Sendable, Equatable, Codable, CaseIterable, Identifiable {
        case white, accent

        public var id: String { rawValue }
        public var label: String { rawValue.capitalized }
    }

    public enum ProgressThickness: String, Sendable, Equatable, Codable, CaseIterable, Identifiable {
        case thin, standard, thick

        public var id: String { rawValue }
        public var label: String { self == .standard ? "Default" : rawValue.capitalized }

        public var points: Double {
            switch self {
            case .thin: 2
            case .standard: 3
            case .thick: 5
            }
        }
    }

    // MARK: - Title pages, navigation and motion

    /// The order of the two sections under a title's episodes.
    public enum SectionOrder: String, Sendable, Equatable, Codable, CaseIterable, Identifiable {
        case reviewsFirst, castFirst

        public var id: String { rawValue }
        public var label: String { self == .reviewsFirst ? "Reviews First" : "Cast First" }
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

    /// How fast the app's own animations run: SwiftUI's, every one of them, scaled at the root. Off draws each change at once.
    /// System pushes, sheets and the keyboard keep the system's timing.
    public enum AnimationSpeed: String, Sendable, Equatable, Codable, CaseIterable, Identifiable {
        case off, slower, standard, faster, fastest

        public var id: String { rawValue }
        public var label: String { self == .standard ? "Default" : rawValue.capitalized }

        /// The speed multiplier; zero is Off.
        public var factor: Double {
            switch self {
            case .off: 0
            case .slower: 0.5
            case .standard: 1
            case .faster: 1.6
            case .fastest: 2.5
            }
        }
    }

    // MARK: - Presets

    /// Ready-made looks. Applying one sets colour, text and cards together and leaves the rest (Home, title pages, navigation and
    /// motion) as it is. The custom accent and background colours are kept too, so a preset never loses a colour the listener mixed.
    public enum Preset: String, Sendable, CaseIterable, Identifiable {
        case original, midnight, cinema, compact, bigScreen, paper, mono, neon, noir, retro, calm

        public var id: String { rawValue }

        public var label: String {
            switch self {
            case .bigScreen: "Big Screen"
            default: rawValue.capitalized
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
                look.cornerScale = 1.8
            case .cinema:
                look.accent = .red
                look.cardScale = 1.2
                look.spacingScale = 1.35
                look.cornerScale = 0.5
                look.phoneGridColumns = 2
            case .compact:
                look.textSize = .small
                look.cardScale = 0.82
                look.spacingScale = 0.66
                look.cornerScale = 0.5
                look.phoneGridColumns = 4
                look.showsPosterTitles = true
            case .bigScreen:
                look.textSize = .xLarge
                look.boldText = true
                look.cardScale = 1.42
                look.spacingScale = 1.35
                look.phoneGridColumns = 2
            case .paper:
                look.accent = .orange
                look.background = .tinted
                look.font = .serif
                look.cornerScale = 1.8
                look.showsPosterTitles = true
            case .mono:
                look.accent = .white
                look.background = .graphite
                look.font = .monospaced
                look.cornerScale = 0
                look.outline = .off
            case .neon:
                look.accent = .pink
                look.background = .plum
                look.font = .rounded
                look.headingWeight = .black
                look.cornerScale = 2.2
                look.outline = .strong
                look.artworkTone = .vivid
                look.progressColour = .accent
                look.progressThickness = .thick
            case .noir:
                look.accent = .white
                look.font = .serif
                look.letterSpacing = .wide
                look.uppercaseHeadings = true
                look.cornerScale = 0
                look.outline = .faint
                look.artworkTone = .mono
            case .retro:
                look.accent = .yellow
                look.background = .cocoa
                look.font = .monospaced
                look.headingWeight = .heavy
                look.cornerScale = 0.5
                look.artworkTone = .muted
                look.progressColour = .accent
                look.progressThickness = .thick
            case .calm:
                look.accent = .mint
                look.background = .forest
                look.font = .rounded
                look.headingWeight = .semibold
                look.lineSpacing = .relaxed
                look.cornerScale = 1.5
                look.spacingScale = 1.35
                look.artworkTone = .muted
            }
            var result = appearance
            result.takeLook(from: look)
            return result
        }
    }

    // MARK: - Ranges and options

    public static let cardScaleRange: ClosedRange<Double> = 0.6...1.6
    public static let cornerScaleRange: ClosedRange<Double> = 0...2.5
    public static let spacingScaleRange: ClosedRange<Double> = 0.3...2
    public static let heroScaleRange: ClosedRange<Double> = 0.6...1.3
    public static let tintStrengthRange: ClosedRange<Double> = 0.04...0.3
    /// The column counts a phone's portrait poster grid offers. A wide window fits as many columns as the card size allows instead.
    public static let phoneGridColumnRange: ClosedRange<Int> = 2...6
    public static let captionLineRange: ClosedRange<Int> = 1...2
    /// Seconds between the spotlight's pages turning by themselves; zero leaves them for the listener to swipe.
    public static let heroAutoAdvanceOptions = [0, 5, 8, 12, 20, 30]

    // MARK: - Colour

    public var accent: Accent = .blusion
    /// The accent when `accent` is `.custom`. Kept when another accent is chosen, so going back to Custom finds it again.
    public var customAccent = RGB(red: 0.42, green: 0.51, blue: 1)
    public var background: Background = .black
    /// The background when `background` is `.custom`. Kept like the custom accent.
    public var customBackground = RGB(red: 0.06, green: 0.06, blue: 0.08)
    /// How much of the accent the Tinted background has, as a share of the accent's own brightness (`tintStrengthRange`).
    public var tintStrength: Double = 0.11

    // MARK: - Text

    public var textSize: TextSize = .system
    public var font: FontStyle = .standard
    public var boldText = false
    public var italicText = false
    public var fontWidth: FontWidth = .standard
    public var letterSpacing: LetterSpacing = .standard
    public var lineSpacing: LineSpacing = .standard
    public var headingFont: HeadingFont = .matchText
    public var headingWeight: HeadingWeight = .bold
    public var headingSize: HeadingSize = .standard
    public var uppercaseHeadings = false

    // MARK: - Cards

    /// Every card's width in shelves and wide grids, as a share of the layout's own (`cardScaleRange`).
    public var cardScale: Double = 1
    /// The roundness of posters, cards, tiles and stills, as a share of their own radius (`cornerScaleRange`). Zero is square.
    public var cornerScale: Double = 1
    /// Missing entries follow the global corner scale; overrides are absolute, not multiplied by it.
    public var cornerOverrides: [String: Double] = [:]
    public var includesCircularButtons = false

    public func cornerScale(for group: CornerGroup) -> Double {
        cornerOverrides[group.rawValue] ?? cornerScale
    }
    /// The gaps between cards and between shelves, as a share of the layout's own (`spacingScaleRange`).
    public var spacingScale: Double = 1
    /// Poster columns of a grid (Library, Discover, See All) on a phone held upright.
    public var phoneGridColumns = 3
    /// Every poster carries its title and a grey line underneath, as landscape and square cards do.
    public var showsPosterTitles = false
    /// Lines a card's title may take under it before it is cut off (`captionLineRange`). Every card of a kind keeps the same height.
    public var captionLines = 1
    /// The grey line under a card's title ("Drama · 2008").
    public var showsCaptionDetails = true
    public var outline: Outline = .standard
    public var artworkTone: ArtworkTone = .natural
    public var progressColour: ProgressColour = .white
    public var progressThickness: ProgressThickness = .standard
    /// The minutes left beside the progress line on Continue cards.
    public var showsTimeLeft = true

    // MARK: - Home

    /// The spotlight's height, as a share of its own (`heroScaleRange`).
    public var heroScale: Double = 1
    /// Seconds between the spotlight turning its page by itself; zero never (`heroAutoAdvanceOptions`).
    public var heroAutoAdvance = 0
    /// The dots under the spotlight that show which page it is on.
    public var showsPageDots = true

    // MARK: - Title pages

    /// Unwatched episodes on a title page hide what `spoilerStills`, `spoilerSynopses` and `spoilerTitles` say until they are started.
    public var hidesSpoilers = false
    public var spoilerStills = true
    public var spoilerSynopses = true
    public var spoilerTitles = false
    /// The synopsis opens unfolded.
    public var expandsSynopsis = false
    /// The title page's sections below the episodes.
    public var showsReviews = true
    public var showsCast = true
    public var showsInformation = true
    public var showsRelated = true
    /// Where the title can be watched in the viewer's region, from TMDb. Off until turned on, as it asks TMDb for each title.
    public var showsWatchAnywhere = false
    public var sectionOrder: SectionOrder = .reviewsFirst

    // MARK: - Navigation and motion

    public var startTab: StartTab = .home
    /// A card zooms into the title it opens, and the title zooms back into it.
    public var zoomTransitions = true
    public var animationSpeed: AnimationSpeed = .standard
    /// The iPhone's tab bar names its tabs under their icons.
    public var phoneTabTitles = false
    /// The iPhone's tab bar shrinks while a page scrolls down.
    public var minimisesTabBar = true
    /// The Continue Watching bar above the iPhone's tab bar.
    public var showsContinueBar = true

    public init() {}

    /// Copies colour, text and cards from `look`: what a preset sets. The custom colours stay.
    mutating func takeLook(from look: AppearancePreferences) {
        accent = look.accent
        background = look.background
        tintStrength = look.tintStrength
        textSize = look.textSize
        font = look.font
        boldText = look.boldText
        italicText = look.italicText
        fontWidth = look.fontWidth
        letterSpacing = look.letterSpacing
        lineSpacing = look.lineSpacing
        headingFont = look.headingFont
        headingWeight = look.headingWeight
        headingSize = look.headingSize
        uppercaseHeadings = look.uppercaseHeadings
        cardScale = look.cardScale
        cornerScale = look.cornerScale
        spacingScale = look.spacingScale
        phoneGridColumns = look.phoneGridColumns
        showsPosterTitles = look.showsPosterTitles
        captionLines = look.captionLines
        showsCaptionDetails = look.showsCaptionDetails
        outline = look.outline
        artworkTone = look.artworkTone
        progressColour = look.progressColour
        progressThickness = look.progressThickness
        showsTimeLeft = look.showsTimeLeft
    }

    // MARK: - Coding

    /// Written out, rather than synthesised, so that each field falls back to its default on its own, so that the old fixed steps read
    /// into their new values, and so that the JSON coding never goes through `RawRepresentable`'s, which would call `rawValue`, which
    /// encodes again.
    public init(from decoder: Decoder) throws {
        self.init()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func read<Value: Decodable>(_ key: CodingKeys, _ fallback: Value) -> Value {
            (try? container.decode(Value.self, forKey: key)) ?? fallback
        }
        func clamp(_ value: Double, _ range: ClosedRange<Double>, _ fallback: Double) -> Double {
            value.isFinite ? min(max(value, range.lowerBound), range.upperBound) : fallback
        }
        func legacy(_ key: CodingKeys, _ steps: [String: Double]) -> Double? {
            (try? container.decode(String.self, forKey: key)).flatMap { steps[$0] }
        }
        accent = read(.accent, accent)
        customAccent = read(.customAccent, customAccent)
        background = read(.background, background)
        customBackground = read(.customBackground, customBackground)
        tintStrength = clamp(read(.tintStrength, tintStrength), Self.tintStrengthRange, 0.11)

        textSize = read(.textSize, textSize)
        font = read(.font, font)
        boldText = read(.boldText, boldText)
        italicText = read(.italicText, italicText)
        fontWidth = read(.fontWidth, fontWidth)
        letterSpacing = read(.letterSpacing, letterSpacing)
        lineSpacing = read(.lineSpacing, lineSpacing)
        headingFont = read(.headingFont, headingFont)
        headingWeight = read(.headingWeight, headingWeight)
        headingSize = read(.headingSize, headingSize)
        uppercaseHeadings = read(.uppercaseHeadings, uppercaseHeadings)

        // Card size, corners and spacing were fixed steps saved by name; a save from then reads the step's value.
        cardScale = clamp(read(.cardSize, legacy(.legacyCardScale, Self.legacyCardScales) ?? 1), Self.cardScaleRange, 1)
        cornerScale = clamp(read(.cornerScale, legacy(.legacyCorners, Self.legacyCornerScales) ?? 1), Self.cornerScaleRange, 1)
        cornerOverrides = read(.cornerOverrides, cornerOverrides).filter { key, value in
            CornerGroup(rawValue: key) != nil && value.isFinite
        }.mapValues { min(max($0, Self.cornerScaleRange.lowerBound), Self.cornerScaleRange.upperBound) }
        includesCircularButtons = read(.includesCircularButtons, includesCircularButtons)
        spacingScale = clamp(read(.spacing, legacy(.legacyDensity, Self.legacySpacingScales) ?? 1), Self.spacingScaleRange, 1)
        phoneGridColumns = min(max(read(.phoneGridColumns, phoneGridColumns), Self.phoneGridColumnRange.lowerBound),
                               Self.phoneGridColumnRange.upperBound)
        showsPosterTitles = read(.showsPosterTitles, showsPosterTitles)
        captionLines = min(max(read(.captionLines, captionLines), Self.captionLineRange.lowerBound), Self.captionLineRange.upperBound)
        showsCaptionDetails = read(.showsCaptionDetails, showsCaptionDetails)
        // The outline was a switch; off reads as Off.
        let legacyOutline: Outline? = (try? container.decode(Bool.self, forKey: .legacyArtworkOutline)).map { $0 ? .standard : .off }
        outline = read(.outline, legacyOutline ?? outline)
        artworkTone = read(.artworkTone, artworkTone)
        progressColour = read(.progressColour, progressColour)
        progressThickness = read(.progressThickness, progressThickness)
        showsTimeLeft = read(.showsTimeLeft, showsTimeLeft)

        heroScale = clamp(read(.heroScale, heroScale), Self.heroScaleRange, 1)
        let advance = read(.heroAutoAdvance, heroAutoAdvance)
        heroAutoAdvance = Self.heroAutoAdvanceOptions.contains(advance) ? advance : 0
        showsPageDots = read(.showsPageDots, showsPageDots)

        hidesSpoilers = read(.hidesSpoilers, hidesSpoilers)
        spoilerStills = read(.spoilerStills, spoilerStills)
        spoilerSynopses = read(.spoilerSynopses, spoilerSynopses)
        spoilerTitles = read(.spoilerTitles, spoilerTitles)
        expandsSynopsis = read(.expandsSynopsis, expandsSynopsis)
        showsReviews = read(.showsReviews, showsReviews)
        showsCast = read(.showsCast, showsCast)
        showsInformation = read(.showsInformation, showsInformation)
        showsWatchAnywhere = read(.showsWatchAnywhere, showsWatchAnywhere)
        showsRelated = read(.showsRelated, showsRelated)
        sectionOrder = read(.sectionOrder, sectionOrder)

        startTab = read(.startTab, startTab)
        zoomTransitions = read(.zoomTransitions, zoomTransitions)
        animationSpeed = read(.animationSpeed, animationSpeed)
        phoneTabTitles = read(.phoneTabTitles, phoneTabTitles)
        minimisesTabBar = read(.minimisesTabBar, minimisesTabBar)
        showsContinueBar = read(.showsContinueBar, showsContinueBar)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(accent, forKey: .accent)
        try container.encode(customAccent, forKey: .customAccent)
        try container.encode(background, forKey: .background)
        try container.encode(customBackground, forKey: .customBackground)
        try container.encode(tintStrength, forKey: .tintStrength)

        try container.encode(textSize, forKey: .textSize)
        try container.encode(font, forKey: .font)
        try container.encode(boldText, forKey: .boldText)
        try container.encode(italicText, forKey: .italicText)
        try container.encode(fontWidth, forKey: .fontWidth)
        try container.encode(letterSpacing, forKey: .letterSpacing)
        try container.encode(lineSpacing, forKey: .lineSpacing)
        try container.encode(headingFont, forKey: .headingFont)
        try container.encode(headingWeight, forKey: .headingWeight)
        try container.encode(headingSize, forKey: .headingSize)
        try container.encode(uppercaseHeadings, forKey: .uppercaseHeadings)

        try container.encode(cardScale, forKey: .cardSize)
        try container.encode(cornerScale, forKey: .cornerScale)
        try container.encode(cornerOverrides, forKey: .cornerOverrides)
        try container.encode(includesCircularButtons, forKey: .includesCircularButtons)
        try container.encode(spacingScale, forKey: .spacing)
        try container.encode(phoneGridColumns, forKey: .phoneGridColumns)
        try container.encode(showsPosterTitles, forKey: .showsPosterTitles)
        try container.encode(captionLines, forKey: .captionLines)
        try container.encode(showsCaptionDetails, forKey: .showsCaptionDetails)
        try container.encode(outline, forKey: .outline)
        try container.encode(artworkTone, forKey: .artworkTone)
        try container.encode(progressColour, forKey: .progressColour)
        try container.encode(progressThickness, forKey: .progressThickness)
        try container.encode(showsTimeLeft, forKey: .showsTimeLeft)

        try container.encode(heroScale, forKey: .heroScale)
        try container.encode(heroAutoAdvance, forKey: .heroAutoAdvance)
        try container.encode(showsPageDots, forKey: .showsPageDots)

        try container.encode(hidesSpoilers, forKey: .hidesSpoilers)
        try container.encode(spoilerStills, forKey: .spoilerStills)
        try container.encode(spoilerSynopses, forKey: .spoilerSynopses)
        try container.encode(spoilerTitles, forKey: .spoilerTitles)
        try container.encode(expandsSynopsis, forKey: .expandsSynopsis)
        try container.encode(showsReviews, forKey: .showsReviews)
        try container.encode(showsCast, forKey: .showsCast)
        try container.encode(showsInformation, forKey: .showsInformation)
        try container.encode(showsRelated, forKey: .showsRelated)
        try container.encode(showsWatchAnywhere, forKey: .showsWatchAnywhere)
        try container.encode(sectionOrder, forKey: .sectionOrder)

        try container.encode(startTab, forKey: .startTab)
        try container.encode(zoomTransitions, forKey: .zoomTransitions)
        try container.encode(animationSpeed, forKey: .animationSpeed)
        try container.encode(phoneTabTitles, forKey: .phoneTabTitles)
        try container.encode(minimisesTabBar, forKey: .minimisesTabBar)
        try container.encode(showsContinueBar, forKey: .showsContinueBar)
    }

    private enum CodingKeys: String, CodingKey {
        case accent, customAccent, background, customBackground, tintStrength
        case textSize, font, boldText, italicText, fontWidth, letterSpacing, lineSpacing, headingFont, headingWeight, headingSize,
             uppercaseHeadings
        case cornerOverrides, includesCircularButtons
        case cardSize, cornerScale, spacing, phoneGridColumns, showsPosterTitles, captionLines, showsCaptionDetails, outline, artworkTone,
             progressColour, progressThickness, showsTimeLeft
        case heroScale, heroAutoAdvance, showsPageDots
        case hidesSpoilers, spoilerStills, spoilerSynopses, spoilerTitles, expandsSynopsis, showsReviews, showsCast, showsInformation,
             showsRelated, showsWatchAnywhere, sectionOrder
        case startTab, zoomTransitions, animationSpeed, phoneTabTitles, minimisesTabBar, showsContinueBar
        /// The fixed steps saved before the sliders, read once and never written.
        case legacyCardScale = "cardScale", legacyCorners = "corners", legacyDensity = "density", legacyArtworkOutline = "artworkOutline"
    }

    static let legacyCardScales: [String: Double] = ["small": 0.82, "standard": 1, "large": 1.2, "huge": 1.42]
    static let legacyCornerScales: [String: Double] = ["square": 0, "subtle": 0.5, "standard": 1, "round": 1.8]
    static let legacySpacingScales: [String: Double] = ["compact": 0.66, "standard": 1, "roomy": 1.35]

    /// Field by field. Written out so that equality never falls to `RawRepresentable`'s, which would compare the JSON text, and split
    /// into groups so the type checker stays quick.
    public static func == (lhs: AppearancePreferences, rhs: AppearancePreferences) -> Bool {
        let colours: Bool = lhs.accent == rhs.accent && lhs.customAccent == rhs.customAccent && lhs.background == rhs.background
            && lhs.customBackground == rhs.customBackground && lhs.tintStrength == rhs.tintStrength
        let text: Bool = lhs.textSize == rhs.textSize && lhs.font == rhs.font && lhs.boldText == rhs.boldText
            && lhs.italicText == rhs.italicText && lhs.fontWidth == rhs.fontWidth
        let spacing: Bool = lhs.letterSpacing == rhs.letterSpacing && lhs.lineSpacing == rhs.lineSpacing
        let headings: Bool = lhs.headingFont == rhs.headingFont && lhs.headingWeight == rhs.headingWeight
            && lhs.headingSize == rhs.headingSize && lhs.uppercaseHeadings == rhs.uppercaseHeadings
        let sizes: Bool = lhs.cardScale == rhs.cardScale && lhs.cornerScale == rhs.cornerScale && lhs.spacingScale == rhs.spacingScale
            && lhs.phoneGridColumns == rhs.phoneGridColumns
            && lhs.cornerOverrides == rhs.cornerOverrides && lhs.includesCircularButtons == rhs.includesCircularButtons
        let captions: Bool = lhs.showsPosterTitles == rhs.showsPosterTitles && lhs.captionLines == rhs.captionLines
            && lhs.showsCaptionDetails == rhs.showsCaptionDetails
        let artwork: Bool = lhs.outline == rhs.outline && lhs.artworkTone == rhs.artworkTone
        let progress: Bool = lhs.progressColour == rhs.progressColour && lhs.progressThickness == rhs.progressThickness
            && lhs.showsTimeLeft == rhs.showsTimeLeft
        let home: Bool = lhs.heroScale == rhs.heroScale && lhs.heroAutoAdvance == rhs.heroAutoAdvance
            && lhs.showsPageDots == rhs.showsPageDots
        let spoilers: Bool = lhs.hidesSpoilers == rhs.hidesSpoilers && lhs.spoilerStills == rhs.spoilerStills
            && lhs.spoilerSynopses == rhs.spoilerSynopses && lhs.spoilerTitles == rhs.spoilerTitles
        let sections: Bool = lhs.expandsSynopsis == rhs.expandsSynopsis && lhs.showsReviews == rhs.showsReviews
            && lhs.showsCast == rhs.showsCast && lhs.showsInformation == rhs.showsInformation && lhs.showsRelated == rhs.showsRelated
            && lhs.showsWatchAnywhere == rhs.showsWatchAnywhere && lhs.sectionOrder == rhs.sectionOrder
        let navigation: Bool = lhs.startTab == rhs.startTab && lhs.zoomTransitions == rhs.zoomTransitions
            && lhs.animationSpeed == rhs.animationSpeed
        let tabs: Bool = lhs.phoneTabTitles == rhs.phoneTabTitles && lhs.minimisesTabBar == rhs.minimisesTabBar
            && lhs.showsContinueBar == rhs.showsContinueBar
        return colours && text && spacing && headings && sizes && captions && artwork && progress && home && spoilers && sections
            && navigation && tabs
    }

    // MARK: - Reading

    /// The preset this look is, if it is one.
    public var preset: Preset? {
        Preset.allCases.first { $0.applied(to: self) == self }
    }

    /// The accent's colour, the app's own included.
    public var accentRGB: RGB {
        accent == .custom ? customAccent : (accent.rgb ?? Accent.blusion.rgb ?? customAccent)
    }

    /// The page background's colour.
    public var backgroundRGB: RGB {
        switch background {
        case .tinted: accentRGB.scaled(by: tintStrength)
        case .custom: customBackground
        default: background.rgb ?? RGB(red: 0, green: 0, blue: 0)
        }
    }

    public var isDefault: Bool { self == AppearancePreferences() }

    /// The parts of Settings → Appearance, each with a page of its own and its own Restore Defaults.
    public enum Section: String, Sendable, CaseIterable, Identifiable {
        case colour, text, cards, corners, home, titlePages, motion

        public var id: String { rawValue }
    }

    /// This look with one section back at its defaults and the rest as it is.
    public func restoringDefaults(of section: Section) -> AppearancePreferences {
        let defaults = AppearancePreferences()
        var result = self
        switch section {
        case .colour:
            result.accent = defaults.accent
            result.customAccent = defaults.customAccent
            result.background = defaults.background
            result.customBackground = defaults.customBackground
            result.tintStrength = defaults.tintStrength
        case .text:
            result.textSize = defaults.textSize
            result.font = defaults.font
            result.boldText = defaults.boldText
            result.italicText = defaults.italicText
            result.fontWidth = defaults.fontWidth
            result.letterSpacing = defaults.letterSpacing
            result.lineSpacing = defaults.lineSpacing
            result.headingFont = defaults.headingFont
            result.headingWeight = defaults.headingWeight
            result.headingSize = defaults.headingSize
            result.uppercaseHeadings = defaults.uppercaseHeadings
        case .cards:
            result.cardScale = defaults.cardScale
            result.spacingScale = defaults.spacingScale
            result.phoneGridColumns = defaults.phoneGridColumns
            result.showsPosterTitles = defaults.showsPosterTitles
            result.captionLines = defaults.captionLines
            result.showsCaptionDetails = defaults.showsCaptionDetails
            result.outline = defaults.outline
            result.artworkTone = defaults.artworkTone
            result.progressColour = defaults.progressColour
            result.progressThickness = defaults.progressThickness
            result.showsTimeLeft = defaults.showsTimeLeft
        case .corners:
            result.cornerScale = defaults.cornerScale
            result.cornerOverrides = defaults.cornerOverrides
            result.includesCircularButtons = defaults.includesCircularButtons
        case .home:
            result.heroScale = defaults.heroScale
            result.heroAutoAdvance = defaults.heroAutoAdvance
            result.showsPageDots = defaults.showsPageDots
        case .titlePages:
            result.hidesSpoilers = defaults.hidesSpoilers
            result.spoilerStills = defaults.spoilerStills
            result.spoilerSynopses = defaults.spoilerSynopses
            result.spoilerTitles = defaults.spoilerTitles
            result.expandsSynopsis = defaults.expandsSynopsis
            result.showsReviews = defaults.showsReviews
            result.showsCast = defaults.showsCast
            result.showsInformation = defaults.showsInformation
            result.showsRelated = defaults.showsRelated
            result.sectionOrder = defaults.sectionOrder
        case .motion:
            result.startTab = defaults.startTab
            result.zoomTransitions = defaults.zoomTransitions
            result.animationSpeed = defaults.animationSpeed
            result.phoneTabTitles = defaults.phoneTabTitles
            result.minimisesTabBar = defaults.minimisesTabBar
            result.showsContinueBar = defaults.showsContinueBar
        }
        return result
    }

    public func isDefault(_ section: Section) -> Bool { restoringDefaults(of: section) == self }

    /// What a card's height depends on besides its own shape, size and width: a shelf or grid that measured its cards measures again when
    /// this changes.
    public var layoutKey: String {
        let numbers = [cardScale, spacingScale, cornerScale].map { String(format: "%.3f", $0) }
        let text = [textSize.rawValue, font.rawValue, "\(boldText)", "\(italicText)", fontWidth.rawValue, letterSpacing.rawValue,
                    lineSpacing.rawValue, headingFont.rawValue, headingWeight.rawValue, headingSize.rawValue, "\(uppercaseHeadings)"]
        let captions = ["\(showsPosterTitles)", "\(captionLines)", "\(showsCaptionDetails)", "\(phoneGridColumns)"]
        return (numbers + text + captions).joined(separator: "|")
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

/// A look the listener saved under a name on Settings → Appearance, to come back to with one tap.
public struct AppearanceLook: Sendable, Equatable, Codable, Identifiable {
    public var id: UUID
    public var name: String
    public var appearance: AppearancePreferences

    public init(id: UUID = UUID(), name: String, appearance: AppearancePreferences) {
        self.id = id
        self.name = name
        self.appearance = appearance
    }
}

/// The saved looks, oldest first, as one JSON string under `defaultsKey`.
public struct AppearanceLooks: Sendable, Equatable, RawRepresentable {
    public static let defaultsKey = "settings.appearance.looks"
    /// More than enough for anyone, and a bound on what the defaults hold.
    public static let limit = 50

    public var looks: [AppearanceLook]

    public init(looks: [AppearanceLook] = []) {
        self.looks = Array(looks.prefix(Self.limit))
    }

    public init?(rawValue: String) {
        guard let data = rawValue.data(using: .utf8), let looks = try? JSONDecoder().decode([AppearanceLook].self, from: data) else {
            return nil
        }
        self.init(looks: looks)
    }

    public var rawValue: String {
        guard let data = try? JSONEncoder().encode(looks), let text = String(data: data, encoding: .utf8) else { return "[]" }
        return text
    }

    /// Adds `appearance` under `name`, trimmed, or replaces the look already saved under that name. An empty name is "Look N".
    public mutating func save(_ appearance: AppearancePreferences, as name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = trimmed.isEmpty ? unusedLookName() : String(trimmed.prefix(40))
        if let index = looks.firstIndex(where: { $0.name.caseInsensitiveCompare(title) == .orderedSame }) {
            looks[index].appearance = appearance
        } else if looks.count < Self.limit {
            looks.append(AppearanceLook(name: title, appearance: appearance))
        }
    }

    /// "Look N" from the count up, skipping a name still in use: after a deletion the count's own name can belong to a saved look,
    /// which an empty name must not replace.
    private func unusedLookName() -> String {
        var number = looks.count + 1
        while looks.contains(where: { $0.name.caseInsensitiveCompare("Look \(number)") == .orderedSame }) { number += 1 }
        return "Look \(number)"
    }

    public static func reset(in defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: defaultsKey)
    }
}
