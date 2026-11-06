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
        #expect(appearance.heroAutoAdvance == 0 && appearance.showsPageDots)
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
        appearance.headingWidth = .expanded
        appearance.headingSpacing = .wider
        appearance.uppercaseHeadings = true
        appearance.cardScale = 1.35
        appearance.cornerScale = 0
        appearance.spacingScale = 1.8
        appearance.phoneGridColumns = 6
        appearance.captionLines = 2
        appearance.outline = .strong
        appearance.artworkTone = .mono
        appearance.progressColour = .accent
        appearance.heroAutoAdvance = 12
        appearance.spoilerTitles = true
        appearance.sectionOrder = .castFirst
        appearance.animationSpeed = .off
        appearance.startTab = .library
        appearance.layout = .editorial
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

    @Test func aPresetIsRecognisedAndLeavesTheListenersOwnChoicesAlone() {
        var appearance = AppearancePreferences()
        appearance.showsReviews = false
        appearance.startTab = .discover
        appearance.heroAutoAdvance = 8
        appearance.animationSpeed = .off
        appearance.textSize = .accessibility2
        #expect(appearance.preset == nil)
        let disney = AppearancePreferences.Preset.disneyPlus.applied(to: appearance)
        #expect(disney.preset == .disneyPlus)
        #expect(disney.accent == .royal && disney.background == .navy)
        // The app's own spotlight and tab bar come with it.
        #expect(disney.heroAutoAdvance == 5 && !disney.phoneTabTitles && !disney.minimisesTabBar)
        #expect(!disney.showsReviews)
        #expect(disney.startTab == .discover)
        #expect(disney.animationSpeed == .off)
        #expect(disney.textSize == .accessibility2)
        var custom = disney
        custom.accent = .green
        #expect(custom.preset == nil)
    }

    @Test func aPresetShapesTheArtworkAndKeepsTheControlsRound() {
        var appearance = AppearancePreferences()
        appearance.cornerOverrides = [AppearancePreferences.CornerGroup.reviews.rawValue: 2]
        let netflix = AppearancePreferences.Preset.netflix.applied(to: appearance)
        #expect(netflix.cornerScale(for: .artwork) == 0.4 && netflix.cornerScale(for: .reviews) == 0.4)
        #expect(netflix.cornerScale(for: .playButton) == 0.3 && netflix.cornerScale(for: .filters) == 1)
        #expect(AppearancePreferences.Preset.appleTV.applied(to: appearance).cornerScale(for: .playButton) == 1)
        let arthouse = AppearancePreferences.Preset.arthouse.applied(to: appearance)
        #expect(arthouse.cornerScale(for: .filters) == 0 && arthouse.cornerScale(for: .actionButtons) == 1)
        #expect(arthouse.uppercaseCaptions && arthouse.artworkTone == .mono && arthouse.layout == .editorial)
        #expect(AppearancePreferences.Preset.appleTV.applied(to: arthouse).layout == .standard)
        #expect(AppearancePreferences.Preset.original.applied(to: arthouse).cornerOverrides.isEmpty)
    }

    @Test func presetsSetPlayTheButtonsFinishHeadingsAndHover() throws {
        let netflix = AppearancePreferences.Preset.netflix.applied(to: AppearancePreferences())
        #expect(netflix.playStyle == .white && netflix.buttonFinish == .solid && !netflix.hover.showsRim)
        let letterboxd = AppearancePreferences.Preset.letterboxd.applied(to: AppearancePreferences())
        #expect(letterboxd.headingColour == .secondary && letterboxd.playStyle == .accent && letterboxd.hover.cardLift == 0)
        let appleTV = AppearancePreferences.Preset.appleTV.applied(to: netflix)
        #expect(appleTV.buttonFinish == .glass && appleTV.playStyle == .white)
        #expect(AppearancePreferences.Preset.original.applied(to: letterboxd).hover == AppearancePreferences.Hover())
        var look = netflix
        look.headingColour = .accent
        let restored = try #require(AppearancePreferences(rawValue: look.rawValue))
        #expect(restored == look)
        #expect(look.restoringDefaults(of: .colour).playStyle == .artwork && look.restoringDefaults(of: .colour).buttonFinish == .glass)
        #expect(look.restoringDefaults(of: .text).headingColour == .primary)
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
        let arthouse = AppearancePreferences.Preset.arthouse.applied(to: appearance)
        #expect(arthouse.customAccent == appearance.customAccent)
        #expect(arthouse.customBackground == appearance.customBackground)
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

    @Test func hoverDefaultsAreTheOriginalFeedback() {
        let hover = AppearancePreferences().hover
        #expect(hover.buttonBrightness == 0.15 && abs(hover.buttonScale - 1.025) < 0.0001)
        #expect(hover.glassFillOpacity == 0.18 && hover.glassRimOpacity == 0.35)
        #expect(abs(hover.segmentFillOpacity - 0.16) < 0.0001 && abs(hover.segmentRimOpacity - 0.3) < 0.0001)
        #expect(abs(hover.cardFillOpacity - 0.08) < 0.0001 && abs(hover.cardScale - 1.04) < 0.0001 && hover.castsShadow)
        #expect(hover.glowOpacity == 0.04 && hover.usesSystemHighlight && hover.duration(0.12) == 0.12)
    }

    @Test func hoverRoundTripsAndAnOldSaveReadsTheDefaults() throws {
        var appearance = AppearancePreferences()
        appearance.hover.brightness = 0.3
        appearance.hover.showsRim = false
        appearance.hover.speed = .instant
        let restored = try #require(AppearancePreferences(rawValue: appearance.rawValue))
        #expect(restored == appearance)
        #expect(restored.hover.glassRimOpacity == 0 && restored.hover.duration(0.12) == nil)

        let old = try #require(AppearancePreferences(rawValue: #"{"accent":"mint"}"#))
        #expect(old.hover == AppearancePreferences.Hover())
        let clamped = try #require(AppearancePreferences(rawValue: #"{"hover":{"brightness":9,"isEnabled":false}}"#))
        #expect(clamped.hover.brightness == AppearancePreferences.Hover.brightnessRange.upperBound && clamped.hover.buttonScale == 1)
    }

    @Test func restoringHoverLeavesTheRestAndPresetsSetTheirOwnHover() {
        var appearance = AppearancePreferences()
        appearance.accent = .mint
        appearance.hover.cardLift = 0.1
        #expect(!appearance.isDefault(.hover))
        let restored = appearance.restoringDefaults(of: .hover)
        #expect(restored.isDefault(.hover) && restored.accent == .mint)
        // A preset brings its app's hover; Arthouse's is the original feedback.
        #expect(AppearancePreferences.Preset.arthouse.applied(to: appearance).hover == AppearancePreferences.Hover())
        #expect(AppearancePreferences.Preset.disneyPlus.applied(to: appearance).hover.rimStrength == 1)
    }
}
