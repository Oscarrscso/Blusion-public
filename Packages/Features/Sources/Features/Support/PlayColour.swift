import CoreGraphics
import Foundation

/// The colour a title's Play button takes from its poster: the poster's most common colour, kept as close to it as a white label allows.
/// Pure arithmetic over a small sample of the picture, so it runs off the main thread and can be tested without a picture.
///
/// The poster's colours are read in OKLab, where distances and lightness follow what the eye sees. Greys, whites and blacks have no
/// colour and are left out; the coloured pixels are grouped by hue, and the hue with the most of them is the poster's colour (of two
/// within 10% of each other, the more vivid). The chosen hue keeps its chroma; only its lightness comes down, as far as a white label
/// needs to read on it (3:1, the contrast for large bold text). A yellow darkened that far turns a little towards gold, not olive.
enum PlayColour {
    /// One sampled pixel, each channel from 0 to 1, not premultiplied.
    struct Pixel: Equatable {
        var red: Double
        var green: Double
        var blue: Double
        var alpha: Double
    }

    /// A colour in HSB, each component from 0 to 1.
    struct HSB: Equatable {
        var hue: Double
        var saturation: Double
        var brightness: Double
    }

    /// A colour in OKLab: `lightness` from 0 to 1, `a` and `b` its green–red and blue–yellow axes.
    struct Lab: Equatable {
        var lightness: Double
        var a: Double
        var b: Double

        var chroma: Double { (a * a + b * b).squareRoot() }
        /// The hue in degrees, 0 to 360.
        var hue: Double {
            let degrees = atan2(b, a) * 180 / .pi
            return degrees < 0 ? degrees + 360 : degrees
        }
    }

    /// The poster is sampled at this size: enough to tell the subject from the background, cheap to read.
    static let sampleWidth = 48
    static let sampleHeight = 72
    /// A pixel counts as a colour when its chroma is at least this, and it is not near black: greys, whites and blacks have no hue.
    static let minimumChroma = 0.04
    static let minimumLightness = 0.15
    /// Fewer coloured pixels than this share of the poster (and never fewer than ten) and the poster is monochrome: no colour, so the
    /// button keeps its own style.
    static let minimumColouredShare = 0.012
    /// The hues are grouped in bins this many degrees wide.
    static let hueBinWidth = 10.0
    /// Colours whose shares of the poster are this close (10%) count as equal, and the more vivid one is taken.
    static let nearlyEqualShare = 0.10
    /// A picture's colour below this chroma, or above this lightness, is dull (see `isDull`).
    static let dullChroma = 0.05
    static let nearWhiteLightness = 0.9
    /// A logo is wide and short: it is sampled at this size, so its letters keep their shape.
    static let logoSampleWidth = 96
    static let logoSampleHeight = 32
    /// The button's chroma, however vivid or dull the poster: enough to read as a colour, never neon.
    static let chromaRange = 0.08...0.20
    /// The button's lightness: never so dark it reads as black, and never so light that a white label stops reading (see
    /// `minimumLabelContrast`).
    static let minimumLightnessOfButton = 0.42
    /// The contrast a white label keeps on the button: 3:1, enough for large bold text.
    static let minimumLabelContrast = 3.0

    /// The button's colour for the pixels of a poster, or nil when the poster has no colour: its most common colour, made readable under
    /// the label.
    static func pick(from pixels: [Pixel]) -> HSB? {
        guard let colour = mostCommonColour(in: pixels) else { return nil }
        let button = buttonColour(for: colour)
        return HSB(red: button.red, green: button.green, blue: button.blue)
    }

    /// The picture's most common colour, as it is in the picture, or nil when it has none. Every coloured pixel counts the same, wherever
    /// it is; see-through pixels (a logo's) are left out.
    static func mostCommonColour(in pixels: [Pixel]) -> Lab? {
        let labs = pixels.map { Lab(red: $0.red, green: $0.green, blue: $0.blue) }
        let opaque = pixels.filter { $0.alpha >= 0.5 }.count
        let coloured = pixels.indices.filter { pixels[$0].alpha >= 0.5 && isColoured(labs[$0]) }
        guard coloured.count >= max(10, Int(Double(opaque) * minimumColouredShare)) else { return nil }
        var bins = [(count: Double, chromaSum: Double)](repeating: (0, 0), count: Int(360 / hueBinWidth))
        for index in coloured {
            let bin = min(bins.count - 1, Int(labs[index].hue / hueBinWidth))
            bins[bin].count += 1
            bins[bin].chromaSum += labs[index].chroma
        }
        // A hue's share of the poster is its bin's and its two neighbours', so a colour that straddles a bin edge is not split in two.
        let areas = bins.indices.map { index -> (area: Double, chroma: Double) in
            let neighbours = [bins[(index + bins.count - 1) % bins.count], bins[index], bins[(index + 1) % bins.count]]
            let count = neighbours.reduce(0) { $0 + $1.count }
            guard count > 0, bins[index].count > 0 else { return (0, 0) }
            return (count, neighbours.reduce(0) { $0 + $1.chromaSum } / count)
        }
        guard let largest = areas.indices.max(by: { areas[$0].area < areas[$1].area }), areas[largest].area > 0 else { return nil }
        // Two colours within 10% of each other's share: the more vivid one is the poster's colour.
        let winner = areas.indices
            .filter { areas[$0].area >= areas[largest].area * (1 - nearlyEqualShare) }
            .max(by: { areas[$0].chroma < areas[$1].chroma }) ?? largest
        let centre = (Double(winner) + 0.5) * hueBinWidth
        // The colour is the mean of the coloured pixels within 15 degrees of that hue.
        var sum = (lightness: 0.0, a: 0.0, b: 0.0, count: 0.0)
        for index in coloured {
            let distance = abs(labs[index].hue - centre)
            guard min(distance, 360 - distance) <= 15 else { continue }
            sum.lightness += labs[index].lightness
            sum.a += labs[index].a
            sum.b += labs[index].b
            sum.count += 1
        }
        guard sum.count > 0 else { return nil }
        return Lab(lightness: sum.lightness / sum.count, a: sum.a / sum.count, b: sum.b / sum.count)
    }

    /// Whether a picture's colour would make a dull button: barely coloured, or so light it is nearly white. The title's logo is tried then.
    static func isDull(_ colour: Lab) -> Bool {
        colour.chroma < dullChroma || colour.lightness > nearWhiteLightness
    }

    /// Whether a pixel has a hue: chroma enough, and not near black.
    static func isColoured(_ lab: Lab) -> Bool {
        lab.chroma >= minimumChroma && lab.lightness >= minimumLightness
    }

    /// The button's colour for the poster's colour: the same hue, its chroma kept between `chromaRange`, and its lightness brought down
    /// only as far as a white label needs. A yellow brought down a long way turns a little towards orange, so it reads as gold rather
    /// than olive. Returns sRGB components from 0 to 1.
    static func buttonColour(for poster: Lab) -> (red: Double, green: Double, blue: Double) {
        let chroma = min(max(poster.chroma, chromaRange.lowerBound), chromaRange.upperBound)
        var lightness = max(poster.lightness, minimumLightnessOfButton)
        var hue = poster.hue
        if contrastWithWhite(lightness: lightness, chroma: chroma, hue: hue) < minimumLabelContrast {
            // The lightest the colour can be with the label's contrast, found by halving.
            func lightest(at hue: Double) -> Double {
                var low = minimumLightnessOfButton
                var high = lightness
                for _ in 0..<24 {
                    let middle = (low + high) / 2
                    if contrastWithWhite(lightness: middle, chroma: chroma, hue: hue) >= minimumLabelContrast { low = middle } else { high = middle }
                }
                return low
            }
            var darker = lightest(at: hue)
            if (85...115).contains(hue) {
                // Turned towards gold by how far it comes down, then measured again at its new hue.
                hue -= 10 * min(1, (lightness - darker) / 0.2)
                darker = lightest(at: hue)
            }
            lightness = darker
        }
        return inGamut(Lab(lightness: lightness, a: chroma * cos(hue * .pi / 180), b: chroma * sin(hue * .pi / 180)))
    }

    /// The contrast of a white label on this colour, as WCAG measures it.
    static func contrastWithWhite(lightness: Double, chroma: Double, hue: Double) -> Double {
        let rgb = inGamut(Lab(lightness: lightness, a: chroma * cos(hue * .pi / 180), b: chroma * sin(hue * .pi / 180)))
        return 1.05 / (relativeLuminance(rgb) + 0.05)
    }

    static func relativeLuminance(_ rgb: (red: Double, green: Double, blue: Double)) -> Double {
        0.2126 * linear(rgb.red) + 0.7152 * linear(rgb.green) + 0.0722 * linear(rgb.blue)
    }

    /// The colour in sRGB, with its chroma reduced (hue and lightness kept) until it fits.
    static func inGamut(_ lab: Lab) -> (red: Double, green: Double, blue: Double) {
        var colour = lab
        for _ in 0..<40 {
            let rgb = colour.rgb
            if [rgb.red, rgb.green, rgb.blue].allSatisfy({ (-0.0005...1.0005).contains($0) }) {
                return (min(max(rgb.red, 0), 1), min(max(rgb.green, 0), 1), min(max(rgb.blue, 0), 1))
            }
            colour.a *= 0.95
            colour.b *= 0.95
        }
        let rgb = colour.rgb
        return (min(max(rgb.red, 0), 1), min(max(rgb.green, 0), 1), min(max(rgb.blue, 0), 1))
    }

    static func linear(_ channel: Double) -> Double {
        channel <= 0.04045 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
    }

    static func gamma(_ channel: Double) -> Double {
        channel <= 0.0031308 ? channel * 12.92 : 1.055 * pow(max(channel, 0), 1 / 2.4) - 0.055
    }

    /// The pixels of a picture drawn at the sample size (a poster's, unless given), row by row, not premultiplied. Nil when the sample
    /// cannot be drawn.
    static func pixels(of image: CGImage, width: Int = sampleWidth, height: Int = sampleHeight) -> [Pixel]? {
        var raw = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = raw.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        return stride(from: 0, to: raw.count, by: 4).map { index in
            let alpha = Double(raw[index + 3]) / 255
            guard alpha > 0 else { return Pixel(red: 0, green: 0, blue: 0, alpha: 0) }
            return Pixel(red: min(Double(raw[index]) / 255 / alpha, 1), green: min(Double(raw[index + 1]) / 255 / alpha, 1),
                         blue: min(Double(raw[index + 2]) / 255 / alpha, 1), alpha: alpha)
        }
    }

    /// The colour as sRGB components from 0 to 1.
    static func rgb(_ colour: HSB) -> (red: Double, green: Double, blue: Double) {
        let sector = (colour.hue - floor(colour.hue)) * 6
        let chroma = colour.brightness * colour.saturation
        let secondary = chroma * (1 - abs(sector.truncatingRemainder(dividingBy: 2) - 1))
        let offset = colour.brightness - chroma
        let (red, green, blue): (Double, Double, Double)
        switch Int(sector) % 6 {
        case 0: (red, green, blue) = (chroma, secondary, 0)
        case 1: (red, green, blue) = (secondary, chroma, 0)
        case 2: (red, green, blue) = (0, chroma, secondary)
        case 3: (red, green, blue) = (0, secondary, chroma)
        case 4: (red, green, blue) = (secondary, 0, chroma)
        default: (red, green, blue) = (chroma, 0, secondary)
        }
        return (red + offset, green + offset, blue + offset)
    }
}

extension PlayColour.Lab {
    /// OKLab from sRGB components from 0 to 1 (Björn Ottosson's matrices).
    init(red: Double, green: Double, blue: Double) {
        let r = PlayColour.linear(red), g = PlayColour.linear(green), b = PlayColour.linear(blue)
        let l = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
        let m = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
        let s = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
        self.init(lightness: 0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
                  a: 1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
                  b: 0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s)
    }

    /// sRGB components, which may fall outside 0 to 1 for a colour sRGB cannot show.
    var rgb: (red: Double, green: Double, blue: Double) {
        let l = pow(lightness + 0.3963377774 * a + 0.2158037573 * b, 3)
        let m = pow(lightness - 0.1055613458 * a - 0.0638541728 * b, 3)
        let s = pow(lightness - 0.0894841775 * a - 1.2914855480 * b, 3)
        let red = 4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s
        let green = -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s
        let blue = -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s
        return (PlayColour.gamma(red), PlayColour.gamma(green), PlayColour.gamma(blue))
    }
}

extension PlayColour.HSB {
    init(_ pixel: PlayColour.Pixel) {
        self.init(red: pixel.red, green: pixel.green, blue: pixel.blue)
    }

    init(red: Double, green: Double, blue: Double) {
        let high = max(red, green, blue)
        let range = high - min(red, green, blue)
        brightness = high
        saturation = high == 0 ? 0 : range / high
        if range == 0 {
            hue = 0
        } else if high == red {
            var sector = (green - blue) / range
            if sector < 0 { sector += 6 }
            hue = sector / 6
        } else if high == green {
            hue = ((blue - red) / range + 2) / 6
        } else {
            hue = ((red - green) / range + 4) / 6
        }
    }
}
