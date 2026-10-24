import CoreGraphics
import Testing
@testable import Features

@Suite struct LogoLegibilityTests {
    private struct Pixel: Equatable {
        let red: UInt8, green: UInt8, blue: UInt8, alpha: UInt8
    }

    /// A 20 x 10 logo on a clear canvas: `colour` fills the left 16 columns and `detail`, when given, the right 4.
    private func logo(_ colour: CGColor, detail: CGColor? = nil) -> CGImage? {
        guard let context = CGContext(data: nil, width: 20, height: 10, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.clear(CGRect(x: 0, y: 0, width: 20, height: 10))
        context.setFillColor(colour)
        context.fill(CGRect(x: 0, y: 0, width: 16, height: 10))
        if let detail {
            context.setFillColor(detail)
            context.fill(CGRect(x: 16, y: 0, width: 4, height: 10))
        }
        return context.makeImage()
    }

    /// The pixel at `x` in the middle row, as stored: colour multiplied by alpha.
    private func pixel(of image: CGImage, x: Int) -> Pixel? {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                                          bytesPerRow: image.width * 4,
                                          space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }
        guard drawn else { return nil }
        let offset = ((image.height / 2) * image.width + x) * 4
        return Pixel(red: bytes[offset], green: bytes[offset + 1], blue: bytes[offset + 2], alpha: bytes[offset + 3])
    }

    private func colour(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, alpha: CGFloat = 1) -> CGColor {
        CGColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }

    @Test func aBlackLogoBecomesWhiteAndKeepsItsShape() throws {
        let source = try #require(logo(colour(0, 0, 0)))
        let legible = LogoLegibility.legible(source)
        #expect(legible.width == 20 && legible.height == 10)
        #expect(pixel(of: legible, x: 4) == Pixel(red: 255, green: 255, blue: 255, alpha: 255))
        #expect(pixel(of: legible, x: 18) == Pixel(red: 0, green: 0, blue: 0, alpha: 0), "the clear part stays clear")
    }

    @Test func aNearBlackLogoBecomesNearWhite() throws {
        let source = try #require(logo(colour(0.12, 0.12, 0.12)))
        let lit = try #require(pixel(of: LogoLegibility.legible(source), x: 4))
        #expect(lit.red > 215 && lit.red == lit.green && lit.green == lit.blue)
    }

    @Test func aLightDetailInsideADarkLogoTurnsDarkSoItStillShows() throws {
        // 80% black lettering, 20% white detail: the lettering turns white, and the detail black rather than vanishing into it.
        let source = try #require(logo(colour(0, 0, 0), detail: colour(1, 1, 1)))
        let legible = LogoLegibility.legible(source)
        #expect(pixel(of: legible, x: 4) == Pixel(red: 255, green: 255, blue: 255, alpha: 255))
        #expect(pixel(of: legible, x: 18) == Pixel(red: 0, green: 0, blue: 0, alpha: 255))
    }

    @Test func aSeeThroughBlackLogoKeepsItsAlpha() throws {
        let source = try #require(logo(colour(0, 0, 0, alpha: 0.5)))
        let lit = try #require(pixel(of: LogoLegibility.legible(source), x: 4))
        // White at half alpha is stored as half of full in every channel.
        #expect(lit.alpha > 120 && lit.alpha < 135)
        #expect(lit.red == lit.alpha && lit.green == lit.alpha && lit.blue == lit.alpha)
    }

    @Test func aLogoInADarkColourKeepsThatColour() throws {
        // Mobland's deep red: dark, but not black.
        let source = try #require(logo(colour(0.6, 0.05, 0.05)))
        #expect(LogoLegibility.legible(source) === source)
    }

    @Test func aWhiteLogoAndAColouredOneAreLeftAlone() throws {
        let white = try #require(logo(colour(1, 1, 1)))
        #expect(LogoLegibility.legible(white) === white)
        let coloured = try #require(logo(colour(0.9, 0.7, 0.1)))
        #expect(LogoLegibility.legible(coloured) === coloured)
    }

    @Test func aLogoThatIsOnlyPartlyDarkIsLeftAlone() throws {
        // White lettering with a black edge taking a fifth of it: turning that over would lose the edge.
        let source = try #require(logo(colour(1, 1, 1), detail: colour(0, 0, 0)))
        #expect(LogoLegibility.legible(source) === source)
    }

    @Test func anEmptyImageIsLeftAlone() throws {
        let context = try #require(CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.clear(CGRect(x: 0, y: 0, width: 8, height: 8))
        let source = try #require(context.makeImage())
        #expect(LogoLegibility.legible(source) === source)
    }
}
