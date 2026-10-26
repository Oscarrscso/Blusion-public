import Foundation
import StremioKit
import Testing
@testable import Features

/// Samples are 256 × 144 copies of the frame, as `PictureSampler` takes them.
@Suite struct LetterboxEstimateTests {
    private typealias Sample = (top: Int, bottom: Int, left: Int, right: Int)

    private func estimate(_ samples: [Sample], width: Int = 256, height: Int = 144) -> LetterboxEstimate {
        var estimate = LetterboxEstimate()
        for sample in samples {
            estimate.add(top: sample.top, bottom: sample.bottom, left: sample.left, right: sample.right, width: width, height: height)
        }
        return estimate
    }

    /// A 2.39:1 film in a 16:9 frame: 18 black lines of 144 at the top and the bottom. The crop is the measured picture, not the
    /// nearest standard ratio.
    @Test func aWidescreenFilmInA16By9FrameKeepsItsMeasuredPicture() {
        #expect(estimate(Array(repeating: (18, 18, 0, 0), count: 6)).crop(frameAspect: 16.0 / 9.0) == .precise(2.393))
        #expect(abs(estimate(Array(repeating: (18, 18, 0, 0), count: 6)).contentAspect(frameAspect: 16.0 / 9.0)! - 256.0 / 107.0) < 1e-9)
    }

    /// A 1.85:1 film in a 16:9 frame has thin bars, about 2% of the frame on each side: 3 lines of 144. They are recognised, and the
    /// correction is precise, so No Bars does not cut more of the picture than the film's own bars.
    @Test func aThinOneEightFiveLetterboxIsRecognisedAndCorrectedPrecisely() {
        #expect(estimate(Array(repeating: (3, 3, 0, 0), count: 6)).crop(frameAspect: 16.0 / 9.0) == .precise(1.869))
        #expect(abs(estimate(Array(repeating: (3, 3, 0, 0), count: 6)).contentAspect(frameAspect: 16.0 / 9.0)! - 256.0 / 137.0) < 1e-9)
    }

    /// A 4:3 show pillarboxed in a 16:9 file loses its side bars; the measured shape is read from the window's columns.
    @Test func aFourByThreePictureInA16By9FrameLosesItsSideBars() {
        #expect(estimate(Array(repeating: (0, 0, 32, 32), count: 6)).crop(frameAspect: 16.0 / 9.0) == .precise(1.326))
    }

    /// The bars are read at the low percentile of a recent window: a dark scene or a partial fade pushes readings up, and cannot
    /// outvote the frames that showed the bars plainly, however many of them come late in the window.
    @Test func darkScenesFadesAndBurnedInSubtitlesDoNotChangeTheBars() {
        let samples: [Sample] = [(18, 18, 0, 0), (80, 80, 0, 0), (40, 62, 0, 0), (18, 6, 0, 0), (24, 18, 0, 0), (18, 18, 0, 0),
                                 (18, 8, 0, 0), (62, 40, 0, 0), (18, 18, 0, 0), (24, 18, 0, 0), (80, 80, 0, 0), (18, 6, 0, 0),
                                 (18, 18, 0, 0), (40, 62, 0, 0), (18, 8, 0, 0), (18, 18, 0, 0)]
        // (80, 80) frames are fades and do not count at all; (40, 62) and (62, 40) are dark scenes, which make the bars read far
        // bigger; the bottom bar lit by subtitles reads 6 or 8. Most of the window saw (18, 18), so the result is that.
        #expect(estimate(samples).crop(frameAspect: 16.0 / 9.0) == .precise(2.393))
    }

    /// The smallest reading of a single frame is not trusted either: one odd frame cannot make the bars disappear.
    @Test func oneOddFrameCannotEraseTheBars() {
        var samples = Array(repeating: (18, 18, 0, 0) as Sample, count: 14)
        samples[7] = (4, 4, 0, 0)
        // The window reads the percentile, which the fourteen standing frames hold at 18.
        #expect(estimate(samples).crop(frameAspect: 16.0 / 9.0) == .precise(2.393))
    }

    /// A dark frame is not fed in: the sampler's brightness question.
    @Test func aDarkSceneOrAFadeIsNotMeasured() {
        #expect(LetterboxEstimate.isBrightFrame(meanLuma: 60))
        #expect(LetterboxEstimate.isBrightFrame(meanLuma: 10))
        #expect(!LetterboxEstimate.isBrightFrame(meanLuma: 8), "a dark scene")
        #expect(!LetterboxEstimate.isBrightFrame(meanLuma: 0), "a fade to black")
    }

    @Test func aFrameWithoutBarsOrTooFewSamplesHasNoCrop() {
        #expect(estimate(Array(repeating: (0, 0, 0, 0), count: 10)).crop(frameAspect: 2.39) == nil, "a film already cropped to its picture")
        #expect(estimate(Array(repeating: (1, 1, 0, 0), count: 10)).crop(frameAspect: 16.0 / 9.0) == nil, "a line or so is no bar")
        #expect(estimate(Array(repeating: (2, 2, 0, 0), count: 5)).crop(frameAspect: 16.0 / 9.0) == nil, "not yet certain")
    }

    /// Two consecutive windows that agree give one equal crop, so the zoom does not change repeatedly; a fuller dark scene among the
    /// bright frames changes nothing either.
    @Test func theWindowAndTheDarkFramesKeepTheCropStill() {
        let settled = Array(repeating: (18, 18, 0, 0) as Sample, count: 24)
        var withDark = settled
        withDark.removeLast(4)
        withDark.append(contentsOf: [(60, 60, 0, 0) as Sample, (30, 40, 0, 0), (60, 60, 0, 0), (30, 40, 0, 0)])
        #expect(estimate(withDark).crop(frameAspect: 16.0 / 9.0) == estimate(settled).crop(frameAspect: 16.0 / 9.0))
    }

    @Test func aNewFrameSizeStartsAgain() {
        var bars = estimate(Array(repeating: (18, 18, 0, 0), count: 6))
        bars.add(top: 0, bottom: 0, left: 0, right: 0, width: 128, height: 72)
        #expect(bars.samples == 1)
        #expect(bars.crop(frameAspect: 16.0 / 9.0) == nil)
    }

    /// A measured crop is stored as the old raw strings when it is a standard shape, as a decimal otherwise, and always loads back.
    @Test func thePreciseCropRoundTripsThroughTheSavedLayout() throws {
        let standard = try JSONDecoder().decode(VideoCrop.self, from: Data(#""2.39:1""#.utf8))
        #expect(standard == .ratio239, "a saved layout from an earlier version")
        let measured = VideoCrop.precise(2.393)
        let saved = try JSONEncoder().encode(measured)
        let loaded = try JSONDecoder().decode(VideoCrop.self, from: saved)
        #expect(loaded == measured)
        #expect(saved == Data(#""2.3930""#.utf8), "four decimals, so it reloads exactly")
        #expect(VideoCrop.off.label == "No Crop" && VideoCrop.ratio185.label == "1.85:1")
    }
}
