import Foundation

/// The user's installed addons: install, remove, enable, reorder, and routing by (resource, type, id).
/// Metadata goes to an `AddonStore`; manifest URLs (secrets) go to a `SecretStore`.
public actor AddonRegistry {
    public private(set) var addons: [InstalledAddon] = []

    private let store: any AddonStore
    private let secrets: any SecretStore
    private let client: AddonClient
    private let logger: AddonLogger
    private var subscribers: [UUID: AsyncStream<[InstalledAddon]>.Continuation] = [:]

    public init(store: any AddonStore, secrets: any SecretStore, client: AddonClient, logger: AddonLogger = .silent) {
        self.store = store
        self.secrets = secrets
        self.client = client
        self.logger = logger
    }

    private static func secretKey(_ id: UUID) -> String { "addon.\(id.uuidString).manifestURL" }

    // MARK: Loading

    /// Restores installed addons. A record whose secret is missing or undecodable is skipped and logged, never fatal.
    public func load() async throws {
        let records: [AddonRecord]
        do { records = try await store.loadAll() } catch { throw RegistryError.storage("load") }
        var loaded: [InstalledAddon] = []
        for record in records.sorted(by: { $0.order < $1.order }) {
            guard let text = try? await secrets.get(Self.secretKey(record.id)),
                  let location = try? AddonURLNormaliser.normalise(text),
                  let manifest = try? JSONDecoder().decode(Manifest.self, from: record.manifestData) else {
                logger.log(.warning, "skipping stored addon \(record.id.uuidString): missing URL or manifest")
                continue
            }
            loaded.append(InstalledAddon(id: record.id, manifestURL: location.manifestURL, baseURL: location.baseURL, manifest: manifest,
                                         isEnabled: record.isEnabled, installedAt: record.installedAt, customName: record.customName))
        }
        addons = loaded
        publish()
    }

    // MARK: Mutations

    /// Normalises `input` (stremio://, https://, bare host), fetches and validates the manifest, then stores it.
    @discardableResult
    public func install(from input: String) async throws -> InstalledAddon {
        let location: AddonLocation
        do { location = try AddonURLNormaliser.normalise(input) } catch let error as AddonURLError { throw RegistryError.invalidURL(error) }
        if addons.contains(where: { $0.manifestURL == location.manifestURL }) { throw RegistryError.alreadyInstalled }

        let manifest: Manifest
        do { manifest = try await client.fetchManifest(at: location) } catch { throw RegistryError.manifest(AddonError.from(error)) }

        let addon = InstalledAddon(manifestURL: location.manifestURL, baseURL: location.baseURL, manifest: manifest)
        do {
            try await secrets.set(location.manifestURL.absoluteString, for: Self.secretKey(addon.id))
        } catch { throw RegistryError.storage("secret") }
        addons.append(addon)
        do {
            try await persist()
        } catch {
            addons.removeAll { $0.id == addon.id }
            try? await secrets.remove(Self.secretKey(addon.id))
            throw error
        }
        logger.log(.info, "installed addon “\(manifest.name)” from \(Redactor.displayHost(location.manifestURL))")
        publish()
        return addon
    }

    public func remove(id: UUID) async throws {
        guard let index = addons.firstIndex(where: { $0.id == id }) else { throw RegistryError.notFound }
        let removed = addons.remove(at: index)
        do { try await persist() } catch {
            addons.insert(removed, at: index)
            throw error
        }
        try? await secrets.remove(Self.secretKey(id))
        logger.log(.info, "removed addon “\(removed.name)”")
        publish()
    }

    public func setEnabled(_ enabled: Bool, id: UUID) async throws {
        guard let index = addons.firstIndex(where: { $0.id == id }) else { throw RegistryError.notFound }
        let previous = addons[index].isEnabled
        addons[index].isEnabled = enabled
        do { try await persist() } catch {
            addons[index].isEnabled = previous
            throw error
        }
        publish()
    }

    /// Sets the name the user gave an addon. Blank or nil clears it, so the manifest's own name shows again.
    public func rename(_ name: String?, id: UUID) async throws {
        guard let index = addons.firstIndex(where: { $0.id == id }) else { throw RegistryError.notFound }
        let previous = addons[index].customName
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        addons[index].customName = (trimmed?.isEmpty ?? true) ? nil : trimmed
        do { try await persist() } catch {
            addons[index].customName = previous
            throw error
        }
        publish()
    }

    /// Moves an addon to `index` (clamped). Order decides which addon's rows and streams come first.
    public func move(id: UUID, to index: Int) async throws {
        guard let from = addons.firstIndex(where: { $0.id == id }) else { throw RegistryError.notFound }
        let before = addons
        let addon = addons.remove(at: from)
        addons.insert(addon, at: min(max(index, 0), addons.count))
        do { try await persist() } catch {
            addons = before
            throw error
        }
        publish()
    }

    /// SwiftUI `onMove` shape: moves the items at `offsets` so they end up before `destination`.
    public func move(fromOffsets offsets: IndexSet, toOffset destination: Int) async throws {
        let before = addons
        let moving = offsets.sorted().map { addons[$0] }
        let destinationAdjusted = destination - offsets.filter { $0 < destination }.count
        addons = addons.enumerated().filter { !offsets.contains($0.offset) }.map(\.element)
        addons.insert(contentsOf: moving, at: min(max(destinationAdjusted, 0), addons.count))
        do { try await persist() } catch {
            addons = before
            throw error
        }
        publish()
    }

    /// Re-fetches an addon's manifest (e.g. after the addon was updated) and keeps the install.
    public func refreshManifest(id: UUID) async throws {
        guard let index = addons.firstIndex(where: { $0.id == id }) else { throw RegistryError.notFound }
        let addon = addons[index]
        do {
            let manifest = try await client.fetchManifest(at: AddonLocation(manifestURL: addon.manifestURL, baseURL: addon.baseURL))
            guard let current = addons.firstIndex(where: { $0.id == id }) else { return }
            addons[current].manifest = manifest
            try await persist()
            publish()
        } catch let error as RegistryError {
            throw error
        } catch {
            throw RegistryError.manifest(AddonError.from(error))
        }
    }

    // MARK: Queries

    public func addon(id: UUID) -> InstalledAddon? { addons.first { $0.id == id } }

    /// Enabled addons that can answer this request, in the user's order.
    public func addons(for resource: ResourceKind, type: String, id: String) -> [InstalledAddon] {
        addons.filter { $0.isEnabled && $0.manifest.supports(resource, type: type, id: id) }
    }

    /// Enabled addons that provide `resource` at all (catalogs, which are not routed by id).
    public func addons(providing resource: ResourceKind) -> [InstalledAddon] {
        addons.filter { $0.isEnabled && $0.manifest.provides(resource) }
    }

    /// Emits the current list immediately and again after every change.
    public func updates() -> AsyncStream<[InstalledAddon]> {
        let token = UUID()
        let (stream, continuation) = AsyncStream<[InstalledAddon]>.makeStream(bufferingPolicy: .bufferingNewest(1))
        subscribers[token] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeSubscriber(token) }
        }
        continuation.yield(addons)
        return stream
    }

    // MARK: Internals

    private func removeSubscriber(_ token: UUID) {
        subscribers[token] = nil
    }

    private func publish() {
        for continuation in subscribers.values { continuation.yield(addons) }
    }

    private func persist() async throws {
        let encoder = JSONEncoder()
        do {
            let records = try addons.enumerated().map { index, addon in
                AddonRecord(id: addon.id, manifestData: try encoder.encode(addon.manifest), isEnabled: addon.isEnabled, order: index,
                            installedAt: addon.installedAt, customName: addon.customName)
            }
            try await store.save(records)
        } catch { throw RegistryError.storage("save") }
    }
}
