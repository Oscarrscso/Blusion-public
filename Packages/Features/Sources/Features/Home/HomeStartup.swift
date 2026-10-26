import Foundation

/// Whether Home has finished its first load since launch. Large background downloads (the IMDb ratings dataset) wait for it, so on a
/// fresh install they do not compete with Home's rows for the connection and the processor.
@MainActor
public final class HomeStartup {
    public static let shared = HomeStartup()

    public private(set) var isSettled = false

    private init() {}

    /// Home's rows have all answered once (or Home has nothing to load).
    func markSettled() {
        isSettled = true
    }

    /// Returns once Home has settled, or after `limit`, whichever comes first, so a Home that never opens holds nothing up for long.
    public func waitUntilSettled(limit: Duration = .seconds(30)) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: limit)
        while !isSettled, clock.now < deadline, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(250))
        }
    }
}
