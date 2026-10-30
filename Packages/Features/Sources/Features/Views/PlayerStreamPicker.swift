#if canImport(UIKit)
import StremioKit
import SwiftUI

/// The player's stream selector: all playable streams in the current plan in a compact glass panel that drops from the top bar,
/// paired with `PlayerEpisodePicker`. Each row states file size and cache status honestly, using unknown labels when unavailable.
struct PlayerStreamPicker: View {
    let candidates: [PlaybackCandidate]
    let currentIndex: Int
    let onSelect: (Int) -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(candidates.enumerated()), id: \.element.id) { entry in
                            row(entry.element, offset: entry.offset)
                                .id(entry.element.id)
                            if entry.offset < candidates.count - 1 {
                                Divider().padding(.leading, 14)
                            }
                        }
                    }
                    .background(.white.opacity(0.065), in: .rect(cornerRadius: 18))
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(12)
                }
                .scrollIndicators(.visible, axes: .vertical)
                .scrollIndicatorsFlash(onAppear: true)
                .scrollBounceBehavior(.basedOnSize)
                .onAppear {
                    if candidates.indices.contains(currentIndex) {
                        proxy.scrollTo(candidates[currentIndex].id, anchor: .center)
                    }
                }
            }
        }
        .clipShape(.rect(cornerRadius: 24))
        .glassEffect(.regular.tint(.black.opacity(0.32)), in: .rect(cornerRadius: 24))
        .foregroundStyle(.white)
        .tint(.white)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("player.streamPicker")
    }

    private var header: some View {
        HStack {
            Text("Streams")
                .font(.headline)
                .lineLimit(1)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 12)
            Button(action: onClose) {
                Image(systemName: "xmark").frame(width: 32, height: 32)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            #if !targetEnvironment(macCatalyst)
            .keyboardShortcut(.escape, modifiers: [])
            #endif
            .accessibilityLabel("Close")
            .accessibilityIdentifier("player.streamPicker.close")
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    private func row(_ candidate: PlaybackCandidate, offset: Int) -> some View {
        let isCurrent = offset == currentIndex
        return Button {
            Haptics.tap()
            onSelect(offset)
        } label: {
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 5) {
                    FlowLayout(spacing: Theme.Spacing.xs) {
                        badges(for: candidate)
                    }
                    Text(primaryTitle(for: candidate))
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    if let release = secondaryRelease(for: candidate) {
                        Text(release)
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.72))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Text(metaLine(for: candidate))
                        .font(Theme.Typography.metaLine)
                        .foregroundStyle(Theme.metaText)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if isCurrent {
                    Image(systemName: "checkmark")
                        .font(.body.weight(.semibold))
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(isCurrent)
        .accessibilityIdentifier("player.stream.\(candidate.id)")
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
    }

    @ViewBuilder
    private func badges(for candidate: PlaybackCandidate) -> some View {
        QualityBadge.cache(candidate.cacheStatus)
        if let delivery = candidate.delivery {
            QualityBadge.delivery(delivery, titled: true)
        }
        if let label = candidate.quality.resolutionLabel {
            QualityBadge.resolution(label, is4K: (candidate.quality.resolution ?? 0) >= 2160)
        }
        if candidate.quality.isHDR || candidate.quality.isDolbyVision {
            QualityBadge.hdr(dolbyVision: candidate.quality.isDolbyVision, compact: true)
        }
        if candidate.quality.isRemux {
            QualityBadge.remux(compact: true)
        }
        if let source = candidate.quality.source {
            QualityBadge.source(source, is4K: (candidate.quality.resolution ?? 0) >= 2160)
        }
        if playsAtmosOverAirPods(candidate) {
            SpatialAudioBadge()
        }
    }

    private func playsAtmosOverAirPods(_ candidate: PlaybackCandidate) -> Bool {
        guard candidate.quality.atmosFormat == .streaming, case .native = candidate.route else { return false }
        return true
    }

    private func primaryTitle(for candidate: PlaybackCandidate) -> String {
        candidate.title.isEmpty ? (candidate.releaseTitle ?? "Stream") : candidate.title
    }

    private func secondaryRelease(for candidate: PlaybackCandidate) -> String? {
        guard let release = candidate.releaseTitle?.trimmingCharacters(in: .whitespacesAndNewlines), !release.isEmpty else { return nil }
        return release.caseInsensitiveCompare(primaryTitle(for: candidate)) == .orderedSame ? nil : release
    }

    private func metaLine(for candidate: PlaybackCandidate) -> String {
        var parts: [String] = [
            candidate.effectiveSizeBytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "Size unknown"
        ]
        if let codec = candidate.quality.videoCodec {
            parts.append(codec.label)
        }
        if let audio = audioText(for: candidate) {
            parts.append(audio)
        }
        let primary = primaryTitle(for: candidate)
        if !candidate.addonName.isEmpty, candidate.addonName.caseInsensitiveCompare(primary) != .orderedSame {
            parts.append(candidate.addonName)
        }
        return parts.joined(separator: " · ")
    }

    private func audioText(for candidate: PlaybackCandidate) -> String? {
        switch candidate.quality.atmosFormat {
        case .lossless:
            return "Atmos TrueHD"
        case .streaming:
            return playsAtmosOverAirPods(candidate) ? "DD+" : "Atmos DD+"
        case nil:
            let parts = [candidate.quality.hasAtmos ? "Atmos" : nil, candidate.quality.audioCodecs.first?.label].compactMap { $0 }
            return parts.isEmpty ? nil : parts.joined(separator: " ")
        }
    }
}
#endif
