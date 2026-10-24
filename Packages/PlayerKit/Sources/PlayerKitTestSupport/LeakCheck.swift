import Foundation

/// Leak pass helper (PLAN M8). Runs `body`, which creates, exercises and returns the objects under test; lets go of everything,
/// then waits for pending tasks to unwind. Returns the names of the objects that are still alive, so `#expect(leaked.isEmpty)` reads well.
@MainActor
public func survivors(timeout: Duration = .seconds(3), _ body: @MainActor () async throws -> [(String, AnyObject)]) async throws -> [String] {
    struct Ref {
        let name: String
        weak var object: AnyObject?
    }
    let refs: [Ref] = try await { () async throws -> [Ref] in
        let objects = try await body()
        return objects.map { Ref(name: $0.0, object: $0.1) }
    }()
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if refs.allSatisfy({ $0.object == nil }) { return [] }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return refs.filter { $0.object != nil }.map(\.name)
}
