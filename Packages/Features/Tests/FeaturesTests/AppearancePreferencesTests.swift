import Foundation
import Testing
@testable import Features

@Suite struct AppearancePreferencesTests {
    @Test func theDefaultsAreTheOriginalLook() {
        let appearance = AppearancePreferences()
        #expect(appearance.isDefault)
        #expect(appearance.accent == .blusion)
        #expect(appearance.background == .black)
        #expect(appearance.cardScale.factor == 1)
        #expect(appearance.corners.factor == 1)
        #expect(appearance.density.factor == 1)
        #expect(appearance.phoneGridColumns == 3)
        #expect(!appearance.showsPosterTitles)
        #expect(appearance.startTab.tab == .home)
    }

    @Test func aSaveRoundTripsThroughItsRawValue() throws {
        var appearance = AppearancePreferences()
        appearance.accent = .custom
        appearance.customAccent = .init(red: 0.2, green: 0.4, blue: 0.6)
        appearance.background = .tinted
        appearance.textSize = .xLarge
        appearance.font = .serif
        appearance.boldText = true
        appearance.cardScale = .huge
        appearance.corners = .square
        appearance.density = .roomy
        appearance.phoneGridColumns = 5
        appearance.showsPosterTitles = true
        appearance.startTab = .library
        let restored = try #require(AppearancePreferences(rawValue: appearance.rawValue))
        #expect(restored == appearance)
        #expect(!restored.isDefault)
        #expect(restored.accentRGB == appearance.customAccent)
    }

    @Test func aFieldThatCannotBeReadFallsBackOnItsOwn() throws {
        let saved = #"{"accent":"neon","background":"graphite","phoneGridColumns":9,"cardScale":"large"}"#
        let appearance = try #require(AppearancePreferences(rawValue: saved))
        #expect(appearance.accent == .blusion)
        #expect(appearance.background == .graphite)
        #expect(appearance.cardScale == .large)
        #expect(appearance.phoneGridColumns == AppearancePreferences.phoneGridColumnRange.upperBound)
        #expect(appearance.font == .standard)
    }

    @Test func savedReadsTheDefaultsAndResetForgets() throws {
        let suite = "AppearancePreferencesTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(AppearancePreferences.saved(in: defaults).isDefault)
        var appearance = AppearancePreferences()
        appearance.accent = .green
        defaults.set(appearance.rawValue, forKey: AppearancePreferences.defaultsKey)
        #expect(AppearancePreferences.saved(in: defaults).accent == .green)
        AppearancePreferences.reset(in: defaults)
        #expect(AppearancePreferences.saved(in: defaults).isDefault)
    }

    @Test func aPresetIsRecognisedAndLeavesTheRestAlone() {
        var appearance = AppearancePreferences()
        appearance.showsReviews = false
        appearance.startTab = .discover
        #expect(appearance.preset == .original)
        let midnight = AppearancePreferences.Preset.midnight.applied(to: appearance)
        #expect(midnight.preset == .midnight)
        #expect(midnight.background == .midnight)
        #expect(!midnight.showsReviews)
        #expect(midnight.startTab == .discover)
        var custom = midnight
        custom.accent = .green
        #expect(custom.preset == nil)
    }

    @Test func theNewSwitchesDefaultToTheOriginalApp() {
        let appearance = AppearancePreferences()
        #expect(appearance.artworkOutline && appearance.zoomTransitions && !appearance.hidesSpoilers)
        #expect(appearance.showsReviews && appearance.showsCast && appearance.showsInformation && appearance.showsRelated)
        #expect(!appearance.phoneTabTitles && appearance.minimisesTabBar && appearance.showsContinueBar)
    }

    @Test func theLayoutKeyFollowsWhatChangesACardsHeight() {
        var appearance = AppearancePreferences()
        let original = appearance.layoutKey
        appearance.accent = .red
        #expect(appearance.layoutKey == original)
        appearance.showsPosterTitles = true
        #expect(appearance.layoutKey != original)
    }
}
