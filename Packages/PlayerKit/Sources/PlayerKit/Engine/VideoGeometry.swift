import CoreGraphics
import StremioKit

/// Where a picture sits in a view for a `VideoLayout`: the aspect override, the crop, fit, fill or stretch, and the zoom. The video surface
/// draws the whole decoded picture into `picture` and shows only `visible`, so a crop takes the bars off without the engine knowing.
/// AetherPlayer keeps its own copy (`AetherHostView`), as that framework links no Blusion package.
public struct VideoGeometry: Equatable, Sendable {
    /// The whole decoded picture, in the view's coordinates. It can run past the view.
    public let picture: CGRect
    /// The part that shows: the cropped picture, clipped to the view.
    public let visible: CGRect

    /// nil when the view or the picture has no size yet.
    public init?(bounds: CGSize, source: CGSize, layout: VideoLayout) {
        self.init(bounds: bounds, source: source, aspect: layout.aspect.ratio, crop: layout.crop.ratio, fit: layout.fit, zoom: layout.zoom)
    }

    public init?(bounds: CGSize, source: CGSize, aspect: Double?, crop: Double?, fit: VideoFit, zoom: Double) {
        guard bounds.width > 0, bounds.height > 0, source.width > 0, source.height > 0 else { return nil }
        let ratio = aspect ?? Double(source.width / source.height)
        // The kept part, as fractions of the picture: the full width and less height for a wider crop, the other way for a narrower one.
        var keptWidth = 1.0, keptHeight = 1.0
        if let crop, crop > 0 {
            if crop > ratio { keptHeight = ratio / crop } else { keptWidth = crop / ratio }
        }
        let shownRatio = ratio * keptWidth / keptHeight
        let viewRatio = Double(bounds.width / bounds.height)
        var width: Double, height: Double
        switch fit {
        case .fit, .fill:
            let byWidth = (fit == .fit) == (viewRatio < shownRatio)
            if byWidth {
                width = Double(bounds.width)
                height = width / shownRatio
            } else {
                height = Double(bounds.height)
                width = height * shownRatio
            }
        case .stretch:
            width = Double(bounds.width)
            height = Double(bounds.height)
        }
        let scale = max(1, zoom)
        width *= scale
        height *= scale
        let shown = CGRect(x: (Double(bounds.width) - width) / 2, y: (Double(bounds.height) - height) / 2, width: width, height: height)
        let pictureWidth = width / keptWidth
        let pictureHeight = height / keptHeight
        picture = CGRect(x: shown.midX - pictureWidth / 2, y: shown.midY - pictureHeight / 2, width: pictureWidth, height: pictureHeight)
        visible = shown.intersection(CGRect(origin: .zero, size: bounds))
    }

    /// The kept part as fractions of the picture (x, y, width, height), for an engine that crops in source pixels (mpv's `video-crop`).
    public static func keptFraction(aspect ratio: Double, crop: Double?) -> CGRect {
        guard let crop, crop > 0, ratio > 0 else { return CGRect(x: 0, y: 0, width: 1, height: 1) }
        if crop > ratio {
            let height = ratio / crop
            return CGRect(x: 0, y: (1 - height) / 2, width: 1, height: height)
        }
        let width = crop / ratio
        return CGRect(x: (1 - width) / 2, y: 0, width: width, height: 1)
    }
}
