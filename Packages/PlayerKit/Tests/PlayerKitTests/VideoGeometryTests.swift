import CoreGraphics
import Testing
import StremioKit
@testable import PlayerKit

/// Where the picture goes for each aspect override, crop, fit and zoom.
@Suite struct VideoGeometryTests {
    /// An iPhone in landscape, about 19.5:9.
    private let phone = CGSize(width: 852, height: 393)
    private let hd = CGSize(width: 1920, height: 1080)

    private func close(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) < 0.5 && abs(a.minY - b.minY) < 0.5 && abs(a.width - b.width) < 0.5 && abs(a.height - b.height) < 0.5
    }

    @Test func fitPillarboxesA16x9PictureOnAWiderScreen() throws {
        let geometry = try #require(VideoGeometry(bounds: phone, source: hd, layout: VideoLayout(fit: .fit)))
        let width = 393 * 16.0 / 9.0
        #expect(close(geometry.picture, CGRect(x: (852 - width) / 2, y: 0, width: width, height: 393)))
        #expect(close(geometry.visible, geometry.picture))
    }

    @Test func fillCropsTopAndBottom() throws {
        let geometry = try #require(VideoGeometry(bounds: phone, source: hd, layout: VideoLayout(fit: .fill)))
        let height = 852 * 9.0 / 16.0
        #expect(close(geometry.picture, CGRect(x: 0, y: (393 - height) / 2, width: 852, height: height)))
        #expect(close(geometry.visible, CGRect(origin: .zero, size: phone)))
    }

    @Test func stretchFillsTheView() throws {
        let geometry = try #require(VideoGeometry(bounds: phone, source: hd, layout: VideoLayout(fit: .stretch)))
        #expect(close(geometry.picture, CGRect(origin: .zero, size: phone)))
    }

    /// A 2.39:1 film letterboxed in a 16:9 file: the crop takes the bars off, so Fit runs it the full width of the phone.
    @Test func cropRemovesBurnedInLetterbox() throws {
        let geometry = try #require(VideoGeometry(bounds: phone, source: hd, layout: VideoLayout(fit: .fit, crop: .ratio239)))
        let shownHeight = 852 / 2.39
        #expect(close(geometry.visible, CGRect(x: 0, y: (393 - shownHeight) / 2, width: 852, height: shownHeight)))
        // The whole 16:9 picture is larger than what shows, centred on it.
        #expect(abs(geometry.picture.width - 852) < 0.5)
        #expect(abs(geometry.picture.height - 852 * 9 / 16) < 0.5)
        #expect(abs(geometry.picture.midY - geometry.visible.midY) < 0.5)
    }

    /// A 4:3 show pillarboxed in a 16:9 file: cropping to 4:3 keeps the middle of the width.
    @Test func cropRemovesPillarbox() throws {
        let geometry = try #require(VideoGeometry(bounds: phone, source: hd, layout: VideoLayout(fit: .fit, crop: .ratio4x3)))
        #expect(abs(geometry.visible.height - 393) < 0.5)
        #expect(abs(geometry.visible.width - 393 * 4 / 3) < 0.5)
        #expect(abs(geometry.picture.width - 393 * 16 / 9) < 0.5)
    }

    /// The precise crop the player measured (a 1.85:1 film's thin bars, say) keeps its exact shape: No Bars shows the picture as
    /// measured, not the standard ratio nearest it.
    @Test func preciseCropKeepsTheMeasuredShape() throws {
        let geometry = try #require(VideoGeometry(bounds: phone, source: hd, layout: VideoLayout(fit: .fit, crop: .precise(1.869))))
        // Shape 1.869 is narrower than the 2.169 screen: it fits by height, so the gap is at the sides now.
        #expect(abs(geometry.visible.height - 393) < 0.5 && abs(geometry.visible.width - 393 * 1.869) < 0.5)
        #expect(abs(geometry.picture.width - 393 * 1.869) < 0.5 && abs(geometry.picture.height - 393 * 1.869 / (16.0 / 9.0)) < 0.5)
        let measured = VideoGeometry.keptFraction(aspect: 16.0 / 9.0, crop: 1.869)
        #expect(measured.width == 1 && abs(measured.height - 16.0 / (9.0 * 1.869)) < 1e-9 && abs(measured.midY - 0.5) < 1e-9)
    }

    @Test func aspectOverrideReshapesThePicture() throws {
        let dvd = CGSize(width: 720, height: 480)
        let geometry = try #require(VideoGeometry(bounds: phone, source: dvd, layout: VideoLayout(fit: .fit, aspect: .ratio16x9)))
        #expect(abs(geometry.picture.width / geometry.picture.height - 16.0 / 9.0) < 0.001)
    }

    @Test func zoomGrowsAboutTheCentreAndIsClipped() throws {
        let geometry = try #require(VideoGeometry(bounds: phone, source: hd, layout: VideoLayout(fit: .fit, zoom: 2)))
        #expect(abs(geometry.picture.height - 786) < 0.5)
        #expect(abs(geometry.picture.midX - 426) < 0.5 && abs(geometry.picture.midY - 196.5) < 0.5)
        #expect(close(geometry.visible, CGRect(origin: .zero, size: phone)))
    }

    /// Zoom Mode's Normal keeps clear of the notch: a picture wider than the safe area fits its width, still centred on the screen.
    @Test func theSafeAreaInsetNarrowsFitAndKeepsThePictureCentred() throws {
        let scope = CGSize(width: 2390, height: 1000)
        let inset = try #require(VideoGeometry(bounds: phone, source: scope, layout: VideoLayout(fit: .fit, inset: 59)))
        #expect(abs(inset.visible.width - (852 - 118)) < 0.5 && abs(inset.visible.midX - 426) < 0.5)
        let whole = try #require(VideoGeometry(bounds: phone, source: scope, layout: VideoLayout(fit: .fit)))
        #expect(abs(whole.visible.width - 852) < 0.5, "Aspect Fit uses the whole screen")
        // A 16:9 picture is narrower than the safe area already: the inset changes nothing.
        let hdInset = try #require(VideoGeometry(bounds: phone, source: hd, layout: VideoLayout(fit: .fit, inset: 59)))
        #expect(close(hdInset.visible, try #require(VideoGeometry(bounds: phone, source: hd, layout: VideoLayout(fit: .fit))).visible))
    }

    @Test func cropIgnoresAStaleSafeInset() throws {
        let layout = VideoLayout(fit: .fill, inset: 59)
        let geometry = try #require(VideoGeometry(bounds: phone, source: hd, layout: layout))
        #expect(close(geometry.visible, CGRect(origin: .zero, size: phone)))
    }

    @Test func noSizeNoGeometry() {
        #expect(VideoGeometry(bounds: .zero, source: hd, layout: VideoLayout()) == nil)
        #expect(VideoGeometry(bounds: phone, source: .zero, layout: VideoLayout()) == nil)
    }

    @Test func keptFractionForPixelCrops() {
        #expect(VideoGeometry.keptFraction(aspect: 16.0 / 9.0, crop: nil) == CGRect(x: 0, y: 0, width: 1, height: 1))
        let letterbox = VideoGeometry.keptFraction(aspect: 16.0 / 9.0, crop: 2.39)
        #expect(letterbox.width == 1 && abs(letterbox.height - (16.0 / 9.0) / 2.39) < 1e-9 && abs(letterbox.midY - 0.5) < 1e-9)
        let pillarbox = VideoGeometry.keptFraction(aspect: 16.0 / 9.0, crop: 4.0 / 3.0)
        #expect(pillarbox.height == 1 && abs(pillarbox.width - 0.75) < 1e-9 && abs(pillarbox.midX - 0.5) < 1e-9)
    }

    @Test(arguments: [16.0 / 9.0, 1.85, 2.0, 2.39])
    func fitPreservesAllPictureAndCropAddsOnlyTheMinimumScale(_ ratio: Double) throws {
        let source = CGSize(width: ratio * 1000, height: 1000)
        let fit = try #require(VideoGeometry(bounds: phone, source: source, layout: VideoLayout(fit: .fit)))
        #expect(close(fit.content, fit.visible), "Aspect Fit preserves the full picture")
        #expect(abs(fit.picture.width / fit.picture.height - ratio) < 0.0001)
        let crop = try #require(VideoGeometry(bounds: phone, source: source, layout: VideoLayout(fit: .fill)))
        let scale = max(phone.width / fit.picture.width, phone.height / fit.picture.height)
        #expect(abs(crop.picture.width - fit.picture.width * scale) < 0.001)
        #expect(abs(crop.picture.height - fit.picture.height * scale) < 0.001)
        #expect(abs(crop.picture.width - phone.width) < 0.001 || abs(crop.picture.height - phone.height) < 0.001,
                "one dimension touches the screen exactly: no overshoot")
    }

    @Test func twoToOneFitsNaturallyWithoutEnlargement() throws {
        let layout = VideoLayout(fit: .fit, aspect: .ratio2x1)
        let fit = try #require(VideoGeometry(bounds: phone, source: CGSize(width: 2000, height: 1000), layout: layout))
        #expect(close(fit.picture, CGRect(x: 33, y: 0, width: 786, height: 393)))
        let letterboxed = try #require(VideoGeometry(bounds: phone, source: hd,
                                                     layout: VideoLayout(fit: .fit, aspect: .ratio2x1, crop: .ratio2x1)))
        #expect(close(letterboxed.visible, fit.visible))
        #expect(abs(letterboxed.picture.width / letterboxed.picture.height - 16.0 / 9.0) < 0.0001)
    }

    @Test func displayAspectCannotChangeTheMeasuredSourceCrop() throws {
        let geometry = try #require(VideoGeometry(bounds: phone, source: hd,
                                                  layout: VideoLayout(fit: .fit, aspect: .ratio2x1, crop: .ratio239)))
        #expect(abs(geometry.content.width / geometry.content.height - 2) < 0.0001)
        #expect(abs(geometry.content.height / geometry.picture.height - (16.0 / 9.0) / 2.39) < 0.0001)
    }

    @Test(arguments: [16.0 / 9.0, 1.85, 2.0, 2.39, 4.0 / 3.0])
    func encodedBarsAndANativePictureHaveTheSameVisibleGeometry(_ ratio: Double) throws {
        for fit in VideoFit.allCases {
            let encoded = try #require(VideoGeometry(bounds: phone, source: hd, layout: VideoLayout(fit: fit, crop: .precise(ratio))))
            let native = try #require(VideoGeometry(bounds: phone, source: CGSize(width: ratio * 1000, height: 1000),
                                                    layout: VideoLayout(fit: fit)))
            #expect(close(encoded.content, native.content))
            #expect(close(encoded.visible, native.visible))
            #expect(abs(encoded.picture.width / encoded.picture.height - 16.0 / 9.0) < 0.001 || fit == .stretch)
        }
    }

    @Test(arguments: [16.0 / 9.0, 1.85, 2.0, 2.39, 4.0 / 3.0])
    func mpvFittedScalesReconstructTheSameOriginalFrameInEveryMode(_ ratio: Double) throws {
        for bounds in [phone, CGSize(width: 393, height: 852), CGSize(width: 1024, height: 768)] {
            let baseline = try #require(VideoGeometry(bounds: bounds, source: hd, layout: VideoLayout()))
            for fit in VideoFit.allCases {
                let layout = VideoLayout(fit: fit, aspect: .ratio2x1, crop: .precise(ratio), inset: fit == .fit ? 59 : 0)
                let geometry = try #require(VideoGeometry(bounds: bounds, source: hd, layout: layout))
                #expect(abs(baseline.picture.width * geometry.fittedScale.width - geometry.picture.width) < 0.001)
                #expect(abs(baseline.picture.height * geometry.fittedScale.height - geometry.picture.height) < 0.001)
            }
        }
    }

    @Test func rotationAndModeSwitchesAlwaysReturnToTheOriginalGeometry() throws {
        let source = CGSize(width: 2000, height: 1000)
        let fit = VideoLayout(fit: .fit, aspect: .ratio2x1)
        let original = try #require(VideoGeometry(bounds: phone, source: source, layout: fit))
        for _ in 0..<10 {
            for mode in VideoFit.allCases {
                _ = VideoGeometry(bounds: CGSize(width: 393, height: 852), source: source, layout: VideoLayout(fit: mode, zoom: 3))
            }
            #expect(VideoGeometry(bounds: phone, source: source, layout: fit) == original)
        }
    }
}
