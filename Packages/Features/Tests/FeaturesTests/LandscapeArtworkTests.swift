import Foundation
import Testing
@testable import Features
#if canImport(UIKit)
import SwiftUI
import UIKit
#endif

@Suite struct LandscapeArtworkTests {
    #if canImport(UIKit)
    /// Compare rendered pixels with the underlying ArtworkImage, without a network fetch or image-loading animation.
    /// The known placeholder surface follows the same overlay path as a loaded picture. The old 32% veil fails this check.
    @MainActor
    @Test(arguments: ["", "Sample Title"])
    func landscapeCompositionPreservesArtworkOutsideTheLogo(title: String) throws {
        let size = CGSize(width: 160, height: 90)
        let baseline = ImageRenderer(content: ArtworkImage(url: nil).frame(width: size.width, height: size.height))
        let landscape = ImageRenderer(content: LandscapeArtwork(title: title, artwork: nil, logo: nil, maxPixelSize: 160)
            .frame(width: size.width, height: size.height))
        baseline.scale = 1
        landscape.scale = 1
        let expected = try pixels(of: #require(baseline.uiImage?.cgImage))
        let actual = try pixels(of: #require(landscape.uiImage?.cgImage))
        // Corners outside the title/shadow and rating area must retain every colour channel, including alpha.
        for (x, y) in [(8, 8), (151, 8), (8, 81), (151, 81)] {
            let start = (y * Int(size.width) + x) * 4
            #expect(Array(actual[start..<(start + 4)]) == Array(expected[start..<(start + 4)]))
        }
    }

    private func pixels(of image: CGImage) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        try bytes.withUnsafeMutableBytes { buffer in
            let context = try #require(CGContext(data: buffer.baseAddress, width: image.width, height: image.height,
                                               bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                               space: CGColorSpaceCreateDeviceRGB(),
                                               bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: CGFloat(image.width), height: CGFloat(image.height)))
        }
        return bytes
    }
    #endif

    @Test func tmdbPicturesAtOriginalOrW1280BecomeW780ForTheMac() throws {
        let original = try #require(URL(string: "https://image.tmdb.org/t/p/original/abc.jpg"))
        #expect(PosterQuality.smallerLandscape(original)?.absoluteString == "https://image.tmdb.org/t/p/w780/abc.jpg")
        let large = try #require(URL(string: "https://image.tmdb.org/t/p/w1280/abc.jpg"))
        #expect(PosterQuality.smallerLandscape(large)?.absoluteString == "https://image.tmdb.org/t/p/w780/abc.jpg")
    }

    @Test func otherPicturesAreReturnedAsTheyCame() throws {
        let metahub = try #require(URL(string: "https://images.metahub.space/background/large/tt0944947/img"))
        #expect(PosterQuality.smallerLandscape(metahub) == metahub)
        #expect(PosterQuality.smallerLandscape(nil) == nil)
    }

    @Test func iPhoneAndTheTestHostKeepTheirPictures() throws {
        // Only the Mac's build shrinks them, so the test host (not Catalyst) keeps the picture as it came.
        let original = try #require(URL(string: "https://image.tmdb.org/t/p/original/abc.jpg"))
        #expect(PosterQuality.landscape(original) == original)
    }
}
