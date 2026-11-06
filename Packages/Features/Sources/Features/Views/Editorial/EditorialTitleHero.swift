#if canImport(UIKit)
import SwiftUI
import StremioKit
import UIKit

/// A title's page on the editorial pages, held upright: its picture fills the first screen and the type is set over it, as the Arthouse
/// mockup sets it. BACK in the top corner; a second still with PLAY TRAILER and the trailer's length, the user ratings and the
/// Metascore; the runtime and the rating large; who directed it and who stars in it; the name in large capitals with Play beside it;
/// the genres spread across the foot; and Save and Watched as capsules where the pill bar would be. Scrims keep the type clear on any
/// picture, and the foot fades into the page so the synopsis, the episodes and the rest follow without a seam.
struct EditorialTitleHero: View {
    let model: DetailViewModel
    let pictureSlot: HeroSlot
    let isRevealed: Bool
    let size: CGSize
    /// The space kept clear at the top, for the status bar.
    let topInset: CGFloat
    /// True while the streams Play asked for are on their way: Play spins.
    let isLoadingStreams: Bool
    /// Play's movie or episode returned no streams: Play stays, dimmed.
    let hasNoStreams: Bool
    /// True while Shuffle's or an episode's streams load: Play takes no taps then.
    let blocksPlay: Bool
    @Binding var isConfirmingUnmarkShow: Bool
    let play: (StreamRequest) -> Void
    let showStreamSelector: (StreamRequest) -> Void
    let playWithInfuse: (StreamRequest) -> Void
    /// Highest Quality or Data Saver from Play's hold menu: the best stream at that quality starts.
    let playAtQuality: (StreamRequest, PlayQuality) -> Void
    let back: () -> Void
    @Environment(TitleActions.self) private var titleActions
    @Environment(PosterRatingsStore.self) private var ratingsStore: PosterRatingsStore?
    @Environment(\.appAppearance) private var appearance
    /// The film's best disc as the device knows it, for Highest Quality's mark, as the standard Play reads it.
    @State private var bestDisc: BestDiscFormat?

    /// The first screen, never shorter than the type set on it needs.
    private var heroHeight: CGFloat { max(size.height, 600) }

    var body: some View {
        ZStack(alignment: .topLeading) {
            picture
            scrims
            content
        }
        .frame(width: size.width, height: heroHeight)
    }

    // MARK: Picture

    private var picture: some View {
        HeroPicture(slot: pictureSlot, isRevealed: isRevealed, contentMode: .fill, preview: model.preview, usesSystemSpinner: true)
            .frame(width: size.width, height: heroHeight)
            .clipped()
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    /// Darkened at the top for BACK and the still, lightly overall, and heavily at the foot, which ends in the page's own ground.
    private var scrims: some View {
        VStack(spacing: 0) {
            LinearGradient(colors: [.black.opacity(0.6), .black.opacity(0)], startPoint: .top, endPoint: .bottom)
                .frame(height: heroHeight * 0.36)
            Spacer(minLength: 0)
            LinearGradient(stops: [
                .init(color: .black.opacity(0), location: 0),
                .init(color: .black.opacity(0.55), location: 0.4),
                .init(color: appearance.pageBackground, location: 1),
            ], startPoint: .top, endPoint: .bottom)
                .frame(height: heroHeight * 0.62)
        }
        .background(Color.black.opacity(0.14))
        .frame(width: size.width, height: heroHeight)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    // MARK: Type

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            EditorialBackButton(action: back)
                .padding(.top, topInset + Theme.Spacing.xs)
            trailerBlock
                .padding(.top, 40)
            Spacer(minLength: Theme.Spacing.l)
            runtimeAndRating
            Spacer(minLength: Theme.Spacing.l)
            if let directors = directorLine {
                Text(directors)
                    .font(Editorial.font(size: 19))
                    .frame(maxWidth: size.width * 0.55, alignment: .leading)
            }
            Spacer(minLength: Theme.Spacing.l)
            if let stars = starsLine {
                Text(stars)
                    .font(Editorial.font(size: 19))
                    .frame(maxWidth: size.width * 0.5, alignment: .leading)
                    .padding(.bottom, Theme.Spacing.xl)
            }
            titleRow
            genreRow
                .padding(.top, Theme.Spacing.s)
            libraryRow
                .padding(.top, Theme.Spacing.l)
        }
        .padding(.horizontal, Editorial.margin)
        .padding(.bottom, Theme.Spacing.m)
        .frame(width: size.width, height: heroHeight, alignment: .topLeading)
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.35), radius: 6)
    }

    /// The second still, with PLAY TRAILER under it and the trailer's length, the user ratings and the Metascore under that.
    private var trailerBlock: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            if let still = model.backdropURL {
                ArtworkImage(url: still, title: model.detail.name, maxPixelSize: 600)
                    .frame(width: 178, height: 136)
                    .clipped()
                    .accessibilityHidden(true)
            }
            Button {
                Haptics.play(.buttons)
                model.toggleTrailer()
            } label: {
                HStack(spacing: 6) {
                    Text(model.trailer.isPlaying ? "CLOSE TRAILER" : "PLAY TRAILER")
                        .font(Editorial.font(size: 21, weight: .medium))
                    if model.trailer.phase == .loading {
                        Spinner().controlSize(.small)
                    } else {
                        Image(systemName: model.trailer.isPlaying ? "xmark.circle.fill" : "play.circle.fill")
                            .font(.system(size: 18, weight: .regular))
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.hoverPlain)
            .disabled(!model.canPlayTrailer)
            .opacity(model.canPlayTrailer ? 1 : 0.4)
            .accessibilityIdentifier("detail.trailerButton")
            if !stats.isEmpty {
                Text(stats.joined(separator: "     "))
                    .font(Editorial.font(.caption))
                    .foregroundStyle(.white.opacity(0.9))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
        }
    }

    /// "2:25", "1.2M USER RATINGS", "64 METASCORE" (IMDb's score when Metacritic has none), each once known.
    private var stats: [String] {
        let ratings = ratingsStore?.ratings(for: model.detail.preview, includeReviews: model.hasSettledHero)
        let length = model.trailers.compactMap(\.duration).first.map(Editorial.duration)
        let votes = ratings?.imdbVotes.map { "\(Editorial.count($0)) USER RATINGS" }
        let score = ratings?.metacritic.map { "\(Int($0.rounded())) METASCORE" }
            ?? ratings?.imdb.map { String(format: "%.1f IMDB", $0) }
        return [length, votes, score].compactMap { $0 }
    }

    /// The runtime ("1H 50M"; a series' seasons) and the rating ("R"), large, across the middle of the picture.
    private var runtimeAndRating: some View {
        let seasons = model.seasons.filter { $0 > 0 }.count
        let length: String? = model.isSeries && seasons > 0 ? "\(seasons) SEASON\(seasons == 1 ? "" : "S")"
            : Editorial.runtime(model.detail.preview.runtime)
        return HStack(alignment: .firstTextBaseline, spacing: 0) {
            Spacer(minLength: 0)
            if let length { Text(length) }
            Spacer(minLength: Theme.Spacing.l)
            if let certification = model.certification, !certification.isEmpty { Text(certification) }
        }
        .font(Editorial.font(size: 34, weight: .medium))
        .lineLimit(1)
        .padding(.trailing, Theme.Spacing.l)
    }

    /// "Director - Luc Besson"; for a series, who created it.
    private var directorLine: String? {
        let names: [String]
        if model.isSeries {
            names = model.titleFacts?.creators ?? []
        } else {
            let credited = model.titleCredits?.people(in: .directing).filter { $0.roles.contains("Director") }.map(\.name) ?? []
            names = credited.isEmpty ? model.detail.director : credited
        }
        guard !names.isEmpty else { return nil }
        return (model.isSeries ? "Created by - " : "Director - ") + names.prefix(2).joined(separator: ", ")
    }

    /// "Stars - Jean Reno, Natalie Portman": the first two of the cast.
    private var starsLine: String? {
        let credited = model.titleCredits?.cast.prefix(2).map(\.name) ?? []
        let names = credited.isEmpty ? Array(model.detail.cast.prefix(2)) : credited
        guard !names.isEmpty else { return nil }
        return "Stars - " + names.joined(separator: ", ")
    }

    /// The name in large capitals, with Play beside its last line.
    private var titleRow: some View {
        HStack(alignment: .bottom, spacing: Theme.Spacing.m) {
            Text(model.detail.name.uppercased())
                .font(Editorial.font(size: 52, weight: .medium))
                .lineLimit(3)
                .minimumScaleFactor(0.5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("detail.title")
            playButton
                .padding(.bottom, 6)
        }
    }

    /// A white circle with a black arrow, as the mockup's. It spins while the streams load; a hold offers the stream selector and Infuse.
    @ViewBuilder
    private var playButton: some View {
        if let request = model.primaryRequest {
            Button {
                // A swipe that ends on Play, such as one going back, starts nothing.
                guard !SwipeRecord.latest.isSwipe(at: ContinuousClock.now) else { return }
                play(request)
            } label: {
                ZStack {
                    Image(systemName: "chevron.forward.circle.fill")
                        .font(.system(size: 36, weight: .regular))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.black, .white)
                        .opacity(isLoadingStreams ? 0 : 1)
                    if isLoadingStreams {
                        Spinner().controlSize(.regular)
                    }
                }
                .frame(width: 48, height: 48)
                .contentShape(Circle())
                .animation(.smooth(duration: 0.25), value: isLoadingStreams)
            }
            .buttonStyle(.hoverPlain)
            .contextMenu {
                Button("Stream Selector", systemImage: "arrow.up.right.square") {
                    Haptics.play(.buttons)
                    showStreamSelector(request)
                }
                Button("Play with Infuse", systemImage: "play.rectangle.on.rectangle") {
                    Haptics.play(.buttons)
                    playWithInfuse(request)
                }
                PlayQualityMenuItems(disc: bestDisc) { playAtQuality(request, $0) }
            }
            .task(id: "\(model.detail.preview.identity)|\(isLoadingStreams)") {
                bestDisc = await ratingsStore?.knownBestDisc(for: model.detail.preview)
            }
            .disabled(hasNoStreams)
            .opacity(hasNoStreams ? 0.4 : 1)
            .allowsHitTesting(!blocksPlay)
            .accessibilityLabel(hasNoStreams ? "No streams available" : (isLoadingStreams ? "\(model.primaryActionTitle), loading"
                : model.primaryActionTitle))
            .accessibilityIdentifier("detail.playButton")
        } else if model.isLoading {
            Spinner().controlSize(.regular).frame(width: 48, height: 48)
        }
    }

    /// The genres spread across the foot of the picture.
    private var genreRow: some View {
        let genres = Array(model.detail.preview.genres.prefix(5))
        return HStack(spacing: 0) {
            ForEach(Array(genres.enumerated()), id: \.offset) { index, genre in
                if index > 0 { Spacer(minLength: Theme.Spacing.s) }
                Text(genre.uppercased())
            }
        }
        .font(Editorial.font(.caption2))
        .lineLimit(1)
        .foregroundStyle(.white.opacity(0.85))
    }

    // MARK: Library

    /// Save and Watched as the pill bar's capsules, where the pill bar sits on the other pages, with what Play will do beside them.
    private var libraryRow: some View {
        HStack(spacing: 2) {
            capsule(model.isInLibrary ? "Saved" : "Save", systemImage: model.isInLibrary ? "checkmark" : "plus",
                    isOn: model.isInLibrary, identifier: "detail.libraryButton") {
                Task {
                    await model.toggleLibrary()
                    await titleActions.refresh()
                }
            }
            watchedCapsule
        }
        .confirmationDialog("Mark every episode as not watched?", isPresented: $isConfirmingUnmarkShow, titleVisibility: .visible) {
            Button("Mark Show as Not Watched", role: .destructive) {
                Task {
                    await model.setSeriesWatched(false)
                    await titleActions.refresh()
                }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    /// A movie is marked on its own; a show as a whole, every episode that has aired, and clearing a whole show asks first.
    @ViewBuilder
    private var watchedCapsule: some View {
        if model.isSeries {
            let watched = model.isSeriesWatched
            let hasNoEpisodes = model.detail.videos.isEmpty && !model.isLoading
            capsule("Watched", systemImage: watched ? "checkmark" : "eye", isOn: watched, identifier: "detail.watchedButton") {
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
        } else {
            let request = model.movieRequest
            let watched = model.isWatched(request)
            capsule("Watched", systemImage: watched ? "checkmark" : "eye", isOn: watched, identifier: "detail.watchedButton") {
                Task {
                    await model.setWatched(!watched, for: request)
                    await titleActions.refresh()
                }
            }
        }
    }

    /// One of the bar's capsules: black, outlined, its name in capitals and its symbol after it; filled white while on.
    private func capsule(_ title: String, systemImage: String, isOn: Bool, identifier: String,
                         action: @escaping () -> Void) -> some View {
        Button {
            Haptics.play(.choices)
            action()
        } label: {
            HStack(spacing: Theme.Spacing.s) {
                Text(title.uppercased())
                    .font(Editorial.font(.body))
                Image(systemName: systemImage)
                    .font(.system(size: 14, weight: .regular))
            }
            .foregroundStyle(isOn ? Color.black : .white)
            .frame(maxWidth: .infinity)
            .frame(height: EditorialTabBar.height)
            .background { Capsule().fill(isOn ? Color.white : .black) }
            .overlay { Capsule().strokeBorder(.white.opacity(0.9), lineWidth: 1) }
            .contentShape(Capsule())
            .animation(.smooth(duration: 0.25), value: isOn)
        }
        .buttonStyle(.hoverPlain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isOn ? .isSelected : [])
        .accessibilityIdentifier(identifier)
    }
}
#endif
