#if canImport(UIKit)
import SwiftUI
import UIKit

/// Settings → Appearance, drawn. The root applies the app-wide parts once (`appliesAppearance()`): the accent as the tint, the text size,
/// the font's design, width, weight, slant and spacing, the animation speed, and the preferences themselves in the environment. Pages read
/// the background from there, headings take `headingStyle()`, and cards, shelves and grids read their sizes, spacing, corners and columns
/// from `LayoutMetrics`, which folds the preferences in. Settings → Appearance's preview applies the same look to itself
/// (`appearanceLook(_:)`), so it can show a look before it is saved.
extension AppearancePreferences.RGB {
    var colour: Color { Color(.sRGB, red: red, green: green, blue: blue, opacity: 1) }

    var uiColour: UIColor { UIColor(red: red, green: green, blue: blue, alpha: 1) }

    /// The sRGB of a colour from the colour picker, kept within 0…1.
    init(_ colour: Color) {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        UIColor(colour).getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        self.init(red: Double(red), green: Double(green), blue: Double(blue))
    }

    /// A filled circle of this colour with a faint ring, which keeps the colour inside a menu (SwiftUI draws plain symbols in the text
    /// colour there) and keeps a near-black colour visible on a dark menu.
    var swatch: Image {
        let size = CGSize(width: 20, height: 20)
        let colour = uiColour
        let image = UIGraphicsImageRenderer(size: size).image { context in
            let circle = CGRect(origin: .zero, size: size).insetBy(dx: 1.5, dy: 1.5)
            colour.setFill()
            context.cgContext.fillEllipse(in: circle)
            UIColor(white: 1, alpha: 0.35).setStroke()
            context.cgContext.setLineWidth(1)
            context.cgContext.strokeEllipse(in: circle)
        }
        return Image(uiImage: image.withRenderingMode(.alwaysOriginal))
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
        background == .black ? Theme.background : backgroundRGB.colour
    }

    /// A background's colour, for its menu and the preview.
    func backgroundSwatch(_ background: Background) -> AppearancePreferences.RGB {
        var look = self
        look.background = background
        return look.backgroundRGB
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
        case .accessibility1: size = .accessibility1
        case .accessibility2: size = .accessibility2
        case .accessibility3: size = .accessibility3
        case .accessibility4: size = .accessibility4
        case .accessibility5: size = .accessibility5
        }
        return size...size
    }

    var fontDesign: Font.Design? { Self.design(font) }

    static func design(_ font: FontStyle) -> Font.Design? {
        switch font {
        case .standard: nil
        case .rounded: .rounded
        case .serif: .serif
        case .monospaced: .monospaced
        }
    }

    var systemFontWidth: Font.Width? {
        switch fontWidth {
        case .compressed: .compressed
        case .condensed: .condensed
        case .standard: nil
        case .expanded: .expanded
        }
    }

    /// The font of shelf and section headings. The default is the app's own, `Theme.Typography.shelfTitle`: Title 2, bold.
    var headingTypeface: Font {
        let style: Font.TextStyle = switch headingSize {
        case .small: .title3
        case .standard: .title2
        case .large: .title
        case .huge: .largeTitle
        }
        let weight: Font.Weight = switch headingWeight {
        case .regular: .regular
        case .medium: .medium
        case .semibold: .semibold
        case .bold: .bold
        case .heavy: .heavy
        case .black: .black
        }
        return Font.system(style, design: Self.design(headingFont.font ?? font), weight: weight)
    }

    /// The progress line's colour on Continue cards.
    var progressFill: Color {
        progressColour == .accent ? (accentColour ?? .accentColor) : .white
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

    /// Draws everything inside with `appearance`: what the root does with the saved look, for a view (the Appearance preview) that shows
    /// a look of its own. The preview leaves out `motion`: the root's animation speed already reaches it, and twice would square it.
    func appearanceLook(_ appearance: AppearancePreferences, motion: Bool = true) -> some View {
        modifier(AppearanceLookModifier(appearance: appearance, motion: motion))
    }

    /// A shelf or section heading in Appearance's heading style: its font, size, weight and case.
    func headingStyle() -> some View {
        modifier(HeadingStyleModifier())
    }

    /// Posters, cards and stills in Appearance's artwork tone. Natural changes nothing.
    func artworkTone(_ tone: AppearancePreferences.ArtworkTone) -> some View {
        modifier(ArtworkToneModifier(tone: tone))
    }
}

private struct AppearanceModifier: ViewModifier {
    @AppStorage(AppearancePreferences.defaultsKey) private var appearance = AppearancePreferences()

    func body(content: Content) -> some View {
        content.appearanceLook(appearance)
    }
}

private struct AppearanceLookModifier: ViewModifier {
    let appearance: AppearancePreferences
    let motion: Bool

    func body(content: Content) -> some View {
        let speed = motion ? appearance.animationSpeed.factor : 1
        content
            .tint(appearance.accentColour)
            .dynamicTypeSize(appearance.dynamicTypeRange)
            .fontDesign(appearance.fontDesign)
            .fontWidth(appearance.systemFontWidth)
            .bold(appearance.boldText)
            .italic(appearance.italicText)
            .tracking(appearance.letterSpacing.points)
            .lineSpacing(appearance.lineSpacing.points)
            .environment(\.appAppearance, appearance)
            // Off stops every SwiftUI animation inside, implicit ones included; another speed scales the animations changes carry.
            .transaction { transaction in
                if speed == 0 {
                    transaction.animation = nil
                    transaction.disablesAnimations = true
                } else if speed != 1 {
                    transaction.animation = transaction.animation?.speed(speed)
                }
            }
    }
}

private struct HeadingStyleModifier: ViewModifier {
    @Environment(\.appAppearance) private var appearance

    func body(content: Content) -> some View {
        content
            .font(appearance.headingTypeface)
            .textCase(appearance.uppercaseHeadings ? .uppercase : nil)
    }
}

private struct ArtworkToneModifier: ViewModifier {
    let tone: AppearancePreferences.ArtworkTone

    @ViewBuilder
    func body(content: Content) -> some View {
        if tone == .natural {
            content
        } else {
            content
                .saturation(tone.saturation)
                .brightness(tone.brightness)
                .contrast(tone.contrast)
        }
    }
}
#endif
