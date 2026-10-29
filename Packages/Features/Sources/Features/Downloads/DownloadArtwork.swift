#if canImport(Darwin)
import Foundation
import ImageIO
import StremioKit

/// The landscape picture a download's card shows: the title's Metahub backdrop, else its poster, which the card crops to 16:9. Both
/// addresses come from the IMDb id, so a download record keeps no picture URL. The picture is cached beside the file (see `DownloadManager`).
enum DownloadArtwork {
    /// The title's IMDb id. An episode's request id is `tt1234567:1:2`, and its series is what has the backdrop.
    static func titleID(_ request: StreamRequest) -> String {
        String(request.id.prefix { $0 != ":" })
    }

    static func backdrop(for request: StreamRequest) -> URL? {
        MetahubArtwork.background(imdbID: titleID(request))
    }

    /// The poster at the smallest size, the same one the cards use. The request's own poster wins over Metahub's.
    static func poster(for request: StreamRequest) -> URL? {
        PosterQuality.smallest(request.poster ?? MetahubArtwork.poster(imdbID: titleID(request)))
    }

    /// What is fetched to cache a download's picture: the backdrop, or the poster when the title has none.
    static func source(for request: StreamRequest) -> URL? {
        backdrop(for: request) ?? poster(for: request)
    }

    /// The picture a card draws, and the one it falls back to: the cached file first, then the backdrop, then the poster. A card with no
    /// cached file yet, or one that has gone missing, still shows artwork when online.
    static func picture(for request: StreamRequest, cached: URL?) -> (url: URL?, fallback: URL?) {
        if let cached { return (cached, backdrop(for: request) ?? poster(for: request)) }
        return (backdrop(for: request) ?? poster(for: request), poster(for: request))
    }

    /// True when `data` is a picture ImageIO can read. A server's error page or a redirect's HTML is never stored as artwork.
    static func isPicture(_ data: Data) -> Bool {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return false }
        return CGImageSourceGetCount(source) > 0
    }
}
#endif
