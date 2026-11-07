#if canImport(UIKit)
import StremioKit
import SwiftUI

/// `RowLayout.deck`: a pile of posters, each under the top one standing a little further out and turned by an angle of its own, with
/// the top one's logo, details and synopsis beside them. Flicking the top poster either way throws it off and slides it under the pile,
/// bringing the next one up; the buttons under the details do the same, or bring the last one back. The top poster opens its title.
struct DeckLayout: View {
    let items: [MetaPreview]
    let showsRating: Bool
    @Environment(\.layoutMetrics) private var metrics
    @Environment(\.heroContainerWidth) private var containerWidth
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The pile from the top down, as indices into `items`. Empty until the first card moves, which is `items` in order.
    @State private var order: [Int] = []
    /// How far the top poster has been dragged or thrown.
    @State private var dragOffset: CGFloat = 0
    /// How far the posters under the top one have risen towards it: 0 at rest, 1 once the top one has gone.
    @State private var lift: CGFloat = 0
    /// True while a poster is thrown off or comes back, so another move waits for it.
    @State private var isMoving = false

    static func cardWidth(_ metrics: LayoutMetrics) -> CGFloat { (metrics.posterWidth * 1.1).rounded() }
    static func cardHeight(_ metrics: LayoutMetrics) -> CGFloat { (cardWidth(metrics) * 1.5).rounded() }
    /// Room above and below the pile for the turned posters' corners.
    static func height(_ metrics: LayoutMetrics) -> CGFloat { cardHeight(metrics) + 20 }
    /// How many posters of the pile are drawn, the top one included.
    static let shown = 4
    /// How far each poster under the top one stands out past the one above it.
    static let peek: CGFloat = 12

    /// The pile, kept in step with `items`: a reloaded row starts again from its first title. `order` only ever holds a reordering of
    /// `items`' indices, so its count tells whether it still fits.
    private var pile: [Int] {
        order.count == items.count ? order : Array(items.indices)
    }

    var body: some View {
        let width = Self.cardWidth(metrics)
        let height = Self.cardHeight(metrics)
        let pile = self.pile
        let spacing = Theme.Spacing.l + Self.peek * CGFloat(min(Self.shown, pile.count) - 1)
        let detailsWidth = min(420, max(80, containerWidth - metrics.pageMargin * 2 - width - spacing))
        HStack(alignment: .center, spacing: spacing) {
            ZStack {
                ForEach(Array(pile.prefix(Self.shown).enumerated()), id: \.element) { depth, index in
                    card(items[index], depth: depth, width: width, height: height)
                }
            }
            .frame(width: width, height: Self.height(metrics))
            // A sideways drag anywhere on the pile moves the top poster; an upright one still scrolls the page.
            .gesture(WallRowPan { distance in
                guard !isMoving, items.count > 1 else { return }
                dragOffset = distance
                lift = min(abs(distance) / (width * 1.5), 1)
            } ended: { distance, velocity in
                guard !isMoving else { return }
                let projected = distance + velocity * 0.15
                if items.count > 1, abs(projected) > width * 0.45 {
                    throwTop(towards: projected < 0 ? -1 : 1)
                } else {
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) {
                        dragOffset = 0
                        lift = 0
                    }
                }
            })
            details(items[pile[0]], position: 1 + (pile.first ?? 0), width: detailsWidth)
                .frame(width: detailsWidth, height: height, alignment: .topLeading)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, metrics.pageMargin)
    }

    /// One poster of the pile. Under the top one each stands `peek` further out, a little smaller and darker, turned by its own small
    /// angle; as the top one leaves they rise towards it, and the next one straightens.
    private func card(_ item: MetaPreview, depth: Int, width: CGFloat, height: CGFloat) -> some View {
        let isTop = depth == 0
        let place = max(0, CGFloat(depth) - lift)
        let angle = isTop ? Double(dragOffset / 18) : Self.tilt(of: item) * Double(min(place, 1))
        return DeckCard(item: item, width: width, height: height)
            .equatable()
            // One shadow for the whole poster, not one for each of its layers.
            .compositingGroup()
            .shadow(color: .black.opacity(0.4), radius: 6, y: 3)
            .scaleEffect(1 - place * 0.04)
            .rotationEffect(.degrees(angle), anchor: .bottom)
            .offset(x: place * Self.peek + (isTop ? dragOffset : 0))
            .brightness(-Double(place) * 0.08)
            .allowsHitTesting(isTop && !isMoving)
            .accessibilityHidden(!isTop)
            .zIndex(-Double(depth))
    }

    /// The top title's logo, its details and the start of its synopsis, crossfading as the pile turns, over the buttons that turn it.
    private func details(_ item: MetaPreview, position: Int, width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            DeckDetails(item: item, showsRating: showsRating, width: width)
                .equatable()
                .id(item.identity)
                .transition(.opacity)
                .accessibilityHidden(true)
            Spacer(minLength: 0)
            if items.count > 1 {
                HStack(spacing: Theme.Spacing.s) {
                    button("chevron.backward", label: "Previous title", action: bringBack)
                    button("chevron.forward", label: "Next title") { throwTop(towards: -1) }
                    Text("\(position) of \(items.count)")
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .foregroundStyle(Theme.metaText)
                        .padding(.leading, Theme.Spacing.xs)
                        .accessibilityHidden(true)
                }
            }
        }
    }

    private func button(_ systemName: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white.opacity(0.8))
        }
        .buttonStyle(FixedGlassButtonStyle(size: 36))
        .accessibilityLabel(label)
    }

    /// Throws the top poster off towards `direction` (-1 left, 1 right) and slides it under the pile as the next one comes up.
    private func throwTop(towards direction: CGFloat) {
        guard items.count > 1, !isMoving else { return }
        let pile = self.pile
        let next = Array(pile.dropFirst()) + [pile[0]]
        Haptics.play(.choices)
        guard !reduceMotion else {
            order = next
            dragOffset = 0
            lift = 0
            return
        }
        isMoving = true
        withAnimation(.easeIn(duration: 0.2)) {
            dragOffset = direction * (containerWidth + Self.cardWidth(metrics))
            lift = 1
        }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(200))
            withAnimation(.spring(response: 0.45, dampingFraction: 0.82)) {
                order = next
                dragOffset = 0
                lift = 0
            }
            try? await Task.sleep(for: .milliseconds(250))
            isMoving = false
        }
    }

    /// Brings the poster at the bottom of the pile back on top, in from the left, as the others settle back one place.
    private func bringBack() {
        guard items.count > 1, !isMoving else { return }
        let pile = self.pile
        let previous = [pile[pile.count - 1]] + pile.dropLast()
        Haptics.play(.choices)
        guard !reduceMotion else {
            order = previous
            return
        }
        isMoving = true
        // Off to the side first, with the others still where they stood, then into place.
        var still = Transaction()
        still.disablesAnimations = true
        withTransaction(still) {
            order = previous
            dragOffset = -(containerWidth + Self.cardWidth(metrics))
            lift = 1
        }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(20))
            withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) {
                dragOffset = 0
                lift = 0
            }
            try? await Task.sleep(for: .milliseconds(300))
            isMoving = false
        }
    }

    /// A poster's own small turn under the top of the pile, the same each time it is drawn: between 1.5 and 4.5 degrees either way.
    private static func tilt(of item: MetaPreview) -> Double {
        let seed = item.identity.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }
        let angle = 1.5 + Double(seed % 31) / 10
        return seed.isMultiple(of: 2) ? angle : -angle
    }
}

/// One poster of the pile. Equatable, so a drag moves, turns and shades the posters without rebuilding them.
private struct DeckCard: View, Equatable {
    let item: MetaPreview
    let width: CGFloat
    let height: CGFloat

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        MainActor.assumeIsolated { lhs.item == rhs.item && lhs.width == rhs.width && lhs.height == rhs.height }
    }

    var body: some View {
        LayoutTitleLink(item: item, cornerRadius: Theme.Radius.poster) {
            LayoutPoster(item: item, width: width, height: height)
        }
    }
}

/// The top title's logo, its details and the start of its synopsis. Equatable, so a drag of the pile leaves it be.
private struct DeckDetails: View, Equatable {
    let item: MetaPreview
    let showsRating: Bool
    let width: CGFloat
    @Environment(\.layoutMetrics) private var metrics

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        MainActor.assumeIsolated { lhs.item == rhs.item && lhs.showsRating == rhs.showsRating && lhs.width == rhs.width }
    }

    var body: some View {
        let line = layoutDetailLine(item, showsRating: showsRating)
        let synopsis = item.description?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            LayoutLogo(item: item, width: min(width, 200), height: 52)
            if !line.isEmpty {
                Text(line)
                    .font(Theme.Typography.metaLine.weight(.semibold))
                    .foregroundStyle(Theme.metaText)
                    .lineLimit(1)
            }
            if !synopsis.isEmpty {
                Text(synopsis)
                    .font(Theme.Typography.metaLine)
                    .foregroundStyle(.secondary)
                    .lineLimit(metrics.isRegular ? 6 : 5)
                    .multilineTextAlignment(.leading)
            }
        }
    }
}
#endif
