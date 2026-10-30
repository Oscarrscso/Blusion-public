#if canImport(UIKit)
import Foundation
import StremioKit
import SwiftUI

/// Groups tuning and previews by the action that uses them.
struct HapticsSettingsPage: View {
    let model: SettingsViewModel

    /// What the sliders and switches show. Held here so a drag stays smooth; committed to the store when it ends.
    @State private var draft = HapticPreferences()
    /// The strength last previewed per feel, so a drag fires once per whole percent rather than once per pixel.
    @State private var lastPreview: [Haptics.Feel: Double] = [:]

    var body: some View {
        List {
            Section {
                // Apply before previewing so the master switch takes effect immediately.
                Toggle("Haptics", isOn: Binding(get: { draft.isOn }, set: { value in
                    draft.isEnabled = value
                    commit()
                    if value { Haptics.preview(.tap) }
                }))
                .accessibilityIdentifier("settings.haptics.enabled")
            }
            Group {
                Section("Buttons & title taps") {
                    styleRow(feel: .tap, key: \.tapStyle, fallback: HapticPreferences.Default.tapStyle, identifier: "tap")
                    strengthRow("Strength", feel: .tap, key: \.tap, fallback: HapticPreferences.Default.tap, identifier: "tap")
                    previewButton("Test button tap", feel: .tap, identifier: "tap")
                }
                Section("Scrolling poster shelves") {
                    styleRow(feel: .shelfSnap, key: \.shelfSnapStyle, fallback: HapticPreferences.Default.shelfSnapStyle, identifier: "shelfSnap")
                    strengthRow("Strength", feel: .shelfSnap, key: \.shelfSnap,
                                fallback: HapticPreferences.Default.shelfSnap, identifier: "shelfSnap")
                    spacingRow
                    VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                        Text("Swipe to test shelf ticks")
                        ShelfScroll(margin: 0, spacing: Theme.Spacing.s, lazy: false) {
                            ForEach(1...8, id: \.self) { number in
                                Text("Poster \(number)")
                                    .frame(width: 100, height: 120)
                                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
                                    .reportsShelfEdge(id: number)
                            }
                        }
                        .accessibilityLabel("Swipe posters to test shelf ticks")
                    }
                }
                Section("Home banner page changes") {
                    styleRow(feel: .pageChange, key: \.pageChangeStyle, fallback: HapticPreferences.Default.pageChangeStyle, identifier: "pageChange")
                    strengthRow("Strength", feel: .pageChange, key: \.pageChange,
                                fallback: HapticPreferences.Default.pageChange, identifier: "pageChange")
                    previewButton("Test page change", feel: .pageChange, identifier: "pageChange")
                }
                Section("Expanding & folding reviews") {
                    styleRow(feel: .textLines, key: \.textLinesStyle, fallback: HapticPreferences.Default.textLinesStyle, identifier: "textLines")
                    strengthRow("Tick strength", feel: .textLines, key: \.textLines,
                                fallback: HapticPreferences.Default.textLines, identifier: "textLines")
                    tickLimitRow
                    Button("Test review · \(draft.reviewTicks) ticks") {
                        Haptics.apply(draft)
                        Haptics.lines(draft.reviewTicks, over: .seconds(DetailReviews.foldDuration))
                    }
                    .buttonStyle(.borderless)
                    .accessibilityIdentifier("settings.haptics.preview.textLines")
                }
                Section("Tabs, filters & pickers") {
                    toggle("Selection tick", feel: .selection, isOn: { draft.selectionOn }, identifier: "selection") { draft.selection = $0 }
                    previewButton("Test selection change", feel: .selection, identifier: "selection")
                        .disabled(!draft.selectionOn)
                }
                Section("Save confirmation") {
                    toggle("Saved feedback", feel: .success, isOn: { draft.successOn }, identifier: "success") { draft.success = $0 }
                    previewButton("Test saved confirmation", feel: .success, identifier: "success")
                        .disabled(!draft.successOn)
                }
                Section("Playback failure") {
                    toggle("Failure feedback", feel: .failure, isOn: { draft.failureOn }, identifier: "failure") { draft.failure = $0 }
                    previewButton("Test playback failure", feel: .failure, identifier: "failure")
                        .disabled(!draft.failureOn)
                }
            }
            .disabled(!draft.isOn)
            Section {
                Button("Reset to defaults") {
                    draft = HapticPreferences()
                    lastPreview = [:]
                    commit()
                    Haptics.preview(.tap)
                }
                .accessibilityIdentifier("settings.haptics.reset")
            }
        }
        .settingsPage("Haptics")
        .onAppear { draft = model.settings.haptics }
    }

    /// Strength changes preview one tick; the named test buttons demonstrate the complete action.
    private func strengthRow(_ title: String, feel: Haptics.Feel, key: WritableKeyPath<HapticPreferences, Double?>,
                             fallback: Double, identifier: String) -> some View {
        let saved = resolved(key, fallback)
        return VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            HStack {
                Text(title)
                Spacer()
                Text(percent(saved)).foregroundStyle(.secondary).monospacedDigit()
            }
            Slider(value: Binding(get: { resolved(key, fallback) }, set: { value in
                draft[keyPath: key] = value
                previewIfNewPercent(feel, value)
            }), in: HapticPreferences.Limits.strength, step: 0.01, onEditingChanged: { editing in
                if !editing {
                    lastPreview[feel] = nil
                    commit()
                }
            })
            .accessibilityLabel(title)
            .accessibilityValue(percent(saved))
            .accessibilityIdentifier("settings.haptics.\(identifier)")
        }
    }

    private func styleRow(feel: Haptics.Feel, key: WritableKeyPath<HapticPreferences, HapticPreferences.ImpactStyle?>,
                          fallback: HapticPreferences.ImpactStyle, identifier: String) -> some View {
        Picker("Feel", selection: Binding(get: { draft[keyPath: key] ?? fallback }, set: { value in
            draft[keyPath: key] = value
            commit()
            Haptics.preview(feel)
        })) {
            ForEach(HapticPreferences.ImpactStyle.allCases, id: \.self) { style in
                Text(style.rawValue.capitalized).tag(style)
            }
        }
        .accessibilityIdentifier("settings.haptics.\(identifier).style")
    }

    private func toggle(_ title: String, feel: Haptics.Feel, isOn: @escaping () -> Bool, identifier: String,
                        set: @escaping (Bool) -> Void) -> some View {
        Toggle(title, isOn: Binding(get: isOn, set: { value in
            set(value)
            commit()
            if value { Haptics.preview(feel) }
        }))
        .accessibilityIdentifier("settings.haptics.\(identifier)")
    }

    private func previewButton(_ title: String, feel: Haptics.Feel, identifier: String) -> some View {
        Button {
            Haptics.apply(draft)
            Haptics.preview(feel)
        } label: {
            Label(title, systemImage: "hand.tap")
        }
        .buttonStyle(.borderless)
        .accessibilityIdentifier("settings.haptics.preview.\(identifier)")
    }

    /// Minimum travel before another card-edge crossing can tick.
    private var spacingRow: some View {
        let value = draft.shelfTickSpacingPoints
        return VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            HStack {
                Text("Minimum travel between ticks")
                Spacer()
                Text("\(Int(value.rounded())) pt").foregroundStyle(.secondary).monospacedDigit()
            }
            Slider(value: Binding(get: { draft.shelfTickSpacingPoints }, set: { draft.shelfTickSpacing = $0 }),
                   in: HapticPreferences.Limits.shelfTickSpacing, step: 2, onEditingChanged: { editing in
                if !editing { commit() }
            })
            .accessibilityLabel("Minimum shelf travel between ticks")
            .accessibilityValue("\(Int(value.rounded())) points")
            .accessibilityIdentifier("settings.haptics.shelfSpacing")
        }
    }

    /// The most ticks one unfolded review gives.
    private var tickLimitRow: some View {
        let value = draft.reviewTicks
        return VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            HStack {
                Text("Maximum ticks per review")
                Spacer()
                Text("\(value)").foregroundStyle(.secondary).monospacedDigit()
            }
            Slider(value: Binding(get: { Double(draft.reviewTicks) }, set: { draft.reviewTickLimit = Int($0.rounded()) }),
                   in: Double(HapticPreferences.Limits.reviewTickLimit.lowerBound)...Double(HapticPreferences.Limits.reviewTickLimit.upperBound),
                   step: 1, onEditingChanged: { editing in
                if !editing { commit() }
            })
            .accessibilityLabel("Review ticks")
            .accessibilityValue("\(value)")
            .accessibilityIdentifier("settings.haptics.reviewTicks")
        }
    }

    private func resolved(_ key: WritableKeyPath<HapticPreferences, Double?>, _ fallback: Double) -> Double {
        let raw = draft[keyPath: key] ?? fallback
        return min(max(raw, HapticPreferences.Limits.strength.lowerBound), HapticPreferences.Limits.strength.upperBound)
    }

    private func percent(_ strength: Double) -> String {
        "\(Int((strength * 100).rounded()))%"
    }

    /// One impact per whole percent, so dragging the slider demonstrates the feel without turning into a rattle.
    private func previewIfNewPercent(_ feel: Haptics.Feel, _ strength: Double) {
        let whole = (strength * 100).rounded() / 100
        guard lastPreview[feel] != whole else { return }
        lastPreview[feel] = whole
        Haptics.apply(draft)
        Haptics.preview(feel, strength: whole)
    }

    /// Saves what the page shows and applies it, so the next tap obeys the slider that has just been let go.
    private func commit() {
        let saved = draft
        Haptics.apply(saved)
        Task { await model.updateHaptics { $0 = saved } }
    }
}
#endif
