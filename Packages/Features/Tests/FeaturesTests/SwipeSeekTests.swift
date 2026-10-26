import Testing
@testable import Features

@Suite struct SwipeSeekTests {
    @Test func aSwipeAcrossTheWholeWidthMovesTwoMinutesEitherWay() {
        // A 1000 s film at 500 s, on a picture 400 pt wide.
        #expect(abs(SwipeSeek.fraction(from: 0.5, translation: 400, width: 400, duration: 1000) - 0.62) < 1e-9, "right goes forward 120 s")
        #expect(abs(SwipeSeek.fraction(from: 0.5, translation: -400, width: 400, duration: 1000) - 0.38) < 1e-9, "left goes back 120 s")
        #expect(abs(SwipeSeek.fraction(from: 0.5, translation: 100, width: 400, duration: 1000) - 0.53) < 1e-9, "a quarter of the width is 30 s")
    }

    @Test func aShortVideoTakesItsWholeLengthAcrossTheWidth() {
        // 60 s long: half the width moves 30 s, half the video.
        #expect(abs(SwipeSeek.fraction(from: 0.25, translation: 200, width: 400, duration: 60) - 0.75) < 1e-9)
    }

    @Test func itStopsAtTheStartAndTheEnd() {
        #expect(SwipeSeek.fraction(from: 0.01, translation: -400, width: 400, duration: 7200) == 0)
        #expect(SwipeSeek.fraction(from: 0.99, translation: 400, width: 400, duration: 7200) == 1)
    }

    @Test func withoutALengthOrAWidthItStaysPut() {
        #expect(SwipeSeek.fraction(from: 0.3, translation: 100, width: 0, duration: 1000) == 0.3)
        #expect(SwipeSeek.fraction(from: 0.3, translation: 100, width: 400, duration: 0) == 0.3)
    }
}
