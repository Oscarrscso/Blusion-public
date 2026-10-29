#if canImport(AVFoundation)
@preconcurrency import AVFoundation

/// An engine whose picture plays through an AVPlayer that Blusion can read small copies of frames from for ambient mode's colours.
/// AVPlayer itself, and AetherEngine whenever it plays through AVPlayer.
@MainActor
public protocol AVPlayerFrameSource: AnyObject {
    /// The AVPlayer playing the picture now; nil when none does. It can change during playback.
    var framePlayer: AVPlayer? { get }
}

extension AVEngine: AVPlayerFrameSource {
    public var framePlayer: AVPlayer? { player }
}

/// An engine that draws its own picture but can carry a layer over it, placed and sized with it: AI super resolution's scaled frames.
@MainActor
public protocol PictureOverlayHosting: AnyObject {
    /// Shows `layer` over the picture; nil removes it.
    func hostPictureOverlay(_ layer: CALayer?)
    /// How the picture is drawn into its frame.
    var pictureGravity: AVLayerVideoGravity { get }
    /// The stream is HDR or Dolby Vision: the super-resolution scaler takes 8-bit SDR frames only.
    var pictureIsHDR: Bool { get }
}
#endif
