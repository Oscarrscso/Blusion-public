#if os(iOS)
@preconcurrency import MediaPlayer
import Foundation

/// Lock-screen and Control Center integration: Now Playing info plus play/pause/skip/seek remote commands.
/// UNVERIFIED in the simulator (see docs/DEVICE_CHECKLIST.md).
@MainActor
public final class NowPlayingController {
    public struct Actions {
        public var play: @MainActor () -> Void
        public var pause: @MainActor () -> Void
        public var toggle: @MainActor () -> Void
        public var skip: @MainActor (TimeInterval) -> Void
        public var seek: @MainActor (TimeInterval) -> Void

        public init(play: @escaping @MainActor () -> Void, pause: @escaping @MainActor () -> Void, toggle: @escaping @MainActor () -> Void,
                    skip: @escaping @MainActor (TimeInterval) -> Void, seek: @escaping @MainActor (TimeInterval) -> Void) {
            self.play = play
            self.pause = pause
            self.toggle = toggle
            self.skip = skip
            self.seek = seek
        }
    }

    private let actions: Actions
    private var targets: [(MPRemoteCommand, Any)] = []
    private var title = ""
    private static let skipInterval: TimeInterval = 15

    public init(title: String, actions: Actions) {
        self.title = title
        self.actions = actions
        install()
    }

    public func update(_ state: PlaybackState) {
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: title,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: state.position,
            MPNowPlayingInfoPropertyPlaybackRate: state.isPlaying ? Double(state.rate) : 0.0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
        ]
        if let duration = state.duration { info[MPMediaItemPropertyPlaybackDuration] = duration }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    public func tearDown() {
        for (command, target) in targets { command.removeTarget(target) }
        targets = []
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    private func install() {
        let center = MPRemoteCommandCenter.shared()
        center.skipForwardCommand.preferredIntervals = [NSNumber(value: Self.skipInterval)]
        center.skipBackwardCommand.preferredIntervals = [NSNumber(value: Self.skipInterval)]
        add(center.playCommand) { $0.actions.play() }
        add(center.pauseCommand) { $0.actions.pause() }
        add(center.togglePlayPauseCommand) { $0.actions.toggle() }
        add(center.skipForwardCommand) { $0.actions.skip(Self.skipInterval) }
        add(center.skipBackwardCommand) { $0.actions.skip(-Self.skipInterval) }
        let seek = center.changePlaybackPositionCommand
        seek.isEnabled = true
        targets.append((seek, seek.addTarget { [weak self] event in
            guard let position = (event as? MPChangePlaybackPositionCommandEvent)?.positionTime else { return .commandFailed }
            Task { @MainActor in self?.actions.seek(position) }
            return .success
        }))
    }

    private func add(_ command: MPRemoteCommand, _ action: @escaping @MainActor (NowPlayingController) -> Void) {
        command.isEnabled = true
        targets.append((command, command.addTarget { [weak self] _ in
            Task { @MainActor in if let self { action(self) } }
            return .success
        }))
    }
}
#endif
