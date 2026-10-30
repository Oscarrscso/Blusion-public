#if canImport(UIKit)
import StremioKit
import SwiftUI

/// The spotlight section of Home: the carousel once its items arrive, a placeholder of the same size until then, and a message when
/// it cannot load.
struct HeroSection: View {
    let section: HomeViewModel.Section
    @Binding var pageID: String?
    let onRetry: () -> Void
    @Environment(\.layoutMetrics) private var metrics

    var body: some View {
        VStack(alignment: .leading, spacing: metrics.headerSpacing) {
            if !section.widget.hideTitle {
                SectionHeader(section.widget.title).padding(.horizontal, metrics.pageMargin)
            }
            content
        }
    }

    @ViewBuilder
    private var content: some View {
        switch section.state {
        case .idle, .loading:
            HeroPlaceholder()
        case .loaded(let items) where !items.isEmpty:
            HeroCarousel(items: items, pageID: $pageID)
        case .loaded:
            if let issue = section.issue {
                IssueMessage(issue: issue)
            }
        case .failed(let error):
            InlineErrorView(error.shortDescription, retry: onRetry)
                .padding(.horizontal, metrics.pageMargin)
        }
    }
}

extension EnvironmentValues {
    /// How far Home has been pulled down past its top while the spotlight is its first section. The spotlight stretches by this much, like
    /// a refresh.
    @Entry var heroPull: CGFloat = 0
}

/// A paging carousel of full-resolution portrait or landscape heroes, each clipped to its own page.
struct HeroCarousel: View {
    let items: [MetaPreview]
    /// Home owns the selection so scrolling this lazy section away does not reset it.
    @Binding var pageID: String?
    @Environment(\.layoutMetrics) private var metrics
    @Environment(\.isPhoneLandscape) private var isPhoneLandscape
    /// The landscape form: a phone turned sideways, or any Mac window.
    private var isLandscape: Bool { isPhoneLandscape || HeroCarousel.isMacCatalyst }
    @Environment(\.heroContainerHeight) private var containerHeight
    @Environment(\.heroContainerWidth) private var containerWidth
    @Environment(\.isHomeScrolling) private var isHomeScrolling
    /// The portrait page's band under the picture, scaled with Dynamic Type so a larger metadata line keeps its room (see `TitleHero.captionBelow`).
    @ScaledMetric(relativeTo: .footnote) private var captionBelow: CGFloat = TitleHero.captionBelow
    @Environment(\.heroPull) private var heroPull
    @Environment(PosterRatingsStore.self) private var ratings
    @Environment(AppRouter.self) private var router
    #if targetEnvironment(macCatalyst)
    /// Whether the pointer is over the spotlight, which shows its page chevrons on Mac.
    @State private var isHoveringSpotlight = false
    #endif

    /// How many pages ahead of (and behind) the one on screen load their full-quality picture: four in portrait, two in landscape, where the
    /// pictures are decoded larger and too big to hold more. The nearest page and its neighbour start at once; the rest of the window
    /// follows. Pages beyond it let go of their picture and show whatever is still cached, else their poster, until a swipe brings them in
    /// range.
    static func loadWindow(isLandscape: Bool) -> Int { 0 }

    /// True on a Mac build. The spotlight keeps its landscape form in every window shape there, rather than following the window's aspect.
    static var isMacCatalyst: Bool {
        #if targetEnvironment(macCatalyst)
        return true
        #else
        return false
        #endif
    }

    private var currentIndex: Int {
        items.firstIndex { $0.identity == (pageID ?? items.first?.identity) } ?? 0
    }

    #if targetEnvironment(macCatalyst)
    /// Mac: a chevron at each side of the spotlight, shown while the pointer is over it, to page it.
    private var pageArrows: some View {
        HStack {
            pageArrow(systemName: "chevron.left", label: "Previous title", step: -1, enabled: currentIndex > 0)
            Spacer()
            pageArrow(systemName: "chevron.right", label: "Next title", step: 1, enabled: currentIndex < items.count - 1)
        }
        .padding(.horizontal, Theme.Spacing.l)
        .frame(maxHeight: .infinity)
    }

    private func pageArrow(systemName: String, label: String, step: Int, enabled: Bool) -> some View {
        Button { page(by: step) } label: {
            Image(systemName: systemName)
                .font(.title2.weight(.semibold))
                .frame(width: 48, height: 48)
                .glassEffect(.regular, in: .circle)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        // A hidden chevron must not take taps meant for the picture beneath it.
        .allowsHitTesting(enabled)
        .opacity(enabled ? 1 : 0)
        .accessibilityLabel(label)
    }

    /// Pages the spotlight by one title in either direction, with the same animation a swipe settles with.
    private func page(by step: Int) {
        let target = min(max(currentIndex + step, 0), items.count - 1)
        guard target != currentIndex else { return }
        withAnimation(.snappy(duration: 0.35)) { pageID = items[target].identity }
    }
    #endif

    var body: some View {
        let preferred = metrics.heroHeight(forContainerHeight: containerHeight) + 100
        let portrait = TitleHero.height(width: containerWidth, metrics: metrics) + captionBelow
        Color.clear
            .frame(maxWidth: .infinity)
            .frame(height: isLandscape ? min(containerHeight, preferred) : portrait)
            .overlay {
                GeometryReader { geometry in
                    // Pulled past the top, the spotlight stretches with the pull, in both orientations, so no black shows above it; its
                    // caption stays where it was. Landscape used to keep its height and left a black gap.
                    let pull = heroPull
                    let height = geometry.size.height + pull
                    TabView(selection: $pageID) {
                        ForEach(Array(items.enumerated()), id: \.element.identity) { index, item in
                            HeroPage(item: item, isScrolling: isHomeScrolling, artworkHeight: height - captionBelow,
                                     cachedArtwork: ratings.cachedHeroArtwork(for: item),
                                     cachedCertification: ratings.cachedCertification(for: item), distance: abs(index - currentIndex))
                                .frame(width: geometry.size.width, height: height)
                                .clipped()
                                .tag(Optional(item.identity))
                        }
                    }
                    .tabViewStyle(.page(indexDisplayMode: .never))
                    // Plays once each time Home returns from a title (the revision changes), never on first appearance. It starts a little
                    // larger and the frame below clips it, so the picture always reaches the screen's edges: started smaller, it showed
                    // black borders round the picture until it settled.
                    .heroSettle(trigger: router.spotlightRevision)
                    .frame(width: geometry.size.width, height: height)
                    .clipped()
                    .offset(y: -pull)
                    .onChange(of: pageID) { oldID, newID in
                        guard let oldID, let newID, oldID != newID,
                              items.contains(where: { $0.identity == oldID }) else { return }
                        // A whole page of content is replaced, so this is the harder click rather than the standard tap.
                        Haptics.scrollSnap()
                    }
                    .onAppear {
                        if !items.contains(where: { $0.identity == pageID }) {
                            pageID = items.first?.identity
                        }
                    }
                }
            }
            .overlay(alignment: .bottom) {
                if items.count > 1 { pageDots(bottom: isLandscape ? Theme.Spacing.m : 0) }
            }
            #if targetEnvironment(macCatalyst)
            .onHover { isHoveringSpotlight = $0 }
            .overlay {
                if isHoveringSpotlight && items.count > 1 { pageArrows }
            }
            #endif
    }

    /// The page dots. In portrait they sit at the page's bottom edge, under the metadata line, which now runs lower (see `HeroPage.pageContent`),
    /// so a line that wraps to two lines still clears them.
    private func pageDots(bottom: CGFloat) -> some View {
        HStack(spacing: 6) {
            ForEach(items, id: \.identity) { item in
                let isCurrent = item.identity == (pageID ?? items.first?.identity)
                Capsule()
                    .fill(.white.opacity(isCurrent ? 0.95 : 0.35))
                    .frame(width: isCurrent ? 16 : 6, height: 6)
            }
        }
        .animation(.snappy(duration: 0.25), value: pageID)
        .padding(.bottom, bottom)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// The grey stand-in for the spotlight, the same size as a page, shimmering while the items load.
struct HeroPlaceholder: View {
    @Environment(\.layoutMetrics) private var metrics
    @Environment(\.isPhoneLandscape) private var isPhoneLandscape
    /// The landscape form: a phone turned sideways, or any Mac window.
    private var isLandscape: Bool { isPhoneLandscape || HeroCarousel.isMacCatalyst }
    @Environment(\.heroContainerHeight) private var containerHeight
    @Environment(\.heroContainerWidth) private var containerWidth
    /// Scaled with Dynamic Type like the spotlight's band, so the placeholder is the same height as the page it stands for.
    @ScaledMetric(relativeTo: .footnote) private var captionBelow: CGFloat = TitleHero.captionBelow
    var body: some View {
        let preferred = metrics.heroHeight(forContainerHeight: containerHeight) + 100
        let portrait = TitleHero.height(width: containerWidth, metrics: metrics) + captionBelow
        Color.clear
            .frame(maxWidth: .infinity)
            .frame(height: isLandscape ? min(containerHeight, preferred) : portrait)
            .background { Rectangle().fill(Theme.surface) }
            .shimmering()
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Loading")
    }
}

/// One hero page of the spotlight, using a separate image for each orientation.
private struct HeroPage: View {
    let item: MetaPreview
    let isScrolling: Bool
    /// The picture's height in portrait: the page less the caption band under it, so a pull stretches the picture too.
    let artworkHeight: CGFloat
    /// Pages between this one and the one on screen. Only pages inside `HeroCarousel.loadWindow(isLandscape:)` load their picture.
    let distance: Int
    @Environment(\.loadsVisibleArtwork) private var sectionIsVisible
    @Environment(AppRouter.self) private var router
    @Environment(\.layoutMetrics) private var metrics
    @Environment(\.heroContainerWidth) private var containerWidth
    @Environment(\.isPhoneLandscape) private var isPhoneLandscape
    /// The landscape form: a phone turned sideways, or any Mac window.
    private var isLandscape: Bool { isPhoneLandscape || HeroCarousel.isMacCatalyst }
    /// The portrait band under the picture, scaled with Dynamic Type the same way as the spotlight's (see `TitleHero.captionBelow`).
    @ScaledMetric(relativeTo: .footnote) private var captionBelow: CGFloat = TitleHero.captionBelow
    @Environment(PosterRatingsStore.self) private var ratings
    /// The titles' fuller details, shared with the title page. Optional, so a preview without it still draws the item's own line.
    @Environment(HeroMetaStore.self) private var heroMeta: HeroMetaStore?
    /// Starts from the artwork already looked up this session, so a title coming back into view shows its logo and picture at once.
    @State private var heroArtwork: TMDbArtwork?
    /// Set once the TMDb artwork lookup has finished, so a title with no logo can fall back to its name. Starts set when the artwork is known.
    @State private var artworkChecked: Bool
    @State private var hero = HeroLoader()
    /// The age rating in the metadata line. Starts from the one already looked up this session.
    @State private var certification: String?
    /// Set once the title's details have answered, or could not, so the grey lines give way to the metadata line and the synopsis.
    @State private var detailsSettled = false

    init(item: MetaPreview, isScrolling: Bool, artworkHeight: CGFloat, cachedArtwork: TMDbArtwork?, cachedCertification: String?,
         distance: Int) {
        self.distance = distance
        self.item = item
        self.isScrolling = isScrolling
        self.artworkHeight = artworkHeight
        _heroArtwork = State(initialValue: cachedArtwork)
        _artworkChecked = State(initialValue: cachedArtwork != nil)
        _certification = State(initialValue: cachedCertification)
    }

    private var isInWindow: Bool { sectionIsVisible && distance == 0 }
    /// The nearest two pages jump the queue; the next one waits behind them.
    private var loadPriority: TaskPriority { distance <= 1 ? .high : .medium }

    private var heroURL: URL? {
        (isLandscape ? heroArtwork?.backdrop : heroArtwork?.portrait)
            ?? (artworkChecked ? (item.background ?? MetahubArtwork.background(imdbID: item.id)) : nil)
    }
    private var heroPixelSize: CGFloat { isLandscape ? TitleHero.landscapePixelSize : TitleHero.portraitPixelSize }
    /// Portrait only, and only when the picture carries the title: the logo is neither loaded nor drawn, its space is kept.
    private var hidesLogo: Bool { !isLandscape && heroArtwork?.portraitHidesLogo == true }
    private var logoURL: URL? { hidesLogo ? nil : (item.logo ?? heroArtwork?.logo) }
    private var pictureSlot: HeroSlot { hero.slot(url: heroURL, maxPixelSize: heroPixelSize, lookupFinished: artworkChecked) }
    private var logoSlot: HeroSlot { hero.slot(url: logoURL, maxPixelSize: HeroLoader.logoPixelSize, lookupFinished: artworkChecked) }
    private var isRevealed: Bool { HeroLoader.isRevealed(pictureSlot, logoSlot) }

    /// The metadata line, built by the shared store from the same details as the title page's. Its score is IMDb's own when the dataset on
    /// the device has the title, else the catalog's, as on the title page. Without the store, the item's own line.
    private var metaParts: [String?] {
        if let heroMeta { return heroMeta.parts(for: item, certification: certification, ratings: ratings) }
        return DetailViewModel.heroMetaParts(for: item, certification: certification,
                                             imdbRating: ratings.ratings(for: item, includeReviews: true, source: .imdb).imdb)
    }

    /// True while the metadata line and the synopsis wait for the title's details: grey lines stand in their places, at their sizes.
    private var awaitsDetails: Bool {
        guard let heroMeta else { return false }
        return heroMeta.kept(for: item) == nil && !detailsSettled
    }

    /// The title's synopsis: its details' own, loaded with the metadata line, else the catalog's. Nil when there is none.
    private var synopsis: String? {
        let text = (heroMeta?.preview(for: item) ?? item).description?.trimmingCharacters(in: .whitespacesAndNewlines)
        return text?.isEmpty == false ? text : nil
    }

    /// The metadata line in a slot of one line's height, whatever it holds, or a grey line across it while the details load: as wide as the
    /// line spreads in portrait, as wide as a short line in landscape.
    private func metaLine(spreads: Bool) -> some View {
        Text(verbatim: " ")
            .font(Theme.Typography.metaLine)
            .frame(maxWidth: .infinity)
            .accessibilityHidden(true)
            .overlay {
                if awaitsDetails {
                    HeroSkeletonLine()
                        .padding(.horizontal, spreads ? 24 : 0)
                        .frame(width: spreads ? nil : 170)
                        .accessibilityHidden(true)
                } else {
                    MetaLine(metaParts, genres: metaGenres, identifier: "hero.metaLine", spreads: spreads)
                        .multilineTextAlignment(.center)
                }
            }
            .animation(.easeOut(duration: 0.2), value: awaitsDetails)
    }

    /// Two lines of the synopsis, a little see-through, cut short with an ellipsis. The two lines' room is kept whatever the text, and two
    /// grey lines stand in while the details load, so nothing moves when the text arrives.
    private var synopsisLines: some View {
        Text(verbatim: awaitsDetails ? " " : (synopsis ?? " "))
            .font(Theme.Typography.metaLine)
            .foregroundStyle(.white.opacity(0.72))
            .multilineTextAlignment(.center)
            .lineLimit(2, reservesSpace: true)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity)
            .overlay {
                if awaitsDetails {
                    VStack(spacing: 8) {
                        HeroSkeletonLine().padding(.horizontal, 10)
                        HeroSkeletonLine().padding(.horizontal, 56)
                    }
                }
            }
            .animation(.easeOut(duration: 0.2), value: awaitsDetails)
            .accessibilityHidden(awaitsDetails || synopsis == nil)
            .accessibilityIdentifier("hero.synopsis")
    }

    /// The genres in the metadata line, the same ones `metaParts` shows. `MetaLine` drops them first when the line is too long.
    private var metaGenres: [String] {
        if let heroMeta { return heroMeta.genres(for: item) }
        return DetailViewModel.heroMetaGenres(for: item)
    }

    /// The picture and logo this page shows now, for the title page it opens. A picture or logo still loading is left out.
    private var handoff: HeroHandoff {
        var picture: HeroHandoff.Resolved?
        if case .ready(let image) = pictureSlot, let url = heroURL {
            picture = HeroHandoff.Resolved(url: url, maxPixelSize: heroPixelSize, image: image)
        }
        var logo: HeroHandoff.Resolved?
        if case .ready(let image) = logoSlot, let url = logoURL {
            logo = HeroHandoff.Resolved(url: url, maxPixelSize: HeroLoader.logoPixelSize, image: image)
        }
        return HeroHandoff(picture: picture, logo: logo)
    }

    var body: some View {
        // The title page repeats the picture and logo in the same place, so it replaces Home with no animation.
        let openTitle = {
            Haptics.tap()
            let destination = TitleDestination(preview: item, sourceID: "hero", artwork: heroArtwork, artworkChecked: artworkChecked,
                                               opensInstantly: true, handoff: handoff)
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) { router.homePath.append(destination) }
            router.spotlightDepth = router.homePath.count
        }
        pageContent
        .overlay(alignment: .top) {
            // A tap anywhere on the page opens the title, but never claims a drag or disables views during one.
            Color.clear
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .simultaneousGesture(TapGesture().onEnded {
                    guard !isScrolling else { return }
                    openTitle()
                })
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(item.name)
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { openTitle() }
        }
        .overlay(alignment: .bottomTrailing) {
            if isLandscape {
                PosterRatingsOverlay(item: item, isLandscape: true)
                    .padding(.horizontal, metrics.pageMargin)
                    .padding(.bottom, Theme.Spacing.m)
                    .allowsHitTesting(false)
            }
        }
        .heroPointerHighlight()
        .coordinateSpace(name: "hero/\(item.identity)")
        .task(id: "\(ratings.reviewServicesRevision)|\(isInWindow)") {
            guard isInWindow else { return }
            let loaded = await ratings.heroArtwork(for: item)
            guard !Task.isCancelled else { return }
            heroArtwork = loaded
            artworkChecked = true
        }
        // The age rating has its own task, so it never holds the picture back.
        .task(id: "certification|\(ratings.reviewServicesRevision)|\(isInWindow)") {
            guard isInWindow else { return }
            let loaded = await ratings.certification(for: item)
            guard !Task.isCancelled else { return }
            certification = loaded
        }
        .task(id: "meta|\(isInWindow)") {
            // Only the current page asks for details.
            guard isInWindow else { return }
            await heroMeta?.load(for: item)
            guard !Task.isCancelled else { return }
            detailsSettled = true
        }
        // The title's Play colour is read while its page is on show, as a poster card reads it, so its title page has the colour on the
        // first frame: a dull poster takes the logo's colour, and the title page only reads a logo that is already loaded. Asked again
        // once the page reveals, when its stand-in poster has surely loaded.
        .task(id: "play-colour|\(isInWindow)|\(isRevealed)") {
            guard isInWindow else { return }
            await PlayColourStore.shared.read(identity: item.identity, pictures: PlayColourStore.pictures(for: item),
                                              logos: PlayColourStore.logos(for: item))
        }
        .task(id: "\(heroURL?.absoluteString ?? "-")|\(heroPixelSize)|\(logoURL?.absoluteString ?? "-")|\(artworkChecked)|\(isInWindow)|\(distance <= 1)") {
            // Out of the window the page lets go of its picture (its logo stays in the shared store) so memory stays bounded.
            guard isInWindow else { hero.release(keeping: []); return }
            // After a rotation the other orientation's picture goes too.
            hero.release(keeping: heroURL.map { [($0, heroPixelSize)] } ?? [])
            await hero.load(priority: loadPriority, picture: heroURL, pictureSize: heroPixelSize, logo: logoURL, logoSize: HeroLoader.logoPixelSize)
        }
    }

    /// Landscape keeps the caption over the picture. Portrait stops the picture above a band that holds the metadata, and the title sits low
    /// on the picture, where the title page puts it too (see `TitleHero.portraitDrop`).
    @ViewBuilder
    private var pageContent: some View {
        if isLandscape {
            ZStack(alignment: .bottom) {
                artwork
                    .allowsHitTesting(false)
                // Keep the fade outside the zoom source so a cancelled press cannot hide it. The same fade the title page's hero uses,
                // and the only shading on the picture.
                BottomFade(length: 0.42)
                caption
                    .allowsHitTesting(false)
            }
        } else {
            let visibleHeight = TitleHero.visibleHeight(
                artworkHeight, logoHeight: TitleHero.logoHeight(logoSlot, hidden: hidesLogo, width: containerWidth - metrics.contentMargin * 2))
            VStack(spacing: 0) {
                // The title sits `portraitDrop` below the picture's edge, and the metadata line under it starts there too. The band gives up
                // the same height, so the page keeps its size.
                portraitTitle
                    .frame(height: artworkHeight + TitleHero.portraitDrop, alignment: .bottom)
                // The metadata line and the synopsis under it, centred within the page's margins, above the page dots.
                VStack(spacing: Theme.Spacing.xs) {
                    metaLine(spreads: true)
                    synopsisLines
                }
                .allowsHitTesting(false)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, metrics.contentMargin)
                .frame(height: captionBelow - TitleHero.portraitDrop, alignment: .top)
            }
            .foregroundStyle(.white)
            // The picture is zoomed, so it is taller than the hero and runs behind the metadata line. The page clips what passes its bottom.
            .background(alignment: .top) {
                artwork
                    .frame(height: TitleHero.pictureHeight(artworkHeight))
                    .frame(height: visibleHeight, alignment: .top)
                    .clipped()
                    .overlay(alignment: .bottom) {
                        // Runs a little past the picture's bottom edge (the picture's height is fractional), so no row of picture shows under it.
                        BottomFade(length: TitleHero.fadeLength(height: artworkHeight, visible: visibleHeight),
                                   strength: TitleHero.fadeStrength)
                            .padding(.bottom, -TitleHero.fadeOverscan)
                    }
                    .allowsHitTesting(false)
            }
        }
    }

    /// The portrait title, low on the picture, with the same gap above the metadata line as on the title page.
    private var portraitTitle: some View {
        HeroTitleArt(name: item.name, slot: logoSlot, alignment: .center, compact: false, hidden: hidesLogo)
            .frame(maxWidth: .infinity, alignment: .center)
            // Hidden until the hero reveals, and its space is kept while the logo is pending.
            .opacity(isRevealed ? 1 : 0)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(item.name)
            .accessibilityAddTraits(.isHeader)
            .allowsHitTesting(false)
            .padding(.horizontal, metrics.contentMargin)
            .padding(.bottom, TitleHero.logoTextGap)
    }

    /// The picture fills its page in both orientations. A landscape phone is wider than the 16:9 backdrop, so fitting the picture left a
    /// black bar down each side; filling crops a little off the bottom instead, under the fade and the caption.
    private var artwork: some View {
        Color.clear
            .overlay {
                if isInWindow {
                    HeroPicture(slot: pictureSlot, isRevealed: isRevealed, contentMode: .fill, preview: item,
                                standInFromBackdrop: HeroCarousel.isMacCatalyst)
                }
            }
    }

    /// The landscape title, its logo, the metadata line and the synopsis.
    private var caption: some View {
        VStack(alignment: .center, spacing: Theme.Spacing.s) {
            titleBlock
                .allowsHitTesting(false)
            metaLine(spreads: false)
                .allowsHitTesting(false)
            synopsisLines
                .frame(maxWidth: 560)
                .allowsHitTesting(false)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, metrics.pageMargin)
        // Room for the page dots beneath the metadata.
        .padding(.bottom, 44)
        .frame(maxWidth: .infinity, alignment: .center)
    }

    /// The landscape logo in its fixed box, the name when there is no logo, and blank while the logo is pending. Hidden until the hero reveals.
    private var titleBlock: some View {
        Group {
            switch logoSlot {
            case .ready(let image):
                // Fades with the container, on the same curve as the picture.
                HeroLogo(image: image)
                    .transition(.identity)
            case .none:
                Text(item.name)
                    .font(.largeTitle.bold())
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
            case .pending:
                Color.clear.frame(width: HeroLogo.box.width, height: HeroLogo.box.height)
            }
        }
        .opacity(isRevealed ? 1 : 0)
    }
}

/// A grey line standing in for a line of text in the spotlight while it loads.
private struct HeroSkeletonLine: View {
    var body: some View {
        Capsule()
            .fill(.white.opacity(0.16))
            .frame(height: 9)
            .shimmering()
    }
}
#endif
