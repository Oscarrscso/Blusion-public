#if canImport(UIKit)
import SwiftUI

/// The faint line between a title page's sections, inset by the page's margin.
struct TitleSectionLine: View {
    let contentMargin: CGFloat

    var body: some View {
        Rectangle()
            .fill(Theme.sectionLine)
            .frame(height: 1)
            .padding(.horizontal, contentMargin)
            .accessibilityHidden(true)
    }
}

/// A title page's sections, one under another, with a faint line between each two. The line sits `titleRatingsGap` from the section on
/// each side, as the one under the ratings does. Only the sections that show count, so a hidden one leaves no line behind.
struct TitleSections<Content: View>: View {
    let contentMargin: CGFloat
    @ViewBuilder let content: Content
    @Environment(\.layoutMetrics) private var metrics

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Group(subviews: content) { sections in
                ForEach(sections) { section in
                    if section.id != sections.first?.id {
                        TitleSectionLine(contentMargin: contentMargin)
                            .padding(.vertical, metrics.titleRatingsGap)
                    }
                    section
                }
            }
        }
    }
}
#endif
