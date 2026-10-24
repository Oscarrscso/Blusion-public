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
    var layout = VideoLayout() { didSet { if layout != oldValue { setNeedsLayout() } } }
    private var sourceSize: CGSize? { didSet { if sourceSize != oldValue { setNeedsLayout() } } }
    private var sizeObservation: NSKeyValueObservation?
    private weak var observedPlayer: AVPlayer?

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
        sizeObservation = nil
        sourceSize = nil
        guard let player else { return }
        sizeObservation = player.observe(\.currentItem?.presentationSize, options: [.initial, .new]) { [weak self] player, _ in
            let size = player.currentItem?.presentationSize ?? .zero
            Task { @MainActor in self?.sourceSize = size.width > 0 && size.height > 0 ? size : nil }
        }
    }

    /// The gravity the picture is drawn with: the geometry sizes the frame itself, so it stretches into it.
    var videoGravity: AVLayerVideoGravity {
        guard sourceSize != nil else {
            return switch layout.fit {
            case .fit: .resizeAspect
            case .fill: .resizeAspectFill
            case .stretch: .resize
            }
        }
        return .resize
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // No animation: the picture stays where it is while the controls, the size or the layout change.
        UIView.performWithoutAnimation { placePicture() }
    }

    private func placePicture() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        videoView.transform = .identity
        if let sourceSize, let geometry = VideoGeometry(bounds: bounds.size, source: sourceSize, layout: layout) {
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
    }

    func host(superResolution layer: AVSampleBufferDisplayLayer) {
        guard superResolutionLayer !== layer else { return }
        superResolutionLayer?.removeFromSuperlayer()
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

struct PlayerSurface: UIViewRepresentable {
    let engine: (any PlaybackEngine)?
    let pip: PiPProxy
    var layout = VideoLayout()
    var upscaling = UpscalingMode.off
    var embeddedSubtitlesOn = false
    var ambientMode = false
    var superResolution: SuperResolutionRenderer?
    var ambient: AmbientSampler?

    func makeUIView(context: Context) -> PlayerLayerView {
        let view = PlayerLayerView()
        view.backgroundColor = .black
        view.playerLayer.videoGravity = .resizeAspect
        view.isAccessibilityElement = false
        return view
    }

    func updateUIView(_ view: PlayerLayerView, context: Context) {
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
                let scale = view.window?.screen.scale ?? view.traitCollection.displayScale
                let size = CGSize(width: view.bounds.width * scale, height: view.bounds.height * scale)
                superResolution.update(player: avEngine.player, wanted: upscaling == .ai, targetSize: size, gravity: view.videoGravity,
                                       embeddedSubtitlesOn: embeddedSubtitlesOn)
            }
            ambient?.update(player: avEngine.player, enabled: ambientMode)
        } else if let provider = engine as? any VideoSurfaceProviding, let surface = provider.videoSurface as? UIView {
            view.playerLayer.player = nil
            view.watch(nil)
            view.layout = VideoLayout()
            view.embed(surface)
            superResolution?.update(player: nil, wanted: false, targetSize: .zero, gravity: .resizeAspect, embeddedSubtitlesOn: false)
            ambient?.update(player: nil, enabled: false)
        } else {
            view.playerLayer.player = nil
            view.watch(nil)
            view.embed(nil)
            superResolution?.update(player: nil, wanted: false, targetSize: .zero, gravity: .resizeAspect, embeddedSubtitlesOn: false)
            ambient?.update(player: nil, enabled: false)
        }
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
