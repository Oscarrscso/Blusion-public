#if canImport(UIKit)
import SwiftUI

/// One darkened landscape image and centered logo, shared by Continue and landscape poster cards. With no logo and no title, only the
/// darkened image is drawn.
struct LandscapeArtwork: View {
    let title: String
    let artwork: URL?
    let logo: URL?
    let maxPixelSize: CGFloat
    @State private var logoImage: UIImage?

    init(title: String, artwork: URL?, logo: URL?, maxPixelSize: CGFloat) {
        self.title = title
        self.artwork = artwork
        self.logo = logo
        self.maxPixelSize = maxPixelSize
        _logoImage = State(initialValue: logo.flatMap { ImagePipeline.shared.cachedImage(for: $0, maxPixelSize: 400) })
    }

    /// The longest edge a card's artwork is decoded to: its width in pixels, at most 1200.
    static func maxPixelSize(width: CGFloat, scale: CGFloat) -> CGFloat {
        min((width * scale).rounded(.up), 1200)
    }

    var body: some View {
        GeometryReader { geometry in
            ArtworkImage(url: artwork, maxPixelSize: maxPixelSize)
                .overlay { Color.black.opacity(0.32).allowsHitTesting(false) }
                .overlay {
                    if logo != nil || !title.isEmpty {
                        Group {
                            if let logoImage {
                                Image(uiImage: logoImage).resizable().scaledToFit()
                            } else {
                                Text(title)
                                    .font(Theme.Typography.cardTitle)
                                    .foregroundStyle(.white)
                                    .multilineTextAlignment(.center)
                                    .lineLimit(2)
                                    .minimumScaleFactor(0.8)
                            }
                        }
                        .frame(width: geometry.size.width * 0.74, height: geometry.size.height * 0.38)
                        .shadow(color: .black.opacity(0.4), radius: 2)
                        .allowsHitTesting(false)
                    }
                }
        }
        .accessibilityHidden(true)
        .task(id: logo) {
            guard let logo else { logoImage = nil; return }
            let image = try? await ImagePipeline.shared.image(for: logo, maxPixelSize: 400)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.25)) { logoImage = image }
        }
    }
}

/// A landscape card at the Continue Watching size (`width` nil) or `width`: the artwork from `LandscapeArtwork`, the caller's `content`
/// over its bottom, and the card's corners and hairline. The card is not an accessibility element; the caller describes it.
struct LandscapeCard<Content: View>: View {
    let title: String
    let logo: URL?
    let artwork: URL?
    let width: CGFloat?
    let content: Content
    @Environment(\.layoutMetrics) private var metrics
    @Environment(\.displayScale) private var displayScale

    init(title: String, logo: URL? = nil, artwork: URL?, width: CGFloat? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.logo = logo
        self.artwork = artwork
        self.width = width
        self.content = content()
    }

    var body: some View {
        let fixed = width ?? metrics.continueCardWidth
        Color.clear
            .frame(width: fixed, height: fixed / CardAspect.wide.ratio)
            .overlay {
                LandscapeArtwork(title: title, artwork: artwork, logo: logo,
                                 maxPixelSize: LandscapeArtwork.maxPixelSize(width: fixed, scale: displayScale))
            }
            .overlay { content }
            .mediaArtwork()
    }
}
#endif
