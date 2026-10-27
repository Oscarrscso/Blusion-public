#if canImport(UIKit)
import SwiftUI

/// The label of a filter menu: a Liquid Glass capsule with a chevron, tinted when a filter in it is active. Used by the Library and
/// Discover, so their filter rows look the same.
struct FilterMenuLabel: View {
    let title: String
    let systemImage: String?
    let tint: Color
    let isActive: Bool
    let minHeight: CGFloat

    init(_ title: String, systemImage: String? = nil, tint: Color = .primary, isActive: Bool = false, minHeight: CGFloat = 44) {
        self.title = title
        self.systemImage = systemImage
        self.tint = tint
        self.isActive = isActive
        self.minHeight = minHeight
    }

    var body: some View {
        HStack(spacing: 5) {
            if let systemImage { Image(systemName: systemImage).font(.caption) }
            Text(title).lineLimit(1).minimumScaleFactor(0.8)
            Spacer(minLength: 0)
            Image(systemName: "chevron.down").font(.caption2.weight(.semibold))
        }
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(tint)
        .padding(.horizontal, Theme.Spacing.m)
        .frame(maxWidth: .infinity, minHeight: minHeight)
        .glassEffect(.regular.tint(tint.opacity(isActive ? 0.25 : 0.08)).interactive(), in: .capsule)
        .accessibilityAddTraits(isActive ? .isSelected : [])
        .pointerFeedback()
    }
}

/// One active filter shown as a removable chip. Tapping it calls `remove`.
struct ActiveFilterChip: Identifiable {
    let id: String
    let label: String
    let remove: () -> Void
}

/// The active filters as removable chips, wrapped left-aligned, with a "Clear all" chip after the last one. Each chip's identifier is
/// `<identifier>.chip.<id>`, and the clear chip's is `<identifier>.chip.clear`.
struct ActiveFilterChips: View {
    let chips: [ActiveFilterChip]
    let identifier: String
    let clearAll: () -> Void

    var body: some View {
        FlowLayout(spacing: Theme.Spacing.s) {
            ForEach(chips) { chip in
                GlassChip(chip.label, systemImage: "xmark", isCompact: true, action: chip.remove)
                    .accessibilityIdentifier("\(identifier).chip.\(chip.id)")
            }
            GlassChip("Clear all", systemImage: "xmark.circle", isCompact: true, action: clearAll)
                .accessibilityIdentifier("\(identifier).chip.clear")
        }
    }
}

/// The filter block the Library and Discover share, so the two pages look the same and differ only in their options: the type selector,
/// one row of menus that show their active choice, then a removable chip for each active filter. The menus sit midway between the
/// selector and the grid; chips under them keep their own padding, and go with the last chip so clearing every filter leaves no gap.
struct BrowseFilterBar<Menus: View>: View {
    /// The type selector. Nil hides it (a source with one type has nothing to choose).
    let kinds: Kinds?
    let chips: [ActiveFilterChip]
    /// Names the chips: each is "<identifier>.chip.<id>".
    let identifier: String
    let clearAll: () -> Void
    @ViewBuilder let menus: Menus
    @Environment(\.layoutMetrics) private var metrics

    /// The type selector's titles (the first is "All"), the index it shows, and its identifier.
    struct Kinds {
        let titles: [String]
        let selection: Binding<Int>
        let identifier: String
    }

    /// The height of a menu's label in the bar.
    static var menuHeight: CGFloat { 34 }

    var body: some View {
        let gap = (Theme.Spacing.s + metrics.shelfSpacing) / 2
        VStack(alignment: .leading, spacing: gap) {
            if let kinds {
                QualitySelector(titles: kinds.titles, selection: kinds.selection, symbols: ["square.grid.2x2", "film", "tv"],
                                accessibilityID: kinds.identifier)
                    .padding(.horizontal, metrics.pageMargin)
            }
            VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                GlassEffectContainer(spacing: Theme.Spacing.s) {
                    HStack(spacing: Theme.Spacing.s) {
                        menus
                    }
                    // Match the floating landscape Back button's row so the shorter menu capsules share its vertical centreline.
                    .frame(minHeight: 44, alignment: .center)
                }
                if !chips.isEmpty {
                    ActiveFilterChips(chips: chips, identifier: identifier, clearAll: clearAll)
                        .padding(.top, Theme.Spacing.xs)
                        .padding(.bottom, Theme.Spacing.xl)
                }
            }
            .padding(.horizontal, metrics.pageMargin)
        }
        .padding(.bottom, chips.isEmpty ? gap : 0)
        .buttonStyle(.plain)
    }
}
#endif
