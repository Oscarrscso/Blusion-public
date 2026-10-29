import SwiftUI
import Features
import StremioKit
import UIKit
import SafariServices

@main
struct BlusionApp: App {
    @UIApplicationDelegateAdaptor(DownloadAppDelegate.self) private var appDelegate
    @State private var environment = AppEnvironment.make()

    var body: some Scene {
        WindowGroup {
            RootView(environment: environment)
        }
        .defaultSize(Self.defaultWindowSize)
        .commands { BlusionCommands() }
    }

    /// 1280x800 where it fits. The Mac trims a new window that is too tall for the screen but not one that is too wide, and
    /// a Dock at the side takes some of the width: nine tenths of the screen leaves room for it.
    private static var defaultWindowSize: CGSize {
        #if targetEnvironment(macCatalyst)
        // No scene is connected this early, so there is no screen to reach through one: UIScreen.main is the only way to ask.
        let screen = UIScreen.main.bounds.size
        return CGSize(width: min(1280, screen.width * 0.9), height: min(800, screen.height * 0.9))
        #else
        return CGSize(width: 1280, height: 800)
        #endif
    }
}

/// Loads installed addons before showing the tabs, so the first screen never flashes an empty state.
struct RootView: View {
    let environment: AppEnvironment
    @State private var isReady = false
    @State private var addonLink: String?
    @State private var userStateRevision = 0
    @State private var pendingPlayerURLs: [URL] = []
    @Environment(\.scenePhase) private var scenePhase

    /// The OMDb and TMDb review services from the saved keys. Run at launch, and again when settings or secrets change on another device.
    private func reloadReviewServices() async {
        let settings = await environment.services.settings.load()
        await environment.services.posterRatings.setReviewServices(
            omdb: settings.omdbAPIKey.map { OMDbRatings(client: environment.services.client, apiKey: $0) },
            tmdb: settings.tmdbReadToken.map { TMDbRatings(client: environment.services.client, readAccessToken: $0) })
    }

    /// Starts the daily IMDb ratings check without waiting for it: the download and the import run off the main actor, and a check that
    /// is not due (the last one was under 24 hours ago) returns at once. At launch it waits for Home's rows first (at most 30 seconds),
    /// so on a fresh install the large download does not slow Home's first load.
    private func refreshIMDbDataset() {
        let ratings = environment.services.posterRatings
        Task(priority: .utility) {
            await HomeStartup.shared.waitUntilSettled()
            await ratings.refreshIMDbDataset()
        }
    }

    var body: some View {
        Group {
            if isReady {
                RootTabView(services: environment.services, route: environment.launchRoute,
                            addonLink: $addonLink, userStateRevision: userStateRevision)
                    .environment(environment.services.downloads!)
            } else {
                Spinner()
                    .accessibilityIdentifier("root.loading")
            }
        }
        #if targetEnvironment(macCatalyst)
        .modifier(MacWindowSize())
        #endif
        .environment(\.openURL, OpenURLAction { url in
            guard ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return .systemAction }
            // Present over the current screen, including links inside an existing sheet.
            guard var presenter = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .first(where: { $0.activationState == .foregroundActive })?
                .windows.first(where: \.isKeyWindow)?.rootViewController else { return .systemAction }
            while let presented = presenter.presentedViewController {
                presenter = presented
            }
            let browser = SFSafariViewController(url: url)
            browser.modalPresentationStyle = .pageSheet
            presenter.present(browser, animated: true)
            return .handled
        })
        .task {
            try? await environment.services.registry.load()
            let settings = await environment.services.settings.load()
            environment.services.posterRatings.isEnabled = settings.showsPosterRatings
            environment.services.posterRatings.showsColouredLogos = settings.showsColouredRatingLogos
            await reloadReviewServices()
            await environment.seedDefaultAddons()
            #if DEBUG
            await DebugDemoData.installExtraAddons(environment.services)
            await DebugDemoData.installFakeOMDbIfRequested(environment.services)
            await DebugDemoData.seedIfRequested(environment.services)
            #endif
            isReady = true
            refreshIMDbDataset()
            #if targetEnvironment(macCatalyst)
            if ProcessInfo.processInfo.environment["BLUSION_WINDOW_SIZE"] == nil {
                for scene in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }) {
                    scene.sizeRestrictions?.minimumSize = CGSize(width: 800, height: 600)
                }
            }
            #endif
            #if DEBUG
            DebugSnapshot.scheduleIfRequested()
            DebugStress.startIfRequested()
            DebugHangSampler.start()
            await DebugHandoffProbe.startIfRequested(environment.services)
            #endif
        }
        // An app left open for days is still checked once a day: coming back to the front asks again, and the 24-hour rule decides.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active, isReady { refreshIMDbDataset() }
        }
        .onChange(of: isReady) { _, ready in
            guard ready else { return }
            let callbacks = pendingPlayerURLs
            pendingPlayerURLs = []
            for url in callbacks { handlePlayerCallback(url) }
        }
        // Settings or secrets changed on the user's other device (iCloud): reread them here.
        .onReceive(NotificationCenter.default.publisher(for: .cloudSecretsDidChange)) { _ in
            userStateRevision += 1
            Task {
                await reloadReviewServices()
                environment.services.posterRatings.settingsDidChangeElsewhere()
            }
        }
        // The player app calls back here with where the viewer stopped (blusion://x-callback-url/handoff/...).
        .onOpenURL { url in
            if let link = AddonLink.installText(from: url) {
                addonLink = link
                return
            }
            if isReady { handlePlayerCallback(url) } else { pendingPlayerURLs.append(url) }
        }
    }

    private func handlePlayerCallback(_ url: URL) {
        Task {
            // Let the tabs register their result observers when a callback cold-launches Blusion.
            await Task.yield()
            if await PlaybackHandoffCenter(services: environment.services).handle(url) { userStateRevision += 1 }
            #if DEBUG
            await DebugHandoffProbe.record(url, services: environment.services)
            #endif
        }
    }
}

#if targetEnvironment(macCatalyst)
/// A Mac window can be no larger than what it shows, and the first thing this app shows is a loading spinner: without room
/// to grow the window opens 16 points wide and ignores the default size. A snapshot run sets its own size (`DebugSnapshot`).
private struct MacWindowSize: ViewModifier {
    private let applies = ProcessInfo.processInfo.environment["BLUSION_WINDOW_SIZE"] == nil

    func body(content: Content) -> some View {
        if applies {
            content.frame(minWidth: 800, maxWidth: .infinity, minHeight: 600, maxHeight: .infinity)
        } else {
            content
        }
    }
}
#endif

/// UIKit reconnects the same URLSession after a system relaunch; its completion is released after the event stream drains.
@MainActor
enum DownloadBackgroundEvents {
    static var pending: (() -> Void)?
    static weak var manager: DownloadManager? {
        didSet { if let pending, let manager { manager.backgroundCompletion = pending; self.pending = nil } }
    }
}

final class DownloadAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        guard identifier == DownloadSession.identifier else { completionHandler(); return }
        if let manager = DownloadBackgroundEvents.manager {
            manager.backgroundCompletion = completionHandler
            Task { await manager.start() }
        } else { DownloadBackgroundEvents.pending = completionHandler }
    }
}
