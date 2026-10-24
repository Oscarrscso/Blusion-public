import Foundation

/// Reads the links Blusion is opened with: an addon's manifest link, as `stremio://` or `http(s)://`, from another app or a web page.
public enum AddonLink {
    /// The text to put in the install field when the app is opened with `url`: a `stremio://…/manifest.json` link or an
    /// `http(s)://…/manifest.json` link. nil for anything else, such as Blusion's own `blusion://` callbacks.
    /// `AddonURLNormaliser` checks the text when the user installs it, so a bad link is explained there.
    public static func installText(from url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased(), ["stremio", "http", "https"].contains(scheme) else { return nil }
        guard url.path.lowercased().hasSuffix("/manifest.json") else { return nil }
        return url.absoluteString
    }
}
