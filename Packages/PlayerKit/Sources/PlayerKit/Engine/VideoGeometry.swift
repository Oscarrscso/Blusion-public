import CoreGraphics
import PlaybackGeometry
import StremioKit

/// The app adapter for the geometry shared by AVPlayer, AetherPlayer and mpv.
public struct VideoGeometry: Equatable, Sendable {
    public let picture: CGRect
    public let content: CGRect
    public let visible: CGRect
    public let fittedScale: CGSize

    public init?(bounds: CGSize, source: CGSize, layout: VideoLayout) {
        self.init(bounds: bounds, source: source, aspect: layout.aspect.ratio, crop: layout.crop.ratio,
                  fit: layout.fit, zoom: layout.zoom, inset: layout.inset)
    }

    public init?(bounds: CGSize, source: CGSize, aspect: Double?, crop: Double?, fit: VideoFit, zoom: Double, inset: Double = 0) {
        let fit: PictureFit = switch fit { case .fit: .fit; case .fill: .fill; case .stretch: .stretch }
        guard let geometry = PictureGeometry(bounds: bounds, source: source, aspect: aspect, crop: crop,
                                             fit: fit, zoom: zoom, inset: inset) else { return nil }
        picture = geometry.picture
        content = geometry.content
        visible = geometry.visible
        fittedScale = geometry.fittedScale
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
