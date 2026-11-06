import Foundation
import StremioKit

/// How a single-source widget looks on Home. One choice in the editor instead of a kind of widget to add for each.
public enum WidgetStyle: String, CaseIterable, Identifiable, Sendable {
    case row = "Row", spotlight = "Spotlight", banner = "Carousel"
    /// Rows drawn in one of Blusion's own layouts (`RowLayout`).
    case mosaic = "Mosaic", flow = "Flow", wall = "Wall", parallax = "Parallax", spines = "Spines"

    public var id: String { rawValue }

    /// The symbol beside the style's name in the style menus.
    public var systemImage: String {
        switch self {
        case .row: "rectangle.split.3x1"
        case .spotlight: "rectangle.inset.filled"
        case .banner: "photo.on.rectangle"
        case .mosaic: "rectangle.3.group"
        case .flow: "rectangle.on.rectangle.angled"
        case .wall: "square.grid.3x3"
        case .parallax: "square.3.layers.3d"
        case .spines: "books.vertical"
        }
    }

    /// The items a widget of this style loads unless the user changes it.
    public var defaultLimit: Int { self == .spotlight ? 8 : 20 }

    /// The layout a row of this style is drawn in; nil for the shelf, the spotlight and the carousel.
    public var layout: RowLayout? {
        switch self {
        case .row, .spotlight, .banner: return nil
        case .mosaic: return .mosaic
        case .flow: return .flow
        case .wall: return .wall
        case .parallax: return .parallax
        case .spines: return .spines
        }
    }

    /// The style a row drawn in `layout` has.
    init(_ layout: RowLayout) {
        switch layout {
        case .mosaic: self = .mosaic
        case .flow: self = .flow
        case .wall: self = .wall
        case .parallax: self = .parallax
        case .spines: self = .spines
        }
    }

    /// The style of a widget's content; nil for collections, Continue and unsupported widgets, which have no single source.
    public init?(_ content: HomeWidget.Content) {
        switch content {
        case .row(let row): self = row.layout.map { WidgetStyle($0) } ?? .row
        case .hero: self = .spotlight
        case .banner: self = .banner
        case .collection, .continueWatching, .unsupported: return nil
        }
    }

    /// The content wrapping `configuration` in this style, with the style's layout.
    public func content(_ configuration: RowConfiguration) -> HomeWidget.Content {
        var configuration = configuration
        configuration.layout = layout
        switch self {
        case .row, .mosaic, .flow, .wall, .parallax, .spines: return .row(configuration)
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
