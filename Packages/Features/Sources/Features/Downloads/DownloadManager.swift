#if canImport(Darwin)
import Foundation
import Observation
import Persistence
import StremioKit
import PlayerKit

/// One device-local queue, shared by every screen and the background session delegate.
@MainActor
@Observable
public final class DownloadManager {
    public private(set) var items: [DownloadItem] = []
    public private(set) var errorMessage: String?
    public private(set) var isReady = false
    public var backgroundCompletion: (() -> Void)?
    private let store: any DownloadStore
    private let secrets: any SecretStore
    private let settings: any SettingsStore
    private let streams: StreamService
    private let subtitles: SubtitleService
    private let fallback: Bool
    private let hardwareAV1: Bool
    private let persistent: Bool
    private var reconciling = true
    private var root: URL?
    private var adapter: DownloadSession?
    private var saving: Task<Void, any Error>?
    private var pausing: Set<UUID> = []
    public private(set) var enqueueing: Set<String> = []
    public private(set) var streamDownloads: [String: UUID] = [:]
    public private(set) var loadingRequests: Set<String> = []
    private var startup: Task<Void, Never>?
    private var listener: Task<Void, Never>?
    private var subtitleTasks: [UUID: Task<Void, Never>] = [:]
    private var retryTasks: [UUID: Task<Void, Never>] = [:]
    private var active: [UUID: URLSessionDownloadTask] = [:]
    private var preparing: Set<UUID> = []
    private var deleting: Set<UUID> = []
    private var playing: Set<UUID> = []
    private var deleteAfterClose: Set<UUID> = []
    public private(set) var transferSpeeds: [UUID: Double] = [:]
    private var rateSamples: [UUID: (bytes: Int64, date: Date)] = [:]
    private var lastSaved: [UUID: Date] = [:]

    /// SecretStore is the only app-owned persistent location of request/response credentials and matching material.
    private struct Credential: Codable {
        var url: URL
        var headers: [String: String]
        var identity: PlaybackStreamIdentity
        var subtitles: [SubtitleItem]
        var validator: String?
        var offset: Int64 = 0
        var total: Int64 = 0
        var resumeCellular: Bool?
    }
    public init(store: any DownloadStore, secrets: any SecretStore, settings: any SettingsStore, streams: StreamService,
                subtitles: SubtitleService, fallback: Bool, hardwareAV1: Bool, persistent: Bool = true) {
        self.store = store; self.secrets = secrets; self.settings = settings; self.streams = streams
        self.subtitles = subtitles; self.fallback = fallback; self.hardwareAV1 = hardwareAV1; self.persistent = persistent
    }
    public var storageBytes: Int64 {
        guard let root, let files = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        return max(items.reduce(0) { $0 + $1.received },
                   files.reduce(0) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) })
    }
    public func configuration() async -> PolicyConfiguration {
        var config = await settings.load().policy(fallbackEngineLinked: fallback, decodesAV1InHardware: hardwareAV1)
        config.playerPreference = .builtIn
        return config
    }
    public func start() async {
        if let startup { await startup.value; return }
        let task = Task { await launch() }
        startup = task
        await task.value
    }
    private func launch() async {
        defer { isReady = true }
        do {
            items = try await store.loadAll()
            deleting = Set(items.filter { $0.pendingDeletion == true }.map(\.id))
            guard persistent else { return }
            // Older records can recover typed release facts from their device-local secret, without querying an addon.
            for item in items where item.mediaDetails == nil {
                if let saved = try? await credential(item.id), let current = index(item.id) {
                    let stream = AddonStream(name: saved.identity.streamName, description: saved.identity.filename, source: .direct(saved.url))
                    items[current].mediaDetails = Self.details(StreamQuality.parse(stream))
                }
            }
            root = try DownloadFiles.directory()
            let adapter = DownloadSession(root: root!)
            self.adapter = adapter
            // Buffer callbacks until task reconciliation has finished; never replace a still-running task.
            let tasks = await adapter.tasks()
            for task in tasks {
                guard let id = task.taskDescription.flatMap(UUID.init(uuidString:)),
                      let index = index(id), !deleting.contains(id), ![.paused, .failed, .complete].contains(items[index].state), active[id] == nil,
                      let download = task as? URLSessionDownloadTask else { task.cancel(); continue }
                active[id] = download
                items[index].state = .downloading
                task.resume()
            }
            for i in items.indices {
                if items[i].state == .downloading, active[items[i].id] == nil { items[i].state = .queued }
                if items[i].state == .complete, localFile(items[i]) == nil {
                    items[i].state = .failed; items[i].failure = "File missing"
                }
            }
            try await persist()
            listener = Task { [weak self] in
                for await event in adapter.events { await self?.handle(event) }
            }
            adapter.reconciliationBarrier()
        } catch { errorMessage = "Downloads unavailable" }
    }
    private func index(_ id: UUID) -> Int? { items.firstIndex { $0.id == id } }
    private func key(_ id: UUID) -> String { "download.\(id.uuidString)" }
    private func credential(_ id: UUID) async throws -> Credential {
        guard let text = try await secrets.get(key(id)), let data = Data(base64Encoded: text) else { throw DownloadError.credentials }
        return try JSONDecoder().decode(Credential.self, from: data)
    }
    private func save(_ credential: Credential, id: UUID) async throws {
        try await secrets.set(JSONEncoder().encode(credential).base64EncodedString(), for: key(id))
    }
    private func persist() async throws {
        let previous = saving
        let records = items
        let store = store
        let task = Task {
            _ = try? await previous?.value
            try await store.save(records)
        }
        saving = task
        try await task.value
    }
    private enum DownloadError: Error { case credentials, storage, format, response }

    @discardableResult
    public func enqueue(_ ranked: RankedStream, request: StreamRequest) async -> Bool {
        guard enqueueing.insert(ranked.id).inserted else { return true }
        defer { enqueueing.remove(ranked.id) }
        await start()
        let config = await configuration()
        guard DownloadItem.validRequest(request), let container = DownloadEligibility.container(for: ranked, config: config),
              case .direct(let url) = ranked.stream.source, let identity = PlaybackStreamIdentity.make(for: ranked.stream) else {
            errorMessage = "This stream cannot be downloaded"; return false
        }
        // Deduplicate only the same release; different releases retain different UUIDs.
        for item in items where item.request.identity == request.identity {
            if let old = try? await credential(item.id), old.identity.matches(ranked.stream), item.pendingDeletion != true {
                streamDownloads[ranked.id] = item.id
                return true
            }
        }
        let route = PlaybackPolicy.route(for: ranked.stream, container: container, quality: ranked.quality, config: config)
        let usesFallback: Bool
        if case .fallback = route { usesFallback = true } else { usesFallback = false }
        var safeRequest = request
        safeRequest.title = Self.displayText(request.title)
        safeRequest.seriesName = request.seriesName.map(Self.displayText)
        safeRequest.year = request.year.flatMap { $0.allSatisfy(\.isNumber) ? $0 : nil }
        var item = DownloadItem(request: safeRequest, addonID: ranked.addon.id, container: container, usesFallback: usesFallback)
        item.expected = max(ranked.stream.behaviorHints.videoSize ?? 0, 0)
        item.mediaDetails = Self.details(ranked.quality)
        do {
            try await save(Credential(url: url, headers: ranked.stream.behaviorHints.proxyHeaders?.request ?? [:], identity: identity,
                                      subtitles: ranked.stream.subtitles), id: item.id)
            items.insert(item, at: 0)
            do { try await persist() } catch {
                items.removeAll { $0.id == item.id }
                try? await secrets.remove(key(item.id))
                throw error
            }
            streamDownloads[ranked.id] = item.id
            await pump()
            return true
        } catch { errorMessage = "Could not save download"; return false }
    }
    private static func details(_ quality: StreamQuality) -> [String: String] {
        var values: [String: String] = [:]
        values["Resolution"] = quality.resolutionLabel
        values["Source"] = quality.source?.label
        values["Video"] = quality.videoCodec?.label
        let audio = quality.audioCodecs.map(\.label) + (quality.hasAtmos ? ["Atmos"] : [])
        if !audio.isEmpty { values["Audio"] = audio.joined(separator: ", ") }
        var hdr: [String] = []
        if quality.isDolbyVision { hdr.append("Dolby Vision") }
        if quality.isHDR10Plus { hdr.append("HDR10+") }
        else if quality.isHDR { hdr.append("HDR10") }
        if quality.isHLG { hdr.append("HLG") }
        if !hdr.isEmpty { values["Dynamic Range"] = hdr.joined(separator: ", ") }
        if quality.isRemux { values["Release"] = "Remux" }
        return values
    }
    public func speed(for id: UUID, at date: Date) -> Double? {
        guard let sample = rateSamples[id], date.timeIntervalSince(sample.date) < 5 else { return nil }
        return transferSpeeds[id]
    }
    public func item(for request: StreamRequest) -> DownloadItem? {
        items.first { $0.request.identity == request.identity && $0.pendingDeletion != true }
    }
    public func item(forStream id: String) -> DownloadItem? {
        guard let downloadID = streamDownloads[id] else { return nil }
        return items.first { $0.id == downloadID && $0.pendingDeletion != true }
    }
    /// Match UI rows using secrets in memory; no remote stream ID is copied into the persisted metadata.
    public func bindStream(_ ranked: RankedStream, request: StreamRequest) async {
        guard item(forStream: ranked.id) == nil else { return }
        await start()
        for item in items where item.request.identity == request.identity && item.pendingDeletion != true {
            if let saved = try? await credential(item.id), saved.identity.matches(ranked.stream), index(item.id) != nil {
                streamDownloads[ranked.id] = item.id
                return
            }
        }
    }
    /// Title/episode actions resolve eligible streams with the same built-in policy as stream cards.
    public func enqueueBest(_ request: StreamRequest) async {
        guard loadingRequests.insert(request.identity).inserted else { return }
        defer { loadingRequests.remove(request.identity) }
        let config = await configuration()
        let fetched = await streams.fetch(request)
        var listing = StreamListing(asking: fetched.asked, config: config)
        for await response in fetched.responses { listing.apply(response) }
        for await result in streams.sniff(listing.sniffTargets) { listing.setContainer(result.container, forKey: result.key) }
        guard let choice = AutoStreamRanking.ranked(listing.items, duration: request.expectedDuration)
            .first(where: { DownloadEligibility.container(for: $0.item, config: config) != nil })?.item else {
            errorMessage = "No downloadable streams"; return
        }
        await enqueue(choice, request: request)
    }
    public func pause(_ id: UUID) async {
        guard let i = index(id), items[i].state != .complete, pausing.insert(id).inserted else { return }
        defer {
            pausing.remove(id)
            if deleting.contains(id) { Task { await remove(id) } }
            else { Task { await pump() } }
        }
        items[i].state = .paused
        transferSpeeds[id] = nil; rateSamples[id] = nil
        retryTasks.removeValue(forKey: id)?.cancel()
        do { try await persist() } catch { errorMessage = "Could not save pause" }
        if let task = active[id] {
            // didCompleteWithError carries any available resume data. Keep active until that event is consumed.
            if let data = await task.cancelByProducingResumeData(), index(id) != nil, !deleting.contains(id) {
                do { try await saveResume(data, id: id, task: task) }
                catch { await fail(id, "Could not save resume data") }
            }
        }
        await pump()
    }
    private func saveResume(_ data: Data, id: UUID, task: URLSessionTask?) async throws {
        var saved = try await credential(id)
        // A temporary file from an explicit Range task contains only a suffix. Never replace the verified prefix with it.
        guard saved.offset == 0 else {
            try await secrets.remove(key(id) + ".resume")
            return
        }
        try await secrets.set(data.base64EncodedString(), for: key(id) + ".resume")
        _ = adapter?.preservePartial(data, id: id)
        saved.resumeCellular = task?.originalRequest?.allowsCellularAccess ?? false
        try await save(saved, id: id)
    }
    public func resume(_ id: UUID) async {
        guard let i = index(id), [.paused, .failed].contains(items[i].state), !deleting.contains(id) else { return }
        items[i].state = .queued; items[i].failure = nil; items[i].retries = 0
        do { try await persist(); await pump() } catch { await fail(id, "Could not save download") }
    }
    public func delete(_ id: UUID) async {
        guard let i = index(id) else { return }
        deleting.insert(id)
        items[i].pendingDeletion = true
        if items[i].state != .complete { items[i].state = .paused }
        retryTasks.removeValue(forKey: id)?.cancel()
        subtitleTasks.removeValue(forKey: id)?.cancel()
        do { try await persist() }
        catch { errorMessage = "Could not save deletion"; return }
        if playing.contains(id) { deleteAfterClose.insert(id); return }
        active[id]?.cancel()
        // Retain the record until cancellation's final callback: it may still deliver a file.
        if active[id] != nil { return }
        await remove(id)
    }
    private func remove(_ id: UUID) async {
        guard !preparing.contains(id), !pausing.contains(id) else { return }
        do {
            if let root { try DownloadFiles.remove(id, in: root) }
            try await secrets.remove(key(id))
            try await secrets.remove(key(id) + ".resume")
            items.removeAll { $0.id == id }
            streamDownloads = streamDownloads.filter { $0.value != id }
            transferSpeeds[id] = nil; rateSamples[id] = nil
            try await persist()
            deleting.remove(id); deleteAfterClose.remove(id)
        } catch { errorMessage = "Could not delete download" }
        await pump()
    }
    public func deleteAll() async { for id in items.map(\.id) { await delete(id) } }
    public func preferencesChanged() async {
        // A new request is required because cellular access belongs to the request, including resumed system requests.
        let ids = items.filter { $0.state == .downloading || $0.state == .queued }.map(\.id)
        for id in ids {
            await pause(id)
            try? await secrets.remove(key(id) + ".resume")
            if let i = index(id) { items[i].state = .queued }
        }
        try? await persist()
        await pump()
    }
    private func enoughSpace(_ remaining: Int64, excluding id: UUID) throws {
        guard let root else { throw DownloadError.storage }
        let capacity = try root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage
        guard let capacity, capacity > 256 * 1024 * 1024 else { throw DownloadError.storage }
        var available = capacity - 256 * 1024 * 1024
        guard max(remaining, 0) < available else { throw DownloadError.storage }
        available -= max(remaining, 0)
        // Reserve remaining bytes for the other live transfers too, without overflowing on untrusted size hints.
        for item in items where item.id != id && active[item.id] != nil {
            let needed = max(item.expected - item.received, 0)
            guard needed < available else { throw DownloadError.storage }
            available -= needed
        }
    }
    private func pump() async {
        guard persistent, !reconciling, active.count < 3, preparing.isEmpty, pausing.isEmpty,
              let item = items.last(where: { $0.state == .queued && !deleting.contains($0.id) && retryTasks[$0.id] == nil }),
              let adapter else { return }
        let id = item.id
        preparing.insert(id)
        defer {
            preparing.remove(id)
            if deleting.contains(id) { Task { await remove(id) } }
            else if active.count < 3 { Task { await pump() } }
        }
        do {
            var credential = try await credential(id)
            let settings = await settings.load()
            let partial = root!.appendingPathComponent(id.uuidString + ".partial")
            let count = Int64((try? partial.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            // Only send Range with both a full-representation validator and a usable partial.
            let offset = count > 0 && credential.validator != nil ? count : 0
            credential.offset = offset
            try await save(credential, id: id)
            try enoughSpace(max(item.expected - offset, 0), excluding: id)
            // Explicit Range is preferred; OS resume data is a fallback when its private temporary file can't be copied.
            let resume: Data?
            if offset == 0, credential.resumeCellular == settings.downloadsAllowCellular,
               let encoded = try await secrets.get(key(id) + ".resume") { resume = Data(base64Encoded: encoded) }
            else { resume = nil }
            guard let i = index(id), items[i].state == .queued, !deleting.contains(id) else { return }
            items[i].state = .downloading
            try await persist()
            guard let current = index(id), items[current].state == .downloading, !deleting.contains(id) else { return }
            transferSpeeds[id] = nil; rateSamples[id] = nil
            active[id] = adapter.start(id: id, url: credential.url, headers: credential.headers,
                                       cellular: settings.downloadsAllowCellular, resume: resume, offset: offset, validator: credential.validator)
        } catch {
            await fail(id, error is DownloadError ? "Not enough storage or missing credentials" : "Could not start download")
        }
    }
    private func fail(_ id: UUID, _ message: String) async {
        guard let i = index(id) else { return }
        items[i].state = .failed; items[i].failure = message
        do { try await persist() } catch { errorMessage = "Could not save download state" }
    }
    private func handle(_ event: DownloadSession.Event) async {
        switch event {
        case .progress(let id, let taskID, let received, let expected, let response):
            guard active[id]?.taskIdentifier == taskID else { return }
            guard let i = index(id), items[i].state == .downloading, !deleting.contains(id) else { return }
            do {
                var credential = try await credential(id)
                if credential.offset == 0, credential.validator == nil {
                    credential.validator = response.validator
                    credential.total = expected
                    try await save(credential, id: id)
                }
                guard let i = index(id) else { return }
                let offset = response.status == 206 ? credential.offset : 0
                items[i].received = received + offset
                items[i].expected = expected > 0 ? expected + offset : 0
                let now = Date()
                if let sample = rateSamples[id], items[i].received >= sample.bytes {
                    let elapsed = now.timeIntervalSince(sample.date)
                    if elapsed > 0 {
                        let speed = Double(items[i].received - sample.bytes) / elapsed
                        transferSpeeds[id] = (transferSpeeds[id] ?? speed) * 0.7 + speed * 0.3
                    }
                }
                rateSamples[id] = (items[i].received, now)
                if lastSaved[id].map({ Date().timeIntervalSince($0) > 2 }) ?? true {
                    try enoughSpace(expected > 0 ? max(expected - received, 0) : 0, excluding: id)
                    try await persist(); lastSaved[id] = Date()
                }
            } catch {
                await fail(id, "Storage unavailable")
                active[id]?.cancel(byProducingResumeData: { _ in })
            }
        case .file(let id, let taskID, let name, let response):
            guard let root else { return }
            let incoming = root.appendingPathComponent(name)
            defer { try? FileManager.default.removeItem(at: incoming) }
            guard let i = index(id), !deleting.contains(id),
                  active[id]?.taskIdentifier == taskID || (reconciling && active[id] == nil && items[i].state == .queued) else { return }
            if reconciling, items[i].state == .queued { items[i].state = .downloading }
            if [401, 403, 410].contains(response.status) {
                try? FileManager.default.removeItem(at: incoming)
                await retry(id, expired: true)
                return
            }
            guard items[i].state == .downloading else { try? FileManager.default.removeItem(at: incoming); return }
            do { try await finish(id, incoming: incoming, response: response) }
            catch {
                try? FileManager.default.removeItem(at: incoming)
                if error is DownloadError { await fail(id, "Invalid media response") }
                else { await fail(id, "Could not save media") }
            }
        case .finished(let id, let taskID, let code, let resume, let response):
            guard active[id]?.taskIdentifier == taskID || (reconciling && active[id] == nil && index(id) != nil) else { return }
            let task = active[id]
            if let resume, index(id) != nil, !deleting.contains(id) {
                do { try await saveResume(resume, id: id, task: task) }
                catch { await fail(id, "Could not save resume data") }
            }
            active[id] = nil
            transferSpeeds[id] = nil; rateSamples[id] = nil
            if deleting.contains(id) { await remove(id); return }
            if let i = index(id), items[i].state == .downloading {
                if [401, 403, 410].contains(response.status) {
                    await retry(id, expired: true)
                } else if code == NSFileWriteOutOfSpaceError || code == URLError.cannotWriteToFile.rawValue {
                    await fail(id, "Not enough storage")
                } else if code != nil {
                    // Invalid opaque resume data gets one clean request on the shared retry budget.
                    if resume == nil { try? await secrets.remove(key(id) + ".resume") }
                    await retry(id, expired: false)
                } else { await fail(id, "Download interrupted") }
            }
            await pump()
        case .reconciled:
            for id in Array(deleting) where active[id] == nil { await remove(id) }
            // A crash can occur between the delegate's move and the store commit. Uncommitted staging is never promoted blindly.
            if let root, let files = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) {
                for item in items where active[item.id] == nil {
                    for file in files where DownloadFiles.valid(file.lastPathComponent, for: item.id) {
                        let name = file.lastPathComponent
                        if name.contains(".incoming-") || (item.mediaPath == nil && name != item.id.uuidString + ".partial") {
                            try? FileManager.default.removeItem(at: file)
                        }
                    }
                }
            }
            reconciling = false
            await pump()
        case .drained:
            let jobs = Array(subtitleTasks.values)
            let completion = backgroundCompletion
            backgroundCompletion = nil
            // Keep consuming progress from other transfers while optional subtitle requests finish.
            Task {
                for job in jobs { await job.value }
                do { try await persist() } catch { errorMessage = "Could not save download state" }
                completion?()
            }
        }
    }
    private func retry(_ id: UUID, expired: Bool) async {
        guard let i = index(id), items[i].state == .downloading, items[i].retries < 3 else {
            await fail(id, "Download failed"); return
        }
        items[i].retries += 1
        items[i].state = .queued
        let delay = items[i].retries * 2
        try? await persist()
        retryTasks[id] = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            guard let self, let i = index(id), items[i].state == .queued, !deleting.contains(id) else { return }
            if expired {
                preparing.insert(id)
                defer {
                    preparing.remove(id)
                    if deleting.contains(id) { Task { await remove(id) } }
                    else { Task { await pump() } }
                }
                do { try await refresh(id) } catch {
                    retryTasks[id] = nil
                    await fail(id, "Original stream could not be renewed")
                    return
                }
            }
            retryTasks[id] = nil
            await pump()
        }
    }
    private func refresh(_ id: UUID) async throws {
        guard let i = index(id) else { throw DownloadError.credentials }
        let item = items[i]
        var old = try await credential(id)
        try await streams.registry.load()
        let fetched = await streams.fetchUncached(item.request)
        let config = await configuration()
        var listing = StreamListing(asking: fetched.asked, config: config)
        for await response in fetched.responses { listing.apply(response) }
        for await result in streams.sniff(listing.sniffTargets) { listing.setContainer(result.container, forKey: result.key) }
        let snapshot = PlaybackSnapshot(request: item.request, stream: old.identity, addonID: item.addonID.uuidString)
        guard let match = snapshot.match(in: listing.items),
              let container = DownloadEligibility.container(for: match, config: config), container.rawValue == item.container,
              case .direct(let url) = match.stream.source, let identity = PlaybackStreamIdentity.make(for: match.stream),
              let current = index(id), items[current].state == .queued, !deleting.contains(id) else { throw DownloadError.credentials }
        old.url = url; old.headers = match.stream.behaviorHints.proxyHeaders?.request ?? [:]
        old.identity = identity; old.subtitles = match.stream.subtitles
        // Validator and expected total remain the ORIGINAL representation's. If-Range must validate before any append.
        try await save(old, id: id)
        try await secrets.remove(key(id) + ".resume")
    }
    private func finish(_ id: UUID, incoming: URL, response: DownloadSession.Response) async throws {
        guard let i = index(id), let root else { throw DownloadError.response }
        let item = items[i]
        let credential = try await credential(id)
        guard [200, 206].contains(response.status) else {
            if response.status == 416 {
                try? FileManager.default.removeItem(at: root.appendingPathComponent(id.uuidString + ".partial"))
                var fresh = credential; fresh.offset = 0; fresh.validator = nil; fresh.total = 0
                try await save(fresh, id: id); try await secrets.remove(key(id) + ".resume")
                await retry(id, expired: false); return
            }
            if response.status == 429 || response.status >= 500 { await retry(id, expired: false); return }
            throw DownloadError.response
        }
        let partial = root.appendingPathComponent(id.uuidString + ".partial")
        let incomingSize = Int64(try incoming.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
        var source = incoming
        if response.status == 206, credential.offset > 0 {
            guard let range = response.range, let parsed = Self.range(range), parsed.0 == credential.offset,
                  parsed.1 >= parsed.0, parsed.1 - parsed.0 + 1 == incomingSize, parsed.1 + 1 == parsed.2,
                  credential.total <= 0 || credential.total == parsed.2,
                  let validator = credential.validator, validator == response.validator,
                  Int64(try partial.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) == credential.offset else {
                // Incompatible or unverifiable representation: remove the partial and explicitly restart, never concatenate.
                try? FileManager.default.removeItem(at: partial)
                var fresh = credential; fresh.offset = 0; fresh.validator = nil; fresh.total = 0
                try await save(fresh, id: id); try await secrets.remove(key(id) + ".resume")
                await retry(id, expired: false)
                return
            }
            try enoughSpace(0, excluding: id)
            try await Task.detached(priority: .utility) {
                let output = try FileHandle(forWritingTo: partial)
                defer { try? output.close() }
                try output.seekToEnd()
                let input = try FileHandle(forReadingFrom: incoming)
                defer { try? input.close() }
                while let bytes = try input.read(upToCount: 1024 * 1024), !bytes.isEmpty { try output.write(contentsOf: bytes) }
                try output.synchronize()
            }.value
            source = partial
        } else if response.status == 206 {
            // OS resume may deliver a complete file, including the prefix. Its response range need not start at zero.
            guard let range = response.range, let parsed = Self.range(range), incomingSize == parsed.2 else { throw DownloadError.response }
        }
        let handle = try FileHandle(forReadingFrom: source)
        let prefix = try handle.read(upToCount: 4096) ?? Data()
        try handle.close()
        // Require recognizable media bytes, never trust an extension or Content-Type on an error/archive body.
        guard let detected = ContainerSniffer.container(fromBytes: prefix), detected != .hls,
              let expected = MediaContainer(rawValue: item.container),
              detected == expected || ([.mp4, .mov, .m4v].contains(detected) && [.mp4, .mov, .m4v].contains(expected)) else { throw DownloadError.format }
        let path = id.uuidString + "." + DownloadEligibility.fileExtension(expected)
        let destination = root.appendingPathComponent(path)
        if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
        try FileManager.default.moveItem(at: source, to: destination)
        if source != incoming { try? FileManager.default.removeItem(at: incoming) }
        if source != partial { try? FileManager.default.removeItem(at: partial) }
        guard let current = index(id) else { throw DownloadError.response }
        items[current].mediaPath = path
        let size = Int64(try destination.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
        items[current].received = size; items[current].expected = size
        guard let current = index(id), !deleting.contains(id) else { return }
        items[current].state = .complete; items[current].failure = nil
        items[current].completedAt = Date()
        transferSpeeds[id] = nil; rateSamples[id] = nil
        try await persist()
        try await secrets.remove(key(id) + ".resume")
        // Subtitle work cannot hold up the queue or progress from the other media transfers.
        subtitleTasks[id] = Task { [weak self] in
            guard let self else { return }
            await saveSubtitles(id, credential: credential)
            do { try await persist() } catch { errorMessage = "Could not save subtitles" }
            subtitleTasks[id] = nil
        }
    }
    private static func range(_ value: String) -> (Int64, Int64, Int64)? {
        guard value.hasPrefix("bytes ") else { return nil }
        let parts = value.dropFirst(6).split(whereSeparator: { $0 == "-" || $0 == "/" })
        guard parts.count == 3, let start = Int64(parts[0]), let end = Int64(parts[1]), let total = Int64(parts[2]) else { return nil }
        guard start >= 0, end >= start, end < Int64.max, total > end else { return nil }
        return (start, end, total)
    }
    private func saveSubtitles(_ id: UUID, credential: Credential) async {
        guard let i = index(id), let root else { return }
        var options = credential.subtitles
        let candidate = PlaybackCandidate(id: id.uuidString, title: "", route: .native(credential.url),
                                          filename: credential.identity.filename, videoHash: credential.identity.videoHash,
                                          videoSize: credential.identity.videoSize)
        for await result in await subtitles.fetch(for: candidate, request: items[i].request) {
            if let value = result.value { options += value }
        }
        var seen = Set<URL>()
        for option in options.prefix(32) where seen.insert(option.url).inserted {
            guard !Task.isCancelled, !deleting.contains(id), index(id) != nil else { return }
            let format = SubtitleOption.FileFormat.detect(option.url)
            guard [.srt, .vtt, .ass, .pgs, .unknown].contains(format) else { continue }
            let track = SubtitleOption(id: option.id, language: option.lang, title: "", url: option.url, source: .stream)
            do {
                let sameOrigin = option.url.scheme == credential.url.scheme && option.url.host == credential.url.host && option.url.port == credential.url.port
                let data = try await streams.client.get(option.url, headers: sameOrigin ? credential.headers : [:],
                                                        limits: FetchLimits(maxBytes: 8 * 1024 * 1024)).data
                let ext: String
                if data.starts(with: [0x50, 0x47]) { ext = "sup" }
                else { ext = try SubtitleParser.parse(data: data).format.rawValue }
                let tags = (track.isForced ? ".forced" : "") + (track.isHearingImpaired ? ".sdh" : "")
                let path = id.uuidString + ".sub-\(UUID().uuidString)\(tags).\(ext)"
                try enoughSpace(Int64(data.count), excluding: id)
                guard let current = index(id), !deleting.contains(id) else { return }
                try data.write(to: root.appendingPathComponent(path), options: .atomic)
                let language = option.lang.count <= 3 && option.lang.allSatisfy(\.isLetter) ? option.lang : "und"
                items[current].subtitles.append(DownloadSubtitle(path: path, language: language))
            } catch { continue } // A subtitle failure never discards the video.
        }
    }
    private func localFile(_ item: DownloadItem) -> URL? {
        guard let root, let path = item.mediaPath, let file = DownloadFiles.resolve(path, for: item.id, in: root),
              FileManager.default.fileExists(atPath: file.path) else { return nil }
        return file
    }
    public func plan(for id: UUID) async -> PlaybackPlan? {
        await start()
        guard let i = index(id), items[i].state == .complete, items[i].pendingDeletion != true, let file = localFile(items[i]), let root else {
            if index(id) != nil { await fail(id, "File missing") }
            errorMessage = "Downloaded file is missing"; return nil
        }
        let item = items[i]
        let tracks = item.subtitles.compactMap { track -> SubtitleItem? in
            guard let url = DownloadFiles.resolve(track.path, for: id, in: root), FileManager.default.fileExists(atPath: url.path) else { return nil }
            return SubtitleItem(id: track.path, url: url, lang: track.language)
        }
        let route: PlaybackRoute = item.usesFallback ? .fallback(file, .unknownFormat) : .native(file)
        return PlaybackPlan(request: item.request, candidates: [PlaybackCandidate(id: "download:\(id.uuidString)", title: item.request.title,
                                                                               route: route, subtitles: tracks)],
                            retriesInFallbackEngine: fallback, retriesInBackupEngine: fallback)
    }
    public func opened(_ id: UUID) { playing.insert(id) }
    public func closed(_ id: UUID, watched: Bool) async {
        playing.remove(id)
        let preferences = await settings.load()
        if deleteAfterClose.contains(id) || (watched && preferences.downloadsDeleteWhenWatched) { await delete(id) }
    }
    private static func displayText(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).map { word in
            let value = String(word)
            return value.contains("://") || value.contains("@") ? "Media" : value
        }.joined(separator: " ")
    }
    public func clearError() { errorMessage = nil }
}
#endif
