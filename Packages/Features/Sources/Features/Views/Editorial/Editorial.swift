#if canImport(UIKit)
import SwiftUI
import StremioKit
import UIKit

/// The editorial pages (the Arthouse preset turns them on), drawn after a film magazine:
/// the system's condensed grotesque throughout, capitals for names and labels, square frames, black pages with the accent as the one
/// colour, and Search's results laid on the accent itself. iPhone first; the iPad and the Mac keep the standard pages for now.
enum Editorial {
    /// The condensed face at a fixed size, for display type: titles, headings, the runtime.
    static func font(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight).width(.condensed)
    }

    /// The condensed face at a text style, for labels and running text, so it follows the text size.
    static func font(_ style: Font.TextStyle, weight: Font.Weight = .regular) -> Font {
        .system(style, weight: weight).width(.condensed)
    }

    /// The side margin of every editorial page.
    static let margin: CGFloat = 24

    /// A runtime as the editorial pages print it: "110 min" and "1h 50min" are "1H 50M", "45 min" is "45M". Nil when it holds no number.
    static func runtime(_ text: String?) -> String? {
        guard let text else { return nil }
        let numbers = text.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
        guard let first = numbers.first else { return nil }
        let minutes: Int
        if text.lowercased().contains("h") {
            minutes = first * 60 + (numbers.dropFirst().first ?? 0)
        } else {
            minutes = first
        }
        guard minutes > 0 else { return nil }
        let hours = minutes / 60, rest = minutes % 60
        if hours == 0 { return "\(rest)M" }
        return rest == 0 ? "\(hours)H" : "\(hours)H \(rest)M"
    }

    /// A count as a short figure: 1,480 is "1.5K", 2,310,000 is "2.3M".
    static func count(_ value: Int) -> String {
        switch value {
        case 1_000_000...: return compact(Double(value) / 1_000_000) + "M"
        case 1_000...: return compact(Double(value) / 1_000) + "K"
        default: return "\(value)"
        }
    }

    private static func compact(_ value: Double) -> String {
        value >= 100 ? String(Int(value.rounded())) : String(format: "%.1f", value).replacingOccurrences(of: ".0", with: "")
    }

    /// A trailer's length as "2:25".
    static func duration(_ seconds: TimeInterval) -> String {
        let whole = Int(seconds.rounded())
        return "\(whole / 60):" + String(format: "%02d", whole % 60)
    }

    /// The year, the rating and the runtime, as the editorial captions print them: "1994   R   1H 50M".
    static func captionLine(year: String?, certification: String?, runtime: String?) -> String {
        [year.map { String($0.prefix(4)) }, certification, Self.runtime(runtime)]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "   ")
    }
}

extension AppearancePreferences {
    /// True where the editorial pages are drawn: on a phone, with Layout set to Editorial.
    @MainActor var showsEditorialPages: Bool {
        layout == .editorial && UIDevice.current.userInterfaceIdiom == .phone
    }

    /// The editorial pages' one colour, the accent; the search results are laid on it.
    var editorialAccent: Color { accentRGB.colour }

    /// A deep shade of the accent, for the capsules over the results laid on it.
    var editorialAccentDeep: Color { accentRGB.scaled(by: 0.36).colour }
}

extension EnvironmentValues {
    /// True while the editorial pill bar stands in for the tab bar (see `EditorialTabBar`): every page keeps the native bar hidden.
    @Entry var usesEditorialTabBar = false
}

/// The editorial pages' navigation in place of the tab bar: two capsules, HOME and FOR YOU, as the Arthouse mockup draws them. A tap on
/// a capsule's name opens its tab (Home; Discover, as For You). Its + opens a menu of the tabs in its half, and the capsule then names
/// the one showing (Library, Settings, Search). The capsule whose half is showing is drawn brighter.
struct EditorialTabBar: View {
    let router: AppRouter
    /// True over Search's results, which are laid on the accent: the capsules fill with a deep shade of it, as the mockup's second page
    /// draws them.
    let onAccent: Bool
    @Environment(\.appAppearance) private var appearance

    private struct Destination: Identifiable {
        let tab: LaunchRoute.Tab
        let title: String
        var id: LaunchRoute.Tab { tab }
    }

    private static var leading: [Destination] {
        [Destination(tab: .home, title: "Home"), Destination(tab: .library, title: "Library"), Destination(tab: .settings, title: "Settings")]
    }
    private static var trailing: [Destination] {
        [Destination(tab: .discover, title: "For You"), Destination(tab: .search, title: "Search")]
    }
    static let height: CGFloat = 48

    var body: some View {
        HStack(spacing: 2) {
            capsule(Self.leading)
            capsule(Self.trailing)
        }
        .padding(.horizontal, Editorial.margin)
        .padding(.top, Theme.Spacing.m)
        .padding(.bottom, Theme.Spacing.xs)
        // The page scrolls under the capsules: a fade into its own ground keeps them clear of what passes beneath.
        .background {
            LinearGradient(colors: [ground.opacity(0), ground.opacity(0.92)], startPoint: .top, endPoint: .center)
                .ignoresSafeArea(edges: .bottom)
                .allowsHitTesting(false)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("editorial.tabBar")
    }

    private var ground: Color { onAccent ? appearance.editorialAccent : appearance.pageBackground }

    private func capsule(_ destinations: [Destination]) -> some View {
        let shown = destinations.first { $0.tab == router.tab } ?? destinations[0]
        let isActive = destinations.contains { $0.tab == router.tab }
        let ink: Color = .white.opacity(isActive ? 1 : 0.72)
        return HStack(spacing: 0) {
            Button { go(to: shown.tab) } label: {
                Text(shown.title.uppercased())
                    .font(Editorial.font(.body))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .padding(.leading, 40)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel(shown.title)
            .accessibilityAddTraits(isActive ? .isSelected : [])
            .accessibilityIdentifier("editorial.tab.\(shown.tab)")
            Menu {
                ForEach(destinations) { destination in
                    Button { go(to: destination.tab) } label: {
                        if destination.tab == router.tab {
                            Label(destination.title, systemImage: "checkmark")
                        } else {
                            Text(destination.title)
                        }
                    }
                }
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 15, weight: .regular))
                    .foregroundStyle(ink)
                    .frame(width: 40, height: Self.height)
                    .contentShape(Rectangle())
            }
            .tint(ink)
            .accessibilityLabel("More in \(destinations[0].title)")
            .padding(.trailing, Theme.Spacing.s)
        }
        .buttonStyle(.hoverPlain)
        .foregroundStyle(ink)
        .frame(height: Self.height)
        .background { Capsule().fill(onAccent ? appearance.editorialAccentDeep : Color.black) }
        .overlay {
            Capsule()
                .strokeBorder(.white.opacity(onAccent ? 0 : (isActive ? 0.95 : 0.5)), lineWidth: 1)
                .allowsHitTesting(false)
        }
        .animation(.smooth(duration: 0.25), value: isActive)
    }

    private func go(to tab: LaunchRoute.Tab) {
        Haptics.play(.navigation)
        router.tapTab(tab)
    }
}

/// The editorial pages' back control: a filled chevron in a circle and BACK, small, as the mockup sets it in its top corner.
struct EditorialBackButton: View {
    var ink: Color = .white
    let action: () -> Void

    var body: some View {
        Button {
            Haptics.play(.navigation)
            action()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "chevron.backward.circle.fill")
                    .font(.system(size: 14, weight: .regular))
                Text("BACK")
                    .font(Editorial.font(.subheadline))
            }
            .foregroundStyle(ink)
            .padding(.vertical, Theme.Spacing.s)
            .contentShape(Rectangle())
        }
        .buttonStyle(.hoverPlain)
        .accessibilityLabel("Back")
        .accessibilityIdentifier("editorial.back")
    }
}
#endif
