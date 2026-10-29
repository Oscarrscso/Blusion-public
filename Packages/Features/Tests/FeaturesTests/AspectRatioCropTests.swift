import CoreGraphics
import Testing
import PlayerKit
import StremioKit
@testable import Features

/// Aspect choices trim the original frame; fitting and filling always scale that frame proportionally about its centre.
@Suite struct AspectRatioCropTests {
    private let hd = CGSize(width: 1920, height: 1080)
    private let phone = CGSize(width: 852, height: 393)

    @Test(arguments: AspectRatioChoice.allCases)
    func aspectChoicesTrimWithoutDistortingOrMovingTheOriginalPicture(_ choice: AspectRatioChoice) throws {
        for mode in [VideoZoomMode.crop, .fill] {
            let layout = VideoLayout(zoomMode: mode, aspectRatio: choice)
            let shown = try #require(VideoGeometry(bounds: phone, source: hd, layout: layout))
            #expect(layout.aspect == .source)
            #expect(abs(shown.picture.width / shown.picture.height - 16.0 / 9.0) < 0.001)
            #expect(abs(shown.picture.midX - phone.width / 2) < 0.001)
            #expect(abs(shown.picture.midY - phone.height / 2) < 0.001)
            #expect(abs(shown.content.width / shown.content.height - (choice.ratio ?? 16.0 / 9.0)) < 0.001)
            if mode == .crop {
                #expect(abs(shown.visible.width - shown.content.width) < 0.001 && abs(shown.visible.height - shown.content.height) < 0.001,
                        "Crop never discards movie content inside the trimmed source rectangle")
            } else {
                #expect(abs(shown.visible.width - phone.width) < 0.001 && abs(shown.visible.height - phone.height) < 0.001,
                        "Fill intentionally covers the entire viewport")
            }
        }
    }

    @Test func cropFitsTrimmedFilmWhileFillCoversTheScreen() throws {
        let cropMode = try #require(VideoGeometry(bounds: phone, source: hd,
                                                  layout: VideoLayout(zoomMode: .crop, aspectRatio: .widescreenB)))
        #expect(abs(cropMode.visible.width - 786) < 0.001 && abs(cropMode.visible.height - 393) < 0.001)
        #expect(abs(cropMode.visibleSourceRect.width - 1920) < 0.01 && abs(cropMode.visibleSourceRect.height - 960) < 0.01)

        let fillMode = try #require(VideoGeometry(bounds: phone, source: hd,
                                                  layout: VideoLayout(zoomMode: .fill, aspectRatio: .widescreenB)))
        #expect(abs(fillMode.picture.width - 852) < 0.001)
        #expect(abs(fillMode.picture.height - 852 * 9.0 / 16.0) < 0.001)
        #expect(abs(fillMode.content.height - 426) < 0.001)
    }
}
