import Foundation
import StremioKit

/// The black bars a film carries inside its own frame (a widescreen film in a 16:9 frame), measured on small copies of its frames.
/// Each sample counts the black lines at the frame's edges, each pair reduced to its larger member. One frame says nothing: the
/// estimate keeps a recent window and reads a low percentile of it, so a dark scene or a partial fade cannot say the bars are bigger
/// than they are, and one odd frame cannot make them vanish either. The sampler only feeds bright frames in (`isBrightFrame`), so
/// fades and dark scenes are not measured at all.
struct LetterboxEstimate: Equatable {
    /// Bright frames needed before the bars count as known: a few seconds of samples.
    static let samplesNeeded = 6
    /// How many samples stay in the window the percentile reads (recent, so a late change of bar is followed).
    static let windowCount = 24
    /// How much of each frame's mean luma counts as bright enough to measure.
    static let minimumMeanLuma = 10
    /// A bar thinner than this share of the frame, on each side, is no bar: a single line of 256 × 144, as noise can draw, is 0.7%.
    /// A 1.85:1 film in a 16:9 frame has about 2% on each side, so it is just over this line.
    static let minimumBar = 0.012

    /// One sample's bars, each pair already reduced to its larger member.
    private struct Sample: Equatable {
        var rows: Int
        var columns: Int
    }

    private(set) var samples = 0
    private var window: [Sample] = []
    private var width = 0, height = 0

    /// A frame whose average brightness falls under `minimumMeanLuma` — a dark scene or a fade — says nothing about the bars.
    static func isBrightFrame(meanLuma: Int) -> Bool { meanLuma >= minimumMeanLuma }

    /// One frame's black lines at each edge, out of `width` × `height`; feed it only bright frames (`isBrightFrame`).
    mutating func add(top: Int, bottom: Int, left: Int, right: Int, width: Int, height: Int) {
        guard width > 0, height > 0 else { return }
        if width != self.width || height != self.height {
            self = LetterboxEstimate()
            self.width = width
            self.height = height
        }
        guard top + bottom < height * 9 / 10, left + right < width * 9 / 10 else { return }
        window.append(Sample(rows: max(top, bottom), columns: max(left, right)))
        if window.count > Self.windowCount { window.removeFirst() }
        samples += 1
    }

    /// The low percentile of the window: the value most of the recent frames agree on, with the readings a dark scene or a partial
    /// fade pushes up outvoted, and a single thin reading in an otherwise constant video outvoted as well. Unlike a bare minimum
    /// across every frame ever seen, it also follows a film whose bars change.
    private func percentile(_ values: [Int]) -> Int {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        return sorted[min(sorted.count - 1, Int((Double(sorted.count) - 1) * 0.25))]
    }

    /// The picture inside the bars, width over height, for a frame shown at `frameAspect`; nil without bars or before enough samples.
    /// The bars are centred, and subtitles burned into one of them make it look thinner, so the thicker of each pair is cropped from both
    /// sides. The line where a bar meets the picture counts as half.
    func contentAspect(frameAspect: Double) -> Double? {
        guard samples >= Self.samplesNeeded, frameAspect.isFinite, frameAspect > 0, !window.isEmpty else { return nil }
        let rows = percentile(window.map(\.rows)), columns = percentile(window.map(\.columns))
        let vertical = rows > 0 ? (Double(rows) + 0.5) / Double(height) : 0
        let horizontal = columns > 0 ? (Double(columns) + 0.5) / Double(width) : 0
        if vertical >= Self.minimumBar { return frameAspect / (1 - 2 * vertical) }
        if horizontal >= Self.minimumBar { return frameAspect * (1 - 2 * horizontal) }
        return nil
    }

    /// The crop that takes the bars off: the measured picture inside them, not a guess at the nearest standard ratio. Quantised to
    /// three decimals, so consecutive windows that agree report one equal crop and no zoom changes.
    func crop(frameAspect: Double) -> VideoCrop? {
        guard let aspect = contentAspect(frameAspect: frameAspect) else { return nil }
        return VideoCrop.precise((aspect * 1000).rounded() / 1000)
    }
}
