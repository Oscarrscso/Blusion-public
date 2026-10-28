import Testing
@testable import PlayerKit

@Suite struct VideoBlackBarsTests {
    private func frame(top: Int = 0, left: Int = 0, picture: UInt8 = 180) -> VideoLumaFrame {
        let width = 320, height = 180
        let pixels = (0..<(width * height)).map { index -> UInt8 in
            let x = index % width, y = index / width
            return x < left || x >= width - left || y < top || y >= height - top ? 0 : picture
        }
        return VideoLumaFrame(width: width, height: height, pixels: pixels)
    }

    @Test(arguments: [1.85, 2.0, 2.39])
    func detectsEncodedLetterboxing(_ ratio: Double) throws {
        var detector = VideoBlackBars()
        let bar = Int((180 - 320 / ratio) / 2)
        var result: Double?
        for _ in 0..<12 { result = detector.sample(frame(top: bar), pictureAspect: 16.0 / 9.0) }
        #expect(abs(try #require(result) - ratio) < 0.035)
    }

    @Test func detectsPillarboxing() throws {
        var detector = VideoBlackBars()
        var result: Double?
        for _ in 0..<12 { result = detector.sample(frame(left: 40), pictureAspect: 16.0 / 9.0) }
        #expect(abs(try #require(result) - 4.0 / 3.0) < 0.001)
    }

    @Test func aTemporaryDarkSceneCannotCropPreviouslyVisiblePicture() {
        var detector = VideoBlackBars()
        #expect(detector.sample(frame(), pictureAspect: 16.0 / 9.0) == nil)
        for _ in 0..<24 {
            #expect(detector.sample(frame(top: 23), pictureAspect: 16.0 / 9.0) == nil)
        }
    }

    @Test func darkFramesAndTooFewSamplesCannotConfirmBars() {
        var detector = VideoBlackBars()
        for _ in 0..<24 { #expect(detector.sample(frame(picture: 0), pictureAspect: 16.0 / 9.0) == nil) }
        for _ in 0..<11 { #expect(detector.sample(frame(top: 10), pictureAspect: 16.0 / 9.0) == nil) }
    }

    @Test func expandedPictureRemovesACropAndLaterDarkScenesCannotRestoreIt() {
        var detector = VideoBlackBars()
        for _ in 0..<12 { _ = detector.sample(frame(top: 23), pictureAspect: 16.0 / 9.0) }
        #expect(detector.sample(frame(top: 23, picture: 0), pictureAspect: 16.0 / 9.0) != nil, "a fade does not change geometry")
        #expect(detector.sample(frame(), pictureAspect: 16.0 / 9.0) == nil)
        for _ in 0..<12 { #expect(detector.sample(frame(top: 23), pictureAspect: 16.0 / 9.0) == nil) }
    }
}
