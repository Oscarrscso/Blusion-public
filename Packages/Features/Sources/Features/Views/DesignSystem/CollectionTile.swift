#if canImport(UIKit)
import SwiftUI

/// The TV app's category tile (a genre, a streaming service, a decade): 16:9 with the name bottom-left in bold white. With an image
/// the name sits over a fade at the bottom of the picture (unless `hideTitle`); without one the tile is a dark gradient derived
/// from the name, so "Action" always gets the same colours. `hideTitle` is ignored without an image: the name is then the tile's
/// only content. `width` defaults to the layout's tile width; `stretched()` takes a grid column's width instead.
struct CollectionTile: View {
    let title: String
    let imageURL: URL?
    let aspect: CardAspect
    let hideTitle: Bool
    let width: CGFloat?
    private var stretches = false
    @Environment(\.layoutMetrics) private var metrics
    @Environment(\.displayScale) private var displayScale

    init(title: String, imageURL: URL? = nil, aspect: CardAspect = .wide, hideTitle: Bool = false, width: CGFloat? = nil) {
        self.title = title
        self.imageURL = imageURL
        self.aspect = aspect
        self.hideTitle = hideTitle
        self.width = width
    }

    var body: some View {
        space
            .overlay { face }
            .overlay(alignment: .bottomLeading) { label }
            .mediaArtwork(cornerRadius: aspect.cornerRadius)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(title)
            .accessibilityAddTraits(.isButton)
    }

    /// The tile takes whatever width it is offered, as a grid column does.
    func stretched() -> CollectionTile {
        var copy = self
        copy.stretches = true
        return copy
    }

    private var resolvedWidth: CGFloat {
        if let width { return width }
        switch aspect {
        case .wide: return metrics.tileWidth
        case .poster: return metrics.posterWidth
        case .square: return metrics.squareWidth
        }
    }

    @ViewBuilder
    private var space: some View {
        if stretches {
            Color.clear.aspectRatio(aspect.ratio, contentMode: .fit)
        } else {
            Color.clear.frame(width: resolvedWidth, height: resolvedWidth / aspect.ratio)
        }
    }

    @ViewBuilder
    private var face: some View {
        if let imageURL {
            ArtworkImage(url: imageURL, title: title, maxPixelSize: min((resolvedWidth * displayScale).rounded(.up), 1200))
        } else {
            let look = TileLook.look(for: title)
            ZStack {
                LinearGradient(colors: [look.top, look.bottom], startPoint: .topLeading, endPoint: .bottomTrailing)
                LinearGradient(colors: [.white.opacity(0.16), .clear], startPoint: .topLeading, endPoint: UnitPoint(x: 0.6, y: 0.6))
                if let symbol = look.symbol {
                    Image(systemName: symbol)
                        .font(.system(size: resolvedWidth * 0.46, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.13))
                        .rotationEffect(.degrees(-12))
                        .offset(x: resolvedWidth * 0.26, y: -resolvedWidth * 0.04)
                }
            }
        }
    }

    @ViewBuilder
    private var label: some View {
        if imageURL == nil || !hideTitle {
            Text(title)
                .font(.title3.bold())
                .foregroundStyle(.white)
                .multilineTextAlignment(.leading)
                .lineLimit(2)
                .minimumScaleFactor(0.8)
                .padding(.horizontal, Theme.Spacing.m + 2)
                .padding(.bottom, Theme.Spacing.m + 2)
                .padding(.top, imageURL == nil ? Theme.Spacing.m : Theme.Spacing.xxl)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(alignment: .bottom) {
                    if imageURL != nil {
                        LinearGradient(colors: [.black.opacity(0), .black.opacity(0.72)], startPoint: .top, endPoint: .bottom)
                    } else {
                        LinearGradient(colors: [.black.opacity(0), .black.opacity(0.28)], startPoint: .top, endPoint: .bottom)
                    }
                }
        }
    }
}

extension CollectionTile {
    /// The colour and glyph a tile without a picture uses for `title`, for a compact row that stands for the same category. A category
    /// with no glyph of its own gets a plain grid.
    static func accent(for title: String) -> (colour: Color, symbol: String) {
        let look = TileLook.look(for: title)
        return (look.top, look.symbol ?? "square.grid.2x2.fill")
    }
}

/// The colours of a tile without a picture: ten hand-picked pairs, a bright corner fading to a deep one, chosen by a stable hash of
/// the title. Hand-picked, because a hue taken straight from a hash gives garish yellows and lime greens.
private struct TileLook {
    let top: Color
    let bottom: Color
    let symbol: String?

    static func look(for title: String) -> TileLook {
        let pair = palettes[Int(seed(for: title) % UInt64(palettes.count))]
        return TileLook(top: pair.0, bottom: pair.1, symbol: symbol(for: title))
    }

    private static let palettes: [(Color, Color)] = [
        (Color(red: 0.36, green: 0.30, blue: 0.86), Color(red: 0.09, green: 0.07, blue: 0.28)),
        (Color(red: 0.78, green: 0.24, blue: 0.52), Color(red: 0.25, green: 0.05, blue: 0.19)),
        (Color(red: 0.90, green: 0.42, blue: 0.20), Color(red: 0.31, green: 0.08, blue: 0.07)),
        (Color(red: 0.16, green: 0.60, blue: 0.62), Color(red: 0.03, green: 0.17, blue: 0.23)),
        (Color(red: 0.25, green: 0.50, blue: 0.92), Color(red: 0.05, green: 0.11, blue: 0.33)),
        (Color(red: 0.32, green: 0.66, blue: 0.40), Color(red: 0.04, green: 0.19, blue: 0.12)),
        (Color(red: 0.62, green: 0.34, blue: 0.88), Color(red: 0.14, green: 0.06, blue: 0.31)),
        (Color(red: 0.86, green: 0.62, blue: 0.20), Color(red: 0.29, green: 0.15, blue: 0.04)),
        (Color(red: 0.82, green: 0.25, blue: 0.30), Color(red: 0.26, green: 0.05, blue: 0.09)),
        (Color(red: 0.45, green: 0.52, blue: 0.64), Color(red: 0.08, green: 0.10, blue: 0.16)),
    ]

    /// A faint glyph for the genres everyone knows, so a grid of tiles does not read as a wall of colour.
    private static func symbol(for title: String) -> String? {
        let name = title.lowercased()
        let known: [(String, String)] = [
            ("action", "bolt.fill"), ("adventure", "map.fill"), ("animation", "paintpalette.fill"), ("comedy", "face.smiling.fill"),
            ("crime", "magnifyingglass"), ("documentary", "film.stack.fill"), ("drama", "theatermasks.fill"), ("family", "figure.2.and.child.holdinghands"),
            ("fantasy", "wand.and.stars"), ("history", "building.columns.fill"), ("horror", "moon.stars.fill"), ("music", "music.note"),
            ("mystery", "questionmark"), ("romance", "heart.fill"), ("sci", "sparkles"), ("thriller", "eye.fill"), ("war", "shield.fill"),
            ("western", "sun.max.fill"), ("sport", "figure.run"), ("reality", "tv.fill"), ("kids", "star.fill"), ("anime", "sparkle"),
        ]
        return known.first { name.contains($0.0) }?.1
    }

    /// FNV-1a over the scalars. `Hasher` is seeded per launch, so it would recolour every tile after each restart.
    private static func seed(for text: String) -> UInt64 {
        text.unicodeScalars.reduce(UInt64(0xcbf2_9ce4_8422_2325)) { ($0 ^ UInt64($1.value)) &* 0x0000_0100_0000_01b3 }
    }
}
#endif
