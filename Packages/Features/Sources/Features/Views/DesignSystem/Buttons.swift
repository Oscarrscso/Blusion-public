#if canImport(UIKit)
import StremioKit
import SwiftUI

/// The one main action of a screen ("Play", "Resume", "Install"): the system's Liquid Glass button as a capsule, the button the
/// navigation bar draws. `.controlSize` picks its size; with none set it is the large one, level with the round actions beside it.
struct PrimaryActionButtonStyle: PrimitiveButtonStyle {
    /// False sizes the button to its label (empty states, inline calls to action) instead of the full width.
    var fillsWidth = true
    /// The least width the button takes on the Mac, so the glass itself is that wide; zero leaves it to its label.
    var minWidth: CGFloat = 0
    var glass: Glass?
    var height: CGFloat?

    func makeBody(configuration: Configuration) -> some View {
        PrimaryActionButton(configuration: configuration, fillsWidth: fillsWidth, minWidth: minWidth, glass: glass, height: height)
    }
}

/// A view of its own because a button style cannot read the environment itself.
private struct PrimaryActionButton: View {
    @Environment(\.layoutMetrics) private var metrics
    @Environment(\.appAppearance) private var appearance
    let configuration: PrimitiveButtonStyleConfiguration
    let fillsWidth: Bool
    let minWidth: CGFloat
    let glass: Glass?
    let height: CGFloat?
    @Environment(\.controlSize) private var controlSize

    var body: some View {
        if let height {
            Button(role: configuration.role) {
                Haptics.play(.buttons)
                configuration.trigger()
            } label: {
                filled(configuration.label
                    .fontWeight(.semibold)
                    .padding(.horizontal, Theme.Spacing.s)
                    .frame(minWidth: minWidth, maxWidth: fillsWidth ? .infinity : nil)
                    .frame(height: height)
                    .contentShape(ScaledCapsule(scale: metrics.cornerScale(for: .playButton))))
                    .glassHover(ScaledCapsule(scale: metrics.cornerScale(for: .playButton)))
            }
            .buttonStyle(.plain)
        } else {
        #if targetEnvironment(macCatalyst)
        // Match the navigation control and the round actions beside Play.
        Button(role: configuration.role) {
            Haptics.play(.buttons)
            configuration.trigger()
        } label: {
            configuration.label
                .fontWeight(.semibold)
                .padding(.horizontal, Theme.Spacing.s)
                .frame(minWidth: minWidth, maxWidth: fillsWidth ? .infinity : nil, maxHeight: .infinity)
                .contentShape(ScaledCapsule(scale: metrics.cornerScale(for: .playButton)))
                .pointerFeedback()
        }
        .finishedButtonStyle(glass, finish: appearance.buttonFinish, fill: solidFill ?? (.white, .black))
        .buttonBorderShape(metrics.cornerScale(for: .playButton) == 1 ? .capsule : .roundedRectangle(radius: Theme.Radius.surface * metrics.cornerScale(for: .playButton)))
        .controlSize(.large)
        .frame(height: CircleActionButton.diameter)
        #else
        Button(role: configuration.role) {
            Haptics.play(.buttons)
            configuration.trigger()
        } label: {
            configuration.label
                .fontWeight(.semibold)
                .frame(maxWidth: fillsWidth ? .infinity : nil)
        }
        .finishedButtonStyle(glass, finish: appearance.buttonFinish, fill: solidFill ?? (.white, .black))
        .buttonBorderShape(metrics.cornerScale(for: .playButton) == 1 ? .capsule : .roundedRectangle(radius: Theme.Radius.surface * metrics.cornerScale(for: .playButton)))
        // A main action is one size up from the controls around it.
        .controlSize(controlSize == .regular ? .large : controlSize)
        .pointerFeedback()
        #endif
        }
    }

    /// Play's own fill: solid white or the accent when Appearance sets one (Colour → Play button), with dark or light text to suit;
    /// otherwise the tinted glass it was given. A Flat finish leaves the label alone, in that white or accent.
    @ViewBuilder
    private func filled<Label: View>(_ label: Label) -> some View {
        let shape = ScaledCapsule(scale: metrics.cornerScale(for: .playButton))
        if appearance.buttonFinish == .flat {
            let colour = solidFill?.fill ?? .white
            label.foregroundStyle(colour).tint(colour)
        } else if let solid = solidFill {
            label.foregroundStyle(solid.text).tint(solid.text).background(solid.fill, in: shape)
        } else {
            label.glassEffect(glass ?? .regular.interactive(), in: shape)
        }
    }

    private var solidFill: (fill: Color, text: Color)? {
        switch appearance.playStyle {
        case .artwork:
            return nil
        case .white:
            return (.white, .black)
        case .accent:
            let rgb = appearance.accentRGB
            let isLight = 0.2126 * rgb.red + 0.7152 * rgb.green + 0.0722 * rgb.blue > 0.55
            return (rgb.colour, isLight ? .black : .white)
        }
    }
}

/// A secondary action ("Customize", "Open on Best Blurays"): the system's Liquid Glass button as a label-sized capsule.
/// Do not stack it on other glass and do not use it for the screen's main action.
struct GlassCapsuleButtonStyle: PrimitiveButtonStyle {
    @Environment(\.layoutMetrics) private var metrics
    @Environment(\.appAppearance) private var appearance
    func makeBody(configuration: Configuration) -> some View {
        Button(role: configuration.role) {
            Haptics.play(.buttons)
            configuration.trigger()
        } label: {
            configuration.label
                .font(.subheadline.weight(.semibold))
                .pointerFeedback()
        }
        .finishedButtonStyle(nil, finish: appearance.buttonFinish)
        .buttonBorderShape(metrics.cornerScale(for: .actionButtons) == 1 ? .capsule : .roundedRectangle(radius: Theme.Radius.surface * metrics.cornerScale(for: .actionButtons)))
    }
}

extension PrimitiveButtonStyle where Self == PrimaryActionButtonStyle {
    /// Full-width glass capsule: the screen's main action.
    static var primaryAction: PrimaryActionButtonStyle { PrimaryActionButtonStyle() }
    /// The same button, only as wide as its label.
    static var primaryActionCompact: PrimaryActionButtonStyle { PrimaryActionButtonStyle(fillsWidth: false) }
}

extension PrimitiveButtonStyle where Self == GlassCapsuleButtonStyle {
    /// A compact glass capsule for secondary actions.
    static var glassCapsule: GlassCapsuleButtonStyle { GlassCapsuleButtonStyle() }
}

extension View {
    @ViewBuilder
    fileprivate func configurableGlassButtonStyle(_ glass: Glass?) -> some View {
        if #available(iOS 26.1, macCatalyst 26.1, *) {
            if let glass {
                buttonStyle(GlassButtonStyle(glass))
            } else {
                buttonStyle(GlassButtonStyle())
            }
        } else {
            buttonStyle(GlassButtonStyle())
        }
    }

    /// The system's glass button, or, for a look whose app draws no glass (Appearance → Colour → Buttons → Finish), the system's
    /// flat bordered button (Solid: prominent in `fill` for a main action, a quiet white tint otherwise) or its borderless one (Flat:
    /// the label alone, in `fill`'s colour or white).
    @ViewBuilder
    func finishedButtonStyle(_ glass: Glass?, finish: AppearancePreferences.ButtonFinish, fill: (fill: Color, text: Color)? = nil) -> some View {
        switch finish {
        case .glass:
            configurableGlassButtonStyle(glass)
        case .solid:
            if let fill {
                buttonStyle(.borderedProminent).tint(fill.fill).foregroundStyle(fill.text)
            } else {
                buttonStyle(.bordered).tint(.white)
            }
        case .flat:
            buttonStyle(.borderless).tint(fill?.fill ?? .white)
        }
    }

    /// The system's prominent glass button in the tint, or its bordered (Solid) or borderless (Flat) form, as Finish sets it.
    @ViewBuilder
    func finishedProminentButtonStyle(_ finish: AppearancePreferences.ButtonFinish) -> some View {
        switch finish {
        case .glass: buttonStyle(.glassProminent)
        case .solid: buttonStyle(.borderedProminent)
        case .flat: buttonStyle(.borderless)
        }
    }

    /// The glass a button draws in its own label, as Finish sets it: that glass, the bordered button's flat grey fill (Solid), or
    /// nothing, the label alone (Flat). For buttons only; panels and indicators keep their glass.
    func buttonSurface(_ glass: Glass = .regular, in shape: some Shape) -> some View {
        modifier(ButtonSurface(glass: glass, shape: shape))
    }

    /// Makes an icon button the system's round Liquid Glass button, the one the navigation bar draws.
    func glassCircleButton(_ size: ControlSize = .large, glass: Glass? = nil, group: AppearancePreferences.CornerGroup = .actionButtons) -> some View {
        modifier(CircularGlassButton(size: size, glass: glass, group: group))
    }
}

/// Keep hover tracking inside the native glass button's label on Catalyst. Bordered or borderless for a Solid or Flat finish.
struct HoverGlassButtonStyle: PrimitiveButtonStyle {
    @Environment(\.appAppearance) private var appearance
    var glass: Glass?

    func makeBody(configuration: Configuration) -> some View {
        Button(role: configuration.role, action: configuration.trigger) {
            configuration.label.pointerFeedback()
        }
        .finishedButtonStyle(glass, finish: appearance.buttonFinish)
    }
}

extension PrimitiveButtonStyle where Self == HoverGlassButtonStyle {
    static var hoverGlass: HoverGlassButtonStyle { HoverGlassButtonStyle() }
}

/// Draw and hover the whole fixed-size glass label, as Play does.
struct FixedGlassButtonStyle: PrimitiveButtonStyle {
    @Environment(\.layoutMetrics) private var metrics
    var size: CGFloat = CircleActionButton.diameter
    var glass: Glass = .regular.interactive()

    func makeBody(configuration: Configuration) -> some View {
        Button(role: configuration.role, action: configuration.trigger) {
            configuration.label
                .frame(width: size, height: size)
                .contentShape(ScaledCapsule(scale: metrics.circularButtonScale(for: .actionButtons)))
                .buttonSurface(glass, in: ScaledCapsule(scale: metrics.circularButtonScale(for: .actionButtons)))
                .glassHover(ScaledCapsule(scale: metrics.circularButtonScale(for: .actionButtons)))
        }
        .buttonStyle(.plain)
    }
}

/// A button's own glass, or the flat grey fill of the bordered button for a Solid finish, or nothing for a Flat one.
private struct ButtonSurface<S: Shape>: ViewModifier {
    @Environment(\.appAppearance) private var appearance
    let glass: Glass
    let shape: S

    @ViewBuilder
    func body(content: Content) -> some View {
        switch appearance.buttonFinish {
        case .glass: content.glassEffect(glass, in: shape)
        case .solid: content.background(.white.opacity(0.14), in: shape)
        case .flat: content
        }
    }
}

private struct CircularGlassButton: ViewModifier {
    let size: ControlSize
    let glass: Glass?
    let group: AppearancePreferences.CornerGroup
    @Environment(\.layoutMetrics) private var metrics

    func body(content: Content) -> some View {
        content.buttonStyle(HoverGlassButtonStyle(glass: glass))
            .buttonBorderShape(metrics.includesCircularButtons
                ? .roundedRectangle(radius: CircleActionButton.diameter / 2 * metrics.cornerScale(for: group)) : .circle)
            .controlSize(size)
    }
}

/// A secondary action on a title page: the system's round Liquid Glass button with its symbol and no caption. `title` ("Add",
/// "Watched", "Trailer") is its VoiceOver label. With `isOn` it shows `onSystemImage` (default: the same symbol, filled) and
/// `onTitle` ("Added"); the symbol swaps with the system replace effect. With `isLoading` the symbol gives way to a small spinner
/// in the same square, so the button keeps its size, and VoiceOver says it is loading.
///
/// Several in a row belong in one `GlassEffectContainer` (or `CircleActionRow`) so the glass is composed once.
struct CircleActionButton: View {
    @Environment(\.layoutMetrics) private var metrics
    let title: String
    let systemImage: String
    let isOn: Bool
    let onTitle: String?
    let onSystemImage: String?
    let action: () -> Void
    let isLoading: Bool
    /// Moves when `isOn` changes without a tick of its own: read in rather than changed by the user (see `DetailViewModel.loadRevision`), or
    /// changed by another control that gave its own haptic. A change of `isOn` that comes with a move of this gives no tick.
    let quietRevision: Int
    /// The symbol's colour while `isOn`: the title's Play colour for Save, Watched and Trailer. Nil keeps the usual grey.
    let onColour: Color?
    let exactSize: Bool
    /// Match Play and the navigation control on Mac; retain the larger touch target on iPhone.
    #if targetEnvironment(macCatalyst)
    static let diameter: CGFloat = MacPageNavigation.controlHeight
    #else
    static let diameter: CGFloat = 50
    #endif

    init(title: String, systemImage: String, isOn: Bool = false, onTitle: String? = nil, onSystemImage: String? = nil,
         quietRevision: Int = 0, onColour: Color? = nil, exactSize: Bool = false, action: @escaping () -> Void, isLoading: Bool = false) {
        self.title = title
        self.systemImage = systemImage
        self.isOn = isOn
        self.onTitle = onTitle
        self.onSystemImage = onSystemImage
        self.quietRevision = quietRevision
        self.exactSize = exactSize
        self.onColour = onColour
        self.action = action
        self.isLoading = isLoading
    }

    /// What the tick watches: the state, and whether it changed quietly.
    private struct TickState: Equatable {
        let isOn: Bool
        let quietRevision: Int
    }

    var body: some View {
        Button(action: action) {
            ZStack {
                Image(systemName: isOn ? (onSystemImage ?? systemImage) : systemImage)
                    .symbolVariant(isOn && onSystemImage == nil ? .fill : .none)
                    .fontWeight(.semibold)
                    // A little greyed, like the link arrow on the rating buttons; while on, the colour it was given (the Play colour).
                    .foregroundStyle(isOn ? onColour ?? .white.opacity(0.6) : .white.opacity(0.6))
                    // A colour that arrives after the page opens fades in with Play's own (see `DetailActions`).
                    .animation(.smooth(duration: 0.3), value: onColour)
                    .contentTransition(.symbolEffect(.replace))
                    // Every symbol is a different width; the label fills the same square so each button is the same circle.
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .opacity(isLoading ? 0 : 1)
                if isLoading {
                    Spinner()
                        .controlSize(.small)
                        .transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(ScaledCapsule(scale: metrics.circularButtonScale(for: .actionButtons)))
            .animation(.smooth(duration: 0.25), value: isLoading)
        }
        // The large size, like the main action beside it on the title page, so the two read as one row.
        .modifier(CircleActionSizing(exact: exactSize))
        // The caption is gone, so the name is spoken here instead. Loading is part of the name, so a caller's own value is left as it is.
        .accessibilityLabel(isLoading ? "\(title), loading" : (isOn ? (onTitle ?? title) : title))
        .help(isOn ? (onTitle ?? title) : title)
        .accessibilityAddTraits(isOn ? .isSelected : [])
        // A tick when the state changes, but not when it is read in: a page that opens on a saved title is silent. The Pickers &
        // switches place, so the Haptics page reaches it.
        .onChange(of: TickState(isOn: isOn, quietRevision: quietRevision)) { old, new in
            guard old.isOn != new.isOn, old.quietRevision == new.quietRevision else { return }
            Haptics.play(.choices)
        }
    }
}

private struct CircleActionSizing: ViewModifier {
    let exact: Bool

    func body(content: Content) -> some View {
        if exact {
            content.buttonStyle(FixedGlassButtonStyle())
        } else {
            content.glassCircleButton()
                .frame(width: CircleActionButton.diameter, height: CircleActionButton.diameter)
        }
    }
}

/// A row of `CircleActionButton`s the way a title page lays them out: one glass container, even gaps, leading aligned.
struct CircleActionRow<Content: View>: View {
    var spacing: CGFloat = Theme.Spacing.xl
    @ViewBuilder let content: () -> Content

    var body: some View {
        GlassEffectContainer(spacing: spacing) {
            HStack(alignment: .top, spacing: spacing) {
                content()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
#endif
