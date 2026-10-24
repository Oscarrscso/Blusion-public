#if canImport(UIKit)
import SwiftUI
import StremioKit
import UIKit

/// A press held still for `minimumDuration`, as UIKit's long press reads it: `began` once the time is up, `ended` when the finger lifts
/// or the press is called off. Once it has begun, the tap under it (a card's link) does not fire, and a press that moves first is a
/// scroll, not a hold.
struct HoldGesture: UIGestureRecognizerRepresentable {
    var minimumDuration: TimeInterval = 1
    let began: () -> Void
    let ended: () -> Void

    func makeUIGestureRecognizer(context: Context) -> UILongPressGestureRecognizer {
        let recognizer = UILongPressGestureRecognizer()
        recognizer.minimumPressDuration = minimumDuration
        return recognizer
    }

    func handleUIGestureRecognizerAction(_ recognizer: UILongPressGestureRecognizer, context: Context) {
        switch recognizer.state {
        case .began: began()
        case .ended, .cancelled, .failed: ended()
        default: break
        }
    }
}

extension View {
    /// Holding the view for a second plays `item` through the environment's `PosterPlayLauncher` (see there). Without one, nothing.
    func holdsToPlay(_ item: MetaPreview) -> some View {
        modifier(HoldToPlayModifier(item: item))
    }
}

private struct HoldToPlayModifier: ViewModifier {
    let item: MetaPreview
    @Environment(PosterPlayLauncher.self) private var launcher: PosterPlayLauncher?

    func body(content: Content) -> some View {
        if let launcher {
            content
                .gesture(HoldGesture(began: {
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    launcher.pressBecameHold(item)
                    launcher.begin(item)
                }, ended: {
                    launcher.end(item)
                    launcher.holdLifted(item)
                }))
                // A card taken off the screen while held never hears the finger lift: its hold ends with it.
                .onDisappear {
                    launcher.end(item)
                    launcher.holdLifted(item)
                }
        } else {
            content
        }
    }
}
#endif
