import Foundation
import StremioKit

/// Tells "the device is offline" apart from "one addon is down": every request failing with `.offline` is the former, anything else the latter.
/// There is no reachability monitor on purpose: the addon requests themselves are the evidence, so the banner can never disagree with them.
public enum Connectivity {
    public static let offlineTitle = "You're offline"
    public static let offlineMessage = "Blusion can't reach your addons. Check your connection and try again. Addons on your home network need Wi-Fi."

    /// True when there is at least one failure and every failure is `.offline`.
    public static func isOffline(_ errors: [AddonError]) -> Bool {
        !errors.isEmpty && errors.allSatisfy { $0 == .offline }
    }
}
