import Foundation
import Testing
@testable import StremioKit

/// Zoom Mode and Aspect Ratio as Infuse has them: the layout each makes, where each is kept, and older saved settings.
@Suite struct VideoZoomTests {
    @Test func eachModeMakesItsLayout() {
        #expect(VideoLayout(zoomMode: .normal, aspectRatio: .anamorphicB, safeInset: 59) == VideoLayout(fit: .fit, inset: 59))
        #expect(VideoLayout(zoomMode: .crop, aspectRatio: .anamorphicB, safeInset: 59) == VideoLayout(fit: .fill, crop: .ratio239))
        #expect(VideoLayout(zoomMode: .stretch, aspectRatio: .widescreenA) == VideoLayout(fit: .stretch, crop: .ratio185))
        #expect(VideoLayout(zoomMode: .crop, aspectRatio: .auto) == VideoLayout(fit: .fill), "Auto: the frame's own shape")
        #if os(iOS) && !targetEnvironment(macCatalyst)
        #expect(VideoLayout(zoomMode: .aspectFit, aspectRatio: .anamorphicB, safeInset: 59) == VideoLayout(fit: .fit))
        #else
        #expect(VideoLayout(zoomMode: .aspectFit, aspectRatio: .anamorphicB, safeInset: 59) == VideoLayout(fit: .fit, inset: 59),
                "a Mac has no Aspect Fit: it plays as Normal")
        #endif
    }

    @Test func theZoomButtonGoesRoundTheModes() {
        var mode = VideoZoomMode.normal
        var seen: [VideoZoomMode] = []
        for _ in VideoZoomMode.available {
            mode = mode.next
            seen.append(mode)
        }
        #expect(seen.last == .normal && Set(seen) == Set(VideoZoomMode.available))
    }

    @Test func aspectRatioIsKeptPerFilmOrSeason() {
        #expect(AspectRatioChoice.titleKey(for: StreamRequest(type: "movie", id: "tt1", title: "Film")) == "tt1")
        let episode = StreamRequest(type: "series", id: "tt9:2:3", title: "Show · Three", season: 2, episode: 3)
        #expect(AspectRatioChoice.titleKey(for: episode) == "tt9:s2")
    }

    /// The inset is the screen's, never saved; Zoom Mode and the per-title choices are.
    @Test func zoomSettingsRoundTripAndTheInsetIsNotSaved() throws {
        var preferences = PlayerPreferences()
        preferences.zoomMode = .stretch
        preferences.aspectRatios = ["tt1": .anamorphicB]
        preferences.videoLayout = VideoLayout(fit: .fit, inset: 40)
        let decoded = try JSONDecoder().decode(PlayerPreferences.self, from: JSONEncoder().encode(preferences))
        #expect(decoded.zoomMode == .stretch && decoded.aspectRatios == ["tt1": .anamorphicB] && decoded.videoLayout.inset == 0)
    }

    /// A Fit or Fill saved before Zoom Mode existed starts it: Fill as Crop, Fit as Normal.
    @Test func anOlderSavedFillStartsAtCrop() throws {
        let fill = Data(#"{"videoLayout":{"fit":"fill","zoom":1,"aspect":"source","crop":"off"}}"#.utf8)
        #expect(try JSONDecoder().decode(PlayerPreferences.self, from: fill).zoomMode == .crop)
        let fit = Data(#"{"videoLayout":{"fit":"fit","zoom":1,"aspect":"source","crop":"off"}}"#.utf8)
        #expect(try JSONDecoder().decode(PlayerPreferences.self, from: fit).zoomMode == .normal)
        #expect(try JSONDecoder().decode(PlayerPreferences.self, from: Data("{}".utf8)).zoomMode == .normal)
    }
}
