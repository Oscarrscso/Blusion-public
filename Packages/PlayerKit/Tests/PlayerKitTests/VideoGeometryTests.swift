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
}
