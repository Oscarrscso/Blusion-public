import Foundation
import Testing
@testable import StremioKit

@Suite struct PlayerControlPreferencesTests {
    @Test func theDefaultsAreTheOriginalControls() {
        let preferences = PlayerPreferences()
        #expect(preferences.skipBackSeconds == 10)
        #expect(preferences.skipForwardSeconds == 10)
        #expect(preferences.doubleTapSkips)
        #expect(preferences.controlsHideSeconds == 3)
        #expect(preferences.playbackSpeed == 1)
    }

    @Test func aSaveFromBeforeTheControlsLoadsWithTheDefaults() throws {
        let saved = Data(#"{"subtitleMode":"off"}"#.utf8)
        let decoded = try JSONDecoder().decode(PlayerPreferences.self, from: saved)
        #expect(decoded.subtitleMode == .off)
        #expect(decoded.skipBackSeconds == 10)
        #expect(decoded.controlsHideSeconds == 3)
        #expect(decoded.playbackSpeed == 1)
    }

    @Test func chosenControlsRoundTrip() throws {
        var preferences = PlayerPreferences()
        preferences.skipBackSeconds = 5
        preferences.skipForwardSeconds = 30
        preferences.doubleTapSkips = false
        preferences.controlsHideSeconds = 0
        preferences.playbackSpeed = 1.25
        let decoded = try JSONDecoder().decode(PlayerPreferences.self, from: JSONEncoder().encode(preferences))
        #expect(decoded == preferences)
    }

    @Test func aValueNoChoiceOffersFallsBackToTheDefault() throws {
        let saved = Data(#"{"skipBackSeconds":7,"controlsHideSeconds":99,"playbackSpeed":3}"#.utf8)
        let decoded = try JSONDecoder().decode(PlayerPreferences.self, from: saved)
        #expect(decoded.skipBackSeconds == 10)
        #expect(decoded.controlsHideSeconds == 3)
        #expect(decoded.playbackSpeed == 1)
    }
}
