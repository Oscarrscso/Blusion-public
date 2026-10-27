#if canImport(UIKit)
import StremioKit
import SwiftUI

/// The portrait hero's numbers, shared by Home's spotlight and the title page so that a title looks the same on both, and opening it from the
/// spotlight does not jump. Both screens read them; change one here and both move together.
enum TitleHero {
    /// On a Mac title page, the widest the synopsis and the trailer's panel under the hero run, and the stream list in their place.
    static let macDetailsWidth: CGFloat = 640
    /// The portrait picture is drawn this much larger than its frame (see `pictureHeight`).
    static let zoom: CGFloat = 1.15
    /// The length of the bottom fade, as a share of the unzoomed hero height. The fade keeps that length however far the picture runs.
    static let fadeShare = 0.42
    static let fadeStrength = 1.0
    /// How far the bottom fade runs past the picture's bottom edge, so no row of picture pixels shows under it while the page moves.
    static let fadeOverscan: CGFloat = 2
    /// The tallest logo, bottom-aligned above the gap to the text.
    static let logoMaxHeight: CGFloat = 150
    /// Cap portrait logos even when an overlay proposes an unconstrained width.
    static let logoMaxWidth: CGFloat = 360
    /// The gap between the bottom of the logo and the text under it (the metadata line), on the title page and on Home's spotlight alike.
    /// The text starts `portraitDrop` below the picture's bottom edge on both, so the logo stops this far above that.
    static let logoTextGap = Theme.Spacing.s
    /// The gap above and below the title page's Play row in portrait: from the metadata line down to the row, and from the row down to
    /// the overview or the trailer's panel, so the row sits evenly between them. The streams that take the row's place start this far
    /// under the line too, where Play sat. Landscape and the Mac keep their own, tighter gaps.
    static let playRowGap = Theme.Spacing.l
    /// How far the portrait hero lowers its logo, its bottom fade and everything below them, so more of the picture shows above the logo. Home's
    /// spotlight and the title page both use it, so a title sits in the same place on both. On Home the metadata line moves down with the logo,
    /// and its band gives up the same height (see `captionBelow`). This is the portrait layout, so iPhone and iPad use it. The Mac keeps its own
    /// layouts: the title page (`DesktopDetailHero`), and the spotlight's landscape caption, which sits over the picture.
    static let portraitDrop = Theme.Spacing.xl
    /// The longest edge of a decoded portrait hero. ImageIO downsamples oversized originals before bitmap creation.
    /// About 1200x1800 for a 2:3 poster: sharp on mobile, with less decoded memory than 2048.
    static let portraitPixelSize: CGFloat = 1800
    /// A 4096px landscape decode wastes memory on a phone-sized hero. Keep a larger budget for Mac windows.
    #if targetEnvironment(macCatalyst)
    static let landscapePixelSize: CGFloat = 3072
    #else
    static let landscapePixelSize: CGFloat = 2560
    #endif
    /// The longest edge the stand-in poster is decoded to. `ArtworkImage` decodes its own stand-in at this size too, and Home preloads the
    /// poster at it, so the stand-in is ready at once.
    static let placeholderPixelSize: CGFloat = 600
    static let imageAlignment = Alignment.top
    /// The blur on the stand-in poster while the picture loads, kept opaque at the edges (see `HeroPicture`).
    static let placeholderBlur: CGFloat = 2
    /// The height of Home's portrait page below the picture at the default text size: the band that holds the metadata line and the two
    /// lines of the synopsis under it. Each view that lays the page out scales it with Dynamic Type (`@ScaledMetric`), so larger text gets a
    /// taller band and stays clear of the page dots. The line starts `portraitDrop` below the picture's edge, so its text sits in what is
    /// left of the band.
    static let captionBelow: CGFloat = 114
    /// The scale a hero starts from before it settles at rest (see `heroSettle`): a little larger. The title page starts there when it opens
    /// from the spotlight, and the spotlight when a title closes back to it. Never smaller than rest: a hero that started smaller showed the
    /// black page round its picture until it had settled.
    static let settleLarger: Double = 1.025

    // MARK: Landscape title page (iPhone only; the Mac keeps its original sizes)
    /// How much of the next section shows under the landscape hero, so the page reads as one that scrolls.
    static let landscapePeek: CGFloat = 56
    /// The tallest the landscape hero gets, so an iPad's hero is not the whole screen.
    static let landscapeMaxHeight: CGFloat = 560
    /// The least the landscape hero is, even on a very short window (split view, a keyboard).
    static let landscapeMinHeight: CGFloat = 220
    /// The height of the landscape hero over the page height: the screen less the peek, capped. Large text may still grow it.
    static func landscapeHeroHeight(pageHeight: CGFloat) -> CGFloat {
        max(landscapeMinHeight, min(pageHeight - landscapePeek, landscapeMaxHeight))
    }
    /// The width of the landscape backdrop: 16:9 at the hero's height, so it is never cropped, and never wider than the page.
    static func landscapeArtWidth(heroHeight: CGFloat, pageWidth: CGFloat) -> CGFloat {
        max(0, min(heroHeight * 16 / 9, pageWidth))
    }
    /// The width of the landscape hero's text column, so Play has room and the overview's lines stay readable.
    static func landscapeTextWidth(pageWidth: CGFloat) -> CGFloat {
        max(0, min(pageWidth * 0.46, 480))
    }
    /// The tallest and widest the landscape logo can be.
    static var landscapeLogoMaxHeight: CGFloat {
        #if targetEnvironment(macCatalyst)
        56
        #else
        100
        #endif
    }
    static var landscapeLogoMaxWidth: CGFloat {
        #if targetEnvironment(macCatalyst)
        220
        #else
        300
        #endif
    }
    /// The one gap in the action row: between Play and the round actions beside it, and between those actions. All gaps are equal.
    static let actionGap: CGFloat = 6

    /// The height of the portrait picture on a screen `width` wide.
    static func height(width: CGFloat, metrics: LayoutMetrics) -> CGFloat {
        min(width * 1.5, metrics.heroMaxHeight)
    }

    /// The height of the zoomed portrait picture on a hero `height` tall. The picture is zoomed, so it is taller than the hero and reaches
    /// below its bottom edge, behind the text.
    static func pictureHeight(_ height: CGFloat) -> CGFloat { height * zoom }

    /// The height the logo is drawn at, as `HeroTitleArt` fits it into `width`. The logo's full reserved height while there is no logo
    /// image to measure or it is hidden, so the picture still ends where a tallest logo would be half covered.
    static func logoHeight(_ slot: HeroSlot, hidden: Bool, width: CGFloat) -> CGFloat {
        guard !hidden, case .ready(let image) = slot, image.size.width > 0, image.size.height > 0 else { return logoMaxHeight }
        return min(width / image.size.width, logoMaxHeight / image.size.height) * image.size.height
    }

    /// How much of the zoomed picture shows: it ends, fully faded to black, half way up the logo (which sits `logoTextGap` above the
    /// picture's edge, lowered by `portraitDrop`, and is `logoHeight` tall), so the fade never ends short of the logo or runs behind all of it.
    static func visibleHeight(_ height: CGFloat, logoHeight: CGFloat) -> CGFloat {
        min(pictureHeight(height), max(1, height + portraitDrop - logoTextGap - logoHeight / 2))
    }

    /// The bottom fade's share of the visible picture, `fadeShare` of the hero height.
    static func fadeLength(height: CGFloat, visible: CGFloat) -> Double { fadeShare * Double(height / max(visible, 1)) }
}

/// The settle as a modifier, so its keyframes are built in a plain type rather than in a generic `View` extension (see `View.heroSettle`).
private struct HeroSettle<Trigger: Equatable & Sendable>: ViewModifier {
    let trigger: Trigger
    /// The scale the settle starts from before it springs to rest at 1.
    let from: Double

    func body(content: Content) -> some View {
        content.keyframeAnimator(initialValue: 1.0, trigger: trigger) { view, scale in
            view.scaleEffect(scale)
        } keyframes: { _ in
            KeyframeTrack {
                // A move, not a keyframe of no length: that one has no speed to hand the spring, and the scale comes out
                // infinite, which draws nothing and takes no touches.
                MoveKeyframe(from)
                SpringKeyframe(1, duration: 0.4, spring: .smooth)
                // The spring is not quite at rest when its time is up. The spotlight ends at exactly its own size.
                LinearKeyframe(1, duration: 0.1)
            }
        }
    }
}

extension View {
    /// The settle a screen plays when `trigger` changes: the picture starts a little larger (`TitleHero.settleLarger`) and springs to rest
    /// at its own size. The title page plays it when it opens from the spotlight, and Home's spotlight when a title closes back to it. The
    /// caller clips it to the hero's frame, so the larger start only crops the edges. Scale only, so the picture and logo are never hidden
    /// or faded. Plays each time `trigger` changes, never on first appearance.
    func heroSettle(trigger: some Equatable & Sendable) -> some View {
        modifier(HeroSettle(trigger: trigger, from: TitleHero.settleLarger))
    }
}

/// What one hero image is doing: still loading, decoded and ready, or there is none (no URL once the lookup has finished, or it failed).
enum HeroSlot {
    case pending
    case ready(UIImage)
    case none
    var isPending: Bool { if case .pending = self { return true } else { return false } }
}

/// The picture and logo a Home spotlight page is showing, carried to the title page it opens so that page's first frame already has them. The
/// handoff holds the decoded images itself, so the shared caches evicting them cannot send the title page back to loading. Each image is used
/// only for the URL and size it was decoded at; anything else the title page asks for loads as usual.
final class HeroHandoff: Hashable {
    /// One decoded image: the URL it came from, the longest edge it was decoded to, and the image.
    struct Resolved {
        let url: URL
        let maxPixelSize: CGFloat
        let image: UIImage
    }

    let picture: Resolved?
    let logo: Resolved?

    init(picture: Resolved?, logo: Resolved?) {
        self.picture = picture
        self.logo = logo
    }

    /// A handoff is one hand-over, so two are equal only when they are the same one.
    static func == (lhs: HeroHandoff, rhs: HeroHandoff) -> Bool { lhs === rhs }

    func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(self)) }
}

/// Loads the hero picture and the logo together and answers from the image cache, so a decoded one is there in the first frame.
/// It also holds what it has shown, so the shared cache evicting a large picture never sends a shown hero back to loading, and every
/// logo lives in a process-wide store, so a title's logo is there in the first frame for the rest of the session.
@MainActor @Observable
final class HeroLoader {
    /// Longest edge the logo is decoded to, on Home and on the title page.
    static let logoPixelSize: CGFloat = 800
    /// Logos are small, so this many are kept for the whole session; the oldest go first.
    private static let logoLimit = 80
    private static var logos: [String: UIImage] = [:]
    private static var logoOrder: [String] = []

    private var failed: Set<String> = []
    private var revision = 0
    /// The pictures this loader has resolved, held strongly so they outlive the shared cache's eviction. Not observed: `revision` is.
    @ObservationIgnored private var held: [String: UIImage] = [:]
    /// The logo this loader has resolved, held apart from `held` so `release(keeping:)` never drops it, and so the shared logo store's limit
    /// cannot take it from a page that is still showing it.
    @ObservationIgnored private var heldLogo: (key: String, image: UIImage)?

    /// A loader that already holds what a Home spotlight page showed, so the title page opened from it has that picture and logo in its first
    /// frame. Each is found only for the URL and size it was decoded at (see `HeroHandoff`).
    init(seeding handoff: HeroHandoff? = nil) {
        if let picture = handoff?.picture { held[Self.key(picture.url, picture.maxPixelSize)] = picture.image }
        if let logo = handoff?.logo { heldLogo = (Self.key(logo.url, logo.maxPixelSize), logo.image) }
    }

    nonisolated private static func key(_ url: URL, _ size: CGFloat) -> String { "\(Int(size))|\(url.absoluteString)" }

    /// The logo of `url` if one has been loaded this session.
    static func storedLogo(_ url: URL) -> UIImage? { logos[key(url, logoPixelSize)] }

    /// The logo cropped to its visible pixels (see `LogoTrim`), so every title's logo-to-text gap is the same, and turned light when it is
    /// drawn in black (see `LogoLegibility`): it sits on the black end of the picture's fade, where black lettering cannot be read.
    nonisolated private static func trimmedLogo(_ image: UIImage) -> UIImage {
        guard let cgImage = image.cgImage else { return image }
        let prepared = LogoLegibility.legible(LogoTrim.trimmed(cgImage))
        return prepared === cgImage ? image : UIImage(cgImage: prepared, scale: image.scale, orientation: image.imageOrientation)
    }

    /// Stores an already prepared logo; the pixel scans and colour transform happen off the main actor.
    @discardableResult
    private static func storeLogo(_ image: UIImage, for url: URL) -> UIImage {
        let key = key(url, logoPixelSize)
        if let stored = logos[key] { return stored }
        logos[key] = image
        logoOrder.append(key)
        while logoOrder.count > logoLimit { logos[logoOrder.removeFirst()] = nil }
        return image
    }

    /// Loads a logo into the process-wide store without any loader, so it is ready before its page is built. Ignores failures.
    static func warmLogo(_ url: URL, priority: TaskPriority) async {
        if storedLogo(url) != nil { return }
        guard let raw = try? await ImagePipeline.shared.image(for: url, maxPixelSize: logoPixelSize, priority: priority),
              !Task.isCancelled else { return }
        let prepared = await Task.detached(priority: priority) { trimmedLogo(raw) }.value
        guard !Task.isCancelled else { return }
        storeLogo(prepared, for: url)
    }

    /// Remembers an image that has been resolved: a logo in the shared store and in this loader, a picture in this loader. A logo that is
    /// stored already is kept.
    private func remember(_ image: UIImage, url: URL, size: CGFloat) {
        if size == Self.logoPixelSize {
            heldLogo = (Self.key(url, size), Self.storedLogo(url) ?? Self.storeLogo(image, for: url))
        } else {
            held[Self.key(url, size)] = image
        }
    }

    /// Drops the pictures this loader holds except those in `kept`, so a page that has left the load window stops pinning memory.
    /// Logos are never dropped.
    func release(keeping kept: [(URL, CGFloat)]) {
        guard !held.isEmpty else { return }
        let keys = Set(kept.map { Self.key($0.0, $0.1) })
        held = held.filter { keys.contains($0.key) }
    }

    /// A slot's state. A nil URL is pending until `lookupFinished`, then there is none.
    func slot(url: URL?, maxPixelSize: CGFloat, lookupFinished: Bool) -> HeroSlot {
        _ = revision
        guard let url else { return lookupFinished ? .none : .pending }
        let key = Self.key(url, maxPixelSize)
        if let image = held[key] { return .ready(image) }
        if maxPixelSize == Self.logoPixelSize {
            if let logo = heldLogo, logo.key == key { return .ready(logo.image) }
            if let logo = Self.storedLogo(url) {
                remember(logo, url: url, size: maxPixelSize)
                return .ready(logo)
            }
        }
        // A raw decoded logo still needs its alpha/colour processing; do not run those pixel scans during a SwiftUI render.
        if maxPixelSize != Self.logoPixelSize,
           let image = ImagePipeline.shared.cachedImage(for: url, maxPixelSize: maxPixelSize) {
            remember(image, url: url, size: maxPixelSize)
            return .ready(image)
        }
        return failed.contains(key) ? .none : .pending
    }

    /// The one reveal condition: neither is still pending. A missing or failed one does not hold the other back.
    static func isRevealed(_ picture: HeroSlot, _ logo: HeroSlot) -> Bool { !picture.isPending && !logo.isPending }

    /// Starts the picture and the logo as soon as each one's URL is known, and returns when both have finished. Neither waits for the other, so a
    /// logo the addon supplies starts while the picture's lookup is still running. The reveal still needs both (`isRevealed`), so a logo that
    /// arrives first is not shown early. `urgent` lets the picture and logo skip the pipeline's queue (see `ImagePipeline.image`).
    func load(priority: TaskPriority = .high, urgent: Bool = false, picture: URL?, pictureSize: CGFloat, logo: URL?, logoSize: CGFloat) async {
        let wanted = [(picture, pictureSize), (logo, logoSize)].compactMap { url, size in
            url.map { ($0, size) }
        }
        var pending: [(URL, CGFloat)] = []
        for (url, size) in wanted {
            if size == Self.logoPixelSize, Self.storedLogo(url) != nil || heldLogo?.key == Self.key(url, size) { continue }
            if held[Self.key(url, size)] != nil { continue }
            if size != Self.logoPixelSize, let cached = ImagePipeline.shared.cachedImage(for: url, maxPixelSize: size) {
                remember(cached, url: url, size: size)
                continue
            }
            pending.append((url, size))
        }
        guard !pending.isEmpty else { return }
        let results = await withTaskGroup(of: (URL, CGFloat, UIImage?, Bool).self, returning: [(URL, CGFloat, UIImage?, Bool)].self) { group in
            for (url, size) in pending {
                let isLogo = size == Self.logoPixelSize
                group.addTask {
                    do {
                        let image = try await Self.download(url, size: size, isLogo: isLogo, priority: priority, urgent: urgent)
                        return (url, size, image, false)
                    } catch { return (url, size, nil, !Task.isCancelled) }
                }
            }
            var all: [(URL, CGFloat, UIImage?, Bool)] = []
            for await result in group { all.append(result) }
            return all
        }
        // Kept even when this load was cancelled: a logo that finished is stored, and the revision moves so the page shows it.
        var failures: [String] = []
        for (url, size, image, didFail) in results {
            if let image { remember(image, url: url, size: size) } else if didFail { failures.append(Self.key(url, size)) }
        }
        withAnimation(.easeOut(duration: 0.25)) {
            failed.formUnion(failures)
            revision += 1
        }
    }

    /// Downloads one picture or logo. A picture belongs to the load that asked for it, so cancelling the load stops it. A logo runs in a task of
    /// its own: a load that is cancelled (a page's task restarts when its picture's URL arrives) leaves it going, and the next load for the logo
    /// joins the same download in the pipeline rather than starting another.
    nonisolated private static func download(_ url: URL, size: CGFloat, isLogo: Bool, priority: TaskPriority, urgent: Bool) async throws -> UIImage {
        guard isLogo else {
            return try await ImagePipeline.shared.image(for: url, maxPixelSize: size, priority: priority, urgent: urgent)
        }
        let raw = try await Task(priority: priority) {
            try await ImagePipeline.shared.image(for: url, maxPixelSize: size, priority: priority, urgent: urgent)
        }.value
        try Task.checkCancellation()
        return await Task.detached(priority: priority) { trimmedLogo(raw) }.value
    }
}

/// The hero picture, drawn over the poster it stands in with until the picture is revealed. The stand-in is the title's card poster (see
/// `PosterQuality.poster(for:)`), slightly blurred and with a spinner over it. Metahub's poster takes its place only if that one fails.
/// The picture itself is shown only while `isRevealed`, with the logo.
struct HeroPicture: View {
    let slot: HeroSlot
    let isRevealed: Bool
    let contentMode: ContentMode
    var alignment: Alignment = TitleHero.imageAlignment
    /// The title whose poster stands in until the picture is revealed. A title with no poster and no IMDb id draws no stand-in.
    let preview: MetaPreview
    /// Whether the stand-in may only be a backdrop, never a poster, and no poster fallback is loaded for it (the Mac title page).
    let standInFromBackdrop: Bool
    /// The title page keeps the system's spinner over its stand-in, as asked; Home's spotlight has the app's thin ring.
    let usesSystemSpinner: Bool
    /// The stand-in's address, chosen once when the page opens (see `standInURL(for:)`).
    @State private var standIn: URL?

    init(slot: HeroSlot, isRevealed: Bool, contentMode: ContentMode, alignment: Alignment = TitleHero.imageAlignment, preview: MetaPreview,
         standInFromBackdrop: Bool = false, usesSystemSpinner: Bool = false) {
        self.slot = slot
        self.isRevealed = isRevealed
        self.contentMode = contentMode
        self.alignment = alignment
        self.preview = preview
        self.standInFromBackdrop = standInFromBackdrop
        self.usesSystemSpinner = usesSystemSpinner
        _standIn = State(initialValue: Self.standInURL(for: preview, backdropOnly: standInFromBackdrop))
    }

    /// The picture that stands in for `preview`: its card poster, or, when that is not decoded and another picture of the title is (the
    /// backdrop a wide card or a turned phone showed), that one. Whatever the card that opened this page was showing is then on screen in
    /// the first frame, and nothing is loaded again for it. With `backdropOnly`, a page that lays out full width (the Mac title page) only
    /// ever stands in with a backdrop, never a cropped poster.
    static func standInURL(for preview: MetaPreview, backdropOnly: Bool = false) -> URL? {
        if backdropOnly {
            let backdrops = [preview.background, MetahubArtwork.background(imdbID: preview.id)].compactMap { $0 }
            return backdrops.first { ImagePipeline.shared.cachedImageAtAnySize(for: $0) != nil } ?? backdrops.first
        }
        let poster = PosterQuality.poster(for: preview)
        let shown = [poster, BetterPosters.posterURL(id: preview.id, type: preview.type), preview.background,
                     MetahubArtwork.background(imdbID: preview.id)].compactMap { $0 }
        return shown.first { ImagePipeline.shared.cachedImageAtAnySize(for: $0) != nil } ?? poster
    }

    private var hasPicture: Bool {
        if case .ready = slot { return true }
        return false
    }

    var body: some View {
        ZStack {
            if !isRevealed, let standIn {
                // Stays fully opaque while the picture fades in over it (the reveal lasts 0.25 s), then goes unseen. With no picture to
                // reveal it goes as it did, with a fade.
                ArtworkImage(url: standIn, maxPixelSize: TitleHero.placeholderPixelSize, contentMode: contentMode,
                             placeholderBlur: 0,
                             fallbackURL: standInFromBackdrop ? nil : PosterQuality.smallest(MetahubArtwork.poster(imdbID: preview.id)),
                             imageAlignment: alignment, acceptsAnyCachedSize: true)
                    .blur(radius: TitleHero.placeholderBlur, opaque: true)
                    .overlay {
                        if usesSystemSpinner {
                            ProgressView()
                                .controlSize(.large)
                                .tint(.white)
                                .accessibilityHidden(true)
                        } else {
                            Spinner()
                                .controlSize(.large)
                                .accessibilityHidden(true)
                        }
                    }
                    .transition(hasPicture ? .asymmetric(insertion: .identity, removal: .opacity.animation(.linear(duration: 0.01).delay(0.3)))
                                           : .opacity)
            }
            Color.clear
                .overlay(alignment: alignment) {
                    if case .ready(let image) = slot {
                        Image(uiImage: image)
                            .resizable()
                            .aspectRatio(contentMode: contentMode)
                            .transition(.identity)
                    }
                }
                .opacity(isRevealed ? 1 : 0)
        }
        .clipped()
        .accessibilityHidden(true)
        // A view that is kept for another title chooses again.
        .onChange(of: preview.identity) { standIn = Self.standInURL(for: preview, backdropOnly: standInFromBackdrop) }
    }
}

/// The title on a portrait hero: the logo, or the name when there is no logo or it failed to load. The title page and Home's spotlight both
/// show it this way, so the logo sits the same distance above the text under it on both. The logo comes from the shared hero loader and is
/// revealed with the picture. While it is pending the name is not drawn, and its full height is kept, so the text below does not move when it
/// arrives.
struct HeroTitleArt: View {
    let name: String
    let slot: HeroSlot
    let alignment: Alignment
    let compact: Bool
    /// Draws nothing, not even the name, but keeps the logo's space, for a portrait picture that already carries the title.
    var hidden = false
    /// The box a logo is fitted into, when a page sizes its own title; nil uses the page's standard sizes.
    var logoBox: CGSize?

    /// The tallest a logo can be on this page.
    private var logoHeight: CGFloat { logoBox?.height ?? (compact ? TitleHero.landscapeLogoMaxHeight : TitleHero.logoMaxHeight) }
    /// Whether the slot has no logo: no URL once the lookup has finished, or a failed load.
    private var isNone: Bool {
        if case .none = slot { return true }
        return false
    }
    /// A title keeps the logo's space until the logo is ready or known to be absent.
    private var reservesLogoHeight: Bool { !isNone || hidden }

    var body: some View {
        Group {
            if hidden {
                Color.clear.frame(height: 0)
            } else if case .ready(let image) = slot {
                LogoLayout(imageSize: image.size, maxWidth: logoBox?.width ?? (compact ? TitleHero.landscapeLogoMaxWidth : TitleHero.logoMaxWidth),
                           maxHeight: logoHeight) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                }
                // Revealed by the page's opacity alone, on the same curve as the picture.
                .transition(.identity)
            } else {
                Text(name)
                    .font(compact ? .title2.bold() : .largeTitle.bold())
                    .multilineTextAlignment(alignment == .center ? .center : .leading)
                    .foregroundStyle(.white)
                    .lineLimit(compact ? 2 : 3)
                    .minimumScaleFactor(0.7)
                    .fixedSize(horizontal: false, vertical: true)
                    // A logo ends at its last visible pixel; the name's frame ends a descender lower, so that space is taken back and the
                    // text under either sits the same distance from what can be seen.
                    .padding(.bottom, -abs(UIFont.preferredFont(forTextStyle: compact ? .title2 : .largeTitle).descender))
                    .opacity(isNone ? 1 : 0)
                    .transition(.identity)
            }
        }
        // Bottom-aligned, so a logo shorter than the reserved space sits where it did before, just above the text under it.
        .frame(minHeight: reservesLogoHeight ? logoHeight : nil, alignment: Alignment(horizontal: alignment.horizontal, vertical: .bottom))
    }
}

/// Reports the fitted image bounds instead of a taller frame containing empty space.
struct LogoLayout: Layout {
    let imageSize: CGSize
    let maxWidth: CGFloat
    let maxHeight: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard imageSize.width > 0, imageSize.height > 0 else { return .zero }
        let width = max(0, min(proposal.width ?? maxWidth, maxWidth))
        let scale = min(width / imageSize.width, maxHeight / imageSize.height)
        return CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(bounds.size))
    }
}

/// A title's logo for Home's landscape caption, fitted into a box of fixed size so the text under it never moves when it arrives.
struct HeroLogo: View {
    static let box = CGSize(width: 260, height: 84)

    let image: UIImage

    var body: some View {
        Color.clear
            .frame(width: Self.box.width, height: Self.box.height)
            .overlay(alignment: .bottom) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
            }
    }
}
#endif
