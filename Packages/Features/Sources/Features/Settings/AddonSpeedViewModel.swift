import Foundation
import Observation
import StremioKit

/// The Addon Speed page: each enabled addon's showing in the speed test, in the user's own order (never reordered, since that order
/// also orders Home's rows and breaks ties), and what Auto Pick waits for.
@MainActor
@Observable
public final class AddonSpeedViewModel {
    public struct Row: Identifiable, Equatable {
        public let addon: AddonSummary
        public let result: AddonSpeedResult?
        public var id: UUID { addon.id }
    }

    public private(set) var rows: [Row] = []
    /// What Auto Pick waits for, as saved.
    public private(set) var wait: AutoPickWait = .allAddons
    public private(set) var isTesting = false
    /// The addon Auto would wait for now: the one marked Fastest. Nil when none qualifies.
    public private(set) var fastest: UUID?

    private let services: AppServices

    public init(services: AppServices) {
        self.services = services
    }

    public func load() async {
        let settings = await services.settings.load()
        wait = settings.autoPickWait
        await refresh(preferredResolution: settings.preferredResolution)
    }

    /// Runs the test and keeps its results. Only on request: every request is a real lookup.
    public func test() async {
        guard !isTesting else { return }
        isTesting = true
        defer { isTesting = false }
        let results = await services.speedTester.run()
        await services.addonSpeed.save(results)
        await refresh(preferredResolution: await services.settings.load().preferredResolution)
    }

    /// Saves what Auto Pick waits for, then calls `saved`. Choosing Auto before anything has been tested starts a test, after that.
    public func choose(_ wait: AutoPickWait, saved: () -> Void = {}) async {
        self.wait = wait
        var settings = await services.settings.load()
        settings.autoPickWait = wait
        await services.settings.save(settings)
        saved()
        if wait == .fastest, await services.addonSpeed.results().isEmpty { await test() }
    }

    /// The choice shown as ticked: a named addon that has since been removed or turned off shows as every addon, which is what Auto
    /// Pick does then.
    public var shownWait: AutoPickWait {
        if case .addon(let id) = wait, !rows.contains(where: { $0.id == id }) { return .allAddons }
        return wait
    }

    private func refresh(preferredResolution: Int?) async {
        let enabled = await services.registry.addons.filter(\.isEnabled)
        let results = await services.addonSpeed.results()
        rows = enabled.map { Row(addon: $0.summary, result: results[$0.id]) }
        fastest = AddonSpeedChoice.fastest(enabled: enabled.map(\.id), results: results, preferredResolution: preferredResolution,
                                           current: await services.addonSpeed.autoPick())
    }

    // MARK: Words

    /// "1.4 s · 6 of 6 · 4K", "Not tested yet", "Has no streams for the test titles" or "Failed every request".
    public static func detail(for result: AddonSpeedResult?) -> String {
        guard let result else { return "Not tested yet" }
        guard result.isApplicable else { return "Has no streams for the test titles" }
        guard let median = result.median else { return "Failed every request" }
        var parts = [median.formatted(.number.precision(.fractionLength(1))) + " s", "\(result.successes) of \(result.attempts)"]
        if let resolution = result.bestResolution { parts.append(resolution >= 2160 ? "4K" : "\(resolution)p") }
        return parts.joined(separator: " · ")
    }

    /// The Settings row's summary: what Auto Pick waits for.
    public static func summary(for wait: AutoPickWait, names: [UUID: String]) -> String {
        switch wait {
        case .allAddons: "All addons"
        case .fastest: "Auto (fastest)"
        case .addon(let id): names[id] ?? "All addons"
        }
    }
}
