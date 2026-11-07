#if canImport(UIKit)
import StremioKit
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
    /// Appearance's corners for the player's controls, which the control's track takes as the glass around it does.
    var cornerScale: CGFloat = 1

    /// Wide enough for the speed segment's "1.25×".
    static let segmentWidth: CGFloat = 52

    func makeCoordinator() -> Coordinator { Coordinator(selection: $selection) }

    func makeUIView(context: Context) -> PlayerMenuBarView {
        let view = PlayerMenuBarView(frame: .zero)
        let control = view.control
        control.apportionsSegmentWidthsByContent = false
        control.backgroundColor = .clear
        control.addTarget(context.coordinator, action: #selector(Coordinator.changed(_:)), for: .valueChanged)
        control.accessibilityIdentifier = "player.menuBar"
        return view
    }

    func updateUIView(_ view: PlayerMenuBarView, context: Context) {
        let control = view.control
        view.cornerScale = cornerScale
        context.coordinator.selection = $selection
        control.configure(tabs: tabs, speedLabel: speedLabel, subtitlesOn: subtitlesOn)
        let index = selection.flatMap { tabs.firstIndex(of: $0) } ?? UISegmentedControl.noSegment
        // Assigning the same index during tracking can interrupt UIKit's slide.
        if control.selectedSegmentIndex != index { control.selectedSegmentIndex = index }
        control.onReselect = { [selection = $selection] in
            // Re-tapping the tab already showing closes the panel, which is a change of screen rather than a tab change.
            Haptics.play(.playerControls)
            selection.wrappedValue = nil
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: PlayerMenuBarView, context: Context) -> CGSize? {
        CGSize(width: CGFloat(tabs.count) * Self.segmentWidth, height: max(36, uiView.control.intrinsicContentSize.height))
    }

    @MainActor
    final class Coordinator: NSObject {
        var selection: Binding<PlayerPanelTab?>

        init(selection: Binding<PlayerPanelTab?>) { self.selection = selection }

        @objc func changed(_ control: PlayerMenuSegmentedControl) {
            guard control.tabs.indices.contains(control.selectedSegmentIndex) else { return }
            let tab = control.tabs[control.selectedSegmentIndex]
            guard selection.wrappedValue != tab else { return }
            Haptics.play(.playerOptions)
            selection.wrappedValue = tab
        }
    }
}

/// The bar's view, so the control's track takes Appearance's corners. UIKit draws the track as a capsule whatever its size, so for any
/// corners short of round the control is laid out half its height wider at each end, past the bar's edges, and trimmed there: the track
/// left showing has straight ends, rounded by the trim to the corners asked for. Its end segments are wider by that much, with their
/// symbols moved back, so every symbol keeps its place. Square corners leave room above and below for the slider to swell as a finger
/// drags it; rounded ones trim it at the track. Round corners leave the control as UIKit draws it.
final class PlayerMenuBarView: UIView {
    let control = PlayerMenuSegmentedControl(frame: .zero)
    var cornerScale: CGFloat = 1 {
        didSet { if cornerScale != oldValue { setNeedsLayout() } }
    }
    /// Trims the control to the bar's corners.
    private let trim = UIView()
    /// The room left above and below a square bar for the slider's swell.
    private static let swell: CGFloat = 8

    override init(frame: CGRect) {
        super.init(frame: frame)
        // The curve of SwiftUI's rounded shapes, so the trim matches the glass around the bar.
        trim.layer.cornerCurve = .continuous
        trim.addSubview(control)
        addSubview(trim)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layoutSubviews() {
        super.layoutSubviews()
        let isRound = cornerScale >= 1
        let isSquare = cornerScale <= 0.001
        let overhang = isRound ? 0 : bounds.height / 2
        let room = isRound || isSquare ? Self.swell : 0
        trim.frame = bounds.insetBy(dx: 0, dy: -room)
        trim.clipsToBounds = !isRound
        trim.layer.cornerRadius = isRound || isSquare ? 0 : bounds.height / 2 * cornerScale
        control.frame = CGRect(x: -overhang, y: room, width: bounds.width + overhang * 2, height: bounds.height)
        control.overhang = overhang
    }
}

/// The menu bar's control: symbols with spoken titles, the speed rate as text, and a tap on the selected segment reported.
final class PlayerMenuSegmentedControl: UISegmentedControl, UIGestureRecognizerDelegate {
    private(set) var tabs: [PlayerPanelTab] = []
    /// How far the control runs past each end of the bar (see `PlayerMenuBarView`): the end segments are that much wider.
    var overhang: CGFloat = 0 {
        didSet { if overhang != oldValue { applyOverhang() } }
    }
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
            applyOverhang()
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

    /// Widens the end segments by `overhang`, moving their content back by half that, so each symbol stays over its part of the bar.
    /// Without an overhang every segment takes an equal share again.
    private func applyOverhang() {
        let count = numberOfSegments
        for index in 0..<count {
            let leading: CGFloat = index == 0 ? overhang : 0
            let trailing: CGFloat = index == count - 1 ? overhang : 0
            setWidth(overhang > 0 ? PlayerMenuBar.segmentWidth + leading + trailing : 0, forSegmentAt: index)
            setContentOffset(CGSize(width: (leading - trailing) / 2, height: 0), forSegmentAt: index)
        }
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
        // The segments' own widths, since the end ones are wider when the bar is trimmed; an equal share where none is set.
        let x = recognizer.location(in: self).x
        var edge: CGFloat = 0
        var index = numberOfSegments - 1
        for segment in 0..<numberOfSegments {
            let width = widthForSegment(at: segment)
            edge += width > 0 ? width : bounds.width / CGFloat(numberOfSegments)
            if x < edge {
                index = segment
                break
            }
        }
        if index == selectionAtTouchDown, index == selectedSegmentIndex { onReselect?() }
    }
}
#endif
