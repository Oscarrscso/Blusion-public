import Foundation

/// Ghost mode: while it is on, nothing that is watched leaves a trace. No position or watched mark is saved, so nothing joins Continue
/// Watching, and Trakt is neither read nor told anything. It stays on, across launches, until it is switched off. Settings turns it on
/// and off (a pull held for two seconds); the stores and the Trakt sync read it here.
public enum GhostMode {
    /// The key the choice is kept under, which Settings also watches to draw its indicator.
    public static let defaultsKey = "ghostMode.isOn"

    public static var isOn: Bool {
        get { UserDefaults.standard.bool(forKey: defaultsKey) }
        set { UserDefaults.standard.set(newValue, forKey: defaultsKey) }
    }
}
