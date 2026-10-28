import PlayerKit

typealias LumaFrame = VideoLumaFrame

/// Finds the black bars baked into a picture (letterboxing) from samples of its frames, so the inline player can show only the content.
/// A bar counts only when it is black in every sample, so a dark moment in one frame, or a 16:9 shot among the scope ones, never cuts the
/// picture. Nothing here touches AVFoundation, so the host tests cover it.
enum TrailerLetterbox {
    /// A row is black when its average luma is at or below this (of 255) and no pixel in it is above `blackPeak`. The peak lets compression
    /// noise through; the average keeps a row with a bright speck from counting as picture.
    static let blackAverage = 12.0
    static let blackPeak: UInt8 = 40
    /// A bar must be at least this share of the picture's height on each side, or the picture is left whole.
    static let minimumBarShare = 0.04
    /// The picture is cut only when at least this many frames show picture to measure, so a short sample decides nothing.
    static let minimumFrames = 3
    /// The content's shape (width over height) must fall in this range, or the picture is left whole.
    static let contentAspectRange = 1.2...3.0

    /// The share of the picture's height that each bar takes, the same at the top and at the bottom: the smallest black run at each edge
    /// across the frames that show any picture. Nil when there is no clear letterbox in every frame, or the frames do not agree in size.
    /// Frames that are black all over say nothing about the bars and are skipped. Asymmetric bars count as the smaller of the two, so no
    /// picture is cut more than it has bars.
    static func barShare(in frames: [LumaFrame]) -> Double? {
        guard let first = frames.first, first.width > 0, first.height > 0,
              frames.allSatisfy({ $0.width == first.width && $0.height == first.height && $0.pixels.count == first.width * first.height })
        else { return nil }
        let height = first.height
        var top = height
        var bottom = height
        var measured = 0
        for frame in frames {
            let runs = blackRuns(of: frame)
            guard runs.top < height else { continue }
            top = min(top, runs.top)
            bottom = min(bottom, runs.bottom)
            measured += 1
        }
        guard measured >= minimumFrames else { return nil }
        let bar = min(top, bottom)
        guard Double(bar) >= minimumBarShare * Double(height), height - 2 * bar > 0 else { return nil }
        return Double(bar) / Double(height)
    }

    /// The shape of the picture's content, with its bars cut off, or nil when `barShare` finds no clear letterbox or the content's shape is
    /// out of range. `pictureAspect` is the picture's shape as it is shown (width over height), which can differ from the frames' own when
    /// the pixels are not square; it defaults to the frames' shape.
    static func contentAspectRatio(in frames: [LumaFrame], pictureAspect: Double? = nil) -> Double? {
        guard let share = barShare(in: frames) else { return nil }
        guard let picture = pictureAspect ?? frames.first.map({ Double($0.width) / Double($0.height) }),
              picture.isFinite, picture > 0 else { return nil }
        let ratio = picture / (1 - 2 * share)
        return contentAspectRange.contains(ratio) ? ratio : nil
    }

    /// How many rows are black at the top and at the bottom. Both are the whole height when every row is black.
    private static func blackRuns(of frame: LumaFrame) -> (top: Int, bottom: Int) {
        var top = 0
        while top < frame.height, isBlackRow(frame, top) { top += 1 }
        if top == frame.height { return (top, top) }
        var bottom = 0
        while bottom < frame.height, isBlackRow(frame, frame.height - 1 - bottom) { bottom += 1 }
        return (top, bottom)
    }

    private static func isBlackRow(_ frame: LumaFrame, _ row: Int) -> Bool {
        let start = row * frame.width
        return VideoBlackBars.isBlackLine(count: frame.width) { frame.pixels[start + $0] }
    }
}
