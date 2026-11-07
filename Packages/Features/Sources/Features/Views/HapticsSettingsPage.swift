#if canImport(UIKit)
import Foundation
import StremioKit
import SwiftUI

/// Settings → Haptics: every place in the app that gives a haptic, grouped by what the hand is doing, each row showing what it plays now.
/// A row opens that place's own page: its switch, its feel, its strength and a way to try it. The master switch and the overall strength
/// sit above them, so the whole app can be quietened or lifted at once.
///
/// The page holds one draft of the tuning, shared with the place pages, so a change made a level down shows in its row on the way back.
struct HapticsSettingsPage: View {
    typealias Place = HapticPreferences.Place

    let model: SettingsViewModel

    /// What the page and its place pages show. Held here so a drag stays smooth; saved when it ends.
    @State private var draft: HapticPreferences
    /// The overall strength last previewed, so a drag plays once per step rather than once per pixel.
    @State private var lastPreview: Double?

    init(model: SettingsViewModel) {
        self.model = model
        // Read once: coming back from a place page must keep the draft it changed, not the saved copy that may still be catching up.
        _draft = State(initialValue: model.settings.haptics)
    }

    /// One section of the page: the places felt while the hand does one kind of thing.
    private struct PlaceGroup: Sendable {
        let title: String
        let places: [Place]
    }

    /// The places, grouped by what the hand is doing when it feels them. Every place appears once.
    private static let groups: [PlaceGroup] = [
        PlaceGroup(title: "Taps", places: [.buttons, .titles, .navigation]),
        PlaceGroup(title: "Choices", places: [.choices, .sliders]),
        PlaceGroup(title: "Player", places: [.playerControls, .playerOptions, .playerGestures]),
        PlaceGroup(title: "Motion", places: [.shelves, .banner, .reviews]),
        PlaceGroup(title: "Confirmations", places: [.saved]),
    ]

    var body: some View {
        SettingsList {
            Section {
                // Apply before previewing so the master switch takes effect immediately. On is the default, so it saves as nothing.
                Toggle("Haptics", isOn: Binding(get: { draft.isOn }, set: { value in
                    draft.isEnabled = value ? nil : false
                    save()
                    if value { Haptics.preview(.buttons) }
                }))
                .accessibilityIdentifier("settings.haptics.enabled")
                overallRow
                    .disabled(!draft.isOn)
            }
            ForEach(Self.groups, id: \.title) { group in
                Section(group.title) {
                    ForEach(group.places) { place in
                        NavigationLink {
                            HapticPlacePage(place: place, model: model, draft: $draft)
                        } label: {
                            SettingsRow(title: place.title, summary: summary(place), systemImage: place.systemImage)
                        }
                        .accessibilityIdentifier("settings.haptics.place.\(place.rawValue)")
                    }
                }
                .disabled(!draft.isOn)
            }
            Section {
                Button("Restore Defaults") {
                    draft = HapticPreferences()
                    lastPreview = nil
                    save()
                    Haptics.preview(.buttons)
                }
                .disabled(draft == HapticPreferences())
                .accessibilityIdentifier("settings.haptics.reset")
            }
        }
        .scrollIndicators(.visible, axes: .vertical)
        .scrollIndicatorsFlash(onAppear: true)
        .settingsPage("Haptics")
    }

    /// Scales every impact in the app at once. Each step plays a button tap at the new strength.
    private var overallRow: some View {
        let value = draft.overall
        return VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            HStack {
                Text("Strength")
                Spacer()
                Text(HapticFormat.percent(value)).foregroundStyle(.secondary).monospacedDigit()
            }
            CornerSlider(value: Binding(get: { draft.overall }, set: { raw in
                let value = HapticFormat.snapped(raw)
                draft.overallStrength = value
                guard lastPreview != value else { return }
                lastPreview = value
                Haptics.apply(draft)
                // A tick or a pattern has no strength to show, so the preview is the button tap as an impact.
                let feel = draft.feel(.buttons)
                Haptics.preview(.buttons, feel: feel.takesStrength ? feel : .light)
            }), in: HapticPreferences.Limits.overallStrength, step: 0.05, onEditingChanged: { editing in
                if !editing {
                    lastPreview = nil
                    save()
                }
            })
            .accessibilityLabel("Overall strength")
            .accessibilityValue(HapticFormat.percent(value))
            .accessibilityIdentifier("settings.haptics.overall")
        }
    }

    /// What a place plays now, as its row shows it: Off, the feel, and the strength when the feel takes one.
    private func summary(_ place: Place) -> String {
        guard draft.plays(place) else { return "Off" }
        let feel = draft.feel(place)
        guard feel.takesStrength else { return feel.title }
        return "\(feel.title) · \(HapticFormat.percent(draft.strength(place)))"
    }

    private func save() {
        HapticFormat.save(draft, to: model)
    }
}

/// One place's page: its switch, its feel, its strength, anything only it has (a shelf's spacing, a review's ticks), and a way to try it
/// as it fires in the app.
private struct HapticPlacePage: View {
    @Environment(\.layoutMetrics) private var metrics
    let place: HapticPreferences.Place
    let model: SettingsViewModel
    @Binding var draft: HapticPreferences

    /// The strength last previewed, so a drag plays once per step rather than once per pixel.
    @State private var lastPreview: Double?
    /// The sample switch's and slider's own values on the Pickers & switches and Sliders pages.
    @State private var sampleSwitch = false
    @State private var sampleStop = 2.0

    var body: some View {
        SettingsList {
            Section {
                Toggle(place.title, isOn: Binding(get: { draft.plays(place) }, set: { value in
                    // On is the default, so turning a place back on saves nothing for it.
                    draft[place].isOn = value ? nil : false
                    save()
                    if value { Haptics.preview(place) }
                }))
                .accessibilityIdentifier("settings.haptics.\(place.rawValue).enabled")
            }
            Group {
                Section("Feel") {
                    Picker("Feel", selection: Binding(get: { draft.feel(place) }, set: { feel in
                        draft[place].feel = feel == place.defaultFeel ? nil : feel
                        save()
                        Haptics.preview(place)
                    })) {
                        ForEach(place.feels) { feel in
                            Text(feel.title).tag(feel)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                    .accessibilityIdentifier("settings.haptics.\(place.rawValue).feel")
                }
                if draft.feel(place).takesStrength {
                    Section {
                        strengthRow
                    }
                }
                switch place {
                case .shelves:
                    Section { spacingRow }
                case .reviews:
                    Section { tickLimitRow }
                default:
                    EmptyView()
                }
                Section {
                    tryIt
                }
            }
            .disabled(!draft.plays(place))
            Section {
                Button("Restore Defaults") {
                    draft.restore(place)
                    lastPreview = nil
                    save()
                    Haptics.preview(place)
                }
                .disabled(draft.isDefault(place))
                .accessibilityIdentifier("settings.haptics.\(place.rawValue).restore")
            }
        }
        .scrollIndicators(.visible, axes: .vertical)
        .settingsPage(place.title)
    }

    /// The place's strength. Each step plays the feel at the strength under the finger; letting go saves it.
    private var strengthRow: some View {
        let value = draft.strength(place)
        return VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            HStack {
                Text("Strength")
                Spacer()
                Text(HapticFormat.percent(value)).foregroundStyle(.secondary).monospacedDigit()
            }
            CornerSlider(value: Binding(get: { draft.strength(place) }, set: { raw in
                let value = HapticFormat.snapped(raw)
                draft[place].strength = value
                guard lastPreview != value else { return }
                lastPreview = value
                Haptics.preview(place, feel: draft.feel(place), strength: value)
            }), in: HapticPreferences.Limits.strength, step: 0.05, onEditingChanged: { editing in
                if !editing {
                    lastPreview = nil
                    save()
                }
            })
            .accessibilityLabel("Strength")
            .accessibilityValue(HapticFormat.percent(value))
            .accessibilityIdentifier("settings.haptics.\(place.rawValue).strength")
        }
    }

    /// How far a shelf travels before the next card edge can tick.
    private var spacingRow: some View {
        let value = draft.shelfTickSpacingPoints
        return VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            HStack {
                Text("Distance between ticks")
                Spacer()
                Text("\(Int(value.rounded())) pt").foregroundStyle(.secondary).monospacedDigit()
            }
            CornerSlider(value: Binding(get: { draft.shelfTickSpacingPoints }, set: { draft.shelfTickSpacing = $0.rounded() }),
                   in: HapticPreferences.Limits.shelfTickSpacing, step: 2, onEditingChanged: { editing in
                if !editing { save() }
            })
            .accessibilityLabel("Distance between ticks")
            .accessibilityValue("\(Int(value.rounded())) points")
            .accessibilityIdentifier("settings.haptics.shelves.spacing")
        }
    }

    /// The most ticks one review's unfold gives. Each change plays the run it now makes.
    private var tickLimitRow: some View {
        let limits = HapticPreferences.Limits.reviewTickLimit
        return Stepper(value: Binding(get: { draft.reviewTicks }, set: { value in
            draft.reviewTickLimit = value
            save()
            playReview()
        }), in: limits) {
            LabeledContent("Most ticks per review", value: "\(draft.reviewTicks)")
        }
        .accessibilityIdentifier("settings.haptics.reviews.ticks")
    }

    /// A way to feel the place as it fires in the app: the real control where one fits on this page, a named test otherwise.
    @ViewBuilder private var tryIt: some View {
        switch place {
        case .choices:
            Toggle("Test switch", isOn: Binding(get: { sampleSwitch }, set: { value in
                sampleSwitch = value
                Haptics.play(.choices)
            }))
            .accessibilityIdentifier("settings.haptics.choices.test")
        case .sliders:
            LabeledContent("Test slider") {
                CornerSlider(value: Binding(get: { sampleStop }, set: { value in
                    guard value != sampleStop else { return }
                    sampleStop = value
                    Haptics.play(.sliders)
                }), in: 0...4, step: 1)
            }
            .accessibilityIdentifier("settings.haptics.sliders.test")
        case .shelves:
            VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                Text("Swipe to test")
                ShelfScroll(margin: 0, spacing: Theme.Spacing.s, lazy: false) {
                    ForEach(1...10, id: \.self) { number in
                        Text("Poster \(number)")
                            .frame(width: 100, height: 120)
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 12 * metrics.cornerScale(for: .settingsRows)))
                            .reportsShelfEdge(id: number)
                    }
                }
                .accessibilityLabel("Swipe posters to test shelf ticks")
            }
            .accessibilityIdentifier("settings.haptics.shelves.test")
        case .reviews:
            testButton("Test review unfold") { playReview() }
        default:
            testButton(Self.testTitle(place)) {
                Haptics.apply(draft)
                Haptics.preview(place)
            }
        }
    }

    private func testButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: "hand.tap")
        }
        .buttonStyle(.borderless)
        .accessibilityIdentifier("settings.haptics.\(place.rawValue).test")
    }

    /// The named test for a place without a sample control: the action it stands for.
    private static func testTitle(_ place: HapticPreferences.Place) -> String {
        switch place {
        case .buttons: "Test button tap"
        case .titles: "Test poster tap"
        case .navigation: "Test tab change"
        case .playerControls: "Test player control"
        case .playerOptions: "Test option change"
        case .playerGestures: "Test gesture step"
        case .banner: "Test page change"
        case .saved: "Test saved"
        case .choices, .sliders, .shelves, .reviews: "Test"
        }
    }

    /// The whole run a review gives as it unfolds, at the tuned count, over the fold's own animation.
    private func playReview() {
        Haptics.apply(draft)
        Haptics.lines(draft.reviewTicks, over: .seconds(DetailReviews.foldDuration))
    }

    private func save() {
        HapticFormat.save(draft, to: model)
    }
}

/// What the Haptics pages share: how a strength reads, and how a change is saved.
private enum HapticFormat {
    static func percent(_ strength: Double) -> String {
        "\(Int((strength * 100).rounded()))%"
    }

    /// A slider's value to the whole percent, so a step that lands a hair off 50% saves as 50% and reads as the default again.
    static func snapped(_ strength: Double) -> Double {
        (strength * 100).rounded() / 100
    }

    /// Saves what the page shows and applies it, so the next tap obeys the control that has just been let go.
    @MainActor static func save(_ preferences: HapticPreferences, to model: SettingsViewModel) {
        Haptics.apply(preferences)
        Task { await model.updateHaptics { $0 = preferences } }
    }
}
#endif
