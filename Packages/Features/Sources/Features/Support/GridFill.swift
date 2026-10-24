import SwiftUI

/// Columns that fill a grid's width exactly. An adaptive grid item stops each column at its maximum width, so at some widths the columns
/// end short of the right margin and leave a gutter there. With no maximum, SwiftUI lays out as many columns as fit at the minimum width
/// and shares the whole width between them, with the same gap between each: the last column ends on the right margin at every width, and
/// a wider grid gets more columns rather than ever wider ones. `columnCount` and `columnWidth` are that layout's arithmetic.
enum GridFill {
    /// `columns` with an adaptive item's maximum lifted, so its columns share the whole width. Any other grid already fills it.
    static func filling(_ columns: [GridItem]) -> [GridItem] {
        guard columns.count == 1, case .adaptive(let minimum, _) = columns[0].size else { return columns }
        return [GridItem(.adaptive(minimum: minimum, maximum: .infinity), spacing: columns[0].spacing, alignment: columns[0].alignment)]
    }

    /// How many columns of at least `minimum` points, with `spacing` between them, fit across `width`. At least one.
    static func columnCount(width: CGFloat, minimum: CGFloat, spacing: CGFloat) -> Int {
        guard width > 0, minimum > 0 else { return 1 }
        return max(1, Int(((width + spacing) / (minimum + spacing)).rounded(.down)))
    }

    /// The width of each of `count` columns sharing `width`, with `spacing` between them.
    static func columnWidth(width: CGFloat, count: Int, spacing: CGFloat) -> CGFloat {
        let count = max(1, count)
        return max(0, (width - spacing * CGFloat(count - 1)) / CGFloat(count))
    }
}
