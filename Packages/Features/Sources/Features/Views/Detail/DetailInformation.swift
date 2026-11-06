#if canImport(UIKit)
import SwiftUI
import StremioKit

/// The title's information, each as a label and a value (see `TitleInformation`). Rows TMDb fills in appear once it answers. Only the
/// most important rows show at first; a tap on the section shows the rest, with the same haptics as a review's fold.
struct DetailInformation: View {
    let model: DetailViewModel
    @Environment(PosterRatingsStore.self) private var ratings: PosterRatingsStore?
    @State private var isExpanded = false
    @Environment(\.pageReveal) private var reveal

    /// How many rows show until the section is opened.
    private static let foldedRows = 5

    var body: some View {
        let all = rows
        let folds = all.count > Self.foldedRows
        let shown = isExpanded || !folds ? all : Array(all.prefix(Self.foldedRows))
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            SectionHeader("Information")
            VStack(alignment: .leading, spacing: Theme.Spacing.m) {
                ForEach(shown, id: \.label) { row in
                    LabeledContent(row.label) {
                        if let value = row.value {
                            Text(value).foregroundStyle(.primary)
                                .transition(.opacity)
                        } else {
                            DetailSkeletonLine(font: .footnote, width: 120)
                                .accessibilityLabel("Loading")
                                .transition(.opacity)
                        }
                    }
                    .font(.footnote)
                }
                if folds {
                    Image(systemName: "chevron.down")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 180 : 0))
                        .frame(maxWidth: .infinity)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { if folds { toggle(hiddenRows: all.count - Self.foldedRows) } }
            .pointerFeedback(folds)
            .accessibilityAddTraits(folds ? .isButton : [])
            .accessibilityHint(folds ? (isExpanded ? "Shows fewer details" : "Shows more details") : "")
        }
        .id(Self.revealID)
        .detailLoadingTransition(model.isLoadingFacts)
        .detailLoadingTransition(model.isLoading)
    }

    private static let revealID = "detail.information"

    /// Opens or folds the rows as a review does: the light tap, then one tick for each row that comes into view or leaves it. Opened,
    /// the section comes into view, as a rating's reviews do.
    private func toggle(hiddenRows: Int) {
        Haptics.play(.buttons)
        Haptics.lines(hiddenRows, over: .seconds(DetailReviews.foldDuration))
        withAnimation(.snappy(duration: DetailReviews.foldDuration)) { isExpanded.toggle() }
        if isExpanded { reveal?.show(Self.revealID) }
    }

    /// Keep known values visible. Reserve common pending fields in their final row order;
    /// absent fields disappear once the corresponding request has actually finished.
    private var rows: [(label: String, value: String?)] {
        let loaded = TitleInformation.rows(detail: model.detail, facts: model.titleFacts,
                                          certification: model.certification, averageRating: averageRating,
                                          prices: model.titlePrices)
        var result: [(label: String, value: String?)] = loaded.map { ($0.label, $0.value) }
        let pending = (model.isLoading ? ["Released", "Runtime", "Genres", "Director", "Writers"] : [])
            + (model.isLoadingFacts && model.titleFacts == nil ? ["Studio", "Country", "Original language", "Original title"] : [])
        for label in pending where !result.contains(where: { $0.label == label }) {
            result.append((label, nil))
        }
        // Most important first: the first rows show until the section opens. A film has no first aired or seasons, so its first five
        // are its release, runtime, genres, director and age rating.
        let priceLabels: [String] = TitlePrices.Kind.allCases.map(\.label)
        let importance: [String] = ["Released", "First aired", "Runtime", "Seasons", "Genres", "Director", "Creator", "Creators", "Network",
                                    "Networks", "Age rating", "Writers", "Last aired", "Status", "Studio", "Studios", "Country", "Countries",
                                    "Original language", "Original title", "Budget", "Box office"] + priceLabels + ["Average rating"]
        return result.sorted { (importance.firstIndex(of: $0.label) ?? importance.count) < (importance.firstIndex(of: $1.label) ?? importance.count) }
    }

    /// The average of the scores in the ratings row, out of 100 as every score in the app reads; nil (no line) with fewer than two.
    private var averageRating: String? {
        ratings?.ratings(for: model.detail.preview).averageScore.map { "\($0)/100" }
    }
}
#endif
