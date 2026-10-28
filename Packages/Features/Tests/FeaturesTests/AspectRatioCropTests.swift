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
        for fit in [VideoFit.fit, .fill] {
            let layout = VideoLayout(fit: fit, crop: choice.crop)
            let shown = try #require(VideoGeometry(bounds: phone, source: hd, layout: layout))
            #expect(layout.aspect == .source)
            #expect(abs(shown.picture.width / shown.picture.height - 16.0 / 9.0) < 0.001)
            #expect(abs(shown.picture.midX - phone.width / 2) < 0.001)
            #expect(abs(shown.picture.midY - phone.height / 2) < 0.001)
            #expect(abs(shown.content.width / shown.content.height - (choice.ratio ?? 16.0 / 9.0)) < 0.001)
        }
    }

    @Test func choosingTwoToOneTrimsTheBarsAndFitsTheWholePicture() throws {
        let fit = try #require(VideoGeometry(bounds: phone, source: hd, layout: VideoLayout(fit: .fit, crop: .ratio2x1)))
        #expect(abs(fit.visible.width - 786) < 0.001 && abs(fit.visible.height - 393) < 0.001)
        #expect(abs(fit.picture.width / fit.picture.height - 16.0 / 9.0) < 0.001)
        let crop = try #require(VideoGeometry(bounds: phone, source: hd, layout: VideoLayout(fit: .fill, crop: .ratio2x1)))
        #expect(abs(crop.picture.width - 852) < 0.001)
        #expect(abs(crop.picture.height - 852 * 9.0 / 16.0) < 0.001)
        #expect(abs(crop.content.height - 426) < 0.001)
    }
}
