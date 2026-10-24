import CoreGraphics
import Foundation
import Testing
@testable import Features

@Suite struct PlayColourTests {
    private func pixels(_ count: Int, red: Double, green: Double, blue: Double, alpha: Double = 1) -> [PlayColour.Pixel] {
        Array(repeating: PlayColour.Pixel(red: red, green: green, blue: blue, alpha: alpha), count: count)
    }

    /// The colour's hue in degrees, as OKLab measures it.
    private func hue(_ colour: PlayColour.HSB) -> Double {
        let rgb = PlayColour.rgb(colour)
        return PlayColour.Lab(red: rgb.red, green: rgb.green, blue: rgb.blue).hue
    }

    private func hueDistance(_ first: Double, _ second: Double) -> Double {
        let distance = abs(first - second).truncatingRemainder(dividingBy: 360)
        return min(distance, 360 - distance)
    }

    private func contrastWithWhite(_ colour: PlayColour.HSB) -> Double {
        1.05 / (PlayColour.relativeLuminance(PlayColour.rgb(colour)) + 0.05)
    }

    /// A poster of `width` by `height` filled with `background`, with a `subject` block in the middle, its pixels alternating with a darker
    /// shade of it so it has the detail a drawn figure has.
    private func poster(width: Int = PlayColour.sampleWidth, height: Int = PlayColour.sampleHeight,
                        background: (Double, Double, Double), subject: (Double, Double, Double), subjectShare: Double) -> [PlayColour.Pixel] {
        let subjectWidth = Int(Double(width) * subjectShare.squareRoot())
        let subjectHeight = Int(Double(height) * subjectShare.squareRoot())
        let left = (width - subjectWidth) / 2
        let top = (height - subjectHeight) / 2
        return (0..<(width * height)).map { index in
            let x = index % width
            let y = index / width
            if (left..<left + subjectWidth).contains(x), (top..<top + subjectHeight).contains(y) {
                let shade = (x + y).isMultiple(of: 3) ? 0.7 : 1
                return PlayColour.Pixel(red: subject.0 * shade, green: subject.1 * shade, blue: subject.2 * shade, alpha: 1)
            }
            return PlayColour.Pixel(red: background.0, green: background.1, blue: background.2, alpha: 1)
        }
    }

    @Test func aMonochromePosterHasNoColour() {
        #expect(PlayColour.pick(from: pixels(864, red: 0.5, green: 0.5, blue: 0.5)) == nil, "grey never becomes the button's colour")
        #expect(PlayColour.pick(from: pixels(864, red: 0.97, green: 0.97, blue: 0.96)) == nil, "nor does white")
        #expect(PlayColour.pick(from: pixels(864, red: 0.04, green: 0.02, blue: 0.02)) == nil, "nor black")
    }

    @Test func tooFewColouredPixelsAreNotEnoughForAColour() {
        let poster = pixels(854, red: 0.5, green: 0.5, blue: 0.5) + pixels(9, red: 0.9, green: 0.1, blue: 0.1)
        #expect(PlayColour.pick(from: poster) == nil)
    }

    @Test func theHeaviestHueIsTheColour() throws {
        let poster = pixels(300, red: 0.9, green: 0.1, blue: 0.1) + pixels(200, red: 0.1, green: 0.8, blue: 0.2)
        let colour = try #require(PlayColour.pick(from: poster))
        #expect(hueDistance(hue(colour), PlayColour.Lab(red: 0.9, green: 0.1, blue: 0.1).hue) < 12, "red has more of the poster than green")
    }

    /// The Simpsons' yellow is so bright that the old pick left it out as "too bright to tell its hue", and its blue sky won.
    @Test func aBrightSaturatedColourCounts() throws {
        let colour = try #require(PlayColour.pick(from: pixels(864, red: 0.996, green: 0.851, blue: 0.059)))
        let yellow = PlayColour.Lab(red: 0.996, green: 0.851, blue: 0.059).hue
        #expect(hueDistance(hue(colour), yellow) <= 12, "still a yellow, turned at most a little towards gold")
    }

    /// The poster's most common colour is the button's, wherever it is: a blue sky that covers most of the poster wins over a smaller
    /// yellow family in front of it, as asked.
    @Test func theMostCommonColourWins() throws {
        let sky = (0.25, 0.62, 0.92)
        let family = (0.996, 0.851, 0.059)
        let colour = try #require(PlayColour.pick(from: poster(background: sky, subject: family, subjectShare: 0.3)))
        #expect(hueDistance(hue(colour), PlayColour.Lab(red: sky.0, green: sky.1, blue: sky.2).hue) <= 5, "the sky has most of the poster")
    }

    @Test func ofTwoColoursWithNearlyTheSameShareTheMoreVividOneWins() throws {
        let dull = (0.55, 0.45, 0.35)
        let vivid = (0.1, 0.35, 0.95)
        let poster = pixels(52, red: dull.0, green: dull.1, blue: dull.2) + pixels(48, red: vivid.0, green: vivid.1, blue: vivid.2)
        let colour = try #require(PlayColour.pick(from: poster))
        #expect(hueDistance(hue(colour), PlayColour.Lab(red: vivid.0, green: vivid.1, blue: vivid.2).hue) <= 5)
    }

    /// Barbie's pink fills the poster to its edges and there is nothing else: it is still the colour.
    @Test func aColourThatFillsThePosterIsStillItsColour() throws {
        let pink = (0.93, 0.36, 0.67)
        let colour = try #require(PlayColour.pick(from: pixels(PlayColour.sampleWidth * PlayColour.sampleHeight, red: pink.0, green: pink.1, blue: pink.2)))
        #expect(hueDistance(hue(colour), PlayColour.Lab(red: pink.0, green: pink.1, blue: pink.2).hue) < 5)
    }

    /// Whatever the colour, a white label reads on it (3:1), its hue stays within 10 degrees, and it is neither grey nor neon.
    @Test(arguments: [(0.996, 0.851, 0.059), (0.93, 0.36, 0.67), (0.2, 0.8, 0.2), (0.9, 0.1, 0.1), (0.1, 0.3, 0.9), (0.95, 0.55, 0.1),
                      (0.3, 0.9, 0.95), (0.55, 0.2, 0.8), (0.35, 0.25, 0.15), (0.12, 0.2, 0.45)])
    func everyColourKeepsItsHueAndAReadableLabel(red: Double, green: Double, blue: Double) throws {
        let colour = try #require(PlayColour.pick(from: pixels(864, red: red, green: green, blue: blue)))
        let source = PlayColour.Lab(red: red, green: green, blue: blue)
        #expect(contrastWithWhite(colour) >= PlayColour.minimumLabelContrast - 0.02)
        #expect(hueDistance(hue(colour), source.hue) <= 10.5)
        let rgb = PlayColour.rgb(colour)
        let button = PlayColour.Lab(red: rgb.red, green: rgb.green, blue: rgb.blue)
        #expect(button.chroma >= PlayColour.chromaRange.lowerBound - 0.02, "it reads as a colour")
        #expect(button.chroma <= PlayColour.chromaRange.upperBound + 0.005, "never neon")
        #expect(button.lightness >= PlayColour.minimumLightnessOfButton - 0.005, "never black")
    }

    @Test func aColourThatAlreadyReadsKeepsItsLightness() throws {
        // A deep blue already reads under a white label: nothing is darkened.
        let colour = try #require(PlayColour.pick(from: pixels(864, red: 0.12, green: 0.25, blue: 0.6)))
        let rgb = PlayColour.rgb(colour)
        let source = PlayColour.Lab(red: 0.12, green: 0.25, blue: 0.6)
        #expect(abs(PlayColour.Lab(red: rgb.red, green: rgb.green, blue: rgb.blue).lightness - source.lightness) < 0.02)
    }

    /// A logo is mostly see-through: its colour is read from its letters alone, however little of the picture they cover.
    @Test func aLogoIsReadFromItsOpaquePixels() throws {
        let logo = pixels(2_800, red: 0, green: 0, blue: 0, alpha: 0) + pixels(272, red: 0.85, green: 0.12, blue: 0.1)
        let colour = try #require(PlayColour.mostCommonColour(in: logo))
        #expect(hueDistance(colour.hue, PlayColour.Lab(red: 0.85, green: 0.12, blue: 0.1).hue) < 5)
        #expect(!PlayColour.isDull(colour))
    }

    /// A poster whose most common colour is barely a colour, or nearly white, is dull: the title's logo is tried for its colour then.
    @Test func aBarelyColouredOrNearlyWhiteColourIsDull() throws {
        let beige = try #require(PlayColour.mostCommonColour(in: pixels(864, red: 0.66, green: 0.58, blue: 0.47)))
        #expect(PlayColour.isDull(beige), "barely coloured")
        let paleYellow = try #require(PlayColour.mostCommonColour(in: pixels(864, red: 1, green: 0.97, blue: 0.82)))
        #expect(PlayColour.isDull(paleYellow), "nearly white")
        let red = try #require(PlayColour.mostCommonColour(in: pixels(864, red: 0.85, green: 0.12, blue: 0.1)))
        #expect(!PlayColour.isDull(red))
    }

    @Test func transparentPixelsAreIgnored() {
        #expect(PlayColour.pick(from: pixels(864, red: 0.1, green: 0.3, blue: 0.9, alpha: 0)) == nil)
    }

    @Test func hsbRoundTripsThroughRGB() {
        let pixel = PlayColour.Pixel(red: 0.2, green: 0.5, blue: 0.8, alpha: 1)
        let back = PlayColour.rgb(PlayColour.HSB(pixel))
        #expect(abs(back.red - 0.2) < 0.0001)
        #expect(abs(back.green - 0.5) < 0.0001)
        #expect(abs(back.blue - 0.8) < 0.0001)
    }

    @Test func okLabRoundTripsThroughRGB() {
        let lab = PlayColour.Lab(red: 0.9, green: 0.4, blue: 0.1)
        let back = lab.rgb
        #expect(abs(back.red - 0.9) < 0.001)
        #expect(abs(back.green - 0.4) < 0.001)
        #expect(abs(back.blue - 0.1) < 0.001)
    }

    @Test func aPictureIsSampledAtTheSampleSizeAndReadsItsColour() throws {
        let context = try #require(CGContext(data: nil, width: 10, height: 10, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(red: 0.9, green: 0.1, blue: 0.1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 10, height: 10))
        let picture = try #require(context.makeImage())
        let sample = try #require(PlayColour.pixels(of: picture))
        #expect(sample.count == PlayColour.sampleWidth * PlayColour.sampleHeight)
        let colour = try #require(PlayColour.pick(from: sample))
        #expect(hueDistance(hue(colour), PlayColour.Lab(red: 0.9, green: 0.1, blue: 0.1).hue) < 6, "a red picture gives a red button")
    }
}
