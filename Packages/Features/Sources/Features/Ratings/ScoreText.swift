import Foundation

/// A score out of 10, shown as a whole number out of 100: "8.4" reads "84", and a rating never shows a decimal anywhere in the app.
enum ScoreText {
    static func wholeScore(_ rating: Double) -> String {
        String(Int((rating * 10).rounded()))
    }
}
