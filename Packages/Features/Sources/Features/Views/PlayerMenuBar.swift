#if canImport(UIKit)
import SwiftUI
import UIKit

/// The bar under the timeline: one system segmented control, a segment per menu. Its slider sits on the open menu and moves to
/// another when that is tapped or the finger slides along the bar; with no menu open no segment is selected. Tapping the open
/// menu's segment again closes it. UIKit owns the slider, its glass, tracking and animation; SwiftUI only mirrors the value.
struct PlayerMenuBar: UIViewRepresentable {
    let tabs: [PlayerPanelTab]
    @Binding var selection: PlayerPanelTab?
    /// Shown in the speed segment instead of its symbol while the rate is not normal, e.g. "1.5×".
    var speedLabel: String?
    var subtitlesOn = false

    /// Wide enough for the speed segment's "1.25×".
    static let segmentWidth: CGFloat = 52

    func makeCoordinator() -> Coordinator { Coordinator(selection: $selection) }

    func makeUIView(context: Context) -> PlayerMenuSegmentedControl {
        let control = PlayerMenuSegmentedControl(frame: .zero)
        control.apportionsSegmentWidthsByContent = false
        // The glass capsule around the bar is its track; the control draws only its slider.
        control.backgroundColor = .clear
        control.addTarget(context.coordinator, action: #selector(Coordinator.changed(_:)), for: .valueChanged)
        control.accessibilityIdentifier = "player.menuBar"
        return control
    }

    func updateUIView(_ control: PlayerMenuSegmentedControl, context: Context) {
        context.coordinator.selection = $selection
        control.configure(tabs: tabs, speedLabel: speedLabel, subtitlesOn: subtitlesOn)
        let index = selection.flatMap { tabs.firstIndex(of: $0) } ?? UISegmentedControl.noSegment
        // Assigning the same index during tracking can interrupt UIKit's slide.
        if control.selectedSegmentIndex != index { control.selectedSegmentIndex = index }
        control.onReselect = { [selection = $selection] in
            // Re-tapping the tab already showing closes the panel, which is a change of screen rather than a tab change.
            Haptics.tap()
            selection.wrappedValue = nil
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: PlayerMenuSegmentedControl, context: Context) -> CGSize? {
        CGSize(width: CGFloat(tabs.count) * Self.segmentWidth, height: max(36, uiView.intrinsicContentSize.height))
    }

    @MainActor
    final class Coordinator: NSObject {
        var selection: Binding<PlayerPanelTab?>

        init(selection: Binding<PlayerPanelTab?>) { self.selection = selection }

        @objc func changed(_ control: PlayerMenuSegmentedControl) {
            guard control.tabs.indices.contains(control.selectedSegmentIndex) else { return }
            let tab = control.tabs[control.selectedSegmentIndex]
            guard selection.wrappedValue != tab else { return }
            Haptics.selection()
            selection.wrappedValue = tab
        }
    }
}

/// The menu bar's control: symbols with spoken titles, the speed rate as text, and a tap on the selected segment reported.
final class PlayerMenuSegmentedControl: UISegmentedControl, UIGestureRecognizerDelegate {
    private(set) var tabs: [PlayerPanelTab] = []
    /// What each segment shows: a symbol name, or "text:" and a title.
    private var content: [String] = []
    var onReselect: (() -> Void)?
    /// The selection when the finger came down, before UIKit moves the slider for this touch.
    private var selectionAtTouchDown = UISegmentedControl.noSegment

    override init(frame: CGRect) {
        super.init(frame: frame)
        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
        tap.cancelsTouchesInView = false
        tap.delaysTouchesEnded = false
        tap.delegate = self
        addGestureRecognizer(tap)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Rebuilds the segments only when a menu came or went; otherwise changes what the segments show in place.
    func configure(tabs: [PlayerPanelTab], speedLabel: String?, subtitlesOn: Bool) {
        let next = tabs.map { tab -> String in
            switch tab {
            case .subtitles: subtitlesOn ? "captions.bubble.fill" : "captions.bubble"
            case .speed: speedLabel.map { "text:" + $0 } ?? tab.symbol
            default: tab.symbol
            }
        }
        guard tabs != self.tabs || next != content else { return }
        if tabs != self.tabs {
            removeAllSegments()
            for index in tabs.indices { insertSegment(withTitle: nil, at: index, animated: false) }
            selectedSegmentIndex = UISegmentedControl.noSegment   // the caller selects the open menu next
            self.tabs = tabs
            content = []
        }
        for (index, item) in next.enumerated() where content.count != next.count || content[index] != item {
            // Each UIKit setter clears the other kind of content, so the old kind goes first and the intended one last.
            if item.hasPrefix("text:") {
                setImage(nil, forSegmentAt: index)
                setTitle(String(item.dropFirst(5)), forSegmentAt: index)
            } else {
                let symbol = UIImage(systemName: item, withConfiguration: UIImage.SymbolConfiguration(textStyle: .body, scale: .medium))
                symbol?.accessibilityLabel = tabs[index].title
                setTitle(nil, forSegmentAt: index)
                setImage(symbol, forSegmentAt: index)
            }
        }
        content = next
    }

    func gestureRecognizer(_ recognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        selectionAtTouchDown = selectedSegmentIndex
        return true
    }

    func gestureRecognizer(_ recognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        true
    }

    /// A tap on the segment that was already selected when the finger came down: the open menu closes.
    @objc private func tapped(_ recognizer: UITapGestureRecognizer) {
        guard recognizer.state == .ended, numberOfSegments > 0, selectionAtTouchDown != UISegmentedControl.noSegment else { return }
        let width = bounds.width / CGFloat(numberOfSegments)
        let index = min(numberOfSegments - 1, max(0, Int(recognizer.location(in: self).x / width)))
        if index == selectionAtTouchDown, index == selectedSegmentIndex { onReselect?() }
    }
}
#endif
