#if canImport(AVFoundation)
@preconcurrency import AVFoundation
import CoreMedia

/// An engine whose picture can go into Picture in Picture. The layer is an `AVPlayerLayer` on the native route (AVPlayer, and AetherEngine's
/// native route), or an `AVSampleBufferDisplayLayer` on a software route, which AVKit drives through the transport below.
@MainActor
public protocol PictureInPictureProviding: AnyObject {
    /// The layer the window shows; nil while the engine has none (mpv has none).
    var pictureInPictureLayer: CALayer? { get }
    /// The playable range of a sample-buffer layer, on its timebase. Invalid when nothing plays.
    func pictureInPictureTimeRange() -> CMTimeRange
    var isPictureInPicturePaused: Bool { get }
    func setPictureInPicturePlaying(_ playing: Bool)
    func skipPictureInPicture(by seconds: Double) async
    /// The window is open or closed. An engine draws subtitles into the picture while it is open.
    func setPictureInPictureActive(_ active: Bool)
}

/// A backend that can hand its picture layer to Picture in Picture (AetherEngine). `FallbackEngine` passes its answers on.
@MainActor
public protocol PictureInPictureBacking: AnyObject {
    var pictureInPictureLayer: CALayer? { get }
    func pictureInPictureTimeRange() -> CMTimeRange
    func setPictureInPictureActive(_ active: Bool)
}
#endif
