import Testing
import UIKit
import PlayerKit
import StremioKit
@testable import Features

@MainActor
@Suite struct PlayerPresentationTests {
    @Test func realSegmentedControlRetainsAllTabsAndSelectionWhileResizing() {
        let control = PlayerTabSegmentedControl(tabs: PlayerPanelTab.allCases)
        control.selectedSegmentIndex = 3
        for width in [CGFloat(260), 600, 320, 440] {
            control.frame = CGRect(x: 0, y: 0, width: width, height: 44)
            control.setNeedsLayout()
            control.layoutIfNeeded()
            #expect(control.numberOfSegments == 5)
            #expect(control.selectedSegmentIndex == 3)
            for (index, tab) in PlayerPanelTab.allCases.enumerated() {
                let label = control.titleForSegment(at: index) ?? control.imageForSegment(at: index)?.accessibilityLabel
                #expect(label == tab.title)
            }
        }
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
