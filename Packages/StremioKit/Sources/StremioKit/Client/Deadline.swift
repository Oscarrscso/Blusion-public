import Foundation

/// Runs `operation` and throws `AddonError.timeout` if it has not finished within `seconds`.
/// Cancelling the caller (or the timeout winning) cancels `operation`, which cancels the underlying URLSession task.
func withDeadline<T: Sendable>(seconds: TimeInterval, operation: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(for: .seconds(seconds))
            throw AddonError.timeout
        }
        defer { group.cancelAll() }
        guard let first = try await group.next() else { throw AddonError.cancelled }
        return first
    }
}
