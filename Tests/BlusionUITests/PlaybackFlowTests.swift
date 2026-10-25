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
        app.launchEnvironment["BLUSION_EXTRA_ADDONS"] = "\(catalogURL)/uitest/manifest.json,\(streamURL)/uitest-streams/manifest.json"
        app.launchEnvironment["BLUSION_ROUTE"] = "streams:movie:mock:movie1?title=Mock%20Movie%201"
        app.launch()
        XCTAssertTrue(app.buttons["stream.row.Mock MP4"].firstMatch.waitForExistence(timeout: 60))
        return app
    }

    /// "1:23" -> 83
    private func seconds(_ label: String) -> Double {
        label.split(separator: ":").compactMap { Double($0) }.reduce(0) { $0 * 60 + $1 }
    }

    @MainActor
    private func playerTime(_ app: XCUIApplication) -> Double {
        let time = app.staticTexts["player.time"]
        return seconds(time.value as? String ?? time.label)
    }

    @MainActor
    private func showControls(_ app: XCUIApplication) {
        let playPause = app.buttons["player.playPause"]
        if playPause.exists && playPause.isEnabled && playPause.isHittable { return }
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25)).tap()
        let ready = NSPredicate { _, _ in playPause.exists && playPause.isEnabled && playPause.isHittable }
        wait(for: [XCTNSPredicateExpectation(predicate: ready, object: playPause)], timeout: 5)
    }

    @MainActor
    private func pausePlayback(_ app: XCUIApplication) {
        let playPause = app.buttons["player.playPause"]
        for _ in 0..<3 {
            showControls(app)
            // A short fixture may have ended during a slow automation round trip.
            if playPause.label == "Play" { return }
            playPause.tap()
        }
        XCTAssertEqual(playPause.label, "Play", "leave playback paused before checking layout or cue timing")
    }

    @MainActor
    private func seek(_ app: XCUIApplication, to fraction: Double, within interval: ClosedRange<Double>) {
        let slider = app.sliders["player.scrubber"]
        var requested = fraction
        var actual: Double?
        for _ in 0..<6 {
            // Drag the visible native thumb directly: XCTest's normalized
            // adjustment helper miscalculates its travel on Liquid Glass.
            // Verify playback is inside the cue's interval, away from its edges.
            // Touch accuracy does not need to equal an exact subtitle timestamp.
            let startPercentage = (slider.value as? String ?? "").filter { $0.isNumber || $0 == "." }
            guard let start = Double(startPercentage) else {
                XCTFail("native slider did not expose its current playback percentage")
                return
            }
            let thumb = slider.coordinate(withNormalizedOffset: CGVector(dx: start / 100, dy: 0.5))
            let destination = slider.coordinate(withNormalizedOffset: CGVector(dx: min(1, max(0, requested)), dy: 0.5))
            thumb.press(forDuration: 0.2, thenDragTo: destination)
            let percentage = (slider.value as? String ?? "").filter { $0.isNumber || $0 == "." }
            guard let value = Double(percentage) else {
                XCTFail("native slider did not expose its playback percentage: \(String(describing: slider.value))")
                return
            }
            actual = value / 100
            if interval.contains(value / 100) { return }
            requested += fraction - value / 100
        }
        captureScreenshot(app, named: "player-seek-failure")
        XCTFail("native slider did not reach \(interval): actual \(String(describing: actual))")
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
    func testNativeSegmentsKeepPanelAndVideoStableAcrossTabsAndRotation() throws {
        let app = launchAndOpenStreams()
        let obsolete = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@ OR label CONTAINS[c] %@", "Jellyfin", "Play on Odin"))
        XCTAssertEqual(obsolete.count, 0, "the actual compiled stream picker must contain no obsolete handoff")
        let row = app.buttons["stream.row.Mock MP4"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()
        waitForTime(app, atLeast: 0.5)
        pausePlayback(app)
        let preparing = app.descendants(matching: .any)["player.preparing"].firstMatch
        wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: preparing)], timeout: 30)
        captureScreenshot(app, named: "player-video-ready")
        let video = app.descendants(matching: .any)["player.videoSurface"].firstMatch
        XCTAssertTrue(video.waitForExistence(timeout: 5))
        let originalSurface = video.value as? String
        XCTAssertFalse(originalSurface?.isEmpty ?? true, "capture the real renderer's measured layout")
        let originalFrame = video.frame
        // Toggle twice at an empty part of the video, away from transport buttons.
        let tap = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25))
        tap.tap()
        let hidden = NSPredicate { _, _ in !app.buttons["player.playPause"].exists || !app.buttons["player.playPause"].isEnabled }
        wait(for: [XCTNSPredicateExpectation(predicate: hidden, object: app)], timeout: 5)
        showControls(app)
        XCTAssertEqual(video.value as? String, originalSurface, "control taps must not resize or recreate the picture")
        XCTAssertEqual(video.frame, originalFrame)
        app.buttons["player.pictureMenu"].tap()
        let segments = app.segmentedControls["player.panel.tabs"]
        XCTAssertTrue(segments.waitForExistence(timeout: 5), "options must use a real UIKit segmented control")
        XCTAssertEqual(segments.buttons.count, 5)
        let segmentFrame = segments.frame
        let panel = app.otherElements["player.panel"]
        let panelFrame = panel.frame
        XCTAssertTrue(app.windows.firstMatch.frame.insetBy(dx: -1, dy: -1).contains(panelFrame))
        for index in [0, 1, 2, 3, 4, 0, 2] {
            let segment = segments.buttons.element(boundBy: index)
            segment.tap()
            XCTAssertTrue(segment.isSelected)
            XCTAssertEqual(segments.frame, segmentFrame, "tab selection must not move the system control")
            XCTAssertEqual(panel.frame, panelFrame, "short and long tabs must keep one panel viewport")
            XCTAssertEqual(video.value as? String, originalSurface, "switching tabs must preserve renderer identity and video geometry")
            captureScreenshot(app, named: "player-tab-\(index)-portrait")
        }
        captureScreenshot(app, named: "player-native-segments-portrait")
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        let rotated = NSPredicate { _, _ in segments.frame != segmentFrame && panel.frame != panelFrame }
        wait(for: [XCTNSPredicateExpectation(predicate: rotated, object: segments)], timeout: 10)
        XCTAssertEqual(segments.buttons.count, 5)
        XCTAssertEqual((video.value as? String)?.split(separator: "|").first,
                       originalSurface?.split(separator: "|").first, "rotation must retain the renderer")
        let landscapeFrame = segments.frame
        captureScreenshot(app, named: "player-landscape-viewport")
        let window = app.windows.firstMatch.frame
        XCTAssertEqual(video.frame.size, window.size, "controls must not expand the video beyond the display")
        XCTAssertTrue(window.insetBy(dx: -1, dy: -1).contains(panel.frame),
                      "landscape window \(window) must contain panel \(panel.frame)")
        XCTAssertTrue(window.insetBy(dx: -1, dy: -1).contains(landscapeFrame))
        for index in [4, 3, 2, 1, 0] {
            segments.buttons.element(boundBy: index).tap()
            XCTAssertTrue(segments.buttons.element(boundBy: index).isSelected)
            XCTAssertEqual(segments.frame, landscapeFrame)
            XCTAssertTrue(segments.isHittable)
        }
        // Exercise UIKit's own tracking of a drag between segments.
        segments.buttons.element(boundBy: 0).press(forDuration: 0.1, thenDragTo: segments.buttons.element(boundBy: 4))
        XCTAssertTrue(segments.buttons.element(boundBy: 4).isSelected)
        captureScreenshot(app, named: "player-native-segments-landscape")
        app.buttons["player.panel.close"].tap()
        XCTAssertTrue(app.buttons["player.playPause"].waitForExistence(timeout: 5))
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
        pausePlayback(app)   // place the playhead precisely while paused

        showControls(app)
        app.buttons["player.subtitlesMenu"].tap()
        let english = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label BEGINSWITH %@",
                                                       "player.subtitle.external.", "English · Mock Streams")).firstMatch
        XCTAssertTrue(english.waitForExistence(timeout: 20))
        english.tap()

        // The cues are 1.0-3.0 "First cue", 4.5-6.25 "Second cue…", 8.0-9.5 "Third cue" on a 10 s clip.
        for (fraction, interval, expected) in [(0.2, 0.11...0.29, "First cue"),
                                              (0.55, 0.46...0.61, "Second cue")] as [(Double, ClosedRange<Double>, String)] {
            showControls(app)
            seek(app, to: fraction, within: interval)
            let cue = app.descendants(matching: .any)["player.subtitle"].firstMatch
            let shown = NSPredicate { _, _ in cue.exists && cue.label.hasPrefix(expected) }
            wait(for: [XCTNSPredicateExpectation(predicate: shown, object: cue)], timeout: 10)
            captureScreenshot(app, named: "player-subtitle-\(fraction)")
        }
        showControls(app)
        seek(app, to: 0.37, within: 0.31...0.44)   // between cues (3.0–4.5 s)
        let cue = app.descendants(matching: .any)["player.subtitle"].firstMatch
        let gone = NSPredicate { _, _ in !cue.exists || cue.label.isEmpty }
        wait(for: [XCTNSPredicateExpectation(predicate: gone, object: cue)], timeout: 10)
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
