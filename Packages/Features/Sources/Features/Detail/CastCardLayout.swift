import Foundation

/// The width of a cast and crew card on a title page: four whole cards fit across the page, between its margins and with the gaps between
/// them, so the fifth only peeks in at the edge. Never wider than the shelf's usual card, so a wide window keeps today's size.
public enum CastCardLayout {
    /// How many whole cards fit across the page.
    public static let cardsAcross = 4

    /// The card width for a page `pageWidth` wide with `margin` on each side and `spacing` between cards, at most `maximum`. Whole points,
    /// rounded down, so the fourth card never runs past the margin. Zero when nothing fits.
    public static func cardWidth(pageWidth: Double, margin: Double, spacing: Double, maximum: Double) -> Double {
        let across = Double(cardsAcross)
        let fitting = (pageWidth - margin * 2 - spacing * (across - 1)) / across
        guard fitting.isFinite, fitting > 0 else { return 0 }
        return min(maximum, fitting.rounded(.down))
    }
}
