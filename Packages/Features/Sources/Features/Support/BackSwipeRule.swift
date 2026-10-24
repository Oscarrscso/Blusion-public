import CoreGraphics

/// When a swipe on a pushed screen (a title's page) goes back. A swipe from the leading edge goes back at once, as the system's does. A
/// swipe that starts on the page goes back once it is plainly a swipe: a sixth of the page's width, or a quick flick of a few dozen points,
/// more sideways than up or down. A nudge of a few points, or a scroll that drifts sideways, keeps the page.
public enum BackSwipeRule {
    /// A swipe that starts this close to the leading edge is an edge swipe.
    public static let edgeWidth: CGFloat = 30
    /// The share of the page's width a swipe that starts on the page travels before it goes back.
    public static let pageTravel: CGFloat = 0.15
    /// How many times further across than up or down a swipe that starts on the page goes.
    public static let sidewaysRatio: CGFloat = 1.5
    /// A swipe on the page this fast (points a second, across) goes back sooner, after `flickTravel`.
    public static let flickSpeed: CGFloat = 600
    public static let flickTravel: CGFloat = 30

    /// Whether the swipe may start, `forward` towards the trailing edge and `vertical` down so far: more across than up or down.
    public static func mayBegin(forward: CGFloat, vertical: CGFloat, fromEdge: Bool) -> Bool {
        forward > abs(vertical)
    }

    /// Whether the swipe goes back now, `forward` towards the trailing edge and `vertical` down so far, moving across at `speed`, on a page
    /// `width` wide.
    public static func goesBack(forward: CGFloat, vertical: CGFloat, fromEdge: Bool, width: CGFloat, speed: CGFloat = 0) -> Bool {
        guard forward > 0 else { return false }
        if fromEdge { return forward > abs(vertical) }
        guard forward >= sidewaysRatio * abs(vertical) else { return false }
        return forward >= width * pageTravel || (speed >= flickSpeed && forward >= flickTravel)
    }
}
