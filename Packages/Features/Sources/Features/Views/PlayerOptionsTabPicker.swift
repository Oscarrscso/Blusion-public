#if canImport(UIKit)
import SwiftUI
import UIKit

/// UIKit owns the indicator, material, tracking and selection animation. SwiftUI only
/// mirrors the value; it never replaces segments or draws a selected background.
struct PlayerOptionsTabPicker: UIViewRepresentable {
    @Binding var selection: PlayerPanelTab?

    func makeCoordinator() -> Coordinator { Coordinator(selection: $selection) }

    func makeUIView(context: Context) -> PlayerTabSegmentedControl {
        let control = PlayerTabSegmentedControl(tabs: PlayerPanelTab.allCases)
        control.selectedSegmentIndex = PlayerPanelTab.allCases.firstIndex(of: selection ?? .subtitles) ?? 0
        control.addTarget(context.coordinator, action: #selector(Coordinator.changed(_:)), for: .valueChanged)
        control.accessibilityIdentifier = "player.panel.tabs"
        return control
    }

    func updateUIView(_ control: PlayerTabSegmentedControl, context: Context) {
        context.coordinator.selection = $selection
        let index = PlayerPanelTab.allCases.firstIndex(of: selection ?? .subtitles) ?? 0
        // Assigning the same index during tracking can interrupt UIKit's slide.
        if control.selectedSegmentIndex != index { control.selectedSegmentIndex = index }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: PlayerTabSegmentedControl, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? uiView.intrinsicContentSize.width, height: max(44, uiView.intrinsicContentSize.height))
    }

    @MainActor
    final class Coordinator: NSObject {
        var selection: Binding<PlayerPanelTab?>

        init(selection: Binding<PlayerPanelTab?>) { self.selection = selection }

        @objc func changed(_ control: UISegmentedControl) {
            let tabs = PlayerPanelTab.allCases
            guard tabs.indices.contains(control.selectedSegmentIndex) else { return }
            let tab = tabs[control.selectedSegmentIndex]
            guard selection.wrappedValue != tab else { return }
            Haptics.selection()
            selection.wrappedValue = tab
        }
    }
}

/// Keep the same five system segments across rotations. Compact layouts use SF
/// Symbols with spoken titles; wider layouts use text at the system's font size.
final class PlayerTabSegmentedControl: UISegmentedControl {
    private let tabs: [PlayerPanelTab]
    private var usesSymbols: Bool?

    init(tabs: [PlayerPanelTab]) {
        self.tabs = tabs
        super.init(items: tabs.map(\.title))
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layoutSubviews() {
        let font = UIFont.preferredFont(forTextStyle: .subheadline)
        let textWidth = tabs.reduce(CGFloat.zero) { $0 + ($1.title as NSString).size(withAttributes: [.font: font]).width + 24 }
        let compact = bounds.width < textWidth || traitCollection.preferredContentSizeCategory.isAccessibilityCategory
        if compact != usesSymbols {
            usesSymbols = compact
            apportionsSegmentWidthsByContent = !compact
            for (index, tab) in tabs.enumerated() {
                let icon = UIImage(systemName: tab.symbol)
                icon?.accessibilityLabel = tab.title
                // Each UIKit setter clears the other content kind, so clear the
                // old kind first and assign the intended content last.
                if compact {
                    setTitle(nil, forSegmentAt: index)
                    setImage(icon, forSegmentAt: index)
                } else {
                    setImage(nil, forSegmentAt: index)
                    setTitle(tab.title, forSegmentAt: index)
                }
            }
        }
        super.layoutSubviews()
    }
}
#endif
