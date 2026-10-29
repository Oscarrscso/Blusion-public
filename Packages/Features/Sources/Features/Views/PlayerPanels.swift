#if canImport(UIKit)
#if os(iOS) && !targetEnvironment(macCatalyst)
import AVFoundation
@preconcurrency import MediaPlayer
#endif
import PlayerKit
import StremioKit
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// A brightness or volume level being set by a swipe.
struct SwipeLevel: Equatable {
    enum Kind { case brightness, volume }
    let kind: Kind
    let value: Double
}

struct SwipeLevelIndicator: View {
    let level: SwipeLevel

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: level.kind == .brightness ? "sun.max.fill" : level.value == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                .frame(width: 24)
            ProgressView(value: level.value).tint(.white).frame(width: 140)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .glassEffect(.regular, in: .capsule)
        .foregroundStyle(.white)
        .frame(maxHeight: .infinity, alignment: .top)
        .padding(.top, 40)
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(level.kind == .brightness ? "Brightness" : "Volume")
        .accessibilityValue("\(Int(level.value * 100)) percent")
        .accessibilityIdentifier("player.swipeLevel")
    }
}

/// The screen the player is on. iOS keeps a brightness the app sets until the screen locks.
@MainActor
enum ScreenBrightness {
    private static var screen: UIScreen? {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first { $0.activationState == .foregroundActive }?.screen
    }

    static var value: CGFloat {
        get { screen?.brightness ?? 0.5 }
        set { screen?.brightness = min(1, max(0, newValue)) }
    }
}

#if os(iOS) && !targetEnvironment(macCatalyst)
/// Keeps the system volume control mounted while picture swipes drive its slider.
@MainActor
final class SystemVolume {
    let view = MPVolumeView(frame: CGRect(x: 0, y: 0, width: 150, height: 32))

    var value: Double {
        get { Double(AVAudioSession.sharedInstance().outputVolume) }
        set {
            guard let slider = view.subviews.compactMap({ $0 as? UISlider }).first else { return }
            slider.setValue(Float(min(1, max(0, newValue))), animated: false)
            slider.sendActions(for: .valueChanged)
        }
    }
}

struct SystemVolumeControl: UIViewRepresentable {
    let volume: SystemVolume

    func makeUIView(context: Context) -> MPVolumeView {
        volume.view
    }

    func updateUIView(_ view: MPVolumeView, context: Context) {}
}
#endif

enum SubtitleFileTypes {
    static let subtitles: [UTType] = ["srt", "vtt", "ass", "ssa", "sup"].compactMap { UTType(filenameExtension: $0) } + [.plainText]
    static let audio: [UTType] = [.audio, .mpeg4Audio, .mp3, .wav] + ["ac3", "eac3", "mka", "flac", "dts", "thd", "opus"]
        .compactMap { UTType(filenameExtension: $0) }
}

/// Search results from OpenSubtitles.com for this title, matched to the stream's hash when it is known. A tap downloads and selects one.
struct OpenSubtitlesSheet: View {
    let model: PlayerViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if let status = model.openSubtitlesStatus {
                    Text(status).foregroundStyle(.secondary).accessibilityIdentifier("opensubtitles.status")
                }
                ForEach(model.openSubtitlesResults) { result in
                    Button {
                        Task {
                            await model.downloadOpenSubtitle(result)
                            if case .external = model.subtitleChoice { dismiss() }
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 6) {
                                Text(LanguageCodes.displayName(result.language)).font(.headline)
                                if result.matchesHash { tag("Matches this file", .green) }
                                if result.isHearingImpaired { tag("SDH", .secondary) }
                                if result.isForeignPartsOnly { tag("Forced", .secondary) }
                                if result.isMachineTranslated { tag("Machine translated", .orange) }
                            }
                            Text(result.release).font(.footnote).foregroundStyle(.secondary).lineLimit(2)
                            Text("\(result.downloadCount.formatted()) downloads").font(.caption).foregroundStyle(.tertiary)
                        }
                    }
                    .accessibilityIdentifier("opensubtitles.result")
                }
            }
            .overlay {
                if model.isSearchingOpenSubtitles { Spinner().controlSize(.large) }
            }
            .navigationTitle("OpenSubtitles")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
            }
        }
        .task { await model.searchOpenSubtitles() }
    }

    private func tag(_ text: String, _ colour: Color) -> some View {
        Text(text).font(.caption2.weight(.semibold)).padding(.horizontal, 6).padding(.vertical, 2)
            .background(colour.opacity(0.2), in: .capsule).foregroundStyle(colour)
    }
}
#endif
