import Foundation
import StremioKit

/// How a single-source widget looks on Home. One choice in the editor instead of three kinds of widget to add.
public enum WidgetStyle: String, CaseIterable, Identifiable, Sendable {
    case row = "Row", spotlight = "Spotlight", banner = "Banner"

    public var id: String { rawValue }

    /// The items a widget of this style loads unless the user changes it.
    public var defaultLimit: Int { self == .spotlight ? 8 : 20 }

    /// The style of a widget's content; nil for collections, Continue and unsupported widgets, which have no single source.
    public init?(_ content: HomeWidget.Content) {
        switch content {
        case .row: self = .row
        case .hero: self = .spotlight
        case .banner: self = .banner
        case .collection, .continueWatching, .unsupported: return nil
        }
    }

    /// The content wrapping `configuration` in this style.
    public func content(_ configuration: RowConfiguration) -> HomeWidget.Content {
        switch self {
        case .row: return .row(configuration)
        case .spotlight: return .hero(configuration)
        case .banner: return .banner(configuration)
        }
    }

    /// `widget` shown in this style. The item count follows the style's default unless the user changed it, and a spotlight hides its
    /// title (its artwork carries the name) as the automatic layout does.
    public static func restyled(_ widget: HomeWidget, as style: WidgetStyle) -> HomeWidget {
        let old: RowConfiguration
        switch widget.content {
        case .row(let row), .hero(let row), .banner(let row): old = row
        case .collection, .continueWatching, .unsupported: return widget
        }
        guard let current = WidgetStyle(widget.content), current != style else { return widget }
        var row = old
        if row.limit == current.defaultLimit { row.limit = style.defaultLimit }
        var result = widget
        result.content = style.content(row)
        if style == .spotlight { result.hideTitle = true } else if current == .spotlight { result.hideTitle = false }
        return result
    }
}
