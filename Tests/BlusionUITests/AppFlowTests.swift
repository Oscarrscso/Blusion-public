import XCTest

/// M3 acceptance flows, driven against the local mock addon (its URLs arrive through TEST_RUNNER_MOCK_ADDON_* variables).
final class AppFlowTests: XCTestCase {
    private var catalogURL: String { ProcessInfo.processInfo.environment["MOCK_ADDON_CATALOG_URL"] ?? "" }

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    private func launch(contentSize: String? = nil) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["BLUSION_UITEST"] = "1"
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
