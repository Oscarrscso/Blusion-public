#if DEBUG
import Features
import Foundation
import PlayerKit
import StremioKit
import UIKit

/// `BLUSION_HANDOFF_PROBE=<log file>` checks the real hand-off to an installed player app: it sends a short public sample clip
/// (Firecore's own test file) through the same code a stream uses, and writes what the player calls back with, and the watch
/// progress that results, to the log. For a developer's one-off check; never part of a normal launch.
@MainActor
enum DebugHandoffProbe {
    private static let sample = "https://files.firecore.com/infuse/sample-5s-360p.mp4"
    private static let request = StreamRequest(type: "movie", id: "tt0000001", title: "Hand-off probe", year: "2026", expectedDuration: 5)

    private static var logURL: URL? {
        ProcessInfo.processInfo.environment["BLUSION_HANDOFF_PROBE"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
    }

    static func startIfRequested(_ services: AppServices) async {
        guard logURL != nil, let stream = URL(string: sample) else { return }
        let player = ExternalPlayer.infuse
        let installed = URL(string: "\(player.scheme)://").map { UIApplication.shared.canOpenURL($0) } ?? false
        let handoff = PlaybackHandoff(request: request, player: player)
        await services.handoffs.save(handoff)
        let name = ExternalPlayerCallback.filename(title: request.title, year: request.year, season: nil, episode: nil, fileExtension: "mp4")
        let link = player.playURL(for: ExternalPlaybackRequest(streamURL: stream, position: 2, filename: name,
                                                               successCallback: ExternalPlayerCallback.successURL(token: handoff.id),
                                                               errorCallback: ExternalPlayerCallback.errorURL(token: handoff.id)))
        log("installed=\(installed) link=\(link?.absoluteString ?? "nil")")
        guard let link else { return }
        let accepted = await UIApplication.shared.open(link)
        log("opened accepted=\(accepted)")
    }

    /// Call after the app handled an incoming URL.
    static func record(_ url: URL, services: AppServices) async {
        guard logURL != nil else { return }
        let progress = await services.progress.progress(for: request.identity)
        log("callback=\(url.absoluteString)")
        log("progress=\(progress.map { "position=\($0.position) duration=\($0.duration) watched=\($0.isWatched)" } ?? "none")")
    }

    private static func log(_ line: String) {
        guard let logURL else { return }
        let existing = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
        try? (existing + line + "\n").write(to: logURL, atomically: true, encoding: .utf8)
    }
}
#endif
