#if canImport(UIKit)
import SwiftUI
import StremioKit

/// Settings → Appearance's live preview: a small page in the look being set, drawn with the app's own pieces (`mediaArtwork`, the
/// progress overlay, `headingStyle()`, `LayoutMetrics`) at their real sizes, so every choice shows what it does as it is made, a slider's
/// included while it is still being dragged. It stands in for help text: the page explains itself by showing the result.
///
/// Each part of Appearance shows the part of the app it changes: cards and text on most pages, the spotlight on Home's, an episode and
/// the sections' order on Title Pages', and a moving dot on Motion & Navigation's.
struct AppearancePreview: View {
    @Environment(\.layoutMetrics) private var metrics
    enum Kind {
        case cards, corners, home, titlePage, motion
    }

    let appearance: AppearancePreferences
    var kind: Kind = .cards

    var body: some View {
        AppearancePreviewContent(kind: kind)
            .padding(.vertical, Theme.Spacing.l)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(appearance.pageBackground)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.surface * metrics.customised(by: appearance).cornerScale(for: .settingsPreview), style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Theme.Radius.surface * metrics.customised(by: appearance).cornerScale(for: .settingsPreview), style: .continuous)
                    .strokeBorder(Theme.separator, lineWidth: 1)
                    .allowsHitTesting(false)
            }
            // The root's animation speed already reaches the preview; applying it again would square it.
            .appearanceLook(appearance, motion: false)
            .accessibilityIdentifier("settings.appearance.preview")
    }
}

private struct AppearancePreviewContent: View {
    let kind: AppearancePreview.Kind
    @Environment(\.layoutMetrics) private var metrics
    @Environment(\.appAppearance) private var appearance
    @Environment(PosterRatingsStore.self) private var ratingsStore: PosterRatingsStore?

    var body: some View {
        switch kind {
        case .cards: cards
        case .corners: corners
        case .home: home
        case .titlePage: titlePage
        case .motion: MotionPreview()
        }
    }

    // MARK: Cards and text

    private var cards: some View {
        VStack(alignment: .leading, spacing: metrics.headerSpacing) {
            BrowseFilterBar(kinds: .init(titles: ["All", "Movies", "Series"], selection: .constant(1),
                                        identifier: "settings.appearance.preview.type"),
                            chips: [], identifier: "settings.appearance.preview.filters", clearAll: {}) {
                FilterMenuLabel("Sort", systemImage: "arrow.up.arrow.down",
                                minHeight: BrowseFilterBar<EmptyView>.menuHeight)
                FilterMenuLabel("Genre", systemImage: "tag",
                                minHeight: BrowseFilterBar<EmptyView>.menuHeight)
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            heading("Continue Watching")
            shelf {
                ForEach(0..<3, id: \.self) { continueCard($0) }
            }
            .accessibilityHidden(true)
            heading("Top Picks")
                .padding(.top, metrics.controlSpacing)
            shelf {
                ForEach(0..<4, id: \.self) { poster($0) }
            }
            .accessibilityHidden(true)
            Text(Samples.synopsis)
                .font(Theme.Typography.body)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .padding(.horizontal, Theme.Spacing.l)
                .padding(.top, Theme.Spacing.xs)
            actionButtons
            accentControls
                .padding(.horizontal, Theme.Spacing.l)
                .padding(.top, Theme.Spacing.xs)
        }
    }

    private func heading(_ title: String) -> some View {
        Text(title)
            .headingStyle()
            .foregroundStyle(.primary)
            .lineLimit(1)
            .padding(.horizontal, Theme.Spacing.l)
    }

    private func shelf<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: metrics.cardSpacing) { content() }
                .padding(.horizontal, Theme.Spacing.l)
        }
        .scrollIndicators(.hidden)
    }

    private func continueCard(_ index: Int) -> some View {
        let item = Samples.items[index % Samples.items.count]
        return ProgressCard(title: item.name, artwork: item.background,
                            logo: item.logo, fraction: 0.62, duration: 2580)
    }

    private func poster(_ index: Int) -> some View {
        MediaCard(item: Samples.items[index % Samples.items.count])
    }

    /// The accent where the app uses it: a prominent button, a switch and a link. Shown, not used.
    private var accentControls: some View {
        HStack(spacing: Theme.Spacing.m) {
            Button {} label: { Label("Add", systemImage: "plus") }
                .buttonStyle(.glassProminent)
            Toggle("Switch", isOn: .constant(true))
                .labelsHidden()
            Text("See All")
                .foregroundStyle(.tint)
            Spacer(minLength: 0)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var actionButtons: some View {
        GlassEffectContainer(spacing: TitleHero.actionGap) {
            HStack(spacing: TitleHero.actionGap) {
                Button {} label: { Label("Play", systemImage: "play.fill") }
                    .buttonStyle(PrimaryActionButtonStyle(height: CircleActionButton.diameter))
                CircleActionButton(title: "Save", systemImage: "bookmark", exactSize: true) {}
                CircleActionButton(title: "Watched", systemImage: "eye", exactSize: true) {}
                CircleActionButton(title: "Trailer", systemImage: "play.rectangle", exactSize: true) {}
            }
        }
        .allowsHitTesting(false)
        .padding(.horizontal, Theme.Spacing.l)
    }

    private var corners: some View {
        VStack(alignment: .leading, spacing: metrics.headerSpacing) {
            actionButtons
            shelf { ForEach(0..<3, id: \.self) { poster($0) } }
            BrowseFilterBar(kinds: nil, chips: [], identifier: "settings.appearance.preview.cornerFilters", clearAll: {}) {
                FilterMenuLabel("Sort", systemImage: "arrow.up.arrow.down")
                FilterMenuLabel("Genre", systemImage: "tag")
            }
            .allowsHitTesting(false)
            if let review = Samples.review {
                shelf {
                    ReviewCard(review: review, isExpanded: false, foldedWidth: metrics.reviewCardWidth,
                               expandedWidth: metrics.reviewCardWidth, onToggle: {})
                }
                .allowsHitTesting(false)
            }
            HStack {
                Label("Auto Pick", systemImage: "sparkles")
                Spacer()
                Image(systemName: "chevron.down")
            }
            .padding()
            .glassCardSurface()
            .padding(.horizontal, Theme.Spacing.l)
            HStack {
                Button {} label: { Image(systemName: "backward.end.fill") }
                    .glassCircleButton(group: .playerControls)
                Spacer()
                Button {} label: { Image(systemName: "play.fill") }
                    .glassCircleButton(group: .playerControls)
                Spacer()
                Button {} label: { Image(systemName: "forward.end.fill") }
                    .glassCircleButton(group: .playerControls)
            }
            .padding()
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 24 * metrics.cornerScale(for: .playerControls)))
            .padding(.horizontal, Theme.Spacing.l)
            .allowsHitTesting(false)
            VStack(spacing: 4) {
                Toggle("Ratings on posters", isOn: .constant(ratingsStore?.isEnabled ?? false))
                    .padding()
                    .background(SettingsRowBackground())
                HStack {
                    SettingsRow(title: "Playback", summary: "Auto", systemImage: "play.circle")
                    Spacer()
                    Image(systemName: "chevron.right").foregroundStyle(.secondary)
                }
                .padding()
                .background(SettingsRowBackground())
            }
            .padding(.horizontal, Theme.Spacing.l)
            .allowsHitTesting(false)
        }
    }

    // MARK: Home

    private var home: some View {
        VStack(alignment: .leading, spacing: metrics.shelfSpacing) {
            SpotlightPreview()
            VStack(alignment: .leading, spacing: metrics.headerSpacing) {
                heading("Top Picks")
                shelf { ForEach(0..<4, id: \.self) { poster($0) } }
                    .accessibilityHidden(true)
            }
        }
        // The spotlight runs to the preview's top edge, as it runs to the screen's on Home.
        .padding(.top, -Theme.Spacing.l)
    }

    // MARK: Title page

    private var titlePage: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.l) {
            actionButtons
            Text(Samples.synopsis + " " + Samples.synopsisMore)
                .font(Theme.Typography.body)
                .foregroundStyle(.secondary)
                .lineLimit(appearance.expandsSynopsis ? nil : 2)
                .padding(.horizontal, Theme.Spacing.l)
            heading("Season 1")
            EpisodePreview(watched: true)
            EpisodePreview(watched: false)
            FlowLayout(spacing: Theme.Spacing.s) {
                ForEach(sectionsInOrder, id: \.self) { name in
                    Text(name)
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, Theme.Spacing.m)
                        .padding(.vertical, Theme.Spacing.xs + 2)
                        .background(Theme.surface, in: ScaledCapsule(scale: metrics.cornerScale(for: .filters)))
                }
            }
            .padding(.horizontal, Theme.Spacing.l)
            .accessibilityElement(children: .combine)
        }
    }

    /// The title page's sections below the episodes, as Appearance orders and shows them.
    private var sectionsInOrder: [String] {
        let reviews = appearance.showsReviews ? ["Reviews"] : []
        var credits: [String] = []
        if appearance.showsCast { credits.append("Cast & Crew") }
        if appearance.showsInformation { credits.append("Information") }
        let middle = appearance.sectionOrder == .reviewsFirst ? reviews + credits : credits + reviews
        return ["Episodes"] + middle + (appearance.showsRelated ? ["More Like This"] : [])
    }
}

/// Fixed titles keep every Appearance page showing the same artwork.
private enum Samples {
    static let items: [MetaPreview] = [
        ("tt0816692", "Interstellar"),
        ("tt0133093", "The Matrix"),
        ("tt0111161", "The Shawshank Redemption"),
        ("tt0120737", "The Lord of the Rings"),
    ].map { id, name in
        MetaPreview(id: id, type: "movie", name: name,
                    poster: MetahubArtwork.poster(imdbID: id),
                    background: MetahubArtwork.background(imdbID: id),
                    logo: MetahubArtwork.logo(imdbID: id))
    }
    static let review = try? JSONDecoder().decode(TMDbReview.self, from: Data("""
        {"id":"appearance-preview","author":"Alex","content":"A beautiful film with a memorable story and an incredible soundtrack. The pacing never lets up, and the ending stays with you long after the credits roll.","author_details":{"rating":8}}
        """.utf8))
    static let synopsis = "A team of explorers travels beyond the solar system to find a future for humanity."
    static let synopsisMore = "Their journey takes them through a wormhole and across worlds where time passes differently."

}

/// Preview artwork uses the same source and image view as the library.
private struct SampleArtwork: View {
    let index: Int

    var body: some View {
        let item = Samples.items[index % Samples.items.count]
        ArtworkImage(url: item.background, title: item.name, maxPixelSize: 640)
    }
}

/// Home's spotlight in miniature, at Appearance's height, with its page dots and, when Appearance turns its pages, turning them.
private struct SpotlightPreview: View {
    @Environment(\.layoutMetrics) private var metrics
    @Environment(\.appAppearance) private var appearance
    @State private var page = 0

    var body: some View {
        TabView(selection: $page) {
            ForEach(0..<3, id: \.self) { index in
                SampleArtwork(index: index + 1)
                    .tag(index)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .frame(height: 190 * appearance.heroScale)
        .overlay { BottomFade(length: 0.45) }
        .overlay(alignment: .bottom) {
            if appearance.showsPageDots {
                HStack(spacing: 6) {
                    ForEach(0..<3, id: \.self) { index in
                        ScaledCapsule(scale: metrics.cornerScale(for: .filters))
                            .fill(.white.opacity(index == page ? 0.95 : 0.35))
                            .frame(width: index == page ? 16 : 6, height: 6)
                    }
                }
                .animation(.snappy(duration: 0.25), value: page)
                .padding(.bottom, Theme.Spacing.m)
            }
        }
        .task(id: PageTurn(seconds: appearance.heroAutoAdvance, page: page)) {
            let seconds = appearance.heroAutoAdvance
            guard seconds > 0 else { return }
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            withAnimation(.snappy(duration: 0.5)) { page = (page + 1) % 3 }
        }
        .accessibilityHidden(true)
    }

    private struct PageTurn: Equatable {
        let seconds: Int
        let page: Int
    }
}

/// An episode row in miniature: a watched one as it always shows, and an unstarted one as Hide spoilers shows it.
private struct EpisodePreview: View {
    let watched: Bool
    @Environment(\.appAppearance) private var appearance

    private var hides: Bool { appearance.hidesSpoilers && !watched }

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.m) {
            SampleArtwork(index: watched ? 1 : 3)
                .blur(radius: hides && appearance.spoilerStills ? 12 : 0, opaque: true)
                .frame(width: 128, height: 72)
                .overlay(alignment: .bottomTrailing) {
                    if watched {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.white)
                            .padding(Theme.Spacing.xs)
                    }
                }
                .mediaArtwork(cornerRadius: Theme.Radius.small)
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                Text(watched ? "EPISODE 3" : "EPISODE 4")
                    .font(Theme.Typography.eyebrow)
                    .foregroundStyle(.white.opacity(0.75))
                Text(watched ? "Low Tide" : "The Boat That Answered")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.white)
                    .redacted(reason: hides && appearance.spoilerTitles ? .placeholder : [])
                Text(watched ? "The keeper logs the signal for the third night running." :
                        "Mara reaches the boat and finds who has been answering her.")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(2)
                    .redacted(reason: hides && appearance.spoilerSynopses ? .placeholder : [])
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.Spacing.l)
        .accessibilityHidden(true)
    }
}

/// A dot that crosses a track with the app's own animation, at Appearance's speed, each time Play Animation is pressed.
private struct MotionPreview: View {
    @Environment(\.layoutMetrics) private var metrics
    @State private var moved = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            Circle()
                .fill(.tint)
                .frame(width: 26, height: 26)
                .frame(maxWidth: .infinity, alignment: moved ? .trailing : .leading)
                .padding(5)
                .background(Theme.surface, in: ScaledCapsule(scale: metrics.cornerScale(for: .filters)))
                .accessibilityHidden(true)
            Button {
                Haptics.play(.buttons)
                withAnimation(.snappy(duration: 0.8)) { moved.toggle() }
            } label: {
                Label("Play Animation", systemImage: "play.fill")
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("settings.appearance.playAnimation")
        }
        .padding(.horizontal, Theme.Spacing.l)
    }
}
#endif
