#if canImport(UIKit)
import SwiftUI
import StremioKit
import UIKit

/// Loads the posters just off screen in a long grid ahead of time and holds them, so scrolling shows the picture in the card's first
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

    /// Keeps only offscreen requests in the prefetch buffer. Decoded images stay in the shared cost-limited NSCache after leaving it,
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
#endif
