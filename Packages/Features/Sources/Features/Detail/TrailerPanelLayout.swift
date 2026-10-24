import Foundation

/// The size of the title page's trailer panel for a picture of a given shape.
public enum TrailerPanelLayout {
    /// The shape the panel takes when the picture's shape is not known.
    public static let defaultAspectRatio = 16.0 / 9.0

    /// The common shapes a picture is snapped to, since the players report rounded sizes.
    private static let commonAspectRatios = [16.0 / 9.0, 4.0 / 3.0, 1.0, 9.0 / 16.0, 21.0 / 9.0, 2.39]

    /// The shape the panel takes: `given` when it is known and between 0.4 and 3, else 16:9. A shape within 2% of a common one is that
    /// one exactly, the nearest when more than one is that close.
    public static func aspectRatio(_ given: Double?) -> Double {
        guard let given, given.isFinite, (0.4...3).contains(given) else { return defaultAspectRatio }
        let near = commonAspectRatios.filter { abs(given - $0) <= 0.02 * $0 }
        return near.min { abs(given - $0) < abs(given - $1) } ?? given
    }

    /// The panel's size in a space `width` wide and at most `maxHeight` tall: as wide as the space when its height fits, else as tall
    /// as `maxHeight` and narrower, so a tall picture never makes a panel taller than the space allows. Zero for a width or height of
    /// 0 or less.
    public static func size(aspectRatio given: Double?, width: Double, maxHeight: Double) -> (width: Double, height: Double) {
        guard width.isFinite, maxHeight.isFinite, width > 0, maxHeight > 0 else { return (0, 0) }
        let ratio = aspectRatio(given)
        var width = width
        var height = width / ratio
        if height > maxHeight {
            height = maxHeight
            width = maxHeight * ratio
        }
        return (width, height)
    }
}
