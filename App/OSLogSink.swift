import os
import StremioKit

/// Forwards already-redacted log lines (see `AddonLogger`) to the unified log. Redaction happens before this point, so `.public` is safe.
struct OSLogSink: LogSink {
    private let logger = Logger(subsystem: "app.blusion.player", category: "addons")

    func write(_ level: LogLevel, _ message: String) {
        switch level {
        case .debug: logger.debug("\(message, privacy: .public)")
        case .info: logger.info("\(message, privacy: .public)")
        case .warning: logger.warning("\(message, privacy: .public)")
        case .error: logger.error("\(message, privacy: .public)")
        }
    }
}
