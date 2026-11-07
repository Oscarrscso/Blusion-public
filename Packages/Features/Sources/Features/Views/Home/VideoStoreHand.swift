#if canImport(UIKit)
import StremioKit
import SwiftUI
import UIKit

/// The video store's case in the hand, over the whole window. It lifts out of its slot on the shelf and flies up, turning a little as it
/// comes, while Home dims and blurs behind it. A sideways drag turns it with the finger, in perspective, past its spine to its back and on
/// round; let go, it settles on whichever side it was thrown towards. A tap on it, or Turn Over, turns it over. View Title flies it back to
/// its slot and opens its title from there; Put Back, a tap beside it or Escape flies it back. With Reduce Motion it fades in and out where it
/// is held and turns over at once.
struct StoreHand: View {
    let item: MetaPreview
    let showsRating: Bool
    /// The case's slot on the window, asked again for the flight back, in case the shelf has moved.
    let slotFrame: () -> CGRect?
    /// Called once the case is back in its slot: true when its title should open.
    let onDone: (_ opens: Bool) -> Void
    @Environment(PosterRatingsStore.self) private var ratings: PosterRatingsStore?
    @Environment(HeroMetaStore.self) private var heroMeta: HeroMetaStore?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.layoutMetrics) private var metrics
    /// 0 in the slot, 1 in the hand.
    @State private var progress: Double = 0
    /// How far the case is turned about its upright middle: 0 shows the front, π the back.
    @State private var angle: Double = 0
    /// Reduce Motion only: how far the case and the dimming have faded in.
    @State private var presence: Double = 0
    @State private var dragStart: Double?
    @State private var isLeaving = false
    @State private var certification: String?
    @State private var prices: TitlePrices?
    @State private var isLoadingPrices = true
    /// The poster at the size the hand shows it: at first whatever size the shelf decoded, so it is there in the first frame.
    @State private var picture: UIImage?

    init(item: MetaPreview, showsRating: Bool, slotFrame: @escaping () -> CGRect?, onDone: @escaping (_ opens: Bool) -> Void) {
        self.item = item
        self.showsRating = showsRating
        self.slotFrame = slotFrame
        self.onDone = onDone
        _picture = State(initialValue: PosterQuality.poster(for: item).flatMap { ImagePipeline.shared.cachedImageAtAnySize(for: $0) })
    }

    var body: some View {
        let kind = StoreCaseKind(ratings?.ratings(for: item, includeMarks: true))
        let details = heroMeta?.preview(for: item) ?? item
        let shown = reduceMotion ? presence : min(max(progress, 0), 1)
        GeometryReader { proxy in
            let layout = StoreHandLayout(size: proxy.size)
            let origin = proxy.frame(in: .global).origin
            let slot = reduceMotion ? nil : slotFrame().map { $0.offsetBy(dx: -origin.x, dy: -origin.y) }
            ZStack(alignment: .topLeading) {
                StoreHeldCase(item: details, kind: kind, width: layout.width, showsRating: showsRating, certification: certification,
                              picture: picture, slot: slot, centre: layout.centre, angle: angle, progress: reduceMotion ? 1 : progress)
                    .opacity(reduceMotion ? presence : 1)
                    .allowsHitTesting(false)
                caseArea(layout: layout, kind: kind)
                information(details: details, kind: kind)
                    .frame(width: layout.information.width, height: layout.information.height)
                    .position(x: layout.information.midX, y: layout.information.midY)
                    .opacity(shown)
                    .allowsHitTesting(!isLeaving)
                controls(layout: layout)
                    .opacity(shown)
                    .allowsHitTesting(!isLeaving)
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
        }
        .background {
            Rectangle()
                .fill(.ultraThinMaterial)
                .overlay { Color.black.opacity(0.4) }
                .opacity(shown)
                .ignoresSafeArea()
                .onTapGesture { leave(opens: false) }
                .accessibilityHidden(true)
        }
        .accessibilityAction(.escape) { leave(opens: false) }
        .onAppear(perform: arrive)
        .task(id: item.identity) { await loadPicture() }
        .task(id: item.identity) { await loadCertification() }
        .task(id: item.identity) {
            await heroMeta?.load(for: item)
            guard !Task.isCancelled else { return }
            prices = await heroMeta?.prices(for: item)
            guard !Task.isCancelled else { return }
            isLoadingPrices = false
        }
    }

    private func information(details: MetaPreview, kind: StoreCaseKind) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.m) {
                HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.m) {
                    Text(details.name)
                        .font(.title2.bold())
                        .accessibilityAddTraits(.isHeader)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if showsRating, let ratings {
                        RatingsLine(ratings: ratings.ratings(for: details, includeReviews: true), font: .subheadline.weight(.semibold))
                            .fixedSize()
                    }
                }
                let metadata = [layoutDetailLine(details, showsRating: false), details.runtime ?? "",
                                kind.spokenName].filter { !$0.isEmpty }.joined(separator: " · ")
                if !metadata.isEmpty {
                    Text(metadata)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                if isLoadingPrices {
                    ProgressView().accessibilityLabel("Loading prices")
                }
                if let prices {
                    ForEach(TitlePrices.Kind.allCases, id: \.self) { kind in
                        ForEach(TitlePrices.Quality.allCases.reversed(), id: \.self) { quality in
                            if let offer = prices.cheapest(kind, quality).first {
                                LabeledContent("\(quality.label) \(kind.label)") {
                                    VStack(alignment: .trailing, spacing: 2) {
                                        Text(offer.priceText).fontWeight(.semibold).monospacedDigit()
                                        Text(offer.store).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                    if !prices.streamers.isEmpty {
                        LabeledContent("Streaming", value: prices.streamers.joined(separator: ", "))
                    }
                }
                if let synopsis = details.description, !synopsis.isEmpty {
                    Text(synopsis)
                        .font(.body)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.trailing, Theme.Spacing.s)
        }
        .scrollIndicatorsFlash(onAppear: true)
        .foregroundStyle(.white)
    }

    /// Where the case is held: it takes a tap to turn over and a drag to turn with the finger, and is one element for VoiceOver.
    private func caseArea(layout: StoreHandLayout, kind: StoreCaseKind) -> some View {
        let height = StoreCase.height(forWidth: layout.width)
        let showsBack = cos(angle) < 0
        let synopsis = (heroMeta?.preview(for: item) ?? item).description?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return Color.clear
            .frame(width: layout.width, height: height)
            .contentShape(Rectangle())
            .pointerInteraction(cornerRadius: StoreCase.cornerRadius(forWidth: layout.width, metrics: metrics))
            .onTapGesture(perform: turnOver)
            .gesture(turning(width: layout.width))
            .allowsHitTesting(!isLeaving)
            .accessibilityElement()
            .accessibilityLabel(item.name)
            .accessibilityValue([showsBack ? synopsis : kind.spokenName, certification.map { "Irish age rating \($0)" } ?? ""]
                .filter { !$0.isEmpty }.joined(separator: ", "))
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { turnOver() }
            .accessibilityAction(named: "View Title") { leave(opens: true) }
            .position(layout.centre)
    }

    /// The native actions stay below the information, separate from the case's turning gesture.
    private func controls(layout: StoreHandLayout) -> some View {
        GlassEffectContainer {
            HStack(spacing: Theme.Spacing.m) { buttons }
        }
        .position(layout.controls)
    }

    @ViewBuilder
    private var buttons: some View {
        Button(action: turnOver) {
            Image(systemName: "rotate.3d")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white.opacity(0.85))
        }
        .buttonStyle(FixedGlassButtonStyle())
        .help("Turn Over")
        .accessibilityLabel("Turn Over")
        .keyboardShortcut(.rightArrow, modifiers: [])
        Button("View Title") { leave(opens: true) }
            .buttonStyle(.primaryActionCompact)
            .keyboardShortcut(.defaultAction)
        Button {
            leave(opens: false)
        } label: {
            Image(systemName: "xmark")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white.opacity(0.85))
        }
        .buttonStyle(FixedGlassButtonStyle())
        .keyboardShortcut(.cancelAction)
        .help("Put Back")
        .accessibilityLabel("Put Back")
    }

    /// A sideways drag turns the case with the finger: across the case's width is half a turn. Let go, it settles on the side it was thrown
    /// towards, at most one side on from where the drag began.
    private func turning(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 6)
            .onChanged { value in
                guard !isLeaving else { return }
                let start = dragStart ?? angle
                if dragStart == nil { dragStart = start }
                angle = start + Double(value.translation.width / max(width, 1)) * .pi
            }
            .onEnded { value in
                guard let start = dragStart else { return }
                dragStart = nil
                let resting = (start / .pi).rounded() * .pi
                let thrown = start + Double(value.predictedEndTranslation.width / max(width, 1)) * .pi
                let target = min(max((thrown / .pi).rounded() * .pi, resting - .pi), resting + .pi)
                if target != resting { Haptics.play(.choices) }
                settle(at: target)
            }
    }

    private func turnOver() {
        guard !isLeaving else { return }
        Haptics.play(.choices)
        settle(at: ((angle / .pi).rounded() + 1) * .pi)
    }

    private func settle(at target: Double) {
        if reduceMotion {
            angle = target
        } else {
            withAnimation(.spring(response: 0.42, dampingFraction: 0.88)) { angle = target }
        }
    }

    private func arrive() {
        if reduceMotion {
            withAnimation(.easeOut(duration: 0.2)) { presence = 1 }
        } else {
            withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) { progress = 1 }
        }
    }

    /// Flies the case back to its slot, front out, and hands over once it is there. View Title gives its own haptic.
    private func leave(opens: Bool) {
        guard !isLeaving else { return }
        isLeaving = true
        if !opens { Haptics.play(.choices) }
        let front = (angle / (2 * .pi)).rounded() * 2 * .pi
        let duration: Duration
        if reduceMotion {
            duration = .milliseconds(200)
            withAnimation(.easeIn(duration: 0.18)) { presence = 0 }
        } else {
            duration = .milliseconds(430)
            withAnimation(.spring(response: 0.42, dampingFraction: 0.9)) {
                progress = 0
                angle = front
            }
        }
        Task { @MainActor in
            try? await Task.sleep(for: duration)
            onDone(opens)
        }
    }

    /// The poster at the hand's size, in place of the shelf's smaller one once it has decoded.
    private func loadPicture() async {
        guard let url = PosterQuality.poster(for: item) else { return }
        guard let full = try? await ImagePipeline.shared.image(for: url, maxPixelSize: 1200), !Task.isCancelled else { return }
        picture = full
    }

    /// The Irish certificate for the case, kept separately from the heroes' US certificates.
    private func loadCertification() async {
        guard let ratings else { return }
        if let known = ratings.cachedCertification(for: item, region: "IE") {
            certification = known
            return
        }
        let answer = await ratings.certification(for: item, region: "IE")
        guard !Task.isCancelled else { return }
        certification = answer
    }
}

/// The case beside its scrollable details in a wide window, or above them on a phone. Prices loading never move the case or buttons.
@MainActor
private struct StoreHandLayout {
    let width: CGFloat
    let centre: CGPoint
    let controls: CGPoint
    let information: CGRect

    init(size: CGSize) {
        let button = CircleActionButton.diameter
        let margin: CGFloat = 24
        if size.width > size.height * 1.2 {
            let column = min(360, size.width * 0.42)
            let gap: CGFloat = 32
            let fitted = min((size.height - margin * 2) / StoreCase.aspect, size.width - column - gap - margin * 2, 520)
            width = max(80, fitted.rounded())
            let left = max(margin, (size.width - width - gap - column) / 2)
            centre = CGPoint(x: left + width / 2, y: size.height / 2)
            information = CGRect(x: left + width + gap, y: margin, width: column,
                                 height: max(40, size.height - margin * 3 - button))
            controls = CGPoint(x: information.midX, y: size.height - margin - button / 2)
        } else {
            let informationHeight = min(230, size.height * 0.28)
            let fitted = min(size.width - margin * 2, (size.height - informationHeight - button - margin * 4) / StoreCase.aspect, 520)
            width = max(80, fitted.rounded())
            let caseHeight = StoreCase.height(forWidth: width)
            let top = max(margin, (size.height - caseHeight - informationHeight - button - margin * 2) / 2)
            centre = CGPoint(x: size.width / 2, y: top + caseHeight / 2)
            information = CGRect(x: margin, y: top + caseHeight + margin, width: size.width - margin * 2, height: informationHeight)
            controls = CGPoint(x: size.width / 2, y: information.maxY + margin + button / 2)
        }
    }
}

/// The case in the hand, drawn as a box: its front, back, spine and opening side, each where it falls as the case turns. Animatable in its
/// turn and its flight, so each frame of either places the faces afresh; the faces themselves are drawn once. On its way out of the slot
/// and back it rises a little and turns towards its spine, as a case does when it is pulled from a shelf.
private struct StoreHeldCase: View, Animatable {
    let item: MetaPreview
    let kind: StoreCaseKind
    let width: CGFloat
    let showsRating: Bool
    let certification: String?
    let picture: UIImage?
    /// The slot on the shelf, in the hand's space; nil flies from the middle.
    let slot: CGRect?
    let centre: CGPoint
    private var angle: Double
    private var progress: Double
    @Environment(\.layoutMetrics) private var metrics

    init(item: MetaPreview, kind: StoreCaseKind, width: CGFloat, showsRating: Bool, certification: String?, picture: UIImage?,
         slot: CGRect?, centre: CGPoint, angle: Double, progress: Double) {
        self.item = item
        self.kind = kind
        self.width = width
        self.showsRating = showsRating
        self.certification = certification
        self.picture = picture
        self.slot = slot
        self.centre = centre
        self.angle = angle
        self.progress = progress
    }

    /// Not tied to the main actor, as `Animatable` asks: it only reads and writes the view's own numbers.
    nonisolated var animatableData: AnimatablePair<Double, Double> {
        get { AnimatablePair(angle, progress) }
        set {
            angle = newValue.first
            progress = newValue.second
        }
    }

    var body: some View {
        let height = StoreCase.height(forWidth: width)
        let depth = StoreCase.depth(forWidth: width)
        let p = CGFloat(progress)
        // Highest, and turned furthest, halfway between the slot and the hand.
        let midway = sin(min(max(progress, 0), 1) * .pi)
        let turned = angle + midway * 0.42
        let startScale = slot.map { $0.width / width } ?? 0.5
        let start = slot.map { CGPoint(x: $0.midX, y: $0.midY) } ?? centre
        let scale = startScale + (1 - startScale) * p
        let place = CGPoint(x: start.x + (centre.x - start.x) * p,
                            y: start.y + (centre.y - start.y) * p - CGFloat(midway) * height * 0.12)
        let radius = StoreCase.cornerRadius(forWidth: width, metrics: metrics)
        let lifted = min(max(p, 0), 1)
        ZStack {
            face(.front, turned, height: height, depth: depth) {
                StoreCaseFront(item: item, kind: kind, width: width, picture: picture)
                    .equatable()
                    .overlay {
                        // The light stays where it is as the case turns, so its streak slides across the sleeve.
                        StoreGlare(width: width, height: height)
                            .offset(x: -CGFloat(sin(turned)) * width * 0.9)
                            .opacity(Double(lifted))
                            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
                    }
            }
            face(.back, turned, height: height, depth: depth) {
                StoreCaseBack(item: item, kind: kind, width: width, showsRating: showsRating, certification: certification)
                    .equatable()
            }
            face(.spine, turned, height: height, depth: depth) {
                StoreCaseSpine(item: item, kind: kind, width: width)
                    .equatable()
            }
            face(.edge, turned, height: height, depth: depth) {
                StoreCaseEdge(kind: kind, width: width)
                    .equatable()
            }
        }
        .frame(width: width, height: height)
        // One shadow for the whole box, growing as it comes off the shelf.
        .compositingGroup()
        .shadow(color: .black.opacity(0.35 + 0.25 * Double(lifted)), radius: 4 + 26 * lifted, y: 2 + 18 * lifted)
        .scaleEffect(scale)
        .position(place)
        .accessibilityHidden(true)
    }

    /// One face, carried to where it falls on the turned box, shaded as it turns from the light, and hidden while it faces away.
    private func face<Content: View>(_ side: StoreCaseFace, _ angle: Double, height: CGFloat, depth: CGFloat,
                                     @ViewBuilder content: () -> Content) -> some View {
        let geometry = StoreCaseFaceGeometry(side, angle: angle, width: width, height: height, depth: depth)
        return content()
            .brightness(-geometry.shade)
            .projectionEffect(geometry.transform)
            .opacity(geometry.isFacing ? 1 : 0)
    }
}
#endif
