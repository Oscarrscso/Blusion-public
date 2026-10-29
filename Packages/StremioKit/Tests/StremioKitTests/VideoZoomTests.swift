import Foundation
import Testing
@testable import StremioKit

/// Zoom Mode and Aspect Ratio: the layout each makes, where each is kept, and older saved settings.
@Suite struct VideoZoomTests {
    @Test func eachModeMakesItsLayout() {
        #expect(VideoLayout(zoomMode: .normal, aspectRatio: .anamorphicB, safeInset: 59) == VideoLayout(fit: .fit, crop: .ratio239, inset: 59))
        #expect(VideoLayout(zoomMode: .normal, aspectRatio: .auto, detectedAspect: 1.85, safeInset: 59) == VideoLayout(fit: .fit, inset: 59),
                "Normal shows the uncropped container frame when Aspect Ratio is Auto")
        #expect(VideoLayout(zoomMode: .crop, aspectRatio: .anamorphicB, safeInset: 59) == VideoLayout(fit: .fit, crop: .ratio239),
                "Crop trims bars and fits proportionally without overshooting into Fill")
        #expect(VideoLayout(zoomMode: .crop, aspectRatio: .auto) == VideoLayout(fit: .fit),
                "Auto with no detected bars preserves the full frame")
        #expect(VideoLayout(zoomMode: .crop, aspectRatio: .auto, detectedAspect: 1.85) == VideoLayout(fit: .fit, crop: .ratio185),
                "Auto in Crop trims detected encoded bars and proportionally fits the remaining film")
        #expect(VideoLayout(zoomMode: .crop, aspectRatio: .widescreenB, detectedAspect: 1.85) == VideoLayout(fit: .fit, crop: .ratio2x1),
                "Manual aspect ratio always overrides automatic bar detection")
        #expect(VideoLayout(zoomMode: .fill, aspectRatio: .auto, safeInset: 59) == VideoLayout(fit: .fill),
                "Fill intentionally scales to cover the screen")
        #expect(VideoLayout(zoomMode: .fill, aspectRatio: .widescreenA, detectedAspect: 2.39) == VideoLayout(fit: .fill, crop: .ratio185))
        #expect(VideoLayout(zoomMode: .stretch, aspectRatio: .widescreenA) == VideoLayout(fit: .stretch, crop: .ratio185))
        #if os(iOS) && !targetEnvironment(macCatalyst)
        #expect(VideoLayout(zoomMode: .aspectFit, aspectRatio: .anamorphicB, safeInset: 59) == VideoLayout(fit: .fit, crop: .ratio239))
        #expect(VideoLayout(zoomMode: .aspectFit, aspectRatio: .auto, detectedAspect: 2.0, safeInset: 59) == VideoLayout(fit: .fit))
        #else
        #expect(VideoLayout(zoomMode: .aspectFit, aspectRatio: .anamorphicB, safeInset: 59) == VideoLayout(fit: .fit, crop: .ratio239, inset: 59),
                "a Mac has no Aspect Fit: it plays as Normal")
        #endif
    }

    @Test func aspectRatioChoicesExcludeMistaken165And166Presets() {
        let labels = AspectRatioChoice.allCases.map(\.label)
        #expect(!labels.contains(where: { $0.contains("1.65") || $0.contains("1.66") }))
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
