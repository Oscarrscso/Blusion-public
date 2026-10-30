import Foundation

/// The listener's own tuning of the app's haptics: impact styles and strengths, notification switches, and timings. `Haptics` in Features reads it every time a feel fires, so a change on the
/// Haptics page is felt on the next tap without a relaunch.
///
/// Every field is optional so that a value left out reads as the default in `Default`, and so that a saved form from an earlier build
/// keeps loading when a knob is added later. `Reset to defaults` writes nothing but nils, which is why an untouched profile stays
/// silent about its values.
public struct HapticPreferences: Sendable, Equatable, Codable {
    public enum ImpactStyle: String, Sendable, Codable, CaseIterable {
        case light, medium, heavy, soft, rigid
    }

    public var tapStyle: ImpactStyle?
    public var shelfSnapStyle: ImpactStyle?
    public var pageChangeStyle: ImpactStyle?
    public var textLinesStyle: ImpactStyle?
    public var holdStyle: ImpactStyle?
    public var success: Bool?

    /// What a value left out reads as, and what `Reset to defaults` leaves behind.
    public enum Default {
        public static let tapStyle: ImpactStyle = .light
        public static let shelfSnapStyle: ImpactStyle = .soft
        public static let pageChangeStyle: ImpactStyle = .rigid
        public static let textLinesStyle: ImpactStyle = .soft
        public static let holdStyle: ImpactStyle = .medium
        public static let tap = 0.5
        public static let shelfSnap = 0.5
        public static let pageChange = 0.8
        public static let textLines = 0.3
        public static let hold = 1.0
        public static let shelfTickSpacing = 12.0
        public static let reviewTickLimit = 6
        public static let holdDuration = 1.0
    }

    /// The ranges the Haptics page offers. A saved value outside one of these is clamped rather than refused, so a hand-edited
    /// preferences file cannot make the phone buzz at 400%.
    public enum Limits {
        public static let strength = 0.0...1.0
        public static let shelfTickSpacing = 6.0...40.0
        public static let reviewTickLimit = 2...6
        public static let holdDuration = 0.5...1.5
    }

    /// The master switch on the Haptics page.
    public var isEnabled: Bool?
    /// How hard a control's tap lands; `0` is silent and the slider's foot.
    public var tap: Double?
    /// The tick a shelf card's edge crossing gives.
    public var shelfSnap: Double?
    /// The harder click of a whole screenful changing.
    public var pageChange: Double?
    /// The strength of each tick in a run under text that unfolds.
    public var textLines: Double?
    /// How hard the press that becomes a hold lands.
    public var hold: Double?

    /// Apple's selection feedback takes no strength, so this feel is a switch.
    public var selection: Bool?
    /// Apple's error notification takes no strength either: a held poster that will not play.
    public var failure: Bool?

    /// How far a shelf travels between ticks, in points. Larger is sparser and steadier.
    public var shelfTickSpacing: Double?
    /// The most ticks one unfold of a review gives.
    public var reviewTickLimit: Int?
    /// How long a press must last to become a hold, in seconds.
    public var holdDuration: Double?

    public init(isEnabled: Bool? = nil, tap: Double? = nil, shelfSnap: Double? = nil, pageChange: Double? = nil, textLines: Double? = nil,
                hold: Double? = nil, selection: Bool? = nil, failure: Bool? = nil, shelfTickSpacing: Double? = nil,
                reviewTickLimit: Int? = nil, holdDuration: Double? = nil) {
        self.isEnabled = isEnabled
        self.tap = tap
        self.shelfSnap = shelfSnap
        self.pageChange = pageChange
        self.textLines = textLines
        self.hold = hold
        self.selection = selection
        self.failure = failure
        self.shelfTickSpacing = shelfTickSpacing
        self.reviewTickLimit = reviewTickLimit
        self.holdDuration = holdDuration
    }

    // MARK: - What the app reads

    public var isOn: Bool { isEnabled ?? true }
    public var selectionOn: Bool { selection ?? true }
    public var failureOn: Bool { failure ?? true }
    public var successOn: Bool { success ?? true }

    public var tapStrength: Double { strength(tap, Default.tap) }
    public var shelfSnapStrength: Double { strength(shelfSnap, Default.shelfSnap) }
    public var pageChangeStrength: Double { strength(pageChange, Default.pageChange) }
    public var textLinesStrength: Double { strength(textLines, Default.textLines) }
    public var holdStrength: Double { strength(hold, Default.hold) }

    /// The distance a shelf must travel between ticks, in points.
    public var shelfTickSpacingPoints: Double {
        min(max(shelfTickSpacing ?? Default.shelfTickSpacing, Limits.shelfTickSpacing.lowerBound), Limits.shelfTickSpacing.upperBound)
    }

    /// The most ticks one run of `Haptics.lines` gives.
    public var reviewTicks: Int {
        min(max(reviewTickLimit ?? Default.reviewTickLimit, Limits.reviewTickLimit.lowerBound), Limits.reviewTickLimit.upperBound)
    }

    /// How long a press must last to become a hold, in seconds.
    public var holdLength: Double {
        min(max(holdDuration ?? Default.holdDuration, Limits.holdDuration.lowerBound), Limits.holdDuration.upperBound)
    }

    private func strength(_ value: Double?, _ fallback: Double) -> Double {
        min(max(value ?? fallback, Limits.strength.lowerBound), Limits.strength.upperBound)
    }

    /// The saved tuning, or the defaults when nothing has been saved yet (a fresh install, or a build from before this existed).
    /// Read synchronously at launch, before any view or gesture can fire a feel.
    public static func saved(in defaults: UserDefaults, key: String = DefaultsSettingsStore.Keys.haptics) -> HapticPreferences {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(HapticPreferences.self, from: $0) } ?? HapticPreferences()
    }
}
