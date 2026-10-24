import Testing
@testable import Features

@Suite struct TrailerLetterboxTests {
    /// A picture of `width` by `height`, with `top` black rows at the top and `bottom` at the bottom, and picture between them.
    private func frame(width: Int = 200, height: Int = 100, top: Int, bottom: Int, picture: UInt8 = 180) -> LumaFrame {
        var pixels = [UInt8](repeating: picture, count: width * height)
        for row in 0..<height where row < top || row >= height - bottom {
            for column in 0..<width { pixels[row * width + column] = 0 }
        }
        return LumaFrame(width: width, height: height, pixels: pixels)
    }

    private func near(_ a: Double?, _ b: Double) -> Bool {
        guard let a else { return false }
        return abs(a - b) < 0.0001
    }

    @Test func aScopePictureInAFrameWithBarsIsCutToItsContent() {
        // 200 x 100 with 10 black rows each side: the content is 200 x 80, a 2.5:1 picture.
        let frames = (0..<5).map { _ in frame(top: 10, bottom: 10) }
        #expect(near(TrailerLetterbox.contentAspectRatio(in: frames), 2.5))
    }

    @Test func aPictureWithoutBarsIsLeftWhole() {
        let frames = (0..<5).map { _ in frame(top: 0, bottom: 0) }
        #expect(TrailerLetterbox.contentAspectRatio(in: frames) == nil)
    }

    @Test func noFramesMeansNoBars() {
        #expect(TrailerLetterbox.contentAspectRatio(in: []) == nil)
    }

    @Test func barsThatAreNotInEveryFrameAreNotCut() {
        // A 16:9 shot among the scope ones: its edges are picture, so no bar is black in every frame.
        let frames = [frame(top: 10, bottom: 10), frame(top: 10, bottom: 10), frame(top: 0, bottom: 0)]
        #expect(TrailerLetterbox.contentAspectRatio(in: frames) == nil)
    }

    @Test func aFullyBlackFrameSaysNothingAboutTheBars() {
        let frames = [frame(top: 10, bottom: 10), frame(top: 100, bottom: 0, picture: 0), frame(top: 10, bottom: 10),
                      frame(top: 10, bottom: 10)]
        #expect(near(TrailerLetterbox.contentAspectRatio(in: frames), 2.5))
    }

    @Test func twoFramesAreTooFewToCutAPicture() {
        let frames = [frame(top: 10, bottom: 10), frame(top: 10, bottom: 10)]
        #expect(TrailerLetterbox.contentAspectRatio(in: frames) == nil)
    }

    @Test func framesThatAreAllBlackMeasureNothing() {
        let frames = (0..<3).map { _ in frame(top: 100, bottom: 0, picture: 0) }
        #expect(TrailerLetterbox.contentAspectRatio(in: frames) == nil)
    }

    @Test func barsThinnerThanFourPercentOfTheHeightAreLeft() {
        // Two rows each side of 100: a 1.85:1 film in a 16:9 frame is about this thin, and it is left whole.
        let frames = (0..<5).map { _ in frame(top: 2, bottom: 2) }
        #expect(TrailerLetterbox.contentAspectRatio(in: frames) == nil)
    }

    @Test func asymmetricBarsAreCutAsTheSmallerOfTheTwo() {
        // 10 rows on top and 14 below: cutting 10 each side keeps every row of the picture.
        let frames = (0..<5).map { _ in frame(top: 10, bottom: 14) }
        #expect(near(TrailerLetterbox.contentAspectRatio(in: frames), 2.5))
    }

    @Test func aContentShapeOutsideTheRangeIsLeftWhole() {
        // 100 x 100 with 40 rows each side: 100 x 20, a 5:1 picture, which no trailer is cut to.
        let frames = (0..<5).map { _ in frame(width: 100, top: 40, bottom: 40) }
        #expect(TrailerLetterbox.contentAspectRatio(in: frames) == nil)
    }

    @Test func aBrightSpeckInABarMakesThatRowPicture() {
        // A bright pixel in row 5 of every frame: the top bar stops there, so the cut is the smaller bar, 5 rows each side.
        let frames = (0..<5).map { _ in frame(top: 10, bottom: 10) }.map { sample -> LumaFrame in
            var pixels = sample.pixels
            pixels[5 * sample.width] = 255
            return LumaFrame(width: sample.width, height: sample.height, pixels: pixels)
        }
        #expect(near(TrailerLetterbox.contentAspectRatio(in: frames), 200.0 / 90.0))
    }

    @Test func theShapeCutIsTakenFromThePictureAsShownNotFromTheSample() {
        // The same 10-row bars, but the pixels are not square and the picture is shown at 1.6:1: 1.6 / 0.8 = 2.0.
        let frames = (0..<5).map { _ in frame(top: 10, bottom: 10) }
        #expect(near(TrailerLetterbox.contentAspectRatio(in: frames, pictureAspect: 1.6), 2.0))
    }

    @Test func framesOfDifferentSizesAreNotMeasuredTogether() {
        let frames = [frame(top: 10, bottom: 10), frame(width: 100, top: 5, bottom: 5)]
        #expect(TrailerLetterbox.contentAspectRatio(in: frames) == nil)
    }
}
