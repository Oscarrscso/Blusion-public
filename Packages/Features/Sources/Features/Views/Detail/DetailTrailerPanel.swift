#if canImport(UIKit)
import SwiftUI
import UIKit

/// The trailer's place on the title page, under the actions and above the synopsis: the player in a panel shaped like the trailer's
/// picture while a trailer plays (16:9 when the shape is not known; AVKit's player for a direct file, YouTube's embedded player for a
/// YouTube video), or one line saying it could not be played with a button that tries again. Nothing is shown while it loads (the trailer button
/// shows the spinner) or when idle.
struct DetailTrailerPanel: View {
    let model: DetailViewModel
    /// The panel's width. Its height follows the picture's shape, and in landscape it is never taller than 16:9 at this width.
    let width: CGFloat
    /// True while the page shows this trailer full screen. A YouTube web view is in one place at a time, so the panel stays empty then.
    var playerIsCovered = false
    @Environment(\.isLandscape) private var isLandscape
    /// The id the page scrolls to when the panel appears.
    static let scrollID = "detail.trailerPanel"

    var body: some View {
        content
            .id(Self.scrollID)
    }

    @ViewBuilder
    private var content: some View {
        // Portrait: never taller than the panel is wide. Landscape: never taller than the 16:9 panel the page allowed at this width.
        let size = TrailerPanelLayout.size(aspectRatio: model.trailer.aspectRatio, width: Double(width),
                                           maxHeight: Double(isLandscape ? width * 9 / 16 : width))
        switch model.trailer.phase {
        case .playing:
            if let playback = model.trailer.playback as? AVTrailerPlayback {
                TrailerPlayerView(player: playback.player, loader: model.trailer, fillsPicture: playback.fillsPicture)
                    .frame(width: size.width, height: size.height)
                    .mediaArtwork()
                    .frame(maxWidth: .infinity)
                    .accessibilityIdentifier("detail.trailerPlayer")
            } else if let playback = model.trailer.playback as? YouTubeTrailerPlayback {
                Group {
                    if playerIsCovered {
                        Color.black
                    } else {
                        YouTubeTrailerView(playback: playback)
                    }
                }
                .frame(width: size.width, height: size.height)
                .mediaArtwork()
                .frame(maxWidth: .infinity)
                .accessibilityIdentifier("detail.trailerPlayer")
            }
        case .failed(let message):
            InlineErrorView(message) { model.toggleTrailer() }
                .accessibilityIdentifier("detail.trailerError")
        case .idle, .loading:
            EmptyView()
        }
    }
}
#endif
