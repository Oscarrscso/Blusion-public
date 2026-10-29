import CoreGraphics
import Testing
@testable import PlaybackGeometry

@Suite struct PictureGeometryTests {
    private let hd = CGSize(width: 1920, height: 1080)
    private let viewports = [
        CGSize(width: 1920, height: 1080),
        CGSize(width: 852, height: 393),
        CGSize(width: 393, height: 852),
    ]

    @Test func sourceCropIsIndependentOfViewportDimensions() throws {
        for ratio in [1.85, 2.0, 2.39, 1.65, 16.0 / 9.0] {
            let expected = try #require(PictureGeometry.sourceCropRect(source: hd, crop: ratio))
            for viewport in viewports {
                let geometry = try #require(PictureGeometry(bounds: viewport, source: hd, crop: ratio, fit: .fit))
                #expect(abs(geometry.sourceRect.minX - expected.minX) < 1e-6)
                #expect(abs(geometry.sourceRect.minY - expected.minY) < 1e-6)
                #expect(abs(geometry.sourceRect.width - expected.width) < 1e-6)
                #expect(abs(geometry.sourceRect.height - expected.height) < 1e-6)
                #expect(abs(geometry.visibleSourceRect.minX - expected.minX) < 1e-6)
                #expect(abs(geometry.visibleSourceRect.minY - expected.minY) < 1e-6)
                #expect(abs(geometry.visibleSourceRect.width - expected.width) < 1e-6)
                #expect(abs(geometry.visibleSourceRect.height - expected.height) < 1e-6)
            }
        }
    }

    @Test func pixelAspectRatioAndCleanApertureApplyInSourceSpace() throws {
        // Anamorphic NTSC 720x480 with 704x480 clean aperture and 32:27 PAR -> 1.85:1 letterboxed inside.
        let source = CGSize(width: 720, height: 480)
        let aperture = CGRect(x: 8, y: 0, width: 704, height: 480)
        let par = 32.0 / 27.0
        let geometry = try #require(PictureGeometry(bounds: CGSize(width: 852, height: 393), source: source,
                                                    pixelAspectRatio: par, cleanAperture: aperture, crop: 1.85, fit: .fit))
        let apertureAspect = (704.0 * par) / 480.0
        let expectedHeight = 480.0 * (apertureAspect / 1.85)
        #expect(abs(geometry.sourceRect.minX - 8) < 1e-6)
        #expect(abs(geometry.sourceRect.width - 704) < 1e-6)
        #expect(abs(geometry.sourceRect.height - expectedHeight) < 1e-6)
        #expect(abs(geometry.content.width / geometry.content.height - 1.85) < 1e-6)
        #expect(abs(geometry.visible.midX - 426) < 1e-6 && abs(geometry.visible.midY - 196.5) < 1e-6)
    }

    @Test func nativeWidescreenEncodeProducesZeroFictitiousCrop() throws {
        let native185 = CGSize(width: 1920, height: 1038)
        for viewport in viewports {
            let geometry = try #require(PictureGeometry(bounds: viewport, source: native185, crop: 1.85, fit: .fit))
            #expect(geometry.sourceRect == CGRect(origin: .zero, size: native185))
            #expect(abs(geometry.visibleSourceRect.width - 1920) < 1e-6)
            #expect(abs(geometry.visibleSourceRect.height - 1038) < 1e-6)
        }
    }
}
