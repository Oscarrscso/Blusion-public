import CoreGraphics

/// Makes a dark title logo readable. A hero's logo sits on the black end of the picture's fade, so one drawn in black or near-black
/// (Disclosure Day) cannot be read there. Such a logo has its lightness turned over: black lettering becomes white, a light detail inside it
/// becomes dark, and a colour keeps its hue. A logo that is not mostly dark is left exactly as it is.
enum LogoLegibility {
    /// A pixel whose brightest channel is at or below this (of 255) is dark: black or close to it. A deep red or blue is not, since one of
    /// its channels is well above it, so a logo in a dark colour keeps that colour.
    static let darkThreshold = 64
    /// The share (of 100) of a logo's visible pixels, weighted by how opaque each is, that must be dark before the logo is changed.
    static let darkPercent = 80

    /// The logo with its lightness turned over when it is mostly dark, or the image itself when it is not, or cannot be read.
    static func legible(_ image: CGImage) -> CGImage {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return image }
        context.clear(CGRect(x: 0, y: 0, width: width, height: height))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let data = context.data else { return image }
        // The context's own rows may be wider than the picture, so pixels are reached a row at a time.
        let rowBytes = context.bytesPerRow
        let pixels = UnsafeMutableBufferPointer(start: data.assumingMemoryBound(to: UInt8.self), count: rowBytes * height)
        let rows = (0..<height).map { $0 * rowBytes }
        guard isMostlyDark(pixels, rows: rows, width: width) else { return image }
        turnLightnessOver(pixels, rows: rows, width: width)
        return context.makeImage() ?? image
    }

    /// Whether the dark pixels carry at least `darkPercent` of the logo's opacity. The pixels are RGBA with the colour multiplied by alpha.
    private static func isMostlyDark(_ pixels: UnsafeMutableBufferPointer<UInt8>, rows: [Int], width: Int) -> Bool {
        var visible = 0
        var dark = 0
        for row in rows {
            for offset in stride(from: row, to: row + width * 4, by: 4) {
                let alpha = Int(pixels[offset + 3])
                guard alpha > Int(LogoTrim.alphaThreshold) else { continue }
                visible += alpha
                // The colour is multiplied by alpha, so the threshold is too, rather than dividing every pixel.
                let brightest = Int(max(pixels[offset], pixels[offset + 1], pixels[offset + 2]))
                if brightest * 255 <= darkThreshold * alpha { dark += alpha }
            }
        }
        return visible > 0 && dark * 100 >= visible * darkPercent
    }

    /// Turns each pixel's lightness over and keeps its hue and its alpha: every channel moves by the same amount, so the brightest
    /// channel ends as far from white as the darkest was from black.
    private static func turnLightnessOver(_ pixels: UnsafeMutableBufferPointer<UInt8>, rows: [Int], width: Int) {
        for row in rows {
            for offset in stride(from: row, to: row + width * 4, by: 4) {
                let alpha = Int(pixels[offset + 3])
                guard alpha > 0 else { continue }
                let red = Int(pixels[offset]), green = Int(pixels[offset + 1]), blue = Int(pixels[offset + 2])
                // In multiplied terms white is `alpha`, so the shift is what is left of it after the brightest and darkest channels.
                let shift = alpha - max(red, green, blue) - min(red, green, blue)
                pixels[offset] = UInt8(clamping: red + shift)
                pixels[offset + 1] = UInt8(clamping: green + shift)
                pixels[offset + 2] = UInt8(clamping: blue + shift)
            }
        }
    }
}
