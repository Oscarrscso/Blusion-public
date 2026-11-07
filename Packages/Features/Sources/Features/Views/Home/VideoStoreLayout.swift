#if canImport(UIKit)
import StremioKit
import SwiftUI
import UIKit

/// The coordinate space of the store's shelf: its cases' slots are kept in it, and its anchor view turns them into the window's.
private let storeShelfSpace = "videoStoreShelf"

/// `RowLayout.videoStore`: a video store's shelf. Each title stands face out in the case of its best release, as the title's mark knows
/// it: a blue Blu-ray case, or a black 4K Ultra HD one, for the disc Best Blurays names for a film; for a title with no disc, a black case
/// under the banner of the service it streams on (Netflix's red, Prime Video's blue); and a plain black case while nothing is known of it.
/// The cases are looked up whether or not posters show marks. They stand on a shelf unit under a strip of light, against a slatwall, with
/// a label for each in the channel along the shelf's front, and their sleeves catch the light as the shelf scrolls. A tap takes a case off
/// the shelf into the hand (`StoreHand`), over the whole window, to be turned over and read; its slot stands empty until it goes back.
/// VoiceOver opens the title straight away, and offers Pick Up.
struct VideoStoreLayout: View {
    let items: [MetaPreview]
    let showsRating: Bool
    @Environment(\.layoutMetrics) private var metrics
    @Environment(AppRouter.self) private var router
    @Environment(\.zoomScope) private var zoomScope
    /// Where each case stands in the shelf's space, for the flight into the hand and back.
    @State private var slots = StoreSlotFrames()
    @State private var presenter = StoreHandPresenter()
    /// The title whose case is in the hand: its slot stands empty.
    @State private var heldID: String?

    static func height(_ metrics: LayoutMetrics) -> CGFloat { StoreShelf(metrics).height }

    var body: some View {
        let shelf = StoreShelf(metrics)
        let heldID = self.heldID
        let last = items.count - 1
        ShelfScroll(margin: metrics.pageMargin, spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.identity) { index, item in
                StoreSlot(item: item, shelf: shelf, isFirst: index == 0, isLast: index == last, isHeld: item.identity == heldID,
                          showsRating: showsRating, sourceID: sourceID(item), slots: slots,
                          onPickUp: { pickUp(item) }, onOpen: { open(item, tick: true) })
                    // Picking up a case redraws only its slot.
                    .equatable()
                    .reportsShelfEdge(id: item.identity)
            }
        }
        .coordinateSpace(.named(storeShelfSpace))
        .background { StoreHandAnchor(presenter: presenter) }
    }

    private func sourceID(_ item: MetaPreview) -> String { "\(zoomScope)/\(item.identity)" }

    /// Takes the case off the shelf: the hand comes up over the window at once, with the case where it stood, and it flies up into the
    /// hand as its slot empties.
    private func pickUp(_ item: MetaPreview) {
        guard heldID == nil, !presenter.isPresenting else { return }
        let id = item.identity
        let slots = slots
        let presenter = presenter
        let hand = StoreHand(item: item, showsRating: showsRating, slotFrame: { presenter.windowFrame(of: slots.frames[id]) }) { opens in
            putBack(item, opens: opens)
        }
        guard presenter.present(hand) else { return }
        Haptics.play(.choices)
        var still = Transaction()
        still.disablesAnimations = true
        withTransaction(still) { heldID = id }
    }

    /// The case is back in its slot: the slot shows it again under the hand's copy, then the hand goes, and the title opens out of the
    /// case when the hand asked.
    private func putBack(_ item: MetaPreview, opens: Bool) {
        var still = Transaction()
        still.disablesAnimations = true
        withTransaction(still) { heldID = nil }
        presenter.dismiss {
            if opens { open(item, tick: false) }
        }
    }

    /// The title's page, zooming out of its case. `tick` false when the control that asked has given its own haptic.
    private func open(_ item: MetaPreview, tick: Bool) {
        if tick { Haptics.play(.titles) }
        router.homePath.append(TitleDestination(preview: item, sourceID: sourceID(item)))
    }
}

/// The shelf unit's measures, all from the case's width: its top trim, the wall above the cases, the cases, the shelf's top and its front
/// with the labels' channel, and the shade under it.
struct StoreShelf: Equatable {
    let caseWidth: CGFloat
    let caseHeight: CGFloat
    let fascia: CGFloat
    let headroom: CGFloat
    let plank: CGFloat
    let lip: CGFloat
    /// The room between two cases, half of it on each side of a case's slot.
    let gap: CGFloat
    let endPanel: CGFloat
    let slatPitch: CGFloat
    let caseRadius: CGFloat
    static let underShadow: CGFloat = 8

    init(_ metrics: LayoutMetrics) {
        caseWidth = (metrics.posterWidth * 1.12).rounded()
        caseHeight = StoreCase.height(forWidth: caseWidth)
        fascia = max(9, (caseWidth * 0.08).rounded())
        headroom = max(12, (caseWidth * 0.14).rounded())
        plank = max(6, (caseWidth * 0.07).rounded())
        lip = max(28, (caseWidth * 0.22).rounded())
        gap = max(10, (metrics.cardSpacing * 0.8).rounded())
        endPanel = max(8, (caseWidth * 0.08).rounded())
        slatPitch = max(14, (caseWidth * 0.18).rounded())
        caseRadius = StoreCase.cornerRadius(forWidth: caseWidth, metrics: metrics)
    }

    var height: CGFloat { fascia + headroom + caseHeight + plank + lip + Self.underShadow }
    /// A case's own shadow stays inside its slot, so the next slot's wall never cuts it off.
    var caseShadow: CGFloat { max(1, min(5, gap / 2 - 1)) }
}

/// Where each case stands in the shelf's space, by title. Kept out of the view's state: it changes on every frame of a scroll, and only the
/// hand reads it.
@MainActor
final class StoreSlotFrames {
    var frames: [String: CGRect] = [:]
}

/// One title's stretch of the shelf: the unit's trim, wall, shelf and front behind its case, its label in the channel and, at either end
/// of the row, the unit's side. Slots sit edge to edge, so the shelf runs on unbroken from one to the next. Equatable, so picking up a
/// case or scrolling redraws no other slot.
private struct StoreSlot: View, Equatable {
    let item: MetaPreview
    let shelf: StoreShelf
    let isFirst: Bool
    let isLast: Bool
    let isHeld: Bool
    let showsRating: Bool
    let sourceID: String
    let slots: StoreSlotFrames
    let onPickUp: () -> Void
    let onOpen: () -> Void
    @Environment(PosterRatingsStore.self) private var ratings: PosterRatingsStore?
    @Environment(HeroMetaStore.self) private var heroMeta: HeroMetaStore?
    @Environment(\.zoomNamespace) private var zoomNamespace
    @State private var rentalPrice: String?

    /// The frames and the actions are left out: they only ever act on this slot's own title.
    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        MainActor.assumeIsolated {
            lhs.item == rhs.item && lhs.shelf == rhs.shelf && lhs.isFirst == rhs.isFirst && lhs.isLast == rhs.isLast
                && lhs.isHeld == rhs.isHeld && lhs.showsRating == rhs.showsRating && lhs.sourceID == rhs.sourceID
        }
    }

    var body: some View {
        // Only this slot observes the title's mark, so a case that learns its kind redraws alone.
        let kind = StoreCaseKind(ratings?.ratings(for: item, includeMarks: true))
        let leading = shelf.gap / 2 + (isFirst ? shelf.endPanel : 0)
        let trailing = shelf.gap / 2 + (isLast ? shelf.endPanel : 0)
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                StoreFascia()
                    .frame(height: shelf.fascia)
                StoreWall(pitch: shelf.slatPitch)
                    .frame(height: shelf.headroom + shelf.caseHeight)
                    .overlay(alignment: .bottomLeading) {
                        // Soft contact shade behind the plastic, distinct from the sharp shadow on the plank.
                        RoundedRectangle(cornerRadius: shelf.caseRadius)
                            .fill(.black.opacity(0.45))
                            .frame(width: shelf.caseWidth, height: shelf.caseHeight * 0.96)
                            .blur(radius: shelf.caseShadow)
                            .offset(x: leading + shelf.caseShadow, y: 0)
                            .opacity(isHeld ? 0 : 1)
                            .allowsHitTesting(false)
                    }
                    .overlay(alignment: .bottomLeading) {
                        caseButton(kind)
                            .padding(.leading, leading)
                    }
                StorePlank()
                    .frame(height: shelf.plank)
                    .overlay(alignment: .topLeading) {
                        // The case's shade on the shelf, which goes with it.
                        LinearGradient(colors: [.black.opacity(0.5), .clear], startPoint: .top, endPoint: .bottom)
                            .frame(width: shelf.caseWidth, height: (shelf.plank * 0.8).rounded())
                            .padding(.leading, leading)
                            .opacity(isHeld ? 0 : 1)
                    }
                StoreLip()
                    .frame(height: shelf.lip)
                    .overlay(alignment: .leading) {
                        StoreTag(name: item.name, rating: showsRating ? item.imdbRating : nil, rentalPrice: rentalPrice)
                            .frame(width: (shelf.caseWidth * 0.94).rounded(), height: max(18, shelf.lip - 9))
                            .frame(width: shelf.caseWidth)
                            .padding(.leading, leading)
                    }
            }
            .overlay(alignment: .leading) {
                if isFirst { StoreEndPanel(width: shelf.endPanel, isLeading: true) }
            }
            .overlay(alignment: .trailing) {
                if isLast { StoreEndPanel(width: shelf.endPanel, isLeading: false) }
            }
            LinearGradient(colors: [.black.opacity(0.4), .clear], startPoint: .top, endPoint: .bottom)
                .frame(height: StoreShelf.underShadow)
                .accessibilityHidden(true)
        }
        .frame(width: leading + shelf.caseWidth + trailing)
        .task(id: item.identity) {
            let prices = await heroMeta?.prices(for: item)
            guard !Task.isCancelled else { return }
            rentalPrice = prices?.bestRent?.priceText
        }
    }

    private func caseButton(_ kind: StoreCaseKind) -> some View {
        Button(action: onPickUp) {
            StoreCaseFront(item: item, kind: kind, width: shelf.caseWidth, glareFollowsScroll: true)
                // One shadow for the whole case, not one for each of its layers.
                .compositingGroup()
                .shadow(color: .black.opacity(0.55), radius: shelf.caseShadow, y: 1)
                .zoomSource(id: sourceID, in: zoomNamespace, cornerRadius: shelf.caseRadius)
        }
        .buttonStyle(PressableCardStyle.poster)
        .prewarmsHeroArtwork(item)
        .help(item.name)
        .titleCardMenu(item)
        .accessibilityLabel(item.name)
        .accessibilityValue([kind.spokenName, rentalPrice.map { "Rental: \($0)" } ?? ""]
            .filter { !$0.isEmpty }.joined(separator: ", "))
        // VoiceOver opens the title straight away; picking the case up is offered beside it.
        .accessibilityAction(.default) { onOpen() }
        .accessibilityAction(named: "Pick Up") { onPickUp() }
        .opacity(isHeld ? 0 : 1)
        .allowsHitTesting(!isHeld)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(storeShelfSpace)) } action: { slots.frames[item.identity] = $0 }
    }
}

// MARK: - The shelf unit

/// Cobalt powder-coated trim, with a warm strip of light tucked under its lower edge.
private struct StoreFascia: View {
    var body: some View {
        LinearGradient(colors: [Color(red: 0.19, green: 0.39, blue: 0.76), Color(red: 0.07, green: 0.18, blue: 0.43)],
                       startPoint: .top, endPoint: .bottom)
            .overlay(alignment: .top) {
                Rectangle().fill(.white.opacity(0.28)).frame(height: 0.5)
            }
            .overlay(alignment: .bottom) {
                Rectangle().fill(.black.opacity(0.65)).frame(height: 2)
                    .overlay(alignment: .top) {
                        Rectangle().fill(Color(red: 1, green: 0.94, blue: 0.76)).frame(height: 0.75)
                    }
            }
            .accessibilityHidden(true)
    }
}

/// The slatwall behind the cases: dark panels with a groove every `pitch`, lit from the strip above and darker towards the shelf.
private struct StoreWall: View {
    let pitch: CGFloat

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(white: 0.23), Color(white: 0.15), Color(white: 0.09)], startPoint: .top, endPoint: .bottom)
            StoreSlats(pitch: pitch, isLitEdge: false).fill(.black.opacity(0.65))
            StoreSlats(pitch: pitch, isLitEdge: true).fill(.white.opacity(0.12))
            LinearGradient(colors: [Color(red: 1, green: 0.92, blue: 0.77).opacity(0.13), .clear], startPoint: .top,
                           endPoint: UnitPoint(x: 0.5, y: 0.55))
            LinearGradient(colors: [.clear, .black.opacity(0.32)], startPoint: .center, endPoint: .bottom)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// The slatwall's grooves: each groove's shadow, or the lit edge just under it. Every slot's wall starts at the same height, so the grooves
/// run straight on from one slot to the next.
private struct StoreSlats: Shape {
    let pitch: CGFloat
    let isLitEdge: Bool

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard pitch > 0 else { return path }
        var y = rect.minY + pitch * 0.5 + (isLitEdge ? 1.5 : 0)
        while y < rect.maxY {
            path.addRect(CGRect(x: rect.minX, y: y, width: rect.width, height: isLitEdge ? 0.75 : 1.5))
            y += pitch
        }
        return path
    }
}

/// The shelf's top, seen a little from above: darker at the back, where the wall shades it, lighter at its front edge.
private struct StorePlank: View {
    var body: some View {
        LinearGradient(stops: [
            .init(color: Color(red: 0.06, green: 0.14, blue: 0.33), location: 0),
            .init(color: Color(red: 0.11, green: 0.28, blue: 0.59), location: 0.6),
            .init(color: Color(red: 0.25, green: 0.46, blue: 0.82), location: 1),
        ], startPoint: .top, endPoint: .bottom)
            .overlay(alignment: .top) {
                Rectangle().fill(.black.opacity(0.65)).frame(height: 1)
            }
            .overlay(alignment: .bottom) {
                Rectangle().fill(.white.opacity(0.4)).frame(height: 0.5)
            }
            .accessibilityHidden(true)
    }
}

/// The blue label rail ends in the rental store's narrow yellow stripe.
private struct StoreLip: View {
    var body: some View {
        LinearGradient(colors: [Color(red: 0.14, green: 0.32, blue: 0.66), Color(red: 0.07, green: 0.18, blue: 0.43)],
                       startPoint: .top, endPoint: .bottom)
            .overlay(alignment: .top) {
                Rectangle().fill(.black.opacity(0.55)).frame(height: 1)
            }
            .overlay(alignment: .bottom) {
                LinearGradient(colors: [Color(red: 1, green: 0.87, blue: 0.22), Color(red: 0.91, green: 0.66, blue: 0.06)],
                               startPoint: .top, endPoint: .bottom)
                    .frame(height: 3)
                    .overlay(alignment: .top) {
                        Rectangle().fill(.white.opacity(0.35)).frame(height: 0.5)
                    }
            }
            .accessibilityHidden(true)
    }
}

/// The side of the shelf unit at either end of the row, its lit face looking into the row.
private struct StoreEndPanel: View {
    let width: CGFloat
    let isLeading: Bool

    var body: some View {
        let dark = Color(red: 0.05, green: 0.13, blue: 0.31), light = Color(red: 0.16, green: 0.35, blue: 0.69)
        LinearGradient(colors: isLeading ? [dark, light] : [light, dark], startPoint: .leading, endPoint: .trailing)
            .overlay(alignment: isLeading ? .trailing : .leading) {
                Rectangle().fill(.black.opacity(0.5)).frame(width: 1)
            }
            .frame(width: width)
            .clipShape(UnevenRoundedRectangle(topLeadingRadius: isLeading ? 3 : 0, topTrailingRadius: isLeading ? 0 : 3,
                                              style: .continuous))
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// The shelf label: title, score and the regional rental price when available.
private struct StoreTag: View {
    let name: String
    let rating: Double?
    let rentalPrice: String?

    var body: some View {
        HStack(spacing: 3) {
            Text(name)
                .textCase(.uppercase)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .frame(maxWidth: .infinity, alignment: rating == nil && rentalPrice == nil ? .center : .leading)
            if let rating {
                Text(verbatim: "★ \(ScoreText.wholeScore(rating))")
                    .fixedSize()
            }
            if let rentalPrice {
                Text(rentalPrice)
                    .fixedSize()
            }
        }
        .font(.caption2.weight(.heavy).width(.condensed))
        .monospacedDigit()
        .foregroundStyle(Color(red: 0.12, green: 0.10, blue: 0.07))
        .padding(.horizontal, 5)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(LinearGradient(colors: [Color(red: 1, green: 0.97, blue: 0.87), Color(red: 0.92, green: 0.87, blue: 0.75)],
                                     startPoint: .top, endPoint: .bottom))
                .overlay {
                    RoundedRectangle(cornerRadius: 1.5).strokeBorder(.black.opacity(0.3), lineWidth: 0.5)
                }
                .shadow(color: .black.opacity(0.45), radius: 1, y: 1)
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Taking a case off the shelf

/// Shows the hand over the whole window, above Home, from wherever the shelf is drawn: a SwiftUI row on iPhone, or a cell of the Mac's
/// UIKit Home, which has no view controller of its own to present from. The hand takes the shelf's environment, as the Mac's cells do.
@MainActor
final class StoreHandPresenter {
    /// A view the shelf's size and place, in the window.
    weak var anchor: UIView?
    /// The shelf's environment, kept up to date by the anchor.
    var environment: EnvironmentValues?
    private weak var controller: UIViewController?

    var isPresenting: Bool { controller != nil }

    /// `rect`, in the shelf's own space, in the window's.
    func windowFrame(of rect: CGRect?) -> CGRect? {
        guard let rect, let anchor, anchor.window != nil else { return nil }
        return anchor.convert(rect, to: nil)
    }

    /// Puts `content` over the window with no animation of its own: the content animates itself. False when there is no window yet or
    /// something is already shown.
    func present(_ content: some View) -> Bool {
        guard controller == nil, let environment, let root = anchor?.window?.rootViewController else { return false }
        var top = root
        while let next = top.presentedViewController, !next.isBeingDismissed { top = next }
        let host = UIHostingController(rootView: AnyView(content.environment(\.self, environment)))
        host.view.backgroundColor = .clear
        host.modalPresentationStyle = .overFullScreen
        controller = host
        top.present(host, animated: false)
        return true
    }

    /// Takes the content away at once, then calls `completion`.
    func dismiss(then completion: @escaping @MainActor () -> Void) {
        guard let controller else {
            completion()
            return
        }
        self.controller = nil
        controller.dismiss(animated: false) { completion() }
    }
}

/// A view that stands where the shelf stands, so its slots can be found on the window, and that hands the shelf's environment to the
/// presenter.
private struct StoreHandAnchor: UIViewRepresentable {
    let presenter: StoreHandPresenter

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        presenter.anchor = view
        presenter.environment = context.environment
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        presenter.anchor = view
        presenter.environment = context.environment
    }
}
#endif
