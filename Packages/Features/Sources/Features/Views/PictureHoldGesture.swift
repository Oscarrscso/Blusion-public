#if canImport(UIKit)
import SwiftUI
import UIKit
import UIKit.UIGestureRecognizerSubclass

/// The press-and-hold on the picture, as UIKit's long press reads it: `began` once the finger has rested for `minimumDuration` without
/// moving more than `SpeedHoldRules.holdTolerance`, `moved` for each move the held finger makes, and `ended` when it lifts, is taken by
/// the system, or moved too far before the hold began (the press then fails). UIKit times the press itself, as it does for the poster
/// hold, so the hold never waits for a drag to report the finger.
struct PictureHoldGesture: UIGestureRecognizerRepresentable {
    var minimumDuration: TimeInterval
    let touchBegan: () -> Void
    let began: (CGPoint) -> Void
    let moved: (CGPoint) -> Void
    let ended: () -> Void

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }

    func makeUIGestureRecognizer(context: Context) -> PictureLongPressRecognizer {
        let recognizer = PictureLongPressRecognizer()
        recognizer.minimumPressDuration = minimumDuration
        recognizer.allowableMovement = SpeedHoldRules.holdTolerance
        recognizer.touchBegan = touchBegan
        recognizer.delegate = context.coordinator
        recognizer.cancelsTouchesInView = false
        return recognizer
    }

    func updateUIGestureRecognizer(_ recognizer: PictureLongPressRecognizer, context: Context) {
        recognizer.touchBegan = touchBegan
    }

    func handleUIGestureRecognizerAction(_ recognizer: PictureLongPressRecognizer, context: Context) {
        let point = context.converter.localLocation
        switch recognizer.state {
        case .began: began(point)
        case .changed: moved(point)
        case .ended, .cancelled, .failed: ended()
        default: break
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            // SwiftUI's simultaneous DragGesture does not configure this UIKit recognizer's delegate.
            // Keep receiving hold movement when that drag recognizes; PlayerScreen routes it using touch ownership.
            true
        }
    }
}

final class PictureLongPressRecognizer: UILongPressGestureRecognizer {
    var touchBegan: (() -> Void)?
    private var tracksTouch = false

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        // Only the first finger starts a new sequence. Adding a finger must not release a hold's ownership.
        if !tracksTouch {
            tracksTouch = true
            touchBegan?()
        }
        super.touchesBegan(touches, with: event)
    }

    override func reset() {
        super.reset()
        tracksTouch = false
    }
}
#endif
