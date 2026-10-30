#if canImport(UIKit)
import SwiftUI

extension View {
    /// The system's confirmation HUD: a glass tick in the middle of the screen that appears each time `trigger` changes, with a
    /// haptic and a VoiceOver announcement of `message`, then goes away on its own. Nothing shows on first appearance.
    func savedHUD(trigger: Int, message: String = "Saved") -> some View {
        modifier(SavedHUDModifier(trigger: trigger, message: message))
    }
}

@MainActor
private struct SavedHUDModifier: ViewModifier {
    let trigger: Int
    let message: String
    @State private var isShowing = false
    @State private var hideTask: Task<Void, Never>?

    /// How long the tick stays up.
    private static let duration: Duration = .milliseconds(1200)

    func body(content: Content) -> some View {
        content
            .overlay {
                if isShowing {
                    SavedHUDBadge(message: message)
                        .transition(.opacity.combined(with: .scale(scale: 0.8)))
                }
            }
            .onChange(of: trigger) {
                // The app's own success chime rather than SwiftUI's, so the Haptics page controls it with the other feels.
                Haptics.success()
                hideTask?.cancel()
                withAnimation(.spring(duration: 0.35, bounce: 0.2)) { isShowing = true }
                AccessibilityNotification.Announcement(message).post()
                hideTask = Task { @MainActor in
                    try? await Task.sleep(for: Self.duration)
                    guard !Task.isCancelled else { return }
                    withAnimation(.easeOut(duration: 0.25)) { isShowing = false }
                }
            }
            .onDisappear { hideTask?.cancel() }
    }
}

/// The badge itself: a large tick and a small label on a rounded glass square, like the system's HUD. It never takes a tap.
private struct SavedHUDBadge: View {
    let message: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "checkmark")
                .font(.system(size: 44, weight: .semibold))
            Text(message)
                .font(.subheadline.weight(.semibold))
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, 30)
        .padding(.vertical, 24)
        .frame(minWidth: 150, minHeight: 150)
        .glassEffect(.regular, in: .rect(cornerRadius: 24))
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
#endif
