import Foundation

/// How the app looks, as the listener sets it on Settings → Appearance: colour (accent, page background), text (size, font, width,
/// weight, slant, spacing, and a style of its own for headings), cards (size, corners, spacing, columns, captions, outline, artwork tone,
/// progress bars), Home's spotlight, title pages (sections, their order, spoilers) and motion and navigation (start tab, transitions,
/// animation speed, the iPhone's tab bar).
///
/// Saved as one JSON string under `defaultsKey` in the standard defaults, so screens read it with `@AppStorage` and follow a change at
/// once. The root applies it (`appliesAppearance()`); cards and grids read it through `LayoutMetrics`. Every field decodes on its own, so
/// a value added later keeps older saves loading, and the fields that used to be fixed steps (card size, corners, spacing, the outline
/// switch) read the old steps into the new values. The defaults live here and nowhere else: Olive on Graphite, flat buttons, square
/// corners, the tightest gaps and a thin progress line.
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
        /// Colours mixed for the presets: Netflix's red, Plex's amber, Arthouse's olive, Disney+'s royal blue and Prime Video's sky blue.
        case crimson, amber, olive, royal, sky
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
            case .crimson: RGB(red: 0.898, green: 0.035, blue: 0.078)
            case .amber: RGB(red: 0.898, green: 0.627, blue: 0.05)
            case .olive: RGB(red: 0.741, green: 0.733, blue: 0.553)
            case .royal: RGB(red: 0, green: 0.388, blue: 0.898)
            case .sky: RGB(red: 0, green: 0.659, blue: 0.882)
            case .custom: nil
            }
        }
    }

    /// The colour behind every page, and the colour hero artwork fades into.
    public enum Background: String, Sendable, Equatable, Codable, CaseIterable, Identifiable {
        case black, graphite, charcoal, slate, steel, ink, navy, midnight, plum, forest, cocoa
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
            case .graphite: RGB(red: 0.078, green: 0.078, blue: 0.078)
            case .charcoal: RGB(red: 0.11, green: 0.12, blue: 0.13)
            case .slate: RGB(red: 0.055, green: 0.067, blue: 0.085)
            case .steel: RGB(red: 0.078, green: 0.094, blue: 0.11)
            case .ink: RGB(red: 0.059, green: 0.09, blue: 0.118)
            case .navy: RGB(red: 0.102, green: 0.114, blue: 0.161)
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

    /// How wide headings' letters are: the text's own, or one of their own. Only the default font has widths.
    public enum HeadingWidth: String, Sendable, Equatable, Codable, CaseIterable, Identifiable {
        case matchText, compressed, condensed, standard, expanded

        public var id: String { rawValue }

        public var label: String {
            switch self {
            case .matchText: "Same as Text"
            case .standard: "Default"
            default: rawValue.capitalized
            }
        }

        /// The width, or nil to follow the text's.
        public var width: FontWidth? {
            switch self {
            case .matchText: nil
            case .compressed: .compressed
            case .condensed: .condensed
            case .standard: .standard
            case .expanded: .expanded
            }
        }
    }

    /// Extra space between headings' letters: the text's own, or their own.
    public enum HeadingSpacing: String, Sendable, Equatable, Codable, CaseIterable, Identifiable {
        case matchText, tight, standard, wide, wider

        public var id: String { rawValue }

        public var label: String {
            switch self {
            case .matchText: "Same as Text"
            case .standard: "Default"
            default: rawValue.capitalized
            }
        }

        /// The spacing, or nil to follow the text's.
        public var spacing: LetterSpacing? {
            switch self {
            case .matchText: nil
            case .tight: .tight
            case .standard: .standard
            case .wide: .wide
            case .wider: .wider
            }
        }
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
        /// What the group rounds, in the words the listener sees it by.
        public var label: String {
            switch self {
            case .artwork: "Posters, Cards & Photos"
            case .playButton: "Play Button"
            case .actionButtons: "Other Buttons"
            case .filters: "Pickers, Chips & Badges"
            case .reviews: "Review Cards"
            case .panels: "Stream Cards & Panels"
            case .playerControls: "Player Controls"
            case .settingsPreview: "Appearance Preview"
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

    // MARK: - Layout

    /// How the app's pages are laid out: its own pages, or the editorial ones (on iPhone for now): a pill bar in place of the tab bar, a
    /// typeset Search with its results on the accent, and title pages set over their full-screen picture. Only presets set it: Arthouse
    /// the editorial pages, every other preset the standard ones.
    public enum Layout: String, Sendable, Equatable, Codable, CaseIterable, Identifiable {
        case standard, editorial

        public var id: String { rawValue }
        public var label: String { rawValue.capitalized }
    }

    // MARK: - Buttons and headings

    /// How Play is filled: tinted glass in the title's artwork colour (the app's own), solid white with dark text, or the accent, solid.
    public enum PlayStyle: String, Sendable, Equatable, Codable, CaseIterable, Identifiable {
        case artwork, white, accent

        public var id: String { rawValue }
        public var label: String { rawValue.capitalized }
    }

    /// What the buttons are made of: Liquid Glass, flat fills for a look whose app draws no glass (shown as Flat), or no fill at all
    /// (shown as Plain: every button, Play included, is its label alone). The saved values keep their first names.
    public enum ButtonFinish: String, Sendable, Equatable, Codable, CaseIterable, Identifiable {
        case glass, solid, flat

        public var id: String { rawValue }
        public var label: String {
            switch self {
            case .glass: "Glass"
            case .solid: "Flat"
            case .flat: "Plain"
            }
        }
    }

    /// The colour of shelf and section headings.
    public enum HeadingColour: String, Sendable, Equatable, Codable, CaseIterable, Identifiable {
        case primary, secondary, accent

        public var id: String { rawValue }
        public var label: String {
            switch self {
            case .primary: "White"
            case .secondary: "Grey"
            case .accent: "Accent"
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

    /// How long the Mac's hover feedback takes to light and fade, as a share of its own timing. Instant draws it at once.
    public enum HoverSpeed: String, Sendable, Equatable, Codable, CaseIterable, Identifiable {
        case instant, fast, standard, slow

        public var id: String { rawValue }
        public var label: String { self == .standard ? "Default" : rawValue.capitalized }

        /// The duration multiplier; zero is Instant.
        public var factor: Double {
            switch self {
            case .instant: 0
            case .fast: 0.5
            case .standard: 1
            case .slow: 2
            }
        }
    }

    /// The Mac's hover feedback: what lights, grows and lifts under the pointer (see `PointerInteraction.swift`). The defaults are the
    /// look the app always had. The iPhone has no pointer to hover, so nothing here reaches it.
    public struct Hover: Sendable, Equatable, Codable {
        public var isEnabled = true
        /// How much brighter a button or glass control draws under the pointer (`brightnessRange`).
        public var brightness: Double = 0.15
        /// How much a button or glass control grows under the pointer, as a share of its size (`growRange`).
        public var grow: Double = 0.025
        /// The white fill a glass control and a navigation segment take under the pointer (`fillRange`).
        public var glassFill: Double = 0.18
        public var showsRim = true
        /// The rim drawn round a glass control and a navigation segment under the pointer (`rimRange`).
        public var rimStrength: Double = 0.35
        /// How much a card the pointer follows grows under it, as a share of its size (`cardLiftRange`).
        public var cardLift: Double = 0.04
        public var cardShadow = true
        public var showsGlow = true
        /// The glow that follows the pointer across a card (`glowRange`).
        public var glowStrength: Double = 0.04
        public var speed: HoverSpeed = .standard
        /// The system's own hover highlight alongside the app's.
        public var systemHighlight = true

        public static let brightnessRange: ClosedRange<Double> = 0...0.4
        public static let growRange: ClosedRange<Double> = 0...0.1
        public static let fillRange: ClosedRange<Double> = 0...0.5
        public static let rimRange: ClosedRange<Double> = 0...1
        public static let cardLiftRange: ClosedRange<Double> = 0...0.12
        public static let glowRange: ClosedRange<Double> = 0...0.2

        public init() {}

        // The values the modifiers draw with: zero when hover feedback is off.

        public var buttonBrightness: Double { isEnabled ? brightness : 0 }
        public var buttonScale: Double { isEnabled ? 1 + grow : 1 }
        public var glassFillOpacity: Double { isEnabled ? glassFill : 0 }
        public var glassRimOpacity: Double { isEnabled && showsRim ? rimStrength : 0 }
        /// A navigation segment's fill and rim, a little quieter than a glass control's (0.16 and 0.3 by default).
        public var segmentFillOpacity: Double { glassFillOpacity * (0.16 / 0.18) }
        public var segmentRimOpacity: Double { glassRimOpacity * (0.3 / 0.35) }
        /// A card's highlight (0.08 by default; 0.012 for a card with the pointer glow), in step with the glass fill.
        public var cardFillOpacity: Double { glassFillOpacity * (0.08 / 0.18) }
        public var trackedCardFillOpacity: Double { glassFillOpacity * (0.012 / 0.18) }
        public var cardScale: Double { isEnabled ? 1 + cardLift : 1 }
        public var castsShadow: Bool { isEnabled && cardShadow }
        public var glowOpacity: Double { isEnabled && showsGlow ? glowStrength : 0 }
        public var usesSystemHighlight: Bool { isEnabled && systemHighlight }
        /// `duration` at this speed, or nil (no animation) for Instant.
        public func duration(_ duration: Double) -> Double? { speed.factor == 0 ? nil : duration * speed.factor }

        public init(from decoder: Decoder) throws {
            self.init()
            let container = try decoder.container(keyedBy: CodingKeys.self)
            func read<Value: Decodable>(_ key: CodingKeys, _ fallback: Value) -> Value {
                (try? container.decode(Value.self, forKey: key)) ?? fallback
            }
            func clamp(_ key: CodingKeys, _ fallback: Double, _ range: ClosedRange<Double>) -> Double {
                let value = read(key, fallback)
                return value.isFinite ? min(max(value, range.lowerBound), range.upperBound) : fallback
            }
            isEnabled = read(.isEnabled, isEnabled)
            brightness = clamp(.brightness, brightness, Self.brightnessRange)
            grow = clamp(.grow, grow, Self.growRange)
            glassFill = clamp(.glassFill, glassFill, Self.fillRange)
            showsRim = read(.showsRim, showsRim)
            rimStrength = clamp(.rimStrength, rimStrength, Self.rimRange)
            cardLift = clamp(.cardLift, cardLift, Self.cardLiftRange)
            cardShadow = read(.cardShadow, cardShadow)
            showsGlow = read(.showsGlow, showsGlow)
            glowStrength = clamp(.glowStrength, glowStrength, Self.glowRange)
            speed = read(.speed, speed)
            systemHighlight = read(.systemHighlight, systemHighlight)
        }

        private enum CodingKeys: String, CodingKey {
            case isEnabled, brightness, grow, glassFill, showsRim, rimStrength, cardLift, cardShadow, showsGlow, glowStrength, speed,
                 systemHighlight
        }
    }

    // MARK: - Presets

    /// Ready-made looks, each the look of a streaming or film app as closely as these settings draw it: its canvas and accent, how its
    /// rows are titled, its cards' size, corners, gaps and captions, its progress line, its Home spotlight, the order of its title
    /// pages, its transitions and, on iPhone, its tab bar. Arthouse is the app's own editorial look (`Layout`).
    ///
    /// Applying one sets all of that together, with Play's fill, whether the buttons are glass, the headings' colour and the Mac's hover.
    /// The listener's text size, custom colours, start tab, Home's Continue Watching bar, the title page sections shown, spoiler hiding
    /// and animation speed stay their own.
    public enum Preset: String, Sendable, CaseIterable, Identifiable {
        case original, netflix, appleTV, disneyPlus, primeVideo, letterboxd, plex, arthouse

        public var id: String { rawValue }

        public var label: String {
            switch self {
            case .original: "Original"
            case .netflix: "Netflix"
            case .appleTV: "Apple TV"
            case .disneyPlus: "Disney+"
            case .primeVideo: "Prime Video"
            case .letterboxd: "Letterboxd"
            case .plex: "Plex"
            case .arthouse: "Arthouse"
            }
        }

        /// The glass buttons, filters, the player and Settings' rows keep the capsules and circles they are drawn with, whatever a preset
        /// does to the posters, cards and panels. Play keeps its capsule too, unless the app squares it.
        static let controlCorners: [String: Double] = Dictionary(uniqueKeysWithValues: [
            CornerGroup.playButton, .actionButtons, .filters, .playerControls, .settingsRows,
        ].map { ($0.rawValue, 1) })

        /// Play as a rectangle with small rounded corners, as Netflix, Disney+ and Prime Video draw it.
        static let squarePlay = 0.3

        /// `appearance` with this preset's look.
        public func applied(to appearance: AppearancePreferences) -> AppearancePreferences {
            var look = AppearancePreferences()
            if self != .original {
                // The other presets build on black, glass buttons and the standard gaps unless they set their own.
                look.background = .black
                look.buttonFinish = .glass
                look.spacingScale = 1
                look.cornerOverrides = Self.controlCorners
            }
            switch self {
            case .original:
                break
            case .netflix:
                // Red on #141414, kept for progress and the switches. Small bold row titles set close; smaller box art with 4-point
                // corners, no captions, in very tight rows; rectangles throughout: Play, the title page's buttons (circles included),
                // the stream cards, reviews and Settings' rows, with capsule filters as Netflix's chips are; a tall billboard that stays
                // on its title, without dots; a thin red line with no minutes; Cast before Reviews; labelled tabs on a fixed bar.
                look.accent = .crimson
                look.background = .graphite
                look.headingWeight = .bold
                look.headingSize = .small
                look.headingSpacing = .tight
                look.cardScale = 0.9
                look.spacingScale = 0.5
                look.cornerScale = 0.4
                look.cornerOverrides[CornerGroup.playButton.rawValue] = Self.squarePlay
                look.cornerOverrides[CornerGroup.actionButtons.rawValue] = Self.squarePlay
                look.cornerOverrides[CornerGroup.settingsRows.rawValue] = 0.4
                look.includesCircularButtons = true
                look.outline = .off
                look.progressColour = .accent
                look.progressThickness = .thin
                look.showsTimeLeft = false
                look.showsPageDots = false
                look.sectionOrder = .castFirst
                look.phoneTabTitles = true
                look.minimisesTabBar = false
                // A white Play and flat grey buttons, no glass; on the Mac a card grows on hover, without rim or glow.
                look.playStyle = .white
                look.buttonFinish = .solid
                look.hover.grow = 0.05
                look.hover.cardLift = 0.1
                look.hover.showsRim = false
                look.hover.showsGlow = false
                look.hover.speed = .fast
            case .appleTV:
                // Black with white as the accent. Large bold row titles; big cards, two across in grids, with generous rounded
                // corners (reviews, stream cards and Settings' rows alike) and wide gaps, each titled with its genre and year
                // underneath; a tall spotlight turning every 8 seconds with its dots; a white line with the minutes left; Cast before
                // Reviews; labelled tabs on a bar that shrinks.
                look.accent = .white
                look.headingSize = .large
                look.cardScale = 1.25
                look.spacingScale = 1.35
                look.phoneGridColumns = 2
                look.cornerScale = 1.4
                look.cornerOverrides[CornerGroup.settingsRows.rawValue] = 1.4
                look.outline = .off
                look.showsPosterTitles = true
                look.lineSpacing = .relaxed
                look.heroAutoAdvance = 8
                look.sectionOrder = .castFirst
                look.phoneTabTitles = true
                // A white Play on Apple's own glass; on the Mac a card lifts with its shadow and a soft glow.
                look.playStyle = .white
                look.hover.cardLift = 0.06
                look.hover.glowStrength = 0.1
                look.hover.showsRim = false
            case .disneyPlus:
                // Royal blue on Disney+'s navy. Semibold row titles with a little air; rounded tiles with a visible edge, as Disney+
                // outlines its tiles; a squared Play beside round buttons; rounded-rectangle filters; a shorter banner turning every
                // 5 seconds with its dots; a blue line; icon-only tabs on a bar that stays put.
                look.accent = .royal
                look.background = .navy
                look.headingWeight = .semibold
                look.headingSpacing = .wide
                look.cardScale = 1.05
                look.spacingScale = 1.1
                look.cornerScale = 0.8
                look.cornerOverrides[CornerGroup.playButton.rawValue] = Self.squarePlay
                look.cornerOverrides[CornerGroup.filters.rawValue] = 0.5
                look.cornerOverrides[CornerGroup.settingsRows.rawValue] = 0.8
                look.outline = .standard
                look.progressColour = .accent
                look.heroAutoAdvance = 5
                look.phoneTabTitles = false
                look.minimisesTabBar = false
                // A white Play and flat buttons; on the Mac a tile lifts inside a bright white rim, as Disney+ frames the one in focus.
                look.playStyle = .white
                look.buttonFinish = .solid
                look.hover.cardLift = 0.05
                look.hover.rimStrength = 1
                look.hover.showsGlow = false
            case .primeVideo:
                // Sky blue on Prime Video's ink. Small bold row titles set close; 6-point cards in close rows; a squared Play and
                // rounded-rectangle buttons beside round icons; a spotlight turning every 8 seconds with its dots; a thin blue line;
                // labelled tabs on a bar that stays put.
                look.accent = .sky
                look.background = .ink
                look.headingSize = .small
                look.headingSpacing = .tight
                look.cardScale = 0.95
                look.spacingScale = 0.75
                look.cornerScale = 0.6
                look.cornerOverrides[CornerGroup.playButton.rawValue] = Self.squarePlay
                look.cornerOverrides[CornerGroup.actionButtons.rawValue] = 0.5
                look.cornerOverrides[CornerGroup.settingsRows.rawValue] = 0.6
                look.outline = .off
                look.progressColour = .accent
                look.progressThickness = .thin
                look.heroAutoAdvance = 8
                look.phoneTabTitles = true
                look.minimisesTabBar = false
                // A sky-blue Play and flat buttons; on the Mac a card lifts and brightens, without rim or glow.
                look.playStyle = .accent
                look.buttonFinish = .solid
                look.hover.cardLift = 0.07
                look.hover.brightness = 0.2
                look.hover.showsRim = false
                look.hover.showsGlow = false
            case .letterboxd:
                // Green on Letterboxd's steel. Small semibold spaced capitals for section titles and relaxed lines for reading
                // reviews; a dense wall of small posters, four across, with 3-point corners, a faint edge and narrow gaps; small-cornered
                // filters, reviews and Settings' rows; a short backdrop that stays put, without dots; a thin green line with no
                // minutes; the synopsis unfolded and Reviews first; cards open without zooming; icon-only tabs.
                look.accent = .green
                look.background = .steel
                look.headingWeight = .semibold
                look.headingSize = .small
                look.headingSpacing = .wide
                look.uppercaseHeadings = true
                look.lineSpacing = .relaxed
                look.cardScale = 0.75
                look.spacingScale = 0.6
                look.phoneGridColumns = 4
                look.cornerScale = 0.3
                look.cornerOverrides[CornerGroup.filters.rawValue] = 0.3
                look.cornerOverrides[CornerGroup.settingsRows.rawValue] = 0.3
                look.outline = .faint
                look.progressColour = .accent
                look.progressThickness = .thin
                look.showsTimeLeft = false
                look.showsPageDots = false
                look.expandsSynopsis = true
                look.zoomTransitions = false
                look.phoneTabTitles = false
                // Grey section titles; a green Play and flat buttons; on the Mac a poster stays put and takes an outline.
                look.headingColour = .secondary
                look.playStyle = .accent
                look.buttonFinish = .solid
                look.hover.grow = 0
                look.hover.cardLift = 0
                look.hover.cardShadow = false
                look.hover.rimStrength = 0.7
                look.hover.showsGlow = false
                look.hover.speed = .instant
            case .plex:
                // Amber on Plex's charcoal. Semibold row titles; 5-point posters, each titled with its year underneath, as a media
                // library lists them; rounded-rectangle filters and Settings' rows; a shorter spotlight that stays put, without dots;
                // a thick amber line; Cast before Reviews; labelled tabs.
                look.accent = .amber
                look.background = .charcoal
                look.headingWeight = .semibold
                look.cornerScale = 0.5
                look.cornerOverrides[CornerGroup.filters.rawValue] = 0.4
                look.cornerOverrides[CornerGroup.settingsRows.rawValue] = 0.5
                look.outline = .off
                look.showsPosterTitles = true
                look.progressColour = .accent
                look.progressThickness = .thick
                look.showsPageDots = false
                look.sectionOrder = .castFirst
                look.phoneTabTitles = true
                // An amber Play and flat buttons; on the Mac a poster lifts a little inside a rim.
                look.playStyle = .accent
                look.buttonFinish = .solid
                look.hover.cardLift = 0.03
                look.hover.rimStrength = 0.6
                look.hover.showsGlow = false
            case .arthouse:
                // Editorial: condensed text, large medium-weight capitals for headings and titles, black-and-white stills in square
                // frames with their captions, olive as the one colour, and square tags.
                look.accent = .olive
                look.fontWidth = .condensed
                look.headingWeight = .medium
                look.headingSize = .huge
                look.uppercaseHeadings = true
                look.cardScale = 1.2
                look.spacingScale = 1.25
                look.phoneGridColumns = 2
                look.cornerScale = 0
                look.cornerOverrides[CornerGroup.filters.rawValue] = nil
                look.showsPosterTitles = true
                look.captionLines = 2
                look.uppercaseCaptions = true
                look.outline = .off
                look.artworkTone = .mono
                look.progressThickness = .thin
                look.layout = .editorial
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
    public static let tintStrengthRange: ClosedRange<Double> = 0.04...0.3
    /// The column counts a phone's portrait poster grid offers. A wide window fits as many columns as the card size allows instead.
    public static let phoneGridColumnRange: ClosedRange<Int> = 2...6
    public static let captionLineRange: ClosedRange<Int> = 1...2
    /// Seconds between the spotlight's pages turning by themselves; zero leaves them for the listener to swipe.
    public static let heroAutoAdvanceOptions = [0, 5, 8, 12, 20, 30]

    // MARK: - Colour

    public var accent: Accent = .olive
    /// The accent when `accent` is `.custom`. Kept when another accent is chosen, so going back to Custom finds it again.
    public var customAccent = RGB(red: 0.42, green: 0.51, blue: 1)
    public var background: Background = .graphite
    /// The background when `background` is `.custom`. Kept like the custom accent.
    public var customBackground = RGB(red: 0.06, green: 0.06, blue: 0.08)
    /// How much of the accent the Tinted background has, as a share of the accent's own brightness (`tintStrengthRange`).
    public var tintStrength: Double = 0.11
    public var playStyle: PlayStyle = .artwork
    public var buttonFinish: ButtonFinish = .solid

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
    public var headingWidth: HeadingWidth = .matchText
    public var headingSpacing: HeadingSpacing = .matchText
    public var uppercaseHeadings = false
    public var headingColour: HeadingColour = .primary

    // MARK: - Cards

    /// Every card's width in shelves and wide grids, as a share of the layout's own (`cardScaleRange`).
    public var cardScale: Double = 1
    /// The roundness of posters, cards, tiles and stills, as a share of their own radius (`cornerScaleRange`). Zero is square.
    public var cornerScale: Double = 0
    /// Missing entries follow the global corner scale; overrides are absolute, not multiplied by it.
    public var cornerOverrides: [String: Double] = [:]
    public var includesCircularButtons = false

    public func cornerScale(for group: CornerGroup) -> Double {
        cornerOverrides[group.rawValue] ?? cornerScale
    }
    /// The gaps between cards and between shelves, as a share of the layout's own (`spacingScaleRange`).
    public var spacingScale: Double = 0.3
    /// Poster columns of a grid (Library, Discover, See All) on a phone held upright.
    public var phoneGridColumns = 3
    /// Every poster carries its title and a grey line underneath, as landscape and square cards do.
    public var showsPosterTitles = false
    /// Lines a card's title may take under it before it is cut off (`captionLineRange`). Every card of a kind keeps the same height.
    public var captionLines = 1
    /// The grey line under a card's title ("Drama · 2008").
    public var showsCaptionDetails = true
    /// A card's title in capitals.
    public var uppercaseCaptions = false
    public var outline: Outline = .standard
    public var artworkTone: ArtworkTone = .natural
    public var progressColour: ProgressColour = .white
    public var progressThickness: ProgressThickness = .thin
    /// The minutes left beside the progress line on Continue cards.
    public var showsTimeLeft = true

    // MARK: - Layout

    public var layout: Layout = .standard

    // MARK: - Home

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

    // MARK: - Hover

    /// The Mac's hover feedback.
    public var hover = Hover()

    public init() {}

    /// Copies what a preset sets from `look`: colour, Play's fill and the buttons' finish, text but its size, cards, corners, the layout,
    /// Home's spotlight, the title page's layout, zoom transitions, the iPhone's tab bar and the Mac's hover. The custom colours stay.
    mutating func takeLook(from look: AppearancePreferences) {
        accent = look.accent
        background = look.background
        tintStrength = look.tintStrength
        playStyle = look.playStyle
        buttonFinish = look.buttonFinish
        font = look.font
        boldText = look.boldText
        italicText = look.italicText
        fontWidth = look.fontWidth
        letterSpacing = look.letterSpacing
        lineSpacing = look.lineSpacing
        headingFont = look.headingFont
        headingWeight = look.headingWeight
        headingSize = look.headingSize
        headingWidth = look.headingWidth
        headingSpacing = look.headingSpacing
        uppercaseHeadings = look.uppercaseHeadings
        headingColour = look.headingColour
        cardScale = look.cardScale
        cornerScale = look.cornerScale
        cornerOverrides = look.cornerOverrides
        includesCircularButtons = look.includesCircularButtons
        spacingScale = look.spacingScale
        phoneGridColumns = look.phoneGridColumns
        showsPosterTitles = look.showsPosterTitles
        captionLines = look.captionLines
        showsCaptionDetails = look.showsCaptionDetails
        uppercaseCaptions = look.uppercaseCaptions
        outline = look.outline
        artworkTone = look.artworkTone
        progressColour = look.progressColour
        progressThickness = look.progressThickness
        showsTimeLeft = look.showsTimeLeft
        layout = look.layout
        heroAutoAdvance = look.heroAutoAdvance
        showsPageDots = look.showsPageDots
        expandsSynopsis = look.expandsSynopsis
        sectionOrder = look.sectionOrder
        zoomTransitions = look.zoomTransitions
        phoneTabTitles = look.phoneTabTitles
        minimisesTabBar = look.minimisesTabBar
        hover = look.hover
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
        playStyle = read(.playStyle, playStyle)
        buttonFinish = read(.buttonFinish, buttonFinish)

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
        headingWidth = read(.headingWidth, headingWidth)
        headingSpacing = read(.headingSpacing, headingSpacing)
        uppercaseHeadings = read(.uppercaseHeadings, uppercaseHeadings)
        headingColour = read(.headingColour, headingColour)

        // Card size, corners and spacing were fixed steps saved by name; a save from then reads the step's value.
        cardScale = clamp(read(.cardSize, legacy(.legacyCardScale, Self.legacyCardScales) ?? 1), Self.cardScaleRange, 1)
        cornerScale = clamp(read(.cornerScale, legacy(.legacyCorners, Self.legacyCornerScales) ?? cornerScale), Self.cornerScaleRange,
                            cornerScale)
        cornerOverrides = read(.cornerOverrides, cornerOverrides).filter { key, value in
            CornerGroup(rawValue: key) != nil && value.isFinite
        }.mapValues { min(max($0, Self.cornerScaleRange.lowerBound), Self.cornerScaleRange.upperBound) }
        includesCircularButtons = read(.includesCircularButtons, includesCircularButtons)
        spacingScale = clamp(read(.spacing, legacy(.legacyDensity, Self.legacySpacingScales) ?? spacingScale), Self.spacingScaleRange,
                             spacingScale)
        phoneGridColumns = min(max(read(.phoneGridColumns, phoneGridColumns), Self.phoneGridColumnRange.lowerBound),
                               Self.phoneGridColumnRange.upperBound)
        showsPosterTitles = read(.showsPosterTitles, showsPosterTitles)
        captionLines = min(max(read(.captionLines, captionLines), Self.captionLineRange.lowerBound), Self.captionLineRange.upperBound)
        showsCaptionDetails = read(.showsCaptionDetails, showsCaptionDetails)
        uppercaseCaptions = read(.uppercaseCaptions, uppercaseCaptions)
        // The outline was a switch; off reads as Off.
        let legacyOutline: Outline? = (try? container.decode(Bool.self, forKey: .legacyArtworkOutline)).map { $0 ? .standard : .off }
        outline = read(.outline, legacyOutline ?? outline)
        artworkTone = read(.artworkTone, artworkTone)
        progressColour = read(.progressColour, progressColour)
        progressThickness = read(.progressThickness, progressThickness)
        showsTimeLeft = read(.showsTimeLeft, showsTimeLeft)
        layout = read(.layout, layout)

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

        hover = read(.hover, hover)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(accent, forKey: .accent)
        try container.encode(customAccent, forKey: .customAccent)
        try container.encode(background, forKey: .background)
        try container.encode(customBackground, forKey: .customBackground)
        try container.encode(tintStrength, forKey: .tintStrength)
        try container.encode(playStyle, forKey: .playStyle)
        try container.encode(buttonFinish, forKey: .buttonFinish)

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
        try container.encode(headingWidth, forKey: .headingWidth)
        try container.encode(headingSpacing, forKey: .headingSpacing)
        try container.encode(uppercaseHeadings, forKey: .uppercaseHeadings)
        try container.encode(headingColour, forKey: .headingColour)

        try container.encode(cardScale, forKey: .cardSize)
        try container.encode(cornerScale, forKey: .cornerScale)
        try container.encode(cornerOverrides, forKey: .cornerOverrides)
        try container.encode(includesCircularButtons, forKey: .includesCircularButtons)
        try container.encode(spacingScale, forKey: .spacing)
        try container.encode(phoneGridColumns, forKey: .phoneGridColumns)
        try container.encode(showsPosterTitles, forKey: .showsPosterTitles)
        try container.encode(captionLines, forKey: .captionLines)
        try container.encode(showsCaptionDetails, forKey: .showsCaptionDetails)
        try container.encode(uppercaseCaptions, forKey: .uppercaseCaptions)
        try container.encode(outline, forKey: .outline)
        try container.encode(artworkTone, forKey: .artworkTone)
        try container.encode(progressColour, forKey: .progressColour)
        try container.encode(progressThickness, forKey: .progressThickness)
        try container.encode(showsTimeLeft, forKey: .showsTimeLeft)
        try container.encode(layout, forKey: .layout)

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

        try container.encode(hover, forKey: .hover)
    }

    private enum CodingKeys: String, CodingKey {
        case accent, customAccent, background, customBackground, tintStrength, playStyle, buttonFinish
        case textSize, font, boldText, italicText, fontWidth, letterSpacing, lineSpacing, headingFont, headingWeight, headingSize,
             headingWidth, headingSpacing, uppercaseHeadings, headingColour
        case cornerOverrides, includesCircularButtons
        case cardSize, cornerScale, spacing, phoneGridColumns, showsPosterTitles, captionLines, showsCaptionDetails, uppercaseCaptions,
             outline, artworkTone, progressColour, progressThickness, showsTimeLeft
        case layout
        case heroAutoAdvance, showsPageDots
        case hidesSpoilers, spoilerStills, spoilerSynopses, spoilerTitles, expandsSynopsis, showsReviews, showsCast, showsInformation,
             showsRelated, showsWatchAnywhere, sectionOrder
        case startTab, zoomTransitions, animationSpeed, phoneTabTitles, minimisesTabBar, showsContinueBar
        case hover
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
            && lhs.playStyle == rhs.playStyle && lhs.buttonFinish == rhs.buttonFinish
        let text: Bool = lhs.textSize == rhs.textSize && lhs.font == rhs.font && lhs.boldText == rhs.boldText
            && lhs.italicText == rhs.italicText && lhs.fontWidth == rhs.fontWidth
        let spacing: Bool = lhs.letterSpacing == rhs.letterSpacing && lhs.lineSpacing == rhs.lineSpacing
        let headings: Bool = lhs.headingFont == rhs.headingFont && lhs.headingWeight == rhs.headingWeight
            && lhs.headingSize == rhs.headingSize && lhs.uppercaseHeadings == rhs.uppercaseHeadings
        let headingShape: Bool = lhs.headingWidth == rhs.headingWidth && lhs.headingSpacing == rhs.headingSpacing
            && lhs.headingColour == rhs.headingColour
        let sizes: Bool = lhs.cardScale == rhs.cardScale && lhs.cornerScale == rhs.cornerScale && lhs.spacingScale == rhs.spacingScale
            && lhs.phoneGridColumns == rhs.phoneGridColumns
            && lhs.cornerOverrides == rhs.cornerOverrides && lhs.includesCircularButtons == rhs.includesCircularButtons
        let captions: Bool = lhs.showsPosterTitles == rhs.showsPosterTitles && lhs.captionLines == rhs.captionLines
            && lhs.showsCaptionDetails == rhs.showsCaptionDetails && lhs.uppercaseCaptions == rhs.uppercaseCaptions
        let artwork: Bool = lhs.outline == rhs.outline && lhs.artworkTone == rhs.artworkTone
        let progress: Bool = lhs.progressColour == rhs.progressColour && lhs.progressThickness == rhs.progressThickness
            && lhs.showsTimeLeft == rhs.showsTimeLeft
        let home: Bool = lhs.heroAutoAdvance == rhs.heroAutoAdvance && lhs.showsPageDots == rhs.showsPageDots
        let spoilers: Bool = lhs.hidesSpoilers == rhs.hidesSpoilers && lhs.spoilerStills == rhs.spoilerStills
            && lhs.spoilerSynopses == rhs.spoilerSynopses && lhs.spoilerTitles == rhs.spoilerTitles
        let sections: Bool = lhs.expandsSynopsis == rhs.expandsSynopsis && lhs.showsReviews == rhs.showsReviews
            && lhs.showsCast == rhs.showsCast && lhs.showsInformation == rhs.showsInformation && lhs.showsRelated == rhs.showsRelated
            && lhs.showsWatchAnywhere == rhs.showsWatchAnywhere && lhs.sectionOrder == rhs.sectionOrder
        let navigation: Bool = lhs.startTab == rhs.startTab && lhs.zoomTransitions == rhs.zoomTransitions
            && lhs.animationSpeed == rhs.animationSpeed
        let tabs: Bool = lhs.phoneTabTitles == rhs.phoneTabTitles && lhs.minimisesTabBar == rhs.minimisesTabBar
            && lhs.showsContinueBar == rhs.showsContinueBar
        let hover: Bool = lhs.hover == rhs.hover && lhs.layout == rhs.layout
        return colours && text && spacing && headings && headingShape && sizes && captions && artwork && progress && home && spoilers
            && sections && navigation && tabs && hover
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
        case colour, text, cards, corners, home, titlePages, motion, hover

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
            result.playStyle = defaults.playStyle
            result.buttonFinish = defaults.buttonFinish
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
            result.headingWidth = defaults.headingWidth
            result.headingSpacing = defaults.headingSpacing
            result.uppercaseHeadings = defaults.uppercaseHeadings
            result.headingColour = defaults.headingColour
        case .cards:
            result.cardScale = defaults.cardScale
            result.spacingScale = defaults.spacingScale
            result.phoneGridColumns = defaults.phoneGridColumns
            result.showsPosterTitles = defaults.showsPosterTitles
            result.captionLines = defaults.captionLines
            result.showsCaptionDetails = defaults.showsCaptionDetails
            result.uppercaseCaptions = defaults.uppercaseCaptions
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
        case .hover:
            result.hover = defaults.hover
        }
        return result
    }

    public func isDefault(_ section: Section) -> Bool { restoringDefaults(of: section) == self }

    /// What a card's height depends on besides its own shape, size and width: a shelf or grid that measured its cards measures again when
    /// this changes.
    public var layoutKey: String {
        let numbers = [cardScale, spacingScale, cornerScale].map { String(format: "%.3f", $0) }
        let text = [textSize.rawValue, font.rawValue, "\(boldText)", "\(italicText)", fontWidth.rawValue, letterSpacing.rawValue,
                    lineSpacing.rawValue, headingFont.rawValue, headingWeight.rawValue, headingSize.rawValue, headingWidth.rawValue,
                    headingSpacing.rawValue, "\(uppercaseHeadings)"]
        let captions = ["\(showsPosterTitles)", "\(captionLines)", "\(showsCaptionDetails)", "\(uppercaseCaptions)", "\(phoneGridColumns)"]
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

    /// Look by look, as `AppearancePreferences` compares itself, rather than `RawRepresentable`'s comparison of the JSON text, whose key
    /// order can differ between two encodings of the same looks.
    public static func == (lhs: AppearanceLooks, rhs: AppearanceLooks) -> Bool {
        lhs.looks == rhs.looks
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
