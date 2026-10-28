import CoreGraphics

public enum PictureFit: Sendable { case fit, fill, stretch }

/// All rectangles are calculated afresh from the original, unscaled source.
public struct PictureGeometry: Equatable, Sendable {
    /// The entire decoded frame, including encoded bars.
    public let picture: CGRect
    /// The visible picture before clipping to the screen.
    public let content: CGRect
    public let visible: CGRect
    /// Scale relative to the original source fitted in the whole screen (mpv's baseline).
    public let fittedScale: CGSize

    /// `crop` describes measured content in the SOURCE, while `aspect` describes that content's DISPLAY shape.
    /// An aspect selection never discards source pixels. Only Fill and an explicit zoom can discard picture content.
    public init?(bounds: CGSize, source: CGSize, aspect: Double? = nil, crop: Double? = nil,
                 fit: PictureFit = .fit, zoom: Double = 1, inset: Double = 0) {
        guard bounds.width.isFinite, bounds.height.isFinite, source.width.isFinite, source.height.isFinite,
              bounds.width > 0, bounds.height > 0, source.width > 0, source.height > 0 else { return nil }
        let sourceRatio = Double(source.width / source.height)
        let kept = Self.keptFraction(aspect: sourceRatio, crop: crop)
        let naturalRatio = sourceRatio * Double(kept.width / kept.height)
        let ratio = aspect.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } ?? naturalRatio
        let screenWidth = Double(bounds.width), screenHeight = Double(bounds.height)
        let areaWidth = fit == .fit ? max(1, screenWidth - 2 * (inset.isFinite ? max(0, inset) : 0)) : screenWidth
        var width: Double, height: Double
        switch fit {
        case .fit, .fill:
            if (fit == .fit) == (areaWidth / screenHeight < ratio) {
                width = areaWidth
                height = width / ratio
            } else {
                height = screenHeight
                width = height * ratio
            }
        case .stretch:
            width = screenWidth
            height = screenHeight
        }
        let extra = zoom.isFinite ? max(1, zoom) : 1
        width *= extra
        height *= extra
        content = CGRect(x: (screenWidth - width) / 2, y: (screenHeight - height) / 2, width: width, height: height)
        let pictureWidth = width / Double(kept.width), pictureHeight = height / Double(kept.height)
        picture = CGRect(x: content.midX - pictureWidth / 2, y: content.midY - pictureHeight / 2,
                         width: pictureWidth, height: pictureHeight)
        visible = content.intersection(CGRect(origin: .zero, size: bounds))
        fittedScale = CGSize(width: pictureWidth / min(screenWidth, screenHeight * sourceRatio),
                             height: pictureHeight / min(screenHeight, screenWidth / sourceRatio))
    }

    /// A centred measured crop, expressed as fractions of the original source, never the aspect-overridden picture.
    public static func keptFraction(aspect ratio: Double, crop: Double?) -> CGRect {
        guard let crop, crop.isFinite, crop > 0, ratio.isFinite, ratio > 0 else {
            return CGRect(x: 0, y: 0, width: 1, height: 1)
        }
        if crop > ratio {
            let height = ratio / crop
            return CGRect(x: 0, y: (1 - height) / 2, width: 1, height: height)
        }
        let width = crop / ratio
        return CGRect(x: (1 - width) / 2, y: 0, width: width, height: 1)
    }
}
