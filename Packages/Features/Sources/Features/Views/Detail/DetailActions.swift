#if canImport(UIKit)
import SwiftUI
import StremioKit
import UIKit

/// The title's metadata line, its main action with the round actions beside it, and the note when only basic details are known. Beneath
/// the logo in portrait, beside the artwork in landscape.
struct DetailActions: View {
    let model: DetailViewModel
    @Binding var isConfirmingUnmarkShow: Bool
    /// False leaves only the metadata line, while the page shows its streams in place of the actions.
    var showsActions = true
    /// True while the streams Play asked for are on their way: Play shows a spinner in place of its label, as the trailer button does.
    var isLoadingStreams = false
    /// The main action's movie or episode returned no streams: leave the action visible, labelled and disabled.
    var hasNoStreams = false
    /// True while Shuffle's or an episode's streams load: Play takes no taps then, and looks exactly as it does otherwise.
    var blocksPlay = false
    /// False leaves the metadata line out, for a page that sets the line itself, above its overview and ratings.
    var showsMetaLine = true
    /// The main action's tap: the page shows this title's streams.
    let play: (StreamRequest) -> Void
    @Environment(\.isLandscape) private var isLandscape
    @Environment(TitleActions.self) private var titleActions
    /// Play was tapped while a series' episodes were still arriving: its spinner shows, and it plays once they are in.
    @State private var playsWhenLoaded = false

    /// Whether the text and the actions lead. Beside the artwork on iPhone in landscape; always on the Mac, whose title page sets them over
    /// the picture's left edge.
    #if targetEnvironment(macCatalyst)
    private var leadsText: Bool { true }
    #else
    private var leadsText: Bool { isLandscape }
    #endif

    /// The least width of the Play button's glass on the Mac, so a title's Play is the long button a Mac page needs. iPhone sizes Play
    /// to the row instead.
    private static let playMinWidth: CGFloat = {
        #if targetEnvironment(macCatalyst)
        return 280
        #else
        return 0
        #endif
    }()

    var body: some View {
        // In portrait the Play row keeps the same gap from the line above it as from the overview below it (see `TitleHero.playRowGap`).
        VStack(alignment: leadsText ? .leading : .center, spacing: leadsText ? Theme.Spacing.s : TitleHero.playRowGap) {
            // The line stays on one line wherever it sits: when it is too long, genres go before the rating does.
            if showsMetaLine {
                MetaLine(metaParts, genres: metaGenres, identifier: "detail.metaLine", spreads: true)
                    .multilineTextAlignment(leadsText ? .leading : .center)
            }
            if showsActions {
                VStack(alignment: leadsText ? .leading : .center, spacing: Theme.Spacing.s) {
                    actionRow
                        .downloadErrors(model.downloadManager)
                    if model.isFallback && !model.isLoading {
                        Label("Only basic details are available for this title.", systemImage: "info.circle")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(leadsText ? nil : 1)
                            .accessibilityIdentifier("detail.fallbackNote")
                    }
                }
                .transition(.opacity)
            }
        }
    }

    /// The metadata line, the same text as the spotlight's. It sits above the actions.
    private var metaParts: [String?] { model.heroMetaLine }

    /// The genres in the metadata line, which `MetaLine` drops first when the line is too long.
    private var metaGenres: [String] { model.heroMetaGenres }

    /// The one main action. A movie plays itself; a series plays its next episode. While its streams load it shows a spinner, and a
    /// tap then calls them off. While a series' episodes are still arriving it already takes a tap: it spins, and plays the next episode
    /// once they are in.
    @ViewBuilder
    private var primaryAction: some View {
        primaryButton
            .animation(.smooth(duration: 0.3), value: model.playColourHex)
            .onChange(of: model.isLoading) { _, loading in
                guard !loading, playsWhenLoaded else { return }
                playsWhenLoaded = false
                if let request = model.primaryRequest { play(request) }
            }
    }

    @ViewBuilder
    private var primaryButton: some View {
        if let request = model.primaryRequest {
            let title = hasNoStreams ? "No streams" : model.primaryActionTitle
            Button {
                // A swipe that ends on Play, such as one going back, starts nothing, as on a stream's card.
                guard !SwipeRecord.latest.isSwipe(at: ContinuousClock.now) else { return }
                play(request)
            } label: {
                // The label keeps its place under the spinner, so the button keeps its size.
                Label(title, systemImage: "play.fill")
                    .opacity(isLoadingStreams ? 0 : 1)
                    .overlay {
                        if isLoadingStreams {
                            Spinner()
                                .controlSize(.small)
                                .transition(.opacity)
                        }
                    }
                    .animation(.smooth(duration: 0.25), value: isLoadingStreams)
            }
            .buttonStyle(PrimaryActionButtonStyle(minWidth: Self.playMinWidth, glass: playGlass))
            .disabled(hasNoStreams)
            .allowsHitTesting(!blocksPlay)
            .accessibilityLabel(isLoadingStreams ? "\(title), loading" : title)
            .accessibilityIdentifier("detail.playButton")
        } else if let airs = model.unairedAirLabel {
            // The series' next episode is not out yet: the button is dimmed and shows when it airs, and nothing starts.
            Button {} label: {
                Label(airs, systemImage: "calendar")
            }
            .buttonStyle(PrimaryActionButtonStyle(glass: playGlass))
            .disabled(true)
            .accessibilityIdentifier("detail.playButton")
        } else if model.isLoading {
            Button {
                guard !SwipeRecord.latest.isSwipe(at: ContinuousClock.now) else { return }
                playsWhenLoaded.toggle()
            } label: {
                Label("Play", systemImage: "play.fill")
                    .opacity(playsWhenLoaded ? 0 : 1)
                    .overlay {
                        if playsWhenLoaded {
                            Spinner()
                                .controlSize(.small)
                                .transition(.opacity)
                        }
                    }
                    .animation(.smooth(duration: 0.25), value: playsWhenLoaded)
            }
            .buttonStyle(PrimaryActionButtonStyle(minWidth: Self.playMinWidth, glass: playGlass))
            .allowsHitTesting(!blocksPlay)
            .accessibilityLabel(playsWhenLoaded ? "Play, loading" : "Play")
            .accessibilityIdentifier("detail.playButton")
        }
    }

    /// Play fills the remaining width beside the circle actions, on one line. The label shrinks before the row ever stacks, so a long
    /// "Resume S3 · E12" stays beside Save, Watched and Trailer.
    @ViewBuilder
    private var actionRow: some View {
        #if !targetEnvironment(macCatalyst)
        if isLandscape {
            GlassEffectContainer(spacing: TitleHero.actionGap / 2) {
                HStack(alignment: .center, spacing: TitleHero.actionGap) {
                    primaryAction
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                        .frame(maxWidth: .infinity)
                    HStack(spacing: TitleHero.actionGap) {
                        downloadAction
                        saveAction
                        watchedAction
                        trailerAction
                    }
                    .fixedSize()
                    .layoutPriority(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            portraitActionRow
        }
        #else
        portraitActionRow
        #endif
    }

    private var portraitActionRow: some View {
        HStack(alignment: .center, spacing: TitleHero.actionGap) {
            primaryAction
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                #if targetEnvironment(macCatalyst)
                // On the Mac, Play keeps its own width rather than stretching across the page; its glass is at least `playMinWidth` wide.
                .fixedSize()
                #else
                .frame(maxWidth: .infinity)
                #endif
            secondaryActions
                .layoutPriority(1)
        }
        .frame(maxWidth: .infinity, alignment: leadsText ? .leading : .center)
    }

    @ViewBuilder
    private var downloadAction: some View {
        if let request = model.primaryRequest, let manager = model.downloadManager {
            NativeDownloadButton(manager: manager, item: manager.item(for: request),
                                 isLoading: manager.loadingRequests.contains(request.identity)) {
                Task { await model.download(request) }
            }
            .accessibilityIdentifier("detail.download")
        }
    }

    private var secondaryActions: some View {
        GlassEffectContainer(spacing: TitleHero.actionGap) {
            HStack(spacing: TitleHero.actionGap) {
                downloadAction
                saveAction
                watchedAction
                trailerAction
            }
        }
        .fixedSize()
    }

    /// The Play button's own colour, from the same value it is drawn with; nil for the plain button. Saved, Watched and the Trailer button
    /// take it while on, and take it too when the page's read decides it after opening.
    private var playColour: Color? { PlayColourStore.colour(hex: model.playColourHex) }
    /// The same subtle material tint as the title's Sort and AI controls, without a solid colour layer beneath it.
    private var playGlass: Glass { .regular.interactive().tint((playColour ?? .clear).opacity(0.25)) }

    private var saveAction: some View {
        CircleActionButton(title: "Save", systemImage: "bookmark", isOn: model.isInLibrary, onTitle: "Saved", onSystemImage: "bookmark.fill",
                           quietRevision: model.loadRevision, onColour: playColour) {
            Task {
                await model.toggleLibrary()
                await titleActions.refresh()
            }
        }
        .accessibilityValue(model.isInLibrary ? "Saved" : "Not saved")
        .accessibilityIdentifier("detail.libraryButton")
    }

    /// A movie is marked on its own. A show is marked as a whole: every episode that has aired. Clearing a whole show asks first,
    /// because it removes the mark from every episode at once.
    @ViewBuilder
    private var watchedAction: some View {
        if model.isSeries {
            let watched = model.isSeriesWatched
            // While the episodes are still arriving it takes a tap, and acts once they are in: a show already watched asks before it is
            // cleared, as it does once loaded.
            let hasNoEpisodes = model.detail.videos.isEmpty && !model.isLoading
            CircleActionButton(title: "Watched", systemImage: "eye", isOn: watched, quietRevision: model.loadRevision,
                               onColour: playColour) {
                Task {
                    await model.waitForDetails()
                    guard !model.isLoading else { return }
                    if model.isSeriesWatched {
                        isConfirmingUnmarkShow = true
                    } else if !model.detail.videos.isEmpty {
                        await model.setSeriesWatched(true)
                        await titleActions.refresh()
                    }
                }
            }
            .disabled(hasNoEpisodes)
            .opacity(hasNoEpisodes ? 0.4 : 1)
            .accessibilityValue(watched ? "Every episode watched" : "Not watched")
            .accessibilityHint(watched ? "Clears the watched mark from every episode" : "Marks every episode that has aired as watched")
            .accessibilityIdentifier("detail.watchedButton")
            .confirmationDialog("Mark every episode as not watched?", isPresented: $isConfirmingUnmarkShow, titleVisibility: .visible) {
                Button("Mark Show as Not Watched", role: .destructive) {
                    Task {
                        await model.setSeriesWatched(false)
                        await titleActions.refresh()
                    }
                }
                Button("Cancel", role: .cancel) {}
            }
        } else {
            let request = model.movieRequest
            let watched = model.isWatched(request)
            CircleActionButton(title: "Watched", systemImage: "eye", isOn: watched, quietRevision: model.loadRevision,
                               onColour: playColour) {
                Task {
                    await model.setWatched(!watched, for: request)
                    await titleActions.refresh()
                }
            }
            .accessibilityValue(watched ? "Watched" : "Not watched")
            .accessibilityIdentifier("detail.watchedButton")
        }
    }

    /// Loads the title's trailer into the page and plays it there, with a spinner while it loads. While it plays the symbol is filled,
    /// and a tap closes the player. A YouTube trailer opens in the YouTube app instead. It is there from the start, so the row does not
    /// change when the page loads; when no trailer can be had it is dimmed and does nothing.
    private var trailerAction: some View {
        CircleActionButton(title: "Trailer", systemImage: "play.rectangle", isOn: model.trailer.isPlaying, onTitle: "Close Trailer",
                           quietRevision: model.trailerQuietCloses, onColour: playColour, action: { model.toggleTrailer() },
                           isLoading: model.trailer.phase == .loading)
        .disabled(!model.canPlayTrailer)
        .opacity(model.canPlayTrailer ? 1 : 0.4)
        .accessibilityIdentifier("detail.trailerButton")
    }
}
#endif
