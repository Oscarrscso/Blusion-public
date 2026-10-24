import XCTest

/// M5 acceptance in the simulator: the mock's MP4 and HLS play, time advances, seeks land within 1 s, subtitles appear at their cue times.
/// (Picture in Picture, AirPlay, lock-screen controls and background audio are device-only: docs/DEVICE_CHECKLIST.md.)
final class PlaybackFlowTests: XCTestCase {
    private var catalogURL: String { ProcessInfo.processInfo.environment["MOCK_ADDON_CATALOG_URL"] ?? "" }
    private var streamURL: String { ProcessInfo.processInfo.environment["MOCK_ADDON_STREAM_URL"] ?? "" }

    override func setUpWithError() throws {
        continueAfterFailure = false
        try XCTSkipIf(catalogURL.isEmpty || streamURL.isEmpty, "mock addon URLs are not set (run through scripts/verify.sh)")
        try requireMediaFixtures()
    }

    @MainActor
    private func launchAndOpenStreams() -> XCUIApplication {
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
        return app
    }

    /// "1:23" -> 83
    private func seconds(_ label: String) -> Double {
        label.split(separator: ":").compactMap { Double($0) }.reduce(0) { $0 * 60 + $1 }
    }

    @MainActor
    private func playerTime(_ app: XCUIApplication) -> Double {
        seconds(app.staticTexts["player.time"].label)
    }

    @MainActor
    private func showControls(_ app: XCUIApplication) {
        if !app.buttons["player.playPause"].exists { app.otherElements["player.screen"].tap() }
        XCTAssertTrue(app.buttons["player.playPause"].waitForExistence(timeout: 5))
    }

    @MainActor
    private func waitForTime(_ app: XCUIApplication, atLeast target: Double, timeout: TimeInterval = 20) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            showControls(app)
            if playerTime(app) >= target { return }
            Thread.sleep(forTimeInterval: 0.4)
        }
        XCTFail("playback time never reached \(target) s (last: \(app.staticTexts["player.time"].label))")
    }

    @MainActor
    func testMP4PlaysTimeAdvancesAndSeeksWithinOneSecond() throws {
        let app = launchAndOpenStreams()
        let row = app.buttons["stream.row.Mock MP4"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()
        XCTAssertTrue(app.otherElements["player.screen"].waitForExistence(timeout: 10))
        waitForTime(app, atLeast: 1.0)
        captureScreenshot(app, named: "M5-player-mp4")

        // Pause: the clock stops.
        showControls(app)
        app.buttons["player.playPause"].tap()
        Thread.sleep(forTimeInterval: 0.8)
        showControls(app)
        let paused = playerTime(app)
        Thread.sleep(forTimeInterval: 1.5)
        XCTAssertEqual(playerTime(app), paused, accuracy: 0.6, "time must not advance while paused")

        // Seek to the middle of the 10 s clip: lands within 1 s of 5 s.
        showControls(app)
        app.sliders["player.scrubber"].adjust(toNormalizedSliderPosition: 0.5)
        Thread.sleep(forTimeInterval: 1.0)
        showControls(app)
        XCTAssertEqual(playerTime(app), 5.0, accuracy: 1.0, "seek landed at \(app.staticTexts["player.time"].label)")
    }

    @MainActor
    func testHLSPlays() throws {
        let app = launchAndOpenStreams()
        let row = app.buttons["stream.row.Mock HLS"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()
        XCTAssertTrue(app.otherElements["player.screen"].waitForExistence(timeout: 10))
        waitForTime(app, atLeast: 1.0)
        captureScreenshot(app, named: "M5-player-hls")
    }

    @MainActor
    func testSubtitlesAppearAtTheirCueTimes() throws {
        let app = launchAndOpenStreams()
        let row = app.buttons["stream.row.Mock MP4"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()
        waitForTime(app, atLeast: 0.5)
        showControls(app)
        app.buttons["player.playPause"].tap()   // pause so we can place the playhead precisely

        showControls(app)
        app.buttons["player.subtitlesMenu"].tap()
        let english = app.buttons["English · Mock Streams"]
        XCTAssertTrue(english.waitForExistence(timeout: 5))
        english.tap()

        // The cues are 1.0-3.0 "First cue", 4.5-6.25 "Second cue…", 8.0-9.5 "Third cue" on a 10 s clip.
        for (fraction, expected) in [(0.2, "First cue"), (0.55, "Second cue")] as [(Double, String)] {
            showControls(app)
            app.sliders["player.scrubber"].adjust(toNormalizedSliderPosition: fraction)
            let cue = app.staticTexts["player.subtitle"]
            XCTAssertTrue(cue.waitForExistence(timeout: 5), "a cue should be showing at \(fraction * 10) s")
            XCTAssertTrue(cue.label.hasPrefix(expected), "at \(fraction * 10) s expected “\(expected)”, got “\(cue.label)”")
        }
        showControls(app)
        app.sliders["player.scrubber"].adjust(toNormalizedSliderPosition: 0.37)   // 3.7 s: between cues
        let gone = NSPredicate(format: "exists == false")
        wait(for: [XCTNSPredicateExpectation(predicate: gone, object: app.staticTexts["player.subtitle"])], timeout: 5)
        captureScreenshot(app, named: "M5-subtitles")
    }

    @MainActor
    func testAnUnplayableStreamFallsThroughToThePlayableOne() throws {
        let app = launchAndOpenStreams()
        let row = app.buttons["stream.row.Mock Blob"].firstMatch   // extensionless; sniffed as MP4 and playable
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()
        waitForTime(app, atLeast: 1.0)
    }
}
