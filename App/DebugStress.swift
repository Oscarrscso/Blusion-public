#if DEBUG
import Foundation
import UIKit

/// Debug-only tools for reproducing a scroll freeze without a hand on the screen.
///
/// - `BLUSION_AUTOSCROLL=1`: ten seconds after launch, scrolls Home by itself at random, in short and long moves, down the page and
///   along whichever rows are on screen.
/// - `BLUSION_HANG_MARKER=<file>`: a background timer asks the main thread to answer every half second and writes `<file>` when it has
///   not for five seconds, so a script knows to take a sample of the stuck process.
enum DebugStress {
    /// Each scroll the driver makes is appended here (the marker's path plus `.log`), so a run can show that it really scrolled.
    @MainActor private static var logPath: String?

    @MainActor
    static func startIfRequested(environment: [String: String] = ProcessInfo.processInfo.environment) {
        if let path = environment["BLUSION_HANG_MARKER"], !path.isEmpty {
            logPath = path + ".log"
            MainThreadWatchdog.shared.start(markerPath: path)
        }
        guard environment["BLUSION_AUTOSCROLL"] == "1" else { return }
        Task { @MainActor in await autoscroll() }
    }

    @MainActor
    private static func log(_ line: String) {
        guard let logPath, let data = (line + "\n").data(using: .utf8) else { return }
        if let handle = FileHandle(forWritingAtPath: logPath) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            FileManager.default.createFile(atPath: logPath, contents: data)
        }
    }

    @MainActor
    private static func autoscroll() async {
        try? await Task.sleep(for: .seconds(10))
        while true {
            let window = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows).first { $0.isKeyWindow }
            guard let window else {
                try? await Task.sleep(for: .seconds(1))
                continue
            }
            let scrollViews = Self.scrollViews(in: window)
            let vertical = scrollViews
                .filter { $0.contentSize.height > $0.bounds.height + 50 && $0.bounds.width > window.bounds.width * 0.8 }
                .max { $0.contentSize.height < $1.contentSize.height }
            let rows = scrollViews.filter { row in
                row.contentSize.width > row.bounds.width + 50 && row.contentSize.height <= row.bounds.height + 8
                    && window.bounds.intersects(row.convert(row.bounds, to: window))
            }
            if Int.random(in: 0..<10) < 5, let vertical {
                let minY = -vertical.adjustedContentInset.top
                let maxY = max(minY, vertical.contentSize.height - vertical.bounds.height + vertical.adjustedContentInset.bottom)
                let y = min(max(vertical.contentOffset.y + CGFloat.random(in: -500...900), minY), maxY)
                log("\(Date()) vertical y=\(Int(vertical.contentOffset.y))->\(Int(y)) of \(Int(maxY)); scrollviews=\(scrollViews.count) rows=\(rows.count)")
                vertical.setContentOffset(CGPoint(x: vertical.contentOffset.x, y: y), animated: true)
            } else if let row = rows.randomElement() {
                let maxX = max(0, row.contentSize.width - row.bounds.width)
                let x = CGFloat.random(in: 0...maxX)
                log("\(Date()) row x=\(Int(row.contentOffset.x))->\(Int(x)) of \(Int(maxX)); scrollviews=\(scrollViews.count) rows=\(rows.count)")
                row.setContentOffset(CGPoint(x: x, y: row.contentOffset.y), animated: true)
            } else {
                log("\(Date()) nothing to scroll; scrollviews=\(scrollViews.count) vertical=\(vertical != nil) rows=\(rows.count)")
            }
            try? await Task.sleep(for: .milliseconds(Int.random(in: 250...900)))
        }
    }

    @MainActor
    private static func scrollViews(in view: UIView) -> [UIScrollView] {
        var found: [UIScrollView] = []
        if let scroll = view as? UIScrollView { found.append(scroll) }
        for child in view.subviews { found += scrollViews(in: child) }
        return found
    }
}

/// Answers "is the main thread still running?" from a background timer.
final class MainThreadWatchdog: @unchecked Sendable {
    static let shared = MainThreadWatchdog()
    private let lock = NSLock()
    private var lastAnswer = Date()
    private var reported = false
    private var timer: DispatchSourceTimer?

    func start(markerPath: String) {
        lock.withLock { lastAnswer = Date() }
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "debug.main-thread-watchdog"))
        timer.schedule(deadline: .now() + 2, repeating: 0.5)
        timer.setEventHandler { [self] in
            DispatchQueue.main.async { [self] in lock.withLock { lastAnswer = Date() } }
            let silent = lock.withLock { Date().timeIntervalSince(lastAnswer) }
            let first = lock.withLock { () -> Bool in
                guard silent > 5, !reported else { return false }
                reported = true
                return true
            }
            if first { try? "main thread silent for \(silent) s at \(Date())".write(toFile: markerPath, atomically: true, encoding: .utf8) }
        }
        timer.resume()
        self.timer = timer
    }
}
#endif
