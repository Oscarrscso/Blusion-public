#if canImport(UIKit)
import SwiftUI
import StremioKit
import UIKit

/// The synopsis, folded to `foldedLines` lines (three unless a page gives more) when it runs past them. A tap on the text opens it or folds it
/// again. Its state belongs to the page, so it survives a rotation.
struct DetailSynopsis: View {
    let description: String?
    @Binding var isExpanded: Bool
    @Binding var isTruncated: Bool
    /// How many lines the synopsis shows while folded.
    var foldedLines = 3
    var isLoading = false
    @Environment(\.pageReveal) private var reveal
    private static let revealID = "detail.synopsis"
    private static let textColour = UIColor(red: 214 / 255.0, green: 211 / 255.0, blue: 204 / 255.0, alpha: 1)

    var body: some View {
        content.detailLoadingTransition(isLoading)
    }

    @ViewBuilder
    private var content: some View {
        if let description = description, !description.isEmpty {
            // Folded when it runs past its folded lines; one that fits has nothing to fold, so a tap does nothing.
            let folds = isExpanded || isTruncated
            VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                JustifiedText(text: description, color: Self.textColour, lineLimit: isExpanded ? 0 : foldedLines,
                              reservesSpace: !isExpanded, isTruncated: $isTruncated)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    // A tap on the text folds or opens it.
                    .onTapGesture {
                        if folds { toggleDescription() }
                    }
                    .pointerFeedback(folds)
                    .accessibilityAddTraits(folds ? .isButton : [])
                    .accessibilityHint(folds ? (isExpanded ? "Collapses the synopsis" : "Expands the synopsis") : "")
            }
            .id(Self.revealID)
            .transition(.opacity)
        } else if isLoading {
            DetailSkeletonParagraph(lines: foldedLines)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Loading synopsis")
                .transition(.opacity)
        }
    }

    /// Opens or folds the synopsis, with the app's light tap, once for each tap. Opened, it comes into view, as a rating's reviews do.
    private func toggleDescription() {
        Haptics.play(.buttons)
        withAnimation(.easeInOut(duration: 0.25)) { isExpanded.toggle() }
        if isExpanded { reveal?.show(Self.revealID) }
    }
}
#endif
