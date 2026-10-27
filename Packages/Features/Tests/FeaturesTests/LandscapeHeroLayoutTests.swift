import CoreGraphics
import Testing
@testable import Features

#if canImport(UIKit)
@Suite struct LandscapeHeroLayoutTests {
    @Test func phoneHeroLeavesThePeekUnderIt() {
        // An iPhone in landscape: the page is about 402pt tall.
        #expect(TitleHero.landscapeHeroHeight(pageHeight: 402) == 402 - TitleHero.landscapePeek)
    }

    @Test func iPadHeroIsCapped() {
        #expect(TitleHero.landscapeHeroHeight(pageHeight: 1024) == TitleHero.landscapeMaxHeight)
    }

    @Test func shortWindowKeepsAFloor() {
        #expect(TitleHero.landscapeHeroHeight(pageHeight: 180) == TitleHero.landscapeMinHeight)
    }

    @Test func artIsSixteenByNineAtHeroHeight() {
        #expect(TitleHero.landscapeArtWidth(heroHeight: 346, pageWidth: 900) == 346 * 16 / 9)
    }

    @Test func artIsNeverWiderThanThePage() {
        #expect(TitleHero.landscapeArtWidth(heroHeight: 560, pageWidth: 700) == 700)
    }

    @Test func textColumnIsAShareOfThePageThenCapped() {
        #expect(TitleHero.landscapeTextWidth(pageWidth: 756) == 756 * 0.46)
        #expect(TitleHero.landscapeTextWidth(pageWidth: 1366) == 480)
    }
}
#endif
