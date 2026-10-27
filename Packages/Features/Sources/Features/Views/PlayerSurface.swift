#if canImport(UIKit) && canImport(AVKit)
import AVKit
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
    private let clipView = UIView()

    private weak var embedded: UIView?
    /// Draws scaled frames over the player layer while AI super resolution runs. It moves and scales with the picture.
    private weak var superResolutionLayer: AVSampleBufferDisplayLayer?
    /// AVPlayer only: a fallback engine lays out its own picture (`EngineCapabilities.videoLayout`).
    var layout = VideoLayout() {
        didSet {
            guard layout != oldValue else { return }
            // Crop changes apply immediately; other Zoom Mode or Aspect Ratio changes ease the picture into place.
            if sourceSize != nil, window != nil, layout.fit != .fill, oldValue.fit != .fill {
                animatesNextLayout = true
            }
            setNeedsLayout()
        }
    }
    private var animatesNextLayout = false
    /// How long a zoom change takes to ease into place.
    static let zoomAnimationDuration: TimeInterval = 0.3
    private var sourceSize: CGSize? { didSet { if sourceSize != oldValue { setNeedsLayout() } } }
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

    /// Crop and Stretch: the picture is fitted in the view as in Normal, and the view is scaled up (`VideoGeometry.fillScale`), so the
    /// result never depends on the frame AVPlayer is handed matching the picture's shape.
    private var scalesFittedPicture: Bool { sourceSize != nil && layout.fit != .fit && layout.aspect.ratio == nil }

    /// The gravity the picture is drawn with: fitted while Crop or Stretch scales the view, else stretched into the frame the geometry
    /// sizes for it.
    var videoGravity: AVLayerVideoGravity {
        guard sourceSize != nil else {
            return switch layout.fit {
            case .fit: .resizeAspect
            case .fill: .resizeAspectFill
            case .stretch: .resize
            }
        }
        return scalesFittedPicture ? .resizeAspect : .resize
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let animates = animatesNextLayout
        animatesNextLayout = false
        guard animates else {
            // No animation: the picture stays where it is while the controls or the size change.
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
        if scalesFittedPicture, let sourceSize {
            let scale = VideoGeometry.fillScale(bounds: bounds.size, source: sourceSize, crop: layout.crop.ratio,
                                                stretch: layout.fit == .stretch, zoom: layout.zoom)
            clipView.frame = bounds
            videoView.bounds = CGRect(origin: .zero, size: bounds.size)
            videoView.center = CGPoint(x: bounds.midX, y: bounds.midY)
            videoView.transform = CGAffineTransform(scaleX: scale.width, y: scale.height)
        } else if let sourceSize, let geometry = VideoGeometry(bounds: bounds.size, source: sourceSize, layout: layout) {
            clipView.frame = geometry.visible
            videoView.frame = geometry.picture.offsetBy(dx: -geometry.visible.minX, dy: -geometry.visible.minY)
        } else {
            // No picture size yet: the layer places it by gravity, zoomed about the centre.
            clipView.frame = bounds
            videoView.bounds = CGRect(origin: .zero, size: bounds.size)
            videoView.center = CGPoint(x: bounds.midX, y: bounds.midY)
            videoView.transform = CGAffineTransform(scaleX: layout.zoom, y: layout.zoom)
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
        embedded?.removeFromSuperview()
        embedded = surface
        guard let surface else { return }
        surface.frame = bounds
        surface.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(surface)
    }
}

/// Picture in Picture for the AVPlayer engine. It starts only from `toggle()`, which only the PiP button calls (ADR-005: App Review rejects
/// programmatic starts).
@MainActor
@Observable
final class PiPProxy {
    private(set) var isPossible = false
    private(set) var isActive = false
    private var controller: AVPictureInPictureController?
    private var observations: [NSKeyValueObservation] = []

    func attach(to layer: AVPlayerLayer) {
        guard AVPictureInPictureController.isPictureInPictureSupported(), controller == nil,
              let controller = AVPictureInPictureController(playerLayer: layer) else { return }
        self.controller = controller
        observations.append(controller.observe(\.isPictureInPicturePossible, options: [.initial, .new]) { [weak self] controller, _ in
            let possible = controller.isPictureInPicturePossible
            Task { @MainActor in self?.isPossible = possible }
        })
        observations.append(controller.observe(\.isPictureInPictureActive, options: [.initial, .new]) { [weak self] controller, _ in
            let active = controller.isPictureInPictureActive
            Task { @MainActor in self?.isActive = active }
        })
    }

    func toggle() {
        guard let controller else { return }
        if controller.isPictureInPictureActive { controller.stopPictureInPicture() } else { controller.startPictureInPicture() }
    }
}

struct PlayerSurface: UIViewRepresentable, Equatable {
    let engine: (any PlaybackEngine)?
    let pip: PiPProxy
    var layout = VideoLayout()
    var upscaling = UpscalingMode.off
    var embeddedSubtitlesOn = false
    var ambientMode = false
    var superResolution: SuperResolutionRenderer?
    var sampler: PictureSampler?
    var onFirstVideoFrame: () -> Void = {}
    #if DEBUG
    var onTestGeometry: ((String) -> Void)?
    #endif

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.engine.map { ObjectIdentifier($0) } == rhs.engine.map { ObjectIdentifier($0) }
            && lhs.pip === rhs.pip && lhs.layout == rhs.layout && lhs.upscaling == rhs.upscaling
            && lhs.embeddedSubtitlesOn == rhs.embeddedSubtitlesOn && lhs.ambientMode == rhs.ambientMode
            && lhs.superResolution === rhs.superResolution && lhs.sampler === rhs.sampler
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
                pip.attach(to: view.playerLayer)
            }
            view.watch(avEngine.player)
            view.layout = layout
            if let superResolution {
                view.host(superResolution: superResolution.displayLayer)
                // The size is read from the layer as it is laid out, not here: the first update comes before the view has a size.
                superResolution.update(source: avEngine, wanted: upscaling == .ai, displayScale: Self.displayScale(of: view),
                                       gravity: view.videoGravity, embeddedSubtitlesOn: embeddedSubtitlesOn)
            }
            sampler?.update(source: avEngine, ambient: ambientMode)
        } else if let provider = engine as? any VideoSurfaceProviding, let surface = provider.videoSurface as? UIView {
            view.playerLayer.player = nil
            view.watch(nil)
            view.layout = VideoLayout()
            view.embed(surface)
            surface.backgroundColor = ambientMode ? .clear : .black
            if let superResolution {
                // AetherEngine: the scaled frames go over its picture, under its own subtitles, so its subtitles never block it. mpv has
                // no AVPlayer to read frames from, and the renderer says so.
                let host = engine as? any PictureOverlayHosting
                let wanted = upscaling == .ai
                host?.hostPictureOverlay(wanted ? superResolution.displayLayer : nil)
                superResolution.update(source: engine as? any AVPlayerFrameSource, wanted: wanted, displayScale: Self.displayScale(of: view),
                                       gravity: host?.pictureGravity ?? .resizeAspect, embeddedSubtitlesOn: false)
            }
            // AetherEngine plays through an AVPlayer most of the time; mpv draws its own picture and has none.
            sampler?.update(source: engine as? any AVPlayerFrameSource, ambient: ambientMode)
        } else {
            view.playerLayer.player = nil
            view.watch(nil)
            view.embed(nil)
            superResolution?.update(source: nil, wanted: false, displayScale: 1, gravity: .resizeAspect, embeddedSubtitlesOn: false)
            sampler?.update(source: nil, ambient: false)
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
