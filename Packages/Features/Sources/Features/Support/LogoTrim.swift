import CoreGraphics

/// Finds the visible part of a title logo. Logo files carry different amounts of transparent padding, which would make the gap between
/// a logo and the text under it differ from title to title; the loader crops each logo to this box so the logo itself sets its size.
enum LogoTrim {
    /// Alpha (of 255) at or below which a pixel counts as empty.
    static let alphaThreshold: UInt8 = 10
    /// Alpha above which a pixel is part of the logo's solid lettering, not a glow or haze around it.
    static let solidThreshold: UInt8 = 230

    /// The bounding box, in pixels from the top left, of the pixels whose alpha is above the threshold. Nil when nothing is visible, the
    /// image cannot be read, or the whole image is visible (nothing to trim).
    static func visibleBounds(of image: CGImage, threshold: UInt8 = alphaThreshold) -> CGRect? {
        guard let box = alphaBounds(of: image, thresholds: [threshold]).first ?? nil else { return nil }
        return box.width == CGFloat(image.width) && box.height == CGFloat(image.height) ? nil : box
    }

    /// The horizontal span, in pixels, the logo is laid out by: the visible box widened with transparent space on its shorter side, so
    /// the solid lettering sits at its centre. A haze trailing further to one side (Project Hail Mary) would otherwise pull the
    /// lettering off the centre line. Nil leaves the visible box as it is.
    static func centredSpan(visible: CGRect, solid: CGRect?) -> (minX: CGFloat, width: CGFloat)? {
        guard let solid, solid.width > 0 else { return nil }
        let centre = solid.midX
        let half = max(centre - visible.minX, visible.maxX - centre)
        let span = (minX: centre - half, width: half * 2)
        // A difference under a pixel or two is not worth a redraw.
        return abs(span.width - visible.width) < 2 ? nil : span
    }

    /// The image cropped to its visible pixels with its solid lettering centred, or the image itself when there is nothing to change.
    static func trimmed(_ image: CGImage) -> CGImage {
        let boxes = alphaBounds(of: image, thresholds: [alphaThreshold, solidThreshold])
        guard let visible = boxes[0] else { return image }
        guard let span = centredSpan(visible: visible, solid: boxes[1]) else {
            let isWhole = visible.width == CGFloat(image.width) && visible.height == CGFloat(image.height)
            return isWhole ? image : (image.cropping(to: visible) ?? image)
        }
        // Draw the visible box into a wider transparent canvas, offset so the lettering's centre is the canvas's centre.
        let width = Int(span.width.rounded(.up))
        let height = Int(visible.height)
        guard let cropped = image.cropping(to: visible),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return image.cropping(to: visible) ?? image }
        context.draw(cropped, in: CGRect(x: visible.minX - span.minX, y: 0, width: visible.width, height: visible.height))
        return context.makeImage() ?? cropped
    }

    /// For each threshold, the bounding box (from the top left) of the pixels whose alpha is above it; nil when none are.
    private static func alphaBounds(of image: CGImage, thresholds: [UInt8]) -> [CGRect?] {
        let width = image.width
        let height = image.height
        let none = [CGRect?](repeating: nil, count: thresholds.count)
        guard width > 0, height > 0 else { return none }
        var pixels = [UInt8](repeating: 0, count: width * height)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                                          space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return none }
        // One pass over the pixels grows every threshold's box at once.
        let count = thresholds.count
        var minX = [Int](repeating: width, count: count), maxX = [Int](repeating: -1, count: count)
        var minY = [Int](repeating: height, count: count), maxY = [Int](repeating: -1, count: count)
        let lowest = thresholds.min() ?? 0
        for y in 0..<height {
            let row = y * width
            for x in 0..<width {
                let alpha = pixels[row + x]
                guard alpha > lowest else { continue }
                for i in 0..<count where alpha > thresholds[i] {
                    if x < minX[i] { minX[i] = x }
                    if x > maxX[i] { maxX[i] = x }
                    if y < minY[i] { minY[i] = y }
                    maxY[i] = y
                }
            }
        }
        return (0..<count).map { i in
            guard maxX[i] >= minX[i], maxY[i] >= minY[i] else { return nil }
            return CGRect(x: minX[i], y: minY[i], width: maxX[i] - minX[i] + 1, height: maxY[i] - minY[i] + 1)
        }
    }
}
