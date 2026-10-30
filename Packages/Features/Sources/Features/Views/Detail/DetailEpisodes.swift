#if canImport(UIKit)
import SwiftUI
import StremioKit
import UIKit

/// A series' seasons and episodes: the season picker and width toggle, then artwork cards with integrated information and progress.
struct DetailEpisodes: View {
    let model: DetailViewModel
    let pageWidth: CGFloat
    let pageHeight: CGFloat
    let contentMargin: CGFloat
    /// True while an episode's menu is open, so the page can blur behind it. Cleared when this view leaves the screen.
    @Binding var isHoldingEpisode: Bool
    /// Shuffle and a tapped episode hand their episode to the page's stream flow, the one Play uses, saying which of them asked: the
    /// streams take the details' place once they are ready.
    let play: (StreamRequest, StreamTrigger) -> Void
    /// The request whose streams are loading, from Play, Shuffle or an episode. Shuffle and the episodes take no taps then, since a tap
    /// would call that lookup off or start a second one.
    var loadingRequest: StreamRequest?
    /// What asked for the loading streams. Only that control shows a spinner: Shuffle in place of its symbol, an episode on its card.
    var loadingTrigger: StreamTrigger?
    var unavailableStreams: Set<String> = []

    private var isLoadingStreams: Bool { loadingRequest != nil }
    @Environment(\.layoutMetrics) private var metrics
    @Environment(\.isLandscape) private var isLandscape
    @Environment(TitleActions.self) private var titleActions
    /// The episode Shuffle last picked: the row scrolls it to the front of its season.
    @State private var shuffledEpisode: String?
    /// Whether the episode Shuffle plays next is named beside it. Hidden until the space beside Shuffle is tapped; a second tap hides it.
    @State private var showsShuffleNext = false
    /// The name's size: a little under `caption2`, and scaled with the text size.
    @ScaledMetric(relativeTo: .caption2) private var shuffleNextSize: CGFloat = 10
    /// Handed on to an episode's menu preview, which is drawn outside the page and does not get the page's environment.
    @Environment(PosterRatingsStore.self) private var ratings: PosterRatingsStore?

    /// The height of the season picker and of the episode-width toggle, so the two sit level on one line.
    private static let secondaryControlHeight: CGFloat = 32

    /// The Shuffle symbol, unseen, behind the season picker's and the width toggle's labels. The glass around a label is the label's height
    /// plus the same padding, and Shuffle's symbol stands half a point taller than the season name and the width symbol, so with it behind
    /// them all three glass shapes are the same height. The season name is wider than it, and the width toggle keeps its fixed square.
    private static var glassHeightReference: some View {
        Image(systemName: "shuffle").font(.caption.weight(.semibold)).hidden().accessibilityHidden(true)
    }

    /// The space inside an episode's menu preview, so the menu's rounded corners do not cut into the still or the text.
    private static let previewPadding: CGFloat = Theme.Spacing.m
    /// The corner radius of the panel the system draws an episode's menu preview in: 32 pt, measured on an iPhone on iOS 27. The system
    /// does not say what it is and does not let a preview set it. The preview's hairline uses it, so it follows the panel's edge.
    private static let previewPanelRadius: CGFloat = 32
    /// The still's corner radius in the preview: the panel's less the padding between them, so the two corners share a centre and the
    /// gap between the still and the panel is the same round the corner as along the sides. With the panel's own radius the gap grew
    /// at the corners, which read as slightly off.
    private static let previewStillRadius: CGFloat = previewPanelRadius - previewPadding
    /// The IMDb mark in the episode menus, in points. Both menus draw it at this size: the asset is 48 points, far larger than the check marks.
    private static let menuLogoSize: CGFloat = 16

    var body: some View {
        let width = episodeWidth(pageWidth: pageWidth)
        return VStack(alignment: .leading, spacing: Theme.Spacing.l) {
            HStack(spacing: Theme.Spacing.m) {
                seasonMenu
                shuffleButton
                shuffleNextArea
                episodeWidthToggle
            }
            .padding(.horizontal, contentMargin)
            ScrollViewReader { proxy in
                ShelfScroll(margin: contentMargin, spacing: metrics.cardSpacing,
                            resetKey: "\(model.selectedSeason ?? -1):\(Int(width))") {
                    if model.isLoading && model.episodes.isEmpty {
                        ForEach(0..<3, id: \.self) { index in
                            VStack(alignment: .leading, spacing: 0) {
                                Theme.placeholder
                                    .frame(width: width, height: width / CardAspect.wide.ratio)
                                    .loadingCardSpinner()
                                VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                                    DetailSkeletonLine(font: Theme.Typography.eyebrow, width: 70)
                                    DetailSkeletonParagraph(style: .footnote, lines: 2)
                                    DetailSkeletonParagraph(style: .caption1, lines: 2)
                                    DetailSkeletonLine(font: .caption2, width: width * 0.65)
                                }
                                .padding(Theme.Spacing.s)
                            }
                            .frame(width: width)
                            .background(Theme.placeholder)
                            .mediaArtwork(cornerRadius: Theme.Radius.card)
                            .reportsShelfEdge(id: index)
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel("Loading episode")
                        }
                    }
                    ForEach(model.episodes) { episode in
                        episodeRow(episode, width: width)
                            .id(episode.id).reportsShelfEdge(id: episode.id)
                    }
                }
                .animation(.snappy, value: model.matchesEpisodeWidthToText)
                // Shuffle's episode becomes the first card in view, in its season, once the row has laid that season out.
                .task(id: shuffledEpisode) {
                    guard let shuffledEpisode else { return }
                    try? await Task.sleep(for: .milliseconds(80))
                    withAnimation(.snappy) { proxy.scrollTo(shuffledEpisode, anchor: .leading) }
                }
            }
        }
        .detailLoadingTransition(model.isLoading)
        .environment(\.showsArtworkLoadingSpinner, true)
        // Season data belongs to the shelf, so newly visible cards do no lookup work during a swipe.
        .task(id: "\(model.selectedSeason ?? -1):\(model.reviewServicesRevision):\(model.isLoading):\(model.hasSettledHero)") {
            guard model.hasSettledHero else { return }
            await model.loadEpisodeSeason(model.selectedSeason)
        }
        // A page that is left never stays blurred, even if its episode's menu was still open.
        .onDisappear { isHoldingEpisode = false }
    }

    /// The season name with its chevron. Choosing opens the list of seasons, and the mark-as-watched action for the selected one.
    private var seasonMenu: some View {
        Menu {
            ForEach(model.seasons, id: \.self) { season in
                Button(season == 0 ? "Specials" : "Season \(season)") {
                    if model.selectedSeason != season { Haptics.selection() }
                    model.selectedSeason = season
                }
            }
            if let season = model.selectedSeason {
                Divider()
                let watched = model.isSeasonWatched(season)
                let name = season == 0 ? "Specials" : "Season \(season)"
                Button(watched ? "Mark \(name) as Not Watched" : "Mark \(name) as Watched",
                       systemImage: watched ? "xmark.circle" : "checkmark.circle") {
                    Task {
                        await model.setSeasonWatched(!watched, season: season)
                        await titleActions.refresh()
                    }
                }
                .accessibilityIdentifier("detail.seasonWatched")
            }
        } label: {
            ZStack {
                Self.glassHeightReference
                HStack(spacing: 4) {
                    Text(model.selectedSeason == 0 ? "Specials" : "Season \(model.selectedSeason ?? 1)").font(.subheadline.weight(.semibold))
                    Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold)).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: Self.secondaryControlHeight)
            .glassEffect(.regular.interactive().tint((Theme.playControlColour(hex: model.playColourHex) ?? .clear)), in: .capsule)
        }
        .buttonStyle(.plain)
        .frame(height: Self.secondaryControlHeight)
        .pointerFeedback()
        .accessibilityIdentifier("detail.seasonPicker")
    }

    /// The space between Shuffle and the width toggle. With an episode picked, a tap there names the episode Shuffle plays next, very
    /// small after a dash, and another tap hides it again. Without one it is only space.
    @ViewBuilder
    private var shuffleNextArea: some View {
        if let next = model.shuffleNext, model.canShuffle {
            let number = [next.season.map { "S\($0)" }, next.episode.map { "E\($0)" }].compactMap { $0 }.joined()
            let name = number.isEmpty ? next.title : "\(number) · \(next.title)"
            ZStack(alignment: .leading) {
                if showsShuffleNext {
                    Text(verbatim: "- \(name)")
                        .font(.system(size: shuffleNextSize))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .transition(.opacity)
                        .accessibilityIdentifier("detail.shuffleNext")
                }
            }
            .frame(maxWidth: .infinity, minHeight: Self.secondaryControlHeight, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.easeInOut(duration: 0.2)) { showsShuffleNext.toggle() }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(showsShuffleNext ? "Shuffle plays \(next.title) next" : "Show the episode Shuffle plays next")
            .accessibilityIdentifier("detail.shuffleNextArea")
        } else {
            Spacer(minLength: 0)
        }
    }

    /// Shuffle, beside the season picker: a random episode that has aired, whose streams show as Play's do. While they load, a thin
    /// spinner takes the place of its symbol, at the same size. It is dimmed while there is nothing to pick, and takes no taps while any
    /// streams are loading. Only shown for a series, as this whole list is.
    private var shuffleButton: some View {
        let isShuffling = loadingTrigger == .shuffle
        return Button {
            guard !SwipeRecord.latest.isSwipe(at: ContinuousClock.now) else { return }
            // The episode's season opens with its card first in view, and its streams load (at once the first time: they were
            // looked up as the page opened).
            if let video = model.takeShuffle() {
                if let season = video.season { model.selectedSeason = season }
                shuffledEpisode = video.id
                play(model.request(for: video), .shuffle)
            }
        } label: {
            Image(systemName: "shuffle")
                .font(.subheadline.weight(.semibold))
                .opacity(isShuffling ? 0 : 1)
                .overlay {
                    if isShuffling {
                        Spinner()
                            .controlSize(.small)
                            .transition(.opacity)
                    }
                }
                .animation(.smooth(duration: 0.2), value: isShuffling)
                // The same grey as the trailer's symbol beside the title's other buttons.
                .foregroundStyle(.white.opacity(0.6))
        }
        .glassCircleButton(.regular)
        .frame(width: Self.secondaryControlHeight, height: Self.secondaryControlHeight)
        .disabled(!model.canShuffle)
        .opacity(model.canShuffle ? 1 : 0.4)
        .allowsHitTesting(!isLoadingStreams)
        .titleTapHaptic()
        .help("Shuffle")
        .accessibilityLabel("Shuffle")
        .accessibilityHint("Picks a random episode that has aired")
        .accessibilityIdentifier("detail.shuffleButton")
    }

    /// Switches the episode cards between their fixed width and the width of the text. The symbol shows the layout in use: a row of
    /// cards, or one card across the page.
    private var episodeWidthToggle: some View {
        let isWide = model.matchesEpisodeWidthToText
        return Button {
            Task { await model.setMatchesEpisodeWidthToText(!isWide) }
        } label: {
            ZStack {
                Self.glassHeightReference
                Image(systemName: isWide ? "rectangle" : "rectangle.split.3x1")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.6))
                    .contentTransition(.symbolEffect(.replace))
            }
        }
        .glassCircleButton(.regular)
        .frame(width: Self.secondaryControlHeight, height: Self.secondaryControlHeight)
        .titleTapHaptic()
        .accessibilityLabel("Episode width")
        .help("Episode width")
        .accessibilityValue(isWide ? (isLandscape ? "Wide" : "Full width") : "Fixed width")
        .accessibilityIdentifier("detail.episodeWidthToggle")
    }

    /// Wide mode fills the text column in portrait and uses a compact wider card in landscape. Normal cards match the reviews.
    private func episodeWidth(pageWidth: CGFloat) -> CGFloat {
        model.matchesEpisodeWidthToText ? min(max(1, pageWidth - contentMargin * 2), isLandscape ? metrics.episodeWidth * 1.5 : .infinity)
            : min(max(1, pageWidth - contentMargin * 2), metrics.episodeWidth)
    }

    private func episodeRow(_ video: Video, width: CGFloat) -> some View {
        let airsLater = !video.hasAired()
        let request = model.request(for: video)
        let hasNoStreams = unavailableStreams.contains(request.identity)
        let card = Button {
            // As Shuffle does: the episode's streams load on this page, with a spinner on its card only, and replace the details once
            // ready. One lookup at a time, so a second tap does not call it off or open another. A swipe that ends on the card, such as
            // one going back, plays nothing, as on a stream's card.
            guard !isLoadingStreams, !SwipeRecord.latest.isSwipe(at: ContinuousClock.now) else { return }
            play(request, .episode)
        } label: {
            episodeCard(video, width: width, airsLater: airsLater,
                        isLoadingStreams: loadingTrigger == .episode && loadingRequest?.id == request.id)
            .overlay(alignment: .topLeading) {
                if hasNoStreams {
                    Text("No streams")
                        .font(.caption).foregroundStyle(.white)
                        .padding(Theme.Spacing.s)
                        .background(.black.opacity(0.5), in: Capsule())
                        .padding(Theme.Spacing.s)
                }
            }
            // The whole card is its hit area, so a hold or tap on the text counts as on the artwork.
            .contentShape(Rectangle())
        }
        #if targetEnvironment(macCatalyst)
        .buttonStyle(PressableCardStyle(addsSystemHighlight: false, tracksPointer: true))
        #else
        .buttonStyle(PressableCardStyle())
        #endif
        .allowsHitTesting(!isLoadingStreams)
        // An episode that has not aired cannot be opened: its card shows the air date instead.
        .disabled(airsLater || hasNoStreams)
        .titleTapHaptic()
        return Group {
            if isLandscape {
                EpisodeContextMenu(content: card, preview: { landscapePreview(video, width: $0) },
                                   previewSize: CGSize(width: max(1, min(400, pageWidth * 0.55)),
                                                       height: pageHeight),
                                   previewCornerRadius: Self.previewPanelRadius,
                                   menu: { landscapeEpisodeMenu(video) }, isPresented: $isHoldingEpisode)
                    .frame(width: width)
            } else {
                card.contextMenu {
                    episodeActions(video)
                } preview: {
                    episodePreview(video, width: pageWidth - contentMargin * 2)
                        .glassHairline(RoundedRectangle(cornerRadius: Self.previewPanelRadius, style: .continuous))
                        .onAppear { isHoldingEpisode = true }
                        .onDisappear { isHoldingEpisode = false }
                }
            }
        }
        .accessibilityIdentifier("detail.episode.\(video.id)")
    }

    private func landscapePreview(_ video: Video, width: CGFloat) -> some View {
        episodePreview(video, width: width)
    }

    /// Portrait and landscape share the same stacked card, padding and panel treatment.
    private func episodePreview(_ video: Video, width: CGFloat) -> some View {
        episodeCard(video, width: max(1, width - Self.previewPadding * 2), airsLater: !video.hasAired(),
                    stillRadius: Self.previewStillRadius, showsWholeOverview: true)
            .padding(Self.previewPadding)
            .environment(ratings)
    }

    /// The same actions as the portrait menu, supplied directly to UIKit for the sized landscape preview (including on Catalyst).
    private func landscapeEpisodeMenu(_ video: Video) -> UIMenu {
        let request = model.request(for: video)
        let watched = model.isWatched(video)
        let downloaded = model.downloadManager?.item(for: request) != nil
        // The palette's titles do not show in the landscape preview, so Watched and Download carry their captions in their images.
        // Each symbol fills while its state holds.
        let watchedAction = UIAction(title: "Watched",
                                     image: Self.paletteItem(Self.paletteSymbol(watched ? "checkmark.circle.fill" : "checkmark.circle"),
                                                             caption: "Watched", mode: .alwaysTemplate)) { _ in
            Task { @MainActor in
                await model.setWatched(!watched, for: request)
                await titleActions.refresh()
            }
        }
        let downloadAction = UIAction(title: "Download",
                                      image: Self.paletteItem(Self.paletteSymbol(downloaded ? "arrow.down.circle.fill" : "arrow.down.circle"),
                                                              caption: "Download", mode: .alwaysTemplate)) { _ in
            // A UIAction is not on the main actor, so the haptic has to come back to it.
            Task { @MainActor in Haptics.tap(); await model.download(request) }
        }
        let imdbMode: UIImage.RenderingMode = ratings?.showsColouredLogos == true ? .alwaysOriginal : .alwaysTemplate
        let imdbAction = UIAction(title: "IMDb", image: Self.paletteItem(Self.menuIMDbLogo(), caption: nil, mode: imdbMode)) { _ in
            Task { @MainActor in
                guard let ratings else { return }
                await EpisodeIMDbReviews.open(request, ratings: ratings)
            }
        }
        let controls = UIMenu(options: [.displayInline, .displayAsPalette], children: [watchedAction, downloadAction, imdbAction])
        controls.preferredElementSize = .large
        let watchedThroughSymbol = model.isWatchedThrough(video) ? "checkmark.circle.fill" : "checkmark.circle"
        let watchedThroughAction = UIAction(title: "All previous episodes watched",
                                            image: UIImage(systemName: watchedThroughSymbol)) { _ in
            Task { @MainActor in
                await model.markEpisodesWatched(through: video)
                await titleActions.refresh()
            }
        }
        return UIMenu(children: [controls, UIMenu(options: .displayInline, children: [watchedThroughAction])])
    }

    /// Each palette item is one image: its glyph in a row of `paletteGlyphSide` points, with its caption, if any, under it. Every item is the
    /// height of a captioned one, so the glyphs line up whether or not they have a caption.
    private static let paletteGlyphSide: CGFloat = 22
    private static var paletteCaptionFont: UIFont { .systemFont(ofSize: 10, weight: .medium) }
    private static var paletteCaptionAttributes: [NSAttributedString.Key: Any] {
        [.font: paletteCaptionFont, .foregroundColor: UIColor.black]
    }

    private static func paletteSymbol(_ name: String) -> UIImage? {
        UIImage(systemName: name, withConfiguration: UIImage.SymbolConfiguration(pointSize: 20, weight: .regular))
    }

    /// The IMDb mark at the menu's size: the asset is 48 points, far larger than the glyphs beside it.
    private static func menuIMDbLogo() -> UIImage? {
        guard let logo = UIImage(named: "ReviewIMDb") else { return nil }
        let size = CGSize(width: menuLogoSize, height: menuLogoSize)
        return UIGraphicsImageRenderer(size: size).image { _ in logo.draw(in: CGRect(origin: .zero, size: size)) }
    }

    private static func paletteItem(_ glyph: UIImage?, caption: String?, mode: UIImage.RenderingMode) -> UIImage? {
        guard let glyph else { return nil }
        let captionSize = caption?.size(withAttributes: paletteCaptionAttributes) ?? .zero
        let side = paletteGlyphSide
        let size = CGSize(width: max(side, ceil(captionSize.width)), height: side + 2 + ceil(paletteCaptionFont.lineHeight))
        let image = UIGraphicsImageRenderer(size: size).image { _ in
            glyph.draw(at: CGPoint(x: (size.width - glyph.size.width) / 2, y: (side - glyph.size.height) / 2))
            caption?.draw(at: CGPoint(x: (size.width - captionSize.width) / 2, y: side + 2), withAttributes: paletteCaptionAttributes)
        }
        return image.withRenderingMode(mode)
    }

    @ViewBuilder
    private func episodeActions(_ video: Video) -> some View {
        let request = model.request(for: video)
        let watched = model.isWatched(video)
        let downloaded = model.downloadManager?.item(for: request) != nil
        // The palette holds Watched and Download with their labels, and the IMDb mark alone. Each symbol fills while its state holds.
        ControlGroup {
            Button("Watched", systemImage: watched ? "checkmark.circle.fill" : "checkmark.circle") {
                Task {
                    await model.setWatched(!watched, for: request)
                    await titleActions.refresh()
                }
            }
            Button("Download", systemImage: downloaded ? "arrow.down.circle.fill" : "arrow.down.circle") {
                Haptics.tap()
                Task { await model.download(request) }
            }
            Button {
                guard let ratings else { return }
                Task { await EpisodeIMDbReviews.open(request, ratings: ratings) }
            } label: {
                ReviewSiteIcon(site: .imdb, size: Self.menuLogoSize, keepsColour: true)
            }
            .accessibilityLabel("IMDb")
        }
        Button("All previous episodes watched",
               systemImage: model.isWatchedThrough(video) ? "checkmark.circle.fill" : "checkmark.circle") {
            Task {
                await model.markEpisodesWatched(through: video)
                await titleActions.refresh()
            }
        }
    }

    /// One episode's card at `width`: the card in the list, and the menu's preview at the page's full width. The preview passes
    /// `showsWholeOverview` lets menu previews expand; shelf cards share a fixed information height.
    private func episodeCard(_ video: Video, width: CGFloat, airsLater: Bool, isLoadingStreams: Bool = false,
                             stillRadius: CGFloat = Theme.Radius.card, showsWholeOverview: Bool = false) -> some View {
        EpisodeRow(video: video, fraction: model.progressFraction(for: video), watched: model.isWatched(video),
                   artwork: model.backdropURL, score: model.score(for: video), runtimeMinutes: model.runtimeMinutes(for: video), width: width,
                   showsWholeOverview: showsWholeOverview,
                   isShortWidth: !model.matchesEpisodeWidthToText && !showsWholeOverview, airsLater: airsLater,
                   isLoadingStreams: isLoadingStreams || model.downloadManager?.loadingRequests.contains(model.request(for: video).identity) == true,
                   stillRadius: stillRadius)
            .overlay(alignment: .topTrailing) {
                if let item = model.downloadManager?.item(for: model.request(for: video)) {
                    DownloadProgressGlyph(item: item)
                        .frame(width: 44, height: 44)
                        .background(Theme.surfaceStrong, in: Circle())
                        .padding(8)
                        .allowsHitTesting(false)
                }
            }
    }
}

/// Use the episode's own IMDb ID to open its reviews, preferring the IMDb app.
@MainActor
enum EpisodeIMDbReviews {
    static func open(_ request: StreamRequest, ratings: PosterRatingsStore) async {
        guard let season = request.season, let episode = request.episode else { return }
        let seriesID = ContentID(request.id).baseID
        guard LetterboxdRatings.isIMDbID(seriesID) else { return }
        guard let episodeID = await ratings.imdbEpisodeID(seriesIMDbID: seriesID, season: season, episode: episode) else {
            // Without a reliable episode ID, link to that season instead of inventing an ID.
            if let seasonURL = URL(string: "https://www.imdb.com/title/\(seriesID)/episodes/?season=\(season)") {
                _ = await UIApplication.shared.open(seasonURL)
            }
            return
        }
        guard let appURL = URL(string: "imdb:///title/\(episodeID)/reviews"),
              let webURL = URL(string: "https://www.imdb.com/title/\(episodeID)/reviews/") else { return }
        UIApplication.shared.open(appURL, options: [:]) { opened in
            if !opened { UIApplication.shared.open(webURL) }
        }
    }
}

/// One episode's sharp 16:9 artwork continues downward into a diffused background behind its independently sized information stack.
private struct EpisodeRow: View {
    let video: Video
    let fraction: Double?
    let watched: Bool
    let artwork: URL?
    let score: DetailViewModel.EpisodeScore?
    /// How long the episode runs, in minutes, once TMDb has said.
    var runtimeMinutes: Int?

    private var runtime: String? { runtimeMinutes.map(DetailViewModel.runtimeText(minutes:)) }

    /// The length as VoiceOver reads it: "47 minutes", "1 hour, 2 minutes".
    private var spokenRuntime: String? {
        runtimeMinutes.map { Duration.seconds($0 * 60).formatted(.units(allowed: [.hours, .minutes], width: .wide)) }
    }
    let width: CGFloat
    @ScaledMetric(relativeTo: .caption) private var informationHeight: CGFloat = 128
    @State private var overviewTextHeight: CGFloat = 0
    @State private var overviewFrameHeight: CGFloat = 0
    /// Menu previews show all the text; shelf cards let the synopsis absorb title wrapping inside a fixed height.
    var showsWholeOverview = false
    /// Short cards show a small progress bar in the air-date slot, without adding another row.
    var isShortWidth = false
    /// Set for an episode that has not aired: its still is dimmed, and the card cannot be opened.
    var airsLater = false
    /// Set while this episode's streams load: a spinner over its still, as Play has one.
    var isLoadingStreams = false
    /// The still's corner radius. The menu's preview gives it one that follows its panel's, which is rounder than a card's.
    var stillRadius: CGFloat = Theme.Radius.card

    private var hasProgress: Bool {
        !watched && fraction.map { $0.isFinite && $0 > 0 && $0 < 1 } == true
    }

    /// How far the progress line and the watched mark move in from the still's edges, so a rounder corner does not cut into them.
    private var overlayInset: CGFloat { max(0, stillRadius - Theme.Radius.small) * 0.3 }

    var body: some View {
        stacked
        .environment(\.colorScheme, .dark)
        .multilineTextAlignment(.leading)
        .accessibilityElement(children: .combine)
    }

    private var stacked: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: width / CardAspect.wide.ratio)
            text
                .fixedSize(horizontal: false, vertical: showsWholeOverview)
                .padding(Theme.Spacing.s + overlayInset)
                .frame(width: width, height: showsWholeOverview ? nil : informationHeight, alignment: .topLeading)
        }
        .frame(width: width, alignment: .topLeading)
        .background { still }
        .overlay(alignment: .topTrailing) {
            if watched { checkmark.padding(overlayInset) }
        }
        .overlay {
            if isLoadingStreams {
                ZStack {
                    Color.black.opacity(0.35)
                    Spinner().controlSize(.large)
                }
                .transition(.opacity)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Loading streams")
            }
        }
        .animation(.smooth(duration: 0.25), value: isLoadingStreams)
        .mediaArtwork(cornerRadius: stillRadius)
    }

    /// Keep the synopsis's full space; move only the lower rule into the middle of the gap above the metadata.
    private var text: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            title
                .fixedSize(horizontal: false, vertical: true)
                .layoutPriority(1)
            if hasOverview { hairline }
            overview
                .frame(maxWidth: .infinity, maxHeight: showsWholeOverview ? nil : .infinity, alignment: .topLeading)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { overviewFrameHeight = $0 }
            if hasMetadata {
                hairline
                    .offset(y: hasOverview ? (overviewTextHeight - overviewFrameHeight) / 2 : 0)
            }
            dateAndScore
                .fixedSize(horizontal: false, vertical: true)
                .layoutPriority(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var hasOverview: Bool { video.overview?.isEmpty == false }

    /// Whether the air date, length or score has anything to show, so the metadata line and its hairline are there.
    private var hasMetadata: Bool { video.airDate != nil || hasProgress || runtime != nil || score != nil }

    /// Half a point in `Theme.separator`: a quiet rule between the title, the synopsis and the metadata.
    private var hairline: some View {
        Rectangle().fill(Theme.separator).frame(height: 0.5).accessibilityHidden(true)
    }

    private var title: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            if let episode = video.episode {
                Text("EPISODE \(episode)").font(Theme.Typography.eyebrow).foregroundStyle(.white.opacity(0.75))
            }
            Group {
                if showsWholeOverview {
                    Text(video.title)
                } else {
                    Text(video.title)
                        .lineLimit(2)
                }
            }
            .font(.footnote.weight(.medium))
            .allowsTightening(true)
            .foregroundStyle(.white)
        }
    }

    @ViewBuilder
    private var overview: some View {
        if let overview = video.overview, !overview.isEmpty {
            // Preserve the original line budget. Measuring before padding lets the divider move without resizing the text.
            Text(overview)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.85))
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { overviewTextHeight = $0 }
                .padding(.bottom, showsWholeOverview ? 0 : -Theme.Spacing.xs)
        }
    }

    /// The episode's own still, or the series' backdrop when the addon sent none.
    private var still: some View {
        ArtworkImage(url: video.thumbnail ?? artwork, maxPixelSize: nil, fallbackURL: artwork, extendsArtworkDownward: true)
            .opacity(airsLater ? 0.45 : 1)
    }

    private var checkmark: some View {
        Image(systemName: "checkmark")
            .font(.caption2.weight(.bold))
            .foregroundStyle(.white)
            .frame(width: 20, height: 20)
            .background(.black.opacity(0.6), in: Circle())
            .padding(Theme.Spacing.xs)
            .accessibilityHidden(true)
    }

    /// "Jan 20, 2008 · 47m · [IMDb] 8.9": the air date, the length, then the score with the IMDb mark when it is IMDb's (a star when it is
    /// the addon's).
    @ViewBuilder
    private var dateAndScore: some View {
        let date = video.airDate?.formatted(date: .abbreviated, time: .omitted)
        let showsProgress = hasProgress
        if hasMetadata {
            HStack(spacing: 5) {
                if let date, !isShortWidth || !showsProgress {
                    Text(date)
                    if showsProgress { Text("·") }
                }
                if showsProgress, let fraction {
                    // The bar takes the width the row has to spare, so the score it leads into sits at the text's trailing margin.
                    HStack(spacing: 4) {
                        Image(systemName: "play.fill").font(.system(size: 7, weight: .semibold))
                        Capsule()
                            .fill(.white.opacity(0.3))
                            .overlay(alignment: .leading) {
                                Capsule().fill(.white).scaleEffect(x: fraction, y: 1, anchor: .leading)
                            }
                            .frame(maxWidth: .infinity)
                            .frame(height: 2)
                    }
                    .frame(minWidth: 52, maxWidth: .infinity, alignment: .leading)
                    .foregroundStyle(.white)
                }
                if date != nil || showsProgress, runtime != nil { Text("·") }
                if let runtime { Text(runtime).monospacedDigit() }
                if date != nil || showsProgress || runtime != nil, score != nil { Text("·") }
                if let score {
                    if score.isIMDb {
                        ReviewSiteIcon(site: .imdb, size: 13)
                    } else {
                        Image(systemName: "star.fill").font(.system(size: 9, weight: .bold))
                    }
                    Text(score.text).monospacedDigit()
                    if !score.isIMDb, video.ratingSource == .tmdb { Text("TMDb") }
                }
            }
            .font(.caption2)
            .foregroundStyle(.white.opacity(0.75))
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel([isShortWidth && showsProgress ? nil : date,
                                 showsProgress ? fraction.map { "\(Int(($0 * 100).rounded()))% watched" } : nil,
                                 spokenRuntime, score.map {
                "\($0.isIMDb ? "IMDb rating" : video.ratingSource == .tmdb ? "TMDb rating" : "Rating") \($0.text)"
            }].compactMap { $0 }.joined(separator: ", "))
        }
    }
}
#endif
