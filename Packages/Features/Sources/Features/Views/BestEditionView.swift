#if canImport(UIKit)
import StremioKit
import SwiftUI

/// Best Blurays' recommendation, shown beside the stream results after Play. Folded into one row, with the release named on it, so
/// it reads as a single line until someone opens it.
struct BestEditionView: View {
    let model: StreamPickerViewModel
    /// The Auto Pick button's height beside it, so the header row is as tall as that button. Zero until the button is measured.
    var rowHeight: CGFloat = 0
    @State private var isExpanded = false
    /// The corner radius in both states, so the row keeps its shape when it opens: half the Auto Pick button's height, so the folded row is a
    /// capsule at any text size, as that button is. Until the button is measured, the surface radius.
    private var panelRadius: CGFloat { rowHeight > 0 ? rowHeight / 2 : Theme.Radius.surface }
    @Environment(\.openURL) private var openURL
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if model.canFindBestEdition {
            VStack(alignment: .leading, spacing: 0) {
                Button {
                    toggle()
                } label: {
                    HStack(spacing: Theme.Spacing.s) {
                        Image(systemName: "opticaldisc")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Text("Best Blu-ray")
                            .font(.subheadline.weight(.semibold))
                        Text(summary)
                            .font(.caption)
                            .foregroundStyle(summaryColor)
                            .lineLimit(1)
                        #if targetEnvironment(macCatalyst)
                        // Folded on a Mac, the row is as wide as its text; open, it runs the column's width.
                        if isExpanded { Spacer(minLength: Theme.Spacing.s) }
                        #else
                        Spacer(minLength: Theme.Spacing.s)
                        #endif
                    }
                    .padding(.horizontal, Theme.Spacing.m)
                    .padding(.vertical, Theme.Spacing.s + 2)
                    // The header is as tall as the Auto Pick button beside it, its text centred in it.
                    .frame(height: rowHeight > 0 ? rowHeight : nil)
                    // Folded, the whole row is the capsule, so its tap area is too. Open, the header is the card's top edge, and its
                    // tap area stays square, as it was.
                    .contentShape(isExpanded
                                  ? AnyShape(Rectangle())
                                  : AnyShape(RoundedRectangle(cornerRadius: panelRadius, style: .continuous)))
                }
                .buttonStyle(.plain)
                .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
                .accessibilityIdentifier("streams.bestEdition")
                if isExpanded {
                    content
                        .padding(.horizontal, Theme.Spacing.m)
                        .padding(.bottom, Theme.Spacing.m)
                        .padding(.top, Theme.Spacing.xs)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        // Anywhere on the open panel folds it, except a link: a link is a button of its own, so it takes its own tap.
                        .contentShape(Rectangle())
                        .onTapGesture { toggle() }
                        .transition(.opacity)
                }
            }
            .glassCardSurface(cornerRadius: panelRadius)
            #if targetEnvironment(macCatalyst)
            // Folded, the row hugs its text and still cuts a long release name short at the column's edge.
            .frame(maxWidth: .infinity, alignment: .leading)
            #endif
        }
    }

    /// Opens or folds the panel, with the same motion either way.
    private func toggle() {
        withAnimation(reduceMotion ? nil : .snappy(duration: 0.28)) { isExpanded.toggle() }
    }

    /// The one line the row shows while it is folded: the release it names, or where the lookup stands.
    private var summary: String {
        switch model.bestEdition {
        case .idle, .loading: "Checking…"
        case .found(let edition): edition.release
        case .listedWithoutEdition: "No best release named yet"
        case .notListed: "No page yet"
        case .failed: "Couldn’t load · tap to retry"
        }
    }

    private var summaryColor: Color {
        if case .failed = model.bestEdition { return .orange }
        return .secondary
    }

    @ViewBuilder
    private var content: some View {
        switch model.bestEdition {
        case .idle, .loading:
            HStack(spacing: Theme.Spacing.m) {
                Spinner()
                Text("Checking Best Blurays for \(model.request.title)…")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("bestEdition.loading")
        case .found(let edition):
            found(edition)
        case .listedWithoutEdition(let title, let url):
            message("Best Blurays lists \(title), but has not named a best release for it yet.", link: url, linkTitle: "Open the page")
        case .notListed(let searchURL):
            message("Best Blurays has no page for \(model.request.title) yet.", link: searchURL, linkTitle: "Search Best Blurays")
        case .failed(let text):
            InlineErrorView(text) { Task { await model.findBestEdition() } }
                .accessibilityIdentifier("bestEdition.failed")
        }
    }

    private func found(_ edition: BestBlurayEdition) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            Text(edition.heading)
                .font(Theme.Typography.eyebrow)
                .textCase(.uppercase)
                .foregroundStyle(.secondary)
            Text(edition.release)
                .font(.subheadline.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("bestEdition.release")
            HStack(spacing: Theme.Spacing.s) {
                if edition.is4K { Badge("4K", style: .quality) }
                if let tier = edition.uhdTier { Badge("\(tier) 4K tier") }
                if let updated = edition.updated {
                    Text(updated).font(.caption).foregroundStyle(.secondary)
                }
            }
            if let notes = edition.videoNotes {
                labelled("Video notes", notes)
            }
            if let upcoming = edition.upcoming {
                labelled("Coming", upcoming)
            }
            Button { openURL(edition.pageURL) } label: {
                Label("Open on Best Blurays", systemImage: "arrow.up.right.square")
            }
            .buttonStyle(.glassCapsule)
            .padding(.top, Theme.Spacing.xs)
            .accessibilityIdentifier("bestEdition.open")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func labelled(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            Text(title).font(.subheadline.weight(.semibold))
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(12)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func message(_ text: String, link: URL, linkTitle: String) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button { openURL(link) } label: {
                Label(linkTitle, systemImage: "arrow.up.right.square")
            }
            .buttonStyle(.glassCapsule)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("bestEdition.message")
    }
}
#endif
