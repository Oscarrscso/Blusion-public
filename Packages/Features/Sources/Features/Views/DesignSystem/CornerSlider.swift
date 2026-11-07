#if canImport(UIKit)
import SwiftUI
import UIKit

/// Keeps native slider interaction while giving a reshaped thumb Other Buttons' corners.
struct CornerSlider: View {
    @Environment(\.layoutMetrics) private var metrics
    @Environment(\.appAppearance) private var appearance
    @Binding var value: Double
    let bounds: ClosedRange<Double>
    var step: Double?
    let tint: Color?
    var onEditingChanged: (Bool) -> Void

    init(value: Binding<Double>, in bounds: ClosedRange<Double>, step: Double? = nil, tint: Color? = nil,
         onEditingChanged: @escaping (Bool) -> Void = { _ in }) {
        _value = value
        self.bounds = bounds
        self.step = step
        self.tint = tint
        self.onEditingChanged = onEditingChanged
    }

    var body: some View {
        if metrics.circularButtonScale(for: .actionButtons) == 1 {
            if let step {
                Slider(value: $value, in: bounds, step: step, onEditingChanged: onEditingChanged)
                    .tint(tint ?? appearance.accentColour)
            } else {
                Slider(value: $value, in: bounds, onEditingChanged: onEditingChanged)
                    .tint(tint ?? appearance.accentColour)
            }
        } else {
            NativeCornerSlider(value: $value, bounds: bounds, step: step,
                               cornerScale: metrics.circularButtonScale(for: .actionButtons),
                               tint: tint ?? appearance.accentColour ?? .accentColor,
                               onEditingChanged: onEditingChanged)
                .frame(height: 32)
        }
    }
}

private struct NativeCornerSlider: UIViewRepresentable {
    @Environment(\.isEnabled) private var isEnabled
    @Binding var value: Double
    let bounds: ClosedRange<Double>
    let step: Double?
    let cornerScale: CGFloat
    let tint: Color
    let onEditingChanged: (Bool) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> CornerThumbSlider {
        let slider = CornerThumbSlider()
        slider.addTarget(context.coordinator, action: #selector(Coordinator.changed(_:)), for: .valueChanged)
        slider.addTarget(context.coordinator, action: #selector(Coordinator.began), for: .touchDown)
        slider.addTarget(context.coordinator, action: #selector(Coordinator.ended), for: [.touchUpInside, .touchUpOutside, .touchCancel])
        return slider
    }

    func updateUIView(_ slider: CornerThumbSlider, context: Context) {
        context.coordinator.parent = self
        slider.minimumValue = Float(bounds.lowerBound)
        slider.maximumValue = Float(bounds.upperBound)
        slider.step = step.map { Float($0) }
        slider.isEnabled = isEnabled
        slider.minimumTrackTintColor = UIColor(tint)
        if !slider.isTracking { slider.setValue(Float(value), animated: false) }
        slider.glassThumb.cornerConfiguration = .corners(radius: .fixed(Double(16 * min(cornerScale, 1))))
        slider.glassThumb.alpha = isEnabled ? 1 : 0.4
        slider.setNeedsLayout()
    }

    final class Coordinator: NSObject {
        var parent: NativeCornerSlider
        init(_ parent: NativeCornerSlider) { self.parent = parent }

        @objc func began() { parent.onEditingChanged(true) }
        @objc func ended() { parent.onEditingChanged(false) }
        @objc func changed(_ slider: UISlider) {
            var value = Double(slider.value)
            if let step = parent.step {
                value = parent.bounds.lowerBound + ((value - parent.bounds.lowerBound) / step).rounded() * step
            }
            value = min(max(value, parent.bounds.lowerBound), parent.bounds.upperBound)
            slider.setValue(Float(value), animated: false)
            slider.setNeedsLayout()
            parent.value = value
        }
    }
}

/// Uses public thumb geometry and glass APIs; UISlider still owns dragging, keyboard and VoiceOver input.
private final class CornerThumbSlider: UISlider {
    let glassThumb = UIVisualEffectView(effect: UIGlassEffect(style: .regular))
    var step: Float?

    override init(frame: CGRect) {
        super.init(frame: frame)
        #if targetEnvironment(macCatalyst)
        preferredBehavioralStyle = .pad
        #endif
        let clearThumb = UIGraphicsImageRenderer(size: CGSize(width: 32, height: 32)).image { _ in }
        setThumbImage(clearThumb, for: .normal)
        setThumbImage(clearThumb, for: .highlighted)
        glassThumb.isUserInteractionEnabled = false
        glassThumb.isAccessibilityElement = false
        addSubview(glassThumb)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        glassThumb.frame = thumbRect(forBounds: bounds, trackRect: trackRect(forBounds: bounds), value: value)
        bringSubviewToFront(glassThumb)
    }

    override func accessibilityIncrement() {
        guard let step else { super.accessibilityIncrement(); return }
        setValue(min(maximumValue, value + step), animated: false)
        sendActions(for: .valueChanged)
    }

    override func accessibilityDecrement() {
        guard let step else { super.accessibilityDecrement(); return }
        setValue(max(minimumValue, value - step), animated: false)
        sendActions(for: .valueChanged)
    }
}
#endif
