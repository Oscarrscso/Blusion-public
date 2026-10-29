import AVFoundation
import Testing
import UIKit
import PlayerKit
import StremioKit
#if BLUSION_FALLBACK_ENGINE && !targetEnvironment(macCatalyst)
@testable import AetherPlayer
#endif
@testable import Features

@MainActor
@Suite struct PlayerPresentationTests {
    /// The bar under the timeline is the system segmented control: a segment per menu, none selected until one opens.
    @Test func menuBarHasASegmentPerMenuAndKeepsTheOpenOneWhileItsContentChanges() {
        let control = PlayerMenuSegmentedControl(frame: .zero)
        let tabs: [PlayerPanelTab] = [.subtitles, .speed, .picture, .info]
        control.configure(tabs: tabs, speedLabel: nil, subtitlesOn: false)
        #expect(control.numberOfSegments == 4)
        #expect(control.selectedSegmentIndex == UISegmentedControl.noSegment)
        for (index, tab) in tabs.enumerated() {
            #expect(control.imageForSegment(at: index)?.accessibilityLabel == tab.title)
        }
        control.selectedSegmentIndex = 1
        control.configure(tabs: tabs, speedLabel: "1.5×", subtitlesOn: true)
        #expect(control.titleForSegment(at: 1) == "1.5×")
        #expect(control.imageForSegment(at: 1) == nil)
        #expect(control.selectedSegmentIndex == 1, "a changing rate keeps the open menu selected")
        control.configure(tabs: tabs, speedLabel: nil, subtitlesOn: true)
        #expect(control.titleForSegment(at: 1) == nil)
        #expect(control.imageForSegment(at: 1)?.accessibilityLabel == "Speed")
        let withChapters: [PlayerPanelTab] = [.subtitles, .speed, .chapters, .picture, .info]
        control.configure(tabs: withChapters, speedLabel: nil, subtitlesOn: true)
        #expect(control.numberOfSegments == 5)
        #expect(control.imageForSegment(at: 2)?.accessibilityLabel == "Chapters")
    }

    @Test func videoSurfaceInputsChangeOnlyForPlaybackConfiguration() {
        let pip = PiPProxy()
        let original = PlayerSurface(engine: nil, pip: pip)
        let clockOrControlUpdate = PlayerSurface(engine: nil, pip: pip)
        let fill = PlayerSurface(engine: nil, pip: pip, layout: VideoLayout(fit: .fill))
        #expect(original == clockOrControlUpdate)
        #expect(original != fill)
    }

    @Test func playerLayerViewRendersExactRectanglesAcrossRotationResolutionChangesAndSuperResolution() throws {
        let phone = CGRect(x: 0, y: 0, width: 852, height: 393)
        let portrait = CGRect(x: 0, y: 0, width: 393, height: 852)
        let hd = CGSize(width: 1920, height: 1080)

        let surface = PlayerLayerView(frame: phone)
        let superResLayer = AVSampleBufferDisplayLayer()
        surface.host(superResolution: superResLayer)
        surface.sourceSize = hd
        surface.layout = VideoLayout(zoomMode: .crop, aspectRatio: .widescreenA)
        surface.layoutIfNeeded()

        let expected185 = try #require(VideoGeometry(bounds: phone.size, source: hd, layout: surface.layout))
        #expect(surface.playerLayer.videoGravity == .resize, "once source size is known, AVPlayerLayer must not add implicit gravity crop/fit")
        #expect(surface.videoView.transform == .identity, "scale transforms must never accumulate")
        #expect(abs(surface.clipView.frame.width - expected185.visible.width) < 0.01)
        #expect(abs(surface.clipView.frame.height - expected185.visible.height) < 0.01)
        let pictureInSurface = surface.clipView.convert(surface.videoView.frame, to: surface)
        #expect(abs(pictureInSurface.minX - expected185.picture.minX) < 0.01)
        #expect(abs(pictureInSurface.minY - expected185.picture.minY) < 0.01)
        #expect(abs(pictureInSurface.width - expected185.picture.width) < 0.01)
        #expect(abs(pictureInSurface.height - expected185.picture.height) < 0.01)
        #expect(superResLayer.frame == surface.videoView.bounds && superResLayer.videoGravity == .resize)

        // Rotate to portrait, switch resolution to UHD, embed a fallback view, then return to native landscape 1.85:1.
        surface.frame = portrait
        surface.sourceSize = CGSize(width: 3840, height: 2160)
        surface.layout = VideoLayout(zoomMode: .fill, aspectRatio: .widescreenB)
        surface.layoutIfNeeded()
        #expect(surface.videoView.transform == .identity)

        let fallback = UIView()
        surface.embed(fallback)
        surface.layoutIfNeeded()
        #expect(fallback.frame == portrait)
        surface.embed(nil)

        surface.frame = phone
        surface.sourceSize = hd
        surface.layout = VideoLayout(zoomMode: .crop, aspectRatio: .widescreenA)
        surface.layoutIfNeeded()
        let returned = surface.clipView.convert(surface.videoView.frame, to: surface)
        #expect(abs(surface.clipView.frame.width - expected185.visible.width) < 0.01)
        #expect(abs(returned.height - expected185.picture.height) < 0.01)
        #expect(surface.videoView.transform == .identity)

        #if BLUSION_FALLBACK_ENGINE && !targetEnvironment(macCatalyst)
        // Parity check: AetherHostView produces the exact same rendered clip and picture rectangles!
        let aetherHost = AetherHostView(frame: phone)
        aetherHost.displaySize = hd
        aetherHost.fit = .fit
        aetherHost.crop = 1.85
        aetherHost.layoutIfNeeded()
        #expect(aetherHost.currentGravity == .resize)
        #expect(abs(aetherHost.overlay.videoRect.width - expected185.visible.width) < 0.01)
        #expect(abs(aetherHost.overlay.pictureRect.height - expected185.picture.height) < 0.01)
        #endif
    }
}
