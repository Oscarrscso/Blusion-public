#if canImport(UIKit)
import SwiftUI
import UIKit

/// UIKit owns placement and dismissal; the stacked preview requests its measured content size.
struct EpisodeContextMenu<Content: View, Preview: View>: UIViewControllerRepresentable {
    let content: Content
    let preview: (CGFloat) -> Preview
    let previewSize: CGSize
    let previewCornerRadius: CGFloat
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
            // Leave room beside the card for the native palette and its separated action.
            let window = interaction.view?.window
            let viewport = window.map { $0.bounds.inset(by: $0.safeAreaInsets).size } ?? owner.previewSize
            // Reserve vertical placement margins as well as room beside the card for the actions.
            let maximumHeight = max(1, min(owner.previewSize.height, viewport.height) - 64)
            var width = max(1, min(owner.previewSize.width, viewport.width - 320))
            let controller = UIHostingController(rootView: AnyView(owner.preview(width).environment(\.self, owner.environment)))
            controller.safeAreaRegions = []
            var size = controller.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude))
            var shortestSize = CGSize(width: width, height: size.height)
            let minimumWidth = min(width, 260)
            // Measure the full title and synopsis, keeping the widest complete card that fits.
            // Wrapping can make a narrower card taller, so retain the shortest if none fits.
            while size.height > maximumHeight && width > minimumWidth {
                width = max(minimumWidth, width - 16)
                controller.rootView = AnyView(owner.preview(width).environment(\.self, owner.environment))
                size = controller.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude))
                if size.height < shortestSize.height { shortestSize = CGSize(width: width, height: size.height) }
            }
            if size.height > maximumHeight {
                width = shortestSize.width
                size = shortestSize
            }
            // Shrink the complete card before resorting to scrolling. Narrowing alone adds
            // wrapped lines and often cannot make even an ordinary synopsis fit.
            let scale = max(0.75, min(1, maximumHeight / max(1, size.height)))
            let cardSize = CGSize(width: width, height: size.height)
            let fittedSize = CGSize(width: width * scale, height: min(size.height * scale, maximumHeight))
            // Preserve the measured layout when UIKit adjusts the preview's bounds. Reflowing
            // at a smaller width after measurement can add lines and clip previously fitting text.
            controller.rootView = AnyView(GeometryReader { geometry in
                let widthScale = geometry.size.width / cardSize.width
                let fitScale = min(widthScale, geometry.size.height / max(1, cardSize.height))
                let contentScale = max(min(widthScale, 0.75), fitScale)
                ScrollView {
                    owner.preview(cardSize.width)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(width: cardSize.width, height: cardSize.height, alignment: .top)
                        .scaleEffect(contentScale, anchor: .top)
                        .frame(width: geometry.size.width, height: cardSize.height * contentScale, alignment: .top)
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
                .scrollBounceBehavior(.basedOnSize)
                .scrollIndicators(.visible)
            }
            .clipShape(RoundedRectangle(cornerRadius: owner.previewCornerRadius, style: .continuous))
            // The panel's outline stays on its visible bounds, outside the scrolling content.
            .glassHairline(RoundedRectangle(cornerRadius: owner.previewCornerRadius, style: .continuous))
            .environment(\.self, owner.environment))
            controller.preferredContentSize = fittedSize
            controller.view.backgroundColor = .secondarySystemBackground
            controller.view.frame = CGRect(origin: .zero, size: fittedSize)
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
            owner.isPresented = false
        }
    }
}
#endif
