#if canImport(UIKit)
import SwiftUI
import StremioKit

/// Opens a movie or series from a TMDb credit with the existing title page. TMDb's credits carry no IMDb id, so this looks the id up
/// first and then shows `DetailView`, exactly as a card from a catalog would.
struct TMDbTitleView: View {
    let destination: TMDbTitleDestination
    let services: AppServices

    @State private var phase: Phase = .loading

    private enum Phase {
        case loading
        case ready(MetaPreview)
        case unavailable
    }

    var body: some View {
        Group {
            switch phase {
            case .loading:
                Spinner()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .screenBackground()
                    .accessibilityIdentifier("tmdbTitle.loading")
            case .ready(let preview):
                DetailView(preview: preview, services: services)
            case .unavailable:
                EmptyStateView("This title has no page",
                               systemImage: "film",
                               message: "TMDb does not list an IMDb id for it, so there is no page to open. Check the TMDb read token in Settings.")
                    .screenBackground()
                    .accessibilityIdentifier("tmdbTitle.unavailable")
            }
        }
        .task { await resolve() }
    }

    private func resolve() async {
        let settings = await services.settings.load()
        guard let token = settings.tmdbReadToken, !token.isEmpty else {
            phase = .unavailable
            return
        }
        let tmdb = TMDbRatings(client: services.client, readAccessToken: token)
        guard let imdbID = try? await tmdb.imdbID(tmdbID: destination.tmdbID, mediaType: destination.mediaType) else {
            phase = .unavailable
            return
        }
        phase = .ready(MetaPreview(id: imdbID, type: destination.mediaType == "tv" ? "series" : "movie", name: destination.name,
                                   poster: destination.poster, background: destination.backdrop,
                                   releaseInfo: destination.year.map(String.init)))
    }
}
#endif
