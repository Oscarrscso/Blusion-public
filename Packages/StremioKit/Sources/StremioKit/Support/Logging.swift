import Foundation

public enum LogLevel: String, Sendable {
    case debug, info, warning, error
}

public protocol LogSink: Sendable {
    func write(_ level: LogLevel, _ message: String)
}

/// Every message passes through `Redactor` before it reaches a sink, so sinks never see a URL path or token.
public struct AddonLogger: Sendable {
    private let sink: (any LogSink)?

    public init(sink: (any LogSink)? = nil) {
        self.sink = sink
    }

    public static let silent = AddonLogger()

    public func log(_ level: LogLevel, _ message: @autoclosure () -> String) {
        guard let sink else { return }
        sink.write(level, Redactor.redact(text: message()))
    }
}

/// Captures log lines; used by tests to prove that tokens never reach logs.
public final class MemoryLogSink: LogSink, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    public init() {}

    public func write(_ level: LogLevel, _ message: String) {
        lock.lock()
        defer { lock.unlock() }
        storage.append("[\(level.rawValue)] \(message)")
    }

    public var lines: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}
