#if canImport(UIKit)
import SwiftUI
import StremioKit
import UIKit

/// A title opened from a card: the value a `MediaCardLink` pushes. `sourceID` names the exact card, so the title's screen zooms
/// out of that artwork even when the same title is on screen in two rows.
struct TitleDestination: Hashable {
    let preview: MetaPreview
    let sourceID: String
    var artwork: TMDbArtwork?
    var artworkChecked = false
    /// Opens with no animation, for a source whose picture and logo the title page repeats in the same place (Home's spotlight): only
    /// the content below changes. `sourceID` is unused then.
    var opensInstantly = false
    /// The picture and logo the spotlight page showed when it opened this title, so the title page starts with them (see `HeroHandoff`).
    var handoff: HeroHandoff?
    /// The item to resume, for a Continue Watching card: the title page opens with its stream picker already on the page, as if Play had
    /// been tapped for this request. Nil opens the details.
    var streams: StreamRequest?
}

extension EnvironmentValues {
    /// The namespace cards and the screens they open share. Set once per navigation stack by `zoomTransitions()`.
    @Entry var zoomNamespace: Namespace.ID?
    /// Tells apart the cards of different rows that show the same title. `MediaRow` and `MediaGrid` set it; a custom container
    /// of `MediaCardLink`s should set its own.
    @Entry var zoomScope: String = ""
}

private struct ZoomNamespaceProvider: ViewModifier {
    @Namespace private var namespace

    func body(content: Content) -> some View {
        content.environment(\.zoomNamespace, namespace)
    }
}

extension View {
    /// Lets the cards in a navigation stack zoom into the screens they open. Apply to the `NavigationStack` itself.
    func zoomTransitions() -> some View {
        modifier(ZoomNamespaceProvider())
    }

    /// Marks the artwork a screen zooms out of. `cornerRadius` rounds the artwork while it morphs into the screen, so a card keeps its
    /// corners; leave it nil for full-bleed artwork. Does nothing without a namespace (outside a stack that called `zoomTransitions()`).
    @ViewBuilder
    func zoomSource(id: String, in namespace: Namespace.ID?, cornerRadius: CGFloat? = nil) -> some View {
        if let namespace, let cornerRadius {
            let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            matchedTransitionSource(id: id, in: namespace) { $0.clipShape(shape) }
        } else if let namespace {
            matchedTransitionSource(id: id, in: namespace)
        } else {
            self
        }
    }

    /// Makes a pushed screen zoom out of the artwork marked with the same id. A back swipe closes it at once (see `BackSwipe`).
    @ViewBuilder
    func zoomDestination(id: String, in namespace: Namespace.ID?) -> some View {
        if let namespace {
            navigationTransition(.zoom(sourceID: id, in: namespace))
        } else {
            self
        }
    }

    /// A pushed title that opened with no animation (`TitleDestination.opensInstantly`) also closes with none: its back button and the
    /// back swipe both pop through `AppRouter.goBack`, which closes it with animations off. Mac keeps the system back button, which
    /// animates its own pop.
    func instantDestination() -> some View {
        modifier(InstantDestination())
    }

    /// Gives a navigation stack its one back swipe: a swipe towards the trailing edge, anywhere on a pushed screen, pops that screen
    /// through the router. Apply to the stack's root screen, with the stack's path.
    func backSwipe(path: ReferenceWritableKeyPath<AppRouter, NavigationPath>) -> some View {
        modifier(BackSwipeModifier(path: path))
    }
}

private struct InstantDestination: ViewModifier {
    @Environment(\.isPhoneLandscape) private var isPhoneLandscape
    @Environment(AppRouter.self) private var router

    func body(content: Content) -> some View {
        #if targetEnvironment(macCatalyst)
        content
        #else
        content
            .navigationBarBackButtonHidden()
            .toolbar {
                if !isPhoneLandscape || UIDevice.current.userInterfaceIdiom != .phone {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            router.goBack(in: \.homePath)
                        } label: {
                            Image(systemName: "chevron.backward")
                                .fontWeight(.semibold)
                        }
                        .accessibilityLabel("Back")
                        .accessibilityIdentifier("detail.back")
                    }
                }
            }
        #endif
    }
}

private struct BackSwipeModifier: ViewModifier {
    @Environment(AppRouter.self) private var router
    let path: ReferenceWritableKeyPath<AppRouter, NavigationPath>

    func body(content: Content) -> some View {
        content.background {
            BackSwipeInstaller { router.goBack(in: path) }
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}

private struct BackSwipeInstaller: UIViewRepresentable {
    /// Goes back. True when the screen on top was popped; false when it stays.
    let onSwipe: () -> Bool

    func makeUIView(context: Context) -> BackSwipeProbe {
        let probe = BackSwipeProbe()
        probe.isUserInteractionEnabled = false
        return probe
    }

    func updateUIView(_ probe: BackSwipeProbe, context: Context) {
        probe.swipe.onSwipe = onSwipe
    }

    static func dismantleUIView(_ probe: BackSwipeProbe, coordinator: ()) {
        probe.swipe.attach(to: nil)
    }
}

/// Sits unseen in a stack's root screen to find the stack's navigation controller, which SwiftUI does not hand out.
private final class BackSwipeProbe: UIView {
    let swipe = BackSwipe()

    override func didMoveToWindow() {
        super.didMoveToWindow()
        // The root screen leaves the window while another screen covers it. The swipe stays on the stack until this view is taken apart.
        guard window != nil else { return }
        if let stack { swipe.attach(to: stack) }
        guard swipe.isDetached else { return }
        // The screen may not be in its navigation controller yet on the first pass.
        Task { @MainActor [weak self] in
            guard let self, self.window != nil, self.swipe.isDetached, let stack = self.stack else { return }
            self.swipe.attach(to: stack)
        }
    }

    /// The navigation controller the screen this view is in sits in, found up the responder chain.
    private var stack: UINavigationController? {
        var responder = next
        while let current = responder {
            if let stack = (current as? UIViewController)?.navigationController { return stack }
            responder = current.next
        }
        return nil
    }
}

/// Sees every touch on a stack's screens and reports it to `SwipeRecord.latest`. It never recognizes, and it does not delay or cancel
/// touches, so scrolling, taps and the back swipe behave as they did.
@MainActor
private final class SwipeWatch: UIGestureRecognizer {
    /// The touch being followed: the most recent one to begin. A new touch restarts it, so a touch UIKit lost cannot block the next.
    private var tracked: UITouch?
    /// Where the tracked touch began, in the stack's view.
    private var start: CGPoint?

    override init(target: Any?, action: Selector?) {
        super.init(target: nil, action: nil)
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesBegan(touches, with: event)
        guard let view, let touch = touches.first else { return }
        tracked = touch
        let point = touch.location(in: view)
        start = point
        // The leading edge only, where a swipe back starts.
        let atEdge = view.effectiveUserInterfaceLayoutDirection == .rightToLeft
            ? point.x > view.bounds.width - SwipeRecord.edgeWidth : point.x < SwipeRecord.edgeWidth
        SwipeRecord.latest.touchBegan(at: ContinuousClock.now, atEdge: atEdge)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesMoved(touches, with: event)
        guard let view, let tracked, touches.contains(tracked), let start else { return }
        let point = tracked.location(in: view)
        SwipeRecord.latest.touchMoved(distance: hypot(point.x - start.x, point.y - start.y))
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesEnded(touches, with: event)
        finish(touches)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesCancelled(touches, with: event)
        finish(touches)
    }

    private func finish(_ touches: Set<UITouch>) {
        guard let tracked, touches.contains(tracked) else { return }
        self.tracked = nil
        SwipeRecord.latest.touchEnded(at: ContinuousClock.now)
    }
}

/// A navigation stack's one back swipe: a pan recognizer on the stack's view that pops the screen on top through the router, at once,
/// the way the back button does.
///
/// It is the only gesture that pops. The stack's own back swipes (from the edge, and from anywhere on the content) are switched off for
/// as long as it is attached, so a swipe is never answered twice. A zoomed screen also has ways out of its own, on the screen's view:
/// pans that drag the screen and let it settle after the finger lifts. Until that settle ends, about a second, the screen is still the
/// one on top: its back button stays, the screen underneath takes no touches, and a new touch catches the closing screen again. Those
/// pans are switched off too. SwiftUI's zoom has no setting for them (UIKit's own has `interactiveDismissShouldBegin`, which SwiftUI
/// does not pass on), so they are found by what they are, with no private class named: pan recognizers on the screen's view whose
/// delegate is an interaction installed on that same view. The zoom's pinch to close is not a pan and is left to UIKit.
///
/// A screen that is still arriving can be swiped away at once. The zoom that opens a title takes about a second to settle, and UIKit
/// lets a pop turn such a push round, so the swipe only waits for a screen that is already leaving (see `isLeaving`).
@MainActor
private final class BackSwipe: NSObject, UIGestureRecognizerDelegate {
    /// Goes back. True when the screen on top was popped; false when it stays.
    var onSwipe: () -> Bool = { false }
    private lazy var pan: UIPanGestureRecognizer = {
        let pan = UIPanGestureRecognizer(target: self, action: #selector(swiped))
        pan.maximumNumberOfTouches = 1
        pan.delegate = self
        return pan
    }()
    /// Sees every touch on the stack, so a card can tell a swipe from a tap whether or not `pan` recognized the swipe.
    private lazy var watch = SwipeWatch(target: nil, action: nil)
    private weak var stack: UINavigationController?
    private weak var touched: UIView?
    private var startsAtEdge = false
    /// Set once this swipe has gone back, so a swipe that goes on does not go back twice.
    private var hasGoneBack = false

    /// A swipe that starts this close to the leading edge goes back at once, even over a shelf that has been scrolled (see `BackSwipeRule`).
    private static let edgeWidth = BackSwipeRule.edgeWidth

    var isDetached: Bool { stack == nil }

    func attach(to stack: UINavigationController?) {
        guard stack !== self.stack else { return }
        pan.view?.removeGestureRecognizer(pan)
        watch.view?.removeGestureRecognizer(watch)
        // The stack this swipe leaves gets its own back swipes again.
        systemPops.forEach { $0.isEnabled = true }
        self.stack = stack
        stack?.view.addGestureRecognizer(pan)
        stack?.view.addGestureRecognizer(watch)
        silenceSystemGestures()
    }

    /// The stack's own back swipes: from the leading edge, and from anywhere on the content.
    private var systemPops: [UIGestureRecognizer] {
        [stack?.interactivePopGestureRecognizer, stack?.interactiveContentPopGestureRecognizer].compactMap { $0 }
    }

    /// The screen on top when it is a pushed one. The root screen has nothing to go back to.
    private var pushed: UIViewController? {
        guard let stack, stack.viewControllers.count > 1 else { return nil }
        return stack.topViewController
    }

    private var isRightToLeft: Bool { stack?.view.effectiveUserInterfaceLayoutDirection == .rightToLeft }

    /// True while a pop is running that brought `controller` to the top: the screen above it is on its way out, and a second swipe must
    /// not pop again. False with no transition, and false while `controller` itself is still arriving: the screen it was pushed from
    /// is then still under it in the stack.
    private func isLeaving(_ controller: UIViewController) -> Bool {
        guard let coordinator = controller.transitionCoordinator else { return false }
        guard let stack, coordinator.viewController(forKey: .to) === controller,
              let origin = coordinator.viewController(forKey: .from) else { return true }
        return !stack.viewControllers.contains(origin)
    }

    /// A zoomed screen's own dismissal pans, see the type's comment.
    private func dismissalPans(on page: UIView) -> [UIGestureRecognizer] {
        (page.gestureRecognizers ?? []).filter { recognizer in
            guard recognizer is UIPanGestureRecognizer, let delegate = recognizer.delegate else { return false }
            return page.interactions.contains { ($0 as AnyObject) === (delegate as AnyObject) }
        }
    }

    /// Switches off UIKit's ways back: the stack's edge and content swipes, and the dismissal pans of the screen on top. UIKit can
    /// switch them back on, so every touch does this again.
    private func silenceSystemGestures() {
        systemPops.forEach { $0.isEnabled = false }
        guard let page = stack?.topViewController?.viewIfLoaded else { return }
        dismissalPans(on: page).forEach { $0.isEnabled = false }
    }

    private func isSystemWayBack(_ recognizer: UIGestureRecognizer) -> Bool {
        if systemPops.contains(where: { $0 === recognizer }) { return true }
        guard let page = stack?.topViewController?.viewIfLoaded else { return false }
        return dismissalPans(on: page).contains { $0 === recognizer }
    }

    /// Goes back once the swipe means it (see `BackSwipeRule`): an edge swipe as it starts, a swipe on the page once it has travelled a
    /// sixth of the page's width, or sooner as a quick flick, more sideways than up or down. A swipe that stops short keeps the page.
    @objc private func swiped() {
        switch pan.state {
        case .began: hasGoneBack = false
        case .changed: break
        default: hasGoneBack = false; return
        }
        guard !hasGoneBack, let controller = pushed, !isLeaving(controller), let page = controller.viewIfLoaded else { return }
        let movement = pan.translation(in: page)
        let forward = isRightToLeft ? -movement.x : movement.x
        let speed = isRightToLeft ? -pan.velocity(in: page).x : pan.velocity(in: page).x
        guard BackSwipeRule.goesBack(forward: forward, vertical: movement.y, fromEdge: startsAtEdge, width: page.bounds.width, speed: speed)
        else { return }
        hasGoneBack = true
        // The same light tap as opening a title, once per swipe that goes back.
        Haptics.tap()
        // A screen that was not popped stays, and keeps taking touches.
        guard onSwipe() else { return }
        // Off at once: a touch that lands while the screen zooms away goes to the screen underneath.
        page.isUserInteractionEnabled = false
        // Should the pop not happen, the screen works again.
        Task { [weak page] in
            try? await Task.sleep(for: .seconds(1.5))
            if let page, page.window != nil { page.isUserInteractionEnabled = true }
        }
    }

    /// A sideways shelf that has been scrolled keeps the swipe: it scrolls back to its start first.
    private func isOverScrolledShelf(within page: UIView) -> Bool {
        var view = touched
        while let current = view, current !== page {
            if let shelf = current as? UIScrollView, shelf.isScrollEnabled, shelf.contentSize.width > shelf.bounds.width + 1 {
                let start = -shelf.adjustedContentInset.left
                let end = shelf.contentSize.width - shelf.bounds.width + shelf.adjustedContentInset.right
                if isRightToLeft ? shelf.contentOffset.x < end - 1 : shelf.contentOffset.x > start + 1 { return true }
            }
            view = current.superview
        }
        return false
    }

    /// Only touches on the pushed screen itself count, as when the swipe sat on that screen's view: not the bars around it.
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        silenceSystemGestures()
        guard let page = pushed?.viewIfLoaded, let view = touch.view, view.isDescendant(of: page) else { return false }
        // Only the touch that starts a swipe says where it began: a second finger landing at the edge mid-swipe changes nothing.
        guard pan.state == .possible else { return true }
        touched = view
        let x = touch.location(in: page).x
        startsAtEdge = isRightToLeft ? x > page.bounds.width - Self.edgeWidth : x < Self.edgeWidth
        return true
    }

    /// Only a swipe towards the trailing edge that is more sideways than vertical (see `BackSwipeRule`), on a pushed screen that is not
    /// already on its way out. Anything else fails here, and the page's scrolling carries on as it would without this recognizer.
    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let controller = pushed, let page = controller.viewIfLoaded else { return false }
        let movement = pan.translation(in: page)
        let forward = isRightToLeft ? -movement.x : movement.x
        guard !isLeaving(controller), BackSwipeRule.mayBegin(forward: forward, vertical: movement.y, fromEdge: startsAtEdge) else { return false }
        return startsAtEdge || !isOverScrolledShelf(within: page)
    }

    /// Scrolling and the screen's own gestures are left alone: they track the same touch, so they start no later than before. UIKit's
    /// ways back are not: one that UIKit switched back on must not pop alongside this one.
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        !isSystemWayBack(otherGestureRecognizer)
    }
}
#endif
