import Testing
import UIKit
import PlayerKit
import StremioKit
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
}
