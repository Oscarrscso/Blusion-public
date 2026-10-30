#if canImport(UIKit)
import SwiftUI
import StremioKit
import UIKit

/// The TMDb reviews shelf: a sort menu, then one card per review. A card opens to its whole text, and opening one widens it to the page.
struct DetailReviews: View {
    private enum ReviewSort: String, CaseIterable {
        case highestRated = "Highest rated"
        case lowestRated = "Lowest rated"
        case longest = "Longest review"
        case shortest = "Shortest review"
    }

    let reviews: [TMDbReview]
    var isLoading = false
    /// What the reviews praise and complain about, from their text, under the heading.
    var consensus: String?
    var isSummarizing = false
    var reviewedCount = 0
    var summaryError: String?
    /// Called only while visible; the view task cancels inference when hidden or removed.
    var onRequestSummary: (() async -> Void)?
    var playColourHex: String?
    let width: CGFloat
    let contentMargin: CGFloat
    @State private var reviewSort = ReviewSort.highestRated
    @State private var showsAISummary = false
    @State private var summaryRetry = 0
    /// The review whose card is open: full width, with its whole text. Opening and closing animate the text and the width together.
    @State private var expandedReviewID: String?
    /// The wait before the open card is centred, so a tap in the meantime can cancel it.
    @State private var centering: Task<Void, Never>?
    /// True while an opened card is moving into place, until it is centred. Only a swipe made after that folds the card.
    @State private var settling = false
    @Environment(\.layoutMetrics) private var metrics

    var body: some View {
        VStack(alignment: .leading, spacing: metrics.headerSpacing) {
            HStack(spacing: 0) {
                Text("TMDb Reviews")
                    .font(Theme.Typography.shelfTitle)
                    .accessibilityAddTraits(.isHeader)
                Menu {
                    // Toggles rather than a picker: a toggle draws the same tick, and it reports every choice, the current sort included.
                    ForEach(ReviewSort.allCases, id: \.self) { sort in
                        Toggle(sort.rawValue, isOn: Binding(get: { reviewSort == sort }, set: { _ in chooseSort(sort) }))
                    }
                } label: {
                    reviewHeadingControl("arrow.up.arrow.down")
                }
                .buttonStyle(.plain)
                .pointerFeedback()
                .padding(.leading, Theme.Spacing.s)
                .accessibilityLabel("Sort TMDb reviews")
                .accessibilityValue(reviewSort.rawValue)
                .accessibilityIdentifier("detail.reviews.sort")
                Button {
                    withAnimation(.snappy(duration: 0.25)) { showsAISummary.toggle() }
                } label: {
                    reviewHeadingControl("sparkles")
                }
                .buttonStyle(.plain)
                .pointerFeedback()
                .padding(.leading, Theme.Spacing.s)
                .accessibilityLabel(showsAISummary ? "Hide AI review summary" : "Show AI review summary")
                .accessibilityValue(showsAISummary ? "Expanded" : "Collapsed")
                .accessibilityIdentifier("detail.reviews.aiSummary")
            }
            .padding(.horizontal, contentMargin)
            .disabled(isLoading)
            if showsAISummary {
                aiSummaryPanel {
                    if isSummarizing {
                        summaryLoading
                    } else if let summaryError {
                        Button(action: { summaryRetry += 1 }) {
                            Label(summaryError, systemImage: "arrow.clockwise")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.leading)
                        }
                        .accessibilityIdentifier("detail.reviews.summaryFailure")
                    } else if let consensus {
                        summaryContent(consensus)
                            .accessibilityIdentifier("detail.reviews.consensus")
                    } else if ReviewConsensusReader.available() == nil {
                        Text("On-device AI summary is unavailable.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    } else {
                        // Covers the short interval before the background summarisation task starts.
                        summaryLoading
                    }
                }
                .padding(.horizontal, contentMargin)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
            ScrollViewReader { proxy in
                // Small shelves keep their expanding-card layout; large paginated sets build cards as they come into view.
                ShelfScroll(margin: contentMargin, spacing: metrics.cardSpacing, lazy: reviews.count > 20) {
                        if isLoading {
                            ForEach(0..<3, id: \.self) { index in
                                VStack(alignment: .leading, spacing: Theme.Spacing.m) {
                                    HStack {
                                        DetailSkeletonLine(font: .headline, width: metrics.episodeWidth * 0.38)
                                        Spacer(minLength: 8)
                                        DetailSkeletonLine(font: .caption.weight(.semibold), width: 65)
                                    }
                                    DetailSkeletonParagraph(style: .subheadline, lines: ReviewCard.foldedLines)
                                }
                                .padding(ReviewCard.padding)
                                .frame(width: metrics.episodeWidth)
                                .cardSurface()
                                .reportsShelfEdge(id: index)
                                .accessibilityElement(children: .ignore)
                                .accessibilityLabel("Loading review")
                            }
                        }
                        ForEach(sortedReviews) { review in
                            let foldedWidth = metrics.episodeWidth
                            let expandedWidth = max(0, width - contentMargin * 2)
                            ReviewCard(review: review, isExpanded: expandedReviewID == review.id,
                                       foldedWidth: foldedWidth, expandedWidth: expandedWidth) {
                                toggleReview(review.id)
                            }
                            .modifier(FoldingWidth(isExpanded: expandedReviewID == review.id, folded: foldedWidth, expanded: expandedWidth))
                            .id(review.id)
                            .reportsShelfEdge(id: review.id)
                            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(reviewsShelfSpace)) } action: { frame in
                                foldIfSwipedAway(review.id, frame)
                            }
                        }
                }
                .coordinateSpace(name: reviewsShelfSpace)
                // The open card is centred once its open has finished, so the row is at its final width when the scroll aims at it. Every
                // tap that opens or folds a card first cancels the centring still waiting, so only the latest open is centred.
                .onChange(of: expandedReviewID) { _, id in
                    centering?.cancel()
                    guard let id else {
                        settling = false
                        return
                    }
                    centering = Task { @MainActor in
                        try? await Task.sleep(for: .seconds(Self.foldDuration))
                        guard !Task.isCancelled else { return }
                        withAnimation(.snappy(duration: Self.foldDuration)) { proxy.scrollTo(id, anchor: .center) }
                        try? await Task.sleep(for: .seconds(Self.foldDuration))
                        guard !Task.isCancelled else { return }
                        settling = false
                    }
                }
            }
        }
        .detailLoadingTransition(isLoading)
        // No on-device generation for a hidden panel. SwiftUI cancels this task on collapse
        // or navigation rather than leaving an unstructured Task running.
        .task(id: "\(showsAISummary)|\(summaryRetry)") {
            guard showsAISummary, consensus == nil else { return }
            await onRequestSummary?()
        }
    }

    /// Both heading controls share a fixed-size glass circle and the Play button's poster colour.
    /// Keep the colour inside the label: attaching it to Menu itself can leave a detached circle
    /// during the system's menu presentation and dismissal animations.
    private func reviewHeadingControl(_ systemName: String) -> some View {
        Image(systemName: systemName)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.white)
            .frame(width: 24, height: 24)
            .glassEffect(.regular.interactive().tint((Theme.playControlColour(hex: playColourHex) ?? .clear)), in: .circle)
            .contentShape(Circle())
    }

    /// The AI button reveals this panel and starts summarisation only when requested.
    private func aiSummaryPanel<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.surface, style: .continuous)
        return VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.s) {
                Image(systemName: "sparkles")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text("AI Review Summary")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(.primary)
                Spacer(minLength: Theme.Spacing.s)
                Text("On-device")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            content()
        }
        .padding(Theme.Spacing.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.035), in: shape)
        .overlay { shape.strokeBorder(Theme.separator, lineWidth: 0.7).allowsHitTesting(false) }
    }

    private var summaryLoading: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
            DetailSkeletonParagraph(lines: 2)
            Rectangle().fill(Theme.separator).frame(height: 0.7)
            ForEach(0..<2, id: \.self) { _ in
                HStack(alignment: .top, spacing: Theme.Spacing.s) {
                    DetailSkeletonLine(font: .title3.weight(.medium), width: 22)
                    VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                        DetailSkeletonLine(font: .headline.weight(.semibold), width: 90)
                        DetailSkeletonParagraph(lines: 2)
                    }
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Preparing review summary on device")
        .accessibilityIdentifier("detail.reviews.summarizing")
    }

    /// The model's labelled lines become a compact verdict, divider, and two icon-led observations.
    /// Missing evidence kinds are omitted; never invent a positive or negative opinion.
    @ViewBuilder
    private func summaryContent(_ summary: String) -> some View {
        let lines = summary.split(separator: "\n").map(String.init)
        let overall = lines.first(where: { $0.hasPrefix("Overall: ") }).map { String($0.dropFirst("Overall: ".count)) }
        let praised = lines.first(where: { $0.hasPrefix("Praised: ") }).map { String($0.dropFirst("Praised: ".count)) }
        let criticised = lines.first(where: { $0.hasPrefix("Criticised: ") }).map { String($0.dropFirst("Criticised: ".count)) }
        let other = lines.filter {
            !$0.hasPrefix("Overall: ") && !$0.hasPrefix("Praised: ") && !$0.hasPrefix("Criticised: ")
        }

        VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
            if let overall {
                Text(overall)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if praised == nil && criticised == nil {
                // Sparse or older plain-text summaries still have a readable primary line.
                ForEach(other.indices, id: \.self) { index in
                    Text(other[index])
                        .font(.body)
                        .foregroundStyle(.primary)
                }
            }
            if (praised != nil || criticised != nil) && overall != nil {
                Rectangle().fill(Theme.separator).frame(height: 0.7)
            }
            if let praised {
                summaryOpinion("Praised", text: praised, symbol: "plus.circle", tint: .green)
            }
            if let criticised {
                summaryOpinion("Criticised", text: criticised, symbol: "minus.circle", tint: .red)
            }
            if praised != nil || criticised != nil {
                ForEach(other.indices, id: \.self) { index in
                    Text(other[index])
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    private func summaryOpinion(_ title: String, text: String, symbol: String, tint: Color) -> some View {
        HStack(alignment: .top, spacing: Theme.Spacing.s) {
            Image(systemName: symbol)
                .font(.title3.weight(.medium))
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                Text(title)
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(text)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var sortedReviews: [TMDbReview] {
        reviews.sorted {
            switch reviewSort {
            case .longest:
                return $0.content.count > $1.content.count
            case .shortest:
                return $0.content.count < $1.content.count
            case .highestRated, .lowestRated:
                guard let left = $0.rating else { return false }
                guard let right = $1.rating else { return true }
                return reviewSort == .highestRated ? left > right : left < right
            }
        }
    }

    /// Choosing a sort, the current one included, folds the open review first: its card would otherwise be moved while it is open. The
    /// fold has the same run of ticks as a fold by tap.
    private func chooseSort(_ sort: ReviewSort) {
        if let open = expandedReviewID {
            tickLines(ofReview: open)
            withAnimation(.snappy(duration: Self.foldDuration)) { expandedReviewID = nil }
        }
        reviewSort = sort
    }

    /// Opening a review widens its card and unfolds its text together. Closing one folds the text and narrows the card in the same motion,
    /// as it opened: one animation for the state, the card's width and the text. While it moves, a light tick comes for each line of
    /// text that is revealed or put away.
    private func toggleReview(_ id: String) {
        Haptics.tap()
        tickLines(ofReview: id)
        let opening = expandedReviewID != id
        // Set in the same step as the open, so a layout pass that reads the card's new width already finds it settling.
        settling = opening
        withAnimation(.snappy(duration: Self.foldDuration)) {
            expandedReviewID = opening ? id : nil
        }
    }

    /// How long a review takes to open or fold, in seconds. Its run of ticks lasts as long.
    static let foldDuration = 0.35

    /// A swipe that leaves the open review less than half on the shelf folds it, as a tap on it would. Nothing folds while the review is
    /// still opening or being centred, since both move it.
    private func foldIfSwipedAway(_ id: String, _ frame: CGRect) {
        guard expandedReviewID == id, !settling else { return }
        let shown = min(frame.maxX, width) - max(frame.minX, 0)
        guard shown < frame.width / 2 else { return }
        tickLines(ofReview: id)
        withAnimation(.snappy(duration: Self.foldDuration)) { expandedReviewID = nil }
    }

    /// Starts the run of ticks for a review that is about to open or fold: one for each line that will come into view or leave it.
    private func tickLines(ofReview id: String) {
        guard let review = reviews.first(where: { $0.id == id }) else { return }
        Haptics.lines(unfoldingLines(of: review), over: .seconds(Self.foldDuration))
    }

    /// About how many lines of a review come into view when it opens, and leave when it folds: its lines at the open card's width, less
    /// the lines a folded card already shows. It is an estimate from the length of the text, since the text is laid out inside its own
    /// view; the ticks only need to be about right.
    private func unfoldingLines(of review: TMDbReview) -> Int {
        let textWidth = max(0, width - contentMargin * 2) - ReviewCard.padding * 2
        // A character of the review's text is about seven points wide on average.
        let perLine = max(20, Int(textWidth / 7))
        let lines = ReviewTextMarkup.markdown(review.content).split(whereSeparator: \.isNewline).reduce(0) { total, paragraph in
            total + max(1, (paragraph.count + perLine - 1) / perLine)
        }
        return max(0, lines - ReviewCard.foldedLines)
    }
}

/// The shelf's own coordinate space, so a card's frame says where it sits on screen.
private let reviewsShelfSpace = "detail.reviews.shelf"

/// A review card's width. Opening, the card takes its full width in the layout at once and the animation draws the growth, so the card
/// is at its full width when the shelf centres it. Folding, the width shrinks in the layout frame by frame. A width that dropped at once made
/// the shelf suddenly shorter than where it was scrolled to when the last card folded, so the row jumped before it moved; shrinking in
/// step lets the row follow the card.
private struct FoldingWidth: ViewModifier, Animatable {
    /// 1 when open and 0 when folded, and every value between while the card folds.
    private var progress: CGFloat
    private let isExpanded: Bool
    private let folded: CGFloat
    private let expanded: CGFloat

    init(isExpanded: Bool, folded: CGFloat, expanded: CGFloat) {
        self.isExpanded = isExpanded
        self.folded = folded
        self.expanded = expanded
        progress = isExpanded ? 1 : 0
    }

    /// Not tied to the main actor, as `Animatable` asks: it only reads and writes the modifier's own number.
    nonisolated var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        content.frame(width: isExpanded ? expanded : folded + (expanded - folded) * min(max(progress, 0), 1))
    }
}

/// TMDb reviews can mix Markdown with inline HTML. Convert the supported HTML
/// formatting to Markdown so JustifiedText keeps native typography, links and sizing.
private enum ReviewTextMarkup {
    static func markdown(_ raw: String) -> String {
        guard raw.contains("<") || raw.contains("&") else { return raw }
        var text = raw

        // Preserve safe HTML links using the Markdown links JustifiedText already handles.
        let links = try! NSRegularExpression(
            pattern: #"<a\b[^>]*\bhref\s*=\s*["'](https?://[^"']+)["'][^>]*>(.*?)</a\s*>"#,
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        )
        text = links.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text),
                                              withTemplate: "[$2]($1)")

        let tags: [(String, String)] = [
            (#"(?i)<\s*br\s*/?\s*>"#, "\n"),
            (#"(?i)</\s*(?:p|div|blockquote)\s*>"#, "\n\n"),
            (#"(?i)<\s*(?:p|div|blockquote)\b[^>]*>"#, ""),
            (#"(?i)</\s*li\s*>"#, "\n"),
            (#"(?i)<\s*li\b[^>]*>"#, "• "),
            (#"(?i)<\s*(?:em|i)\b[^>]*>"#, "*"),
            (#"(?i)</\s*(?:em|i)\s*>"#, "*"),
            (#"(?i)<\s*(?:strong|b)\b[^>]*>"#, "**"),
            (#"(?i)</\s*(?:strong|b)\s*>"#, "**"),
            (#"(?i)<\s*(?:s|strike|del)\b[^>]*>"#, "~~"),
            (#"(?i)</\s*(?:s|strike|del)\s*>"#, "~~"),
            (#"(?i)</?\s*(?:a|span|font|u|small|ul|ol)\b[^>]*>"#, "")
        ]
        for (pattern, replacement) in tags {
            text = text.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
        }

        // Decode entities after replacing tags: escaped literal markup stays literal.
        let names: [String: String] = [
            "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ",
            "hellip": "…", "mdash": "—", "ndash": "–", "lsquo": "‘", "rsquo": "’",
            "ldquo": "“", "rdquo": "”", "bull": "•", "copy": "©"
        ]
        let entities = try! NSRegularExpression(pattern: #"&(#(?:[xX][0-9a-fA-F]+|[0-9]+)|[A-Za-z]+);"#)
        let original = text as NSString
        for match in entities.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            let entity = original.substring(with: match.range(at: 1))
            let replacement: String?
            if entity.hasPrefix("#") {
                let hexadecimal = entity.lowercased().hasPrefix("#x")
                let digits = String(entity.dropFirst(hexadecimal ? 2 : 1))
                replacement = Int(digits, radix: hexadecimal ? 16 : 10)
                    .flatMap { Unicode.Scalar($0) }
                    .map(String.init)
            } else {
                replacement = names[entity.lowercased()]
            }
            if let replacement {
                text = (text as NSString).replacingCharacters(in: match.range, with: replacement)
            }
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// One TMDb review. Folded, every card is the same height: the text keeps six lines whether or not it fills them. A tap opens or
/// folds it, and only a review that runs past those lines folds. Links in the text are drawn as links in both states, and a tap on one
/// opens it only once the card is expanded; folded, the tap expands the card as any other tap on the text does.
private struct ReviewCard: View {
    let review: TMDbReview
    let isExpanded: Bool
    /// The card's outer width folded and expanded. The text is laid out at the inner width of each and never re-wraps while the card animates.
    let foldedWidth: CGFloat
    let expandedWidth: CGFloat
    let onToggle: () -> Void
    @State private var isTruncated = false
    @Environment(\.openURL) private var openURL

    private var folds: Bool { isExpanded || isTruncated }

    var body: some View {
        let displayedText = ReviewTextMarkup.markdown(review.content)
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    // Short cards cut a long name to one line; an expanded card has the width, so the name wraps in full.
                    Text(review.author).font(.headline).lineLimit(isExpanded ? nil : 1)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    if let rating = review.rating {
                        let stars = min(10, max(0, rating)).rounded() / 2
                        HStack(spacing: 2) {
                            ForEach(0..<5) { index in
                                Image(systemName: stars >= Double(index + 1) ? "star.fill" :
                                        stars >= Double(index) + 0.5 ? "star.leadinghalf.filled" : "star")
                            }
                        }
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white)
                        // The stars keep their width; the name takes what is left, and wraps or cuts before the stars are squeezed.
                        .fixedSize()
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("Rating \(ScoreText.wholeScore(rating)) out of 100")
                    }
                }
                // The gap under the header belongs to the header, so a tap there folds or opens the card as before.
                .padding(.bottom, Theme.Spacing.m)
                .contentShape(Rectangle())
                .onTapGesture {
                    if folds { onToggle() }
                }
                // Two texts, each at its final width: the old one fades out as laid out and the new one fades in already laid out.
                // The text takes its own taps (see `tapText`), so the card's tap does not reach it.
                ZStack(alignment: .topLeading) {
                    if isExpanded {
                        JustifiedText(text: displayedText, textStyle: .subheadline, isMarkdown: true, lineLimit: 0,
                                      showsLinks: true, linksAreTappable: true, onTap: tapText)
                            .frame(width: max(0, expandedWidth - Self.padding * 2), alignment: .leading)
                            .transition(.opacity)
                    } else {
                        JustifiedText(text: displayedText, textStyle: .subheadline, isMarkdown: true, lineLimit: Self.foldedLines,
                                      reservesSpace: true, isTruncated: $isTruncated, showsLinks: true, onTap: tapText)
                            .frame(width: max(0, foldedWidth - Self.padding * 2), alignment: .leading)
                            .transition(.opacity)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        .padding(Self.padding)
        .cardSurface()
        // Fixed-width text never draws outside the card while it grows or shrinks.
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.surface, style: .continuous))
    }

    /// A tap on a link opens it and leaves the card as it is. Any other tap on the text folds or opens the card, as a tap on the header does.
    /// Folded, a link is not tappable, so every tap on the text reaches here with no link.
    private func tapText(_ link: URL?) {
        if let link {
            openURL(link)
        } else if folds {
            onToggle()
        }
    }

    static let padding: CGFloat = 16
    /// The lines of text a folded card shows.
    static let foldedLines = 6
}
#endif
