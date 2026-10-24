import XCTest

/// M8 launch-time baseline. `XCTApplicationLaunchMetric` measures cold launch; Xcode compares each run to the baseline stored for the
/// reference device (Report navigator, Set Baseline) and fails on a regression beyond the allowed deviation. Without a stored baseline
/// the test only records numbers, so the second test is a hard budget that catches order-of-magnitude regressions anywhere
/// (for example network work or a store migration slipping onto the launch path).
final class LaunchPerformanceTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testColdLaunchMetric() {
        let options = XCTMeasureOptions()
        options.iterationCount = 5
        measure(metrics: [XCTApplicationLaunchMetric()], options: options) {
            let app = XCUIApplication()
            app.launchEnvironment["BLUSION_UITEST"] = "1"
            app.launch()
        }
    }

    /// Launch to an interactive first screen, in wall-clock time, with a deliberately generous ceiling (CI simulators are slow).
    @MainActor
    func testFirstScreenIsInteractiveWithinBudget() {
        let app = XCUIApplication()
        app.launchEnvironment["BLUSION_UITEST"] = "1"
        let started = Date()
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["Home"].waitForExistence(timeout: 10))
        let seconds = Date().timeIntervalSince(started)
        XCTAssertLessThan(seconds, 8.0, "launch to the first interactive screen took \(seconds) s")
        let attachment = XCTAttachment(string: String(format: "launch-to-interactive: %.2f s", seconds))
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
