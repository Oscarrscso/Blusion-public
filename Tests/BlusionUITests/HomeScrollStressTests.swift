import XCTest

/// Scrolls Home hard, at several speeds and in both directions, and fails when any swipe takes long to finish: a main thread that is
/// spinning inside SwiftUI never goes idle, so XCUITest's wait for the app to settle is what shows it.
///
/// Meant for a real device (`xcodebuild test -destination id=<udid> -only-testing:BlusionUITests/HomeScrollStressTests`): the
/// freeze it hunts appeared in the scroll machinery of the iOS 27 build, not on the Mac. Needs the network, since Home shows the live
/// Cinemeta catalogs. `BLUSION_FAKE_OMDB` answers poster-rating lookups locally, so that path runs without a key.
final class HomeScrollStressTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testScrollingHomeNeverStalls() throws {
        let app = XCUIApplication()
        app.launchEnvironment["BLUSION_UITEST"] = "1"
        app.launchEnvironment["BLUSION_SEED_DEFAULTS"] = "1"
        if ProcessInfo.processInfo.environment["STRESS_REAL_RATINGS_OFF"] != "1" {
            app.launchEnvironment["BLUSION_FAKE_OMDB"] = "1"
        }
        app.launch()

        let rows = app.scrollViews["board.rows"]
        XCTAssertTrue(rows.waitForExistence(timeout: 40), "Home never showed its rows")
        // Let the first catalogs and posters arrive.
        Thread.sleep(forTimeInterval: 4)

        var timings: [String] = []
        var slowest = 0.0

        func timed(_ name: String, _ action: () -> Void) {
            let started = Date()
            action()
            let seconds = Date().timeIntervalSince(started)
            slowest = max(slowest, seconds)
            timings.append(String(format: "%@ %.1fs", name, seconds))
            XCTAssertLessThan(seconds, 12, "\(name) took \(seconds)s: Home stopped responding. Timings: \(timings.joined(separator: ", "))")
        }

        for cycle in 0..<4 {
            for velocity in [XCUIGestureVelocity.slow, .default, .fast] {
                for _ in 0..<5 { timed("up\(cycle)-\(velocity.label)") { rows.swipeUp(velocity: velocity) } }
                Thread.sleep(forTimeInterval: 1.5)   // lets OMDb answers land while the rows are on screen
                // A horizontal swipe along whatever row is on screen, at a few heights.
                for height in [0.35, 0.55, 0.75] {
                    let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: height))
                    let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: height))
                    timed("left\(cycle)-\(height)") { start.press(forDuration: 0.05, thenDragTo: end, withVelocity: velocity, thenHoldForDuration: 0) }
                }
                for _ in 0..<5 { timed("down\(cycle)-\(velocity.label)") { rows.swipeDown(velocity: velocity) } }
            }
        }

        XCTAssertTrue(rows.exists, "Home is still there")
        let report = XCTAttachment(string: "slowest swipe \(slowest)s\n" + timings.joined(separator: "\n"))
        report.lifetime = .keepAlways
        add(report)
    }
}

private extension XCUIGestureVelocity {
    var label: String {
        if self == .slow { return "slow" }
        return self == .fast ? "fast" : "default"
    }
}
