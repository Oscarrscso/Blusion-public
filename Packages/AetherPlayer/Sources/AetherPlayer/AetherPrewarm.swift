#if canImport(UIKit)
import AetherEngine
import Foundation

/// Starts fetching a stream before the player loads it: AetherEngine follows the link's redirects (a debrid link resolves to its file
/// here) and keeps the opening bytes, and the load that follows starts on them (AetherEngine #551).
///
/// The engine's load does not wait for a warm still under way, so `AetherSession.load` waits for it here, for a while: the load would
/// make the same requests itself.
@MainActor
public enum AetherPrewarm {
    /// The header and the first stretch of the picture: enough to start on, small enough to arrive quickly on a slow link.
    static let byteBudget = 4 << 20
    /// How long a load waits for a warm still under way before it goes to the network itself.
    static let longestWait: Duration = .seconds(4)

    private static var running: [URL: Task<Void, Never>] = [:]

    static func isWarming(_ url: URL) -> Bool { running[url] != nil }

    /// Starts warming `url`, sent with `headers` exactly as the load will send them. Nothing happens when it is warm or warming already.
    public static func start(url: URL, headers: [String: String]) {
        guard running[url] == nil, !AetherEngine.isPrewarmed(url: url) else { return }
        let budget = byteBudget
        let task = Task.detached(priority: .userInitiated) {
            _ = await AetherEngine.prewarm(url: url, httpHeaders: headers, byteBudget: budget)
        }
        running[url] = task
        Task {
            await task.value
            if running[url] == task { running[url] = nil }
        }
    }

    /// Returns once the warm of `url` is done, or after `longestWait`, or at once when nothing is warming it.
    static func waitForWarm(of url: URL) async {
        guard let task = running[url] else { return }
        let limit = longestWait
        // A task group's cancellation cannot interrupt a child awaiting another task's value: the old race still waited for
        // the warm after its timeout. Finishing this stream releases the load immediately on timeout or caller cancellation.
        let waiting = AsyncStream<Void> { continuation in
            let completion = Task { await task.value; continuation.finish() }
            let timeout = Task {
                do { try await Task.sleep(for: limit) } catch { return }
                continuation.finish()
            }
            continuation.onTermination = { _ in completion.cancel(); timeout.cancel() }
        }
        for await _ in waiting { }
    }
}
#endif
