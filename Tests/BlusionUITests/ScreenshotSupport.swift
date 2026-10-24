import XCTest

extension XCTestCase {
    @MainActor
    func openSettings(_ app: XCUIApplication) {
        let settings = app.tabBars.buttons["Settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 10))
        settings.tap()
        XCTAssertTrue(app.buttons["settings.addons"].waitForExistence(timeout: 5))
    }

    @MainActor
    func openAddons(_ app: XCUIApplication) {
        openSettings(app)
        app.buttons["settings.addons"].tap()
        XCTAssertTrue(app.textFields["addons.installField"].waitForExistence(timeout: 5))
    }

    @MainActor
    /// Settings is a tab, so leaving it is a tap on Home. (The name stayed from when it was a sheet.)
    func dismissSettings(_ app: XCUIApplication) {
        let home = app.tabBars.buttons["Home"]
        XCTAssertTrue(home.waitForExistence(timeout: 5))
        home.tap()
    }

    func requireMediaFixtures() throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["BLUSION_HAS_MEDIA_FIXTURES"] != "1",
                      "needs generated media: run Tools/MockAddon/make-fixtures.sh (ffmpeg), then scripts/verify.sh milestone")
    }

    /// Attaches a screenshot to the result bundle and, when `UITEST_SHOT_DIR` is set (verify.sh does this),
    /// also writes `<name>.png` there so milestone screenshots can be reviewed and committed.
    @MainActor
    func captureScreenshot(_ app: XCUIApplication, named name: String) {
        let shot = app.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let dir = ProcessInfo.processInfo.environment["UITEST_SHOT_DIR"] {
            let url = URL(fileURLWithPath: dir).appendingPathComponent("\(name).png")
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? shot.pngRepresentation.write(to: url)
        }
    }
}
