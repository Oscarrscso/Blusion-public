#if DEBUG
import Features
import Foundation
import PlayerKit
import StremioKit

/// `BLUSION_DEMO_DATA=1` fills the library and watch history with a few well-known titles, so Library, Continue Watching and
/// Detail have something to show in a `scripts/snapshot.sh` picture. Only meant for the in-memory stores of a snapshot run.
enum DebugDemoData {
    /// `BLUSION_EXTRA_ADDONS=<link>[,<link>…]` installs more addons for one run, so a snapshot can show real streams. The links
    /// come from the environment only: with the in-memory stores of a snapshot run they are never written anywhere.
    static func installExtraAddons(_ services: AppServices, environment: [String: String] = ProcessInfo.processInfo.environment) async {
        for link in (environment["BLUSION_EXTRA_ADDONS"] ?? "").split(separator: ",") {
            _ = try? await services.registry.install(from: String(link))
        }
    }

    static func seedIfRequested(_ services: AppServices, environment: [String: String] = ProcessInfo.processInfo.environment) async {
        guard environment["BLUSION_DEMO_DATA"] == "1" else { return }
        func poster(_ id: String) -> URL? { URL(string: "https://images.metahub.space/poster/medium/\(id)/img") }
        let now = Date()
        let inProgress: [(id: String, type: String, content: String, title: String, at: Double, of: Double, season: Int?, episode: Int?)] = [
            ("movie/tt1375666", "movie", "tt1375666", "Inception", 3120, 8880, nil, nil),
            ("series/tt0903747:2:5", "series", "tt0903747:2:5", "Breaking Bad · Breakage", 1260, 2820, 2, 5),
            ("movie/tt0816692", "movie", "tt0816692", "Interstellar", 7400, 10140, nil, nil),
        ]
        for (index, item) in inProgress.enumerated() {
            let base = item.content.split(separator: ":").first.map(String.init) ?? item.content
            await services.progress.save(WatchProgress(id: item.id, type: item.type, contentID: item.content, title: item.title, poster: poster(base),
                                                       position: item.at, duration: item.of, isWatched: false,
                                                       updatedAt: now.addingTimeInterval(-Double(index) * 3600), season: item.season, episode: item.episode))
        }
        await services.progress.save(WatchProgress(id: "movie/tt0468569", type: "movie", contentID: "tt0468569", title: "The Dark Knight", poster: poster("tt0468569"),
                                                   position: 0, duration: 9120, isWatched: true, updatedAt: now.addingTimeInterval(-86_400)))
        let saved: [(id: String, type: String, name: String, year: String)] = [
            ("tt15398776", "movie", "Oppenheimer", "2023"), ("tt0944947", "series", "Game of Thrones", "2011–2019"),
            ("tt1160419", "movie", "Dune", "2021"), ("tt2861424", "series", "Rick and Morty", "2013–"),
            ("tt0111161", "movie", "The Shawshank Redemption", "1994"),
        ]
        for (index, item) in saved.enumerated() {
            await services.library.add(LibraryItem(preview: MetaPreview(id: item.id, type: item.type, name: item.name, poster: poster(item.id), releaseInfo: item.year),
                                                   addedAt: now.addingTimeInterval(-Double(index) * 7200)))
        }
    }
}
#endif
