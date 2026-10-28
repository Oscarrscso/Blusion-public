import Foundation

/// A native renderer may expose an original-frame sample when it has no AVPlayer output.
@MainActor
public protocol OriginalPictureSampling: AnyObject {
    func sampleOriginalPicture() -> (frame: VideoLumaFrame, aspect: Double)?
}

/// Small, unscaled source samples: one byte of luma per pixel, rows from the top.
public struct VideoLumaFrame: Equatable, Sendable {
    public let width: Int
    public let height: Int
    public let pixels: [UInt8]

    public init(width: Int, height: Int, pixels: [UInt8]) {
        self.width = width
        self.height = height
        self.pixels = pixels
    }
}

/// Conservative version of the trailer/ambient detector. Only persistent, symmetric black edges count.
/// Once picture has appeared at an edge, a later dark scene cannot turn that edge into a bar.
public struct VideoBlackBars: Sendable {
    private var size: (width: Int, height: Int)?
    private var horizontal = 1.0
    private var vertical = 1.0
    private var measured = 0

    public init() {}

    public mutating func sample(_ frame: VideoLumaFrame, pictureAspect: Double, minimumFrames: Int = 12,
                                minimumBarShare: Double = 0.01) -> Double? {
        guard frame.width > 2, frame.height > 2, frame.pixels.count == frame.width * frame.height,
              pictureAspect.isFinite, pictureAspect > 0 else { return nil }
        if size?.width != frame.width || size?.height != frame.height {
            self = Self()
            size = (frame.width, frame.height)
        }
        // A fade or dark scene says nothing about where the picture ends. Require substantial bright picture, not a subtitle/speck.
        let bright = frame.pixels.reduce(0) { $0 + ($1 > 48 ? 1 : 0) }
        guard bright > frame.pixels.count / 10 else { return aspect(pictureAspect, minimumFrames: minimumFrames) }
        var top = 0, bottom = 0, left = 0, right = 0
        while top < frame.height / 3, Self.isBlackLine(count: frame.width, pixel: { frame.pixels[top * frame.width + $0] }) { top += 1 }
        while bottom < frame.height / 3, Self.isBlackLine(count: frame.width, pixel: { frame.pixels[(frame.height - 1 - bottom) * frame.width + $0] }) { bottom += 1 }
        while left < frame.width / 3, Self.isBlackLine(count: frame.height, pixel: { frame.pixels[$0 * frame.width + left] }) { left += 1 }
        while right < frame.width / 3, Self.isBlackLine(count: frame.height, pixel: { frame.pixels[$0 * frame.width + frame.width - 1 - right] }) { right += 1 }
        // Minima across the entire sampling session preserve any real content seen in earlier frames.
        let x = Double(min(left, right)) / Double(frame.width)
        let y = Double(min(top, bottom)) / Double(frame.height)
        horizontal = min(horizontal, x >= minimumBarShare ? x : 0)
        vertical = min(vertical, y >= minimumBarShare ? y : 0)
        measured += 1
        return aspect(pictureAspect, minimumFrames: minimumFrames)
    }

    /// Shared with the trailer detector; compression noise is allowed, bright picture pixels are not.
    public static func isBlackLine(count: Int, pixel: (Int) -> UInt8) -> Bool {
        guard count > 0 else { return false }
        var sum = 0
        var peak: UInt8 = 0
        for index in 0..<count { let value = pixel(index); sum += Int(value); peak = max(peak, value) }
        return peak <= 40 && Double(sum) <= 12 * Double(count)
    }

    private func aspect(_ picture: Double, minimumFrames: Int) -> Double? {
        guard measured >= minimumFrames, horizontal > 0 || vertical > 0 else { return nil }
        let ratio = picture * (1 - 2 * horizontal) / (1 - 2 * vertical)
        return (0.5...4).contains(ratio) ? ratio : nil
    }
}
