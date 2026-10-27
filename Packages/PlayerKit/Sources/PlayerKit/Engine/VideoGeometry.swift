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
        self.init(bounds: bounds, source: source, aspect: layout.aspect.ratio, crop: layout.crop.ratio, fit: layout.fit, zoom: layout.zoom,
                  inset: layout.inset)
    }

    /// `inset` keeps Fit and Fill that far from the left and the right (the safe area beside a notch); the picture stays centred.
    public init?(bounds: CGSize, source: CGSize, aspect: Double?, crop: Double?, fit: VideoFit, zoom: Double, inset: Double = 0) {
        guard bounds.width > 0, bounds.height > 0, source.width > 0, source.height > 0 else { return nil }
        let ratio = aspect ?? Double(source.width / source.height)
        // The kept part, as fractions of the picture: the full width and less height for a wider crop, the other way for a narrower one.
        var keptWidth = 1.0, keptHeight = 1.0
        if let crop, crop > 0 {
            if crop > ratio { keptHeight = ratio / crop } else { keptWidth = crop / ratio }
        }
        let shownRatio = ratio * keptWidth / keptHeight
        let areaWidth = max(1, Double(bounds.width) - 2 * max(0, inset))
        let viewRatio = areaWidth / Double(bounds.height)
        var width: Double, height: Double
        switch fit {
        case .fit, .fill:
            let byWidth = (fit == .fit) == (viewRatio < shownRatio)
            if byWidth {
                width = areaWidth
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

    /// Crop and Stretch as a scale of the fitted picture. The engine draws the whole picture fitted in the view, exactly as in Normal, and
    /// the view is scaled about its centre by this much, so the kept part of the picture covers the view. Crop scales both ways alike and
    /// overshoots each edge by a point, so no hairline of black shows; Stretch scales each way to the view.
    public static func fillScale(bounds: CGSize, source: CGSize, crop: Double?, stretch: Bool, zoom: Double = 1) -> CGSize {
        guard bounds.width > 0, bounds.height > 0, source.width > 0, source.height > 0 else { return CGSize(width: 1, height: 1) }
        let width = Double(bounds.width), height = Double(bounds.height)
        let ratio = Double(source.width / source.height)
        let kept = keptFraction(aspect: ratio, crop: crop)
        // The whole picture fitted in the view.
        let fittedWidth = min(width, height * ratio)
        let fittedHeight = min(height, width / ratio)
        let scaleX = width / (fittedWidth * Double(kept.width))
        let scaleY = height / (fittedHeight * Double(kept.height))
        let extra = max(1, zoom)
        if stretch { return CGSize(width: scaleX * extra, height: scaleY * extra) }
        let overshoot = max((width + 2) / width, (height + 2) / height)
        let scale = max(scaleX, scaleY) * overshoot * extra
        return CGSize(width: scale, height: scale)
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
