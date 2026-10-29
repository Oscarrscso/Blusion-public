#if canImport(UIKit)
import SwiftUI
import StremioKit

/// One stream as a card, in the title page's design: a "Best match" label for the stream Auto Pick recommends, small badges for sharpness,
/// REMUX, source, where iOS plays it over AirPods, Dolby Atmos, and whether TorBox holds the file already. A web release's streaming service sits in a box to the left of the
/// release name, which is in up to two lines, with one grey line of facts (size, codec, audio). A note appears when the stream opens
/// elsewhere or Blusion cannot play it. A round mark at the trailing edge says what a tap does. The technical details fold away in a
/// section of their own, so tapping the card always plays.
struct StreamRow: View {
    let item: RankedStream
    /// True for the stream Auto Pick recommends, shown with a "Best match" label.
    var isBest = false
    /// True when the release name says REMUX, as the stream's parsed quality reads it.
    var isRemux = false
    /// True on a card that opens in another player: under the round mark is the room for the bookmark that saves the stream there (see
    /// `StreamSaveSlotKey`).
    var savesToPlayer = false
    var downloadsToPlayer = false
    var downloadsNatively = false
    /// True while Blusion readies this stream to play: its play button turns into a spinner until the film is ready.
    var isPreparing = false
    /// Usenet or debrid, as the addon marks it, read once. Nil when its text says neither.
    private let delivery: StreamDelivery?
    /// Whether TorBox holds this stream's file already, as the addon marks it, read once. Nil for a stream that is not on TorBox.
    private let torBox: TorBoxCache?
    /// Compact width (iPhone in portrait) takes the short badge words: "RMX" and "DV".
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    init(item: RankedStream, isBest: Bool = false, isRemux: Bool = false, savesToPlayer: Bool = false, downloadsToPlayer: Bool = false, downloadsNatively: Bool = false,
         isPreparing: Bool = false) {
        self.item = item
        self.isPreparing = isPreparing
        self.delivery = StreamDelivery.detect(in: item.stream)
        self.isBest = isBest
        self.isRemux = isRemux
        self.savesToPlayer = savesToPlayer
        self.downloadsToPlayer = downloadsToPlayer
        self.downloadsNatively = downloadsNatively
        self.torBox = TorBoxCache.detect(in: item.stream)
    }

    var body: some View {
        HStack(alignment: .center, spacing: Theme.Spacing.m) {
            VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                if isBest {
                    Label("Best match", systemImage: "sparkles")
                        .font(Theme.Typography.eyebrow)
                        .textCase(.uppercase)
                        .foregroundStyle(.white.opacity(0.7))
                        .lineLimit(1)
                        .accessibilityIdentifier("stream.bestMatch")
                }
                if hasBadges {
                    // Every badge with its words when they fit on one line. Otherwise the delivery and TorBox marks give up their words
                    // and the badges wrap onto a second line, so none is cut and the card never runs past the screen's edge.
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: Theme.Spacing.xs) { badges(titled: true) }
                        FlowLayout(spacing: Theme.Spacing.xs) { badges(titled: false) }
                    }
                }
                HStack(alignment: .top, spacing: Theme.Spacing.m) {
                    if let provider = provider {
                        StreamProviderBox(provider: provider)
                    } else if let disc = disc {
                        // A disc gets the same box a service does, with its format's name in it.
                        StreamDiscBox(is4K: disc == .fourKDisc)
                    }
                    Text(Self.headline(for: item))
                        .font(.subheadline.weight(.semibold))
                        .multilineTextAlignment(.leading)
                        .lineLimit(2)
                        .minimumScaleFactor(0.7)
                        .fixedSize(horizontal: false, vertical: true)
                }
                #if targetEnvironment(macCatalyst)
                // On a Mac the technical details open from a small chevron at the end of this line, set there by the picker (see
                // `StreamDetailsSlotKey`), instead of a row of their own across the card's foot.
                HStack(alignment: .center, spacing: Theme.Spacing.xs) {
                    if !facts.isEmpty {
                        Text(facts)
                            .font(Theme.Typography.metaLine)
                            .foregroundStyle(Theme.metaText)
                            .lineLimit(1)
                    }
                    Color.clear
                        .frame(width: StreamCardMetrics.disclosureSize, height: StreamCardMetrics.disclosureSize)
                        .anchorPreference(key: StreamDetailsSlotKey.self, value: .bounds) { $0 }
                }
                #else
                if !facts.isEmpty {
                    Text(facts)
                        .font(Theme.Typography.metaLine)
                        .foregroundStyle(Theme.metaText)
                        .lineLimit(1)
                }
                #endif
                if let routeNote {
                    Label(routeNote.text, systemImage: routeNote.symbol)
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(routeNote.isWarning ? Color.orange : Color.white.opacity(0.62))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            trailingMarks
        }
        .padding(StreamCardMetrics.padding)
        .contentShape(Rectangle())
        .help(item.route.handoffTarget.map { "Play in \($0.player.displayName)" } ?? "Choose this stream")
    }

    /// The streaming service a web release names, when its card takes the service's look.
    private var provider: StreamProvider? {
        if case .streaming(let provider) = StreamLook(item.quality) { return provider }
        return nil
    }

    /// The disc a release is, when its card takes a disc's look: a Blu-ray, or a 4K REMUX.
    private var disc: StreamLook? {
        switch StreamLook(item.quality) {
        case .disc, .fourKDisc: StreamLook(item.quality)
        case .plain, .streaming: nil
        }
    }

    /// Whether iOS sends this stream's Dolby Atmos to AirPods as spatial audio, so the AirPods mark stands for it. That is streaming Atmos
    /// (E-AC-3 with JOC) that Blusion's native player plays. Lossless TrueHD from a disc does not reach AirPods as Atmos on iOS, and a
    /// stream the fallback engine or another app plays is not claimed here.
    private var playsAtmosOverAirPods: Bool {
        guard item.quality.atmosFormat == .streaming, case .native = item.route else { return false }
        return true
    }

    /// The badges, for the row or the wrapping layout to place. `titled` keeps the delivery and TorBox marks' words.
    @ViewBuilder
    private func badges(titled: Bool) -> some View {
        // Usenet or Debrid first, so how the stream arrives reads before its quality.
        if let delivery { QualityBadge.delivery(delivery, titled: titled) }
        if let label = item.quality.resolutionLabel {
            QualityBadge.resolution(label, is4K: (item.quality.resolution ?? 0) >= 2160)
        }
        if item.quality.isHDR || item.quality.isDolbyVision {
            QualityBadge.hdr(dolbyVision: item.quality.isDolbyVision, compact: horizontalSizeClass == .compact)
        }
        if isRemux { QualityBadge.remux(compact: horizontalSizeClass == .compact) }
        if let source = item.quality.source {
            QualityBadge.source(source, is4K: (item.quality.resolution ?? 0) >= 2160)
        }
        if playsAtmosOverAirPods { SpatialAudioBadge() }
        if let torBox {
            if titled {
                QualityBadge.torBox(torBox, compact: horizontalSizeClass == .compact)
            } else {
                TorBoxMark(cache: torBox)
            }
        }
    }

    /// Whether any badge applies, so the badge row is left out for a stream with none and takes no spacing.
    private var hasBadges: Bool {
        item.quality.resolutionLabel != nil || item.quality.isHDR || item.quality.isDolbyVision || isRemux || item.quality.source != nil
            || playsAtmosOverAirPods || torBox != nil || delivery != nil
    }

    /// Keep the release name, not the badges' resolution/HDR: the file name when the addon gives one, else the name of the file it links to.
    /// The technical details use it too, to avoid repeating the description's first line when that is the headline.
    static func headline(for item: RankedStream) -> String {
        if let filename = item.stream.behaviorHints.filename?.trimmingCharacters(in: .whitespacesAndNewlines), !filename.isEmpty {
            return (filename as NSString).lastPathComponent
        }
        if case .direct(let url) = item.stream.source, !url.pathExtension.isEmpty {
            return url.lastPathComponent.removingPercentEncoding ?? url.lastPathComponent
        }
        return item.stream.description?.split(whereSeparator: \.isNewline).first.map(String.init) ?? item.title
    }

    /// The grey line of facts: "38.2 GB · HEVC · Atmos TrueHD". The parts the stream does not give are left out.
    private var facts: String {
        var parts: [String] = []
        if let size = item.quality.sizeBytes { parts.append(ByteCountFormatter.string(fromByteCount: size, countStyle: .file)) }
        if let codec = item.quality.videoCodec { parts.append(codec.label) }
        if let audio = audioText { parts.append(audio) }
        return parts.joined(separator: " · ")
    }

    /// The audio for the grey line. Atmos that the AirPods mark stands for is left to the mark, so only its codec is named; any other Atmos
    /// keeps its name. Otherwise the first audio codec the release names, with "Atmos" beside it when the release marks Atmos.
    private var audioText: String? {
        switch item.quality.atmosFormat {
        case .lossless:
            return "Atmos TrueHD"
        case .streaming:
            return playsAtmosOverAirPods ? "DD+" : "Atmos DD+"
        case nil:
            let parts = [item.quality.hasAtmos ? "Atmos" : nil, item.quality.audioCodecs.first?.label].compactMap { $0 }
            return parts.isEmpty ? nil : parts.joined(separator: " ")
        }
    }

    /// Play, then the bookmark, then download. The picker overlays independent controls in these slots.
    @ViewBuilder
    private var trailingMarks: some View {
        if savesToPlayer || downloadsToPlayer || downloadsNatively {
            VStack(spacing: Theme.Spacing.s) {
                routeGlyph
                if downloadsNatively {
                    let side = item.route.isPlayable ? StreamCardMetrics.playButtonSize : StreamCardMetrics.markSize
                    Color.clear.frame(width: side, height: side)
                        .anchorPreference(key: StreamNativeDownloadSlotKey.self, value: .bounds) { $0 }
                }
                if savesToPlayer {
                    Color.clear
                        .frame(width: StreamCardMetrics.markSize, height: StreamCardMetrics.markSize)
                        .anchorPreference(key: StreamSaveSlotKey.self, value: .bounds) { $0 }
                }
                if downloadsToPlayer {
                    Color.clear
                        .frame(width: StreamCardMetrics.markSize, height: StreamCardMetrics.markSize)
                        .anchorPreference(key: StreamDownloadSlotKey.self, value: .bounds) { $0 }
                }
            }
        } else {
            routeGlyph
        }
    }

    /// The round mark at the trailing edge: it shows what a tap does with this stream. A stream Blusion plays has the one play button,
    /// a little larger, centred on the card's right; while Blusion readies the film it is a spinner instead. It is not a control of its
    /// own (the whole card plays), so it is hidden from VoiceOver, which reads the card's hint instead.
    private var routeGlyph: some View {
        let side = item.route.isPlayable ? StreamCardMetrics.playButtonSize : StreamCardMetrics.markSize
        return ZStack {
            if isPreparing {
                Spinner()
                    .controlSize(.small)
                    .transition(.opacity)
            } else {
                Image(systemName: routeMark.symbol)
                    .font((item.route.isPlayable ? Font.subheadline : .footnote).weight(.bold))
                    .foregroundStyle(routeMark.tint)
                    .transition(.opacity)
            }
        }
        .frame(width: side, height: side)
        .background(Theme.surfaceStrong, in: Circle())
        .animation(.smooth(duration: 0.2), value: isPreparing)
        .accessibilityHidden(true)
    }

    private var routeMark: (symbol: String, tint: Color) {
        switch item.route {
        case .native, .fallback, .hidden: ("play.fill", .white)
        case .handoff, .external: ("arrow.up.forward", .white)
        case .unsupported: ("exclamationmark.triangle.fill", .orange)
        }
    }

    private var routeNote: (text: String, symbol: String, isWarning: Bool)? {
        switch item.route {
        case .handoff(let player, _): ("Opens in \(player.displayName)", "arrow.up.forward.app", false)
        case .unsupported: ("Blusion can't play this yet", "exclamationmark.triangle", true)
        case .native, .fallback, .external, .hidden: nil
        }
    }
}

/// The proportions of a stream card. A Mac's are a desktop's: a pointer needs less room than a finger, so the padding, the corners, the
/// round mark and the service's box are smaller there, in step with the Mac's smaller text.
enum StreamCardMetrics {
    #if targetEnvironment(macCatalyst)
    static let padding: CGFloat = Theme.Spacing.m
    static let cornerRadius: CGFloat = 14
    /// The width and height of the round mark, and of the bookmark under it.
    static let markSize: CGFloat = 28
    /// The play button of a stream Blusion plays, its card's one control.
    static let playButtonSize: CGFloat = 34
    /// The service's or the disc's box, its corners, and how much smaller than the box the logo is fitted.
    static let providerBox = CGSize(width: 40, height: 28)
    static let providerBoxRadius: CGFloat = 8
    static let logoInset = CGSize(width: 9, height: 11)
    /// The chevron at the end of the facts line that opens the technical details.
    static let disclosureSize: CGFloat = 18
    /// A grey stand-in's height while the streams load: about a card's.
    static let skeletonHeight: CGFloat = 104
    /// Whether a card has the system's hover highlight as well as its own; a Mac card has its own only.
    static let addsSystemHighlight = false
    #else
    static let padding: CGFloat = Theme.Spacing.l
    static let cornerRadius: CGFloat = Theme.Radius.surface
    static let markSize: CGFloat = 36
    static let playButtonSize: CGFloat = 44
    static let providerBox = CGSize(width: 52, height: 36)
    static let providerBoxRadius: CGFloat = 10
    static let logoInset = CGSize(width: 12, height: 14)
    /// Includes the collapsed technical-details row below the stream information.
    static let skeletonHeight: CGFloat = 168
    static let addsSystemHighlight = true
    #endif
}

#if targetEnvironment(macCatalyst)
/// Where a Mac stream card keeps the room for the chevron that opens its technical details, at the end of its facts line, so the picker
/// can set the chevron there outside the card's button, as it does the save bookmark.
struct StreamDetailsSlotKey: PreferenceKey {
    static var defaultValue: Anchor<CGRect>? { nil }

    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = value ?? nextValue()
    }
}

/// A Mac card's chevron for its technical details, at the end of its facts line: it turns as they open and fold.
struct StreamDetailsDisclosure: View {
    let isExpanded: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "chevron.down")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.tertiary)
                .rotationEffect(.degrees(isExpanded ? 180 : 0))
                .frame(width: StreamCardMetrics.disclosureSize, height: StreamCardMetrics.disclosureSize)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerFeedback()
        .help(isExpanded ? "Hide technical details" : "Technical details")
        .accessibilityLabel("Technical details")
        .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
    }
}
#endif

/// Where a stream card keeps the room for its save bookmark, so the picker can set the bookmark there outside the card's button: a button
/// inside another button's label does not take its own taps.
struct StreamSaveSlotKey: PreferenceKey {
    static var defaultValue: Anchor<CGRect>? { nil }

    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = value ?? nextValue()
    }
}

struct StreamNativeDownloadSlotKey: PreferenceKey {
    static var defaultValue: Anchor<CGRect>? { nil }
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) { value = nextValue() ?? value }
}

struct StreamDownloadSlotKey: PreferenceKey {
    static var defaultValue: Anchor<CGRect>? { nil }

    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = value ?? nextValue()
    }
}

/// Circular controls: bookmarks show confirmed saves; downloads open Infuse without claiming completion.
struct StreamSaveButton: View {
    let player: ExternalPlayer
    let isSaved: Bool
    var isDownload = false
    let action: () -> Void

    private var label: String {
        if isDownload { return "Download in \(player.displayName)" }
        return isSaved ? "Saved to \(player.displayName)" : "Save to \(player.displayName)"
    }

    var body: some View {
        Button {
            Haptics.tap()
            action()
        } label: {
            Image(systemName: isDownload ? "arrow.down" : (isSaved ? "bookmark.fill" : "bookmark"))
                .font(.footnote.weight(.bold))
                .foregroundStyle(.white)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: StreamCardMetrics.markSize, height: StreamCardMetrics.markSize)
                .background(Theme.surfaceStrong, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .pointerFeedback()
        .help(label)
        .accessibilityLabel(label)
        .accessibilityHint(isDownload ? "Opens \(player.displayName) to download this stream for offline playback"
                           : "Adds this stream to \(player.displayName)'s library without downloading it")
    }
}

/// The card's own section for the technical details: every fact the addon and the file name give (seeders, size, hash, trackers and the rest,
/// see `StreamFacts`), then the addon's description. Folded away until asked for, so the list stays about choosing.
struct StreamTechnicalDetails: View {
    let item: RankedStream
    /// Set on a Mac, where the chevron at the end of the card's facts line opens and folds them: only the details themselves are drawn
    /// here, with no row of their own. Nil keeps the row, which opens and folds them itself.
    var openedOutside: Bool?
    @State private var isExpanded = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if let openedOutside {
            if openedOutside, !facts.isEmpty || description != nil {
                details
                    .padding(.top, Theme.Spacing.xs)
            }
        } else {
            foldingRow
        }
    }

    /// The row across the card's foot that opens and folds the details, then the details when open.
    private var foldingRow: some View {
        VStack(alignment: .leading, spacing: 0) {
            Rectangle()
                .fill(Theme.separator)
                .frame(height: 1)
                .padding(.horizontal, Theme.Spacing.l)
                .accessibilityHidden(true)
            Button {
                withAnimation(reduceMotion ? nil : .snappy(duration: 0.25)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: Theme.Spacing.xs) {
                    Text("Technical details")
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.down")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isExpanded ? 180 : 0))
                        .accessibilityHidden(true)
                }
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, Theme.Spacing.l)
                .padding(.vertical, Theme.Spacing.m)
                .contentShape(Rectangle())
                // The row is the card's foot: a plain highlight the card's own corners clip, and no ring of its own.
                .pointerInteraction(cornerRadius: 0, showsFocus: false)
            }
            .buttonStyle(.plain)
            .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
            .accessibilityIdentifier("stream.details.\(item.title)")
            if isExpanded, !facts.isEmpty || description != nil {
                details
            }
        }
    }

    /// Every fact, then the addon's description.
    private var details: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            if !facts.isEmpty { factGrid }
            if let description {
                Text(description)
                    .foregroundStyle(.secondary)
            }
        }
        .font(.footnote)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, StreamCardMetrics.padding)
        .padding(.bottom, StreamCardMetrics.padding)
        .transition(.opacity)
    }

    private var facts: [StreamFacts.Fact] { StreamFacts(item).rows }

    /// Label in grey, value beside it. Hashes are monospaced so they can be read and selected.
    private var factGrid: some View {
        Grid(alignment: .leading, horizontalSpacing: Theme.Spacing.m, verticalSpacing: Theme.Spacing.xs) {
            ForEach(facts, id: \.label) { fact in
                GridRow(alignment: .firstTextBaseline) {
                    Text(fact.label)
                        .foregroundStyle(.secondary)
                    Text(fact.value)
                        .font(fact.isIdentifier ? .footnote.monospaced() : .footnote)
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    /// The addon's description. Its first line goes when it is the headline already shown above the details.
    private var description: String? {
        guard let text = item.stream.description, !text.isEmpty else { return nil }
        let lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        let rest = lines.first.map(String.init) == StreamRow.headline(for: item) ? lines.dropFirst() : lines[...]
        let kept = rest.joined(separator: "\n")
        return kept.isEmpty ? nil : kept
    }
}

/// Grey stand-ins for stream cards while the first answers are on their way, so the screen has its shape at once.
struct StreamRowsSkeleton: View {
    var heights: [Int: CGFloat] = [:]

    var body: some View {
        VStack(spacing: Theme.Spacing.m) {
            ForEach(0..<3, id: \.self) { index in
                RoundedRectangle(cornerRadius: StreamCardMetrics.cornerRadius, style: .continuous)
                    .fill(Theme.surface)
                    .frame(height: heights[index] ?? StreamCardMetrics.skeletonHeight)
                    .overlay {
                        RoundedRectangle(cornerRadius: StreamCardMetrics.cornerRadius, style: .continuous)
                            .strokeBorder(index == 0 ? AnyShapeStyle(Theme.brandGradient) : AnyShapeStyle(Theme.artworkBorder),
                                          lineWidth: index == 0 ? 1.5 : 0.7)
                    }
            }
        }
        .shimmering()
        .accessibilityHidden(true)
    }
}
#endif
