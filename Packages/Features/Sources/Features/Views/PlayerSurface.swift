#if canImport(UIKit) && canImport(AVKit)
import AVKit
import CoreMedia
import PlayerKit
import StremioKit
import SwiftUI
import UIKit

/// The AVPlayer picture: a view backed by an `AVPlayerLayer`.
final class PlayerVideoView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }

    var playerLayer: AVPlayerLayer {
        guard let layer = layer as? AVPlayerLayer else { preconditionFailure("layerClass is AVPlayerLayer") }
        return layer
    }
}

/// Hosts the AVPlayer picture or the view a fallback engine renders into. The AVPlayer picture is placed by `VideoGeometry` (aspect
/// override, crop, fit, zoom): the whole picture is drawn into its frame, inside a clipping view the size of the part that shows.
final class PlayerLayerView: UIView {
    let videoView = PlayerVideoView()
    var playerLayer: AVPlayerLayer { videoView.playerLayer }
    /// Clips the picture to its visible part, so a crop hides the bars.
    let clipView = UIView()

    private weak var embedded: UIView?
    /// Draws scaled frames over the player layer while AI super resolution runs. It moves and scales with the picture.
    private weak var superResolutionLayer: AVSampleBufferDisplayLayer?
    /// AVPlayer only: a fallback engine lays out its own picture (`EngineCapabilities.videoLayout`).
    var layout = VideoLayout() {
        didSet {
            guard layout != oldValue else { return }
            // A new inset comes with a rotation, so it applies at once, as the new size does; only a picture change eases into place.
            var sameInset = layout
            sameInset.inset = oldValue.inset
            if sameInset != oldValue, sourceSize != nil, window != nil, embedded == nil {
                animatesNextLayout = true
            }
            setNeedsLayout()
        }
    }
    private var animatesNextLayout = false
    private var laidOutSize = CGSize.zero
    /// How long a zoom change takes to ease into place.
    static let zoomAnimationDuration: TimeInterval = 0.3
    var sourceSize: CGSize? { didSet { if sourceSize != oldValue { setNeedsLayout() } } }
    private var sizeObservation: NSKeyValueObservation?
    private var frameObservation: NSKeyValueObservation?
    var onFirstVideoFrame: (() -> Void)?
    private weak var observedPlayer: AVPlayer?
    private var observationGeneration = 0
    private var reportedFirstFrame = false
    #if DEBUG
    var onTestGeometry: ((String) -> Void)?
    private let testSurfaceID = UUID().uuidString
    private var lastTestGeometry = ""
    private var exposesTestGeometry: Bool { ProcessInfo.processInfo.environment["BLUSION_UITEST"] == "1" }
    #endif

    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = true
        clipView.clipsToBounds = true
        clipView.isUserInteractionEnabled = false
        videoView.backgroundColor = .clear
        videoView.isAccessibilityElement = false
        clipView.addSubview(videoView)
        addSubview(clipView)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    /// Follows the player's picture size, which the geometry needs.
    func watch(_ player: AVPlayer?) {
        guard player !== observedPlayer else { return }
        observedPlayer = player
        observationGeneration += 1
        let generation = observationGeneration
        reportedFirstFrame = false
        animatesNextLayout = false
        sizeObservation = nil
        frameObservation = nil
        sourceSize = nil
        guard let player else { return }
        // AVPlayer may report "playing" before the layer displays a decoded frame.
        // Keep the startup artwork until the actual first picture appears.
        frameObservation = playerLayer.observe(\.isReadyForDisplay, options: [.initial, .new]) { [weak self] layer, _ in
            let ready = layer.isReadyForDisplay
            guard ready else { return }
            Task { @MainActor [weak self] in
                guard let self, self.observationGeneration == generation, !self.reportedFirstFrame,
                      self.playerLayer.isReadyForDisplay else { return }
                self.reportedFirstFrame = true
                self.onFirstVideoFrame?()
            }
        }
        sizeObservation = player.observe(\.currentItem?.presentationSize, options: [.initial, .new]) { [weak self] player, _ in
            let size = player.currentItem?.presentationSize ?? .zero
            Task { @MainActor [weak self] in
                guard let self, self.observationGeneration == generation else { return }
                self.sourceSize = size.width > 0 && size.height > 0 ? size : nil
            }
        }
    }

    /// Once the source size is known, geometry supplies the final frame in every mode.
    var videoGravity: AVLayerVideoGravity {
        sourceSize == nil ? .resizeAspect : .resize
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let sizeChanged = bounds.size != laidOutSize
        laidOutSize = bounds.size
        let animates = animatesNextLayout && !sizeChanged && embedded == nil
        animatesNextLayout = false
        guard animates else {
            // Rotation, resize, and engine switches apply immediately without animating stale bounds.
            UIView.performWithoutAnimation { placePicture(animated: false) }
            return
        }
        UIView.animate(withDuration: Self.zoomAnimationDuration, delay: 0, options: [.curveEaseInOut, .beginFromCurrentState]) {
            self.placePicture(animated: true)
        }
    }

    private func placePicture(animated: Bool) {
        CATransaction.begin()
        if animated {
            // The super resolution layer is no view's own layer: it follows the frames with the same timing.
            CATransaction.setAnimationDuration(Self.zoomAnimationDuration)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeInEaseOut))
        } else {
            CATransaction.setDisableActions(true)
        }
        videoView.transform = .identity
        if let sourceSize, let geometry = VideoGeometry(bounds: bounds.size, source: sourceSize, layout: layout) {
            clipView.frame = geometry.visible
            videoView.frame = geometry.picture.offsetBy(dx: -layoutClipOriginX(geometry), dy: -layoutClipOriginY(geometry))
        } else {
            // Until metadata arrives, preserve the whole frame without guessing a crop or zoom.
            clipView.frame = bounds
            videoView.bounds = CGRect(origin: .zero, size: bounds.size)
            videoView.center = CGPoint(x: bounds.midX, y: bounds.midY)
        }
        playerLayer.videoGravity = videoGravity
        superResolutionLayer?.frame = videoView.bounds
        superResolutionLayer?.videoGravity = videoGravity
        CATransaction.commit()
        #if DEBUG
        if exposesTestGeometry, window != nil {
            let frame = embedded?.frame ?? videoView.frame
            let measured = "\(testSurfaceID)|\(convert(bounds, to: nil))|\(clipView.frame)|\(frame)"
            if measured != lastTestGeometry {
                lastTestGeometry = measured
                Task { @MainActor [weak self] in
                    guard let self, self.window != nil else { return }
                    self.onTestGeometry?(measured)
                }
            }
        }
        #endif
    }

    private func layoutClipOriginX(_ geometry: VideoGeometry) -> CGFloat { geometry.visible.minX }
    private func layoutClipOriginY(_ geometry: VideoGeometry) -> CGFloat { geometry.visible.minY }

    func host(superResolution layer: AVSampleBufferDisplayLayer) {
        // The layer may have gone over AetherEngine's picture in the meantime: it is taken back.
        guard layer.superlayer !== videoView.layer else { return }
        if superResolutionLayer !== layer { superResolutionLayer?.removeFromSuperlayer() }
        videoView.layer.addSublayer(layer)
        superResolutionLayer = layer
        setNeedsLayout()
    }

    /// Hosts the view a fallback engine renders into (nil removes it).
    func embed(_ surface: UIView?) {
        guard surface !== embedded else { return }
        animatesNextLayout = false
        embedded?.removeFromSuperview()
        embedded = surface
        guard let surface else { return }
        surface.frame = bounds
        surface.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(surface)
    }
}

/// Picture in Picture for the layer an engine draws: an AVPlayerLayer (the AVPlayer route, and AetherEngine's native route), or an
/// AVSampleBufferDisplayLayer (AetherEngine's software route, driven through `PiPSampleBufferDelegate`). It starts from `toggle()`, which
/// only the PiP button calls, or by itself when the app leaves the front while the picture plays (`canStartPictureInPictureAutomaticallyFromInline`,
/// the system's own start rather than a programmatic one; ADR-005: App Review rejects programmatic starts).
@MainActor
@Observable
final class PiPProxy {
    private(set) var isPossible = false
    private(set) var isActive = false
    @ObservationIgnored private var controller: AVPictureInPictureController?
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []
    /// The layer and engine the window should show. An open window keeps what it shows; these apply when it closes.
    @ObservationIgnored private weak var wantedLayer: CALayer?
    @ObservationIgnored private weak var wantedSource: (any PictureInPictureProviding)?
    /// The layer and engine the controller was built on.
    @ObservationIgnored private weak var boundLayer: CALayer?
    @ObservationIgnored private weak var boundSource: (any PictureInPictureProviding)?
    /// AVKit holds its playback delegate weakly, so the proxy keeps it for as long as the controller lives.
    @ObservationIgnored private var sampleBufferDelegate: PiPSampleBufferDelegate?

    /// Shows `layer` in the window. `source` is the engine behind a sample-buffer layer; an AVPlayerLayer needs none.
    func attach(to layer: CALayer?, source: (any PictureInPictureProviding)? = nil) {
        guard layer !== wantedLayer else { return }
        wantedLayer = layer
        wantedSource = source
        rebind()
    }

    /// The engine has no layer to show (mpv, or its picture left the screen).
    func detach() { attach(to: nil) }

    /// The engine's playback changed (paused, played, or a new duration): AVKit reads the state again.
    func playbackStateChanged() { controller?.invalidatePlaybackState() }

    func toggle() {
        guard let controller else { return }
        if controller.isPictureInPictureActive { controller.stopPictureInPicture() } else { controller.startPictureInPicture() }
    }

    /// Builds the controller for the wanted layer, unless the window is open or the layer is already bound.
    private func rebind() {
        guard !isActive, wantedLayer !== boundLayer else { return }
        unbind()
        guard let layer = wantedLayer, AVPictureInPictureController.isPictureInPictureSupported() else { return }
        let made: AVPictureInPictureController?
        if let playerLayer = layer as? AVPlayerLayer {
            made = AVPictureInPictureController(playerLayer: playerLayer)
        } else if let bufferLayer = layer as? AVSampleBufferDisplayLayer, let source = wantedSource {
            let delegate = PiPSampleBufferDelegate(source: source)
            sampleBufferDelegate = delegate
            made = AVPictureInPictureController(contentSource: AVPictureInPictureController.ContentSource(
                sampleBufferDisplayLayer: bufferLayer, playbackDelegate: delegate))
        } else {
            made = nil
        }
        guard let made else { return }
        // Going home while the picture plays floats it in the window, with no tap: the system starts it, not the app.
        made.canStartPictureInPictureAutomaticallyFromInline = true
        controller = made
        boundLayer = layer
        boundSource = wantedSource
        observe(made)
    }

    private func unbind() {
        observations.removeAll()
        controller = nil
        sampleBufferDelegate = nil
        boundLayer = nil
        boundSource = nil
        isPossible = false
    }

    private func observe(_ controller: AVPictureInPictureController) {
        observations.append(controller.observe(\.isPictureInPicturePossible, options: [.initial, .new]) { [weak self] controller, _ in
            let possible = controller.isPictureInPicturePossible
            Task { @MainActor in self?.isPossible = possible }
        })
        observations.append(controller.observe(\.isPictureInPictureActive, options: [.initial, .new]) { [weak self] controller, _ in
            let active = controller.isPictureInPictureActive
            Task { @MainActor in self?.windowActivityChanged(active) }
        })
    }

    /// The window opened or closed. The engine draws subtitles into the picture while it is open, and a layer that changed meanwhile
    /// takes over when it closes.
    private func windowActivityChanged(_ active: Bool) {
        isActive = active
        boundSource?.setPictureInPictureActive(active)
        if !active { rebind() }
    }
}

/// AVKit's playback answers for a sample-buffer layer, taken from the engine that draws it. AVKit calls them on the main thread.
@MainActor
final class PiPSampleBufferDelegate: NSObject, @preconcurrency AVPictureInPictureSampleBufferPlaybackDelegate {
    private let source: any PictureInPictureProviding

    init(source: any PictureInPictureProviding) {
        self.source = source
        super.init()
    }

    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, setPlaying playing: Bool) {
        source.setPictureInPicturePlaying(playing)
    }

    func pictureInPictureControllerTimeRangeForPlayback(_ pictureInPictureController: AVPictureInPictureController) -> CMTimeRange {
        source.pictureInPictureTimeRange()
    }

    func pictureInPictureControllerIsPlaybackPaused(_ pictureInPictureController: AVPictureInPictureController) -> Bool {
        source.isPictureInPicturePaused
    }

    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, didTransitionToRenderSize newRenderSize: CMVideoDimensions) {}

    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, skipByInterval skipInterval: CMTime,
                                    completion completionHandler: @escaping () -> Void) {
        nonisolated(unsafe) let finish = completionHandler
        Task {
            await source.skipPictureInPicture(by: skipInterval.seconds)
            finish()
        }
    }
}

struct PlayerSurface: UIViewRepresentable, Equatable {
    let engine: (any PlaybackEngine)?
    let pip: PiPProxy
    var layout = VideoLayout()
    var upscaling = UpscalingMode.off
    var hdrBrightness = 0.0
    var embeddedSubtitlesOn = false
    var ambientMode = false
    var superResolution: SuperResolutionRenderer?
    var sampler: PictureSampler?
    /// The first frame is on screen. A Picture in Picture layer can appear with it, so this is what updates the view to take it.
    var pictureReady = false
    /// Paused, so the Picture in Picture window's controls show it.
    var paused = false
    var onFirstVideoFrame: () -> Void = {}
    #if DEBUG
    var onTestGeometry: ((String) -> Void)?
    #endif

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.engine.map { ObjectIdentifier($0) } == rhs.engine.map { ObjectIdentifier($0) }
            && lhs.pip === rhs.pip && lhs.layout == rhs.layout && lhs.upscaling == rhs.upscaling
            && lhs.hdrBrightness == rhs.hdrBrightness
            && lhs.embeddedSubtitlesOn == rhs.embeddedSubtitlesOn && lhs.ambientMode == rhs.ambientMode
            && lhs.superResolution === rhs.superResolution && lhs.sampler === rhs.sampler
            && lhs.pictureReady == rhs.pictureReady && lhs.paused == rhs.paused
    }

    func makeUIView(context: Context) -> PlayerLayerView {
        let view = PlayerLayerView()
        view.backgroundColor = .black
        view.playerLayer.videoGravity = .resizeAspect
        view.isAccessibilityElement = false
        return view
    }

    func updateUIView(_ view: PlayerLayerView, context: Context) {
        view.onFirstVideoFrame = onFirstVideoFrame
        #if DEBUG
        view.onTestGeometry = onTestGeometry
        #endif
        // Ambient mode's glow lies behind the picture: around it, the surface must let it through.
        view.backgroundColor = ambientMode ? .clear : .black
        if let avEngine = engine as? AVEngine {
            view.embed(nil)
            if view.playerLayer.player !== avEngine.player {
                view.playerLayer.player = avEngine.player
            }
            pip.attach(to: view.playerLayer)
            view.watch(avEngine.player)
            view.layout = layout
            HDRBrightnessOverride.apply(hdrBrightness, to: view.playerLayer)
            if let superResolution {
                view.host(superResolution: superResolution.displayLayer)
                // The size is read from the layer as it is laid out, not here: the first update comes before the view has a size.
                HDRBrightnessOverride.apply(hdrBrightness, to: superResolution.displayLayer)
                superResolution.update(source: avEngine, wanted: upscaling == .ai, displayScale: Self.displayScale(of: view),
                                       gravity: view.videoGravity, embeddedSubtitlesOn: embeddedSubtitlesOn)
            }
            sampler?.update(source: avEngine, ambient: ambientMode, cropRatio: layout.crop.ratio)
        } else if let provider = engine as? any VideoSurfaceProviding, let surface = provider.videoSurface as? UIView {
            view.playerLayer.player = nil
            view.watch(nil)
            view.layout = VideoLayout()
            view.embed(surface)
            surface.backgroundColor = ambientMode ? .clear : .black
            // AetherEngine's own layer: its AVPlayerLayer on the native route, its sample-buffer layer on the software route. mpv has neither,
            // so the window has nothing to show.
            let pictureSource = engine as? any PictureInPictureProviding
            pip.attach(to: pictureSource?.pictureInPictureLayer, source: pictureSource)
            pip.playbackStateChanged()
            if let superResolution {
                // AetherEngine: the scaled frames go over its picture, under its own subtitles, so its subtitles never block it. mpv has
                // no AVPlayer to read frames from, and the renderer says so.
                let host = engine as? any PictureOverlayHosting
                let wanted = upscaling == .ai
                host?.hostPictureOverlay(wanted ? superResolution.displayLayer : nil)
                HDRBrightnessOverride.apply(hdrBrightness, to: superResolution.displayLayer)
                superResolution.update(source: engine as? any AVPlayerFrameSource, wanted: wanted, displayScale: Self.displayScale(of: view),
                                       gravity: host?.pictureGravity ?? .resizeAspect, embeddedSubtitlesOn: false)
            }
            sampler?.update(source: engine as? any AVPlayerFrameSource, ambient: ambientMode, cropRatio: layout.crop.ratio)
        } else {
            view.playerLayer.player = nil
            view.watch(nil)
            view.embed(nil)
            pip.detach()
            superResolution?.update(source: nil, wanted: false, displayScale: 1, gravity: .resizeAspect, embeddedSubtitlesOn: false)
            sampler?.update(source: nil, ambient: false)
        }
    }
}

/// HDR brightness on a picture layer we draw (AVPlayer's, and the super resolution layer). Core Animation has no level between its ranges,
/// so any brightness above 0 asks for `high`, the display's whole HDR range; 0 puts back what the layer had.
@MainActor
enum HDRBrightnessOverride {
    private static let originals = NSMapTable<CALayer, NSString>.weakToStrongObjects()

    static func apply(_ level: Double, to layer: CALayer) {
        if level > 0 {
            if originals.object(forKey: layer) == nil { originals.setObject(layer.preferredDynamicRange.rawValue as NSString, forKey: layer) }
            if layer.preferredDynamicRange != .high { layer.preferredDynamicRange = .high }
        } else if let original = originals.object(forKey: layer) {
            layer.preferredDynamicRange = CALayer.DynamicRange(rawValue: original as String)
            originals.removeObject(forKey: layer)
        }
    }
}

extension PlayerSurface {
    /// Pixels per point of the screen the picture is on.
    fileprivate static func displayScale(of view: UIView) -> CGFloat {
        view.window?.screen.scale ?? view.traitCollection.displayScale
    }
}

/// The system AirPlay route picker.
struct AirPlayButton: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.tintColor = .white
        view.activeTintColor = .systemBlue
        view.prioritizesVideoDevices = true
        return view
    }

    func updateUIView(_ view: AVRoutePickerView, context: Context) {}
}
#endif
