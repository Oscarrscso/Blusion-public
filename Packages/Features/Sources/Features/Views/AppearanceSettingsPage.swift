#if canImport(UIKit)
import SwiftUI
import StremioKit
import UIKit

/// The choices Appearance lays out as a segmented control: every case, by its label.
private protocol AppearanceOption: CaseIterable, Identifiable, Hashable {
    var label: String { get }
}

extension AppearancePreferences.CardScale: AppearanceOption {}
extension AppearancePreferences.Corners: AppearanceOption {}
extension AppearancePreferences.Density: AppearanceOption {}

/// Settings → Appearance: presets, colour, text, cards, title pages and navigation, with a way to copy a look to another device, on
/// iPhone and Mac. Every choice is saved as it is made and the whole app
/// follows at once (see `AppearancePreferences`). The poster switches below the cards are the playback settings' own.
struct AppearanceSettingsPage: View {
    let model: SettingsViewModel
    @AppStorage(AppearancePreferences.defaultsKey) private var appearance = AppearancePreferences()
    @State private var confirmsReset = false

    /// The choices only a phone has: a phone held upright has a fixed number of poster columns (a wide window fits as many as the card
    /// size allows), and only the iPhone has a tab bar with labels to show, a bar that shrinks and the Continue Watching bar above it.
    private var isPhone: Bool {
        #if targetEnvironment(macCatalyst)
        return false
        #else
        return UIDevice.current.userInterfaceIdiom == .phone
        #endif
    }

    /// The preset the look is now, or nil for a look of the listener's own. Choosing one applies it.
    private var preset: Binding<AppearancePreferences.Preset?> {
        Binding(get: { appearance.preset }, set: { chosen in
            guard let chosen, chosen != appearance.preset else { return }
            Haptics.play(.choices)
            appearance = chosen.applied(to: appearance)
        })
    }

    /// Takes a look copied from this page, on this device or another. Anything else on the clipboard is left alone.
    private func paste(_ strings: [String]) {
        guard let pasted = strings.lazy.compactMap({ AppearancePreferences(rawValue: $0.trimmingCharacters(in: .whitespacesAndNewlines)) })
            .first else { return }
        Haptics.play(.buttons)
        appearance = pasted
    }

    /// One preference, which ticks when it changes, as the app's other pickers and switches do.
    private func choice<Value: Equatable>(_ keyPath: WritableKeyPath<AppearancePreferences, Value>) -> Binding<Value> {
        Binding(get: { appearance[keyPath: keyPath] }, set: { value in
            guard value != appearance[keyPath: keyPath] else { return }
            Haptics.play(.choices)
            appearance[keyPath: keyPath] = value
        })
    }

    private var customAccent: Binding<Color> {
        Binding(get: { appearance.customAccent.colour }, set: { appearance.customAccent = AppearancePreferences.RGB($0) })
    }

    var body: some View {
        List {
            Section {
                Picker("Preset", selection: preset) {
                    if appearance.preset == nil { Text("Custom").tag(AppearancePreferences.Preset?.none) }
                    ForEach(AppearancePreferences.Preset.allCases) { Text($0.label).tag(Optional($0)) }
                }
                .accessibilityIdentifier("settings.appearance.preset")
            }
            Section("Colour") {
                Picker("Accent", selection: choice(\.accent)) {
                    ForEach(AppearancePreferences.Accent.allCases) { accent in
                        Label { Text(accent.label) } icon: { (accent.rgb ?? appearance.customAccent).swatch }
                            .tag(accent)
                    }
                }
                .accessibilityIdentifier("settings.appearance.accent")
                if appearance.accent == .custom {
                    ColorPicker("Custom accent", selection: customAccent, supportsOpacity: false)
                        .accessibilityIdentifier("settings.appearance.customAccent")
                }
                Picker("Background", selection: choice(\.background)) {
                    ForEach(AppearancePreferences.Background.allCases) { background in
                        Label { Text(background.label) } icon: { appearance.backgroundSwatch(background).swatch }
                            .tag(background)
                    }
                }
                .accessibilityIdentifier("settings.appearance.background")
            }
            Section("Text") {
                Picker("Text size", selection: choice(\.textSize)) {
                    ForEach(AppearancePreferences.TextSize.allCases) { Text($0.label).tag($0) }
                }
                .accessibilityIdentifier("settings.appearance.textSize")
                Picker("Font", selection: choice(\.font)) {
                    ForEach(AppearancePreferences.FontStyle.allCases) { Text($0.label).tag($0) }
                }
                .accessibilityIdentifier("settings.appearance.font")
                Toggle("Bold text", isOn: choice(\.boldText))
                    .accessibilityIdentifier("settings.appearance.bold")
            }
            Section("Cards") {
                segmented("Card size", \.cardScale, id: "settings.appearance.cardSize")
                segmented("Corners", \.corners, id: "settings.appearance.corners")
                segmented("Spacing", \.density, id: "settings.appearance.spacing")
                if isPhone {
                    VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                        Text("Columns")
                        Picker("Columns", selection: choice(\.phoneGridColumns)) {
                            ForEach(Array(AppearancePreferences.phoneGridColumnRange), id: \.self) { Text("\($0)").tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .accessibilityIdentifier("settings.appearance.columns")
                    }
                }
                Toggle("Titles under posters", isOn: choice(\.showsPosterTitles))
                    .accessibilityIdentifier("settings.appearance.posterTitles")
                Toggle("Artwork outline", isOn: choice(\.artworkOutline))
                    .accessibilityIdentifier("settings.appearance.outline")
                Toggle("Hero artwork on posters", isOn: Binding(get: { model.settings.usesHeroPosters }, set: { value in
                    Haptics.play(.choices)
                    Task { await model.setUsesHeroPosters(value) }
                }))
                .accessibilityIdentifier("settings.heroPosters")
                Toggle("Ratings on posters", isOn: Binding(get: { model.settings.showsPosterRatings }, set: { value in
                    Haptics.play(.choices)
                    Task { await model.setShowsPosterRatings(value) }
                }))
                .accessibilityIdentifier("settings.posterRatings")
                Toggle("Coloured rating logos", isOn: Binding(get: { model.settings.showsColouredRatingLogos }, set: { value in
                    Haptics.play(.choices)
                    Task { await model.setShowsColouredRatingLogos(value) }
                }))
                .accessibilityIdentifier("settings.colouredRatingLogos")
            }
            Section("Title pages") {
                Toggle("Hide spoilers", isOn: choice(\.hidesSpoilers))
                    .accessibilityIdentifier("settings.appearance.spoilers")
                Toggle("Reviews", isOn: choice(\.showsReviews))
                    .accessibilityIdentifier("settings.appearance.reviews")
                Toggle("Cast & Crew", isOn: choice(\.showsCast))
                    .accessibilityIdentifier("settings.appearance.cast")
                Toggle("Information", isOn: choice(\.showsInformation))
                    .accessibilityIdentifier("settings.appearance.information")
                Toggle("More Like This", isOn: choice(\.showsRelated))
                    .accessibilityIdentifier("settings.appearance.related")
            }
            Section("Navigation") {
                Picker("Open on", selection: choice(\.startTab)) {
                    ForEach(AppearancePreferences.StartTab.allCases) { Text($0.label).tag($0) }
                }
                .accessibilityIdentifier("settings.appearance.startTab")
                Toggle("Zoom transitions", isOn: choice(\.zoomTransitions))
                    .accessibilityIdentifier("settings.appearance.zoom")
                if isPhone {
                    Toggle("Tab labels", isOn: choice(\.phoneTabTitles))
                        .accessibilityIdentifier("settings.appearance.tabLabels")
                    Toggle("Shrink tab bar on scroll", isOn: choice(\.minimisesTabBar))
                        .accessibilityIdentifier("settings.appearance.shrinkTabBar")
                    Toggle("Continue Watching bar", isOn: choice(\.showsContinueBar))
                        .accessibilityIdentifier("settings.appearance.continueBar")
                }
            }
            Section {
                Button("Copy Appearance") {
                    Haptics.play(.buttons)
                    UIPasteboard.general.string = appearance.rawValue
                }
                .accessibilityIdentifier("settings.appearance.copy")
                PasteButton(payloadType: String.self) { strings in paste(strings) }
                    .accessibilityIdentifier("settings.appearance.paste")
            }
            Section {
                Button("Reset Appearance", role: .destructive) { confirmsReset = true }
                    .disabled(appearance.isDefault)
                    .accessibilityIdentifier("settings.appearance.reset")
            }
        }
        .scrollIndicators(.visible, axes: .vertical)
        .scrollIndicatorsFlash(onAppear: true)
        .settingsPage("Appearance")
        .confirmationDialog("Reset Appearance?", isPresented: $confirmsReset, titleVisibility: .visible) {
            Button("Reset Appearance", role: .destructive) {
                Haptics.play(.buttons)
                appearance = AppearancePreferences()
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    /// A titled segmented control over every case of a choice.
    private func segmented<Option: AppearanceOption>(_ title: String, _ keyPath: WritableKeyPath<AppearancePreferences, Option>,
                                                     id: String) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            Text(title)
            Picker(title, selection: choice(keyPath)) {
                ForEach(Array(Option.allCases)) { option in Text(option.label).tag(option) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityIdentifier(id)
        }
    }
}
#endif
