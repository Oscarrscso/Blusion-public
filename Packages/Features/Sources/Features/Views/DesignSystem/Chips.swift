#if canImport(UIKit)
import SwiftUI

/// A filter chip: the system's Liquid Glass button as a capsule, and the selected one its prominent form in white with dark text
/// (the same inversion as the TV app's category filters). Semibold in both states, so selecting never shifts the neighbours.
struct GlassChip: View {
    let title: String
    let systemImage: String?
    let isSelected: Bool
    let fillsWidth: Bool
    /// The small size, for a row of removable filters that sits above a list.
    let isCompact: Bool
    /// False keeps a full-width chip at the regular height instead of the large one, for a row that shares the screen with other controls.
    let isTall: Bool
    let action: () -> Void

    init(_ title: String, systemImage: String? = nil, isSelected: Bool = false, fillsWidth: Bool = false, isCompact: Bool = false,
         isTall: Bool = true, action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.isSelected = isSelected
        self.fillsWidth = fillsWidth
        self.isCompact = isCompact
        self.isTall = isTall
        self.action = action
    }

    var body: some View {
        Group {
            if isSelected {
                button.buttonStyle(.glassProminent).tint(.white)
            } else {
                button.buttonStyle(.glass)
            }
        }
        .buttonBorderShape(.capsule)
        .controlSize(isCompact ? .small : fillsWidth && isTall ? .large : .regular)
        .pointerFeedback()
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("chip.\(title)")
        .sensoryFeedback(.selection, trigger: isSelected)
    }

    private var button: some View {
        Button(action: action) {
            label
                .font(.subheadline.weight(.semibold))
                .lineLimit(fillsWidth ? 1 : nil)
                .minimumScaleFactor(0.8)
                .foregroundStyle(isSelected ? Color.black : Color.primary)
                .frame(maxWidth: fillsWidth ? .infinity : nil)
        }
    }

    @ViewBuilder
    private var label: some View {
        if let systemImage {
            Label(title, systemImage: systemImage)
        } else {
            Text(title)
        }
    }
}

/// A horizontal scroller of chips. The chips share one `GlassEffectContainer`, so neighbouring glass shapes blend together.
struct ChipRow<Content: View>: View {
    let content: () -> Content
    let fittingColumns: Int?
    @Environment(\.layoutMetrics) private var metrics

    init(fittingColumns: Int? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.content = content
        self.fittingColumns = fittingColumns
    }

    @ViewBuilder var body: some View {
        if let fittingColumns {
            GlassEffectContainer(spacing: Theme.Spacing.s) {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Theme.Spacing.s), count: max(1, fittingColumns)),
                          spacing: Theme.Spacing.s) { content() }
            }
            .padding(.horizontal, metrics.pageMargin)
        } else {
        ScrollView(.horizontal) {
            GlassEffectContainer(spacing: Theme.Spacing.s) {
                HStack(spacing: Theme.Spacing.s) {
                    content()
                }
            }
        }
        .shelfIndicators()
        .contentMargins(.horizontal, metrics.pageMargin, for: .scrollContent)
        .scrollClipDisabled()
        }
    }
}

/// A small non-interactive label such as "4K", "HDR", "Dolby Vision" or "Watched". `.quality` is the TV app's capability glyph:
/// grey text in a thin outline.
struct Badge: View {
    enum Style {
        case neutral, accent, quality, warning
    }

    let text: String
    let systemImage: String?
    let style: Style

    init(_ text: String, systemImage: String? = nil, style: Style = .neutral) {
        self.text = text
        self.systemImage = systemImage
        self.style = style
    }

    var body: some View {
        label
            .font(style == .quality ? .system(size: 10, weight: .bold) : .caption2.weight(.bold))
            .foregroundStyle(foreground)
            .padding(.horizontal, style == .quality ? 6 : 7)
            .padding(.vertical, style == .quality ? 2 : 3)
            .background { surface }
            .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var label: some View {
        if let systemImage {
            Label(text, systemImage: systemImage)
        } else {
            Text(text)
        }
    }

    private var foreground: Color {
        switch style {
        case .neutral: .primary
        case .quality: .white.opacity(0.62)
        case .accent: .white
        case .warning: .orange
        }
    }

    /// A warning differs from a neutral badge only in its text colour: no coloured block, in keeping with the design bar.
    @ViewBuilder
    private var surface: some View {
        switch style {
        case .neutral, .warning: Capsule().fill(Color.white.opacity(0.14))
        case .accent: Capsule().fill(Theme.brandGradient)
        case .quality: RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(Color.white.opacity(0.38), lineWidth: 1)
        }
    }
}

/// A row of capability badges ("4K", "Dolby Vision", "HDR") under a title's name. Draws nothing for an empty list.
struct CapabilityBadges: View {
    let names: [String]

    init(_ names: [String]) {
        self.names = names
    }

    var body: some View {
        if !names.isEmpty {
            HStack(spacing: Theme.Spacing.s - 2) {
                ForEach(names, id: \.self) { Badge($0, style: .quality) }
            }
        }
    }
}

/// "★ 84" in quiet semibold white, for a place where one number is enough. Has no backdrop of its own: it assumes dark artwork
/// or a fade behind it. Posters carry `PosterRatingsOverlay` instead (IMDb and Letterboxd).
struct RatingBadge: View {
    let rating: Double

    init(_ rating: Double) {
        self.rating = rating
    }

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "star.fill")
                .font(.system(size: 9, weight: .bold))
            Text(ScoreText.wholeScore(rating))
        }
        .font(.caption.weight(.semibold))
        .monospacedDigit()
        .foregroundStyle(.white)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Rating \(ScoreText.wholeScore(rating))")
    }
}

/// Dot-separated metadata such as "Drama · 2008 · 2 hr 32 min". Nil and empty parts are skipped, and it renders nothing when every
/// part is skipped. It stays on one line: when the parts are too long for the width, genres go first, the last one first, so the rest
/// (the rating above all) stays. Only when no genre is left does the line shrink to fit.
struct MetaLine: View {
    /// The space kept on each side of a dot when the parts are spread, so a dot never touches the text beside it.
    private static let minimumGap: CGFloat = 4
    /// The fewest parts that are spread across the width. Fewer would leave wide gaps between them, so they are joined as usual.
    private static let minimumSpreadParts = 5
    /// The most genres the line drops. A hero's line has two (see `DetailViewModel.heroMetaGenres`), so three variants cover it.
    private static let maximumDroppedGenres = 2
    /// The smallest scale the line shrinks to once no genre is left to drop, so it still fits a narrow width on one line.
    private static let minimumShrink: CGFloat = 0.5

    private let parts: [String]
    /// The genres among the parts, in order. They are the parts the line drops when it is too long.
    private let genres: [String]
    /// The accessibility identifier of the line, for UI tests. Nil leaves it unset.
    private let identifier: String?
    /// True spreads the parts across the whole width the line is given, with the dots between them, so the line is as wide as what sits
    /// under it. When the parts do not fit on one line that way, the line is joined as usual.
    private let spreads: Bool

    init(_ parts: [String?], genres: [String] = [], identifier: String? = nil, spreads: Bool = false) {
        self.parts = Self.cleaned(parts)
        self.genres = Self.cleaned(genres)
        self.identifier = identifier
        self.spreads = spreads
    }

    private static func cleaned(_ texts: [String?]) -> [String] {
        texts
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    var body: some View {
        if !parts.isEmpty {
            let line = partsLine
                .font(Theme.Typography.metaLine)
                .foregroundStyle(Theme.metaText)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(parts.joined(separator: ", "))
            if let identifier {
                line.accessibilityIdentifier(identifier)
            } else {
                line
            }
        }
    }

    /// The line as drawn: the first variant that fits the width it is given. The variants keep every genre, then drop one more each time,
    /// the last genre first. The last one has no genre left to drop, so it shrinks to fit rather than wrapping.
    @ViewBuilder
    private var partsLine: some View {
        let droppable = min(genres.count, Self.maximumDroppedGenres)
        // Always three children, so no slot depends on a missing child: with fewer genres, a slot repeats the variant before it.
        ViewThatFits(in: .horizontal) {
            variant(dropping: 0, shrinks: false)
            variant(dropping: min(1, droppable), shrinks: false)
            variant(dropping: droppable, shrinks: true)
        }
    }

    /// One variant: the parts with the last `count` genres left out, spread across the width when `spreads` is set and there are enough of
    /// them, otherwise joined by dots. A shrinking variant is always joined, as a spread line cannot shrink.
    @ViewBuilder
    private func variant(dropping count: Int, shrinks: Bool) -> some View {
        let shown = partsDropping(count)
        if spreads && !shrinks && shown.count >= Self.minimumSpreadParts {
            spread(shown)
        } else {
            joined(shown, shrinks: shrinks)
        }
    }

    /// The parts without the last `count` genres. Each genre goes by its last occurrence, so a repeated name leaves one copy at a time,
    /// and the line never drops its last part, so it is never left empty.
    private func partsDropping(_ count: Int) -> [String] {
        var shown = parts
        for genre in genres.suffix(count) where shown.count > 1 {
            if let index = shown.lastIndex(of: genre) {
                shown.remove(at: index)
            }
        }
        return shown
    }

    /// The parts spread across the width, with the dots between them.
    private func spread(_ shown: [String]) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(shown.enumerated()), id: \.offset) { index, part in
                if index > 0 {
                    Spacer(minLength: Self.minimumGap)
                    Text("·")
                    Spacer(minLength: Self.minimumGap)
                }
                Text(part)
                    .lineLimit(1)
                    .fixedSize()
            }
        }
        .frame(maxWidth: .infinity)
    }

    /// The parts joined by dots on one line. Measured at full width, so a variant too wide for the space is passed over. A shrinking one
    /// is drawn smaller to fit instead.
    private func joined(_ shown: [String], shrinks: Bool) -> some View {
        Text(shown.joined(separator: " · "))
            .lineLimit(1)
            .minimumScaleFactor(shrinks ? Self.minimumShrink : 1)
    }
}
#endif
