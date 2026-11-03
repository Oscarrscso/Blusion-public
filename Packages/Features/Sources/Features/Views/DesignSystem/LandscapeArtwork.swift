#if canImport(UIKit)
import SwiftUI

/// Original-colour artwork and a logo, shared by Continue and poster cards.
/// Logo legibility comes from its own shadow; the artwork is never dimmed.
struct LandscapeArtwork: View {
    let title: String
    let artwork: URL?
    let logo: URL?
    let maxPixelSize: CGFloat
    let fallbackArtwork: URL?
    let logoAlignment: Alignment
    let logoBottomInset: CGFloat
    let showsLogo: Bool
    let acceptsAnyCachedSize: Bool
    let usesHeroLogo: Bool
    let artworkIsReady: Binding<Bool>?
    @State private var logoImage: UIImage?
    @State private var heroImage: UIImage?
    @Environment(\.artworkPriority) private var artworkPriority
    @Environment(\.artworkOrder) private var artworkOrder

    init(title: String, artwork: URL?, logo: URL?, maxPixelSize: CGFloat, fallbackArtwork: URL? = nil,
         logoAlignment: Alignment = .center, logoBottomInset: CGFloat = 0, showsLogo: Bool = true,
         acceptsAnyCachedSize: Bool = true, usesHeroLogo: Bool = false, artworkIsReady: Binding<Bool>? = nil) {
        self.title = title
        self.artwork = artwork
        self.logo = logo
        self.maxPixelSize = maxPixelSize
        self.fallbackArtwork = fallbackArtwork
        self.logoAlignment = logoAlignment
        self.logoBottomInset = logoBottomInset
        self.showsLogo = showsLogo
        self.acceptsAnyCachedSize = acceptsAnyCachedSize
        self.usesHeroLogo = usesHeroLogo
        self.artworkIsReady = artworkIsReady
        _heroImage = State(initialValue: usesHeroLogo ? artwork.flatMap {
            ImagePipeline.shared.cachedImage(for: $0, maxPixelSize: maxPixelSize)
        } : nil)
        _logoImage = State(initialValue: logo.flatMap {
            usesHeroLogo ? HeroLoader.storedLogo($0) : ImagePipeline.shared.cachedImage(for: $0, maxPixelSize: 400)
        })
    }

    /// The longest edge a card's artwork is decoded to: its width in pixels, at most 1200.
    static func maxPixelSize(width: CGFloat, scale: CGFloat) -> CGFloat {
        min((width * scale).rounded(.up), 1200)
    }

    var body: some View {
        GeometryReader { geometry in
            Group {
                if usesHeroLogo {
                    Color.clear.overlay {
                        if let heroImage {
                            Image(uiImage: heroImage).resizable().scaledToFill()
                        } else {
                            Theme.placeholder.overlay {
                                Text(title)
                                    .font(Theme.Typography.cardTitle)
                                    .foregroundStyle(.secondary)
                                    .multilineTextAlignment(.center)
                                    .lineLimit(4)
                                    .padding(Theme.Spacing.s)
                            }
                        }
                    }
                    .clipped()
                } else {
                    ArtworkImage(url: artwork ?? fallbackArtwork, maxPixelSize: maxPixelSize, fallbackURL: fallbackArtwork,
                                 acceptsAnyCachedSize: acceptsAnyCachedSize, keepsPictureOnShow: true)
                }
            }
                .overlay(alignment: logoAlignment) {
                    if showsLogo && (!usesHeroLogo || heroImage != nil) && (logo != nil || !title.isEmpty) {
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
                        .frame(width: geometry.size.width * 0.74, height: geometry.size.height * 0.38, alignment: logoAlignment)
                        .padding(.bottom, logoBottomInset)
                        .shadow(color: .black.opacity(0.85), radius: 3, y: 1)
                        .allowsHitTesting(false)
                        .transaction { $0.animation = nil; $0.disablesAnimations = true }
                    }
                }
        }
        .accessibilityHidden(true)
        .onChange(of: heroImage != nil, initial: true) { _, ready in artworkIsReady?.wrappedValue = ready }
        .task(id: artwork) {
            guard usesHeroLogo else { return }
            heroImage = artwork.flatMap { ImagePipeline.shared.cachedImage(for: $0, maxPixelSize: maxPixelSize) }
            guard let artwork, heroImage == nil else { return }
            let image = try? await ImagePipeline.shared.image(for: artwork, maxPixelSize: maxPixelSize,
                                                            priority: artworkPriority, order: artworkOrder)
            guard !Task.isCancelled else { return }
            heroImage = image
        }
        .task(id: "\(logo?.absoluteString ?? "-")|\(usesHeroLogo)|\(showsLogo)") {
            // A recycled card must not keep another title's logo, or crossfade its fallback text over the new logo.
            if usesHeroLogo {
                logoImage = logo.flatMap { HeroLoader.storedLogo($0) }
                guard showsLogo, let logo, logoImage == nil else { return }
                await HeroLoader.warmLogo(logo, priority: .medium)
                guard !Task.isCancelled else { return }
                logoImage = HeroLoader.storedLogo(logo)
                return
            }
            logoImage = logo.flatMap { ImagePipeline.shared.cachedImage(for: $0, maxPixelSize: 400) }
            guard let logo, logoImage == nil else { return }
            let image = try? await ImagePipeline.shared.image(for: logo, maxPixelSize: 400)
            guard !Task.isCancelled else { return }
            logoImage = image
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
