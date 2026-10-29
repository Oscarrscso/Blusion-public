import Foundation

/// A native renderer may expose an original-frame sample when it has no AVPlayer output.
@MainActor
public protocol OriginalPictureSampling: AnyObject {
    /// Incremented whenever the underlying source media is replaced on the same sampler object.
    var pictureSamplingRevision: Int { get }
    func sampleOriginalPicture() -> (frame: VideoLumaFrame, aspect: Double)?
}

public extension OriginalPictureSampling {
    var pictureSamplingRevision: Int { 0 }
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

/// Detects persistent, symmetric encoded black bars from downscaled original-source luma frames.
///
/// Design invariants:
/// - Fades and dark scenes (`<= 10%` bright pixels) are ignored without clearing or creating bars.
/// - Asymmetric edges (such as a subtitle cue in the bottom black bar or a dark night sky at the top) are ignored.
/// - Localized corner watermarks or specks do not count as full-frame content and cannot permanently lock bar size to zero.
/// - A single unreliable full-frame glitch does not permanently disable detection; sustained symmetric edge-to-edge picture
///   (`>= 3` valid frames) confirms full-frame / IMAX content and prevents later dark scenes from cropping it.
public struct VideoBlackBars: Sendable {
    private var size: (width: Int, height: Int)?
    private var horizontalSamples: [Double] = []
    private var verticalSamples: [Double] = []
    private var fullFrameHorizontalStreak = 0
    private var fullFrameVerticalStreak = 0
    private var lockedFullHorizontal = false
    private var lockedFullVertical = false
    private var confirmedHorizontal = 0.0
    private var confirmedVertical = 0.0

    public init() {}

    public mutating func reset() {
        self = Self()
    }

    public mutating func sample(_ frame: VideoLumaFrame, pictureAspect: Double, minimumFrames: Int = 12,
                                minimumBarShare: Double = 0.01) -> Double? {
        guard frame.width > 2, frame.height > 2, frame.pixels.count == frame.width * frame.height,
              pictureAspect.isFinite, pictureAspect > 0 else { return nil }
        if size?.width != frame.width || size?.height != frame.height {
            self = Self()
            size = (frame.width, frame.height)
        }

        // Ignore fades and dark scenes: neither confirm a new crop nor discard an existing one.
        let bright = frame.pixels.reduce(0) { $0 + ($1 > 48 ? 1 : 0) }
        guard bright > frame.pixels.count / 10 else { return confirmedAspect(pictureAspect) }

        var top = 0, bottom = 0, left = 0, right = 0
        let maxVertical = frame.height / 3
        let maxHorizontal = frame.width / 3
        while top < maxVertical, Self.isBlackLine(count: frame.width, pixel: { frame.pixels[top * frame.width + $0] }) { top += 1 }
        while bottom < maxVertical, Self.isBlackLine(count: frame.width, pixel: { frame.pixels[(frame.height - 1 - bottom) * frame.width + $0] }) { bottom += 1 }
        while left < maxHorizontal, Self.isBlackLine(count: frame.height, pixel: { frame.pixels[$0 * frame.width + left] }) { left += 1 }
        while right < maxHorizontal, Self.isBlackLine(count: frame.height, pixel: { frame.pixels[$0 * frame.width + frame.width - 1 - right] }) { right += 1 }

        let requiredFullFrames = max(2, min(3, minimumFrames / 4))
        let maxWindow = max(24, minimumFrames * 2)

        Self.updateAxis(
            first: top,
            second: bottom,
            total: frame.height,
            minimumFrames: minimumFrames,
            minimumBarShare: minimumBarShare,
            requiredFullFrames: requiredFullFrames,
            maxWindow: maxWindow,
            hasBroadEdgePicture: { band in
                Self.litCrossSpan(crossCount: frame.width, bandDepth: band) { cross, depth in
                    frame.pixels[depth * frame.width + cross]
                } >= max(1, frame.width / 4)
                    && Self.litCrossSpan(crossCount: frame.width, bandDepth: band) { cross, depth in
                        frame.pixels[(frame.height - 1 - depth) * frame.width + cross]
                    } >= max(1, frame.width / 4)
            },
            samples: &verticalSamples,
            fullFrameStreak: &fullFrameVerticalStreak,
            lockedFull: &lockedFullVertical,
            confirmed: &confirmedVertical
        )

        Self.updateAxis(
            first: left,
            second: right,
            total: frame.width,
            minimumFrames: minimumFrames,
            minimumBarShare: minimumBarShare,
            requiredFullFrames: requiredFullFrames,
            maxWindow: maxWindow,
            hasBroadEdgePicture: { band in
                Self.litCrossSpan(crossCount: frame.height, bandDepth: band) { cross, depth in
                    frame.pixels[cross * frame.width + depth]
                } >= max(1, frame.height / 4)
                    && Self.litCrossSpan(crossCount: frame.height, bandDepth: band) { cross, depth in
                        frame.pixels[cross * frame.width + frame.width - 1 - depth]
                    } >= max(1, frame.height / 4)
            },
            samples: &horizontalSamples,
            fullFrameStreak: &fullFrameHorizontalStreak,
            lockedFull: &lockedFullHorizontal,
            confirmed: &confirmedHorizontal
        )

        return confirmedAspect(pictureAspect)
    }

    /// Shared with the trailer detector; compression noise is allowed, bright picture pixels are not.
    public static func isBlackLine(count: Int, pixel: (Int) -> UInt8) -> Bool {
        guard count > 0 else { return false }
        var sum = 0
        var peak: UInt8 = 0
        for index in 0..<count { let value = pixel(index); sum += Int(value); peak = max(peak, value) }
        return peak <= 40 && Double(sum) <= 12 * Double(count)
    }

    private static func updateAxis(
        first: Int,
        second: Int,
        total: Int,
        minimumFrames: Int,
        minimumBarShare: Double,
        requiredFullFrames: Int,
        maxWindow: Int,
        hasBroadEdgePicture: (Int) -> Bool,
        samples: inout [Double],
        fullFrameStreak: inout Int,
        lockedFull: inout Bool,
        confirmed: inout Double
    ) {
        let firstShare = Double(first) / Double(total)
        let secondShare = Double(second) / Double(total)
        let symmetryTolerance = max(2, Int((Double(total) * 0.015).rounded()))
        let minBand = max(1, Int((Double(total) * minimumBarShare).rounded(.up)))

        if firstShare < minimumBarShare, secondShare < minimumBarShare {
            // Distinguish genuine edge-to-edge picture from a localized watermark/subtitle cue.
            guard hasBroadEdgePicture(minBand) else { return }
            fullFrameStreak += 1
            if fullFrameStreak >= requiredFullFrames {
                lockedFull = true
                samples.removeAll()
                confirmed = 0
            }
            return
        }

        let barPixels = min(first, second)
        let share = Double(barPixels) / Double(total)
        guard share >= minimumBarShare, abs(first - second) <= symmetryTolerance else {
            // Asymmetric edge (e.g. subtitle inside bottom bar or dark sky at top): ignore without resetting.
            return
        }

        fullFrameStreak = 0
        guard !lockedFull else { return }

        samples.append(share)
        if samples.count > maxWindow {
            samples.removeFirst(samples.count - maxWindow)
        }
        guard samples.count >= max(1, minimumFrames) else { return }

        let sorted = samples.sorted()
        let candidate = sorted[min(sorted.count - 1, sorted.count / 8)]
        let clusterTolerance = max(0.012, 1.5 / Double(total))
        let clusterCount = sorted.filter { abs($0 - candidate) <= clusterTolerance }.count
        guard clusterCount * 2 >= max(2, minimumFrames) else { return }

        let hysteresis = max(0.004, 1.25 / Double(total))
        if confirmed == 0 || abs(candidate - confirmed) >= hysteresis {
            confirmed = candidate
        }
    }

    private static func litCrossSpan(crossCount: Int, bandDepth: Int, pixel: (Int, Int) -> UInt8) -> Int {
        guard crossCount > 0, bandDepth > 0 else { return 0 }
        var lit = 0
        for cross in 0..<crossCount {
            for depth in 0..<bandDepth where pixel(cross, depth) > 40 {
                lit += 1
                break
            }
        }
        return lit
    }

    private func confirmedAspect(_ picture: Double) -> Double? {
        guard confirmedHorizontal > 0 || confirmedVertical > 0 else { return nil }
        let widthFactor = 1 - 2 * confirmedHorizontal
        let heightFactor = 1 - 2 * confirmedVertical
        guard widthFactor > 0, heightFactor > 0 else { return nil }
        let ratio = picture * widthFactor / heightFactor
        return (0.5...4).contains(ratio) ? ratio : nil
    }
}
