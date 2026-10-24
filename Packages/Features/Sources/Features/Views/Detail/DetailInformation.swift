#if canImport(UIKit)
import SwiftUI
import StremioKit

/// The title's information, each as a label and a value (see `TitleInformation`). Rows TMDb fills in appear once it answers.
struct DetailInformation: View {
    let model: DetailViewModel
    @Environment(PosterRatingsStore.self) private var ratings: PosterRatingsStore?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            SectionHeader("Information")
            ForEach(rows, id: \.label) { row in
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
        }
        .detailLoadingTransition(model.isLoadingFacts)
        .detailLoadingTransition(model.isLoading)
    }

    /// Keep known values visible. Reserve common pending fields in their final row order;
    /// absent fields disappear once the corresponding request has actually finished.
    private var rows: [(label: String, value: String?)] {
        let loaded = TitleInformation.rows(detail: model.detail, facts: model.titleFacts,
                                          certification: model.certification, averageRating: averageRating)
        var result: [(label: String, value: String?)] = loaded.map { ($0.label, $0.value) }
        let pending = (model.isLoading ? ["Released", "Runtime", "Genres", "Director", "Writers"] : [])
            + (model.isLoadingFacts && model.titleFacts == nil ? ["Studio", "Country", "Original language", "Original title"] : [])
        for label in pending where !result.contains(where: { $0.label == label }) {
            result.append((label, nil))
        }
        let order = ["First aired", "Last aired", "Released", "Runtime", "Genres", "Director", "Creator", "Creators",
                     "Writers", "Studio", "Studios", "Network", "Networks", "Country", "Countries", "Original language",
                     "Original title", "Seasons", "Status", "Budget", "Box office", "Age rating", "Average rating"]
        return result.sorted { (order.firstIndex(of: $0.label) ?? order.count) < (order.firstIndex(of: $1.label) ?? order.count) }
    }

    /// The average of the scores in the ratings row, out of 100 as every score in the app reads; nil (no line) with fewer than two.
    private var averageRating: String? {
        ratings?.ratings(for: model.detail.preview).averageScore.map { "\($0)/100" }
    }
}
#endif
