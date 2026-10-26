import Foundation
import StremioKit

/// Connects `ProgressRecorder` to a `ProgressStore`: saves every 10 s while playing and on exit.
@MainActor
public final class ProgressSession {
    private var recorder: ProgressRecorder
    private let store: any ProgressStore
    private let clock: @Sendable () -> Date
    private var pendingSaves: [Task<Void, Never>] = []
    /// False while a player is readied before its screen shows (see `PlayerViewModel.prepare`): nothing is saved, so a stream loaded
    /// in the background and never watched leaves no Continue Watching entry and nothing for Trakt.
    public var isRecording = true

    public init(request: StreamRequest, previous: WatchProgress?, store: any ProgressStore, policy: ProgressPolicy = .default,
                clock: @escaping @Sendable () -> Date = Date.init) {
        self.recorder = ProgressRecorder(request: request, previous: previous, policy: policy)
        self.store = store
        self.clock = clock
    }

    public func observe(position: TimeInterval, duration: TimeInterval?) {
        guard isRecording else { return }
        guard let record = recorder.observe(position: position, duration: duration, now: clock()) else { return }
        save(record)
    }

    /// Writes the final position. Call when playback stops or the player is dismissed.
    public func finish() async {
        if isRecording, let record = recorder.finish(now: clock()) { save(record) }
        for task in pendingSaves { await task.value }
        pendingSaves = []
    }

    private func save(_ record: WatchProgress) {
        let store = self.store
        pendingSaves.append(Task { await store.save(record) })
    }
}
