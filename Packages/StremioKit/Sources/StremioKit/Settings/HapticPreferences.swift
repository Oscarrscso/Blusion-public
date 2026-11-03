import Foundation

/// The listener's own tuning of the app's haptics, by place. Every haptic in the app belongs to one of the `Place`s below, and each
/// place has its own switch, feel and strength, so the player's taps can be softer than the buttons', or the tab bar silent while
/// shelves still tick. `Haptics` in Features reads it every time a place fires, so a change on the Haptics page is felt on the next
/// tap without a relaunch.
///
/// Every field is optional so that a value left out reads as the place's default, and so that a saved form from an earlier build keeps
/// loading when a knob is added later. Reset writes nothing but nils. A form saved before places existed (one style and strength per
/// feel) is read into the places those feels used to cover; see `init(from:)`.
public struct HapticPreferences: Sendable, Equatable, Codable {
    /// What one haptic feels like. `tick` is Apple's selection feedback, the five impacts are `UIImpactFeedbackGenerator`'s styles,
    /// and the last three are its notification patterns. Only the impacts take a strength.
    ///
    /// The raw values are the impact styles' own names, which is what a form saved before places existed holds.
    public enum Feel: String, Sendable, Codable, CaseIterable, Identifiable {
        case tick, soft, light, medium, rigid, heavy, success, warning, error

        public var id: String { rawValue }

        /// The name the Haptics page shows. Apple's "rigid" is called Sharp, which is what it feels like.
        public var title: String {
            switch self {
            case .tick: "Tick"
            case .soft: "Soft"
            case .light: "Light"
            case .medium: "Medium"
            case .rigid: "Sharp"
            case .heavy: "Heavy"
            case .success: "Success"
            case .warning: "Warning"
            case .error: "Error"
            }
        }

        /// Apple's selection tick and notification patterns play as they are; only an impact can be made harder or softer.
        public var takesStrength: Bool {
            switch self {
            case .soft, .light, .medium, .rigid, .heavy: true
            case .tick, .success, .warning, .error: false
            }
        }

        /// The single taps, lightest first, then the tick.
        public static let taps: [Feel] = [.tick, .soft, .light, .medium, .rigid, .heavy]
        /// The multi-tap patterns.
        public static let patterns: [Feel] = [.success, .warning, .error]
    }

    /// Where a haptic is felt. Every call site in the app names one of these, and the Haptics page has a row for each.
    public enum Place: String, Sendable, Codable, CaseIterable, Identifiable {
        /// Glass buttons and every control that acts on a tap outside the player.
        case buttons
        /// Posters, cards and links that open a title, a person or a collection.
        case titles
        /// The tab bar, Home, the landscape back button and a back swipe.
        case navigation
        /// Pickers, switches, filters and chips: a choice changing.
        case choices
        /// A slider passing a stop, or let go after a change.
        case sliders
        /// The player's buttons and gestures: close, skip, double-tap, hold, swipe, scrub, episode and stream picks.
        case playerControls
        /// Choices inside the player: tabs, subtitle, audio and video options, speed steps and zoom.
        case playerOptions
        /// A shelf card's edge passing the screen's edge as a shelf scrolls.
        case shelves
        /// The Home banner turning to another page.
        case banner
        /// The run of ticks under a review that unfolds or folds.
        case reviews
        /// The saved confirmation.
        case saved

        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .buttons: "Buttons"
            case .titles: "Posters & titles"
            case .navigation: "Tabs & navigation"
            case .choices: "Pickers & switches"
            case .sliders: "Sliders"
            case .playerControls: "Player controls"
            case .playerOptions: "Player options"
            case .shelves: "Poster shelves"
            case .banner: "Home banner"
            case .reviews: "Reviews"
            case .saved: "Saved"
            }
        }

        public var systemImage: String {
            switch self {
            case .buttons: "hand.tap"
            case .titles: "film.stack"
            case .navigation: "dock.rectangle"
            case .choices: "switch.2"
            case .sliders: "slider.horizontal.3"
            case .playerControls: "play.rectangle"
            case .playerOptions: "list.bullet.rectangle"
            case .shelves: "rectangle.3.group"
            case .banner: "photo.stack"
            case .reviews: "text.quote"
            case .saved: "checkmark.circle"
            }
        }

        /// What the place plays before the listener touches it: the feels the app used before places existed.
        public var defaultFeel: Feel {
            switch self {
            case .buttons, .titles, .navigation, .playerControls: .light
            case .choices, .sliders, .playerOptions: .tick
            case .shelves, .reviews: .soft
            case .banner: .rigid
            case .saved: .success
            }
        }

        /// How hard an impact lands here by default, and where the strength slider starts when a tick is changed to an impact.
        public var defaultStrength: Double {
            switch self {
            case .banner: 0.8
            case .reviews: 0.3
            default: 0.5
            }
        }

        /// The feels a place offers. A place that ticks while something moves (a shelf, a slider, a review) fires many in a row, so
        /// it is offered single taps only: a run of notification patterns would blur into a buzz.
        public var feels: [Feel] {
            switch self {
            case .shelves, .sliders, .reviews: Feel.taps
            default: Feel.taps + Feel.patterns
            }
        }
    }

    /// One place's own tuning. A nil reads as the place's default.
    public struct PlaceTuning: Sendable, Equatable, Codable {
        public var isOn: Bool?
        public var feel: Feel?
        public var strength: Double?

        public init(isOn: Bool? = nil, feel: Feel? = nil, strength: Double? = nil) {
            self.isOn = isOn
            self.feel = feel
            self.strength = strength
        }

        var isEmpty: Bool { isOn == nil && feel == nil && strength == nil }
    }

    /// What a value left out reads as, and what Reset leaves behind. Each place's own defaults are on `Place`.
    public enum Default {
        public static let overallStrength = 1.0
        public static let shelfTickSpacing = 12.0
        public static let reviewTickLimit = 6
    }

    /// The ranges the Haptics page offers. A saved value outside one of these is clamped rather than refused, so a hand-edited
    /// preferences file cannot make the phone buzz at 400%.
    public enum Limits {
        /// A place's strength. Its foot is a faint tap rather than silence: a place is silenced with its own switch.
        public static let strength = 0.05...1.0
        /// Scales every impact. Above 100% it lifts the softer places towards full strength; no impact lands past full.
        public static let overallStrength = 0.25...2.0
        public static let shelfTickSpacing = 4.0...60.0
        public static let reviewTickLimit = 1...12
    }

    /// The master switch on the Haptics page.
    public var isEnabled: Bool?
    /// Scales every impact in the app, on top of each place's own strength.
    public var overallStrength: Double?
    /// Each place's own tuning, by `Place.rawValue`. Keyed by string rather than by `Place` so that a saved form naming a place a
    /// later build has dropped still loads. Read and written through the `Place` subscript.
    public var places: [String: PlaceTuning]
    /// How far a shelf travels between ticks, in points. Larger is sparser and steadier.
    public var shelfTickSpacing: Double?
    /// The most ticks one unfold of a review gives.
    public var reviewTickLimit: Int?

    public init(isEnabled: Bool? = nil, overallStrength: Double? = nil, places: [Place: PlaceTuning] = [:],
                shelfTickSpacing: Double? = nil, reviewTickLimit: Int? = nil) {
        self.isEnabled = isEnabled
        self.overallStrength = overallStrength
        self.places = Dictionary(uniqueKeysWithValues: places.filter { !$0.value.isEmpty }.map { ($0.key.rawValue, $0.value) })
        self.shelfTickSpacing = shelfTickSpacing
        self.reviewTickLimit = reviewTickLimit
    }

    /// One place's own tuning. Setting an empty tuning removes the place, so a place put back to its defaults saves as nothing.
    public subscript(place: Place) -> PlaceTuning {
        get { places[place.rawValue] ?? PlaceTuning() }
        set { places[place.rawValue] = newValue.isEmpty ? nil : newValue }
    }

    // MARK: - What the app reads

    public var isOn: Bool { isEnabled ?? true }

    /// Whether a place plays at all, before the master switch.
    public func plays(_ place: Place) -> Bool { self[place].isOn ?? true }

    /// The place's feel. A saved feel the place does not offer reads as its default.
    public func feel(_ place: Place) -> Feel {
        let feel = self[place].feel ?? place.defaultFeel
        return place.feels.contains(feel) ? feel : place.defaultFeel
    }

    /// The place's own strength, before the overall strength scales it.
    public func strength(_ place: Place) -> Double {
        clamp(self[place].strength ?? place.defaultStrength, Limits.strength)
    }

    /// The overall strength, 1 being each place as tuned.
    public var overall: Double { clamp(overallStrength ?? Default.overallStrength, Limits.overallStrength) }

    /// How hard an impact for this place lands: its strength scaled by the overall strength, never past full.
    public func intensity(_ place: Place) -> Double { intensity(place, strength: strength(place)) }

    /// How hard an impact at `strength` lands once the overall strength scales it.
    public func intensity(_ place: Place, strength: Double) -> Double {
        min(clamp(strength, Limits.strength) * overall, 1)
    }

    /// Whether everything the place's page shows is its default, so its Restore button has nothing to do.
    public func isDefault(_ place: Place) -> Bool {
        guard plays(place), feel(place) == place.defaultFeel, strength(place) == place.defaultStrength else { return false }
        switch place {
        case .shelves: return shelfTickSpacingPoints == Default.shelfTickSpacing
        case .reviews: return reviewTicks == Default.reviewTickLimit
        default: return true
        }
    }

    /// Puts one place back to its defaults, with the extra setting its page shows.
    public mutating func restore(_ place: Place) {
        self[place] = PlaceTuning()
        switch place {
        case .shelves: shelfTickSpacing = nil
        case .reviews: reviewTickLimit = nil
        default: break
        }
    }

    /// The distance a shelf must travel between ticks, in points.
    public var shelfTickSpacingPoints: Double { clamp(shelfTickSpacing ?? Default.shelfTickSpacing, Limits.shelfTickSpacing) }

    /// The most ticks one run of `Haptics.lines` gives.
    public var reviewTicks: Int {
        min(max(reviewTickLimit ?? Default.reviewTickLimit, Limits.reviewTickLimit.lowerBound), Limits.reviewTickLimit.upperBound)
    }

    private func clamp(_ value: Double, _ range: ClosedRange<Double>) -> Double {
        min(max(value, range.lowerBound), range.upperBound)
    }

    /// The saved tuning, or the defaults when nothing has been saved yet (a fresh install, or a build from before this existed).
    /// Read synchronously at launch, before any view or gesture can fire a feel.
    public static func saved(in defaults: UserDefaults, key: String = DefaultsSettingsStore.Keys.haptics) -> HapticPreferences {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(HapticPreferences.self, from: $0) } ?? HapticPreferences()
    }

    // MARK: - Saved form

    private enum CodingKeys: String, CodingKey {
        case isEnabled, overallStrength, places, shelfTickSpacing, reviewTickLimit
    }

    /// The fields of a form saved before places existed: one style and strength per feel, and switches for the Apple feels.
    private enum LegacyKeys: String, CodingKey {
        case tap, tapStyle, shelfSnap, shelfSnapStyle, pageChange, pageChangeStyle, textLines, textLinesStyle, selection, success
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled = try? container.decodeIfPresent(Bool.self, forKey: .isEnabled)
        overallStrength = try? container.decodeIfPresent(Double.self, forKey: .overallStrength)
        shelfTickSpacing = try? container.decodeIfPresent(Double.self, forKey: .shelfTickSpacing)
        reviewTickLimit = try? container.decodeIfPresent(Int.self, forKey: .reviewTickLimit)
        if container.contains(.places) {
            places = (try? container.decode([String: PlaceTuning].self, forKey: .places)) ?? [:]
        } else {
            places = Self.legacyPlaces(try decoder.container(keyedBy: LegacyKeys.self))
        }
    }

    /// An earlier build's tuning, spread over the places each of its feels covered, so a listener's tuning survives the move to places.
    /// A strength of 0 used to be how a feel was silenced, so it becomes that place's switch turned off.
    private static func legacyPlaces(_ legacy: KeyedDecodingContainer<LegacyKeys>) -> [String: PlaceTuning] {
        var places: [String: PlaceTuning] = [:]
        func impact(_ strengthKey: LegacyKeys, _ styleKey: LegacyKeys, _ targets: [Place]) {
            let strength = try? legacy.decodeIfPresent(Double.self, forKey: strengthKey)
            let feel = (try? legacy.decodeIfPresent(String.self, forKey: styleKey)).flatMap(Feel.init(rawValue:))
            var tuning = PlaceTuning(feel: feel, strength: strength)
            if let strength, strength <= 0 {
                tuning.isOn = false
                tuning.strength = nil
            }
            guard !tuning.isEmpty else { return }
            for place in targets { places[place.rawValue] = tuning }
        }
        func toggle(_ key: LegacyKeys, _ targets: [Place]) {
            guard (try? legacy.decodeIfPresent(Bool.self, forKey: key)) == false else { return }
            for place in targets { places[place.rawValue] = PlaceTuning(isOn: false) }
        }
        impact(.tap, .tapStyle, [.buttons, .titles, .navigation, .playerControls])
        impact(.shelfSnap, .shelfSnapStyle, [.shelves])
        impact(.pageChange, .pageChangeStyle, [.banner])
        impact(.textLines, .textLinesStyle, [.reviews])
        toggle(.selection, [.choices, .sliders, .playerOptions])
        toggle(.success, [.saved])
        return places
    }
}
