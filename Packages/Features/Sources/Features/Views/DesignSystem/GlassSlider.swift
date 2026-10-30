#if canImport(UIKit)
import SwiftUI

/// A slider with a few fixed stops, drawn in Liquid Glass: a glass track and a glass thumb that follows the finger and settles on the
/// nearest stop. `value` runs from 1 to `stops`. It is one adjustable element for VoiceOver.
struct GlassSlider: View {
    @Binding var value: Int
    let stops: Int
    private let thumb: CGFloat = 32
    private let track: CGFloat = 14
    @State private var dragFraction: CGFloat?

    var body: some View {
        GeometryReader { geometry in
            let travel = max(1, geometry.size.width - thumb)
            let fraction = dragFraction ?? CGFloat(value - 1) / CGFloat(max(1, stops - 1))
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.clear)
                    .frame(height: track)
                    .glassEffect(.regular, in: .capsule)
                HStack(spacing: 0) {
                    ForEach(0..<stops, id: \.self) { index in
                        if index > 0 { Spacer(minLength: 0) }
                        Circle().fill(.white.opacity(0.45)).frame(width: 4, height: 4)
                    }
                }
                .padding(.horizontal, thumb / 2 - 2)
                .allowsHitTesting(false)
                Circle()
                    .fill(.clear)
                    .frame(width: thumb, height: thumb)
                    .glassEffect(.regular.interactive(), in: .circle)
                    .offset(x: travel * fraction)
            }
            .frame(height: thumb)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        let raw = min(max((drag.location.x - thumb / 2) / travel, 0), 1)
                        dragFraction = raw
                        let stop = Int((raw * CGFloat(stops - 1)).rounded()) + 1
                        // One tick per stop crossed, not one per pixel: a drag over three stops ticks three times.
                        if stop != value { Haptics.selection(); value = stop }
                    }
                    .onEnded { _ in
                        withAnimation(.snappy(duration: 0.2)) { dragFraction = nil }
                    }
            )
        }
        .frame(height: thumb)
        .accessibilityElement(children: .ignore)
        .accessibilityValue("\(value) of \(stops)")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: value = min(stops, value + 1)
            case .decrement: value = max(1, value - 1)
            @unknown default: break
            }
        }
    }
}
#endif
