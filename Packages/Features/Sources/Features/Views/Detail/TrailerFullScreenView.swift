#if canImport(UIKit)
import SwiftUI

/// A trailer on a phone turned sideways, shown full screen on black with a button that closes the cover. It shows the page's own
/// player: AVKit's player is a second view of the same AVPlayer, so the trailer keeps playing, and YouTube's web view is moved here
/// from the panel, which stays empty while this is up.
struct TrailerFullScreenView: View {
    let trailer: TrailerLoader
    let close: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()
            if let playback = trailer.playback as? AVTrailerPlayback {
                TrailerPlayerView(player: playback.player, loader: trailer)
                    .ignoresSafeArea()
            } else if let playback = trailer.playback as? YouTubeTrailerPlayback {
                YouTubeTrailerView(playback: playback)
                    .ignoresSafeArea()
            }
            Button {
                Haptics.tap()
                close()
            } label: {
                Image(systemName: "xmark")
                    .font(.title3.weight(.semibold))
                    .frame(width: 44, height: 44)
                    .glassEffect(.regular.interactive(), in: .circle)
            }
            .accessibilityLabel("Close")
            .accessibilityIdentifier("detail.trailerClose")
            .padding()
        }
        #if os(iOS)
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        #endif
    }
}
#endif
