// Makes the Mac icon from the iPhone icon, so the Mac app shows the same artwork.
//
// macOS does not mask app icons the way iOS does, so the artwork is shaped here instead: the iPhone icon is scaled to 824/1024
// of a transparent 1024 canvas, clipped to a continuous-corner shape (a superellipse, which matches a 22.37% corner radius at
// the diagonal), and given a soft drop shadow like Apple's macOS icon template. Each size is then drawn from the 1024 source
// with high-quality resampling.
//
// Rerun after changing AppIcon-1024.png:
//
//     swift scripts/make-mac-icon.swift
//
// Writes ten PNGs next to the iPhone icon in App/Assets.xcassets/AppIcon.appiconset/, named AppIcon-mac-<points>[@2x].png.
// Contents.json is not touched: it already lists these files as idiom "mac" entries.

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Points at 1x and 2x for each macOS icon slot, with the output pixel size.
let slots: [(file: String, pixels: Int)] = [
    ("AppIcon-mac-16.png", 16), ("AppIcon-mac-16@2x.png", 32),
    ("AppIcon-mac-32.png", 32), ("AppIcon-mac-32@2x.png", 64),
    ("AppIcon-mac-128.png", 128), ("AppIcon-mac-128@2x.png", 256),
    ("AppIcon-mac-256.png", 256), ("AppIcon-mac-256@2x.png", 512),
    ("AppIcon-mac-512.png", 512), ("AppIcon-mac-512@2x.png", 1024),
]

/// Geometry on the 1024 canvas, from Apple's macOS icon template.
let canvasSide = 1024.0
let bodySide = 824.0
let shadowDrop = 12.0
let shadowBlur = 24.0
let shadowAlpha = 0.3
/// Exponent of the superellipse that stands in for Apple's continuous corners.
let cornerExponent = 5.0

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

let scriptURL = URL(fileURLWithPath: #filePath)
let iconSetURL = scriptURL
    .deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("App/Assets.xcassets/AppIcon.appiconset", isDirectory: true)
let sourceURL = iconSetURL.appendingPathComponent("AppIcon-1024.png")

guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
      let artwork = CGImageSourceCreateImageAtIndex(source, 0, nil)
else { fail("Cannot read \(sourceURL.path)") }

/// The continuous-corner outline of a square, centred at `center` with half-side `half`.
func squircle(center: CGPoint, half: CGFloat) -> CGPath {
    let path = CGMutablePath()
    let steps = 720
    let exponent = 2 / cornerExponent
    for step in 0...steps {
        let angle = Double(step) / Double(steps) * 2 * .pi
        let cosine = cos(angle), sine = sin(angle)
        let x = center.x + half * CGFloat(copysign(pow(abs(cosine), exponent), cosine))
        let y = center.y + half * CGFloat(copysign(pow(abs(sine), exponent), sine))
        if step == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
    }
    path.closeSubpath()
    return path
}

/// One icon at `pixels` square: the shaped artwork with its shadow on a transparent background.
func renderIcon(pixels: Int) -> CGImage {
    let scale = CGFloat(pixels) / canvasSide
    guard let context = CGContext(
        data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { fail("Cannot create a \(pixels) px context") }

    let body = CGRect(x: (canvasSide - bodySide) / 2 * scale, y: (canvasSide - bodySide) / 2 * scale,
                      width: bodySide * scale, height: bodySide * scale)
    let shape = squircle(center: CGPoint(x: body.midX, y: body.midY), half: body.width / 2)

    context.interpolationQuality = .high
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -shadowDrop * scale), blur: shadowBlur * scale,
                      color: CGColor(gray: 0, alpha: shadowAlpha))
    context.addPath(shape)
    context.setFillColor(CGColor(gray: 0, alpha: 1))
    context.fillPath()
    context.restoreGState()

    context.saveGState()
    context.addPath(shape)
    context.clip()
    context.draw(artwork, in: body)
    context.restoreGState()

    guard let image = context.makeImage() else { fail("Cannot render \(pixels) px") }
    return image
}

for slot in slots {
    let image = renderIcon(pixels: slot.pixels)
    let url = iconSetURL.appendingPathComponent(slot.file)
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        fail("Cannot write \(url.path)")
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { fail("Cannot write \(url.path)") }
    print("\(slot.file) \(slot.pixels) px")
}
