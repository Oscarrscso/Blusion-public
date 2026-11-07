#if canImport(UIKit)
import StremioKit
import SwiftUI

/// `RowLayout.snapshots`: instant photos of the titles' stills, each in its paper frame with the name written in the deep border under
/// the picture, leaning this way and that, some held on with a strip of tape. A photo develops as it first comes on screen, from a murky
/// brown to its colours, and the photos sway a little as the row scrolls. With Reduce Motion they are developed already and stand still.
struct SnapshotsLayout: View {
    let items: [MetaPreview]
    @Environment(\.layoutMetrics) private var metrics
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The photos that have developed, so one scrolled back to stays developed.
    @State private var developed: Set<String> = []

    static func pictureWidth(_ metrics: LayoutMetrics) -> CGFloat { (metrics.posterWidth * 1.45).rounded() }
    /// The wide film's picture: about 1.6 times as wide as it is tall.
    static func pictureHeight(_ metrics: LayoutMetrics) -> CGFloat { (pictureWidth(metrics) / 1.6).rounded() }
    /// The frame's border at the sides and top.
    static func border(_ metrics: LayoutMetrics) -> CGFloat { max(6, (pictureWidth(metrics) * 0.055).rounded()) }
    /// The deeper border at the foot, where the name is written.
    static func foot(_ metrics: LayoutMetrics) -> CGFloat { (pictureWidth(metrics) * 0.24).rounded() }
    /// Room above and below each photo for its lean, its sway and its tape.
    static let margin: CGFloat = 18
    static func height(_ metrics: LayoutMetrics) -> CGFloat { border(metrics) + pictureHeight(metrics) + foot(metrics) + margin * 2 }

    var body: some View {
        ShelfScroll(margin: metrics.pageMargin, spacing: metrics.cardSpacing) {
            ForEach(Array(items.enumerated()), id: \.element.identity) { index, item in
                SnapshotCard(item: item, leansLeft: index.isMultiple(of: 2), isDeveloped: reduceMotion || developed.contains(item.identity))
                    .onAppear { develop(item.identity) }
                    .reportsShelfEdge(id: item.identity)
            }
        }
    }

    private func develop(_ id: String) {
        guard !reduceMotion, !developed.contains(id) else { return }
        withAnimation(.easeOut(duration: 2.2).delay(0.2)) { _ = developed.insert(id) }
    }
}

private struct SnapshotCard: View {
    let item: MetaPreview
    let leansLeft: Bool
    let isDeveloped: Bool
    /// True once the photo has finished developing, so it is drawn without the film's filter and its murky layer.
    @State private var isSettled: Bool
    @Environment(\.layoutMetrics) private var metrics
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.displayScale) private var displayScale

    init(item: MetaPreview, leansLeft: Bool, isDeveloped: Bool) {
        self.item = item
        self.leansLeft = leansLeft
        self.isDeveloped = isDeveloped
        _isSettled = State(initialValue: isDeveloped)
    }

    private static let paper = LinearGradient(colors: [Color(white: 0.97), Color(white: 0.89)], startPoint: .top, endPoint: .bottom)
    /// The name's ink: a ballpoint blue.
    private static let ink = Color(red: 0.12, green: 0.16, blue: 0.36)

    private var still: URL? {
        PosterQuality.landscape(item.background) ?? MetahubArtwork.background(imdbID: item.id) ?? PosterQuality.poster(for: item)
    }

    /// A number of the photo's own, the same each time, for its lean and its tape.
    private var seed: Int { item.identity.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF } }

    var body: some View {
        let width = SnapshotsLayout.pictureWidth(metrics)
        let border = SnapshotsLayout.border(metrics)
        let seed = self.seed
        // Between 1.5 and 4.4 degrees, alternate photos leaning opposite ways; the sway adds up to 3 more at the row's edges.
        let lean = (1.5 + Double(seed % 30) / 10) * (leansLeft ? -1 : 1)
        let sway: Double = reduceMotion ? 0 : 3
        LayoutTitleLink(item: item, cornerRadius: 2) {
            VStack(spacing: 0) {
                picture(width: width, height: SnapshotsLayout.pictureHeight(metrics))
                caption
                    .frame(width: width, height: SnapshotsLayout.foot(metrics))
            }
            .padding([.top, .horizontal], border)
            .background(Self.paper)
        }
        // One shadow for the whole photo, not one for each of its layers.
        .compositingGroup()
        .shadow(color: .black.opacity(0.45), radius: 6, y: 3)
        .overlay(alignment: .top) {
            // Two photos in three are taped on.
            if seed % 3 != 0 { tape(width: width, seed: seed) }
        }
        .scrollTransition(.interactive, axis: .horizontal) { content, phase in
            content.rotationEffect(.degrees(lean + phase.value * sway))
        }
        .padding(.vertical, SnapshotsLayout.margin)
        .task(id: isDeveloped) {
            // The development runs 2.4 seconds; after it the film's effects leave the drawing.
            guard isDeveloped, !isSettled else { return }
            try? await Task.sleep(for: .seconds(2.6))
            guard !Task.isCancelled else { return }
            isSettled = true
        }
    }

    /// The still, murky brown and without colour until it develops.
    private func picture(width: CGFloat, height: CGFloat) -> some View {
        Color.clear
            .frame(width: width, height: height)
            .overlay {
                ArtworkImage(url: still, title: item.name, maxPixelSize: min((width * displayScale).rounded(.up), 1200))
            }
            .clipped()
            .modifier(UndevelopedFilm(isDeveloped: isDeveloped, isActive: !isSettled))
            .overlay {
                // The film's own faint warmth, which stays.
                LinearGradient(colors: [.orange.opacity(0.08), .clear, .teal.opacity(0.05)], startPoint: .topLeading, endPoint: .bottomTrailing)
                    .allowsHitTesting(false)
            }
    }

    /// The name, written by hand.
    private var caption: some View {
        Text(item.name)
            .font(.custom("Noteworthy-Bold", size: 15, relativeTo: .subheadline))
            .foregroundStyle(Self.ink)
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .padding(.horizontal, Theme.Spacing.xs)
            .accessibilityHidden(true)
    }

    /// A strip of translucent tape across the photo's top edge, at an angle and a place of its own.
    private func tape(width: CGFloat, seed: Int) -> some View {
        RoundedRectangle(cornerRadius: 1.5, style: .continuous)
            .fill(Color(white: 0.94).opacity(0.6))
            .frame(width: (width * 0.3).rounded(), height: 18)
            .shadow(color: .black.opacity(0.15), radius: 1, y: 0.5)
            .rotationEffect(.degrees(seed.isMultiple(of: 2) ? -7 : 6))
            .offset(x: CGFloat(seed % 5 - 2) * 8, y: -9)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// A photo's film before it has developed: without colour under a murky brown, both clearing as `isDeveloped` turns true. Left out once
/// the photo has settled, so a developed photo carries no filter.
private struct UndevelopedFilm: ViewModifier {
    let isDeveloped: Bool
    let isActive: Bool

    /// The murky brown an undeveloped photo starts as.
    private static let undeveloped = Color(red: 0.22, green: 0.18, blue: 0.14)

    @ViewBuilder
    func body(content: Content) -> some View {
        if isActive {
            content
                .saturation(isDeveloped ? 1 : 0)
                .overlay {
                    Self.undeveloped
                        .opacity(isDeveloped ? 0 : 0.94)
                        .allowsHitTesting(false)
                }
        } else {
            content
        }
    }
}
#endif
