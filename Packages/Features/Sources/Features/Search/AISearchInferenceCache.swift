import Foundation

/// Reuse successful inference, not finished result rows: watched history and database candidates are checked on every search.
actor AISearchInferenceCache {
    static let shared = AISearchInferenceCache()

    struct RankingKey: Hashable, Sendable {
        let request: String
        let references: [String]
        let candidates: [String]
        let watched: [String]
    }

    private struct Entry<Value: Sendable>: Sendable {
        let value: Value
        let date: Date
    }

    private let limit = 32
    private let lifetime: TimeInterval = 900
    private var plans: [String: Entry<AISearchPlan>] = [:]
    private var rankings: [RankingKey: Entry<[Int]>] = [:]

    func plan(for request: String, at date: Date = Date()) -> AISearchPlan? {
        guard let entry = plans[request], date.timeIntervalSince(entry.date) < lifetime else { return nil }
        return entry.value
    }

    func store(_ plan: AISearchPlan, for request: String, at date: Date = Date()) {
        plans[request] = Entry(value: plan, date: date)
        if plans.count > limit, let oldest = plans.min(by: { $0.value.date < $1.value.date })?.key { plans[oldest] = nil }
    }

    func ranking(for key: RankingKey, at date: Date = Date()) -> [Int]? {
        guard let entry = rankings[key], date.timeIntervalSince(entry.date) < lifetime else { return nil }
        return entry.value
    }

    func store(_ numbers: [Int], for key: RankingKey, at date: Date = Date()) {
        rankings[key] = Entry(value: numbers, date: date)
        if rankings.count > limit, let oldest = rankings.min(by: { $0.value.date < $1.value.date })?.key { rankings[oldest] = nil }
    }
}
