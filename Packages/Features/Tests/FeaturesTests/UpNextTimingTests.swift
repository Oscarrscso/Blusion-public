import Testing
@testable import Features

@Suite struct UpNextTimingTests {
    @Test func theLastMinuteIsTheEnd() {
        #expect(UpNextTiming.isNearEnd(position: 1_380, duration: 1_440, creditsToEnd: false))
        #expect(UpNextTiming.isNearEnd(position: 1_439, duration: 1_440, creditsToEnd: false))
        #expect(!UpNextTiming.isNearEnd(position: 1_379, duration: 1_440, creditsToEnd: false), "61 s left is not the last minute")
    }

    @Test func creditsThatRunToTheEndBeginIt() {
        #expect(UpNextTiming.isNearEnd(position: 1_300, duration: 1_440, creditsToEnd: true))
    }

    @Test func noLengthOrAShortVideoHasNoUpNext() {
        #expect(!UpNextTiming.isNearEnd(position: 50, duration: nil, creditsToEnd: true))
        #expect(!UpNextTiming.isNearEnd(position: 100, duration: 120, creditsToEnd: false), "a two-minute video is not all last minute")
        #expect(!UpNextTiming.isNearEnd(position: .nan, duration: 1_440, creditsToEnd: false))
    }
}
