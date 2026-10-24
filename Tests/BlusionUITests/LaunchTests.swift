import XCTest

final class LaunchTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testAppLaunchesAndShowsTheTabs() {
        let app = XCUIApplication()
        app.launchEnvironment["BLUSION_UITEST"] = "1"
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
        XCTAssertTrue(app.tabBars.buttons["Home"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.tabBars.buttons["Discover"].exists)
        XCTAssertTrue(app.tabBars.buttons["Library"].exists)
        XCTAssertTrue(app.tabBars.buttons["Search"].exists)
        XCTAssertTrue(app.tabBars.buttons["Settings"].exists)
        captureScreenshot(app, named: "M0-launch")
        for name in ["Discover", "Library", "Settings", "Home"] {
            let tab = app.tabBars.buttons[name]
            tab.tap()
            XCTAssertTrue(tab.isSelected)
            captureScreenshot(app, named: "M0-tab-\(name)")
        }
    }
}
