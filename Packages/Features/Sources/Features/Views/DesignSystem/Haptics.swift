#if canImport(UIKit)
import StremioKit
import SwiftUI
import UIKit

/// Every haptic in the app. A call site names the place it fires in (`Haptics.play(.buttons)`), never a feel or a number: the place's
/// feel and strength are the listener's, tuned on the Haptics page, so a tap on a poster and a tap on a shelf's See All are the same
/// tap until the listener makes them different. The two exceptions are in the widget grid, which uses SwiftUI's own `.sensoryFeedback`
/// (`.alignment` on the Mac, `.impact` on iPhone) because that drag is a SwiftUI gesture with no generator to call; see
/// `WidgetsManagerView`.
///
/// Fire a place when the moment is one a view cannot see through its own state: a setter that runs as the user changes a value, a menu
/// action, a gesture that has already ended. Where the view does hold the value, `.sensoryFeedback` would be the shorter form; the app's
/// own places are used instead so that the Haptics page reaches every tick.
///
/// All of this respects the system's haptic settings. Nothing here is iPhone-only: the file is compiled for Mac Catalyst too, so the
/// call sites stay identical on both platforms (see `docs/HAPTICS.md`).
@MainActor
public enum Haptics {
    public typealias Place = HapticPreferences.Place
    public typealias Feel = HapticPreferences.Feel

    // MARK: - Tuning

    /// The listener's own tuning, from the Haptics page in Settings. Applied at launch and again as the page saves, so a slider
    /// takes effect on the very next tap.
    private(set) static var configuration = HapticPreferences()

    /// Takes the tuning the app has just loaded or saved. Public so the app can apply the saved tuning at launch, before any view
    /// exists.
    public static func apply(_ preferences: HapticPreferences) {
        configuration = preferences
    }

    /// How far a shelf must travel between ticks, in points: the tuning's `shelfTickSpacingPoints`.
    static var shelfTickSpacing: CGFloat { CGFloat(configuration.shelfTickSpacingPoints) }

    // MARK: - Playing

    /// The haptic for `place`: its feel at its strength, or nothing when the place or haptics as a whole are off.
    ///
    /// Once per action is the rule (player scrubbing and level swipes also give spaced steps): a view that gives its own haptic must not also let a card's tap arrive (see `MediaCard` and the
    /// full-screen trailer's close button). Fire on the new value, never on a value read in from storage, so a screen that opens on
    /// saved settings stays silent.
    static func play(_ place: Place) {
        guard configuration.isOn, configuration.plays(place) else { return }
        fire(configuration.feel(place), intensity: configuration.intensity(place))
    }

    /// The Haptics page's try-outs: `feel` (the place's own by default) at `strength` (the place's own by default), scaled by the
    /// overall strength as the app would. Plays even when the place's own switch is off, so a feel can be tried before it is chosen;
    /// nothing when haptics are off altogether.
    static func preview(_ place: Place, feel: Feel? = nil, strength: Double? = nil) {
        guard configuration.isOn else { return }
        let intensity = strength.map { configuration.intensity(place, strength: $0) } ?? configuration.intensity(place)
        fire(feel ?? configuration.feel(place), intensity: intensity)
    }

    /// One haptic. `intensity` reaches only the impacts; Apple's tick and notification patterns take none.
    private static func fire(_ feel: Feel, intensity: Double) {
        switch feel {
        case .tick:
            UISelectionFeedbackGenerator().selectionChanged()
        case .success:
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        case .warning:
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
        case .error:
            UINotificationFeedbackGenerator().notificationOccurred(.error)
        case .soft, .light, .medium, .rigid, .heavy:
            guard intensity > 0 else { return }
            UIImpactFeedbackGenerator(style: impactStyle(feel)).impactOccurred(intensity: CGFloat(min(intensity, 1)))
        }
    }

    private static func impactStyle(_ feel: Feel) -> UIImpactFeedbackGenerator.FeedbackStyle {
        switch feel {
        case .soft: .soft
        case .medium: .medium
        case .rigid: .rigid
        case .heavy: .heavy
        default: .light
        }
    }

    /// The run of ticks that is going, so a new one takes its place.
    private static var lineRun: Task<Void, Never>?

    /// A run of ticks under text that is unfolding or folding, in the Reviews place's feel: one for each line that comes into view or
    /// leaves it, spread over the time the text takes to move, the first at once. At least two, so a short text still reads as a run,
    /// and never more than the tuning's `reviewTicks`. A new run stops one that is still going.
    ///
    /// This is the only haptic that runs over time, and the only one that cancels its predecessor, so a second review opened mid-fold
    /// does not leave the first one ticking. `count` is how many lines the motion will show or hide and `duration` the animation it
    /// accompanies; the caller owes both, since only it knows the text and the animation.
    static func lines(_ count: Int, over duration: Duration) {
        lineRun?.cancel()
        guard configuration.isOn, configuration.plays(.reviews), count > 0 else { return }
        let feel = configuration.feel(.reviews)
        let intensity = configuration.intensity(.reviews)
        let ticks = min(max(count, 2), configuration.reviewTicks)
        // One prepared generator for the whole run, so the first tick lands with the motion rather than after it.
        let impact = feel.takesStrength ? UIImpactFeedbackGenerator(style: impactStyle(feel)) : nil
        impact?.prepare()
        lineRun = Task { @MainActor in
            let gap = duration / ticks
            for tick in 0..<ticks {
                guard !Task.isCancelled, configuration.isOn else { return }
                if let impact { impact.impactOccurred(intensity: CGFloat(intensity)) } else { fire(feel, intensity: intensity) }
                guard tick < ticks - 1 else { return }
                do { try await Task.sleep(for: gap) } catch { return }
            }
        }
    }
}

extension View {
    /// The place's haptic when the view is tapped, alongside whatever the view does on tap (a link, say), and without taking the tap.
    /// Posters & titles by default, so every card that opens a title ticks alike.
    ///
    /// Use it on a link or a card that navigates. Do not stack it on a control that already fires a haptic in its action, or the
    /// one gesture gives two ticks.
    func titleTapHaptic(_ place: Haptics.Place = .titles) -> some View {
        simultaneousGesture(TapGesture().onEnded { Haptics.play(place) })
    }

    /// Let a swipe travel naturally, align to cards, and tick each time a card's leading edge passes the screen's leading edge,
    /// so the tick falls in the gap between two cards. Each card in the shelf must call `reportsShelfEdge(id:)`. Every horizontal
    /// shelf uses this one feel: the actor shelf's.
    ///
    /// This is where the Poster shelves place fires: its feel, strength and the distance between ticks are on the Haptics page's
    /// Poster shelves page, and a shelf that forgets `reportsShelfEdge(id:)` scrolls silently. Prefer `ShelfScroll` to applying this
    /// by hand: it also sizes a lazy row and gives the Mac its chevrons.
    func softSnappingScroll() -> some View {
        modifier(SoftSnappingScrollModifier())
    }

    /// Tell the enclosing `softSnappingScroll` where this card sits, so it can tick between cards.
    func reportsShelfEdge<ID: Hashable>(id: ID) -> some View {
        background {
            GeometryReader { proxy in
                #if targetEnvironment(macCatalyst)
                // Mac shelves need card heights, but have no haptic crossings to track while scrolling.
                Color.clear.preference(key: ShelfEdgeKey.self,
                                       value: [ShelfEdge(id: AnyHashable(id), minX: 0, height: proxy.size.height)])
                #else
                Color.clear.preference(key: ShelfEdgeKey.self,
                                       value: [ShelfEdge(id: AnyHashable(id), minX: proxy.frame(in: .named(shelfScrollSpace)).minX,
                                                           height: proxy.size.height)])
                #endif
            }
        }
    }
}

/// The one horizontal card shelf: a row of cards that snaps to the page margin, bleeds past the screen's edge, and ticks as cards cross the
/// leading edge. Every card shelf is built with this, so they all scroll and tick alike. Each card must call `reportsShelfEdge(id:)` and have
/// a stable `id`.
///
/// By default the row is lazy, which builds only the cards near the screen. A lazy stack cannot size itself from the cards it has not built,
/// and a card that changes height (an opened review) or is taller than the first would spill over the section below. So every card reports
/// its height and the shelf takes the tallest of those built so far. That height only grows, since the tallest card may not be built yet. When
/// `resetKey` changes (a different season, a different card width) the height starts again from the cards then built.
///
/// `lazy: false` is for a short shelf whose cards all exist already. A plain row is exactly as tall as its tallest card, so the shelf changes
/// height with that card's own animation, and no height is measured.
/// `shrinksToFit` lets an expandable lazy shelf (reviews) recalculate its height as cards close; ordinary lazy shelves retain their maximum.
struct ShelfScroll<Content: View>: View {
    @Environment(\.layoutMetrics) private var metrics
    let margin: CGFloat
    let spacing: CGFloat
    let lazy: Bool
    let resetKey: String
    let shrinksToFit: Bool
    let content: Content
    @State private var height: CGFloat?
    @State private var measuredKey: String?
    @State private var shelfPosition = ScrollPosition()
    #if targetEnvironment(macCatalyst)
    /// How wide the shelf is and whether the pointer is over it, for the chevrons at its ends.
    @State private var shelfTracking = ShelfScrollTracking()
    @State private var canScrollBack = false
    @State private var canScrollForward = false
    @State private var isHoveringShelf = false
    #endif

    init(margin: CGFloat, spacing: CGFloat, lazy: Bool = true, resetKey: String = "", shrinksToFit: Bool = false,
         initialID: String? = nil, @ViewBuilder content: () -> Content) {
        self.margin = margin
        self.spacing = spacing
        self.lazy = lazy
        self.resetKey = resetKey
        self.shrinksToFit = shrinksToFit
        _shelfPosition = State(initialValue: initialID.map { ScrollPosition(id: $0, anchor: .leading) } ?? ScrollPosition())
        self.content = content()
    }

    var body: some View {
        ScrollView(.horizontal) {
            if lazy {
                LazyHStack(alignment: .top, spacing: spacing) { content }
                    .scrollTargetLayout()
            } else {
                HStack(alignment: .top, spacing: spacing) { content }
                    .scrollTargetLayout()
            }
        }
        .scrollPosition($shelfPosition)
        #if targetEnvironment(macCatalyst)
        .onScrollGeometryChange(for: ShelfMetrics.self) { geometry in
            ShelfMetrics(offset: geometry.contentOffset.x, contentWidth: geometry.contentSize.width, viewWidth: geometry.containerSize.width)
        } action: { _, metrics in
            shelfTracking.metrics = metrics
            let back = metrics.offset > 1
            let forward = metrics.offset + metrics.viewWidth < metrics.contentWidth - 1
            if canScrollBack != back { canScrollBack = back }
            if canScrollForward != forward { canScrollForward = forward }
        }
        .onHover { isHoveringShelf = $0 }
        .overlay {
            if isHoveringShelf { shelfArrows }
        }
        #endif
        .scrollIndicators(.hidden, axes: .horizontal)
        .contentMargins(.horizontal, margin, for: .scrollContent)
        .softSnappingScroll()
        .scrollClipDisabled()
        .frame(height: height)
        .onPreferenceChange(ShelfEdgeKey.self) { edges in
            // A plain row sizes itself, so there is nothing to measure.
            guard lazy else { return }
            let tallest = edges.map(\.height).max() ?? 0
            guard tallest > 0 else { return }
            let previous = measuredKey == resetKey ? height : nil
            let next = shrinksToFit ? tallest : max(previous ?? 0, tallest)
            if measuredKey != resetKey { measuredKey = resetKey }
            if abs(next - (height ?? -1)) > 0.5 { height = next }
        }
    }

    #if targetEnvironment(macCatalyst)
    /// Mac: a chevron at each end of the shelf while the pointer is over it, shown where the shelf can scroll that way. Each pages by most
    /// of the shelf's width.
    private var shelfArrows: some View {
        HStack {
            shelfArrow(systemName: "chevron.left", label: "Scroll back", step: -1, enabled: canScrollBack)
            Spacer()
            shelfArrow(systemName: "chevron.right", label: "Scroll forward", step: 1,
                       enabled: canScrollForward)
        }
        .padding(.horizontal, Theme.Spacing.s)
        .frame(maxHeight: .infinity)
    }

    private func shelfArrow(systemName: String, label: String, step: CGFloat, enabled: Bool) -> some View {
        Button {
            // The shelf rests at minus its leading margin, so a page back stops there rather than cutting the margin off the first card.
            let metrics = shelfTracking.metrics
            let target = max(-margin, metrics.offset + step * metrics.viewWidth * 0.8)
            withAnimation(.snappy(duration: 0.35)) { shelfPosition.scrollTo(x: target) }
        } label: {
            Image(systemName: systemName)
                .font(.headline.weight(.semibold))
                .frame(width: 40, height: 40)
                .glassEffect(.regular, in: ScaledCapsule(scale: metrics.circularButtonScale(for: .actionButtons)))
                // Only the circle takes the click. The square's corners pass it to the card beneath, as they would with no chevron there.
                .contentShape(ScaledCapsule(scale: metrics.circularButtonScale(for: .actionButtons)))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        // A hidden chevron must not take clicks meant for the cards beneath it.
        .allowsHitTesting(enabled)
        .opacity(enabled ? 1 : 0)
        .accessibilityLabel(label)
    }
    #endif
}

#if targetEnvironment(macCatalyst)
/// A shelf's scroll state for the Mac chevrons: how far it is scrolled, how wide its content is, and how wide the shelf shows.
private struct ShelfMetrics: Equatable {
    var offset: CGFloat = 0
    var contentWidth: CGFloat = 0
    var viewWidth: CGFloat = 0
}

/// Keep the latest position for arrow clicks without invalidating the shelf on every scroll movement.
private final class ShelfScrollTracking {
    var metrics = ShelfMetrics()
}
#endif

/// The coordinate space of a shelf's viewport: a card's `minX` in it is where the card's leading edge sits on screen.
private let shelfScrollSpace = "softSnappingShelf"

private struct ShelfEdge: Equatable {
    let id: AnyHashable
    let minX: CGFloat
    let height: CGFloat
}

private struct ShelfEdgeKey: PreferenceKey {
    static var defaultValue: [ShelfEdge] { [] }

    static func reduce(value: inout [ShelfEdge], nextValue: () -> [ShelfEdge]) {
        value += nextValue()
    }
}

/// Per-frame scroll bookkeeping is deliberately non-observable: the shelf should redraw for content changes,
/// not each time the finger moves. Keep the morning's crossing thresholds and haptic timing unchanged.
@MainActor
private final class ShelfHapticTracking {
    var leadingID: AnyHashable?
    var isUserScrolling = false
    var offset: CGFloat = 0
    var offsetAtLastTick: CGFloat = 0
}

private struct SoftSnappingScrollModifier: ViewModifier {
    #if !targetEnvironment(macCatalyst)
    @State private var tracking = ShelfHapticTracking()
    #endif

    func body(content: Content) -> some View {
        content
            .scrollTargetBehavior(.viewAligned(limitBehavior: .never))
            #if !targetEnvironment(macCatalyst)
            .coordinateSpace(name: shelfScrollSpace)
            .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.x } action: { _, new in tracking.offset = new }
            .onPreferenceChange(ShelfEdgeKey.self) { edges in
                let leading = edges.filter { $0.minX <= 0 }.max { $0.minX < $1.minX }?.id
                guard leading != tracking.leadingID else { return }
                tracking.leadingID = leading
                // How far the shelf must travel before another crossing ticks: the listener's shelf spacing, 4 to 60 points. Only
                // enough by default to keep a card resting on the edge from chattering; a swipe back over the gap ticks again.
                guard tracking.isUserScrolling, leading != nil,
                      abs(tracking.offset - tracking.offsetAtLastTick) >= Haptics.shelfTickSpacing else { return }
                tracking.offsetAtLastTick = tracking.offset
                Haptics.play(.shelves)
            }
            .onScrollPhaseChange { _, phase in
                switch phase {
                case .interacting, .decelerating:
                    tracking.isUserScrolling = true
                default:
                    tracking.isUserScrolling = false
                }
            }
            .onDisappear { tracking.isUserScrolling = false }
            #endif
    }
}

#endif
