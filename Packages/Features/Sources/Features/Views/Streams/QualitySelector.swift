#if canImport(UIKit)
import SwiftUI

/// The system's segmented control for media types and quality filters.
struct QualitySelector: View {
    let titles: [String]
    @Binding var selection: Int
    var symbols: [String] = []
    var showsTitles = true
    var accessibilityID = "streams.filter"

    var body: some View {
        Picker("Show", selection: $selection) {
            ForEach(titles.indices, id: \.self) { index in
                segment(index)
                    .tag(index)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(width: showsTitles ? nil : CGFloat(titles.count * 44))
        .accessibilityIdentifier(accessibilityID)
        .sensoryFeedback(.selection, trigger: selection)
    }

    @ViewBuilder private func segment(_ index: Int) -> some View {
        if showsTitles, symbols.indices.contains(index) {
            Label(titles[index], systemImage: symbols[index])
        } else if showsTitles {
            Text(titles[index])
        } else if symbols.indices.contains(index) {
            Image(systemName: symbols[index])
        } else {
            Text(titles[index])
        }
    }
}
#endif
