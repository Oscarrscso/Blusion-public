import XCTest

/// M4 acceptance: the picker shows its first result before the slowest addon has answered.
final class StreamPickerFlowTests: XCTestCase {
    private var catalogURL: String { ProcessInfo.processInfo.environment["MOCK_ADDON_CATALOG_URL"] ?? "" }
    private var streamURL: String { ProcessInfo.processInfo.environment["MOCK_ADDON_STREAM_URL"] ?? "" }

    override func setUpWithError() throws {
        continueAfterFailure = false
        try XCTSkipIf(catalogURL.isEmpty || streamURL.isEmpty, "mock addon URLs are not set (run through scripts/verify.sh)")
    }

    @MainActor
    private func install(_ app: XCUIApplication, _ url: String) {
        let field = app.textFields["addons.installField"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText(url)
        app.buttons["addons.installButton"].tap()
        XCTAssertTrue(app.staticTexts["addons.success"].waitForExistence(timeout: 15), "installing the mock addon should succeed")
    }

    @MainActor
    func testFirstStreamAppearsBeforeTheSlowestAddonAnswers() throws {
        let app = XCUIApplication()
        app.launchEnvironment["BLUSION_UITEST"] = "1"
        app.launch()
        openAddons(app)
        install(app, "\(catalogURL)/uitest/manifest.json")
        // The slow addon is listed first; the fast one second. The mock delays `flag-slow` resources by 3 s by default.
        install(app, "\(streamURL)/flag-slow/uitest-slow/manifest.json")
        install(app, "\(streamURL)/uitest-fast/manifest.json")

        dismissSettings(app)
        let poster = app.buttons["poster.mock:movie1"].firstMatch
        XCTAssertTrue(poster.waitForExistence(timeout: 15))
        poster.tap()
        XCTAssertTrue(app.buttons["detail.playButton"].waitForExistence(timeout: 10))
        app.buttons["detail.playButton"].tap()

        let firstRow = app.buttons["stream.row.Mock MP4"].firstMatch
        XCTAssertTrue(firstRow.waitForExistence(timeout: 2.5), "the fast addon's stream should show up before the 3 s slow addon answers")
        XCTAssertTrue(app.otherElements["streams.loading"].exists || app.staticTexts["streams.loading"].exists,
                      "…while the picker is still waiting for the slow addon")
        captureScreenshot(app, named: "M4-streams-partial")

        let loading = app.descendants(matching: .any)["streams.loading"]
        let gone = NSPredicate(format: "exists == false")
        wait(for: [XCTNSPredicateExpectation(predicate: gone, object: loading)], timeout: 15)
        XCTAssertTrue(app.buttons["stream.row.Mock HLS"].exists)
        XCTAssertTrue(app.staticTexts["streams.hidden"].exists || app.otherElements["streams.hidden"].exists || app.descendants(matching: .any)["streams.hidden"].exists,
                      "torrent and usenet streams are hidden with an explanation")
        captureScreenshot(app, named: "M4-streams-complete")
    }

    @MainActor
    func testUnsupportedFormatOffersTheNextStream() throws {
        let app = XCUIApplication()
        app.launchEnvironment["BLUSION_UITEST"] = "1"
        app.launch()
        openAddons(app)
        install(app, "\(catalogURL)/uitest/manifest.json")
        install(app, "\(streamURL)/uitest-streams/manifest.json")
        dismissSettings(app)
        let poster = app.buttons["poster.mock:movie1"].firstMatch
        XCTAssertTrue(poster.waitForExistence(timeout: 15))
        poster.tap()
        app.buttons["detail.playButton"].tap()
        let mkv = app.buttons["stream.row.Mock MKV AC3"].firstMatch
        XCTAssertTrue(mkv.waitForExistence(timeout: 10))
        mkv.tap()
        XCTAssertTrue(app.alerts["This format isn't supported yet"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.alerts.buttons["Try the next stream"].exists)
        captureScreenshot(app, named: "M4-unsupported")
    }
}
