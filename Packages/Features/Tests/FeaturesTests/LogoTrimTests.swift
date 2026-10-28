import CoreGraphics
import Testing
#if canImport(UIKit)
import UIKit
#endif
@testable import Features

@Suite struct LogoTrimTests {
    /// A width x height RGBA image, clear except for an opaque block at `block` (pixels from the top left).
    private func image(width: Int, height: Int, block: CGRect?, alpha: CGFloat = 1) -> CGImage? {
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.clear(CGRect(x: 0, y: 0, width: width, height: height))
        if let block {
            context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: alpha))
            // Core Graphics counts from the bottom, so flip to describe the block from the top.
            context.fill(CGRect(x: block.minX, y: CGFloat(height) - block.maxY, width: block.width, height: block.height))
        }
        return context.makeImage()
    }

    @Test func boundsAreTheVisiblePixelsFromTheTopLeft() throws {
        let source = try #require(image(width: 40, height: 30, block: CGRect(x: 5, y: 8, width: 20, height: 10)))
        #expect(LogoTrim.visibleBounds(of: source) == CGRect(x: 5, y: 8, width: 20, height: 10))
        let trimmed = LogoTrim.trimmed(source)
        #expect(trimmed.width == 20 && trimmed.height == 10)
    }

    @Test func aFullyTransparentImageIsLeftAlone() throws {
        let source = try #require(image(width: 10, height: 10, block: nil))
        #expect(LogoTrim.visibleBounds(of: source) == nil)
        #expect(LogoTrim.trimmed(source) === source)
    }

    @Test func anImageWithNoPaddingIsLeftAlone() throws {
        let source = try #require(image(width: 10, height: 6, block: CGRect(x: 0, y: 0, width: 10, height: 6)))
        #expect(LogoTrim.visibleBounds(of: source) == nil)
        #expect(LogoTrim.trimmed(source) === source)
    }

    @Test func aHazeTrailingToOneSideIsBalancedSoTheLetteringIsCentred() {
        // Lettering 40...60, haze reaching out to 0 on the left and 70 on the right: centre 50, so the span runs 0...100.
        let span = LogoTrim.centredSpan(visible: CGRect(x: 0, y: 0, width: 70, height: 10), solid: CGRect(x: 40, y: 0, width: 20, height: 10))
        #expect(span?.minX == 0 && span?.width == 100)
        #expect(LogoTrim.centredSpan(visible: CGRect(x: 0, y: 0, width: 70, height: 10), solid: nil) == nil, "no solid lettering: as it is")
        let symmetric = LogoTrim.centredSpan(visible: CGRect(x: 0, y: 0, width: 70, height: 10), solid: CGRect(x: 25, y: 0, width: 20, height: 10))
        #expect(symmetric == nil, "already centred")
    }

    @Test func trimmingAHazyLogoWidensItWithTransparentSpace() throws {
        let width = 100, height = 20
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.3))
        context.fill(CGRect(x: 10, y: 0, width: 60, height: height))
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 50, y: 0, width: 20, height: height))
        let source = try #require(context.makeImage())
        // Visible 10...70, lettering 50...70 (centre 60): widened to 10...110, so 100 wide.
        #expect(LogoTrim.trimmed(source).width == 100)
    }

    @Test func faintPixelsBelowTheThresholdDoNotCount() throws {
        let source = try #require(image(width: 20, height: 20, block: CGRect(x: 2, y: 2, width: 16, height: 16), alpha: 0.02))
        #expect(LogoTrim.visibleBounds(of: source) == nil)
    }

    #if canImport(UIKit)
    @Test func paddedLogoReservesItsTrimmedVisibleHeight() throws {
        let source = try #require(image(width: 400, height: 400, block: CGRect(x: 50, y: 170, width: 300, height: 60)))
        let trimmed = LogoTrim.trimmed(source)
        let prepared = UIImage(cgImage: trimmed)

        #expect(prepared.size == CGSize(width: 300, height: 60))
        let measured = LogoLayout.fittedSize(imageSize: prepared.size, proposedWidth: 300,
                                             maxWidth: 300, maxHeight: 100)
        #expect(measured == CGSize(width: 300, height: 60))
    }
    #endif
}
