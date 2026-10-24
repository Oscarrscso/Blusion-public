import Foundation
import StremioKit

/// A title an addon lists under its TMDb number ("tmdb:354857", BetterPosters' search does this, or "tmdb:movie:354857") instead of its
/// IMDb id. A title's details, ratings, cast and artwork are all found by IMDb id, so its page opens under the IMDb id, looked up on TMDb
/// the way a credit's title is (see `TMDbTitleView`). Without a TMDb read token, or when TMDb has no IMDb id for it, it opens as it came.
@MainActor
public enum TMDbPreviewResolver {
    /// The TMDb number and media type ("movie" or "tv") of a preview listed under its TMDb number; nil for any other id, and for a bare
    /// "tmdb:<number>" whose type is neither a movie nor a series.
    nonisolated public static func tmdbIdentity(of preview: MetaPreview) -> (tmdbID: Int, mediaType: String)? {
        let parts = preview.id.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard parts.first == "tmdb" else { return nil }
        switch parts.count {
        case 2:
            guard let number = Int(parts[1]), number > 0 else { return nil }
            switch preview.type {
            case "movie": return (number, "movie")
            case "series": return (number, "tv")
            default: return nil
            }
        case 3:
            guard ["movie", "tv"].contains(parts[1]), let number = Int(parts[2]), number > 0 else { return nil }
            return (number, parts[1])
        default:
            return nil
        }
    }

    /// IMDb ids already looked up this session, by media type and TMDb number: TMDb numbers its movies and its series apart, so a movie
    /// and a series can share a number.
    private static var known: [String: String] = [:]

    nonisolated private static func key(_ identity: (tmdbID: Int, mediaType: String)) -> String { "\(identity.mediaType):\(identity.tmdbID)" }

    /// The preview a page can open with at once: the preview itself when it needs no lookup, its IMDb-id copy when one was looked up
    /// already, or nil when it must be looked up first.
    public static func readyPreview(for preview: MetaPreview) -> MetaPreview? {
        guard let identity = tmdbIdentity(of: preview) else { return preview }
        return known[key(identity)].map { renamed(preview, to: $0) }
    }

    /// The preview under its IMDb id, looked up on TMDb; the preview as it came when it is not listed under a TMDb number, when no TMDb read
    /// token is saved, or when TMDb has no IMDb id for it.
    public static func resolve(_ preview: MetaPreview, services: AppServices) async -> MetaPreview {
        guard let identity = tmdbIdentity(of: preview) else { return preview }
        if let imdb = known[key(identity)] { return renamed(preview, to: imdb) }
        let settings = await services.settings.load()
        guard let token = settings.tmdbReadToken, !token.isEmpty,
              let imdb = try? await TMDbRatings(client: services.client, readAccessToken: token)
                .imdbID(tmdbID: identity.tmdbID, mediaType: identity.mediaType)
        else { return preview }
        known[key(identity)] = imdb
        return renamed(preview, to: imdb)
    }

    /// `preview` under `imdbID`, everything else as it came.
    nonisolated static func renamed(_ preview: MetaPreview, to imdbID: String) -> MetaPreview {
        var renamed = preview
        renamed.id = imdbID
        return renamed
    }
}
