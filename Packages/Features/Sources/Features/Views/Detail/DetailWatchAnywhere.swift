import StremioKit
import SwiftUI

/// Where a title can be watched in the viewer's region, from TMDb: the services it streams on, then those it can be rented or bought
/// from. Each logo opens TMDb's page for the title, where the links are.
struct DetailWatchAnywhere: View {
    let watch: TMDbTitleWatch
    let contentMargin: CGFloat
    @Environment(\.layoutMetrics) private var metrics
    @Environment(\.openURL) private var openURL

    private static let logoSize: CGFloat = 72

    /// Each service once: streaming first, then rent and buy.
    private var services: [TMDbWatchService] {
        var seen = Set<Int>()
        return (watch.streaming + watch.rent + watch.buy).filter { seen.insert($0.id).inserted }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: metrics.headerSpacing) {
            SectionHeader("Watch Anywhere")
                .padding(.horizontal, contentMargin)
            ShelfScroll(margin: contentMargin, spacing: metrics.cardSpacing) {
                ForEach(services) { service in
                    Button {
                        Haptics.play(.buttons)
                        if let link = watch.link { openURL(link) }
                    } label: {
                        ArtworkImage(url: service.logo, title: service.name, maxPixelSize: 200, contentMode: .fit)
                            .frame(width: Self.logoSize, height: Self.logoSize)
                            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.small * metrics.cornerScale(for: .artwork),
                                                        style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(service.name)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Watch Anywhere")
    }
}
