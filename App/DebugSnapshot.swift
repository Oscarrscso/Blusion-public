#if DEBUG
import UIKit

/// Developer aid for Macs without an iOS simulator: a Debug build launched with `BLUSION_SNAPSHOT=<file.png>` draws its own
/// window into that file after `BLUSION_SNAPSHOT_DELAY` seconds (default 6) and exits. `BLUSION_WINDOW_SIZE=402x874` first sizes
/// the Mac Catalyst window like a phone. Driven by `scripts/snapshot.sh`. An app may draw its own window without the
/// Screen Recording permission, which is what makes this work from a terminal.
@MainActor
enum DebugSnapshot {
    static func scheduleIfRequested(environment: [String: String] = ProcessInfo.processInfo.environment) {
        guard let path = environment["BLUSION_SNAPSHOT"], !path.isEmpty else { return }
        let delay = environment["BLUSION_SNAPSHOT_DELAY"].flatMap(Double.init) ?? 6
        if let size = size(from: environment["BLUSION_WINDOW_SIZE"]) { resizeWindows(to: size) }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(delay))
            exit(capture(to: URL(fileURLWithPath: path)) ? 0 : 1)
        }
    }

    private static var scenes: [UIWindowScene] {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
    }

    private static func size(from text: String?) -> CGSize? {
        guard let parts = text?.lowercased().split(separator: "x"), parts.count == 2,
              let width = Double(parts[0]), let height = Double(parts[1]), width > 0, height > 0 else { return nil }
        return CGSize(width: width, height: height)
    }

    private static func resizeWindows(to size: CGSize) {
        for scene in scenes {
            scene.sizeRestrictions?.minimumSize = size
            scene.sizeRestrictions?.maximumSize = size
            #if targetEnvironment(macCatalyst)
            scene.requestGeometryUpdate(UIWindowScene.GeometryPreferences.Mac(systemFrame: CGRect(origin: CGPoint(x: 60, y: 60), size: size)))
            #endif
        }
    }

    private static func capture(to url: URL) -> Bool {
        let windows = scenes.flatMap(\.windows)
        guard let main = windows.first(where: \.isKeyWindow) ?? windows.first else { return false }
        // On the Mac a sheet lives in a window of its own (bridged to AppKit), which the main window's drawing leaves out:
        // when something is presented, draw the window that shows it instead.
        let top = main.rootViewController.flatMap(presentedController)
        let window = top?.viewIfLoaded?.window ?? main
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        guard let data = image.pngData() else { return false }
        return (try? data.write(to: url, options: .atomic)) != nil
    }

    // SwiftUI can present a sheet from a child of the window's root controller.
    private static func presentedController(in controller: UIViewController) -> UIViewController? {
        if let presented = controller.presentedViewController {
            return presentedController(in: presented) ?? presented
        }
        for child in controller.children.reversed() {
            if let presented = presentedController(in: child) { return presented }
        }
        return nil
    }
}
#endif
