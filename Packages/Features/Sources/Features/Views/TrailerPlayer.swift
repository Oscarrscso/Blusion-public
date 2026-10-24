#if canImport(UIKit)
import AVKit
import CoreGraphics
import CoreMedia
import StremioKit
import SwiftUI
import UIKit

extension View {
    /// Opens a YouTube trailer that the page handed over, and clears the binding again. The page hands over only a video that YouTube
    /// will not embed, so it opens in the YouTube app, or on its web page when the app is not installed. Any other trailer only clears
    /// the binding.
    func youTubeTrailer(_ item: Binding<Trailer?>) -> some View {
        modifier(YouTubeTrailerModifier(item: item))
    }
}

private struct YouTubeTrailerModifier: ViewModifier {
    @Binding var item: Trailer?

    func body(content: Content) -> some View {
        content.onChange(of: item) { _, trailer in
            guard let trailer else { return }
            item = nil
            guard let videoID = trailer.youtubeID else { return }
            openYouTube(videoID)
        }
    }

    /// The YouTube app first. The web link is a universal link too, so it opens the app when the app is installed; the page is the
    /// fallback.
    private func openYouTube(_ videoID: String) {
        guard let app = YouTubeLink.appURL(videoID: videoID), let web = YouTubeLink.webURL(videoID: videoID) else { return }
        UIApplication.shared.open(app, options: [:]) { opened in
            if !opened { UIApplication.shared.open(web, options: [:]) }
        }
    }
}

/// A trailer that is ready to play in AVKit's player, shown in the page's panel. Playing sets the audio session to playback;
/// stopping pauses the player, releases its item and lets the session go. A trailer that was prepared but never played leaves the
/// session alone, so stopping it cannot silence something else the app has started since.
@MainActor
final class AVTrailerPlayback: TrailerPlayback {
    let player: AVPlayer
    let duration: TimeInterval?
    /// The shape of the panel: the picture's content when its black bars are cut (`fillsPicture`), else the picture as it is.
    let aspectRatio: Double?
    /// True when the picture's baked-in bars are cut: the player fills the panel, which is the shape of the content.
    let fillsPicture: Bool
    /// Never called: AVKit shows its own state once a trailer has started, including when it fails or ends.
    var onFinish: (@MainActor (TrailerPlaybackError?) -> Void)?
    private var hasActivatedSession = false

    init(player: AVPlayer, duration: TimeInterval?, aspectRatio: Double?, fillsPicture: Bool = false) {
        self.player = player
        self.duration = duration
        self.aspectRatio = aspectRatio
        self.fillsPicture = fillsPicture
    }

    func play() {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        try? AVAudioSession.sharedInstance().setActive(true)
        hasActivatedSession = true
        player.play()
    }

    func stop() {
        player.pause()
        player.replaceCurrentItem(with: nil)
        guard hasActivatedSession else { return }
        hasActivatedSession = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}

/// Makes AVKit's player for a trailer's link and waits until it has buffered enough to start.
///
/// The remote link goes to AVPlayer as it is. AVPlayer streams it itself (the segments of an HLS stream, or byte ranges of a progressive
/// file), so nothing is downloaded whole and the app caches nothing.
struct AVTrailerPreparer: TrailerPreparing {
    /// How long the item may take to learn whether it can play at all.
    static let readyTimeout: Duration = .seconds(20)
    /// How long to wait for the first buffer. After it the player waits by itself, so the page is not held longer than this.
    static let bufferTimeout: Duration = .seconds(6)
    /// How long the picture's bars may take to be measured. It runs while the first buffer loads; a measure that is not done by then
    /// leaves the picture whole.
    static let barsTimeout: Duration = .seconds(2)
    /// Where in the trailer its frames are read, as shares of its length. Not the very start or end, which are often black.
    static let barSamples: [Double] = [0.2, 0.35, 0.5, 0.65, 0.8]

    /// YouTube videos are not AVKit's: they play in YouTube's embedded player, see `YouTubeTrailerPreparer`.
    @MainActor
    func prepareYouTube(_ videoID: String) async throws -> any TrailerPlayback {
        try await YouTubeTrailerPreparer.prepare(videoID)
    }

    @MainActor
    func prepare(_ url: URL) async throws -> any TrailerPlayback {
        let item = AVPlayerItem(url: url)
        let player = AVPlayer(playerItem: item)
        player.automaticallyWaitsToMinimizeStalling = true
        // Set once the bars are being read, so a failure below can stop the read rather than wait for it.
        var measuring: Task<[LumaFrame]?, Never>?
        do {
            try await Self.waitUntilReady(item)
            let assetDuration = try? await item.asset.load(.duration)
            let seconds = assetDuration?.seconds
            // The frames are read while the first buffer loads, so the trailer waits for the longer of the two: at most `barsTimeout`
            // more than the buffer alone takes.
            let measure = Task { @MainActor in await Self.sampleFrames(of: item.asset, seconds: seconds) }
            measuring = measure
            try await Self.waitForBuffer(item)
            // The picture's shape is read only now: before the buffer it may not be known yet.
            let samples = await measure.value
            let size = item.presentationSize
            let shape = size.width > 0 && size.height > 0 ? Double(size.width / size.height) : nil
            let content = shape.flatMap { picture in
                samples.flatMap { TrailerLetterbox.contentAspectRatio(in: $0, pictureAspect: picture) }
            }
            return AVTrailerPlayback(player: player, duration: seconds.flatMap { $0.isFinite && $0 > 0 ? $0 : nil },
                                     aspectRatio: content ?? shape, fillsPicture: content != nil)
        } catch {
            measuring?.cancel()
            player.replaceCurrentItem(with: nil)
            throw error
        }
    }

    /// The frames of the picture that are read in time to measure its bars, else nil. A few frames of the trailer are read through AVKit's
    /// image generator, which fetches only what those frames need. A read that the timeout or a cancellation cuts short gives nil, so a
    /// picture is cut only on a complete read.
    @MainActor
    private static func sampleFrames(of asset: AVAsset, seconds: Double?) async -> [LumaFrame]? {
        guard let seconds, seconds.isFinite, seconds > 0 else { return nil }
        let times = Self.barSamples.map { CMTime(seconds: seconds * $0, preferredTimescale: 600) }
        let reader = SampleGenerator(LetterboxSampler.generator(for: asset))
        let sampling = Task { @MainActor in await LetterboxSampler.frames(from: reader, at: times) }
        let watchdog = Task { @MainActor in
            do {
                try await Task.sleep(for: Self.barsTimeout)
            } catch {
                // The read finished first, and the watchdog was cancelled.
                return
            }
            reader.generator.cancelAllCGImageGeneration()
            sampling.cancel()
        }
        let frames = await withTaskCancellationHandler {
            await sampling.value
        } onCancel: {
            sampling.cancel()
        }
        watchdog.cancel()
        guard !sampling.isCancelled else { return nil }
        return frames
    }

    /// Polls until the item is ready or has failed. A poll keeps this simple and cancellable.
    @MainActor
    private static func waitUntilReady(_ item: AVPlayerItem) async throws {
        let clock = ContinuousClock()
        let started = clock.now
        while item.status == .unknown {
            if started.duration(to: clock.now) > readyTimeout { throw TrailerPlaybackError.timedOut }
            try await Task.sleep(for: .milliseconds(50))
        }
        guard item.status == .readyToPlay else { throw TrailerPlaybackError.unplayable }
    }

    /// Polls until the first buffer is in, or the timeout passes. An item that fails meanwhile is unplayable.
    @MainActor
    private static func waitForBuffer(_ item: AVPlayerItem) async throws {
        let clock = ContinuousClock()
        let started = clock.now
        while !item.isPlaybackLikelyToKeepUp && !item.isPlaybackBufferFull {
            if item.status == .failed { throw TrailerPlaybackError.unplayable }
            if started.duration(to: clock.now) > bufferTimeout { return }
            try await Task.sleep(for: .milliseconds(50))
        }
    }
}

/// Reads frames of a trailer through AVKit's image generator, as grayscale samples for `TrailerLetterbox`. The generator reads only what the
/// frames need, so the trailer is not fetched whole.
enum LetterboxSampler {
    /// The largest size of a sampled frame. The bars show at this size, and a small frame costs little to read.
    static let sampleSize = CGSize(width: 320, height: 320)

    /// A generator for the trailer's frames, at the size the bars are read at.
    static func generator(for asset: AVAsset) -> AVAssetImageGenerator {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = sampleSize
        generator.requestedTimeToleranceBefore = .positiveInfinity
        generator.requestedTimeToleranceAfter = .positiveInfinity
        return generator
    }

    /// The frames at `times` that can be read, in order. Stops early when the task is cancelled.
    nonisolated static func frames(from reader: SampleGenerator, at times: [CMTime]) async -> [LumaFrame] {
        var frames: [LumaFrame] = []
        for time in times {
            guard !Task.isCancelled else { break }
            guard let sample = try? await reader.generator.image(at: time), let frame = LumaFrame(sample.image) else { continue }
            frames.append(frame)
        }
        return frames
    }
}

/// One measurement's image generator, held so the watchdog can cancel a read that runs past the timeout. Only the reading task calls
/// `image(at:)`; the watchdog only cancels.
final class SampleGenerator: @unchecked Sendable {
    let generator: AVAssetImageGenerator

    init(_ generator: AVAssetImageGenerator) {
        self.generator = generator
    }
}

extension LumaFrame {
    /// The picture as grayscale, each pixel's luma. Nil when the picture is empty or cannot be drawn.
    init?(_ image: CGImage) {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { return nil }
        var pixels = [UInt8](repeating: 0, count: width * height)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
            return true
        }
        guard drawn else { return nil }
        self.init(width: width, height: height, pixels: pixels)
    }
}

/// AVKit's own player controller, with its controls and full-screen button. A trailer that is full screen covers the page without leaving
/// it, so the loader is told when that starts and ends, and the player resumes if it was playing.
struct TrailerPlayerView: UIViewControllerRepresentable {
    let player: AVPlayer
    let loader: TrailerLoader
    /// True when the picture's bars are cut, so the picture fills the panel. Full screen always shows the whole picture.
    var fillsPicture = false

    func makeCoordinator() -> Coordinator {
        Coordinator(loader: loader, fillsPicture: fillsPicture)
    }

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = player
        controller.showsPlaybackControls = true
        controller.videoGravity = .resizeAspect
        controller.allowsPictureInPicturePlayback = false
        controller.updatesNowPlayingInfoCenter = false
        controller.delegate = context.coordinator
        controller.view.backgroundColor = .black
        controller.videoGravity = fillsPicture ? .resizeAspectFill : .resizeAspect
        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        if controller.player !== player { controller.player = player }
    }

    static func dismantleUIViewController(_ controller: AVPlayerViewController, coordinator: Coordinator) {
        controller.player = nil
        // A view that goes away while full screen never hears that full screen ended. The page must still close the player when it is left.
        coordinator.viewWasDismantled()
    }

    /// AVKit calls its delegate on the main thread, so each method hops onto the main actor to reach the loader.
    final class Coordinator: NSObject, AVPlayerViewControllerDelegate {
        private let loader: TrailerLoader
        /// The panel's picture is cut to its content; full screen puts the whole picture back, and the cut returns once it has closed.
        private let fillsPicture: Bool

        init(loader: TrailerLoader, fillsPicture: Bool) {
            self.loader = loader
            self.fillsPicture = fillsPicture
        }

        @MainActor
        func viewWasDismantled() {
            loader.isFullScreen = false
        }

        nonisolated func playerViewController(
            _ playerViewController: AVPlayerViewController,
            willBeginFullScreenPresentationWithAnimationCoordinator coordinator: UIViewControllerTransitionCoordinator
        ) {
            let loader = self.loader
            MainActor.assumeIsolated {
                loader.isFullScreen = true
                playerViewController.videoGravity = .resizeAspect
            }
        }

        nonisolated func playerViewController(
            _ playerViewController: AVPlayerViewController,
            willEndFullScreenPresentationWithAnimationCoordinator coordinator: UIViewControllerTransitionCoordinator
        ) {
            let loader = self.loader
            let fillsPicture = self.fillsPicture
            MainActor.assumeIsolated {
                // AVKit pauses the player when full screen closes, so it is started again once the transition has finished.
                let wasPlaying = playerViewController.player?.timeControlStatus != .paused
                coordinator.animate(alongsideTransition: nil) { context in
                    MainActor.assumeIsolated {
                        guard !context.isCancelled else { return }
                        loader.isFullScreen = false
                        if fillsPicture { playerViewController.videoGravity = .resizeAspectFill }
                        if wasPlaying { loader.playback?.play() }
                    }
                }
            }
        }
    }
}
#endif
