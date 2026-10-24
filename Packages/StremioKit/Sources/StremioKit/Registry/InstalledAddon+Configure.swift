import Foundation

extension InstalledAddon {
    /// The addon's configuration page, by Stremio's convention: the manifest URL with `manifest.json` replaced by `configure`.
    /// Nil unless the manifest URL ends in `manifest.json` over http(s). The URL can carry a token, so never log it.
    public var configureURL: URL? {
        guard manifestURL.lastPathComponent == "manifest.json",
              let scheme = manifestURL.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return nil }
        return manifestURL.deletingLastPathComponent().appendingPathComponent("configure")
    }
}
