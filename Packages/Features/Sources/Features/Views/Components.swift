#if canImport(UIKit)
import SwiftUI
import StremioKit

/// A capsule that names a failing addon without hiding the rest of the screen. The failure is said by the icon and the text,
/// not by a coloured block.
struct ErrorChip: View {
    let text: String

    var body: some View {
        Label {
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(.secondary)
        }
        .font(.footnote.weight(.medium))
        .foregroundStyle(.primary)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Theme.surfaceStrong, in: Capsule())
        .accessibilityElement(children: .combine)
    }
}

/// Shown instead of a wall of per-addon errors when every request failed because the device is offline.
struct OfflineBanner: View {
    var body: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.m) {
            Image(systemName: "wifi.slash")
                .font(.title3)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                Text(Connectivity.offlineTitle)
                    .font(.headline)
                Text(Connectivity.offlineMessage)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(Theme.Spacing.l)
        .cardSurface()
        .padding(.horizontal, Theme.screenPadding)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("offline.banner")
    }
}

/// Wraps its children onto several lines instead of clipping them (chips at large Dynamic Type sizes).
struct WrappingStack<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        // A vertical stack of chips keeps layout trivial and never clips at accessibility sizes.
        VStack(alignment: .leading, spacing: 8, content: content)
    }
}

/// Poster artwork: 2:3 with poster corners. Give it a width (`.frame(width:)`) and the height follows.
struct PosterImage: View {
    let url: URL?
    let title: String

    var body: some View {
        ArtworkImage(url: url, title: title, maxPixelSize: 480)
            .aspectRatio(CardAspect.poster.ratio, contentMode: .fit)
            .mediaArtwork(cornerRadius: Theme.Radius.poster)
            .accessibilityHidden(true)
    }
}

/// The first-run state: no addon is installed, so there is nothing to browse yet.
struct EmptyAddonsView: View {
    let onOpenAddons: () -> Void

    var body: some View {
        EmptyStateLayout(
            title: "No addons yet",
            systemImage: "puzzlepiece.extension",
            message: "Addons bring the catalogs, search and streams. "
                + "Paste an addon's link (it starts with https:// or stremio://) in Settings."
        ) {
            Button("Add an addon", action: onOpenAddons)
                .buttonStyle(.primaryActionCompact)
                .padding(.top, Theme.Spacing.s)
                .accessibilityIdentifier("empty.addAddon")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("empty.noAddons")
    }
}

/// Where each kind of value in a stack leads. Every tab's stack uses the same set.
struct AppDestinations: ViewModifier {
    let services: AppServices
    /// The stack's path in the router, which its back swipe pops.
    let path: ReferenceWritableKeyPath<AppRouter, NavigationPath>
    @Environment(\.zoomNamespace) private var zoomNamespace
    @Environment(AppRouter.self) private var router

    func body(content: Content) -> some View {
        content
            .navigationDestination(for: MetaPreview.self) { preview in
                IMDbTitlePage(preview: preview, services: services) { DetailView(preview: $0, services: services) }
                    .titlePage(on: path)
                    // Only a title opened from Search is recorded as a recent search, and the title's name is what is kept.
                    .onAppear { if path == \.searchPath { recordSearchedTitle(preview.name) } }
            }
            .navigationDestination(for: TitleDestination.self) { destination in
                let detail = IMDbTitlePage(preview: destination.preview, services: services) {
                    DetailView(preview: $0, services: services, artwork: destination.artwork, artworkChecked: destination.artworkChecked,
                               handoff: destination.handoff, streams: destination.streams)
                }
                .titlePage(on: path)
                if destination.opensInstantly {
                    detail.instantDestination()
                } else {
                    detail.zoomDestination(id: destination.sourceID, in: zoomNamespace)
                }
            }
            .navigationDestination(for: PersonDestination.self) { PersonView(destination: $0, services: services).titlePage(on: path) }
            .navigationDestination(for: TMDbTitleDestination.self) { TMDbTitleView(destination: $0, services: services).titlePage(on: path) }
            .navigationDestination(for: StreamRequest.self) { StreamPickerView(request: $0, services: services) }
            .navigationDestination(for: CatalogListRequest.self) { CatalogListView(request: $0, services: services) }
            // A title's page that left the stack without a word (a pop to the root) gives up its depth, so no other page there is taken
            // for one (see `TitlePageBars`).
            .onChange(of: router[keyPath: path].count) { _, count in
                if let depths = router.titlePageDepths[path], depths.contains(where: { $0 > count }) {
                    router.titlePageDepths[path] = depths.filter { $0 <= count }
                }
            }
            .backSwipe(path: path)
    }

    /// Puts the title at the top of the recent searches, and tells Search to read them again.
    private func recordSearchedTitle(_ name: String) {
        services.searchHistory.save(SearchViewModel.recording(name, into: services.searchHistory.load()))
        router.recentSearchRevision += 1
    }
}

/// A title's page in a stack: no tab bar while it is on top (iPhone and iPad; the Mac has only its sidebar), and the bar starts coming
/// back the moment it is left, as the stack's path shrinks at the start of the way back rather than once it has finished. Its depth is
/// noted with the router, so the Continue Watching bar goes and comes back with it (see `AppRouter.showsTitlePage`).
private struct TitlePageBars: ViewModifier {
    let path: ReferenceWritableKeyPath<AppRouter, NavigationPath>
    @Environment(AppRouter.self) private var router
    @State private var depth: Int?

    func body(content: Content) -> some View {
        content
            #if !targetEnvironment(macCatalyst)
            .toolbarVisibility(isOnTop ? .hidden : .visible, for: .tabBar)
            #endif
            .onAppear {
                let current = router[keyPath: path].count
                depth = current
                // Pages deeper than this one have gone, whether or not they said so.
                router.titlePageDepths[path] = (router.titlePageDepths[path] ?? []).filter { $0 < current }.union([current])
            }
            // A page covered by another keeps its place; one that has been left gives it up.
            .onDisappear {
                guard let depth, router[keyPath: path].count < depth else { return }
                router.titlePageDepths[path]?.remove(depth)
            }
    }

    /// On top, or under a page pushed over it, until the stack's path falls below it. Before it has appeared it is the page arriving.
    private var isOnTop: Bool {
        guard let depth else { return true }
        return router[keyPath: path].count >= depth
    }
}

extension View {
    /// See `TitlePageBars`.
    func titlePage(on path: ReferenceWritableKeyPath<AppRouter, NavigationPath>) -> some View {
        modifier(TitlePageBars(path: path))
    }
}

extension View {
    func appDestinations(services: AppServices, path: ReferenceWritableKeyPath<AppRouter, NavigationPath>) -> some View {
        modifier(AppDestinations(services: services, path: path))
    }
}
#endif
