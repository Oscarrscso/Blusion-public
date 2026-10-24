import Foundation
import StremioKit

/// The poster of a title at the one size every card and the title page's stand-in share, so a title's poster is downloaded once. Metahub's
/// posters are the English ones and come in three sizes; TMDb's come in several. This only rewrites the URL: no request is made, and a URL
/// it does not know is returned as it came.
enum PosterQuality {
    /// TMDb's poster sizes are w92, w154, w185, w342, w500, w780 and original. w154 was the old floor, too soft for a hero's stand-in on a 3x
    /// phone, so w342 is the floor now.
    static let tmdbSize = "w342"
    static let metahubSize = "medium"

    /// `url` at the smallest usable poster size. Only poster URLs change; a background, a logo or an unknown host is returned as it is.
    static func smallest(_ url: URL?) -> URL? {
        guard let url, var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let host = components.host?.lowercased() else { return url }
        var parts = components.path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        switch host {
        case "images.metahub.space":
            // /poster/<size>/<id>/img
            guard parts.count == 5, parts[0].isEmpty, parts[1] == "poster", parts[4] == "img" else { return url }
            parts[2] = metahubSize
        case "image.tmdb.org":
            // /t/p/<size>/<file>
            guard parts.count == 5, parts[0].isEmpty, parts[1] == "t", parts[2] == "p" else { return url }
            parts[3] = tmdbSize
        default:
            return url
        }
        components.path = parts.joined(separator: "/")
        return components.url ?? url
    }

    /// The poster a card shows for `item`, and the title page's stand-in until its picture is ready: its own, or Metahub's for its IMDb id,
    /// at the smallest size.
    static func poster(for item: MetaPreview) -> URL? {
        smallest(item.poster ?? MetahubArtwork.poster(imdbID: item.id))
    }

    /// A landscape picture (a wide card's or a row's backdrop) at the size the Mac draws it. On the Mac, TMDb's original and w1280 pictures
    /// become w780, so a Home full of wide cards downloads and decodes less. iPhone keeps the picture as it came. Only the URL changes.
    static func landscape(_ url: URL?) -> URL? {
        #if targetEnvironment(macCatalyst)
        return smallerLandscape(url)
        #else
        return url
        #endif
    }

    /// The Mac's size for a landscape picture: TMDb's original and w1280 become w780. Any other address is returned as it came.
    static func smallerLandscape(_ url: URL?) -> URL? {
        guard let url, url.host?.lowercased() == "image.tmdb.org" else { return url }
        let text = url.absoluteString
            .replacingOccurrences(of: "/t/p/original/", with: "/t/p/w780/")
            .replacingOccurrences(of: "/t/p/w1280/", with: "/t/p/w780/")
        return URL(string: text) ?? url
    }
}
