import Testing
@testable import Features

/// How an episode card writes the episode's length.
@Suite struct EpisodeRuntimeTextTests {
    @Test func minutesHoursAndBoth() {
        #expect(DetailViewModel.runtimeText(minutes: 45) == "45m")
        #expect(DetailViewModel.runtimeText(minutes: 60) == "1h")
        #expect(DetailViewModel.runtimeText(minutes: 62) == "1h 2m")
        #expect(DetailViewModel.runtimeText(minutes: 125) == "2h 5m")
    }
}
