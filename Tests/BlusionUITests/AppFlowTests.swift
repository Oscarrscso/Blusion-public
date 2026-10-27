import XCTest
import UIKit

/// M3 acceptance flows, driven against the local mock addon (its URLs arrive through TEST_RUNNER_MOCK_ADDON_* variables).
final class AppFlowTests: XCTestCase {
    private var catalogURL: String { ProcessInfo.processInfo.environment["MOCK_ADDON_CATALOG_URL"] ?? "" }

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    private func launch(contentSize: String? = nil, demoData: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["BLUSION_UITEST"] = "1"
        if demoData { app.launchEnvironment["BLUSION_DEMO_DATA"] = "1" }
        if let contentSize { app.launchArguments += ["-UIPreferredContentSizeCategoryName", contentSize] }
        app.launch()
        return app
    }

    @MainActor
    private func installMockCatalogAddon(_ app: XCUIApplication, token: String = "uitest") throws {
        try XCTSkipIf(catalogURL.isEmpty, "MOCK_ADDON_CATALOG_URL is not set (run through scripts/verify.sh)")
        openAddons(app)
        let field = app.textFields["addons.installField"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText("\(catalogURL)/\(token)/manifest.json")
        app.buttons["addons.installButton"].tap()
        XCTAssertTrue(app.staticTexts["addons.success"].waitForExistence(timeout: 15), "install should succeed against the mock")
    }

    @MainActor
    func testEmptyStateExplainsHowToAddAnAddon() throws {
        let app = launch()
        XCTAssertTrue(app.staticTexts["No addons yet"].waitForExistence(timeout: 10))
        captureScreenshot(app, named: "M3-home-empty")
        app.buttons["empty.addAddon"].tap()
        XCTAssertTrue(app.textFields["addons.installField"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["addons.installSuggested"].exists, "the catalog-only suggestion is offered, never installed automatically")
        captureScreenshot(app, named: "M3-addons-empty")
    }

    @MainActor
    func testInstallBrowseAndOpenDetail() throws {
        let app = launch()
        try installMockCatalogAddon(app)
        captureScreenshot(app, named: "M3-addons-installed")

        dismissSettings(app)
        XCTAssertTrue(app.scrollViews["board.rows"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["poster.mock:movie1"].firstMatch.waitForExistence(timeout: 15))
        captureScreenshot(app, named: "M3-home")

        let poster = app.buttons["poster.mock:movie1"].firstMatch
        XCTAssertTrue(poster.waitForExistence(timeout: 10))
        poster.tap()
        XCTAssertTrue(app.staticTexts["detail.title"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.staticTexts["detail.title"].label, "Mock Movie 1")
        XCTAssertTrue(app.buttons["detail.playButton"].exists)
        captureScreenshot(app, named: "M3-detail")
    }

    @MainActor
    func testPreviewOnlyTitleStillOpensDetailWithAFallbackNote() throws {
        let app = launch()
        try installMockCatalogAddon(app)
        dismissSettings(app)
        let poster = app.buttons["poster.mock:nometa1"].firstMatch
        XCTAssertTrue(poster.waitForExistence(timeout: 15))
        poster.tap()
        XCTAssertTrue(app.staticTexts["detail.fallbackNote"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.staticTexts["detail.title"].label, "Preview Only Movie")
    }

    @MainActor
    func testSearchFindsAMovieAcrossAddons() throws {
        let app = launch()
        try installMockCatalogAddon(app)
        dismissSettings(app)
        app.tabBars.buttons["Search"].tap()
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText("movie 12")
        XCTAssertTrue(app.buttons["poster.mock:movie12"].firstMatch.waitForExistence(timeout: 15))
        captureScreenshot(app, named: "M3-search")
    }

    @MainActor
    func testDiscoverShowsAGridAndAGenreMenu() throws {
        let app = launch()
        try installMockCatalogAddon(app)
        dismissSettings(app)
        app.tabBars.buttons["Discover"].tap()
        XCTAssertTrue(app.buttons["discover.catalogMenu"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["poster.mock:movie1"].firstMatch.waitForExistence(timeout: 15))
        app.buttons["discover.genreMenu"].tap()
        app.buttons["Drama"].tap()
        XCTAssertTrue(app.buttons["discover.genreMenu"].waitForExistence(timeout: 10))
        captureScreenshot(app, named: "M3-discover")
    }

    @MainActor
    func testLandscapeBrowsingRemovesResumeAccessoryAndRestoresItInPortrait() throws {
        try XCTSkipIf(catalogURL.isEmpty, "MOCK_ADDON_CATALOG_URL is not set (run through scripts/verify.sh)")
        XCUIDevice.shared.orientation = .portrait
        defer { XCUIDevice.shared.orientation = .portrait }
        let app = launch(demoData: true)
        try XCTSkipIf(app.frame.width >= 600, "requires an iPhone-sized simulator")
        if #unavailable(iOS 26.1) { throw XCTSkip("tab accessories require iOS 26.1") }
        try installMockCatalogAddon(app)
        dismissSettings(app)

        let accessory = app.descendants(matching: .any)["tabbar.continue"].firstMatch
        XCTAssertTrue(accessory.waitForExistence(timeout: 10), "seeded progress must make the portrait accessory visible")
        // Change resume data through the real action before rotating, rather than testing an empty accessory model.
        let previousTitle = accessory.label
        accessory.press(forDuration: 1.2)
        let watched = app.buttons["Mark as Watched"]
        XCTAssertTrue(watched.waitForExistence(timeout: 5))
        watched.tap()
        let changed = NSPredicate { _, _ in accessory.exists && accessory.label != previousTitle }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: changed, object: nil)], timeout: 10), .completed)

        for orientation in [UIDeviceOrientation.landscapeLeft, .landscapeRight] {
            XCUIDevice.shared.orientation = orientation
            let rotated = NSPredicate { _, _ in app.frame.width > app.frame.height }
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: rotated, object: nil)], timeout: 5), .completed)
            XCTAssertTrue(accessory.waitForNonExistence(timeout: 5))

            let rows = app.scrollViews["board.rows"]
            XCTAssertTrue(rows.waitForExistence(timeout: 10))
            let home = app.buttons["landscape.home"]
            let searchControl = app.buttons["landscape.search"]
            XCTAssertTrue(home.waitForExistence(timeout: 5), "Home stays mounted before scrolling")
            XCTAssertTrue(searchControl.waitForExistence(timeout: 5))
            let homeFrameBeforeScroll = home.frame
            for _ in 0..<6 where searchControl.exists { rows.swipeUp(velocity: .slow) }
            XCTAssertTrue(searchControl.waitForNonExistence(timeout: 5), "other landscape controls fade on scroll")
            XCTAssertTrue(home.exists, "collapsed landscape navigation keeps the same Home")
            XCTAssertEqual(home.frame.midX, homeFrameBeforeScroll.midX, accuracy: 1, "Home must not move horizontally")
            XCTAssertEqual(home.frame.midY, homeFrameBeforeScroll.midY, accuracy: 1, "Home must not jump vertically")
            XCTAssertEqual(home.frame.width, homeFrameBeforeScroll.width, accuracy: 1, "Home must not resize")
            XCTAssertEqual(home.frame.height, homeFrameBeforeScroll.height, accuracy: 1, "Home must not resize")
            XCTAssertFalse(accessory.exists)
            captureScreenshot(app, named: "landscape-home-\(orientation.rawValue)")

            home.tap()
            let discover = app.buttons["landscape.discover"]
            XCTAssertTrue(discover.waitForExistence(timeout: 5))
            discover.tap()
            let grid = app.scrollViews["discover.scroll"]
            XCTAssertTrue(grid.waitForExistence(timeout: 10))
            XCTAssertTrue(app.buttons["poster.mock:movie1"].firstMatch.waitForExistence(timeout: 15))
            grid.swipeUp(velocity: .slow)
            XCTAssertFalse(accessory.exists, "tab navigation and grid scrolling must not restore the accessory")
            captureScreenshot(app, named: "landscape-grid-\(orientation.rawValue)")

            // Home stays fixed and tappable even while the other buttons are hidden.
            XCTAssertTrue(home.exists)
            home.tap()
            let seeAll = app.buttons["section.seeAll.Mock Movies"]
            for _ in 0..<6 where !seeAll.isHittable { rows.swipeUp(velocity: .slow) }
            XCTAssertTrue(seeAll.waitForExistence(timeout: 5))
            seeAll.tap()
            let catalog = app.descendants(matching: .any)["catalogList.grid"].firstMatch
            XCTAssertTrue(catalog.waitForExistence(timeout: 10))
            catalog.swipeUp(velocity: .slow)
            let pageTitle = app.staticTexts["landscape.pageTitle"]
            XCTAssertTrue(pageTitle.waitForExistence(timeout: 5), "the catalogue title appears beside Home after scrolling")
            XCTAssertEqual(pageTitle.label, "Mock Movies")
            XCTAssertFalse(accessory.exists)
            captureScreenshot(app, named: "landscape-catalogue-\(orientation.rawValue)")

            // Foregrounding refreshes progress at the root. It must not reattach the native accessory in landscape.
            XCUIDevice.shared.press(.home)
            app.activate()
            XCTAssertTrue(accessory.waitForNonExistence(timeout: 5))

            XCUIDevice.shared.orientation = .portrait
            XCTAssertTrue(catalog.waitForExistence(timeout: 5), "rotation preserves the catalogue navigation path")
            XCTAssertTrue(accessory.waitForExistence(timeout: 10))
            XCTAssertFalse(home.exists)
            let homeTab = app.tabBars.buttons["Home"]
            XCTAssertTrue(homeTab.waitForExistence(timeout: 5))
            homeTab.tap()
        }
        captureScreenshot(app, named: "landscape-return-to-portrait")
    }

    @MainActor
    func testBadAddonURLShowsAReadableError() throws {
        let app = launch()
        openAddons(app)
        let field = app.textFields["addons.installField"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText("ftp://example.com/manifest.json")
        app.buttons["addons.installButton"].tap()
        XCTAssertTrue(app.staticTexts["addons.error"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testAccessibilityAuditOnMainScreens() throws {
        let app = launch()
        try installMockCatalogAddon(app)
        try app.performAccessibilityAudit()
        dismissSettings(app)
        XCTAssertTrue(app.buttons["poster.mock:movie1"].firstMatch.waitForExistence(timeout: 15))
        try app.performAccessibilityAudit()
        app.buttons["poster.mock:movie1"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["detail.title"].waitForExistence(timeout: 10))
        try app.performAccessibilityAudit()
    }

    @MainActor
    func testLargestDynamicTypeDoesNotClipTheMainScreens() throws {
        let app = launch(contentSize: "UICTContentSizeCategoryAccessibilityXXXL")
        try installMockCatalogAddon(app)
        captureScreenshot(app, named: "M3-addons-AX5")
        try app.performAccessibilityAudit(for: .textClipped)
        dismissSettings(app)
        XCTAssertTrue(app.buttons["poster.mock:movie1"].firstMatch.waitForExistence(timeout: 15))
        captureScreenshot(app, named: "M3-home-AX5")
        try app.performAccessibilityAudit(for: .textClipped)
    }
}
