import CoreGraphics

public enum PictureFit: Sendable { case fit, fill, stretch }

/// Two-stage playback geometry calculated afresh from the original, unscaled source:
/// 1. `sourceRect` crops encoded black bars strictly in source space, independent of screen dimensions.
/// 2. `content`, `picture` and `visible` independently scale and centre `sourceRect` into `bounds`.
public struct PictureGeometry: Equatable, Sendable {
    /// Relative tolerance within which a target crop matches the source's own aspect (e.g. 1920x1038 for 1.85:1).
    public static let aspectMatchTolerance = 0.002

    /// The active movie area in original source coordinates after removing encoded bars (and applying clean aperture).
    public let sourceRect: CGRect
    /// The portion of `source` that remains visible on screen after display scaling and viewport clipping.
    public let visibleSourceRect: CGRect
    /// The entire decoded source frame placed in display coordinates, including any cropped bars.
    public let picture: CGRect
    /// The cropped movie content placed in display coordinates before clipping to `bounds`.
    public let content: CGRect
    /// The on-screen intersection of `content` with `bounds`.
    public let visible: CGRect
    /// Scale of `picture` relative to fitting the uncropped source inside `bounds` (mpv's baseline).
    public let fittedScale: CGSize

    /// `crop` trims encoded bars in the SOURCE (`sourceRect`), while `aspect` overrides that content's DISPLAY shape.
    /// Source cropping never consults `bounds`; only `.fill` or `zoom > 1` can clip inside `sourceRect`.
    public init?(bounds: CGSize, source: CGSize, pixelAspectRatio: Double = 1, cleanAperture: CGRect? = nil,
                 aspect: Double? = nil, crop: Double? = nil, fit: PictureFit = .fit, zoom: Double = 1, inset: Double = 0) {
        guard bounds.width.isFinite, bounds.height.isFinite, bounds.width > 0, bounds.height > 0,
              let sourceRect = Self.sourceCropRect(source: source, pixelAspectRatio: pixelAspectRatio,
                                                   cleanAperture: cleanAperture, crop: crop) else { return nil }
        self.sourceRect = sourceRect

        let par = pixelAspectRatio.isFinite && pixelAspectRatio > 0 ? pixelAspectRatio : 1
        let naturalRatio = (Double(sourceRect.width) * par) / Double(sourceRect.height)
        let displayRatio = aspect.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } ?? naturalRatio

        let screenWidth = Double(bounds.width), screenHeight = Double(bounds.height)
        let safeInset = inset.isFinite ? max(0, inset) : 0
        let areaWidth = fit == .fit ? max(1, screenWidth - 2 * safeInset) : screenWidth
        var width: Double, height: Double
        switch fit {
        case .fit:
            if areaWidth / screenHeight < displayRatio {
                width = areaWidth
                height = width / displayRatio
            } else {
                height = screenHeight
                width = height * displayRatio
            }
        case .fill:
            if screenWidth / screenHeight > displayRatio {
                width = screenWidth
                height = width / displayRatio
            } else {
                height = screenHeight
                width = height * displayRatio
            }
        case .stretch:
            width = screenWidth
            height = screenHeight
        }
        let extra = zoom.isFinite ? max(1, zoom) : 1
        width *= extra
        height *= extra

        let contentRect = CGRect(x: (screenWidth - width) / 2, y: (screenHeight - height) / 2, width: width, height: height)
        content = contentRect

        let scaleX = width / Double(sourceRect.width)
        let scaleY = height / Double(sourceRect.height)
        let pictureX = Double(contentRect.minX) - Double(sourceRect.minX) * scaleX
        let pictureY = Double(contentRect.minY) - Double(sourceRect.minY) * scaleY
        let pictureWidth = Double(source.width) * scaleX
        let pictureHeight = Double(source.height) * scaleY
        picture = CGRect(x: pictureX, y: pictureY, width: pictureWidth, height: pictureHeight)

        let clipped = contentRect.intersection(CGRect(origin: .zero, size: bounds))
        let visibleRect = clipped.isNull ? .zero : clipped
        visible = visibleRect

        if visibleRect.width > 0, visibleRect.height > 0, scaleX > 0, scaleY > 0 {
            visibleSourceRect = CGRect(
                x: (Double(visibleRect.minX) - pictureX) / scaleX,
                y: (Double(visibleRect.minY) - pictureY) / scaleY,
                width: Double(visibleRect.width) / scaleX,
                height: Double(visibleRect.height) / scaleY
            )
        } else {
            visibleSourceRect = .zero
        }

        let fullRatio = (Double(source.width) * par) / Double(source.height)
        fittedScale = CGSize(width: pictureWidth / min(screenWidth, screenHeight * fullRatio),
                             height: pictureHeight / min(screenHeight, screenWidth / fullRatio))
    }

    /// Maps a point in original `source` coordinates to display (`bounds`) coordinates.
    public func displayPoint(forSource point: CGPoint) -> CGPoint {
        guard sourceRect.width > 0, sourceRect.height > 0 else { return .zero }
        let scaleX = content.width / sourceRect.width
        let scaleY = content.height / sourceRect.height
        return CGPoint(x: picture.minX + point.x * scaleX, y: picture.minY + point.y * scaleY)
    }

    /// Maps a point in display (`bounds`) coordinates back to original `source` coordinates.
    public func sourcePoint(forDisplay point: CGPoint) -> CGPoint {
        guard content.width > 0, content.height > 0 else { return .zero }
        let scaleX = content.width / sourceRect.width
        let scaleY = content.height / sourceRect.height
        return CGPoint(x: (point.x - picture.minX) / scaleX, y: (point.y - picture.minY) / scaleY)
    }

    /// Calculates the source content rectangle strictly from the video's own dimensions, pixel aspect ratio,
    /// optional clean aperture, and target movie aspect ratio. Screen dimensions never enter this calculation.
    public static func sourceCropRect(source: CGSize, pixelAspectRatio: Double = 1, cleanAperture: CGRect? = nil,
                                      crop: Double? = nil) -> CGRect? {
        guard source.width.isFinite, source.height.isFinite, source.width > 0, source.height > 0 else { return nil }
        let par = pixelAspectRatio.isFinite && pixelAspectRatio > 0 ? pixelAspectRatio : 1
        let full = CGRect(origin: .zero, size: source)
        let aperture: CGRect
        if let cleanAperture,
           cleanAperture.origin.x.isFinite, cleanAperture.origin.y.isFinite,
           cleanAperture.width.isFinite, cleanAperture.height.isFinite,
           cleanAperture.width > 0, cleanAperture.height > 0 {
            let clamped = cleanAperture.intersection(full)
            aperture = !clamped.isNull && clamped.width > 0 && clamped.height > 0 ? clamped : full
        } else {
            aperture = full
        }
        guard let crop, crop.isFinite, crop > 0 else { return aperture }
        let apertureAspect = (Double(aperture.width) * par) / Double(aperture.height)
        guard abs(crop - apertureAspect) / max(crop, apertureAspect) >= aspectMatchTolerance else {
            return aperture
        }
        if crop > apertureAspect {
            let height = Double(aperture.height) * (apertureAspect / crop)
            let y = Double(aperture.minY) + (Double(aperture.height) - height) / 2
            return CGRect(x: Double(aperture.minX), y: y, width: Double(aperture.width), height: height)
        } else {
            let width = Double(aperture.width) * (crop / apertureAspect)
            let x = Double(aperture.minX) + (Double(aperture.width) - width) / 2
            return CGRect(x: x, y: Double(aperture.minY), width: width, height: Double(aperture.height))
        }
    }

    /// A centred measured crop, expressed as fractions of the original source, never the aspect-overridden picture.
    public static func keptFraction(aspect ratio: Double, crop: Double?) -> CGRect {
        guard let crop, crop.isFinite, crop > 0, ratio.isFinite, ratio > 0,
              abs(crop - ratio) / max(crop, ratio) >= aspectMatchTolerance else {
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
