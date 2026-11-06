#if canImport(UIKit)
import SwiftUI

/// The label of a filter menu: a Liquid Glass capsule with a chevron, tinted when a filter in it is active. Used by the Library and
/// Discover, so their filter rows look the same.
struct FilterMenuLabel: View {
    @Environment(\.layoutMetrics) private var metrics
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
        let shape = RoundedRectangle(cornerRadius: minHeight / 2 * metrics.cornerScale(for: .filters), style: .continuous)
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
        .contentShape(shape)
        .contentShape(.contextMenuPreview, shape)
        .buttonSurface(.regular.tint(tint.opacity(isActive ? 0.25 : 0.08)).interactive(), in: shape)
        .clipShape(shape)
        .glassHover(shape)
        .accessibilityAddTraits(isActive ? .isSelected : [])
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
    @Environment(\.layoutMetrics) private var metrics

    var body: some View {
        FlowLayout(spacing: metrics.controlSpacing) {
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
/// menus that fill one row on Mac and wrap on iPhone, then a removable chip for each active filter. The menus sit midway between the
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

    /// The type selector's titles (the first is "All"), the index it shows, and its identifier. `symbols` go with the titles in order.
    struct Kinds {
        let titles: [String]
        let selection: Binding<Int>
        let identifier: String
        var symbols: [String] = ["square.grid.2x2", "film", "tv"]
    }

    /// The height of a menu's label in the bar.
    static var menuHeight: CGFloat { 34 }

    var body: some View {
        VStack(alignment: .leading, spacing: metrics.controlSpacing) {
            if let kinds {
                QualitySelector(titles: kinds.titles, selection: kinds.selection, symbols: kinds.symbols,
                                accessibilityID: kinds.identifier)
                    .navigationAlignedWidth(margin: metrics.pageMargin)
            }
            VStack(alignment: .leading, spacing: metrics.controlSpacing) {
                GlassEffectContainer(spacing: metrics.cardSpacing) {
                    Group {
                        #if targetEnvironment(macCatalyst)
                        HStack(spacing: metrics.cardSpacing) {
                            menus
                        }
                        .frame(maxWidth: .infinity)
                        #else
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: metrics.controlSpacing)],
                                  alignment: .leading, spacing: metrics.controlSpacing) {
                            menus
                        }
                        #endif
                    }
                    // Match the floating landscape Back button's row so the shorter menu capsules share its vertical centreline.
                    .frame(minHeight: 44, alignment: .center)
                }
                if !chips.isEmpty {
                    ActiveFilterChips(chips: chips, identifier: identifier, clearAll: clearAll)
                }
            }
            .padding(.horizontal, metrics.pageMargin)
        }
        .padding(.bottom, metrics.controlSpacing)
        .buttonStyle(.hoverPlain)
        .buttonBorderShape(.roundedRectangle(radius: Self.menuHeight / 2 * metrics.cornerScale(for: .filters)))
    }
}

/// The minimum rating, shown out of 100. Each title is rated by its best available score, so the menu names no site.
struct RatingPicker: View {
    @Binding var threshold: Double?

    var body: some View {
        Picker("At least", selection: $threshold) {
            Text("Any").tag(Double?.none)
            ForEach([5.0, 6, 7, 8, 9, 10], id: \.self) { value in
                Text(LibraryFiltering.minimumRatingText(value)).tag(Double?.some(value))
            }
        }
        .accessibilityIdentifier("library.filter.rating.threshold")
    }
}

/// Shared release windows, individual years and decades. One Any choice clears both bounds.
struct ReleaseYearOptions: View {
    @Binding var minimumYear: Int?
    @Binding var maximumYear: Int?
    let identifier: String

    var body: some View {
        Button {
            minimumYear = nil
            maximumYear = nil
        } label: {
            choice("Any", isOn: minimumYear == nil && maximumYear == nil)
        }
        Section {
            ForEach(CatalogListRecent.allCases) { recent in
                let range = recent.years()
                Button {
                    minimumYear = range.lowerBound
                    maximumYear = range.upperBound
                } label: {
                    choice(recent.title, isOn: minimumYear == range.lowerBound && maximumYear == range.upperBound)
                }
                .accessibilityIdentifier("\(identifier).recent.\(recent.rawValue)")
            }
        }
        Menu("Individual Year") {
            ForEach(Array(stride(from: Calendar.current.component(.year, from: Date()), through: 1920, by: -1)), id: \.self) { year in
                Button {
                    minimumYear = year
                    maximumYear = year
                } label: {
                    choice(String(year), isOn: minimumYear == year && maximumYear == year)
                }
            }
        }
        Section("Decades") {
            ForEach(Array(stride(from: 2020, through: 1920, by: -10)), id: \.self) { start in
                Button {
                    minimumYear = start
                    maximumYear = start + 9
                } label: {
                    choice("\(start)–\(start + 9)", isOn: minimumYear == start && maximumYear == start + 9)
                }
                .accessibilityIdentifier("\(identifier).\(start)")
            }
        }
    }

    @ViewBuilder private func choice(_ title: String, isOn: Bool) -> some View {
        if isOn { Label(title, systemImage: "checkmark") } else { Text(title) }
    }
}
#endif
