import Foundation

/// One addon's answer. Failures are values, so one broken addon never affects another.
public struct AddonResponse<Value: Sendable>: Sendable {
    public let addon: AddonSummary
    public let result: Result<Value, AddonError>

    public init(addon: AddonSummary, result: Result<Value, AddonError>) {
        self.addon = addon
        self.result = result
    }

    public var value: Value? { try? result.get() }

    public var error: AddonError? {
        if case .failure(let error) = result { return error }
        return nil
    }
}

public enum FanOut {
    /// Runs `operation` against every addon concurrently and yields each response the moment that addon answers.
    /// A slow or failing addon only delays or fails its own response. Cancelling the consumer cancels all in-flight requests.
    public static func run<Value: Sendable>(
        over addons: [InstalledAddon],
        operation: @escaping @Sendable (InstalledAddon) async throws -> Value
    ) -> AsyncStream<AddonResponse<Value>> {
        AsyncStream { continuation in
            let task = Task {
                await withTaskGroup(of: AddonResponse<Value>.self) { group in
                    for addon in addons {
                        group.addTask {
                            do {
                                return AddonResponse(addon: addon.summary, result: .success(try await operation(addon)))
                            } catch {
                                return AddonResponse(addon: addon.summary, result: .failure(AddonError.from(error)))
                            }
                        }
                    }
                    for await response in group { continuation.yield(response) }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

extension AsyncStream {
    /// Waits for the stream to finish and returns everything it yielded, in arrival order.
    public func collect() async -> [Element] {
        var all: [Element] = []
        for await element in self { all.append(element) }
        return all
    }
}
