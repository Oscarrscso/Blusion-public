#if canImport(UIKit)
import PlayerKit
import StremioKit
import SwiftUI
import UIKit

/// What the tab bar accessory shows: the newest title to resume. The accessory is enabled only while there is one.
@MainActor
@Observable
final class ContinueWatchingModel {
    private(set) var newest: WatchProgress?

    private let services: AppServices

    init(services: AppServices) {
        self.services = services
    }

    /// Reads the saved progress again. The root tab view calls this on launch and whenever the tab changes.
    func refresh() async {
        update(from: await services.progress.all())
    }

    func update(from records: [WatchProgress]) {
        newest = LibraryViewModel.continueWatching(from: records).first
    }

    /// Complete the accessory's current title, syncing its watched mark and clearing Trakt's pause.
    func markWatched(_ item: WatchProgress) async {
        var record = await services.progress.progress(for: item.id) ?? item
        record.isWatched = true
        record.isQueuedForContinue = false
        record.updatedAt = Date()
        await services.progress.save(record)
        await services.traktSync.playbackRemoved(item.id)
        await services.queueNextContinueEpisode(after: LibraryViewModel.request(for: item))
        await refresh()
    }

    /// Takes the title off Continue Watching. The removal is queued for Trakt, which sync sends, so this never waits on the network.
    func remove(_ item: WatchProgress) async {
        await services.removeContinueWatching(identity: item.id)
        await refresh()
    }
}

/// Attaches the accessory with its `isEnabled` form, which needs iOS 26.1. On iOS 26.0 there is no accessory and Continue Watching stays
/// on Home.
struct ResumeAccessoryModifier: ViewModifier {
    let model: ContinueWatchingModel
    /// True while a title's page is on top: the page has the whole screen, without the accessory.
    var hidden = false
    /// Suppress the native accessory on a landscape iPhone without changing the tab view's identity.
    var isPhoneLandscape = false

    func body(content: Content) -> some View {
        #if targetEnvironment(macCatalyst)
        // The Mac's bar belongs to each tab's page (see `macPlayBar`), so it stops at the sidebar.
        content
        #else
        if #available(iOS 26.1, *) {
            // Keep this modifier attached in both orientations: branching around Content rebuilds the entire TabView.
            content.tabViewBottomAccessory(isEnabled: model.newest != nil && !hidden && !isPhoneLandscape) {
                if let newest = model.newest {
                    ContinueWatchingAccessory(item: newest,
                                              onMarkWatched: { Task { await model.markWatched(newest) } },
                                              onRemove: { Task { await model.remove(newest) } })
                }
            }
            .background {
                ResumeAccessoryVisibility(isEnabled: model.newest != nil && !hidden, isPhoneLandscape: isPhoneLandscape)
                    .frame(width: 0, height: 0)
            }
        } else {
            content
        }
        #endif
    }
}

/// SwiftUI can retain the UIKit accessory after its tab bar hides. Remove it through UIKit's public API as well.
@available(iOS 26.1, *)
private struct ResumeAccessoryVisibility: UIViewControllerRepresentable {
    let isEnabled: Bool
    let isPhoneLandscape: Bool

    func makeUIViewController(context: Context) -> ResumeAccessoryVisibilityController {
        ResumeAccessoryVisibilityController()
    }

    func updateUIViewController(_ controller: ResumeAccessoryVisibilityController, context: Context) {
        controller.isEnabled = isEnabled
        controller.isPhoneLandscape = isPhoneLandscape
        // Run after SwiftUI has applied its own accessory update to the tab controller.
        DispatchQueue.main.async { [weak controller] in controller?.synchronize() }
    }
}

@available(iOS 26.1, *)
final class ResumeAccessoryVisibilityController: UIViewController {
    var isEnabled = false
    var isPhoneLandscape = false
    private var savedAccessory: UITabAccessory?
    private weak var owner: UITabBarController?

    override func loadView() {
        let surface = UIView()
        surface.backgroundColor = .clear
        surface.isUserInteractionEnabled = false
        view = surface
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        synchronize()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        synchronize()
    }

    func synchronize() {
        guard let tabs = tabBarController ?? Self.findTabs(in: view.window?.rootViewController) else { return }
        let landscape = UIDevice.current.userInterfaceIdiom == .phone
            && (view.window?.windowScene?.interfaceOrientation.isLandscape ?? isPhoneLandscape)
        synchronize(with: tabs, landscape: landscape)
    }

    /// Also used by the UIKit regression tests, without a window or device rotation.
    func synchronize(with tabs: UITabBarController, landscape: Bool) {
        if owner !== tabs {
            savedAccessory = nil
            owner = tabs
        }
        if !isEnabled || landscape || isPhoneLandscape {
            if let accessory = tabs.bottomAccessory {
                savedAccessory = isEnabled ? accessory : nil
                tabs.setBottomAccessory(nil, animated: false)
            }
            if !isEnabled { savedAccessory = nil }
        } else {
            if tabs.bottomAccessory == nil, let savedAccessory {
                tabs.setBottomAccessory(savedAccessory, animated: false)
            }
            savedAccessory = nil
        }
    }

    private static func findTabs(in controller: UIViewController?) -> UITabBarController? {
        guard let controller else { return nil }
        if let tabs = controller as? UITabBarController { return tabs }
        for child in controller.children {
            if let tabs = findTabs(in: child) { return tabs }
        }
        return nil
    }
}

/// The tab bar accessory (iOS 26, like the mini player in Music): the newest title to resume, with its progress. Tapping it opens
/// that title's page on Home with its stream picker open, where the player resumes from the saved position.
struct ContinueWatchingAccessory: View {
    let item: WatchProgress
    let onMarkWatched: () -> Void
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: Theme.Spacing.m) {
            ArtworkImage(url: item.poster, title: item.title, maxPixelSize: 120)
                .frame(width: 30, height: 45)
                .mediaArtwork(cornerRadius: 6)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text(item.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                ProgressView(value: item.fraction)
                    .progressViewStyle(.linear)
                    .tint(.white)
                    .accessibilityHidden(true)
            }
            Spacer(minLength: 0)
            Image(systemName: "play.fill")
                .accessibilityHidden(true)
        }
        .padding(.horizontal, Theme.Spacing.l)
        .continueWatchingHold(preview: MetaPreview(id: ContentID(item.contentID).baseID, type: item.type,
                                                  name: item.title, poster: item.poster), request: LibraryViewModel.request(for: item),
                                  itemID: item.id, launcher: nil, onMarkWatched: onMarkWatched, onRemove: onRemove)
        .accessibilityLabel("Continue watching \(item.title), \(Int((item.fraction * 100).rounded())) percent watched")
        .accessibilityIdentifier("tabbar.continue")
    }
}
#endif
