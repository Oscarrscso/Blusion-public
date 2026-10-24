import CoreGraphics

/// Where each card's slot is in the widget grid. Pure arithmetic: the drag works out which slot the pointer is in from this, never from
/// measured views, so a drag cannot feed back into its own layout.
struct WidgetSlotLayout: Equatable {
    /// The gutter between cards, across and down, and at the grid's sides.
    static let gutter: CGFloat = 16

    let columns: Int
    let cardWidth: CGFloat
    let count: Int

    /// The cards are 2:3 portrait.
    var cardHeight: CGFloat { cardWidth * 1.5 }
    var rows: Int { count == 0 || columns <= 0 ? 0 : (count + columns - 1) / columns }

    var contentSize: CGSize {
        guard columns > 0 else { return .zero }
        return CGSize(width: CGFloat(columns) * cardWidth + CGFloat(columns - 1) * Self.gutter,
                      height: rows == 0 ? 0 : CGFloat(rows) * cardHeight + CGFloat(rows - 1) * Self.gutter)
    }

    /// A scroll offset moved by `step`, kept between `lowest` and `highest` (which is never below `lowest`).
    static func scrolledOffset(_ offset: CGFloat, by step: CGFloat, lowest: CGFloat, highest: CGFloat) -> CGFloat {
        min(max(offset + step, lowest), max(lowest, highest))
    }

    /// The layout of `columns` cards that fill `width` between them, with a gutter between each.
    static func fitting(width: CGFloat, columns: Int, count: Int) -> WidgetSlotLayout {
        guard columns > 0 else { return WidgetSlotLayout(columns: 1, cardWidth: 0, count: count) }
        let cardWidth = max(0, (width - CGFloat(columns - 1) * gutter) / CGFloat(columns))
        return WidgetSlotLayout(columns: columns, cardWidth: cardWidth, count: count)
    }

    func frame(for index: Int) -> CGRect {
        let column = index % columns
        let row = index / columns
        return CGRect(x: CGFloat(column) * (cardWidth + Self.gutter), y: CGFloat(row) * (cardHeight + Self.gutter),
                      width: cardWidth, height: cardHeight)
    }

    func center(for index: Int) -> CGPoint {
        let frame = frame(for: index)
        return CGPoint(x: frame.midX, y: frame.midY)
    }

    /// The slot under a point: nil in a gutter, and beside the grid. Below the last row, and in an empty slot of a short last row, it is the
    /// last card's slot, so a drag past the end lands last.
    func index(at point: CGPoint) -> Int? {
        guard count > 0, columns > 0, cardWidth > 0, point.x >= 0, point.y >= 0 else { return nil }
        let step = cardWidth + Self.gutter
        let rowStep = cardHeight + Self.gutter
        let column = Int(point.x / step)
        guard column < columns, point.x - CGFloat(column) * step <= cardWidth else { return nil }
        let row = Int(point.y / rowStep)
        if row >= rows { return count - 1 }
        guard point.y - CGFloat(row) * rowStep <= cardHeight else { return nil }
        let index = row * columns + column
        return index < count ? index : count - 1
    }

    /// The slot a held card goes to with the pointer at `point`: the slot under it, or the card's own slot `from` while the pointer is in a
    /// gutter or beside the grid. Never one of the first `pinned` slots, which the showcase keeps.
    func target(at point: CGPoint, from: Int, pinned: Int) -> Int {
        max(index(at: point) ?? from, pinned)
    }

    /// The order with the item at `from` taken out and put back so it ends at `to`.
    static func moved<Item>(_ items: [Item], from: Int, to: Int) -> [Item] {
        guard items.indices.contains(from), items.indices.contains(to), from != to else { return items }
        var result = items
        let item = result.remove(at: from)
        result.insert(item, at: to)
        return result
    }
}
