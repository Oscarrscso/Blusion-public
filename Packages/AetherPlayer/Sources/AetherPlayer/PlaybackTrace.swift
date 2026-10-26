#if DEBUG && canImport(UIKit)
import AetherEngine
import AVFoundation
import Combine
import Foundation

/// Debug builds only: how the first three minutes of each AetherEngine stream went, a line a second, appended to
/// Library/Caches/playback-trace.log (read off the phone with `devicectl device copy from`). It tells a download falling behind (little
/// ahead, AVPlayer waiting) from frames dropping with plenty in hand, and shows when the start was let through.
@MainActor
final class PlaybackTrace {
    private static let file = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appending(path: "playback-trace.log")
    /// The file keeps its newest half megabyte.
    private static let keptBytes = 512 * 1024
    private static let window: TimeInterval = 180
    private static let writer = DispatchQueue(label: "app.blusion.playback-trace", qos: .utility)

    private var lines: [String] = []
    private var began = ContinuousClock.now
    private var isActive = false
    private var lastDropped: Int?
    private var subscription: AnyCancellable?

    func begin(name: String, start: TimeInterval, engine: AetherEngine) {
        end()
        began = .now
        isActive = true
        lastDropped = nil
        lines.append("--- \(Date().formatted(.iso8601)) \(name) from \(Int(start)) s")
        subscription = engine.diagnostics.$liveTelemetry.compactMap { $0 }.receive(on: RunLoop.main).sink { [weak self, weak engine] telemetry in
            MainActor.assumeIsolated {
                guard let self, let engine else { return }
                self.sample(telemetry, engine: engine)
            }
        }
    }

    func note(_ text: String) {
        guard isActive else { return }
        lines.append(String(format: "%7.2f ", elapsed) + text)
    }

    func end() {
        guard isActive else { return }
        note("end")
        isActive = false
        subscription = nil
        flush()
    }

    private var elapsed: TimeInterval {
        let parts = began.duration(to: .now).components
        return TimeInterval(parts.seconds) + TimeInterval(parts.attoseconds) / 1e18
    }

    private func sample(_ telemetry: LiveTelemetry, engine: AetherEngine) {
        guard isActive else { return }
        guard elapsed <= Self.window else { return end() }
        let player = engine.currentAVPlayer
        let dropped = telemetry.droppedFrameCount
        let newlyDropped = dropped.flatMap { total in lastDropped.map { total - $0 } }
        if let dropped { lastDropped = dropped }
        let status = switch player?.timeControlStatus {
        case .playing: "playing"
        case .paused: "paused"
        case .waitingToPlayAtSpecifiedRate: "waiting"
        default: "-"
        }
        func one(_ value: Double?) -> String { value.map { String(format: "%.1f", $0) } ?? "-" }
        let fields = [
            "pos=" + one(engine.clock.currentTime),
            "ahead=" + one(engine.clock.bufferedPosition - engine.clock.currentTime),
            "phase=\(engine.playbackPhase)",
            "avp=\(status)",
            "wait=" + (player?.reasonForWaitingToPlay?.rawValue ?? "-"),
            "net=" + one(telemetry.networkThroughputMbps),
            "media=" + one(telemetry.instantBitrateMbps),
            "fps=" + one(telemetry.observedFps),
            "dropped=" + (dropped.map(String.init) ?? "-") + "+" + (newlyDropped.map(String.init) ?? "-"),
            "outputs=\(player?.currentItem?.outputs.count ?? 0)",
            "route=\(engine.videoRoute.rawValue)",
            "thermal=\(ProcessInfo.processInfo.thermalState.rawValue)",
            "restarts=\(telemetry.producerRestartCount)",
        ]
        note(fields.joined(separator: " "))
        if lines.count >= 20 { flush() }
    }

    private func flush() {
        guard !lines.isEmpty else { return }
        let text = lines.joined(separator: "\n") + "\n"
        lines = []
        let file = Self.file, kept = Self.keptBytes
        Self.writer.async {
            var data = (try? Data(contentsOf: file)) ?? Data()
            data.append(Data(text.utf8))
            if data.count > kept { data = data.suffix(kept) }
            try? data.write(to: file, options: .atomic)
        }
    }
}
#endif
