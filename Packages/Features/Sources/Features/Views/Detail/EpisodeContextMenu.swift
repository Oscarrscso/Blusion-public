#if canImport(UIKit)
import SwiftUI
import UIKit

/// UIKit owns the hold, menu and dismissal. Its preview controller requests the full landscape size;
/// the preview's SwiftUI layout still follows the bounds UIKit actually gives it.
struct EpisodeContextMenu<Content: View, Preview: View>: UIViewControllerRepresentable {
    let content: Content
    let preview: Preview
    let previewSize: CGSize
    let menu: () -> UIMenu
    @Binding var isPresented: Bool
    @Environment(\.self) private var environment

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIViewController(context: Context) -> UIHostingController<AnyView> {
        let controller = UIHostingController(rootView: AnyView(content.environment(\.self, environment)))
        controller.safeAreaRegions = []
        controller.view.backgroundColor = .clear
        controller.view.addInteraction(UIContextMenuInteraction(delegate: context.coordinator))
        return controller
    }

    func updateUIViewController(_ controller: UIHostingController<AnyView>, context: Context) {
        context.coordinator.owner = self
        controller.rootView = AnyView(content.environment(\.self, environment))
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiViewController: UIHostingController<AnyView>, context: Context) -> CGSize? {
        uiViewController.sizeThatFits(in: proposal.replacingUnspecifiedDimensions(by: UIView.layoutFittingExpandedSize))
    }

    @MainActor
    final class Coordinator: NSObject, UIContextMenuInteractionDelegate {
        var owner: EpisodeContextMenu

        init(_ owner: EpisodeContextMenu) { self.owner = owner }

        func contextMenuInteraction(_ interaction: UIContextMenuInteraction,
                                    configurationForMenuAtLocation location: CGPoint) -> UIContextMenuConfiguration? {
            let owner = owner
            let controller = UIHostingController(rootView: owner.preview.environment(\.self, owner.environment))
            controller.safeAreaRegions = []
            controller.preferredContentSize = owner.previewSize
            controller.view.backgroundColor = .secondarySystemBackground
            controller.view.frame = CGRect(origin: .zero, size: owner.previewSize)
            let configuration = UIContextMenuConfiguration(identifier: nil, previewProvider: { controller }) { _ in owner.menu() }
            configuration.preferredMenuElementOrder = .fixed
            return configuration
        }

        func contextMenuInteraction(_ interaction: UIContextMenuInteraction,
                                    willDisplayMenuFor configuration: UIContextMenuConfiguration,
                                    animator: (any UIContextMenuInteractionAnimating)?) {
            owner.isPresented = true
        }

        func contextMenuInteraction(_ interaction: UIContextMenuInteraction,
                                    willEndFor configuration: UIContextMenuConfiguration,
                                    animator: (any UIContextMenuInteractionAnimating)?) {
            let presented = owner.$isPresented
            if let animator {
                animator.addCompletion { presented.wrappedValue = false }
            } else {
                presented.wrappedValue = false
            }
        }
    }
}
#endif
