import Foundation

/// Stream lookups started ahead of the picker, one per title. A lookup runs to the end whether or not anyone is listening yet, is handed to
/// the first picker that claims it, and is dropped when it expires or when its title's page was left without a claim.
actor StreamPrefetchCache {
    typealias Responses = AsyncStream<AddonResponse<[AddonStream]>>
    typealias Lookup = (asked: [AddonSummary], responses: Responses)

    /// How long a lookup stays usable after it starts.
    static let timeToLive: Duration = .seconds(60)
    /// How long an unclaimed lookup survives after its page is left, so the Play button can push the picker before it is dropped.
    private static let releaseGrace: Duration = .seconds(2)

    private struct Entry {
        let token: UUID
        let created: ContinuousClock.Instant
        let started: Task<Lookup, Never>
        let askedTask: Task<[AddonSummary], Never>
        var task: Task<Void, Never>?
        var asked: [AddonSummary] = []
        var responses: [AddonResponse<[AddonStream]>] = []
        var isFinished = false
        var continuations: [UUID: Responses.Continuation] = [:]
        var consumerCount = 0
        var releaseTask: Task<Void, Never>?

        /// Finished, and either nobody can answer or every addon that was asked failed.
        var isFailed: Bool {
            guard isFinished else { return false }
            return asked.isEmpty || responses.allSatisfy { $0.error != nil }
        }
    }

    private var entries: [String: Entry] = [:]

    /// Starts the lookup for `key` unless a usable one already exists. The lookup drains its own stream, independent of any consumer.
    func prefetch(key: String, start: @escaping @Sendable () async -> Lookup) {
        expireStale()
        if let live = entries[key], !live.isFailed {
            entries[key]?.releaseTask?.cancel()
            entries[key]?.releaseTask = nil
            return
        }
        discard(key: key)
        let token = UUID()
        let started = Task { await start() }
        let askedTask = Task { await started.value.asked }
        entries[key] = Entry(token: token, created: ContinuousClock.now, started: started, askedTask: askedTask)
        entries[key]?.task = Task { [self] in
            let lookup = await started.value
            self.begin(key: key, token: token, asked: lookup.asked)
            for await response in lookup.responses {
                self.absorb(key: key, token: token, response)
            }
            self.complete(key: key, token: token)
        }
    }

    /// Returns once the lookup for `key` has every answer, or at once when there is none.
    func waitUntilFinished(key: String) async {
        guard let task = entries[key]?.task else { return }
        await task.value
    }

    /// The lookup's answers so far, then the rest as they arrive. Nil when there is no usable lookup.
    func claim(key: String) async -> Lookup? {
        expireStale()
        guard let entry = entries[key], !entry.isFailed else { return nil }
        let token = entry.token
        let asked = await entry.askedTask.value
        // Other calls may have run while waiting: check again, then replay and register without suspending.
        guard var current = entries[key], current.token == token, !current.isFailed else { return nil }
        current.consumerCount += 1
        current.releaseTask?.cancel()
        current.releaseTask = nil
        let made = Responses.makeStream(of: AddonResponse<[AddonStream]>.self)
        for response in current.responses { made.continuation.yield(response) }
        if current.isFinished {
            made.continuation.finish()
        } else {
            let id = UUID()
            current.continuations[id] = made.continuation
            made.continuation.onTermination = { [self] _ in
                Task { await self.detach(key: key, id: id) }
            }
        }
        entries[key] = current
        return (asked, made.stream)
    }

    /// The page was left: an unclaimed lookup is dropped after a short grace period.
    func release(key: String) {
        guard let token = entries[key]?.token else { return }
        entries[key]?.releaseTask?.cancel()
        entries[key]?.releaseTask = Task { [self] in
            try? await Task.sleep(for: Self.releaseGrace)
            guard !Task.isCancelled else { return }
            self.dropIfUnclaimed(key: key, token: token)
        }
    }

    // MARK: lookup task

    private func begin(key: String, token: UUID, asked: [AddonSummary]) {
        guard entries[key]?.token == token else { return }
        entries[key]?.asked = asked
    }

    private func absorb(key: String, token: UUID, _ response: AddonResponse<[AddonStream]>) {
        guard entries[key]?.token == token else { return }
        entries[key]?.responses.append(response)
        entries[key]?.continuations.values.forEach { $0.yield(response) }
    }

    private func complete(key: String, token: UUID) {
        guard let entry = entries[key], entry.token == token else { return }
        for continuation in entry.continuations.values { continuation.finish() }
        entries[key]?.continuations = [:]
        entries[key]?.isFinished = true
    }

    private func detach(key: String, id: UUID) {
        entries[key]?.continuations[id] = nil
    }

    // MARK: dropping

    private func dropIfUnclaimed(key: String, token: UUID) {
        guard let entry = entries[key], entry.token == token, entry.consumerCount == 0 else { return }
        discard(key: key)
    }

    private func expireStale() {
        let now = ContinuousClock.now
        let stale = entries.filter { now - $0.value.created >= Self.timeToLive }.map(\.key)
        for key in stale { discard(key: key) }
    }

    /// Removes the entry, stops its lookup and ends any consumer still attached to it.
    private func discard(key: String) {
        guard let entry = entries.removeValue(forKey: key) else { return }
        entry.started.cancel()
        entry.task?.cancel()
        entry.releaseTask?.cancel()
        for continuation in entry.continuations.values { continuation.finish() }
    }
}
