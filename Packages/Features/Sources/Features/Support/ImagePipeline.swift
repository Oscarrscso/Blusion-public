#if canImport(UIKit)
import Foundation
import ImageIO
import os
import UIKit

/// Loads and caches artwork for `ArtworkImage`. Most pictures are downsampled for display; episode artwork explicitly requests
/// original pixels with a nil `maxPixelSize`. Both paths share the download queue and decoded cache.
actor ImagePipeline {
    static let shared = ImagePipeline()

    private let session: URLSession
    /// The checks for a newer copy go through a session with no cache of its own, so only `revalidate` writes to the disk cache: a server
    /// error page sent in place of a picture is never stored over the good copy.
    private let refreshSession: URLSession
    /// The downloaded files on disk, kept until the size limit (`ImageCachePolicy`) pushes the least recently used out. `URLCache` is
    /// thread-safe, so its size and usage are read and set without hopping onto the actor.
    private nonisolated let files: URLCache
    /// The picture being checked for a newer copy now, if any: one at a time.
    private var refreshing: String?
    /// `NSCache` is thread-safe and can evict under memory pressure. It has no fixed app-imposed memory limit.
    private nonisolated(unsafe) let decoded = NSCache<NSString, UIImage>()
    /// What the cache cannot be asked: the sizes each address has been decoded at, and the addresses that answered "not found". Behind a
    /// lock, so views can read it without hopping onto the actor.
    private struct Known {
        /// `NSCache` does not say what it evicts, so a size listed here may be gone; `cachedImageAtAnySize` forgets those as it meets them.
        var sizes: [String: Set<Int>] = [:]
        var missing: Set<String> = []
    }
    private let known = OSAllocatedUnfairLock(initialState: Known())
    /// Both lists are emptied when they pass this many addresses, so a long session cannot grow them without end.
    private static let knownLimit = 4000
    /// Downloads and decodes still running, keyed like the cache, so two views asking for one poster share one request.
    private struct Pending {
        let task: Task<UIImage, Error>
        var consumers: Set<UUID>
        /// The download's place in the slot queue. An urgent caller that joins it moves it past the limit.
        let slot: UUID
        var priority: TaskPriority
        var order: Int?
    }
    private var inFlight: [String: Pending] = [:]
    private var activeDownloads = 0
    private typealias Waiting = (id: UUID, priority: TaskPriority, order: Int?, continuation: CheckedContinuation<Void, Error>)
    private var waiting: [Waiting] = []
    /// Downloads that take a slot without waiting. An urgent caller asked for them, either before they reached the queue or while they waited.
    private var urgentSlots: Set<UUID> = []

    init() {
        let configuration = URLSessionConfiguration.default
        let saved = UserDefaults.standard.object(forKey: ImageCachePolicy.diskMegabytesKey) as? Int
        files = URLCache(memoryCapacity: 32 * 1024 * 1024, diskCapacity: ImageCachePolicy.diskBytes(forSavedMegabytes: saved))
        configuration.urlCache = files
        // A cached copy is served without asking the server first, however old it is: a poster is not downloaded again for its age. One
        // that is due a check is checked afterwards, in the background (see `refreshIfDue`).
        configuration.requestCachePolicy = .returnCacheDataElseLoad
        session = URLSession(configuration: configuration)
        let checks = URLSessionConfiguration.default
        checks.urlCache = nil
        checks.requestCachePolicy = .reloadIgnoringLocalCacheData
        refreshSession = URLSession(configuration: checks)
    }

    // MARK: The cache on disk

    /// The bytes the pictures take on disk now.
    nonisolated var diskUsage: Int { files.currentDiskUsage }

    /// Sets the disk cache's size. A smaller size removes the least recently used pictures until they fit.
    nonisolated func setDiskLimit(megabytes: Int) {
        files.diskCapacity = ImageCachePolicy.diskBytes(forSavedMegabytes: megabytes)
    }

    /// Removes every picture on disk. The pictures decoded in memory stay, with what is known about them (their sizes, the addresses that
    /// were missing), so the screens and the placeholders they show are as before; they go when the app is next opened.
    nonisolated func clearDisk() {
        files.removeAllCachedResponses()
    }

    /// A picture that is already decoded, without waiting. A card that scrolls back into view shows its artwork in the same
    /// frame instead of flashing its placeholder.
    nonisolated func cachedImage(for url: URL, maxPixelSize: CGFloat?) -> UIImage? {
        decoded.object(forKey: Self.key(url, maxPixelSize: maxPixelSize) as NSString)
    }

    /// A picture of `url` that is already decoded, at whatever size, the largest first, without waiting. For a stand-in that only has to be
    /// there in the first frame: the page a card opens shows the poster the card is showing instead of loading it again.
    nonisolated func cachedImageAtAnySize(for url: URL) -> UIImage? {
        let address = url.absoluteString
        let sizes = known.withLock { $0.sizes[address] } ?? []
        var gone: [Int] = []
        var found: UIImage?
        for size in sizes.sorted(by: >) {
            let key = size == Int.max ? "original|\(address)" : "\(size)|\(address)"
            if let image = decoded.object(forKey: key as NSString) {
                found = image
                break
            }
            gone.append(size)
        }
        if !gone.isEmpty {
            let evicted = gone
            known.withLock { known in
                known.sizes[address]?.subtract(evicted)
                if known.sizes[address]?.isEmpty == true { known.sizes[address] = nil }
            }
        }
        return found
    }

    /// True when `url` answered "not found" earlier in this session. Such an address is not asked again, so a card whose first choice of
    /// artwork does not exist goes straight to its fallback.
    nonisolated func isKnownMissing(_ url: URL) -> Bool {
        known.withLock { $0.missing.contains(url.absoluteString) }
    }

    /// Drops the decoded picture for this URL and size from memory. A view that still shows it keeps its own reference.
    nonisolated func evict(_ url: URL, maxPixelSize: CGFloat?) {
        decoded.removeObject(forKey: Self.key(url, maxPixelSize: maxPixelSize) as NSString)
    }

    /// The size is part of the key: a 44 pt thumbnail and a full-width backdrop of one title are different images.
    private static func key(_ url: URL, maxPixelSize: CGFloat?) -> String {
        guard let maxPixelSize else { return "original|\(url.absoluteString)" }
        return "\(Int(min(max(maxPixelSize.rounded(), 1), 4096)))|\(url.absoluteString)"
    }

    /// The image at `url`, decoded no larger than `maxPixelSize` on its long edge, or at full source resolution when nil. Concurrent requests for
    /// the same URL and size share one download. Only http, https and file URLs are loaded; a file is read from disk, never fetched.
    ///
    /// An `urgent` request does not wait for one of the download slots: it starts at once, past the limit, so a page the user has just
    /// opened is not held up by posters. A download already waiting for a slot is moved ahead when an urgent caller joins it.
    func image(for url: URL, maxPixelSize: CGFloat?, priority: TaskPriority = .medium, urgent: Bool = false,
               order: Int? = nil) async throws -> UIImage {
        guard let scheme = url.scheme?.lowercased(), ["http", "https", "file"].contains(scheme) else {
            throw ImagePipelineError.unsupportedURL
        }
        let size = maxPixelSize.map { min(max($0.rounded(), 1), 4096) }
        try Task.checkCancellation()
        let key = Self.key(url, maxPixelSize: maxPixelSize)
        if let cached = decoded.object(forKey: key as NSString) { return cached }
        if isKnownMissing(url) { throw ImagePipelineError.httpStatus(404) }
        let consumer = UUID()
        let task: Task<UIImage, Error>
        if var pending = inFlight[key] {
            pending.consumers.insert(consumer)
            inFlight[key] = pending
            promote(key: key, priority: priority, order: order)
            task = pending.task
            if urgent { skipSlotLimit(for: pending.slot) }
        } else {
            let slot = UUID()
            if urgent { urgentSlots.insert(slot) }
            task = Task(priority: priority) {
                try await acquireDownloadSlot(id: slot, priority: priority, order: order)
                defer { releaseDownloadSlot() }
                try Task.checkCancellation()
                let fetched = try await Self.fetch(url, maxPixelSize: size, session: session, files: files)
                if fetched.isDue { await refreshIfDue(url) }
                return fetched.image
            }
            inFlight[key] = Pending(task: task, consumers: [consumer], slot: slot, priority: priority, order: order)
        }
        return try await withTaskCancellationHandler {
            defer { releaseConsumer(consumer, for: key) }
            let image: UIImage
            do {
                image = try await task.value
            } catch ImagePipelineError.httpStatus(404) {
                known.withLock { known in
                    if known.missing.count >= Self.knownLimit { known.missing.removeAll() }
                    known.missing.insert(url.absoluteString)
                }
                throw ImagePipelineError.httpStatus(404)
            }
            try Task.checkCancellation()
            decoded.setObject(image, forKey: key as NSString, cost: Self.cost(of: image))
            known.withLock { known in
                if known.sizes.count >= Self.knownLimit { known.sizes.removeAll() }
                known.sizes[url.absoluteString, default: []].insert(size.map { Int($0) } ?? Int.max)
            }
            return image
        } onCancel: {
            Task { await self.releaseConsumer(consumer, for: key) }
        }
    }

    private func releaseConsumer(_ consumer: UUID, for key: String) {
        guard var pending = inFlight[key], pending.consumers.remove(consumer) != nil else { return }
        if pending.consumers.isEmpty {
            pending.task.cancel()
            inFlight[key] = nil
            urgentSlots.remove(pending.slot)
        } else { inFlight[key] = pending }
    }

    /// Reorders queued work only. The caller keeps its existing consumer and shares the same download.
    func prioritize(_ url: URL, maxPixelSize: CGFloat?, priority: TaskPriority, order: Int?) {
        promote(key: Self.key(url, maxPixelSize: maxPixelSize), priority: priority, order: order)
    }

    private func promote(key: String, priority: TaskPriority, order: Int?) {
        guard var pending = inFlight[key] else { return }
        let bestPriority = max(priority, pending.priority)
        let bestOrder = min(order ?? Int.max, pending.order ?? Int.max)
        let rank: Int? = bestOrder == Int.max ? nil : bestOrder
        guard bestPriority != pending.priority || rank != pending.order else { return }
        pending.priority = bestPriority
        pending.order = rank
        inFlight[key] = pending
        if let index = waiting.firstIndex(where: { $0.id == pending.slot }) {
            var entry = waiting.remove(at: index)
            entry.priority = bestPriority
            entry.order = rank
            if activeDownloads < (bestPriority >= .high ? 6 : 5) {
                activeDownloads += 1
                entry.continuation.resume()
            } else {
                enqueue(entry)
            }
        }
    }

    private func enqueue(_ entry: Waiting) {
        let index = waiting.firstIndex {
            $0.priority < entry.priority || ($0.priority == entry.priority && ($0.order ?? Int.max) > (entry.order ?? Int.max))
        } ?? waiting.endIndex
        waiting.insert(entry, at: index)
    }

    private func acquireDownloadSlot(id: UUID, priority: TaskPriority, order: Int?) async throws {
        try Task.checkCancellation()
        let pending = inFlight.values.first { $0.slot == id }
        let effectivePriority = pending?.priority ?? priority
        let effectiveOrder = pending?.order ?? order
        // Keep one of the six slots available for title logos, even when posters fill the queue.
        if urgentSlots.remove(id) != nil || activeDownloads < (effectivePriority >= .high ? 6 : 5) { activeDownloads += 1; return }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                enqueue((id, effectivePriority, effectiveOrder, continuation))
            }
        } onCancel: {
            Task { await self.cancelWaitingDownload(id) }
        }
    }

    /// An urgent caller joined the download in `slot`. A download waiting for a slot takes one now, past the limit; one not yet in the
    /// queue is marked so it takes one as soon as it asks.
    private func skipSlotLimit(for slot: UUID) {
        if let index = waiting.firstIndex(where: { $0.id == slot }) {
            activeDownloads += 1
            waiting.remove(at: index).continuation.resume()
        } else {
            urgentSlots.insert(slot)
        }
    }

    private func cancelWaitingDownload(_ id: UUID) {
        guard let index = waiting.firstIndex(where: { $0.id == id }) else { return }
        waiting.remove(at: index).continuation.resume(throwing: CancellationError())
    }

    private func releaseDownloadSlot() {
        activeDownloads -= 1
        guard let next = waiting.first, activeDownloads < (next.priority >= .high ? 6 : 5) else { return }
        activeDownloads += 1
        waiting.removeFirst().continuation.resume()
    }

    /// Runs off the actor, so a slow download or decode never blocks requests for other images. `isDue` is true when the picture came
    /// from the disk cache and has been there long enough to be checked for a newer copy.
    private nonisolated static func fetch(_ url: URL, maxPixelSize: CGFloat?, session: URLSession,
                                          files: URLCache) async throws -> (image: UIImage, isDue: Bool) {
        // A file on this device (a download's cached artwork) is read as it is: it is never stale and never checked for a newer copy.
        if url.isFileURL {
            let data = try Data(contentsOf: url)
            guard let image = decode(data, maxPixelSize: maxPixelSize) else { throw ImagePipelineError.undecodable }
            return (image, false)
        }
        let (data, response) = try await session.data(from: url)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw ImagePipelineError.httpStatus(http.statusCode)
        }
        guard let image = decode(data, maxPixelSize: maxPixelSize) else {
            throw ImagePipelineError.undecodable
        }
        // A copy from the network is dated about now, so only one that has been on disk a while is old enough to be due.
        // One with no date is checked once, and dated then (see `revalidate`).
        let fetched = ImageCachePolicy.date(fromHeader: (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Date"))
        return (image, ImageCachePolicy.isDueForRefresh(url: url, fetched: fetched))
    }

    /// Checks a picture that has been on disk a while for a newer copy, in the background, at the lowest priority, one at a time, and only
    /// when no other picture is loading or waiting: the loads the screens ask for are never held up, reordered or joined by it. A newer
    /// copy only replaces the file on disk. The picture decoded in memory, the one on screen and the placeholders stay as they are, so the
    /// newer copy is used the next time the picture is read from disk. One skipped because others were loading is checked the next time.
    private func refreshIfDue(_ url: URL) {
        // This picture's own download still holds its slot here.
        guard refreshing == nil, activeDownloads <= 1, waiting.isEmpty else { return }
        refreshing = url.absoluteString
        let session = refreshSession
        let files = files
        Task.detached(priority: .background) {
            await Self.revalidate(url, session: session, files: files)
            await self.finishRefresh()
        }
    }

    private func finishRefresh() {
        refreshing = nil
    }

    /// Asks the server, at the network's lowest priority, whether the stored copy is still current (If-None-Match, If-Modified-Since).
    /// Unchanged: the stored copy is kept and dated now, so it is not asked about again for a while. Changed: the new copy is stored on
    /// disk. A failure leaves the stored copy as it is.
    private nonisolated static func revalidate(_ url: URL, session: URLSession, files: URLCache) async {
        let plain = URLRequest(url: url)
        guard let stored = files.cachedResponse(for: plain), let old = stored.response as? HTTPURLResponse else { return }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        if let tag = old.value(forHTTPHeaderField: "ETag") { request.setValue(tag, forHTTPHeaderField: "If-None-Match") }
        if let modified = old.value(forHTTPHeaderField: "Last-Modified") { request.setValue(modified, forHTTPHeaderField: "If-Modified-Since") }
        guard let (data, response) = await lowPriorityData(for: request, session: session), let http = response as? HTTPURLResponse else { return }
        if http.statusCode == 304 || ((200..<300).contains(http.statusCode) && data == stored.data) {
            var headers: [String: String] = [:]
            for (key, value) in old.allHeaderFields {
                guard let key = key as? String, let value = value as? String, key.lowercased() != "date" else { continue }
                headers[key] = value
            }
            headers["Date"] = ImageCachePolicy.header(for: Date())
            if let renewed = HTTPURLResponse(url: url, statusCode: old.statusCode, httpVersion: "HTTP/1.1", headerFields: headers) {
                files.storeCachedResponse(CachedURLResponse(response: renewed, data: stored.data), for: plain)
            }
            return
        }
        // Validate the compressed source without making a reduced image, including for original-resolution episode requests.
        guard (200..<300).contains(http.statusCode), let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetStatus(source) == .statusComplete, CGImageSourceGetCount(source) > 0 else { return }
        files.storeCachedResponse(CachedURLResponse(response: http, data: data), for: plain)
    }

    /// A request at the network's lowest priority, so it never competes with the pictures being loaded for the screen.
    private nonisolated static func lowPriorityData(for request: URLRequest, session: URLSession) async -> (Data, URLResponse)? {
        await withCheckedContinuation { continuation in
            let task = session.dataTask(with: request) { data, response, _ in
                guard let data, let response else { return continuation.resume(returning: nil) }
                continuation.resume(returning: (data, response))
            }
            task.priority = URLSessionTask.lowPriority
            task.resume()
        }
    }

    /// Original requests decode the provider's complete image; other requests retain ImageIO's direct thumbnail decoding.
    private nonisolated static func decode(_ data: Data, maxPixelSize: CGFloat?) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        guard let maxPixelSize else {
            guard let cgImage = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
            else { return nil }
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
            let orientation = (properties?[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
            let orientations: [UIImage.Orientation] = [.up, .upMirrored, .down, .downMirrored, .leftMirrored, .right, .rightMirrored, .left]
            return UIImage(cgImage: cgImage, scale: 1, orientation: orientations[(1...8).contains(orientation) ? orientation - 1 : 0])
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: cgImage)
    }

    private static func cost(of image: UIImage) -> Int {
        guard let cgImage = image.cgImage else { return 0 }
        return cgImage.bytesPerRow * cgImage.height
    }
}

enum ImagePipelineError: Error, Sendable {
    case unsupportedURL
    case httpStatus(Int)
    case undecodable
}
#endif
