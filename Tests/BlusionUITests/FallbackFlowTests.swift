import XCTest

/// M6 acceptance in the simulator: the mock's MKV files (H.264 + AC3, and H.264 + DTS) play through the fallback engine.
/// Only meaningful in a build made with the opt-in engine: `FALLBACK=1 ./scripts/verify.sh milestone` (ADR-006). Skipped otherwise.
final class FallbackFlowTests: XCTestCase {
    private var catalogURL: String { ProcessInfo.processInfo.environment["MOCK_ADDON_CATALOG_URL"] ?? "" }
    private var streamURL: String { ProcessInfo.processInfo.environment["MOCK_ADDON_STREAM_URL"] ?? "" }

    override func setUpWithError() throws {
        continueAfterFailure = false
        try XCTSkipIf(ProcessInfo.processInfo.environment["BLUSION_FALLBACK"]?.isEmpty ?? true, "built without the fallback engine")
        try XCTSkipIf(catalogURL.isEmpty || streamURL.isEmpty, "mock addon URLs are not set (run through scripts/verify.sh)")
        try requireMediaFixtures()
    }

    @MainActor
    private func openStream(_ name: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["BLUSION_UITEST"] = "1"
        app.launch()
        openAddons(app)
        for url in ["\(catalogURL)/uitest/manifest.json", "\(streamURL)/uitest-streams/manifest.json"] {
            let field = app.textFields["addons.installField"]
            XCTAssertTrue(field.waitForExistence(timeout: 10))
            field.tap()
            field.typeText(url)
            app.buttons["addons.installButton"].tap()
            XCTAssertTrue(app.staticTexts["addons.success"].waitForExistence(timeout: 15))
        }
        dismissSettings(app)
        let poster = app.buttons["poster.mock:movie1"].firstMatch
        XCTAssertTrue(poster.waitForExistence(timeout: 15))
        poster.tap()
        app.buttons["detail.playButton"].tap()
        let row = app.buttons["stream.row.\(name)"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()
        XCTAssertTrue(app.otherElements["player.screen"].waitForExistence(timeout: 10))
        return app
    }

    @MainActor
    private func assertTimeAdvances(_ app: XCUIApplication, shot: String) {
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            if !app.buttons["player.playPause"].exists { app.otherElements["player.screen"].tap() }
            let parts = app.staticTexts["player.time"].label.split(separator: ":").compactMap { Double($0) }
            if parts.reduce(0, { $0 * 60 + $1 }) >= 1.0 {
                captureScreenshot(app, named: shot)
                return
            }
            Thread.sleep(forTimeInterval: 0.4)
        }
        XCTFail("the fallback engine never advanced past 1 s (last: \(app.staticTexts["player.time"].label))")
    }

    @MainActor
    func testMKVWithAC3Plays() throws {
        assertTimeAdvances(openStream("Mock MKV AC3"), shot: "M6-mkv-ac3")
    }

    @MainActor
    func testMKVWithDTSPlays() throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["BLUSION_HAS_DTS_FIXTURE"] != "1", "ffmpeg did not generate the optional DTS fixture")
        assertTimeAdvances(openStream("Mock MKV DTS"), shot: "M6-mkv-dts")
    }
}
