import Testing
@testable import PlayerKit

@Suite struct VideoBlackBarsTests {
    /// Quarter-HD (480×270) matches PictureSampler's sampling resolution, where 1.85:1's ~21px bars in 1080p span ~5 rows.
    private func frame(
        width: Int = 480,
        height: Int = 270,
        top: Int = 0,
        bottom: Int? = nil,
        left: Int = 0,
        right: Int? = nil,
        picture: UInt8 = 180,
        overlay: ((Int, Int) -> UInt8?)? = nil
    ) -> VideoLumaFrame {
        let bottom = bottom ?? top
        let right = right ?? left
        let pixels = (0..<(width * height)).map { index -> UInt8 in
            let x = index % width, y = index / width
            if let custom = overlay?(x, y) { return custom }
            return x < left || x >= width - right || y < top || y >= height - bottom ? 0 : picture
        }
        return VideoLumaFrame(width: width, height: height, pixels: pixels)
    }

    @Test(arguments: [1.85, 2.0, 2.39])
    func detectsEncodedLetterboxingIncludingThin185Bars(_ ratio: Double) throws {
        var detector = VideoBlackBars()
        let bar = Int(((270.0 - 480.0 / ratio) / 2.0).rounded())
        var result: Double?
        for _ in 0..<12 { result = detector.sample(frame(top: bar), pictureAspect: 16.0 / 9.0) }
        #expect(abs(try #require(result) - ratio) < 0.02)
    }

    @Test(arguments: [4.0 / 3.0, 1.65])
    func detectsPillarboxingIncludingThin165Bars(_ ratio: Double) throws {
        var detector = VideoBlackBars()
        let bar = Int(((480.0 - 270.0 * ratio) / 2.0).rounded())
        var result: Double?
        for _ in 0..<12 { result = detector.sample(frame(left: bar), pictureAspect: 16.0 / 9.0) }
        #expect(abs(try #require(result) - ratio) < 0.02)
    }

    @Test func aSingleUnreliableFullFrameSampleDoesNotPermanentlyLockThinBarsToZero() throws {
        var detector = VideoBlackBars()
        // One stray full-frame or noisy startup frame before the film settles: must NOT permanently kill 1.85:1 detection!
        #expect(detector.sample(frame(), pictureAspect: 16.0 / 9.0) == nil)
        let bar185 = 5   // ~20px on 1080p
        var result: Double?
        for _ in 0..<12 { result = detector.sample(frame(top: bar185), pictureAspect: 16.0 / 9.0) }
        #expect(abs(try #require(result) - 1.85) < 0.02)
    }

    @Test func genuineFullFrameContentPreventsTemporaryDarkScenesFromCropping() {
        var detector = VideoBlackBars()
        for _ in 0..<3 { #expect(detector.sample(frame(), pictureAspect: 16.0 / 9.0) == nil) }
        for _ in 0..<24 {
            #expect(detector.sample(frame(top: 35), pictureAspect: 16.0 / 9.0) == nil)
        }
    }

    @Test func darkFramesAsymmetricSkiesSubtitlesInBarsAndCornerWatermarksDoNotCorruptDetection() throws {
        var detector = VideoBlackBars()
        // Complete fades to black and too-few samples never confirm bars.
        for _ in 0..<24 { #expect(detector.sample(frame(picture: 0), pictureAspect: 16.0 / 9.0) == nil) }
        // Asymmetric dark top (night sky, bottom lit) is rejected by symmetry check.
        for _ in 0..<16 { #expect(detector.sample(frame(top: 40, bottom: 0), pictureAspect: 16.0 / 9.0) == nil) }

        // Confirm 2.00:1 bars (15 rows top & bottom on 480×270).
        var result: Double?
        for _ in 0..<12 { result = detector.sample(frame(top: 15), pictureAspect: 16.0 / 9.0) }
        #expect(abs(try #require(result) - 2.0) < 0.01)

        // Bright burned-in subtitles inside the bottom black bar (asymmetric) are ignored, keeping the 2.00:1 crop stable.
        for _ in 0..<8 {
            result = detector.sample(frame(top: 15) { x, y in
                (y >= 258 && y < 266 && (140..<340).contains(x)) ? 235 : nil
            }, pictureAspect: 16.0 / 9.0)
        }
        #expect(abs(try #require(result) - 2.0) < 0.01)

        // A small corner watermark touching the top-right bar edge (< 25% cross-span) must NOT trigger full-frame lock.
        for _ in 0..<8 {
            result = detector.sample(frame(top: 15) { x, y in
                (y < 15 && x >= 430) ? 200 : nil
            }, pictureAspect: 16.0 / 9.0)
        }
        #expect(abs(try #require(result) - 2.0) < 0.01)
    }

    @Test func expandedIMAXPictureRemovesACropAndResetClearsStateForNewItem() throws {
        var detector = VideoBlackBars()
        for _ in 0..<12 { _ = detector.sample(frame(top: 35), pictureAspect: 16.0 / 9.0) }
        #expect(detector.sample(frame(top: 35, picture: 0), pictureAspect: 16.0 / 9.0) != nil, "a fade does not change geometry")
        // Sustained genuine full-frame IMAX expansion clears the crop.
        for _ in 0..<3 { _ = detector.sample(frame(), pictureAspect: 16.0 / 9.0) }
        #expect(detector.sample(frame(), pictureAspect: 16.0 / 9.0) == nil)
        for _ in 0..<12 { #expect(detector.sample(frame(top: 35), pictureAspect: 16.0 / 9.0) == nil) }

        // Resetting for a new video item allows thin-bar detection on the next movie.
        detector.reset()
        var nextMovie: Double?
        for _ in 0..<12 { nextMovie = detector.sample(frame(top: 5), pictureAspect: 16.0 / 9.0) }
        #expect(abs(try #require(nextMovie) - 1.85) < 0.02)
    }
}
