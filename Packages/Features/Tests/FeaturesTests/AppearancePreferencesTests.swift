import Foundation
import Testing
@testable import Features

@Suite struct AppearancePreferencesTests {
    @Test func theDefaultsAreTheOriginalLook() {
        let appearance = AppearancePreferences()
        #expect(appearance.isDefault)
        #expect(appearance.accent == .blusion)
        #expect(appearance.background == .black)
        #expect(appearance.cardScale == 1 && appearance.cornerScale == 1 && appearance.spacingScale == 1)
        #expect(appearance.phoneGridColumns == 3)
        #expect(!appearance.showsPosterTitles)
        #expect(appearance.captionLines == 1 && appearance.showsCaptionDetails)
        #expect(appearance.outline == .standard && appearance.artworkTone == .natural)
        #expect(appearance.headingFont == .matchText && appearance.headingWeight == .bold && appearance.headingSize == .standard)
        #expect(appearance.heroScale == 1 && appearance.heroAutoAdvance == 0 && appearance.showsPageDots)
        #expect(appearance.animationSpeed == .standard)
        #expect(appearance.startTab.tab == .home)
        #expect(appearance.backgroundRGB == AppearancePreferences.RGB(red: 0, green: 0, blue: 0))
    }

    @Test func aSaveRoundTripsThroughItsRawValue() throws {
        var appearance = AppearancePreferences()
        appearance.accent = .custom
        appearance.customAccent = .init(red: 0.2, green: 0.4, blue: 0.6)
        appearance.background = .custom
        appearance.customBackground = .init(red: 0.1, green: 0.05, blue: 0)
        appearance.textSize = .accessibility2
        appearance.font = .serif
        appearance.boldText = true
        appearance.italicText = true
        appearance.fontWidth = .condensed
        appearance.letterSpacing = .wider
        appearance.headingFont = .monospaced
        appearance.headingWeight = .black
        appearance.uppercaseHeadings = true
        appearance.cardScale = 1.35
        appearance.cornerScale = 0
        appearance.spacingScale = 1.8
        appearance.phoneGridColumns = 6
        appearance.captionLines = 2
        appearance.outline = .strong
        appearance.artworkTone = .mono
        appearance.progressColour = .accent
        appearance.heroScale = 0.7
        appearance.heroAutoAdvance = 12
        appearance.spoilerTitles = true
        appearance.sectionOrder = .castFirst
        appearance.animationSpeed = .off
        appearance.startTab = .library
        let restored = try #require(AppearancePreferences(rawValue: appearance.rawValue))
        #expect(restored == appearance)
        #expect(!restored.isDefault)
        #expect(restored.accentRGB == appearance.customAccent)
        #expect(restored.backgroundRGB == appearance.customBackground)
    }

    @Test func aFieldThatCannotBeReadFallsBackOnItsOwn() throws {
        let saved = #"{"accent":"neon","background":"graphite","phoneGridColumns":9,"cardSize":4,"captionLines":0,"heroAutoAdvance":7}"#
        let appearance = try #require(AppearancePreferences(rawValue: saved))
        #expect(appearance.accent == .blusion)
        #expect(appearance.background == .graphite)
        #expect(appearance.cardScale == AppearancePreferences.cardScaleRange.upperBound)
        #expect(appearance.phoneGridColumns == AppearancePreferences.phoneGridColumnRange.upperBound)
        #expect(appearance.captionLines == 1)
        #expect(appearance.heroAutoAdvance == 0)
        #expect(appearance.font == .standard)
    }

    @Test func theOldFixedStepsReadIntoTheNewValues() throws {
        let saved = #"{"cardScale":"large","corners":"round","density":"compact","artworkOutline":false}"#
        let appearance = try #require(AppearancePreferences(rawValue: saved))
        #expect(appearance.cardScale == 1.2)
        #expect(appearance.cornerScale == 1.8)
        #expect(appearance.spacingScale == 0.66)
        #expect(appearance.outline == .off)
        // Written back under the new names only.
        let rewritten = appearance.rawValue
        #expect(!rewritten.contains("\"density\"") && !rewritten.contains("\"artworkOutline\""))
        #expect(AppearancePreferences(rawValue: rewritten) == appearance)
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
        appearance.heroAutoAdvance = 8
        #expect(appearance.preset == .original)
        let midnight = AppearancePreferences.Preset.midnight.applied(to: appearance)
        #expect(midnight.preset == .midnight)
        #expect(midnight.background == .midnight)
        #expect(!midnight.showsReviews)
        #expect(midnight.startTab == .discover)
        #expect(midnight.heroAutoAdvance == 8)
        var custom = midnight
        custom.accent = .green
        #expect(custom.preset == nil)
    }

    @Test func everyPresetIsItsOwn() {
        let looks = AppearancePreferences.Preset.allCases.map { $0.applied(to: AppearancePreferences()) }
        for (preset, look) in zip(AppearancePreferences.Preset.allCases, looks) {
            #expect(look.preset == preset, "\(preset)")
        }
    }

    @Test func aPresetKeepsTheMixedColours() {
        var appearance = AppearancePreferences()
        appearance.customAccent = .init(red: 1, green: 0, blue: 0)
        appearance.customBackground = .init(red: 0, green: 0.1, blue: 0)
        let neon = AppearancePreferences.Preset.neon.applied(to: appearance)
        #expect(neon.customAccent == appearance.customAccent)
        #expect(neon.customBackground == appearance.customBackground)
    }

    @Test func restoringASectionLeavesTheOthers() {
        var appearance = AppearancePreferences()
        appearance.accent = .red
        appearance.cardScale = 1.5
        appearance.hidesSpoilers = true
        let restored = appearance.restoringDefaults(of: .cards)
        #expect(restored.cardScale == 1)
        #expect(restored.accent == .red && restored.hidesSpoilers)
        #expect(restored.isDefault(.cards) && !restored.isDefault(.colour) && !restored.isDefault(.titlePages))
        for section in AppearancePreferences.Section.allCases {
            #expect(AppearancePreferences().isDefault(section))
        }
        let all = AppearancePreferences.Section.allCases.reduce(appearance) { $0.restoringDefaults(of: $1) }
        #expect(all.isDefault)
    }

    @Test func theTintedBackgroundFollowsItsStrength() {
        var appearance = AppearancePreferences()
        appearance.accent = .white
        appearance.background = .tinted
        appearance.tintStrength = 0.2
        let rgb = appearance.backgroundRGB
        #expect(abs(rgb.red - 0.92 * 0.2) < 0.0001)
    }

    @Test func theLayoutKeyFollowsWhatChangesACardsHeight() {
        var appearance = AppearancePreferences()
        let original = appearance.layoutKey
        appearance.accent = .red
        appearance.artworkTone = .mono
        #expect(appearance.layoutKey == original)
        appearance.captionLines = 2
        #expect(appearance.layoutKey != original)
        appearance.captionLines = 1
        appearance.cardScale = 1.05
        #expect(appearance.layoutKey != original)
    }

    @Test func looksAreSavedByNameAndReplaced() throws {
        var looks = AppearanceLooks()
        var appearance = AppearancePreferences()
        appearance.accent = .pink
        looks.save(appearance, as: "  Night  ")
        looks.save(AppearancePreferences(), as: "")
        #expect(looks.looks.map(\.name) == ["Night", "Look 2"])
        appearance.accent = .mint
        looks.save(appearance, as: "night")
        #expect(looks.looks.count == 2)
        #expect(looks.looks[0].appearance.accent == .mint)
        let restored = try #require(AppearanceLooks(rawValue: looks.rawValue))
        #expect(restored == looks)
    }
}
