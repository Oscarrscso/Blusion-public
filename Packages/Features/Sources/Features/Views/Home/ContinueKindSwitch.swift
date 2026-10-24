#if canImport(UIKit)
import StremioKit
import SwiftUI

/// Which titles the Continue Watching rail shows: everything, movies, or series (each episode counts as its series).
enum ContinueKind: String, CaseIterable, Identifiable {
    case all, movies, series

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: "All"
        case .movies: "Movies"
        case .series: "Series"
        }
    }

    var symbol: String {
        switch self {
        case .all: "infinity"
        case .movies: "film"
        case .series: "tv"
        }
    }

    func includes(_ request: StreamRequest) -> Bool {
        switch self {
        case .all: true
        case .movies: request.type != "series"
        case .series: request.type == "series"
        }
    }
}

/// The shared glass pill: compact icons on Continue, or icons and text on Discover.
struct ContinueKindSwitch: View {
    @Binding var selection: ContinueKind
    var kinds = ContinueKind.allCases
    var showsTitles = false
    var accessibilityID = "continue.kind"

    var body: some View {
        QualitySelector(titles: kinds.map(\.title), selection: Binding {
            kinds.firstIndex(of: selection) ?? 0
        } set: { index in
            guard kinds.indices.contains(index) else { return }
            selection = kinds[index]
        }, symbols: kinds.map(\.symbol), showsTitles: showsTitles, accessibilityID: accessibilityID)
    }
}
#endif
