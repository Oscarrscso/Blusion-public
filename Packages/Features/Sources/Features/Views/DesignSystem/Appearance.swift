#if canImport(UIKit)
import SwiftUI
import UIKit

/// Settings → Appearance, drawn. The root applies the app-wide parts once (`appliesAppearance()`): the accent as the tint, the text size,
/// the font's design and weight, and the preferences themselves in the environment. Pages read the background from there; cards, shelves
/// and grids read their sizes, spacing, corners and columns from `LayoutMetrics`, which folds the preferences in.
extension AppearancePreferences.RGB {
    var colour: Color { Color(.sRGB, red: red, green: green, blue: blue, opacity: 1) }

    var uiColour: UIColor { UIColor(red: red, green: green, blue: blue, alpha: 1) }

    /// The sRGB of a colour from the colour picker, kept within 0…1.
    init(_ colour: Color) {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        UIColor(colour).getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        self.init(red: Double(red), green: Double(green), blue: Double(blue))
    }

    /// A filled circle of this colour that keeps it inside a menu, where SwiftUI draws plain symbols in the text colour.
    var swatch: Image {
        let image = UIImage(systemName: "circle.fill")?.withTintColor(uiColour, renderingMode: .alwaysOriginal) ?? UIImage()
        return Image(uiImage: image)
    }
}

extension AppearancePreferences {
    /// The tint, or nil to keep the asset catalogue's accent, which the default (Blusion) is.
    var accentColour: Color? {
        accent == .blusion ? nil : accentRGB.colour
    }

    /// Where the app draws a selected item in a colour of its own (the landscape tab buttons): the accent, or the app's own light blue.
    var selectionColour: Color {
        accentColour ?? Color(red: 0.50, green: 0.59, blue: 1)
    }

    /// The colour behind every page, which hero artwork fades into.
    var pageBackground: Color {
        switch background {
        case .black: Theme.background
        case .graphite: Color(white: 0.075)
        case .midnight: Color(.sRGB, red: 0.02, green: 0.035, blue: 0.085, opacity: 1)
        case .tinted:
            Color(.sRGB, red: accentRGB.red * 0.11, green: accentRGB.green * 0.11, blue: accentRGB.blue * 0.11, opacity: 1)
        }
    }

    /// The background's colour as a swatch, for its menu.
    func backgroundSwatch(_ background: Background) -> AppearancePreferences.RGB {
        switch background {
        case .black: AppearancePreferences.RGB(red: 0, green: 0, blue: 0)
        case .graphite: AppearancePreferences.RGB(red: 0.2, green: 0.2, blue: 0.2)
        case .midnight: AppearancePreferences.RGB(red: 0.08, green: 0.12, blue: 0.28)
        case .tinted: AppearancePreferences.RGB(red: accentRGB.red * 0.35, green: accentRGB.green * 0.35, blue: accentRGB.blue * 0.35)
        }
    }

    /// The text sizes the app may use: the whole range when it follows the system, otherwise the one size chosen.
    var dynamicTypeRange: ClosedRange<DynamicTypeSize> {
        let size: DynamicTypeSize
        switch textSize {
        case .system: return DynamicTypeSize.xSmall...DynamicTypeSize.accessibility5
        case .xSmall: size = .xSmall
        case .small: size = .small
        case .medium: size = .medium
        case .large: size = .large
        case .xLarge: size = .xLarge
        case .xxLarge: size = .xxLarge
        case .xxxLarge: size = .xxxLarge
        }
        return size...size
    }

    var fontDesign: Font.Design? {
        switch font {
        case .standard: nil
        case .rounded: .rounded
        case .serif: .serif
        case .monospaced: .monospaced
        }
    }
}

extension CardAspect {
    /// Whether a card of this shape carries its name underneath when its caller leaves that to the shape: posters follow Appearance's
    /// Titles under posters; landscape and square cards always do.
    func showsCaption(_ appearance: AppearancePreferences) -> Bool {
        self == .poster ? appearance.showsPosterTitles : showsCaptionByDefault
    }
}

extension EnvironmentValues {
    /// Settings → Appearance, as the root read it (see `appliesAppearance()`).
    @Entry var appAppearance = AppearancePreferences()
}

extension View {
    /// Applies Settings → Appearance to everything inside, and keeps following it. Applied once, at the root.
    func appliesAppearance() -> some View {
        modifier(AppearanceModifier())
    }
}

private struct AppearanceModifier: ViewModifier {
    @AppStorage(AppearancePreferences.defaultsKey) private var appearance = AppearancePreferences()

    func body(content: Content) -> some View {
        content
            .tint(appearance.accentColour)
            .dynamicTypeSize(appearance.dynamicTypeRange)
            .fontDesign(appearance.fontDesign)
            .bold(appearance.boldText)
            .environment(\.appAppearance, appearance)
    }
}
#endif
