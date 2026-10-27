import CoreGraphics
import Testing
import PlayerKit
import StremioKit
@testable import Features

/// Video › Aspect Ratio's crop on a 1920×1080 file: the part of the frame kept (in pixels, as mpv crops it) and where it lands on the screen
/// (as AVPlayer and AetherEngine place it). The picture's geometry is always kept: the frame is cropped, never squeezed.
@Suite struct AspectRatioCropTests {
    private let hd = CGSize(width: 1920, height: 1080)
    /// An iPhone in landscape, about 2.17:1.
    private let phone = CGSize(width: 852, height: 393)

    /// The kept rectangle in source pixels, rounded the way the mpv backend rounds `video-crop`.
    private func keptPixels(_ choice: PlayerViewModel.AspectRatioChoice) -> CGRect {
        let kept = VideoGeometry.keptFraction(aspect: hd.width / hd.height, crop: choice.ratio)
        let width = (hd.width * kept.width).rounded(), height = (hd.height * kept.height).rounded()
        return CGRect(x: ((hd.width - width) / 2).rounded(.down), y: ((hd.height - height) / 2).rounded(.down), width: width, height: height)
    }

    private func geometry(_ choice: PlayerViewModel.AspectRatioChoice, fit: VideoFit = .fit) throws -> VideoGeometry {
        try #require(VideoGeometry(bounds: phone, source: hd, layout: VideoLayout(fit: fit, crop: choice.crop ?? .off)))
    }

    @Test func autoCropsNothing() throws {
        #expect(PlayerViewModel.AspectRatioChoice.auto.crop == nil)
        #expect(keptPixels(.auto) == CGRect(origin: .zero, size: hd))
        let shown = try geometry(.auto)
        #expect(abs(shown.visible.width / shown.visible.height - 16.0 / 9.0) < 0.001)
    }

    @Test func widescreenACutsTheTopAndBottomTo1038Lines() throws {
        #expect(keptPixels(.widescreenA) == CGRect(x: 0, y: 21, width: 1920, height: 1038))
        let shown = try geometry(.widescreenA)
        // 1.85 is narrower than the phone: it fits by height, the cropped picture at its own shape.
        #expect(abs(shown.visible.height - 393) < 0.5 && abs(shown.visible.width / shown.visible.height - 1.85) < 0.001)
        #expect(abs(shown.picture.width / shown.picture.height - 16.0 / 9.0) < 0.001, "the frame is scaled uniformly")
    }

    @Test func anamorphicBCutsTheTopAndBottomTo803Lines() {
        #expect(keptPixels(.anamorphicB) == CGRect(x: 0, y: 138, width: 1920, height: 803))
    }

    /// 2.39 is wider than the phone's 2.17: Fit runs the cropped picture the full width with thin bars above and below, Fill crops the
    /// sides a little more; both keep its shape.
    @Test func aTargetWiderThanTheScreenFitsByWidth() throws {
        let fitted = try geometry(.anamorphicB)
        #expect(abs(fitted.visible.width - 852) < 0.5 && abs(fitted.visible.height - 852 / 2.39) < 0.5)
        #expect(abs(fitted.visible.midY - 196.5) < 0.5)
        #expect(abs(fitted.picture.width / fitted.picture.height - 16.0 / 9.0) < 0.001)
        let filled = try geometry(.anamorphicB, fit: .fill)
        #expect(abs(filled.visible.height - 393) < 0.5 && abs(filled.visible.width - 852) < 0.5)
        #expect(abs(filled.picture.width / filled.picture.height - 16.0 / 9.0) < 0.001)
    }

    @Test func sdtvCutsTheSides() {
        #expect(keptPixels(.sdtv) == CGRect(x: 240, y: 0, width: 1440, height: 1080))
    }

    @Test func everyChoiceIsACropNeverADisplayAspect() {
        for choice in PlayerViewModel.AspectRatioChoice.allCases where choice != .auto {
            #expect(abs((choice.crop?.ratio ?? 0) - (choice.ratio ?? -1)) < 0.0005, "\(choice)")
        }
    }
}
