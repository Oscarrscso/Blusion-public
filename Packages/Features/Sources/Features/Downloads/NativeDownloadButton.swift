#if canImport(UIKit)
import SwiftUI
import StremioKit

/// The same progress ring on stream cards, title actions, episodes and the download list.
struct DownloadProgressGlyph: View {
    let item: DownloadItem?
    var isLoading = false
    var colour: Color = .white
    var progressColour: Color = .accentColor
    var body: some View {
        ZStack {
            if isLoading || item?.state == .queued || (item?.state == .downloading && item?.expected == 0) {
                Spinner().controlSize(.small)
            } else if let item, item.state != .complete {
                Circle().stroke(.white.opacity(0.25), lineWidth: 2.5)
                Circle().trim(from: 0, to: item.fraction)
                    .stroke(progressColour, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Image(systemName: item.state == .downloading ? "pause.fill" : "arrow.down")
                    .font(.system(size: 10, weight: .bold))
            } else {
                Image(systemName: item?.state == .complete ? "checkmark" : "arrow.down")
                    .font(.subheadline.weight(.bold))
            }
        }
        .foregroundStyle(colour)
        .frame(width: 24, height: 24)
        .animation(.linear(duration: 0.25), value: item?.fraction)
    }
}

struct NativeDownloadButton: View {
    let manager: DownloadManager?
    let item: DownloadItem?
    var isLoading = false
    var isAvailable = true
    var size: CGFloat = CircleActionButton.diameter
    var matchesStream = false
    var glass: Glass?
    var progressColour: Color = .accentColor
    let start: () -> Void
    @Environment(AppRouter.self) private var router: AppRouter?

    private var title: String {
        switch item?.state {
        case .queued, .downloading: "Pause Download"
        case .paused, .failed: "Resume Download"
        case .complete: "Downloaded"
        case nil: "Download"
        }
    }
    var body: some View {
        let button = Button {
            guard let manager, isAvailable, !isLoading else { return }
            Haptics.tap()
            if let item {
                switch item.state {
                case .queued, .downloading: Task { await manager.pause(item.id) }
                case .paused, .failed: Task { await manager.resume(item.id) }
                case .complete: break
                }
            } else { start() }
        } label: {
            DownloadProgressGlyph(item: item, isLoading: isLoading, colour: glass == nil ? .white : .white.opacity(0.6),
                                  progressColour: progressColour)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Circle())
        }
        Group {
            if matchesStream {
                button.buttonStyle(.plain).background(Theme.surfaceStrong, in: Circle())
            } else if let glass {
                button.buttonStyle(.plain)
                    .frame(width: size, height: size)
                    .glassEffect(glass, in: .circle)
            } else {
                button.glassCircleButton()
            }
        }
        .frame(width: size, height: size)
        .highPriorityGesture(LongPressGesture(minimumDuration: 0.45).onEnded { _ in
            Haptics.tap()
            router?.opensDownloads = true
            router?.open(.library)
        })
        .disabled(manager == nil || !isAvailable || isLoading)
        .accessibilityLabel(isLoading ? "Download, loading" : title)
        .accessibilityValue(item.map { $0.expected > 0 ? "\(Int($0.fraction * 100)) percent" : "" } ?? "")
        .help(title)
    }
}
#endif
