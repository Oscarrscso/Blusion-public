import Foundation
import PlayerKit
import StremioKit

/// Delivered after a known callback has been consumed, including saves and failures that do not change watch progress.
struct PlaybackHandoffReceipt: Sendable {
    let handoff: PlaybackHandoff
    let result: ExternalPlaybackResult
}

extension Notification.Name {
    static let playbackHandoffDidFinish = Notification.Name("Blusion.playbackHandoffDidFinish")
}

/// Turns a player app's callback into watch progress: where the viewer stopped becomes their resume point, and a stop near the end
/// of a title with a known length marks it watched.
public struct PlaybackHandoffCenter: Sendable {
    private let services: AppServices
    private let now: @Sendable () -> Date

    public init(services: AppServices, now: @escaping @Sendable () -> Date = { Date() }) {
        self.services = services
        self.now = now
    }

    /// Handles one of Blusion's callback URLs. Returns false for any other URL (the caller may then try other handlers).
    @discardableResult
    public func handle(_ url: URL) async -> Bool {
        guard let callback = ExternalPlayerCallback.parse(url) else { return false }
        // Taken in every case, so one callback is recorded at most once. A token Blusion does not know was never its hand-off.
        guard let handoff = await services.handoffs.take(id: callback.token) else { return true }
        if handoff.isPlayback, case .finished(let stoppedAt) = callback.result, let position = stoppedAt, position >= 0 {
            await record(position: position, for: handoff)
        }
        let receipt = PlaybackHandoffReceipt(handoff: handoff, result: callback.result)
        await MainActor.run {
            NotificationCenter.default.post(name: .playbackHandoffDidFinish, object: receipt)
        }
        return true
    }

    private func record(position: TimeInterval, for handoff: PlaybackHandoff) async {
        let request = handoff.request
        let previous = await services.progress.progress(for: request.identity)
        // A callback must not undo a more recent local watch/unwatch or playback session.
        if let previous, previous.updatedAt > handoff.startedAt { return }
        // A measured runtime is more accurate than the addon's estimate. Zero and invalid lengths remain unknown.
        let duration = [previous?.duration, request.expectedDuration].compactMap { $0 }.first { $0.isFinite && $0 > 0 } ?? 0
        let reachedEnd = duration > 0 && position / duration >= ProgressPolicy.default.watchedThreshold
        let record = WatchProgress(id: request.identity, type: request.type, contentID: request.id, title: request.title, poster: request.poster,
                                   position: position, duration: duration, isWatched: reachedEnd || previous?.isWatched == true,
                                   updatedAt: now(), season: request.season, episode: request.episode)
        await services.progress.save(record)
    }
}
