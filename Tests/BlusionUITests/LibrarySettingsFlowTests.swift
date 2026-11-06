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
        XCTAssertTrue(app.descendants(matching: .any)["settings.form"].firstMatch.waitForExistence(timeout: 10))
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
        // iOS 27's popover lists its button twice, so the first is the one tapped.
        let confirm = app.buttons["settings.confirmClear"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        captureScreenshot(app, named: "M7-settings-confirm")
        confirm.tap()
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

    /// Every Settings page opens from its row and shows its own controls, the pages opened from a page open too, and each goes back.
    @MainActor
    func testEverySettingsPageOpens() throws {
        let app = launch()
        openSettings(app)
        func element(_ id: String) -> XCUIElement { app.descendants(matching: .any)[id].firstMatch }
        func open(_ id: String, showing shown: String) {
            let row = element(id)
            var swipes = 0
            while !row.isHittable && swipes < 8 { app.swipeUp(); swipes += 1 }
            XCTAssertTrue(row.isHittable, "\(id) is not on the page")
            row.tap()
            // A page may open on something tall (Appearance's preview), with the control below the screen.
            var found = element(shown).waitForExistence(timeout: 5)
            swipes = 0
            while !found && swipes < 3 { app.swipeUp(); swipes += 1; found = element(shown).waitForExistence(timeout: 2) }
            XCTAssertTrue(found, "\(id) did not show \(shown)")
            captureScreenshot(app, named: "settings-page-\(id)")
        }
        func back() { app.navigationBars.buttons.element(boundBy: 0).tap() }

        open("settings.addons", showing: "addons.installField"); back()
        open("settings.section.server", showing: "settings.serverURL"); back()

        open("settings.section.playback", showing: "settings.resolution")
        XCTAssertTrue(element("settings.autoPlay").exists)
        XCTAssertFalse(element("settings.subtitleLanguage").exists, "subtitle language belongs to Player only")
        open("settings.section.addonSpeed", showing: "settings.addonSpeed.test"); back()
        back()

        open("settings.section.player", showing: "settings.player")
        XCTAssertTrue(element("settings.player.subtitleLanguage").exists)
        open("settings.player.openSubtitles", showing: "settings.opensubtitles.key"); back()
        back()

        open("settings.section.downloads", showing: "settings.downloads.deleteWatched"); back()

        open("settings.section.appearance", showing: "settings.appearance.colour")
        open("settings.appearance.colour", showing: "settings.appearance.accent"); back()
        back()
        open("settings.widgets", showing: "widgets.add"); back()

        open("settings.section.haptics", showing: "settings.haptics.enabled")
        open("settings.haptics.place.buttons", showing: "settings.haptics.buttons.enabled"); back()
        open("settings.haptics.place.playerControls", showing: "settings.haptics.playerControls.enabled"); back()
        back()

        open("settings.trakt", showing: "trakt.signIn"); back()
        open("settings.section.reviews", showing: "settings.omdbUsage")
        app.swipeUp()
        XCTAssertTrue(element("settings.imdbDataset").waitForExistence(timeout: 5), "Ratings has no IMDb section")
        back()
        open("settings.section.optimisation", showing: "settings.lazyLoadLookahead"); back()
        open("settings.section.data", showing: "settings.clear.everything"); back()
        open("settings.section.about", showing: "settings.acknowledgements"); back()
        captureScreenshot(app, named: "settings-root")
    }

    /// Each Appearance preset can be chosen by its app's name, and the picker then reads it.
    @MainActor
    func testEveryAppearancePresetApplies() throws {
        let app = launch()
        openSettings(app)
        let row = app.buttons["settings.section.appearance"]
        var swipes = 0
        while !row.isHittable && swipes < 6 { app.swipeUp(); swipes += 1 }
        row.tap()
        // The page opens on its preview; the preset menu is below it.
        let picker = app.buttons["settings.appearance.preset"].firstMatch
        XCTAssertTrue(app.buttons["settings.appearance.preview"].firstMatch.waitForExistence(timeout: 5))
        for name in ["Netflix", "Apple TV", "Disney+", "Prime Video", "Letterboxd", "Plex", "Arthouse", "Original"] {
            swipes = 0
            while !(picker.exists && picker.isHittable) && swipes < 4 { app.swipeUp(); swipes += 1 }
            XCTAssertTrue(picker.isHittable, "no preset menu")
            picker.tap()
            let choice = app.buttons[name].firstMatch
            XCTAssertTrue(choice.waitForExistence(timeout: 5), "no \(name) preset")
            choice.tap()
            // A look can make the preview taller, so the menu may now sit below the screen.
            swipes = 0
            while !picker.waitForExistence(timeout: 2) && swipes < 4 { app.swipeUp(); swipes += 1 }
            XCTAssertTrue(picker.exists, "the preset menu went missing after \(name)")
            XCTAssertTrue(picker.label.contains(name) || (picker.value as? String)?.contains(name) == true, "picker does not read \(name)")
            app.swipeDown()
            app.swipeDown()
            captureScreenshot(app, named: "preset-\(name)")
        }
    }

    /// Pulling Settings down and holding it for two seconds turns Ghost mode on; its banner's Turn Off turns it off.
    @MainActor
    func testGhostModeTurnsOnAndOffFromSettings() throws {
        let app = launch()
        openSettings(app)
        let banner = app.descendants(matching: .any)["settings.ghost"].firstMatch
        if banner.exists { app.buttons["settings.ghost.off"].tap() }
        XCTAssertFalse(banner.waitForExistence(timeout: 2))
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7))
        start.press(forDuration: 0.1, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 3)
        XCTAssertTrue(banner.waitForExistence(timeout: 5), "the held pull did not turn Ghost mode on")
        captureScreenshot(app, named: "ghost-on")
        app.buttons["settings.ghost.off"].tap()
        XCTAssertTrue(banner.waitForNonExistence(timeout: 5), "Turn Off did not turn Ghost mode off")
    }
}
