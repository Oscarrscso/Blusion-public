#if canImport(UIKit)
import SwiftUI
import StremioKit

struct RelatedTitleCard: View {
    let title: TMDbRelatedTitle
    let services: AppServices
    @State private var artwork: TMDbArtwork?
    @Environment(\.layoutMetrics) private var metrics

    var body: some View {
        LandscapeCard(title: title.title, logo: artwork?.logo,
                      artwork: artwork?.textlessBackdrop ?? title.backdrop ?? title.poster,
                      width: metrics.landscapePosterWidth) {
            EmptyView()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title.title)
        .task(id: title.id) {
            artwork = nil
            let settings = await services.settings.load()
            guard let token = settings.tmdbReadToken, !token.isEmpty else { return }
            let loaded = try? await TMDbRatings(client: services.client, readAccessToken: token)
                .artwork(tmdbID: title.tmdbID, mediaType: title.mediaType)
            guard !Task.isCancelled else { return }
            artwork = loaded
        }
    }
}
#endif
