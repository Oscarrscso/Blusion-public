#if canImport(UIKit)
import StremioKit
import SwiftUI
import UIKit

/// Every haptic in the app. Every one of them is one of the feels below, with two exceptions in the widget grid that use SwiftUI's
/// own `.sensoryFeedback` (`.alignment` on the Mac, `.impact` on iPhone) because that drag is a SwiftUI gesture with no generator to
/// call; see `WidgetsManagerView`.
///
/// Fire a feel when the moment is one a view cannot see through its own state: a setter that runs as the user changes a value, a menu
/// action, a gesture that has already ended. Where the view does hold the value, `.sensoryFeedback` would be the shorter form, and it
/// was used before the Haptics page existed; the app's own feels are used instead so that the page's switches and sliders reach every
/// tick, in one voice.
///
/// All of this respects the system's haptic settings. Nothing here is iPhone-only: the file is compiled for Mac Catalyst too, so
/// the call sites stay identical on both platforms (see `docs/HAPTICS.md`).
///
/// How hard each feel lands, and the three timings, are the listener's own: they live in `HapticPreferences`, are tuned on the
/// Haptics page in Settings, and arrive here through `apply(_:)`. The call sites never hold a number, so a tap on a poster and a
/// tap on a menu are always the same tap, and changing one changes both.
@MainActor
public enum Haptics {
    // MARK: - Tuning

    /// The listener's own tuning, from the Haptics page in Settings. Applied at launch and again as the page saves, so a slider
    /// takes effect on the very next tap. Every feel reads it as it fires, and the defaults are `HapticPreferences.Default`, which
    /// are the numbers this file used before the page existed.
    private(set) static var configuration = HapticPreferences()

    /// Takes the tuning the app has just loaded or saved. A no-op for a profile that has never touched the page. Public so the app
    /// can apply the saved tuning at launch, before any view exists.
    public static func apply(_ preferences: HapticPreferences) {
        configuration = preferences
    }

    /// How far a shelf must travel between ticks, in points: the tuning's `shelfTickSpacingPoints`.
    static var shelfTickSpacing: CGFloat { CGFloat(configuration.shelfTickSpacingPoints) }


    // MARK: - Feels

    /// A tick for a choice changing: a toggle, a picker or a filter. Fires on the new value, never on the old one and never
    /// on a value read in from storage, so a screen that opens on saved settings stays silent.
    ///
    /// There is nothing to tune but the generator: Apple's selection feedback has no style or intensity, so the Haptics page has a
    /// switch for it rather than a slider.
    static func selection() {
        guard configuration.isOn, configuration.selectionOn else { return }
        UISelectionFeedbackGenerator().selectionChanged()
    }

    /// The app's standard tap: a light impact, for a control that acts on the tap. It fires on a completed tap, so a scroll that
    /// starts on a poster stays silent.
    ///
    /// This is also what `titleTapHaptic()` fires, which is how posters, cards and links get it without each one calling
    /// here. Once per gesture is the rule: a view that gives its own haptic must not also let the tap's arrive (see
    /// `MediaCard` and the full-screen trailer's close button).
    static func tap() {
        guard configuration.isOn else { return }
        impact(configuration.tapStyle ?? HapticPreferences.Default.tapStyle, configuration.tapStrength)
    }

    /// A distinct click, harder and drier than `tap()`, for a whole page or screen's worth of content being replaced: the
    /// hero's page change, and the one menu action that moves the app to another screen. Not for a tap that stays on the
    /// same screen; that is `tap()`.
    static func scrollSnap() {
        guard configuration.isOn else { return }
        impact(configuration.pageChangeStyle ?? HapticPreferences.Default.pageChangeStyle, configuration.pageChangeStrength)
    }

    /// The gentler click of a shelf card's leading edge crossing the screen's edge. Only `softSnappingScroll()` fires this:
    /// a shelf should tick in one voice, so do not call it from a card or a button, or the shelf's feel gets lost among the
    /// other clicks.
    static func scrollSnapSoft() {
        guard configuration.isOn else { return }
        impact(configuration.shelfSnapStyle ?? HapticPreferences.Default.shelfSnapStyle, configuration.shelfSnapStrength)
    }

    /// The press that has become a hold, heavier than a tap: the point where lifting the finger starts to mean something else.
    /// Fired once, as the hold begins, not while the finger rests. It is the app's only way of saying "keep holding" without any
    /// text, which is why it lands at full strength by default.
    static func hold() {
        guard configuration.isOn else { return }
        impact(configuration.holdStyle ?? HapticPreferences.Default.holdStyle, configuration.holdStrength)
    }

    /// The double thud of something the user asked for going wrong. Apple's error notification, not one of the taps, so it cannot
    /// be mistaken for a control answering. Deliberately rare: a failure the user cannot act on does not get one.
    static func failure() {
        guard configuration.isOn, configuration.failureOn else { return }
        UINotificationFeedbackGenerator().notificationOccurred(.error)
    }

    /// The chime of a save landing, where the app gives the save: the saved HUD. Same reasoning as `failure()`: a notification, not
    /// a tap, because it is the app speaking rather than a control answering.
    static func success() {
        guard configuration.isOn, configuration.successOn else { return }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    /// One impact at a strength from the tuning, clamped so a saved value cannot make the generator grumble. A strength of 0 fires
    /// nothing at all, which is how a slider at its foot is silent.
    private static func impact(_ style: HapticPreferences.ImpactStyle, _ strength: Double) {
        let intensity = min(max(strength, HapticPreferences.Limits.strength.lowerBound), HapticPreferences.Limits.strength.upperBound)
        guard intensity > 0 else { return }
        UIImpactFeedbackGenerator(style: feedbackStyle(style)).impactOccurred(intensity: CGFloat(intensity))
    }

    private static func feedbackStyle(_ style: HapticPreferences.ImpactStyle) -> UIImpactFeedbackGenerator.FeedbackStyle {
        switch style {
        case .light: .light
        case .medium: .medium
        case .heavy: .heavy
        case .soft: .soft
        case .rigid: .rigid
        }
    }

    // MARK: - Preview

    /// The feels as the Haptics page lists them, so a row can play its own feel at the strength it is showing.
    enum Feel: Hashable {
        case tap, shelfSnap, pageChange, textLines, hold, selection, failure, success
    }

    /// Plays a feel from the Haptics page, at `strength` when the row is a slider and the tuning's value otherwise. Nothing when the
    /// master switch is off, the same as everywhere else. `textLines` previews a single tick: a run belongs to an animation.
    static func preview(_ feel: Feel, strength: Double? = nil) {
        guard configuration.isOn else { return }
        switch feel {
        case .tap: impact(configuration.tapStyle ?? HapticPreferences.Default.tapStyle, strength ?? configuration.tapStrength)
        case .shelfSnap: impact(configuration.shelfSnapStyle ?? HapticPreferences.Default.shelfSnapStyle, strength ?? configuration.shelfSnapStrength)
        case .pageChange: impact(configuration.pageChangeStyle ?? HapticPreferences.Default.pageChangeStyle, strength ?? configuration.pageChangeStrength)
        case .textLines: impact(configuration.textLinesStyle ?? HapticPreferences.Default.textLinesStyle, strength ?? configuration.textLinesStrength)
        case .hold: impact(configuration.holdStyle ?? HapticPreferences.Default.holdStyle, strength ?? configuration.holdStrength)
        case .selection: selection()
        case .failure: failure()
        case .success: success()
        }
    }

    /// The run of ticks that is going, so a new one takes its place.
    private static var lineRun: Task<Void, Never>?

    /// A run of faint, soft ticks under text that is unfolding or folding: one for each line that comes into view or leaves it,
    /// spread over the time the text takes to move, the first at once. At least two, so a short text still reads as a run, and never more
    /// than the tuning's `reviewTicks`. A new run stops one that is still going. Nothing for no lines, and nothing at 0 strength.
    ///
    /// This is the only feel that runs over time, and the only one that cancels its predecessor, so a second review opened
    /// mid-fold does not leave the first one ticking. `count` is how many lines the motion will show or hide and `duration`
    /// the animation it accompanies; the caller owes both, since only it knows the text and the animation.
    static func lines(_ count: Int, over duration: Duration) {
        lineRun?.cancel()
        guard configuration.isOn, count > 0 else { return }
        let strength = configuration.textLinesStrength
        guard strength > 0 else { return }
        let ticks = min(max(count, 2), configuration.reviewTicks)
        let generator = UIImpactFeedbackGenerator(style: feedbackStyle(configuration.textLinesStyle ?? HapticPreferences.Default.textLinesStyle))
        generator.prepare()
        lineRun = Task { @MainActor in
            let gap = duration / ticks
            for tick in 0..<ticks {
                guard !Task.isCancelled, configuration.isOn else { return }
                generator.impactOccurred(intensity: CGFloat(strength))
                guard tick < ticks - 1 else { return }
                do { try await Task.sleep(for: gap) } catch { return }
            }
        }
    }
}

extension View {
    /// A very light tap when the view is tapped, alongside whatever the view does on tap (a link, say), and without taking the tap.
    /// Fires `Haptics.tap()`, so a screen whose cards use this and whose buttons are glass buttons all tick alike.
    ///
    /// Use it on a link or a card that navigates. Do not stack it on a control that already fires a haptic in its action, or the
    /// one gesture gives two ticks.
    func titleTapHaptic() -> some View {
        simultaneousGesture(TapGesture().onEnded { Haptics.tap() })
    }

    /// Let a swipe travel naturally, align to cards, and tick each time a card's leading edge passes the screen's leading edge,
    /// so the tick falls in the gap between two cards. Each card in the shelf must call `reportsShelfEdge(id:)`. Every horizontal
    /// shelf uses this one feel: the actor shelf's.
    ///
    /// This is where the app's shelf feel lives: the tick's strength and the distance between ticks are the Haptics page's "Shelf
    /// tick" slider and its "Shelf tick spacing", and a shelf that forgets `reportsShelfEdge(id:)` scrolls silently. Prefer
    /// `ShelfScroll` to applying this by hand: it also sizes a lazy row and gives the Mac its chevrons.
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
struct ShelfScroll<Content: View>: View {
    let margin: CGFloat
    let spacing: CGFloat
    let lazy: Bool
    let resetKey: String
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

    init(margin: CGFloat, spacing: CGFloat, lazy: Bool = true, resetKey: String = "", initialID: String? = nil, @ViewBuilder content: () -> Content) {
        self.margin = margin
        self.spacing = spacing
        self.lazy = lazy
        self.resetKey = resetKey
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
            let next = max(previous ?? 0, tallest)
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
                .glassEffect(.regular, in: .circle)
                // Only the circle takes the click. The square's corners pass it to the card beneath, as they would with no chevron there.
                .contentShape(Circle())
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
                // How far the shelf must travel before another crossing ticks: the listener's shelf spacing, 6 to 40 points. Only
                // enough by default to keep a card resting on the edge from chattering; a swipe back over the gap ticks again.
                guard tracking.isUserScrolling, leading != nil,
                      abs(tracking.offset - tracking.offsetAtLastTick) >= Haptics.shelfTickSpacing else { return }
                tracking.offsetAtLastTick = tracking.offset
                Haptics.scrollSnapSoft()
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
