#if canImport(UIKit)
import SwiftUI

/// The stream cards that have already come in. The list is lazy, so a card scrolled away is built again when it comes back; the log
/// keeps it from coming in a second time. A plain class, not observed: writing to it redraws nothing.
@MainActor
final class StreamCardEntranceLog {
    var shown: Set<AnyHashable> = []
}

/// How a stream card arrives: it fades in while rising a little into place. The first few cards follow one another, so the list
/// fills from the top; a card further down comes in at once as it scrolls on. Reduce Motion keeps the fade and drops the movement.
private struct StreamCardEntrance: ViewModifier {
    let id: AnyHashable
    let order: Int
    let log: StreamCardEntranceLog
    @State private var isShown: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The cards that follow one another, and the gap between them.
    private static let staggered = 8
    private static let step = 0.045

    @MainActor
    init(id: AnyHashable, order: Int, log: StreamCardEntranceLog) {
        self.id = id
        self.order = order
        self.log = log
        _isShown = State(initialValue: log.shown.contains(id))
    }

    func body(content: Content) -> some View {
        let isMoved = !isShown && !reduceMotion
        content
            .opacity(isShown ? 1 : 0)
            .scaleEffect(isMoved ? 0.97 : 1, anchor: .top)
            .offset(y: isMoved ? 14 : 0)
            .onAppear {
                guard !isShown else { return }
                log.shown.insert(id)
                let delay = order < Self.staggered ? Double(order) * Self.step : 0
                withAnimation(reduceMotion ? .easeOut(duration: 0.2) : .spring(response: 0.42, dampingFraction: 0.86).delay(delay)) {
                    isShown = true
                }
            }
    }
}

extension View {
    /// Brings a stream card in the first time it is shown. `order` is its place in the list, counted from the top.
    func streamCardEntrance(id: AnyHashable, order: Int, log: StreamCardEntranceLog) -> some View {
        modifier(StreamCardEntrance(id: id, order: order, log: log))
    }
}
#endif
