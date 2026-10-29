import Foundation
import Testing
@testable import StremioKit

/// Zoom Mode and Aspect Ratio: the layout each makes, where each is kept, and older saved settings.
@Suite struct VideoZoomTests {
    @Test func eachModeMakesItsLayout() {
        #expect(VideoLayout(zoomMode: .normal, aspectRatio: .anamorphicB, safeInset: 59) == VideoLayout(fit: .fit, inset: 59),
                "Normal shows the uncropped container frame inside the safe area")
        #expect(VideoLayout(zoomMode: .normal, aspectRatio: .original, safeInset: 59) == VideoLayout(fit: .fit, inset: 59))
        #expect(VideoLayout(zoomMode: .crop, aspectRatio: .anamorphicB, safeInset: 59) == VideoLayout(fit: .fit, crop: .ratio239),
                "Crop trims bars for the chosen Aspect Ratio and fits proportionally without overshooting into Fill")
        #expect(VideoLayout(zoomMode: .crop, aspectRatio: .original) == VideoLayout(fit: .fit),
                "Original preserves the full frame")
        #expect(VideoLayout(zoomMode: .crop, aspectRatio: .widescreenB) == VideoLayout(fit: .fit, crop: .ratio2x1))
        #expect(VideoLayout(zoomMode: .fill, aspectRatio: .original, safeInset: 59) == VideoLayout(fit: .fill),
                "Fill intentionally scales to cover the screen")
        #expect(VideoLayout(zoomMode: .fill, aspectRatio: .widescreenA) == VideoLayout(fit: .fill, crop: .ratio185))
        #expect(VideoLayout(zoomMode: .stretch, aspectRatio: .widescreenA) == VideoLayout(fit: .stretch, crop: .ratio185))
        #if os(iOS) && !targetEnvironment(macCatalyst)
        #expect(VideoLayout(zoomMode: .aspectFit, aspectRatio: .anamorphicB, safeInset: 59) == VideoLayout(fit: .fit),
                "Aspect Fit shows the uncropped container frame across the full screen")
        #else
        #expect(VideoLayout(zoomMode: .aspectFit, aspectRatio: .anamorphicB, safeInset: 59) == VideoLayout(fit: .fit, inset: 59),
                "a Mac has no Aspect Fit: it plays as Normal")
        #endif
    }

    @Test func aspectRatioChoicesExcludeAutoAndMistaken165And166Presets() throws {
        let labels = AspectRatioChoice.allCases.map(\.label)
        #expect(!labels.contains("Auto"))
        #expect(labels.first == "Original")
        #expect(!labels.contains(where: { $0.contains("1.65") || $0.contains("1.66") }))
        let legacyAuto = try JSONDecoder().decode(AspectRatioChoice.self, from: Data(#""auto""#.utf8))
        #expect(legacyAuto == .original)
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
        preferences.zoomMode = .fill
        preferences.aspectRatios = ["tt1": .anamorphicB]
        preferences.videoLayout = VideoLayout(fit: .fit, inset: 40)
        let decoded = try JSONDecoder().decode(PlayerPreferences.self, from: JSONEncoder().encode(preferences))
        #expect(decoded.zoomMode == .fill && decoded.aspectRatios == ["tt1": .anamorphicB] && decoded.videoLayout.inset == 0)
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
