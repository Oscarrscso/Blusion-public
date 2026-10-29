#if canImport(UIKit)
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
    let configuration: PrimitiveButtonStyleConfiguration
    let fillsWidth: Bool
    let minWidth: CGFloat
    let glass: Glass?
    let height: CGFloat?
    @Environment(\.controlSize) private var controlSize

    var body: some View {
        if let height {
            Button(role: configuration.role) {
                Haptics.tap()
                configuration.trigger()
            } label: {
                configuration.label
                    .fontWeight(.semibold)
                    .padding(.horizontal, Theme.Spacing.s)
                    .frame(minWidth: minWidth, maxWidth: fillsWidth ? .infinity : nil)
                    .frame(height: height)
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .glassEffect(glass ?? .regular.interactive(), in: .capsule)
            .pointerFeedback()
        } else {
        #if targetEnvironment(macCatalyst)
        // The Mac's own glass button is a third shorter than the round actions beside it, so the capsule is given their height: the label
        // fills the frame and the glass follows it, as a round action's does. A small one (Auto Pick) is a step down.
        Button(role: configuration.role) {
            Haptics.tap()
            configuration.trigger()
        } label: {
            configuration.label
                .fontWeight(.semibold)
                .padding(.horizontal, Theme.Spacing.s)
                .frame(minWidth: minWidth, maxWidth: fillsWidth ? .infinity : nil, maxHeight: .infinity)
        }
        .configurableGlassButtonStyle(glass)
        .buttonBorderShape(.capsule)
        .controlSize(.large)
        .frame(height: controlSize == .small || controlSize == .mini ? Self.macSmallHeight : CircleActionButton.diameter)
        .pointerFeedback()
        #else
        Button(role: configuration.role) {
            Haptics.tap()
            configuration.trigger()
        } label: {
            configuration.label
                .fontWeight(.semibold)
                .frame(maxWidth: fillsWidth ? .infinity : nil)
        }
        .configurableGlassButtonStyle(glass)
        .buttonBorderShape(.capsule)
        // A main action is one size up from the controls around it.
        .controlSize(controlSize == .regular ? .large : controlSize)
        .pointerFeedback()
        #endif
        }
    }

    #if targetEnvironment(macCatalyst)
    /// The height of a small main action on a Mac.
    static let macSmallHeight: CGFloat = 32
    #endif
}

/// A secondary action ("Customize", "Open on Best Blurays"): the system's Liquid Glass button as a label-sized capsule.
/// Do not stack it on other glass and do not use it for the screen's main action.
struct GlassCapsuleButtonStyle: PrimitiveButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button(role: configuration.role) {
            Haptics.tap()
            configuration.trigger()
        } label: {
            configuration.label
                .font(.subheadline.weight(.semibold))
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.capsule)
        .pointerFeedback()
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

    /// Makes an icon button the system's round Liquid Glass button, the one the navigation bar draws.
    func glassCircleButton(_ size: ControlSize = .large, glass: Glass? = nil) -> some View {
        configurableGlassButtonStyle(glass)
            .buttonBorderShape(.circle)
            .controlSize(size)
            .pointerFeedback()
    }
}

/// A secondary action on a title page: the system's round Liquid Glass button with its symbol and no caption. `title` ("Add",
/// "Watched", "Trailer") is its VoiceOver label. With `isOn` it shows `onSystemImage` (default: the same symbol, filled) and
/// `onTitle` ("Added"); the symbol swaps with the system replace effect. With `isLoading` the symbol gives way to a small spinner
/// in the same square, so the button keeps its size, and VoiceOver says it is loading.
///
/// Several in a row belong in one `GlassEffectContainer` (or `CircleActionRow`) so the glass is composed once.
struct CircleActionButton: View {
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
    /// The height of the large glass capsule beside it, so the circles are level with Play and equally wide. Smaller on a Mac, where a
    /// pointer needs less room than a finger and 50 points stood twice as tall as the Mac's own Play button.
    #if targetEnvironment(macCatalyst)
    static let diameter: CGFloat = 40
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
            .animation(.smooth(duration: 0.25), value: isLoading)
        }
        // The large size, like the main action beside it on the title page, so the two read as one row.
        .modifier(CircleActionSizing(exact: exactSize))
        // The caption is gone, so the name is spoken here instead. Loading is part of the name, so a caller's own value is left as it is.
        .accessibilityLabel(isLoading ? "\(title), loading" : (isOn ? (onTitle ?? title) : title))
        .help(isOn ? (onTitle ?? title) : title)
        .accessibilityAddTraits(isOn ? .isSelected : [])
        // A tick when the state changes, but not when it is read in: a page that opens on a saved title is silent.
        .sensoryFeedback(trigger: TickState(isOn: isOn, quietRevision: quietRevision)) { old, new in
            old.isOn != new.isOn && old.quietRevision == new.quietRevision ? .selection : nil
        }
    }
}

private struct CircleActionSizing: ViewModifier {
    let exact: Bool

    func body(content: Content) -> some View {
        if exact {
            content.buttonStyle(.plain)
                .frame(width: CircleActionButton.diameter, height: CircleActionButton.diameter)
                .glassEffect(.regular.interactive(), in: .circle)
                .pointerFeedback()
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
