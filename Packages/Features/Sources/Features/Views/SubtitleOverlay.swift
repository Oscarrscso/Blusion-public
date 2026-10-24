#if canImport(UIKit)
import PlayerKit
import StremioKit
import SwiftUI
import UIKit

/// The app's own subtitle drawing (for engines that do not draw subtitle files): styled text cues placed by their alignment or position,
/// and PGS pictures placed in the video frame. The viewer's `SubtitleStyle` sets the size, colour, background and height.
struct SubtitleOverlay: View {
    let cues: [SubtitleCue]
    let bitmap: BitmapSubtitleCue?
    let style: SubtitleStyle
    let controlsVisible: Bool

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                if let bitmap { BitmapSubtitleView(cue: bitmap, size: proxy.size) }
                let placed = cues.filter { $0.position != nil }
                let rows = Dictionary(grouping: cues.filter { $0.position == nil }, by: \.row)
                ForEach(Row.allCases, id: \.self) { row in
                    if let lines = rows[row] { block(lines, row: row, in: proxy.size) }
                }
                ForEach(Array(placed.enumerated()), id: \.offset) { _, cue in
                    if let point = cue.position {
                        line(cue, height: proxy.size.height)
                            .frame(maxWidth: proxy.size.width * 0.9)
                            .position(x: point.x * proxy.size.width, y: point.y * proxy.size.height)
                    }
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("player.subtitle")
    }

    enum Row: CaseIterable { case top, middle, bottom }

    private func block(_ lines: [SubtitleCue], row: Row, in size: CGSize) -> some View {
        let lift = size.height * style.bottomMargin / 100 + (controlsVisible ? 100 : 0)
        return VStack(spacing: 2) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, cue in line(cue, height: size.height) }
        }
        .frame(maxWidth: size.width * 0.86)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: row == .top ? .top : row == .middle ? .center : .bottom)
        .padding(.top, row == .top ? max(24, size.height * 0.04) + (controlsVisible ? 80 : 0) : 0)
        .padding(.bottom, row == .bottom ? max(16, lift) : 0)
    }

    private func line(_ cue: SubtitleCue, height: CGFloat) -> some View {
        let size = min(72, max(15, height * 0.052 * style.scale * min(2, max(0.5, cue.fontScale))))
        return Text(attributed(cue))
            .font(.system(size: size, weight: .semibold))
            .multilineTextAlignment(cue.alignment.textAlignment)
            .padding(.horizontal, style.background == .box ? 8 : 0)
            .padding(.vertical, style.background == .box ? 2 : 0)
            .background {
                if style.background == .box { RoundedRectangle(cornerRadius: 4).fill(.black.opacity(0.6)) }
            }
            .shadow(color: style.background == .outline ? .black : .clear, radius: 1.5, x: 0, y: 0)
            .shadow(color: style.background == .outline ? .black.opacity(0.8) : .clear, radius: 3, x: 0, y: 1)
            .frame(maxWidth: .infinity, alignment: cue.alignment.frameAlignment)
    }

    private func attributed(_ cue: SubtitleCue) -> AttributedString {
        let base = style.colour.rgb
        var result = AttributedString()
        for span in cue.spans {
            var piece = AttributedString(span.text)
            if span.isItalic { piece.inlinePresentationIntent = (piece.inlinePresentationIntent ?? []).union(.emphasized) }
            if span.isBold { piece.inlinePresentationIntent = (piece.inlinePresentationIntent ?? []).union(.stronglyEmphasized) }
            if span.isUnderlined { piece.underlineStyle = .single }
            if span.isStrikethrough { piece.strikethroughStyle = .single }
            if let colour = span.colour, !style.overridesFileStyles {
                piece.foregroundColor = Color(red: colour.red, green: colour.green, blue: colour.blue).opacity(colour.alpha)
            } else {
                piece.foregroundColor = Color(red: base.red, green: base.green, blue: base.blue)
            }
            result += piece
        }
        return result
    }
}

private extension SubtitleCue {
    var row: SubtitleOverlay.Row { alignment.isTop ? .top : alignment.isMiddle ? .middle : .bottom }
}

private extension SubtitleAlignment {
    var textAlignment: TextAlignment {
        switch rawValue % 3 {
        case 1: .leading
        case 0: .trailing
        default: .center
        }
    }

    var frameAlignment: Alignment {
        switch rawValue % 3 {
        case 1: .leading
        case 0: .trailing
        default: .center
        }
    }
}

/// A PGS display set, placed where the disc puts it in the video frame (fitted into the view the way the picture is).
private struct BitmapSubtitleView: View {
    let cue: BitmapSubtitleCue
    let size: CGSize

    var body: some View {
        let frame = CGSize(width: CGFloat(max(1, cue.frameWidth)), height: CGFloat(max(1, cue.frameHeight)))
        let scale = min(size.width / frame.width, size.height / frame.height)
        let origin = CGPoint(x: (size.width - frame.width * scale) / 2, y: (size.height - frame.height * scale) / 2)
        ZStack(alignment: .topLeading) {
            ForEach(Array(cue.images.enumerated()), id: \.offset) { index, image in
                if let picture = BitmapImageCache.image(for: cue, index: index) {
                    Image(uiImage: picture)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
                        .offset(x: origin.x + CGFloat(image.x) * scale, y: origin.y + CGFloat(image.y) * scale)
                }
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
    }
}

/// Images built once per display set: the overlay redraws several times a second.
@MainActor
private enum BitmapImageCache {
    private static let cache = NSCache<NSString, UIImage>()

    static func image(for cue: BitmapSubtitleCue, index: Int) -> UIImage? {
        let key = "\(cue.start)-\(cue.end)-\(index)" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        let image = cue.images[index]
        guard image.width > 0, image.height > 0, image.rgba.count == image.width * image.height * 4,
              let provider = CGDataProvider(data: Data(image.rgba) as CFData),
              let cgImage = CGImage(width: image.width, height: image.height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: image.width * 4,
                                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                                    provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else { return nil }
        let picture = UIImage(cgImage: cgImage)
        cache.setObject(picture, forKey: key)
        return picture
    }
}
#endif
