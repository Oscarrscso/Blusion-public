#if canImport(UIKit)
import SwiftUI
import StremioKit
import UIKit

/// The choices Appearance lays out as a menu or a segmented control: every case, by its label.
private protocol AppearanceOption: CaseIterable, Identifiable, Hashable where AllCases: RandomAccessCollection {
    var label: String { get }
}

extension AppearancePreferences.Background: AppearanceOption {}
extension AppearancePreferences.TextSize: AppearanceOption {}
extension AppearancePreferences.FontStyle: AppearanceOption {}
extension AppearancePreferences.FontWidth: AppearanceOption {}
extension AppearancePreferences.LetterSpacing: AppearanceOption {}
extension AppearancePreferences.LineSpacing: AppearanceOption {}
extension AppearancePreferences.HeadingFont: AppearanceOption {}
extension AppearancePreferences.HeadingWeight: AppearanceOption {}
extension AppearancePreferences.HeadingSize: AppearanceOption {}
extension AppearancePreferences.Outline: AppearanceOption {}
extension AppearancePreferences.ArtworkTone: AppearanceOption {}
extension AppearancePreferences.ProgressColour: AppearanceOption {}
extension AppearancePreferences.ProgressThickness: AppearanceOption {}
extension AppearancePreferences.SectionOrder: AppearanceOption {}
extension AppearancePreferences.StartTab: AppearanceOption {}
extension AppearancePreferences.AnimationSpeed: AppearanceOption {}

/// The choices only a phone has: a phone held upright has a fixed number of poster columns (a wide window fits as many as the card size
/// allows), and only the iPhone has a tab bar with labels to show, a bar that shrinks and the Continue Watching bar above it.
@MainActor
private var isPhone: Bool {
    #if targetEnvironment(macCatalyst)
    return false
    #else
    return UIDevice.current.userInterfaceIdiom == .phone
    #endif
}

private func percent(_ value: Double) -> String { "\(Int((value * 100).rounded()))%" }

/// Settings → Appearance, on iPhone and Mac: a live preview of the look, the presets, one row per part of the look (Colour, Text, Cards,
/// Home, Title Pages, Motion & Navigation) that opens its page and reads what it is set to, the listener's own saved looks, a way to copy a
/// look to another device, and Reset. Every choice is saved as it is made and the whole app follows at once (see `AppearancePreferences`).
/// No page explains itself in words: each opens on the preview, which shows what its choices do.
struct AppearanceSettingsPage: View {
    let model: SettingsViewModel
    @AppStorage(AppearancePreferences.defaultsKey) private var appearance = AppearancePreferences()
    @AppStorage(AppearanceLooks.defaultsKey) private var looks = AppearanceLooks()
    @State private var confirmsReset = false
    @State private var namesLook = false
    @State private var lookName = ""

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

    var body: some View {
        SettingsList {
            Section {
                AppearancePreview(appearance: appearance)
            }
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
            Section {
                Picker("Preset", selection: preset) {
                    if appearance.preset == nil { Text("Custom").tag(AppearancePreferences.Preset?.none) }
                    ForEach(AppearancePreferences.Preset.allCases) { Text($0.label).tag(Optional($0)) }
                }
                .accessibilityIdentifier("settings.appearance.preset")
            }
            Section {
                NavigationLink { AppearanceColourPage() } label: {
                    SettingsRow(title: "Colour", summary: appearance.colourSummary, systemImage: "paintpalette")
                }
                .accessibilityIdentifier("settings.appearance.colour")
                NavigationLink { AppearanceTextPage() } label: {
                    SettingsRow(title: "Text", summary: appearance.textSummary, systemImage: "textformat")
                }
                .accessibilityIdentifier("settings.appearance.text")
                NavigationLink { AppearanceCardsPage(model: model) } label: {
                    SettingsRow(title: "Cards", summary: appearance.cardsSummary, systemImage: "rectangle.portrait.on.rectangle.portrait")
                }
                .accessibilityIdentifier("settings.appearance.cards")
                NavigationLink { AppearanceCornersPage() } label: {
                    SettingsRow(title: "Corners", summary: "Global \(percent(appearance.cornerScale))", systemImage: "square.on.circle")
                }
                .accessibilityIdentifier("settings.appearance.corners")
                NavigationLink { AppearanceHomePage() } label: {
                    SettingsRow(title: "Home", summary: appearance.homeSummary, systemImage: "play.house")
                }
                .accessibilityIdentifier("settings.appearance.home")
                NavigationLink { AppearanceTitlePagesPage() } label: {
                    SettingsRow(title: "Title Pages", summary: appearance.titlePagesSummary, systemImage: "film")
                }
                .accessibilityIdentifier("settings.appearance.titlePages")
                NavigationLink { AppearanceMotionPage() } label: {
                    SettingsRow(title: "Motion & Navigation", summary: appearance.motionSummary, systemImage: "wind")
                }
                .accessibilityIdentifier("settings.appearance.motion")
            }
            Section("My Looks") {
                ForEach(looks.looks) { look in lookRow(look) }
                Button("Save Current Look…") {
                    lookName = ""
                    namesLook = true
                }
                .accessibilityIdentifier("settings.appearance.saveLook")
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
        .alert("Save Look", isPresented: $namesLook) {
            TextField("Name", text: $lookName)
            Button("Save") {
                Haptics.play(.buttons)
                looks.save(appearance, as: lookName)
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    /// A saved look: a tap puts it on, a tick shows it is on, and a swipe or the context menu deletes it or saves the current look over it.
    private func lookRow(_ look: AppearanceLook) -> some View {
        let isOn = look.appearance == appearance
        return Button {
            guard !isOn else { return }
            Haptics.play(.choices)
            appearance = look.appearance
        } label: {
            HStack {
                Label { Text(look.name).foregroundStyle(.primary) } icon: { look.appearance.accentRGB.swatch }
                Spacer()
                if isOn {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.tint)
                        .accessibilityHidden(true)
                }
            }
        }
        .accessibilityAddTraits(isOn ? .isSelected : [])
        .swipeActions {
            Button("Delete", role: .destructive) { delete(look) }
        }
        .contextMenu {
            Button("Save Current Look Here", systemImage: "square.and.arrow.down") {
                Haptics.play(.buttons)
                looks.save(appearance, as: look.name)
            }
            .disabled(isOn)
            Button("Delete", systemImage: "trash", role: .destructive) { delete(look) }
        }
    }

    private func delete(_ look: AppearanceLook) {
        Haptics.play(.buttons)
        looks.looks.removeAll { $0.id == look.id }
    }
}

// MARK: - A part of Appearance

/// One part of Appearance on a page of its own: the preview on top, showing the look as it is being set, then the part's choices, then
/// Restore Defaults for this part alone.
private struct AppearanceSectionPage<Content: View>: View {
    let title: String
    let section: AppearancePreferences.Section
    let preview: AppearancePreview.Kind
    @ViewBuilder let content: (AppearanceControls) -> Content
    @AppStorage(AppearancePreferences.defaultsKey) private var appearance = AppearancePreferences()
    /// A slider's value while it is dragged, shown in the preview and saved when the drag ends, so the whole app is not laid out again on
    /// every step of a drag.
    @State private var draft: AppearancePreferences?
    @State private var isSliding = false

    var body: some View {
        let controls = AppearanceControls(appearance: $appearance, draft: $draft, isSliding: $isSliding)
        SettingsList {
            Section {
                AppearancePreview(appearance: draft ?? appearance, kind: preview)
            }
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
            content(controls)
            Section {
                Button("Restore Defaults") {
                    Haptics.play(.buttons)
                    appearance = appearance.restoringDefaults(of: section)
                }
                .disabled(appearance.isDefault(section))
                .accessibilityIdentifier("settings.appearance.\(section.rawValue).restore")
            }
        }
        .scrollIndicators(.visible, axes: .vertical)
        .settingsPage(title)
    }
}

/// The controls every part of Appearance builds its choices from. Pickers and switches save at once and tick (Pickers & switches);
/// sliders show their value as they move and save, with the Sliders tick, when they are let go.
@MainActor
private struct AppearanceControls {
    let appearance: Binding<AppearancePreferences>
    let draft: Binding<AppearancePreferences?>
    let isSliding: Binding<Bool>

    /// The look shown: a slider's value while it is dragged, otherwise what is saved.
    var current: AppearancePreferences { draft.wrappedValue ?? appearance.wrappedValue }

    func choice<Value: Equatable>(_ keyPath: WritableKeyPath<AppearancePreferences, Value>) -> Binding<Value> {
        let appearance = appearance
        return Binding(get: { appearance.wrappedValue[keyPath: keyPath] }, set: { value in
            guard value != appearance.wrappedValue[keyPath: keyPath] else { return }
            Haptics.play(.choices)
            appearance.wrappedValue[keyPath: keyPath] = value
        })
    }

    func colour(_ keyPath: WritableKeyPath<AppearancePreferences, AppearancePreferences.RGB>) -> Binding<Color> {
        let appearance = appearance
        return Binding(get: { appearance.wrappedValue[keyPath: keyPath].colour }, set: { colour in
            appearance.wrappedValue[keyPath: keyPath] = AppearancePreferences.RGB(colour)
        })
    }

    func toggle(_ title: String, _ keyPath: WritableKeyPath<AppearancePreferences, Bool>, id: String) -> some View {
        Toggle(title, isOn: choice(keyPath))
            .accessibilityIdentifier("settings.appearance.\(id)")
    }

    /// A menu of every case.
    func menu<Option: AppearanceOption>(_ title: String, _ keyPath: WritableKeyPath<AppearancePreferences, Option>,
                                        id: String) -> some View {
        Picker(title, selection: choice(keyPath)) {
            ForEach(Option.allCases) { option in Text(option.label).tag(option) }
        }
        .accessibilityIdentifier("settings.appearance.\(id)")
    }

    /// A titled segmented control over every case.
    func segmented<Option: AppearanceOption>(_ title: String, _ keyPath: WritableKeyPath<AppearancePreferences, Option>,
                                             id: String) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            Text(title)
            Picker(title, selection: choice(keyPath)) {
                ForEach(Option.allCases) { option in Text(option.label).tag(option) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
        .accessibilityIdentifier("settings.appearance.\(id)")
    }

    /// A titled segmented control over numbers.
    func numbers(_ title: String, _ keyPath: WritableKeyPath<AppearancePreferences, Int>, in values: ClosedRange<Int>,
                 id: String) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            Text(title)
            Picker(title, selection: choice(keyPath)) {
                ForEach(Array(values), id: \.self) { Text("\($0)").tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
        .accessibilityIdentifier("settings.appearance.\(id)")
    }

    /// A titled slider with its value as a percentage beside the title and a small and a large symbol at its ends. A drag shows in the
    /// preview as it goes and is saved when it ends; VoiceOver's and the keyboard's steps, which come without a drag, are saved at once.
    func slider(_ title: String, _ keyPath: WritableKeyPath<AppearancePreferences, Double>, in range: ClosedRange<Double>,
                step: Double, low: String, high: String, id: String) -> some View {
        slider(title, read: { $0[keyPath: keyPath] }, write: { $0[keyPath: keyPath] = $1 },
               in: range, step: step, low: low, high: high, id: id)
    }

    func slider(_ title: String, read: @escaping (AppearancePreferences) -> Double,
                write: @escaping (inout AppearancePreferences, Double) -> Void, in range: ClosedRange<Double>,
                step: Double, low: String, high: String, id: String) -> some View {
        let appearance = appearance
        let draft = draft
        let isSliding = isSliding
        let value = Binding<Double>(get: { read(draft.wrappedValue ?? appearance.wrappedValue) }, set: { newValue in
            if isSliding.wrappedValue {
                var look = draft.wrappedValue ?? appearance.wrappedValue
                write(&look, newValue)
                draft.wrappedValue = look
            } else if newValue != read(appearance.wrappedValue) {
                Haptics.play(.sliders)
                var look = appearance.wrappedValue
                write(&look, newValue)
                appearance.wrappedValue = look
            }
        })
        let shown = percent(read(current))
        return VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            HStack {
                Text(title)
                Spacer()
                Text(shown)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .accessibilityHidden(true)
            Slider(value: value, in: range, step: step) {
                Text(title)
            } minimumValueLabel: {
                Image(systemName: low).imageScale(.small).foregroundStyle(.secondary)
            } maximumValueLabel: {
                Image(systemName: high).imageScale(.large).foregroundStyle(.secondary)
            } onEditingChanged: { editing in
                isSliding.wrappedValue = editing
                guard !editing, let look = draft.wrappedValue else { return }
                draft.wrappedValue = nil
                if look != appearance.wrappedValue {
                    Haptics.play(.sliders)
                    appearance.wrappedValue = look
                }
            }
            .accessibilityValue(shown)
        }
        .accessibilityIdentifier("settings.appearance.\(id)")
    }
}

// MARK: - The parts

private struct AppearanceColourPage: View {
    var body: some View {
        AppearanceSectionPage(title: "Colour", section: .colour, preview: .cards) { controls in
            Section("Accent") {
                Picker("Accent", selection: controls.choice(\.accent)) {
                    ForEach(AppearancePreferences.Accent.allCases) { accent in
                        Label { Text(accent.label) } icon: { (accent.rgb ?? controls.current.customAccent).swatch }
                            .tag(accent)
                    }
                }
                .accessibilityIdentifier("settings.appearance.accent")
                if controls.current.accent == .custom {
                    ColorPicker("Custom accent", selection: controls.colour(\.customAccent), supportsOpacity: false)
                        .accessibilityIdentifier("settings.appearance.customAccent")
                }
            }
            Section("Background") {
                Picker("Background", selection: controls.choice(\.background)) {
                    ForEach(AppearancePreferences.Background.allCases) { background in
                        Label { Text(background.label) } icon: { controls.current.backgroundSwatch(background).swatch }
                            .tag(background)
                    }
                }
                .accessibilityIdentifier("settings.appearance.background")
                if controls.current.background == .custom {
                    ColorPicker("Custom background", selection: controls.colour(\.customBackground), supportsOpacity: false)
                        .accessibilityIdentifier("settings.appearance.customBackground")
                }
                if controls.current.background == .tinted {
                    controls.slider("Tint strength", \.tintStrength, in: AppearancePreferences.tintStrengthRange, step: 0.01,
                                    low: "circle.lefthalf.filled", high: "circle.fill", id: "tintStrength")
                }
            }
        }
    }
}

private struct AppearanceTextPage: View {
    var body: some View {
        AppearanceSectionPage(title: "Text", section: .text, preview: .cards) { controls in
            Section("Text") {
                controls.menu("Size", \.textSize, id: "textSize")
                controls.menu("Font", \.font, id: "font")
                controls.menu("Width", \.fontWidth, id: "fontWidth")
                controls.toggle("Bold", \.boldText, id: "bold")
                controls.toggle("Italic", \.italicText, id: "italic")
            }
            Section("Spacing") {
                controls.segmented("Letter spacing", \.letterSpacing, id: "letterSpacing")
                controls.segmented("Line spacing", \.lineSpacing, id: "lineSpacing")
            }
            Section("Headings") {
                controls.menu("Font", \.headingFont, id: "headingFont")
                controls.menu("Weight", \.headingWeight, id: "headingWeight")
                controls.segmented("Size", \.headingSize, id: "headingSize")
                controls.toggle("All caps", \.uppercaseHeadings, id: "headingCaps")
            }
        }
    }
}

private struct AppearanceCardsPage: View {
    let model: SettingsViewModel

    var body: some View {
        AppearanceSectionPage(title: "Cards", section: .cards, preview: .cards) { controls in
            Section("Size and Shape") {
                controls.slider("Card size", \.cardScale, in: AppearancePreferences.cardScaleRange, step: 0.05,
                                low: "rectangle.portrait", high: "rectangle.portrait", id: "cardSize")
                controls.slider("Spacing", \.spacingScale, in: AppearancePreferences.spacingScaleRange, step: 0.05,
                                low: "arrow.down.right.and.arrow.up.left", high: "arrow.up.left.and.arrow.down.right", id: "spacing")
                if isPhone {
                    controls.numbers("Columns", \.phoneGridColumns, in: AppearancePreferences.phoneGridColumnRange, id: "columns")
                }
            }
            Section("Captions") {
                controls.toggle("Titles under posters", \.showsPosterTitles, id: "posterTitles")
                controls.numbers("Title lines", \.captionLines, in: AppearancePreferences.captionLineRange, id: "titleLines")
                controls.toggle("Genre and year", \.showsCaptionDetails, id: "captionDetails")
            }
            Section("Artwork") {
                controls.menu("Tone", \.artworkTone, id: "tone")
                controls.segmented("Outline", \.outline, id: "outline")
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
            Section("Progress") {
                controls.segmented("Colour", \.progressColour, id: "progressColour")
                controls.segmented("Thickness", \.progressThickness, id: "progressThickness")
                controls.toggle("Time left", \.showsTimeLeft, id: "timeLeft")
            }
        }
    }
}

private struct AppearanceCornersPage: View {
    var body: some View {
        AppearanceSectionPage(title: "Corners", section: .corners, preview: .corners) { controls in
            Section("Global") {
                controls.slider("Corners", \.cornerScale, in: AppearancePreferences.cornerScaleRange, step: 0.1,
                                low: "square", high: "circle", id: "corners")
                controls.toggle("Include circular buttons", \.includesCircularButtons, id: "circularCorners")
            }
            Section("Overrides") {
                ForEach(AppearancePreferences.CornerGroup.allCases) { group in
                    DisclosureGroup {
                        Toggle("Use global", isOn: Binding(get: {
                            controls.current.cornerOverrides[group.rawValue] == nil
                        }, set: { follows in
                            Haptics.play(.choices)
                            var look = controls.appearance.wrappedValue
                            look.cornerOverrides[group.rawValue] = follows ? nil : look.cornerScale(for: group)
                            controls.appearance.wrappedValue = look
                        }))
                        if controls.current.cornerOverrides[group.rawValue] != nil {
                            controls.slider("Corners", read: { $0.cornerScale(for: group) },
                                            write: { $0.cornerOverrides[group.rawValue] = $1 },
                                            in: AppearancePreferences.cornerScaleRange, step: 0.1,
                                            low: "square", high: "circle", id: "corners.\(group.rawValue)")
                        }
                    } label: {
                        LabeledContent(group.label, value: controls.current.cornerOverrides[group.rawValue]
                            .map(percent) ?? "Global · \(percent(controls.current.cornerScale))")
                    }
                }
            }
        }
    }
}

private struct AppearanceHomePage: View {
    var body: some View {
        AppearanceSectionPage(title: "Home", section: .home, preview: .home) { controls in
            Section("Spotlight") {
                controls.slider("Height", \.heroScale, in: AppearancePreferences.heroScaleRange, step: 0.05,
                                low: "rectangle", high: "rectangle.portrait", id: "spotlightHeight")
                Picker("Turn pages", selection: controls.choice(\.heroAutoAdvance)) {
                    ForEach(AppearancePreferences.heroAutoAdvanceOptions, id: \.self) { seconds in
                        Text(seconds == 0 ? "Never" : "Every \(seconds) seconds").tag(seconds)
                    }
                }
                .accessibilityIdentifier("settings.appearance.turnPages")
                controls.toggle("Page dots", \.showsPageDots, id: "pageDots")
            }
        }
    }
}

private struct AppearanceTitlePagesPage: View {
    var body: some View {
        AppearanceSectionPage(title: "Title Pages", section: .titlePages, preview: .titlePage) { controls in
            Section("Spoilers") {
                controls.toggle("Hide spoilers", \.hidesSpoilers, id: "spoilers")
                if controls.current.hidesSpoilers {
                    controls.toggle("Blur stills", \.spoilerStills, id: "spoilerStills")
                    controls.toggle("Hide synopses", \.spoilerSynopses, id: "spoilerSynopses")
                    controls.toggle("Hide episode titles", \.spoilerTitles, id: "spoilerTitles")
                }
            }
            Section("Layout") {
                controls.toggle("Unfold synopsis", \.expandsSynopsis, id: "unfoldSynopsis")
                controls.segmented("Section order", \.sectionOrder, id: "sectionOrder")
            }
            Section("Sections") {
                controls.toggle("Reviews", \.showsReviews, id: "reviews")
                controls.toggle("Cast & Crew", \.showsCast, id: "cast")
                controls.toggle("Information", \.showsInformation, id: "information")
                controls.toggle("More Like This", \.showsRelated, id: "related")
            }
        }
    }
}

private struct AppearanceMotionPage: View {
    var body: some View {
        AppearanceSectionPage(title: "Motion & Navigation", section: .motion, preview: .motion) { controls in
            Section("Motion") {
                controls.menu("Animation speed", \.animationSpeed, id: "animationSpeed")
                controls.toggle("Zoom transitions", \.zoomTransitions, id: "zoom")
            }
            Section("Navigation") {
                controls.menu("Open on", \.startTab, id: "startTab")
                if isPhone {
                    controls.toggle("Tab labels", \.phoneTabTitles, id: "tabLabels")
                    controls.toggle("Shrink tab bar on scroll", \.minimisesTabBar, id: "shrinkTabBar")
                    controls.toggle("Continue Watching bar", \.showsContinueBar, id: "continueBar")
                }
            }
        }
    }
}

// MARK: - Summaries

/// What each part of Appearance is set to, for its row on the Appearance page.
extension AppearancePreferences {
    var colourSummary: String {
        "\(accent.label) · \(background.label)"
    }

    var textSummary: String {
        var parts = [textSize == .system ? "System size" : textSize.label, font.label]
        if fontWidth != .standard { parts.append(fontWidth.label) }
        if boldText { parts.append("Bold") }
        if italicText { parts.append("Italic") }
        if !isHeadingDefault { parts.append("Custom headings") }
        return parts.joined(separator: " · ")
    }

    private var isHeadingDefault: Bool {
        let defaults = AppearancePreferences()
        return headingFont == defaults.headingFont && headingWeight == defaults.headingWeight && headingSize == defaults.headingSize
            && uppercaseHeadings == defaults.uppercaseHeadings
    }

    var cardsSummary: String {
        "Size \(percent(cardScale)) · Spacing \(percent(spacingScale))"
    }

    var homeSummary: String {
        "Spotlight \(percent(heroScale))" + (heroAutoAdvance > 0 ? " · Every \(heroAutoAdvance) s" : "")
    }

    var titlePagesSummary: String {
        let shown = [showsReviews, showsCast, showsInformation, showsRelated].filter { $0 }.count
        var parts = [shown == 4 ? "All sections" : "\(shown) of 4 sections"]
        if sectionOrder == .castFirst { parts.append("Cast first") }
        if hidesSpoilers { parts.append("No spoilers") }
        return parts.joined(separator: " · ")
    }

    var motionSummary: String {
        let speed = switch animationSpeed {
        case .standard: "Default speed"
        case .off: "No animation"
        default: "\(animationSpeed.label) animation"
        }
        return "Opens on \(startTab.label) · \(speed)"
    }
}
#endif
