#if canImport(UIKit)
import SwiftUI
import StremioKit
import UIKit

/// A cast or crew member's page: the portrait and biography, what they are known for, then every credit, newest first, with
/// filters for the kind of title and the role. Credits are laid out a page at a time as the list scrolls.
struct PersonView: View {
    @State private var model: PersonViewModel
    @State private var isBiographyExpanded = false
    @State private var isBiographyTruncated = false
    @Environment(\.layoutMetrics) private var metrics

    /// The Mac page reads from the left, 60 points from the sidebar like the title page, with its credits in columns. iPhone and iPad
    /// keep the centred page with one column.
    #if targetEnvironment(macCatalyst)
    private static let isDesktop = true
    #else
    private static let isDesktop = false
    #endif
    /// The page's side margin.
    private var margin: CGFloat { Self.isDesktop ? 60 : metrics.pageMargin }
    /// Where the name, the summary and the biography sit across the page.
    private var leading: Bool { Self.isDesktop }

    init(destination: PersonDestination, services: AppServices) {
        _model = State(initialValue: PersonViewModel(destination: destination, services: services))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                    .padding(.horizontal, margin)
                if !model.photoStrip.isEmpty {
                    photos.padding(.top, Theme.Spacing.xxl)
                }
                synopsis
                    .padding(.horizontal, margin)
                    .padding(.top, model.photoStrip.isEmpty ? Theme.Spacing.m : Theme.Spacing.xl)
                if !model.knownFor.isEmpty {
                    knownFor.padding(.top, Theme.Spacing.xxl)
                }
                credits
                    .padding(.horizontal, margin)
                    .padding(.top, Theme.Spacing.xxl)
            }
            .padding(.bottom, Theme.Spacing.xxl)
        }
        .screenBackground()
        .navigationTitle(model.destination.name)
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.load() }
        .accessibilityIdentifier("person.scroll")
    }

    // MARK: - Header

    private var name: String { model.person?.name ?? model.destination.name }

    /// The portrait while it loads is the one the card already showed, so the page never opens on an empty frame.
    private var header: some View {
        VStack(alignment: leading ? .leading : .center, spacing: Theme.Spacing.xs) {
            Text(name)
                .font(Theme.Typography.heroTitle)
                .multilineTextAlignment(leading ? .leading : .center)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("person.name")
            if let line = summaryLine {
                Text(line).font(Theme.Typography.metaLine).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: leading ? .leading : .center)
        .padding(.top, Theme.Spacing.l)
    }

    /// The biography and any note on why the page is short, below the photos.
    private var synopsis: some View {
        VStack(alignment: leading ? .leading : .center, spacing: Theme.Spacing.m) {
            if let biography = model.person?.biography {
                biographyText(biography)
            }
            if let reason = model.unavailableReason {
                Text(reason)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(leading ? .leading : .center)
                    .accessibilityIdentifier("person.unavailable")
            }
        }
        .frame(maxWidth: .infinity, alignment: leading ? .leading : .center)
    }

    /// "Directing · 42 credits". Parts that are not known yet are left out.
    private var summaryLine: String? {
        var parts: [String] = []
        if let department = model.person?.department { parts.append(department) }
        if !model.credits.isEmpty { parts.append("\(model.credits.count) credits") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    @ViewBuilder
    private func biographyText(_ biography: String) -> some View {
        // Folded when it runs past four lines; one that fits has nothing to fold and no button.
        let folds = isBiographyExpanded || isBiographyTruncated
        let toggle = { withAnimation(.easeInOut(duration: 0.25)) { isBiographyExpanded.toggle() } }
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            JustifiedText(text: biography, color: UIColor.white.withAlphaComponent(0.85), lineLimit: isBiographyExpanded ? 0 : 4,
                          isTruncated: $isBiographyTruncated)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                // A tap folds or opens it, as on a title page.
                .onTapGesture {
                    if folds { toggle() }
                }
        }
        .frame(maxWidth: metrics.readableWidth, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: leading ? .leading : .center)
    }

    // MARK: - Photos

    /// Every profile photo TMDb has for the person, best voted first, as a strip of portraits.
    private var photos: some View {
        ScrollView(.horizontal) {
            LazyHStack(alignment: .top, spacing: metrics.cardSpacing) {
                ForEach(model.photoStrip, id: \.self) { url in
                    ArtworkImage(url: url, title: "", maxPixelSize: 360, contentMode: .fill)
                        .frame(width: metrics.posterWidth, height: metrics.posterWidth * 1.5)
                        .mediaArtwork(cornerRadius: Theme.Radius.poster)
                        .reportsShelfEdge(id: url)
                }
            }
            .scrollTargetLayout()
        }
        .shelfIndicators()
        .contentMargins(.horizontal, margin, for: .scrollContent)
        .scrollClipDisabled()
        .softSnappingScroll()
        .accessibilityIdentifier("person.photos")
    }

    // MARK: - Known For

    /// The titles to remember them by, as wide cards with their backdrops.
    private var knownFor: some View {
        VStack(alignment: .leading, spacing: metrics.headerSpacing) {
            SectionHeader("Known For")
                .padding(.horizontal, margin)
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: metrics.cardSpacing) {
                    ForEach(model.knownFor) { credit in
                        NavigationLink(value: credit.titleDestination) {
                            KnownForCard(title: credit.title.isEmpty ? "Untitled" : credit.title,
                                         backdrop: model.knownForArtwork[credit.id]?.backdrop ?? credit.backdrop,
                                         logo: model.knownForArtwork[credit.id]?.logo, role: credit.roleText)
                        }
                        .buttonStyle(PressableCardStyle())
                        .titleTapHaptic()
                        .reportsShelfEdge(id: credit.id)
                        .accessibilityIdentifier("person.knownFor.\(credit.id)")
                    }
                }
                .scrollTargetLayout()
            }
            .shelfIndicators()
            .contentMargins(.horizontal, margin, for: .scrollContent)
            .scrollClipDisabled()
            .softSnappingScroll()
        }
    }

    // MARK: - Credits

    private var credits: some View {
        VStack(alignment: .leading, spacing: metrics.headerSpacing) {
            SectionHeader("Credits")
            filters
            if model.isLoading && model.credits.isEmpty {
                Spinner()
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, Theme.Spacing.l)
            } else if model.sections.isEmpty {
                Text(model.credits.isEmpty ? "No credits yet." : "No credits match these filters.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, Theme.Spacing.s)
                    .accessibilityIdentifier("person.noCredits")
            }
            // A lazy stack builds a card only when it is about to scroll on screen, so artwork is requested for what is visible.
            // The next page loads when a row inside the lazy-load buffer from the end appears, not only at the very end.
            let triggerID = LazyLoadLookahead.triggerElement(in: model.sections.flatMap(\.credits))?.id
            LazyVStack(alignment: .leading, spacing: Theme.Spacing.l) {
                ForEach(model.sections) { section in
                    VStack(alignment: .leading, spacing: Theme.Spacing.m) {
                        Text(section.year.map(String.init) ?? "Unknown Date")
                            .font(.title3.bold())
                            .accessibilityAddTraits(.isHeader)
                            .accessibilityIdentifier("person.year.\(section.id)")
                        // A year's credits are one column on a phone, and as many columns as fit on a Mac, where one row across the
                        // whole window left each title a long way from its rating.
                        LazyVGrid(columns: creditColumns, alignment: .leading, spacing: Theme.Spacing.m) {
                            ForEach(section.credits) { credit in
                                CreditRow(credit: credit, isUnreleased: model.isUnreleased(credit))
                                    .onAppear { if credit.id == triggerID { model.loadMore() } }
                            }
                        }
                    }
                }
                if model.hasMoreCredits {
                    Spinner()
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, Theme.Spacing.m)
                        .onAppear { model.loadMore() }
                }
            }
        }
    }

    private var creditColumns: [GridItem] {
        Self.isDesktop
            ? [GridItem(.adaptive(minimum: 340, maximum: 520), spacing: Theme.Spacing.m, alignment: .top)]
            : [GridItem(.flexible(), alignment: .top)]
    }

    /// Two compact menus side by side: the kind of title, and the role. Each shows what it is set to.
    private var filters: some View {
        HStack(spacing: Theme.Spacing.s) {
            Menu {
                Picker("Titles", selection: $model.mediaFilter) {
                    ForEach(PersonMediaFilter.allCases) { Text($0.title).tag($0) }
                }
            } label: {
                FilterMenuLabel(model.mediaFilter.title, systemImage: "film", isActive: model.mediaFilter != .all)
            }
            .accessibilityIdentifier("person.mediaFilter")
            Menu {
                Picker("Roles", selection: $model.roleFilter) {
                    Text("All Roles").tag(CreditCategory?.none)
                    ForEach(model.availableRoles, id: \.self) { Text($0.title).tag(CreditCategory?.some($0)) }
                }
            } label: {
                FilterMenuLabel(model.roleFilter?.title ?? "All Roles", systemImage: "person.text.rectangle", isActive: model.roleFilter != nil)
            }
            .accessibilityIdentifier("person.roleFilter")
        }
    }
}

// MARK: - Pieces

/// A Known For card: the Continue card's picture, without its bottom fade and playback row.
private struct KnownForCard: View {
    let title: String
    let backdrop: URL?
    let logo: URL?
    let role: String
    @Environment(\.layoutMetrics) private var metrics
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        let width = metrics.continueCardWidth
        Color.clear
            .frame(width: width, height: width / CardAspect.wide.ratio)
            .overlay {
                LandscapeArtwork(title: title, artwork: backdrop, logo: logo, maxPixelSize: min((width * displayScale).rounded(.up), 1200))
            }
            .mediaArtwork()
            .accessibilityElement(children: .ignore)
            .accessibilityLabel([title, role].filter { !$0.isEmpty }.joined(separator: ", "))
    }
}

/// One credit as a row in the filmography: a poster, the title and kind, the role, and the rating when TMDb has one.
private struct CreditRow: View {
    let credit: TMDbPersonCredit
    let isUnreleased: Bool
    @Environment(\.layoutMetrics) private var metrics

    var body: some View {
        NavigationLink(value: credit.titleDestination) {
            HStack(alignment: .center, spacing: Theme.Spacing.m) {
                ArtworkImage(url: PosterQuality.smallest(credit.poster), title: credit.title, maxPixelSize: 240, contentMode: .fill)
                    .frame(width: 60, height: 90)
                    .mediaArtwork(cornerRadius: Theme.Radius.poster)
                VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                    Text(credit.title.isEmpty ? "Untitled" : credit.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                    Text(kindLine)
                        .font(Theme.Typography.cardSubtitle)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Text(credit.roleText)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    footer
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(Theme.Spacing.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassCardSurface()
        }
        .buttonStyle(PressableCardStyle())
        .titleTapHaptic()
        .accessibilityIdentifier("person.credit.\(credit.id)")
    }

    /// "Movie", or "TV Show · 10 episodes" when TMDb counts them.
    private var kindLine: String {
        guard !credit.isMovie else { return "Movie" }
        guard let episodes = credit.episodeCount, episodes > 0 else { return "TV Show" }
        return "TV Show · \(episodes) episodes"
    }

    /// The rating, or an "Unreleased" mark for a title that is not out yet. A title with neither shows nothing here.
    @ViewBuilder
    private var footer: some View {
        if isUnreleased {
            Badge("Unreleased", style: .neutral)
        } else if let average = credit.voteAverage {
            Label(ScoreText.wholeScore(average), systemImage: "star.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
        }
    }
}

/// A cast or crew member as a card: a portrait with rounded corners, then the name and the role. Tapping opens their page.
struct PersonCardLink: View {
    let person: TMDbTitlePerson
    /// The card's width; zero for a shelf's usual card. A card narrower than that sets its two lines one size smaller.
    var width: CGFloat = 0
    @Environment(\.layoutMetrics) private var metrics

    var body: some View {
        let width = width > 0 ? min(width, metrics.posterWidth) : metrics.posterWidth
        let isNarrow = width < metrics.posterWidth
        NavigationLink(value: PersonDestination(id: person.id, name: person.name, profile: person.profile)) {
            VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                ArtworkImage(url: person.profile, title: person.name, maxPixelSize: 360, contentMode: .fill)
                    .frame(width: width, height: width * 1.5)
                    .mediaArtwork(cornerRadius: Theme.Radius.poster)
                VStack(alignment: .leading, spacing: 2) {
                    Text(person.name)
                        .font(isNarrow ? .caption.weight(.semibold) : Theme.Typography.cardTitle)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(person.roleText ?? (person.isCast ? "Actor" : "Crew"))
                        .font(isNarrow ? .caption2 : Theme.Typography.cardSubtitle)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(width: width, alignment: .leading)
            }
        }
        .buttonStyle(PressableCardStyle())
        .titleTapHaptic()
        .help(person.name)
        .accessibilityIdentifier("cast.\(person.id)")
    }
}
#endif
