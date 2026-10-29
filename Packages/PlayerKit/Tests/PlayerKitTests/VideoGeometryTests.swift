import CoreGraphics
import Testing
import StremioKit
@testable import PlayerKit

/// Where the picture goes for each aspect override, crop, fit and zoom, and which exact source pixels remain visible.
@Suite struct VideoGeometryTests {
    /// An iPhone in landscape (~19.5:9), portrait, and a 16:9 display.
    private let phone = CGSize(width: 852, height: 393)
    private let portrait = CGSize(width: 393, height: 852)
    private let hd = CGSize(width: 1920, height: 1080)

    private func close(_ a: CGRect, _ b: CGRect, tolerance: CGFloat = 0.5) -> Bool {
        abs(a.minX - b.minX) < tolerance && abs(a.minY - b.minY) < tolerance
            && abs(a.width - b.width) < tolerance && abs(a.height - b.height) < tolerance
    }

    /// Builds a synthetic RGBA video frame (`source`) with black bars outside `movieRect` (`RGB(0,0,0)`) and distinct 6px sentinel bands
    /// right along the inner movie boundaries:
    /// - Top movie edge: Red `(255, 0, 0)`
    /// - Bottom movie edge: Green `(0, 255, 0)`
    /// - Left movie edge: Blue `(0, 0, 255)`
    /// - Right movie edge: Yellow `(255, 255, 0)`
    /// - Interior: Neutral gray `(128, 128, 128)`
    private func makeSyntheticMarkedFrame(source: CGSize, movieRect: CGRect) throws -> CGImage {
        let width = Int(source.width), height = Int(source.height)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let ctx = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        // CoreGraphics bitmap context has bottom-left origin; flip so y=0 is top-left like video coordinates.
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: 1, y: -1)
        ctx.setFillColor(red: 0, green: 0, blue: 0, alpha: 1)
        ctx.fill(CGRect(origin: .zero, size: source))

        let movie = movieRect.integral
        ctx.setFillColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1)
        ctx.fill(movie)

        let band: CGFloat = 6
        ctx.setFillColor(red: 0, green: 0, blue: 1, alpha: 1)
        ctx.fill(CGRect(x: movie.minX, y: movie.minY, width: band, height: movie.height))
        ctx.setFillColor(red: 1, green: 1, blue: 0, alpha: 1)
        ctx.fill(CGRect(x: movie.maxX - band, y: movie.minY, width: band, height: movie.height))
        ctx.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        ctx.fill(CGRect(x: movie.minX + band, y: movie.minY, width: movie.width - 2 * band, height: band))
        ctx.setFillColor(red: 0, green: 1, blue: 0, alpha: 1)
        ctx.fill(CGRect(x: movie.minX + band, y: movie.maxY - band, width: movie.width - 2 * band, height: band))

        return try #require(ctx.makeImage())
    }

    /// Renders `frame` into a `viewport` bitmap at `displayScale` using the exact clip (`geometry.visible`) + `.resize` (`geometry.picture`)
    /// transform used by AVPlayerLayer, AetherHostView, and MPVBackend, returning a top-left-origin pixel reader `(x, y) -> (r, g, b)`.
    private func renderIntoViewport(
        frame: CGImage,
        viewport: CGSize,
        displayScale: CGFloat,
        geometry: VideoGeometry
    ) throws -> (Int, Int) -> (Int, Int, Int) {
        let width = Int((viewport.width * displayScale).rounded())
        let height = Int((viewport.height * displayScale).rounded())
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        var buffer = [UInt8](repeating: 0, count: width * height * 4)
        try buffer.withUnsafeMutableBytes { raw in
            let ctx = try #require(CGContext(
                data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            ctx.interpolationQuality = .none
            let flipRect = { (r: CGRect) -> CGRect in
                let scaled = CGRect(x: r.minX * displayScale, y: r.minY * displayScale,
                                    width: r.width * displayScale, height: r.height * displayScale)
                return CGRect(x: scaled.minX, y: CGFloat(height) - scaled.maxY, width: scaled.width, height: scaled.height)
            }
            ctx.saveGState()
            ctx.clip(to: flipRect(geometry.visible))
            ctx.draw(frame, in: flipRect(geometry.picture))
            ctx.restoreGState()
        }
        return { x, y in
            let clampedX = min(max(0, x), width - 1)
            let clampedY = min(max(0, y), height - 1)
            let offset = (clampedY * width + clampedX) * 4
            return (Int(buffer[offset]), Int(buffer[offset + 1]), Int(buffer[offset + 2]))
        }
    }

    /// Synthetic marked-frame verifier: asserts source pixel coordinates AND renders a real RGBA bitmap into `viewport` to verify that
    /// the rendered pixels at all 4 edges of `geometry.visible` carry the active movie's sentinel border colors (never black bars, and
    /// never cropped past the sentinel borders into gray interior).
    private func assertVisiblePixelMarkersAndRenderedBitmap(
        viewport: CGSize,
        geometry: VideoGeometry,
        expectedMovieRect movie: CGRect,
        source: CGSize
    ) throws {
        #expect(close(geometry.sourceRect, movie, tolerance: 0.05))
        #expect(close(geometry.visibleSourceRect, movie, tolerance: 0.05))

        let movieMarkers = [
            CGPoint(x: movie.midX, y: movie.minY + 0.5),
            CGPoint(x: movie.midX, y: movie.maxY - 0.5),
            CGPoint(x: movie.minX + 0.5, y: movie.midY),
            CGPoint(x: movie.maxX - 0.5, y: movie.midY),
            CGPoint(x: movie.midX, y: movie.midY),
        ]
        for marker in movieMarkers {
            let projected = geometry.displayPoint(forSource: marker)
            #expect(geometry.visible.insetBy(dx: -1e-4, dy: -1e-4).contains(projected),
                    "movie pixel \(marker) must remain visible, got \(projected) vs \(geometry.visible)")
            let roundTrip = geometry.sourcePoint(forDisplay: projected)
            #expect(hypot(roundTrip.x - marker.x, roundTrip.y - marker.y) < 1e-4)
        }

        if movie.minY >= 1 {
            let topBar = geometry.displayPoint(forSource: CGPoint(x: movie.midX, y: movie.minY - 0.5))
            let bottomBar = geometry.displayPoint(forSource: CGPoint(x: movie.midX, y: movie.maxY + 0.5))
            #expect(!geometry.visible.insetBy(dx: 1e-4, dy: 1e-4).contains(topBar), "top bar pixel must be cropped out")
            #expect(!geometry.visible.insetBy(dx: 1e-4, dy: 1e-4).contains(bottomBar), "bottom bar pixel must be cropped out")
        }
        if movie.minX >= 1 {
            let leftBar = geometry.displayPoint(forSource: CGPoint(x: movie.minX - 0.5, y: movie.midY))
            let rightBar = geometry.displayPoint(forSource: CGPoint(x: movie.maxX + 0.5, y: movie.midY))
            #expect(!geometry.visible.insetBy(dx: 1e-4, dy: 1e-4).contains(leftBar), "left bar pixel must be cropped out")
            #expect(!geometry.visible.insetBy(dx: 1e-4, dy: 1e-4).contains(rightBar), "right bar pixel must be cropped out")
        }

        // Actual RGBA bitmap render verification at native display pixel resolution (1x on 1920×1080, 3x Retina on 852×393 / 393×852).
        let displayScale: CGFloat = viewport == hd ? 1 : 3
        let image = try makeSyntheticMarkedFrame(source: source, movieRect: movie)
        let pixelAt = try renderIntoViewport(frame: image, viewport: viewport, displayScale: displayScale, geometry: geometry)
        let vis = CGRect(x: geometry.visible.minX * displayScale, y: geometry.visible.minY * displayScale,
                         width: geometry.visible.width * displayScale, height: geometry.visible.height * displayScale)
        let midX = Int(vis.midX.rounded(.down))
        let midY = Int(vis.midY.rounded(.down))
        let topInsideY = Int(vis.minY.rounded(.up)) + 1
        let bottomInsideY = Int(vis.maxY.rounded(.down)) - 2
        let leftInsideX = Int(vis.minX.rounded(.up)) + 1
        let rightInsideX = Int(vis.maxX.rounded(.down)) - 2

        let topPixel = pixelAt(midX, topInsideY)
        let bottomPixel = pixelAt(midX, bottomInsideY)
        let leftPixel = pixelAt(leftInsideX, midY)
        let rightPixel = pixelAt(rightInsideX, midY)
        let centerPixel = pixelAt(midX, midY)

        #expect(topPixel.0 > 200 && topPixel.1 < 50 && topPixel.2 < 50,
                "top visible row must show Red movie sentinel border, got \(topPixel) in \(viewport)")
        #expect(bottomPixel.1 > 200 && bottomPixel.0 < 50 && bottomPixel.2 < 50,
                "bottom visible row must show Green movie sentinel border, got \(bottomPixel) in \(viewport)")
        #expect(leftPixel.2 > 200 && leftPixel.0 < 50 && leftPixel.1 < 50,
                "left visible column must show Blue movie sentinel border, got \(leftPixel) in \(viewport)")
        #expect(rightPixel.0 > 200 && rightPixel.1 > 200 && rightPixel.2 < 50,
                "right visible column must show Yellow movie sentinel border, got \(rightPixel) in \(viewport)")
        #expect(abs(centerPixel.0 - 128) <= 5 && abs(centerPixel.1 - 128) <= 5 && abs(centerPixel.2 - 128) <= 5,
                "center pixel must show movie interior, got \(centerPixel)")

        if vis.minX >= 3 {
            #expect(pixelAt(Int(vis.minX) - 2, midY) == (0, 0, 0))
            #expect(pixelAt(Int(vis.maxX.rounded(.up)) + 1, midY) == (0, 0, 0))
        }
        if vis.minY >= 3 {
            #expect(pixelAt(midX, Int(vis.minY) - 2) == (0, 0, 0))
            #expect(pixelAt(midX, Int(vis.maxY.rounded(.up)) + 1) == (0, 0, 0))
        }
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
        #expect(geometry.visibleSourceRect.height < hd.height, "Fill intentionally sacrifices top and bottom picture edges")
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

    /// Synthetic marked-frame & rendered RGBA bitmap verification across 16:9 displays, widescreen landscape iPhones, and portrait viewports:
    /// 1920×1080 with 1.85:1 (~21px bars), 2.00:1 (60px bars), 2.39:1 (~138px bars), and 1.65:1 (69px pillarbox bars),
    /// native 1920×1038 (no bars), and genuine 16:9 Auto.
    @Test func syntheticMarkedFramesPreserveExactMoviePixelsAcrossAllViewports() throws {
        let viewports = [hd, phone, portrait]

        for viewport in viewports {
            // 1. 1920×1080 with 1.85:1 content (~1920×1037.84, ~21.08px bars top & bottom).
            let layout185 = VideoLayout(zoomMode: .crop, aspectRatio: .widescreenA)
            let geo185 = try #require(VideoGeometry(bounds: viewport, source: hd, layout: layout185))
            let h185 = 1920.0 / 1.85
            try assertVisiblePixelMarkersAndRenderedBitmap(
                viewport: viewport,
                geometry: geo185,
                expectedMovieRect: CGRect(x: 0, y: (1080 - h185) / 2, width: 1920, height: h185),
                source: hd
            )
            #expect(abs(geo185.visible.width / geo185.visible.height - 1.85) < 0.0005)
            #expect(abs(geo185.visible.midX - viewport.width / 2) < 0.01 && abs(geo185.visible.midY - viewport.height / 2) < 0.01)

            // 2. 1920×1080 with 2.00:1 content (1920×960, 60px bars top & bottom).
            let layout200 = VideoLayout(zoomMode: .crop, aspectRatio: .widescreenB)
            let geo200 = try #require(VideoGeometry(bounds: viewport, source: hd, layout: layout200))
            try assertVisiblePixelMarkersAndRenderedBitmap(
                viewport: viewport,
                geometry: geo200,
                expectedMovieRect: CGRect(x: 0, y: 60, width: 1920, height: 960),
                source: hd
            )
            #expect(abs(geo200.visible.width / geo200.visible.height - 2.0) < 0.0005)

            // 3. 1920×1080 with 2.39:1 content (~1920×803.35, ~138.33px bars top & bottom).
            let layout239 = VideoLayout(zoomMode: .crop, aspectRatio: .anamorphicB)
            let geo239 = try #require(VideoGeometry(bounds: viewport, source: hd, layout: layout239))
            let h239 = 1920.0 / 2.39
            try assertVisiblePixelMarkersAndRenderedBitmap(
                viewport: viewport,
                geometry: geo239,
                expectedMovieRect: CGRect(x: 0, y: (1080 - h239) / 2, width: 1920, height: h239),
                source: hd
            )
            #expect(abs(geo239.visible.width / geo239.visible.height - 2.39) < 0.0005)

            // 4. 1920×1080 with 1.65:1 pillarboxed content (1782×1080, 69px bars left & right).
            let layout165 = VideoLayout(fit: .fit, crop: .precise(1.65))
            let geo165 = try #require(VideoGeometry(bounds: viewport, source: hd, layout: layout165))
            try assertVisiblePixelMarkersAndRenderedBitmap(
                viewport: viewport,
                geometry: geo165,
                expectedMovieRect: CGRect(x: 69, y: 0, width: 1782, height: 1080),
                source: hd
            )
            #expect(abs(geo165.visible.width / geo165.visible.height - 1.65) < 0.0005)

            // 5. Native 1.85:1 encode (1920×1038) without embedded black bars: zero fictitious crop.
            let native185 = CGSize(width: 1920, height: 1038)
            let geoNative = try #require(VideoGeometry(bounds: viewport, source: native185, layout: layout185))
            try assertVisiblePixelMarkersAndRenderedBitmap(
                viewport: viewport,
                geometry: geoNative,
                expectedMovieRect: CGRect(origin: .zero, size: native185),
                source: native185
            )

            // 6. Genuine 16:9 content (1920×1080) with Crop + Auto: zero pixels cropped.
            let layoutAuto = VideoLayout(zoomMode: .crop, aspectRatio: .auto)
            let geoAuto = try #require(VideoGeometry(bounds: viewport, source: hd, layout: layoutAuto))
            try assertVisiblePixelMarkersAndRenderedBitmap(
                viewport: viewport,
                geometry: geoAuto,
                expectedMovieRect: CGRect(origin: .zero, size: hd),
                source: hd
            )
        }

        let uncroppedPhone = try #require(VideoGeometry(bounds: phone, source: hd, layout: VideoLayout(zoomMode: .crop, aspectRatio: .auto)))
        let auto185Phone = try #require(VideoGeometry(bounds: phone, source: hd, layout: VideoLayout(zoomMode: .crop, aspectRatio: .auto, detectedAspect: 1.85)))
        let w185Phone = try #require(VideoGeometry(bounds: phone, source: hd, layout: VideoLayout(zoomMode: .crop, aspectRatio: .widescreenA)))
        let w200Phone = try #require(VideoGeometry(bounds: phone, source: hd, layout: VideoLayout(zoomMode: .crop, aspectRatio: .widescreenB)))
        #expect(abs(uncroppedPhone.visible.width - 393 * 16.0 / 9.0) < 0.1)
        #expect(close(auto185Phone.visible, w185Phone.visible, tolerance: 0.01))
        #expect(abs(w185Phone.visible.width - 393 * 1.85) < 0.1)
        #expect(abs(w200Phone.visible.width - 393 * 2.0) < 0.1)
        #expect(uncroppedPhone.visible.width < w185Phone.visible.width - 25)
        #expect(w185Phone.visible.width < w200Phone.visible.width - 55)
        #expect(w200Phone.visible.width < phone.width - 60, "2.00:1 leaves side margins on 19.5:9 rather than discarding movie pixels")
    }

    @Test func preciseCropKeepsTheMeasuredShape() throws {
        let geometry = try #require(VideoGeometry(bounds: phone, source: hd, layout: VideoLayout(fit: .fit, crop: .precise(1.869))))
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

    @Test func pixelAspectRatioAndCleanApertureCropSourceOnceIndependentlyOfViewport() throws {
        let coded = CGSize(width: 720, height: 480)
        let clean = CGRect(x: 8, y: 0, width: 704, height: 480)
        let par = 40.0 / 33.0
        let layout = VideoLayout(zoomMode: .crop, aspectRatio: .anamorphicA)
        let onPhone = try #require(VideoGeometry(bounds: phone, source: coded, pixelAspectRatio: par, cleanAperture: clean, layout: layout))
        let onPortrait = try #require(VideoGeometry(bounds: portrait, source: coded, pixelAspectRatio: par, cleanAperture: clean, layout: layout))
        #expect(onPhone.sourceRect == onPortrait.sourceRect, "source crop must never depend on screen dimensions")
        #expect(abs(onPhone.sourceRect.minX - 8) < 0.001 && abs(onPhone.sourceRect.width - 704) < 0.001)
        let expectedHeight = (704 * par) / 2.35
        #expect(abs(onPhone.sourceRect.height - expectedHeight) < 0.01)
        #expect(abs(onPhone.visible.width / onPhone.visible.height - 2.35) < 0.001)
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
        let hdInset = try #require(VideoGeometry(bounds: phone, source: hd, layout: VideoLayout(fit: .fit, inset: 59)))
        #expect(close(hdInset.visible, try #require(VideoGeometry(bounds: phone, source: hd, layout: VideoLayout(fit: .fit))).visible))
    }

    @Test func fillIgnoresAStaleSafeInset() throws {
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
    func fitPreservesAllPictureAndFillAddsOnlyTheMinimumCoverScale(_ ratio: Double) throws {
        let source = CGSize(width: ratio * 1000, height: 1000)
        let fit = try #require(VideoGeometry(bounds: phone, source: source, layout: VideoLayout(fit: .fit)))
        #expect(close(fit.content, fit.visible), "Aspect Fit preserves the full picture")
        #expect(abs(fit.picture.width / fit.picture.height - ratio) < 0.0001)
        let fill = try #require(VideoGeometry(bounds: phone, source: source, layout: VideoLayout(fit: .fill)))
        let scale = max(phone.width / fit.picture.width, phone.height / fit.picture.height)
        #expect(abs(fill.picture.width - fit.picture.width * scale) < 0.001)
        #expect(abs(fill.picture.height - fit.picture.height * scale) < 0.001)
        #expect(abs(fill.picture.width - phone.width) < 0.001 || abs(fill.picture.height - phone.height) < 0.001,
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
        for bounds in [phone, portrait, CGSize(width: 1024, height: 768)] {
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
                _ = VideoGeometry(bounds: portrait, source: source, layout: VideoLayout(fit: mode, zoom: 3))
            }
            #expect(VideoGeometry(bounds: phone, source: source, layout: fit) == original)
        }
    }
}
