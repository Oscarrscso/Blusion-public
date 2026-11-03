#if canImport(UIKit)
import SwiftUI
import StremioKit
import UIKit

/// Loads the posters just off screen in a shelf or grid ahead of time and holds them, so scrolling shows the picture in the card's first
/// frame. A grid owns one (as `@State`) and tells it which requests it wants after every change of what is visible. Loads run at low
/// priority and are cancelled when the request is no longer wanted. The decoded images are held strongly while they are wanted, so
/// the buffer does not empty when the shared cache trims; they are released when they leave the buffer.
@MainActor
final class ArtworkPrefetcher {
    /// One image as a card asks for it: the pipeline's cache key is this URL and size.
    struct Request: Hashable, Sendable {
        let url: URL
        let maxPixelSize: CGFloat
    }

    private var wanted: Set<Request> = []
    private var tasks: [Request: Task<Void, Never>] = [:]
    private var held: [Request: UIImage] = [:]

    /// Keeps requests in the prefetch buffer. Decoded images stay in the shared NSCache after leaving it,
    /// so returning to a poster does not force another decode and another screen can continue reusing the same image.
    func update(wanted newWanted: [Request]) {
        let newSet = Set(newWanted)
        for request in wanted.subtracting(newSet) {
            tasks.removeValue(forKey: request)?.cancel()
            held.removeValue(forKey: request)
        }
        wanted = newSet
        for request in newWanted where tasks[request] == nil && held[request] == nil {
            if let cached = ImagePipeline.shared.cachedImage(for: request.url, maxPixelSize: request.maxPixelSize) {
                held[request] = cached
                continue
            }
            tasks[request] = Task { [weak self] in
                let image = try? await ImagePipeline.shared.image(for: request.url, maxPixelSize: request.maxPixelSize, priority: .low)
                guard !Task.isCancelled else { return }
                self?.finish(request, image: image)
            }
        }
    }

    /// Stops all loading and lets go of the held images, but leaves the decoded cache alone: the grid may come straight back.
    func cancelAll() {
        for task in tasks.values { task.cancel() }
        tasks = [:]
        held = [:]
        wanted = []
    }

    private func finish(_ request: Request, image: UIImage?) {
        // Completed failures must release their task entry too, or a subsequent update cannot retry them.
        guard wanted.contains(request) else { return }
        tasks[request] = nil
        if let image { held[request] = image }
    }
}
/// The cards of one shelf that `BufferedArtwork` keeps loaded, drawn as the shelf draws them.
struct ArtworkShelf {
    let items: [MetaPreview]
    let aspect: CardAspect
    var size: CardSize = .medium
    var width: CGFloat? = nil
    var usesBetterPosters = false
    /// The shelf's own Hero posters setting. Nil takes the environment's (a row's), then the Settings'.
    var heroOverride: Bool? = nil
}

/// Resolves and downloads buffered titles of one or more shelves independently of SwiftUI creating their offscreen card views.
struct BufferedArtwork: ViewModifier {
    let shelves: [ArtworkShelf]
    @State private var prefetcher = ArtworkPrefetcher()
    @State private var heroArtworkByID: [String: TMDbArtwork] = [:]
    @State private var checkedHeroIDs: Set<String> = []
    @AppStorage(DefaultsSettingsStore.Keys.usesHeroPosters) private var usesHeroPosters = false
    @Environment(\.heroPosterOverride) private var heroPosterOverride
    @Environment(PosterRatingsStore.self) private var ratingsStore: PosterRatingsStore?
    @Environment(\.displayScale) private var displayScale
    @Environment(\.layoutMetrics) private var metrics
    @Environment(\.isLandscape) private var isLandscape

    private func usesHeroArtwork(_ shelf: ArtworkShelf) -> Bool {
        ((shelf.heroOverride ?? heroPosterOverride) ?? usesHeroPosters) && shelf.aspect == .poster
    }

    private var heroItems: [MetaPreview] {
        shelves.filter { usesHeroArtwork($0) }.flatMap(\.items)
    }

    private var requests: [ArtworkPrefetcher.Request] {
        shelves.flatMap { shelf in
            shelf.items.flatMap { item in
                MediaCard.artworkRequests(for: item, aspect: shelf.aspect, size: shelf.size, width: shelf.width, metrics: metrics,
                                          isLandscape: isLandscape, displayScale: displayScale, usesBetterPosters: shelf.usesBetterPosters,
                                          usesHeroPosters: usesHeroArtwork(shelf),
                                          heroArtwork: heroArtworkByID[item.identity] ?? ratingsStore?.cachedHeroArtwork(for: item),
                                          heroArtworkChecked: checkedHeroIDs.contains(item.identity))
            }
        }
    }

    func body(content: Content) -> some View {
        content
            .task(id: requests) { prefetcher.update(wanted: requests) }
            .task(id: heroItems.map(\.identity)) {
                for item in heroItems {
                    guard !Task.isCancelled else { return }
                    await ratingsStore?.prewarmHeroArtwork(for: item)
                    guard !Task.isCancelled else { return }
                    if let artwork = ratingsStore?.cachedHeroArtwork(for: item) {
                        // The store's session cache isn't observed; publish the result so prefetch switches to the actual poster URL.
                        heroArtworkByID[item.identity] = artwork
                    }
                    checkedHeroIDs.insert(item.identity)
                    if let logo = item.logo ?? heroArtworkByID[item.identity]?.logo {
                        await HeroLoader.warmLogo(logo, priority: .low)
                    }
                }
            }
            .onDisappear { prefetcher.cancelAll() }
    }
}
#endif
