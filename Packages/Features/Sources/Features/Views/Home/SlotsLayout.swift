#if canImport(UIKit)
import StremioKit
import SwiftUI

/// `RowLayout.slots`: a slot machine. Three reels of posters stand side by side in a dark cabinet, each showing one title whole with the
/// edges of the ones above and below it. Pulling the lever beside them spins the reels, which stop one after another on titles picked at
/// random, with one haptic as the last one lands. Each poster opens its title. With Reduce Motion the reels change without spinning.
struct SlotsLayout: View {
    let items: [MetaPreview]
    @Environment(\.layoutMetrics) private var metrics
    @Environment(\.heroContainerWidth) private var containerWidth
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Where each reel stands, in titles from its first. It only grows, so the reels always spin the same way.
    @State private var positions = Array(repeating: 0.0, count: SlotsLayout.reelCount)
    @State private var isSpinning = false
    /// Counts the lever's pulls, so it goes down and springs back up on each.
    @State private var pulls = 0

    static let reelCount = 3
    static let leverWidth: CGFloat = 30
    static let padding: CGFloat = Theme.Spacing.m
    static func gap(_ metrics: LayoutMetrics) -> CGFloat { max(4, (metrics.cardSpacing * 0.67).rounded()) }

    /// A reel's poster width: three across the cabinet with the lever beside them, never wider than a shelf's poster.
    static func posterWidth(_ metrics: LayoutMetrics, containerWidth: CGFloat) -> CGFloat {
        let available = containerWidth - metrics.pageMargin * 2 - padding * 2 - leverWidth - gap(metrics) * CGFloat(reelCount)
        return max(40, min(metrics.posterWidth, (available / CGFloat(reelCount)).rounded(.down)))
    }

    /// A reel's window: its middle poster whole, and a little over a quarter of the ones above and below it.
    static func windowHeight(_ metrics: LayoutMetrics, containerWidth: CGFloat) -> CGFloat {
        (posterWidth(metrics, containerWidth: containerWidth) * 1.5 * 1.56 + gap(metrics) * 2).rounded()
    }

    static func height(_ metrics: LayoutMetrics, containerWidth: CGFloat) -> CGFloat {
        windowHeight(metrics, containerWidth: containerWidth) + padding * 2
    }

    /// The cabinet's width: its reels and the lever, the gaps between them and its padding.
    static func width(_ metrics: LayoutMetrics, containerWidth: CGFloat) -> CGFloat {
        posterWidth(metrics, containerWidth: containerWidth) * CGFloat(reelCount) + gap(metrics) * CGFloat(reelCount) + leverWidth + padding * 2
    }

    /// How long `reel` takes to stop: each one a little after the one before it.
    static func spinDuration(of reel: Int) -> Double { 1.4 + 0.45 * Double(reel) }

    /// Each reel's titles. With enough of them each reel takes its own share, at most twelve; with few, every reel has them all, each
    /// starting at a different one.
    private var reels: [[MetaPreview]] {
        let count = Self.reelCount
        guard items.count >= count * 3 else {
            return (0..<count).map { reel in
                let start = reel * items.count / count
                return Array(items[start...]) + Array(items[..<start])
            }
        }
        return (0..<count).map { reel in stride(from: reel, to: items.count, by: count).prefix(12).map { items[$0] } }
    }

    var body: some View {
        let width = Self.posterWidth(metrics, containerWidth: containerWidth)
        let window = Self.windowHeight(metrics, containerWidth: containerWidth)
        let gap = Self.gap(metrics)
        let radius = HeroBanner.cornerRadius * metrics.cornerScale(for: .artwork)
        let reels = self.reels
        HStack(spacing: gap) {
            HStack(spacing: gap) {
                ForEach(reels.indices, id: \.self) { index in
                    SlotReel(items: reels[index], reel: index, position: positions[index], width: width, window: window, gap: gap)
                }
            }
            // Spinning reels take no taps, so a title is opened only once it has landed.
            .allowsHitTesting(!isSpinning)
            // The payline: a marker at each end of the middle row.
            .overlay(alignment: .leading) { marker("arrowtriangle.right.fill").offset(x: -(Self.padding + 8) / 2) }
            .overlay(alignment: .trailing) { marker("arrowtriangle.left.fill").offset(x: (gap + 8) / 2) }
            SlotLever(pulls: pulls, height: window, isSpinning: isSpinning, action: spin)
                .frame(width: Self.leverWidth)
        }
        .padding(Self.padding)
        .background {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(LinearGradient(colors: [Color(white: 0.17), Color(white: 0.07)], startPoint: .top, endPoint: .bottom))
                .overlay {
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .strokeBorder(Theme.artworkBorder, lineWidth: 0.5)
                }
                .accessibilityHidden(true)
        }
        // On a wide screen the cabinet stands in the middle of the row.
        .frame(maxWidth: .infinity)
        .padding(.horizontal, metrics.pageMargin)
        .accessibilityElement(children: .contain)
    }

    private func marker(_ systemName: String) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 8, weight: .bold))
            .foregroundStyle(.tint)
            .frame(width: 8)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    /// Spins every reel to a title picked at random. The later reels turn for longer, so they stop one after another.
    private func spin() {
        guard !isSpinning else { return }
        let reels = self.reels
        pulls += 1
        isSpinning = true
        var next = positions
        for index in reels.indices where next.indices.contains(index) {
            let count = Double(reels[index].count)
            let landing = Double(Int.random(in: 0..<reels[index].count))
            let current = positions[index]
            var target = (current / count).rounded(.down) * count + landing + count * Double(2 + index)
            // A short reel still passes a good run of posters before it stops.
            while target - current < Double(12 + index * 4) { target += count }
            next[index] = target
        }
        positions = next
        let settle = reduceMotion ? 0.1 : Self.spinDuration(of: reels.count - 1)
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(settle))
            isSpinning = false
            Haptics.play(.choices)
        }
    }
}

/// One reel: its titles one above another, drawn once more at each end so it loops without a seam, moved to `position` in its window
/// and shaded at the top and bottom like a drum.
private struct SlotReel: View {
    let items: [MetaPreview]
    let reel: Int
    let position: Double
    let width: CGFloat
    let window: CGFloat
    let gap: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.layoutMetrics) private var metrics

    var body: some View {
        let height = (width * 1.5).rounded()
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.small * metrics.cornerScale(for: .artwork), style: .continuous)
        SlotStrip(items: items, reel: reel, width: width, height: height, gap: gap)
            .equatable()
            .modifier(ReelOffset(position: position, count: items.count, step: height + gap, window: window, posterHeight: height))
            .animation(reduceMotion ? nil : Animation.spring(duration: SlotsLayout.spinDuration(of: reel), bounce: 0.14), value: position)
            // The rounded clip below cuts the strip to the window; no second clip is needed.
            .frame(width: width, height: window, alignment: .top)
            .overlay {
                LinearGradient(stops: [
                    .init(color: .black.opacity(0.85), location: 0),
                    .init(color: .black.opacity(0), location: 0.24),
                    .init(color: .white.opacity(0.05), location: 0.5),
                    .init(color: .black.opacity(0), location: 0.76),
                    .init(color: .black.opacity(0.85), location: 1),
                ], startPoint: .top, endPoint: .bottom)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
            .background(Color.black)
            .clipShape(shape)
            // The strip runs past the window; only what shows in it takes touches.
            .contentShape(shape)
    }
}

/// A reel's strip where `position` puts it: the title at `position` in the middle of the window, within one lap of the strip. The
/// position animates, so a spin runs through many laps and wraps round each one instead of running back.
private struct ReelOffset: ViewModifier, Animatable {
    private var position: Double
    let count: Int
    let step: CGFloat
    let window: CGFloat
    let posterHeight: CGFloat

    init(position: Double, count: Int, step: CGFloat, window: CGFloat, posterHeight: CGFloat) {
        self.position = position
        self.count = count
        self.step = step
        self.window = window
        self.posterHeight = posterHeight
    }

    /// Not tied to the main actor, as `Animatable` asks: it only reads and writes the modifier's own number.
    nonisolated var animatableData: Double {
        get { position }
        set { position = newValue }
    }

    func body(content: Content) -> some View {
        let lap = Double(max(count, 1))
        let wrapped = position - (position / lap).rounded(.down) * lap
        // The strip starts one title early, so the title before the first shows above it: entry `wrapped + 1` sits in the middle.
        content.offset(y: (window - posterHeight) / 2 - CGFloat(wrapped + 1) * step)
    }
}

/// A reel's posters, from the last title round to the first two again. Equatable, so the spin moves the strip without rebuilding it.
private struct SlotStrip: View, Equatable {
    let items: [MetaPreview]
    let reel: Int
    let width: CGFloat
    let height: CGFloat
    let gap: CGFloat

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        MainActor.assumeIsolated {
            lhs.reel == rhs.reel && lhs.width == rhs.width && lhs.height == rhs.height && lhs.gap == rhs.gap && lhs.items == rhs.items
        }
    }

    var body: some View {
        let count = items.count
        VStack(spacing: gap) {
            ForEach(0..<(count + 3), id: \.self) { index in
                let item = items[(index - 1 + count) % count]
                LayoutTitleLink(item: item, copy: "\(reel).\(index)/", cornerRadius: Theme.Radius.small) {
                    LayoutPoster(item: item, width: width, height: height)
                }
                // VoiceOver reads each title once.
                .accessibilityHidden(index < 1 || index > count)
            }
        }
        .fixedSize()
    }
}

/// The cabinet's lever: a glossy knob at the top of its slot that goes down and springs back up when pulled, spinning the reels.
private struct SlotLever: View {
    let pulls: Int
    let height: CGFloat
    let isSpinning: Bool
    let action: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isDown = false

    private static let knob: CGFloat = 24

    var body: some View {
        let travel = (height * 0.42).rounded()
        Button(action: action) {
            ZStack(alignment: .top) {
                Capsule()
                    .fill(.black.opacity(0.6))
                    .overlay { Capsule().strokeBorder(.white.opacity(0.12), lineWidth: 0.5) }
                    .frame(width: 7, height: travel + Self.knob)
                Circle()
                    .fill(.tint)
                    .overlay {
                        Circle().fill(RadialGradient(colors: [.white.opacity(0.7), .white.opacity(0)], center: UnitPoint(x: 0.35, y: 0.3),
                                                     startRadius: 0, endRadius: Self.knob * 0.55))
                    }
                    // One shadow for the knob and its shine together.
                    .compositingGroup()
                    .shadow(color: .black.opacity(0.5), radius: 3, y: 2)
                    .frame(width: Self.knob, height: Self.knob)
                    .offset(y: isDown ? travel : 0)
            }
            .frame(width: SlotsLayout.leverWidth, height: height)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isSpinning)
        .help("Spin")
        .accessibilityLabel("Spin")
        .onChange(of: pulls) { _, _ in
            guard !reduceMotion else { return }
            withAnimation(.easeIn(duration: 0.16)) { isDown = true }
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(160))
                withAnimation(.spring(response: 0.5, dampingFraction: 0.45)) { isDown = false }
            }
        }
    }
}
#endif
