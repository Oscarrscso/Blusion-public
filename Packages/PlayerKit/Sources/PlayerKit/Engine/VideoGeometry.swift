import CoreGraphics
import PlaybackGeometry
import StremioKit

/// The app adapter for the authoritative two-stage geometry shared by AVPlayer, AetherPlayer and mpv.
public struct VideoGeometry: Equatable, Sendable {
    /// The cropped movie region in original source coordinates, independent of screen dimensions.
    public let sourceRect: CGRect
    /// The portion of `source` that remains visible after display scaling and viewport clipping.
    public let visibleSourceRect: CGRect
    public let picture: CGRect
    public let content: CGRect
    public let visible: CGRect
    public let fittedScale: CGSize

    private let underlying: PictureGeometry

    public init?(bounds: CGSize, source: CGSize, pixelAspectRatio: Double = 1, cleanAperture: CGRect? = nil, layout: VideoLayout) {
        self.init(bounds: bounds, source: source, pixelAspectRatio: pixelAspectRatio, cleanAperture: cleanAperture,
                  aspect: layout.aspect.ratio, crop: layout.crop.ratio, fit: layout.fit, zoom: layout.zoom, inset: layout.inset)
    }

    public init?(bounds: CGSize, source: CGSize, pixelAspectRatio: Double = 1, cleanAperture: CGRect? = nil,
                 aspect: Double?, crop: Double?, fit: VideoFit, zoom: Double, inset: Double = 0) {
        let fit: PictureFit = switch fit { case .fit: .fit; case .fill: .fill; case .stretch: .stretch }
        guard let geometry = PictureGeometry(bounds: bounds, source: source, pixelAspectRatio: pixelAspectRatio,
                                             cleanAperture: cleanAperture, aspect: aspect, crop: crop,
                                             fit: fit, zoom: zoom, inset: inset) else { return nil }
        underlying = geometry
        sourceRect = geometry.sourceRect
        visibleSourceRect = geometry.visibleSourceRect
        picture = geometry.picture
        content = geometry.content
        visible = geometry.visible
        fittedScale = geometry.fittedScale
    }

    public func displayPoint(forSource point: CGPoint) -> CGPoint {
        underlying.displayPoint(forSource: point)
    }

    public func sourcePoint(forDisplay point: CGPoint) -> CGPoint {
        underlying.sourcePoint(forDisplay: point)
    }

    public static func sourceCropRect(source: CGSize, pixelAspectRatio: Double = 1, cleanAperture: CGRect? = nil,
                                      crop: Double?) -> CGRect? {
        PictureGeometry.sourceCropRect(source: source, pixelAspectRatio: pixelAspectRatio, cleanAperture: cleanAperture, crop: crop)
    }

    /// Scale a fitted original frame just enough to fill; there is no overshoot or second crop.
    public static func fillScale(bounds: CGSize, source: CGSize, crop: Double?, stretch: Bool, zoom: Double = 1) -> CGSize {
        PictureGeometry(bounds: bounds, source: source, crop: crop, fit: stretch ? .stretch : .fill, zoom: zoom)?.fittedScale
            ?? CGSize(width: 1, height: 1)
    }

    public static func keptFraction(aspect: Double, crop: Double?) -> CGRect {
        PictureGeometry.keptFraction(aspect: aspect, crop: crop)
    }
}
