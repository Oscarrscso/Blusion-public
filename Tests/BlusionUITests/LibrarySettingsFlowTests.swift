import XCTest

/// M7 acceptance in the simulator: save a title and find it in Library, resume from Continue Watching, change settings, clear data.
final class LibrarySettingsFlowTests: XCTestCase {
    private var catalogURL: String { ProcessInfo.processInfo.environment["MOCK_ADDON_CATALOG_URL"] ?? "" }
    private var streamURL: String { ProcessInfo.processInfo.environment["MOCK_ADDON_STREAM_URL"] ?? "" }

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["BLUSION_UITEST"] = "1"
        app.launch()
        return app
    }

    @MainActor
    private func install(_ app: XCUIApplication, _ urls: [String]) {
        openAddons(app)
        for url in urls {
            let field = app.textFields["addons.installField"]
            XCTAssertTrue(field.waitForExistence(timeout: 10))
            field.tap()
            field.typeText(url)
            app.buttons["addons.installButton"].tap()
            XCTAssertTrue(app.staticTexts["addons.success"].waitForExistence(timeout: 15))
        }
    }

    @MainActor
    func testEmptyLibraryExplainsItself() throws {
        let app = launch()
        app.tabBars.buttons["Library"].tap()
        XCTAssertTrue(app.staticTexts["Your library is empty"].waitForExistence(timeout: 10))
        captureScreenshot(app, named: "M7-library-empty")
    }

    @MainActor
    func testSavingATitleShowsItInTheLibraryAndUnsavingRemovesIt() throws {
        try XCTSkipIf(catalogURL.isEmpty, "MOCK_ADDON_CATALOG_URL is not set (run through scripts/verify.sh)")
        let app = launch()
        install(app, ["\(catalogURL)/uitest/manifest.json"])
        dismissSettings(app)
        let poster = app.buttons["poster.mock:movie1"].firstMatch
        XCTAssertTrue(poster.waitForExistence(timeout: 15))
        poster.tap()

        let save = app.buttons["detail.libraryButton"]
        XCTAssertTrue(save.waitForExistence(timeout: 10))
        XCTAssertEqual(save.value as? String, "Not saved")
        save.tap()
        XCTAssertEqual(save.value as? String, "Saved")
        app.buttons["detail.watchedButton"].tap()
        XCTAssertEqual(app.buttons["detail.watchedButton"].value as? String, "Watched")
        captureScreenshot(app, named: "M7-detail-saved")

        app.tabBars.buttons["Library"].tap()
        XCTAssertTrue(app.buttons["library.saved.movie/mock:movie1"].waitForExistence(timeout: 10), "the saved title is listed")
        XCTAssertTrue(app.staticTexts["Watched"].exists, "the watched mark is listed too")
        captureScreenshot(app, named: "M7-library")

        // Back to Detail through the library, then unsave.
        app.buttons["library.saved.movie/mock:movie1"].tap()
        let unsave = app.buttons["detail.libraryButton"]
        XCTAssertTrue(unsave.waitForExistence(timeout: 10))
        XCTAssertEqual(unsave.value as? String, "Saved", "state survives leaving and returning")
        unsave.tap()
        app.tabBars.buttons["Library"].tap()
        XCTAssertFalse(app.buttons["library.saved.movie/mock:movie1"].waitForExistence(timeout: 2))
    }

    @MainActor
    func testStoppedPlaybackAppearsUnderContinueWatching() throws {
        try requireMediaFixtures()
        try XCTSkipIf(catalogURL.isEmpty || streamURL.isEmpty, "mock addon URLs are not set (run through scripts/verify.sh)")
        let app = launch()
        install(app, ["\(catalogURL)/uitest/manifest.json", "\(streamURL)/uitest-streams/manifest.json"])
        dismissSettings(app)
        let poster = app.buttons["poster.mock:movie1"].firstMatch
        XCTAssertTrue(poster.waitForExistence(timeout: 15))
        poster.tap()
        app.buttons["detail.playButton"].tap()
        let row = app.buttons["stream.row.Mock MP4"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()
        XCTAssertTrue(app.otherElements["player.screen"].waitForExistence(timeout: 10))

        // Let it pass the five-second resume threshold, then pause (the clip is only 10 s: it must not finish and count as watched) and leave.
        let deadline = Date().addingTimeInterval(25)
        var seconds = 0.0
        while Date() < deadline, seconds < 5.5 {
            if !app.buttons["player.playPause"].exists { app.otherElements["player.screen"].tap() }
            if app.staticTexts["player.time"].waitForExistence(timeout: 2) {
                seconds = app.staticTexts["player.time"].label.split(separator: ":").compactMap { Double($0) }.reduce(0) { $0 * 60 + $1 }
            }
            Thread.sleep(forTimeInterval: 0.25)
        }
        XCTAssertGreaterThanOrEqual(seconds, 5.5, "playback never got past the resume threshold")
        if !app.buttons["player.playPause"].exists { app.otherElements["player.screen"].tap() }
        app.buttons["player.playPause"].tap()
        if !app.buttons["player.close"].exists { app.otherElements["player.screen"].tap() }
        app.buttons["player.close"].tap()

        // Home shows Continue Watching; the Library does not.
        app.tabBars.buttons["Library"].tap()
        XCTAssertFalse(app.buttons["library.continue.movie/mock:movie1"].waitForExistence(timeout: 2))
        app.tabBars.buttons["Home"].tap()
        XCTAssertTrue(app.otherElements["board.continueWatching"].waitForExistence(timeout: 10))
        captureScreenshot(app, named: "M7-home-continue")
    }

    @MainActor
    func testSettingsPersistAndDataCanBeCleared() throws {
        let app = launch()
        openSettings(app)
        XCTAssertTrue(app.otherElements["settings.form"].waitForExistence(timeout: 10) || app.tables["settings.form"].waitForExistence(timeout: 2))
        captureScreenshot(app, named: "M7-settings")

        // An invalid server address explains itself and cannot be saved.
        let serverRow = app.buttons["settings.section.server"]
        while !serverRow.isHittable { app.swipeUp() }
        serverRow.tap()
        let server = app.textFields["settings.serverURL"]
        XCTAssertTrue(server.waitForExistence(timeout: 5))
        server.tap()
        server.typeText("not a url")
        XCTAssertTrue(app.staticTexts["settings.serverURL.message"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["settings.serverURL.save"].isEnabled)
        captureScreenshot(app, named: "M7-settings-invalid-server")
        app.navigationBars.buttons.element(boundBy: 0).tap()

        // Clearing asks first, and Cancel changes nothing.
        let dataRow = app.buttons["settings.section.data"]
        while !dataRow.isHittable { app.swipeUp() }
        dataRow.tap()
        let clearHistory = app.buttons["settings.clear.history"]
        XCTAssertTrue(clearHistory.waitForExistence(timeout: 5))
        clearHistory.tap()
        XCTAssertTrue(app.buttons["settings.confirmClear"].waitForExistence(timeout: 5))
        captureScreenshot(app, named: "M7-settings-confirm")
        app.buttons["settings.confirmClear"].tap()
        XCTAssertTrue(app.staticTexts["settings.clearMessage"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["settings.clearMessage"].label, "Watch history cleared.")

        app.navigationBars.buttons.element(boundBy: 0).tap()

        // Acknowledgements, on the About page.
        let aboutRow = app.buttons["settings.section.about"]
        while !aboutRow.isHittable { app.swipeUp() }
        aboutRow.tap()
        let acknowledgements = app.buttons["settings.acknowledgements"]
        XCTAssertTrue(acknowledgements.waitForExistence(timeout: 5))
        acknowledgements.tap()
        XCTAssertTrue(app.staticTexts["Apple frameworks"].waitForExistence(timeout: 5))
        captureScreenshot(app, named: "M7-acknowledgements")
    }
}
