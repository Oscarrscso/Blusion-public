#if canImport(UIKit)
import StremioKit
import SwiftUI
import UIKit

// MARK: - The kind of case

/// The case a title stands in on the video store's shelf, by its best release.
enum StoreCaseKind: Equatable {
    /// Best Blurays names a Blu-ray as the film's best release.
    case bluRay
    /// Best Blurays names a 4K Ultra HD Blu-ray.
    case ultraHD
    /// No disc, and the title streams on this service in the viewer's region.
    case streaming(TMDbWatchService)
    /// Nothing known yet, or neither a disc nor a service: a plain black case.
    case plain

    /// The kind `ratings` knows of. Read in a view's body, so a disc or service that arrives later redraws the case.
    @MainActor
    init(_ ratings: TitleRatings?) {
        switch ratings?.bestDisc {
        case .uhdBluRay: self = .ultraHD
        case .bluRay: self = .bluRay
        case nil: self = ratings?.streamer.map { StoreCaseKind.streaming($0) } ?? .plain
        }
    }

    /// What VoiceOver reads after the title's name.
    var spokenName: String {
        switch self {
        case .bluRay: "Blu-ray"
        case .ultraHD: "4K Ultra HD Blu-ray"
        case .streaming(let service): service.name
        case .plain: ""
        }
    }

    /// Whether the cover carries a format's banner across its top. A plain case is all cover.
    var hasBanner: Bool { self != .plain }

    /// The service's own colours and logo, when Blusion knows the service.
    var provider: StreamProvider? {
        if case .streaming(let service) = self { return StreamProvider(watchService: service) }
        return nil
    }

    /// The case's plastic, lit from the top left: a Blu-ray case's translucent blue; every other case is black.
    var shell: LinearGradient {
        let colours: [Color] = switch self {
        case .bluRay: [Color(red: 0.38, green: 0.66, blue: 1), Color(red: 0.07, green: 0.36, blue: 0.82),
                       Color(red: 0.02, green: 0.15, blue: 0.43)]
        case .ultraHD: [Color(white: 0.26), Color(white: 0.08), Color(white: 0.02)]
        case .streaming, .plain: [Color(white: 0.25), Color(white: 0.10), Color(white: 0.035)]
        }
        return LinearGradient(colors: colours, startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    /// The back cover's ground under its text.
    var backGround: Color {
        switch self {
        case .bluRay: Color(red: 0.03, green: 0.09, blue: 0.21)
        case .ultraHD: Color(white: 0.03)
        case .streaming, .plain: Color(white: 0.05)
        }
    }
}

extension StreamProvider {
    /// The service a TMDb watch service is: by TMDb's number for it, or else by its name ("Netflix Standard with Ads").
    init?(watchService service: TMDbWatchService) {
        let name = service.name.lowercased()
        guard let match = Self.allCases.first(where: { $0.tmdbProviderIDs.contains(service.id) })
            ?? Self.allCases.first(where: { name.contains($0.name.lowercased()) }) else { return nil }
        self = match
    }

    /// True when the service's logo is a wordmark that already spells its name, so a banner does not write the name again. Hulu shows
    /// the Disney+ logo (`logoName`).
    var logoIsWordmark: Bool {
        switch self {
        case .disneyPlus, .hulu, .peacock: true
        case .netflix, .primeVideo, .appleTV, .hboMax, .paramountPlus, .crunchyroll: false
        }
    }
}

// MARK: - Proportions

/// A keep case's proportions. A Blu-ray case is 135 by 171.5 mm and 12 mm deep; the 4K, streaming and plain cases share its size, so
/// the shelf stands level and a case never changes size when its kind becomes known.
enum StoreCase {
    static let aspect: CGFloat = 171.5 / 135

    static func height(forWidth width: CGFloat) -> CGFloat { (width * aspect).rounded() }
    static func depth(forWidth width: CGFloat) -> CGFloat { max(4, (width * 12 / 135).rounded()) }

    /// A case's rounded corners, scaled with Appearance's artwork corners, but never rounder than a case could be.
    static func cornerRadius(forWidth width: CGFloat, metrics: LayoutMetrics) -> CGFloat {
        min(width * 0.035 * metrics.cornerScale(for: .artwork), width * 0.07)
    }

    /// The format's banner: about a tenth of the cover, as on a real sleeve.
    static func bannerHeight(coverHeight: CGFloat) -> CGFloat { (coverHeight * 0.105).rounded() }

    /// The plastic showing round the cover under the case's clear sleeve: a little at the top, the foot and the opening side, less at
    /// the spine, where the cover wraps round.
    struct Rim {
        let edge: CGFloat
        let spine: CGFloat

        init(width: CGFloat) {
            edge = max(1.5, width * 0.024)
            spine = max(1, width * 0.012)
        }
    }
}

// MARK: - Front

/// A case's front: the cover under the case's clear sleeve, with the format's banner across its top and the poster under it, the hinge's
/// crease beside the spine, a "New" sticker on a title from this year, and the sleeve's sheen. On the shelf a streak of light crosses the
/// sleeve as the shelf scrolls (still with Reduce Motion); in the hand the hand draws its own. Every size follows `width`, so a case in the
/// hand is the shelf's case, larger.
struct StoreCaseFront: View, Equatable {
    let item: MetaPreview
    let kind: StoreCaseKind
    let width: CGFloat
    var glareFollowsScroll = false
    /// The poster already decoded, for the case in the hand; nil loads it as a shelf's poster does.
    var picture: UIImage?
    @Environment(PosterRatingsStore.self) private var ratings: PosterRatingsStore?
    @Environment(\.layoutMetrics) private var metrics
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var certification: String?

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        MainActor.assumeIsolated {
            lhs.item == rhs.item && lhs.kind == rhs.kind && lhs.width == rhs.width && lhs.glareFollowsScroll == rhs.glareFollowsScroll
                && lhs.picture === rhs.picture
        }
    }

    var body: some View {
        let height = StoreCase.height(forWidth: width)
        let rim = StoreCase.Rim(width: width)
        let coverWidth = width - rim.spine - rim.edge
        let coverHeight = height - rim.edge * 2
        let banner = kind.hasBanner ? StoreCase.bannerHeight(coverHeight: coverHeight) : 0
        let radius = StoreCase.cornerRadius(forWidth: width, metrics: metrics)
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        ZStack(alignment: .topLeading) {
            Rectangle().fill(kind.shell)
            VStack(spacing: 0) {
                if banner > 0 { StoreBanner(kind: kind, width: coverWidth, height: banner) }
                poster(width: coverWidth, height: coverHeight - banner)
            }
            .clipShape(RoundedRectangle(cornerRadius: radius * 0.4, style: .continuous))
            .offset(x: rim.spine, y: rim.edge)
            StoreHinge(caseWidth: width, height: coverHeight)
                .offset(x: (width * 0.05).rounded(), y: rim.edge)
            if Self.isNew(item) {
                let diameter = (width * 0.19).rounded()
                StoreNewSticker(diameter: diameter)
                    .offset(x: width - rim.edge - diameter - width * 0.04, y: rim.edge + banner + width * 0.04)
            }
            StoreSleeve()
            if glareFollowsScroll { scrollingGlare(width: width, height: height) }
        }
        .frame(width: width, height: height)
        .clipShape(shape)
        .overlay {
            shape.strokeBorder(.black.opacity(0.75), lineWidth: 0.5)
            shape.inset(by: 0.75).strokeBorder(
                LinearGradient(stops: [
                    .init(color: .white.opacity(0.58), location: 0),
                    .init(color: .white.opacity(0.12), location: 0.35),
                    .init(color: .black.opacity(0.4), location: 0.7),
                    .init(color: .white.opacity(0.22), location: 1),
                ], startPoint: .topLeading, endPoint: .bottomTrailing),
                lineWidth: max(0.5, width * 0.004)
            )
        }
        .overlay(alignment: .leading) {
            LinearGradient(colors: [.black.opacity(0.35), .white.opacity(0.2), .clear], startPoint: .leading, endPoint: .trailing)
                .frame(width: max(2, width * 0.035))
                .padding(.vertical, radius)
                .allowsHitTesting(false)
        }
        .overlay(alignment: .bottom) {
            // The moulded foot catches a thin line of the shelf's light below the sleeve.
            Capsule()
                .fill(.white.opacity(0.22))
                .frame(width: width * 0.84, height: max(0.5, rim.edge * 0.28))
                .padding(.bottom, rim.edge * 0.35)
                .allowsHitTesting(false)
        }
        .contentShape(shape)
        .overlay(alignment: .bottomTrailing) {
            if let certification {
                StoreAgeBadge(certification: certification, diameter: width * 0.12)
                    .padding(width * 0.04)
            }
        }
        .task(id: item.identity) {
            let loaded = await ratings?.certification(for: item, region: "IE")
            guard !Task.isCancelled else { return }
            certification = loaded
        }
    }

    @ViewBuilder
    private func poster(width: CGFloat, height: CGFloat) -> some View {
        if let picture {
            Color.clear
                .frame(width: width, height: height)
                .overlay {
                    Image(uiImage: picture)
                        .resizable()
                        .scaledToFill()
                }
                .clipped()
        } else {
            LayoutPoster(item: item, width: width, height: height)
        }
    }

    /// The streak of the store's light on the sleeve. It stays where the light is as the case moves past, so it slides across the case
    /// against the scroll.
    @ViewBuilder
    private func scrollingGlare(width: CGFloat, height: CGFloat) -> some View {
        if reduceMotion {
            StoreGlare(width: width, height: height)
                .offset(x: -width * 0.22)
        } else {
            StoreGlare(width: width, height: height)
                .scrollTransition(.interactive.threshold(.centered), axis: .horizontal) { content, phase in
                    content.offset(x: -CGFloat(phase.value) * width * 0.75)
                }
        }
    }

    /// A title first released this year: its "New" sticker.
    static func isNew(_ item: MetaPreview) -> Bool {
        guard let year = item.releaseInfo?.firstMatch(of: /[0-9]{4}/).flatMap({ Int($0.output) }) else { return false }
        return year >= Calendar.current.component(.year, from: Date())
    }
}

/// The format's band across the top of a cover: Blu-ray's blue with its mark, 4K's black with the Ultra HD Blu-ray mark, or a
/// streaming service's colour with its logo and name. Without its mark, it is the band at the head of a spine.
struct StoreBanner: View {
    let kind: StoreCaseKind
    let width: CGFloat
    let height: CGFloat
    var showsMark = true

    var body: some View {
        ZStack {
            ground
            if showsMark {
                mark.padding(.horizontal, (height * 0.42).rounded())
            }
        }
        .frame(width: width, height: height)
        .overlay(alignment: .top) {
            Rectangle().fill(.white.opacity(0.3)).frame(height: max(0.5, height * 0.035))
        }
        .overlay(alignment: .bottom) {
            Rectangle().fill(.black.opacity(0.5)).frame(height: max(0.5, height * 0.035))
        }
        .clipped()
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var ground: some View {
        switch kind {
        case .bluRay:
            LinearGradient(colors: [Color(red: 0.33, green: 0.63, blue: 0.97), Color(red: 0.08, green: 0.35, blue: 0.76),
                                    Color(red: 0.03, green: 0.21, blue: 0.53)], startPoint: .top, endPoint: .bottom)
        case .ultraHD:
            LinearGradient(colors: [Color(white: 0.22), Color(white: 0.06), Color(white: 0.01)], startPoint: .top, endPoint: .bottom)
        case .streaming:
            (kind.provider?.tint ?? Color(white: 0.24))
                .overlay {
                    LinearGradient(colors: [.white.opacity(0.22), .clear, .black.opacity(0.28)], startPoint: .top, endPoint: .bottom)
                }
        case .plain:
            Color.clear
        }
    }

    @ViewBuilder
    private var mark: some View {
        switch kind {
        case .bluRay:
            StoreLogo(name: "StreamLogoBluRay", height: height * 0.66, ink: .white)
        case .ultraHD:
            StoreLogo(name: "StreamLogoUHDBluRay", height: height * 0.56, ink: .white)
        case .streaming(let service):
            StoreServiceMark(service: service, height: height)
        case .plain:
            EmptyView()
        }
    }
}

/// One of the app's logos, drawn in one ink.
private struct StoreLogo: View {
    let name: String
    let height: CGFloat
    let ink: Color

    var body: some View {
        Image(name)
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
            .frame(height: height)
            .foregroundStyle(ink)
    }
}

/// A streaming service's logo in its own ink, and its name beside it unless the logo spells it; for a service Blusion does not know, TMDb's
/// logo for it and its name.
private struct StoreServiceMark: View {
    let service: TMDbWatchService
    let height: CGFloat

    var body: some View {
        let provider = StreamProvider(watchService: service)
        let ink = provider?.markInk ?? .white
        HStack(spacing: height * 0.24) {
            if let provider {
                StoreLogo(name: provider.logoName, height: height * 0.62 * provider.logoScale, ink: ink)
            } else if let logo = service.logo {
                ArtworkImage(url: logo, title: service.name, maxPixelSize: (height * 3).rounded(.up), contentMode: .fit)
                    .frame(width: height * 0.66, height: height * 0.66)
                    .clipShape(RoundedRectangle(cornerRadius: height * 0.16, style: .continuous))
            }
            if !(provider?.logoIsWordmark ?? false) {
                Text((provider?.name ?? service.name).uppercased())
                    .font(.system(size: height * 0.46, weight: .heavy).width(.condensed))
                    .foregroundStyle(ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
            }
        }
    }
}

/// The crease where the case's front hinges, just in from the spine.
private struct StoreHinge: View {
    let caseWidth: CGFloat
    let height: CGFloat

    var body: some View {
        HStack(spacing: 0) {
            Rectangle().fill(.black.opacity(0.46)).frame(width: max(0.5, caseWidth * 0.007))
            Rectangle().fill(.white.opacity(0.3)).frame(width: max(0.5, caseWidth * 0.005))
        }
        .frame(height: height)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// The clear sleeve's sheen over the cover: brightest at the top left, where the store's light falls.
private struct StoreSleeve: View {
    var body: some View {
        LinearGradient(stops: [
            .init(color: .white.opacity(0.18), location: 0),
            .init(color: .white.opacity(0.04), location: 0.08),
            .init(color: .clear, location: 0.12),
            .init(color: .white.opacity(0.025), location: 0.18),
            .init(color: .clear, location: 0.4),
            .init(color: .clear, location: 0.8),
            .init(color: .black.opacity(0.14), location: 1),
        ], startPoint: .topLeading, endPoint: .bottomTrailing)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// A streak of light across a case's sleeve, leaning a little, in a frame the case's size; whoever draws it moves it and clips it.
struct StoreGlare: View {
    let width: CGFloat
    let height: CGFloat

    var body: some View {
        LinearGradient(stops: [
            .init(color: .clear, location: 0),
            .init(color: .white.opacity(0.05), location: 0.3),
            .init(color: .white.opacity(0.18), location: 0.5),
            .init(color: .white.opacity(0.03), location: 0.7),
            .init(color: .clear, location: 1),
        ], startPoint: .leading, endPoint: .trailing)
            .frame(width: width * 0.24, height: height * 1.5)
            .rotationEffect(.degrees(16))
            .frame(width: width, height: height)
            .blendMode(.plusLighter)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// IFCO's classification colours. Unknown or missing certificates draw no badge.
private struct StoreAgeBadge: View {
    let certification: String
    let diameter: CGFloat

    private var colour: Color? {
        switch certification.uppercased() {
        case "G": Color(red: 0, green: 0.5, blue: 1)
        case "PG": Color(red: 0, green: 1, blue: 0)
        case "12", "12A": Color(red: 1, green: 0.5, blue: 0)
        case "15", "15A": Color(red: 1, green: 0, blue: 1)
        case "16": Color(red: 0.5, green: 0, blue: 1)
        case "18": Color(red: 1, green: 0, blue: 0)
        default: nil
        }
    }

    var body: some View {
        if let colour {
            Text(certification.uppercased())
                .font(.system(size: diameter * 0.4, weight: .black).width(.condensed))
                .foregroundStyle(.white)
                .shadow(color: .black, radius: 0.5, y: 0.5)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(width: diameter, height: diameter)
                .background(colour, in: Circle())
                .overlay { Circle().strokeBorder(.white, lineWidth: max(1, diameter * 0.035)) }
                .shadow(color: .black.opacity(0.35), radius: 1, y: 1)
                .accessibilityLabel("Irish age rating \(certification)")
                .allowsHitTesting(false)
        }
    }
}

/// The round yellow "New" sticker a store puts on its new releases.
private struct StoreNewSticker: View {
    let diameter: CGFloat

    var body: some View {
        Circle()
            .fill(RadialGradient(colors: [Color(red: 1, green: 0.91, blue: 0.32), Color(red: 0.98, green: 0.74, blue: 0.05)],
                                 center: .topLeading, startRadius: 0, endRadius: diameter))
            .overlay {
                Text("New")
                    .textCase(.uppercase)
                    .font(.system(size: diameter * 0.3, weight: .black).width(.condensed))
                    .foregroundStyle(Color(red: 0.6, green: 0.05, blue: 0.05))
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
            }
            .frame(width: diameter, height: diameter)
            .rotationEffect(.degrees(-14))
            .shadow(color: .black.opacity(0.3), radius: 1, y: 0.5)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

// MARK: - Back

/// A case's back: the banner again, the title's logo, its details and synopsis, a widescreen still framed in white, and along the foot
/// its age rating, the format's mark and a barcode. Seen from behind, the spine is on the right.
struct StoreCaseBack: View, Equatable {
    let item: MetaPreview
    let kind: StoreCaseKind
    let width: CGFloat
    let showsRating: Bool
    /// The title's Irish certificate, when TMDb has one.
    let certification: String?
    @Environment(\.layoutMetrics) private var metrics

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        MainActor.assumeIsolated {
            lhs.item == rhs.item && lhs.kind == rhs.kind && lhs.width == rhs.width && lhs.showsRating == rhs.showsRating
                && lhs.certification == rhs.certification
        }
    }

    private var still: URL? {
        PosterQuality.landscape(item.background) ?? MetahubArtwork.background(imdbID: item.id) ?? PosterQuality.poster(for: item)
    }

    var body: some View {
        let height = StoreCase.height(forWidth: width)
        let rim = StoreCase.Rim(width: width)
        let coverWidth = width - rim.spine - rim.edge
        let coverHeight = height - rim.edge * 2
        let banner = kind.hasBanner ? StoreCase.bannerHeight(coverHeight: coverHeight) : 0
        let radius = StoreCase.cornerRadius(forWidth: width, metrics: metrics)
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        ZStack(alignment: .topLeading) {
            Rectangle().fill(kind.shell)
            VStack(spacing: 0) {
                if banner > 0 { StoreBanner(kind: kind, width: coverWidth, height: banner) }
                content(unit: coverWidth / 100)
                    .frame(width: coverWidth, height: coverHeight - banner, alignment: .topLeading)
                    .background { wash }
                    .clipped()
            }
            .clipShape(RoundedRectangle(cornerRadius: radius * 0.4, style: .continuous))
            .offset(x: rim.edge, y: rim.edge)
            StoreHinge(caseWidth: width, height: coverHeight)
                .offset(x: width - (width * 0.05).rounded(), y: rim.edge)
            StoreSleeve()
        }
        .frame(width: width, height: height)
        .clipShape(shape)
        .overlay {
            shape.strokeBorder(.black.opacity(0.75), lineWidth: 0.5)
            shape.inset(by: 0.75).strokeBorder(
                LinearGradient(colors: [.white.opacity(0.42), .clear, .black.opacity(0.4), .white.opacity(0.16)],
                               startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: max(0.5, width * 0.004))
        }
    }

    /// The cover's ground: its poster, faint, sinking into the case's colour.
    private var wash: some View {
        ZStack {
            kind.backGround
            ArtworkImage(url: PosterQuality.poster(for: item), title: "", maxPixelSize: 400)
                .opacity(0.22)
            LinearGradient(colors: [kind.backGround.opacity(0.35), kind.backGround.opacity(0.92), kind.backGround],
                           startPoint: .top, endPoint: .bottom)
        }
    }

    /// Every size is a share of the cover's width (`unit` is a hundredth of it), as print is. The synopsis gives up lines first when
    /// the cover is short of room.
    private func content(unit: CGFloat) -> some View {
        let details = [layoutDetailLine(item, showsRating: false), item.runtime ?? ""].filter { !$0.isEmpty }.joined(separator: " · ")
        let synopsis = item.description?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return VStack(alignment: .leading, spacing: unit * 2.4) {
            HStack(spacing: unit * 2) {
                LayoutLogo(item: item, width: unit * 64, height: unit * 13)
                Spacer(minLength: 0)
                if showsRating, let rating = item.imdbRating {
                    Text(verbatim: "★ \(ScoreText.wholeScore(rating))")
                        .font(.system(size: unit * 4, weight: .bold))
                        .foregroundStyle(.white)
                        .monospacedDigit()
                        .fixedSize()
                }
            }
            if !details.isEmpty {
                Text(details)
                    .font(.system(size: unit * 4, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(2)
            }
            if !synopsis.isEmpty {
                Text(synopsis)
                    .font(.system(size: unit * 4.5))
                    .lineSpacing(unit * 0.4)
                    .foregroundStyle(.white.opacity(0.9))
                    .multilineTextAlignment(.leading)
                    .lineLimit(5)
            }
            StoreStill(url: still, title: item.name, width: unit * 78, border: max(1, unit * 0.7))
                .frame(maxWidth: .infinity)
            Spacer(minLength: 0)
            footer(unit: unit)
        }
        .padding(unit * 5)
    }

    private func footer(unit: CGFloat) -> some View {
        HStack(alignment: .bottom, spacing: unit * 3) {
            if let certification, !certification.isEmpty {
                StoreAgeBadge(certification: certification, diameter: unit * 10)
            }
            formatMark(unit: unit)
            Spacer(minLength: 0)
            StoreBarcode(code: item.id, width: unit * 26, height: unit * 13)
        }
    }

    @ViewBuilder
    private func formatMark(unit: CGFloat) -> some View {
        switch kind {
        case .bluRay:
            StoreLogo(name: "StreamLogoBluRay", height: unit * 6.5, ink: .white)
        case .ultraHD:
            StoreLogo(name: "StreamLogoUHDBluRay", height: unit * 5.5, ink: .white)
        case .streaming(let service):
            if let provider = kind.provider {
                StoreLogo(name: provider.logoName, height: unit * 6 * provider.logoScale, ink: .white)
            } else if let logo = service.logo {
                ArtworkImage(url: logo, title: service.name, maxPixelSize: 120, contentMode: .fit)
                    .frame(width: unit * 7, height: unit * 7)
                    .clipShape(RoundedRectangle(cornerRadius: unit * 1.6, style: .continuous))
            }
        case .plain:
            EmptyView()
        }
    }
}

/// A widescreen still from the title in a thin white border, as a back cover prints its screenshots.
private struct StoreStill: View {
    let url: URL?
    let title: String
    let width: CGFloat
    let border: CGFloat
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        Color.clear
            .frame(width: width - border * 2, height: ((width - border * 2) / 2.39).rounded())
            .overlay {
                ArtworkImage(url: url, title: title, maxPixelSize: min((width * displayScale).rounded(.up), 1200))
            }
            .clipped()
            .padding(border)
            .background(Color(white: 0.94))
            .shadow(color: .black.opacity(0.4), radius: border, y: border * 0.4)
    }
}

/// A barcode on a white label, its bars drawn from the title's number as an EAN's are drawn from its digits, with the digits under it.
/// It is there for the look of a case's back and encodes nothing.
struct StoreBarcode: View {
    let code: String
    let width: CGFloat
    let height: CGFloat

    struct Module: Sendable {
        let isBar: Bool
        let width: Int
    }

    var body: some View {
        let digits = Self.digits(of: code)
        let modules = Self.modules(for: digits)
        let text = digits.prefix(6).map(String.init).joined() + " " + digits.suffix(6).map(String.init).joined()
        VStack(spacing: height * 0.04) {
            Canvas { context, size in
                let total = modules.reduce(0) { $0 + $1.width }
                guard total > 0 else { return }
                let step = size.width / CGFloat(total)
                var x: CGFloat = 0
                for module in modules {
                    let span = step * CGFloat(module.width)
                    if module.isBar {
                        context.fill(Path(CGRect(x: x, y: 0, width: span, height: size.height)), with: .color(.black))
                    }
                    x += span
                }
            }
            Text(verbatim: text)
                .font(.system(size: height * 0.15, design: .monospaced))
                .foregroundStyle(.black)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
        }
        .padding(.horizontal, width * 0.07)
        .padding(.vertical, height * 0.07)
        .frame(width: width, height: height)
        .background(.white, in: RoundedRectangle(cornerRadius: height * 0.04))
        .accessibilityHidden(true)
    }

    /// Twelve digits from the code's own, repeated as needed: "tt0468569" gives 046856904685.
    static func digits(of code: String) -> [Int] {
        let own = code.compactMap(\.wholeNumberValue)
        let source = own.isEmpty ? [0] : own
        return (0..<12).map { source[$0 % source.count] }
    }

    /// The guard bars at each end and in the middle, and between them each digit's two spaces and two bars, in an EAN's widths.
    static func modules(for digits: [Int]) -> [Module] {
        let widths: [[Int]] = [[3, 2, 1, 1], [2, 2, 2, 1], [2, 1, 2, 2], [1, 4, 1, 1], [1, 1, 3, 2],
                               [1, 2, 3, 1], [1, 1, 1, 4], [1, 3, 1, 2], [1, 2, 1, 3], [3, 1, 1, 2]]
        let edge = [true, false, true].map { Module(isBar: $0, width: 1) }
        var modules = edge
        for (index, digit) in digits.enumerated() {
            if index == digits.count / 2 {
                modules += [false, true, false, true, false].map { Module(isBar: $0, width: 1) }
            }
            // The left half starts each digit with a space, the right half with a bar.
            let startsWithBar = index >= digits.count / 2
            for (part, width) in widths[digit % 10].enumerated() {
                modules.append(Module(isBar: part.isMultiple(of: 2) == startsWithBar, width: width))
            }
        }
        return modules + edge
    }
}

// MARK: - Spine and edge

/// A case's spine: the format's band at its head with a small mark, then the name running down it, under the plastic's roundness.
struct StoreCaseSpine: View, Equatable {
    let item: MetaPreview
    let kind: StoreCaseKind
    /// The case's width, which its depth and height follow.
    let width: CGFloat

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        MainActor.assumeIsolated { lhs.item == rhs.item && lhs.kind == rhs.kind && lhs.width == rhs.width }
    }

    var body: some View {
        let height = StoreCase.height(forWidth: width)
        let depth = StoreCase.depth(forWidth: width)
        let band = StoreCase.bannerHeight(coverHeight: height)
        ZStack(alignment: .top) {
            Rectangle().fill(kind.shell)
            VStack(spacing: depth * 0.5) {
                if kind.hasBanner {
                    StoreBanner(kind: kind, width: depth, height: band, showsMark: false)
                        .overlay { head(depth: depth) }
                }
                Text(item.name)
                    .font(.system(size: depth * 0.44, weight: .bold).width(.condensed))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .frame(width: height * 0.7)
                    .rotationEffect(.degrees(90))
                    .frame(width: depth, height: height * 0.7)
            }
            .padding(.top, kind.hasBanner ? 0 : depth)
            LinearGradient(stops: [
                .init(color: .black.opacity(0.5), location: 0),
                .init(color: .white.opacity(0.12), location: 0.45),
                .init(color: .black.opacity(0.55), location: 1),
            ], startPoint: .leading, endPoint: .trailing)
        }
        .frame(width: depth, height: height)
        .clipShape(RoundedRectangle(cornerRadius: depth * 0.35, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: depth * 0.35, style: .continuous)
                .strokeBorder(.white.opacity(0.12), lineWidth: max(0.5, depth * 0.025))
        }
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func head(depth: CGFloat) -> some View {
        switch kind {
        case .bluRay:
            StoreLogo(name: "StreamLogoBluRay", height: depth * 0.42, ink: .white)
        case .ultraHD:
            StoreLogo(name: "StreamLogoUHDBluRay", height: depth * 0.22, ink: .white)
        case .streaming:
            if let provider = kind.provider {
                StoreLogo(name: provider.logoName, height: depth * 0.5, ink: provider.markInk)
            }
        case .plain:
            EmptyView()
        }
    }
}

/// The case's opening side: its plastic, the edges of the front and back covers either side of where the case closes.
struct StoreCaseEdge: View, Equatable {
    let kind: StoreCaseKind
    /// The case's width, which its depth and height follow.
    let width: CGFloat

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        MainActor.assumeIsolated { lhs.kind == rhs.kind && lhs.width == rhs.width }
    }

    var body: some View {
        let height = StoreCase.height(forWidth: width)
        let depth = StoreCase.depth(forWidth: width)
        ZStack {
            Rectangle().fill(kind.shell)
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                Rectangle().fill(.white.opacity(0.55)).frame(width: max(0.5, depth * 0.05))
                Spacer(minLength: 0)
                Rectangle().fill(.black.opacity(0.5)).frame(width: max(0.5, depth * 0.08))
                Spacer(minLength: 0)
                Rectangle().fill(.white.opacity(0.55)).frame(width: max(0.5, depth * 0.05))
                Spacer(minLength: 0)
            }
            .padding(.vertical, depth * 0.3)
            // The recessed opening grip interrupts the seam halfway down the case.
            RoundedRectangle(cornerRadius: depth * 0.2, style: .continuous)
                .fill(.black.opacity(0.65))
                .frame(width: depth * 0.48, height: height * 0.12)
                .overlay {
                    RoundedRectangle(cornerRadius: depth * 0.2, style: .continuous)
                        .strokeBorder(.white.opacity(0.2), lineWidth: max(0.5, depth * 0.035))
                }
            LinearGradient(stops: [
                .init(color: .black.opacity(0.45), location: 0),
                .init(color: .white.opacity(0.1), location: 0.5),
                .init(color: .black.opacity(0.45), location: 1),
            ], startPoint: .leading, endPoint: .trailing)
        }
        .frame(width: depth, height: height)
        .clipShape(RoundedRectangle(cornerRadius: depth * 0.3, style: .continuous))
        .accessibilityHidden(true)
    }
}

// MARK: - Turning a case

/// One face of a case in the hand.
enum StoreCaseFace {
    case front, back, spine, edge
}

/// Where one face of a case is drawn as the case turns about its upright middle by `angle` (0 shows the front, π the back, π/2 the
/// spine), seen in perspective from in front of it. Each face is a flat view centred on the case; `transform` takes it from there to
/// where that face of the turned box falls, so the faces meet at the case's corners. A face turned away is hidden, and a face is darker
/// the further it turns from the light in front.
struct StoreCaseFaceGeometry {
    let transform: ProjectionTransform
    let isFacing: Bool
    /// How much darker the face is drawn, 0 when it faces the viewer.
    let shade: Double

    init(_ face: StoreCaseFace, angle: Double, width: CGFloat, height: CGFloat, depth: CGFloat) {
        let w = Double(width), h = Double(height), d = Double(depth)
        // The eye stands three case-heights in front of the front's plane, level with the case's middle.
        let camera = 3 * h
        // Points across the case (x) and towards the viewer (z), from its middle: where the face's leading top corner is, which way
        // its own width runs, the way it faces, and its middle.
        let origin: (x: Double, z: Double)
        let across: (x: Double, z: Double)
        let normal: (x: Double, z: Double)
        let centre: (x: Double, z: Double)
        let faceWidth: Double
        switch face {
        case .front:
            origin = (-w / 2, d / 2); across = (1, 0); normal = (0, 1); centre = (0, d / 2); faceWidth = w
        case .back:
            origin = (w / 2, -d / 2); across = (-1, 0); normal = (0, -1); centre = (0, -d / 2); faceWidth = w
        case .spine:
            origin = (-w / 2, -d / 2); across = (0, 1); normal = (-1, 0); centre = (-w / 2, 0); faceWidth = d
        case .edge:
            origin = (w / 2, d / 2); across = (0, -1); normal = (1, 0); centre = (w / 2, 0); faceWidth = d
        }
        let c = cos(angle), s = sin(angle)
        func turned(_ point: (x: Double, z: Double)) -> (x: Double, z: Double) {
            (point.x * c + point.z * s, -point.x * s + point.z * c)
        }
        let o = turned(origin), u = turned(across), n = turned(normal), m = turned(centre)
        isFacing = n.x * -m.x + n.z * (d / 2 + camera - m.z) > 0
        shade = (1 - max(0, n.z)) * 0.5
        // A point `p` along the face's width and `q` down it lands, before the perspective divide, at
        // x = o.x + u.x·p, y = q - h/2, and is scaled by camera / (camera - z), z measured from the front's plane. Written as one
        // projective map from the face's own coordinates to the view's, centred as the face is.
        let z0 = (o.z - d / 2) / camera
        let uz = u.z / camera
        var transform = ProjectionTransform()
        transform.m11 = CGFloat(u.x - faceWidth / 2 * uz)
        transform.m12 = CGFloat(-h / 2 * uz)
        transform.m13 = CGFloat(-uz)
        transform.m21 = 0
        transform.m22 = 1
        transform.m23 = 0
        transform.m31 = CGFloat(o.x + faceWidth / 2 * (1 - z0))
        transform.m32 = CGFloat(-h / 2 * z0)
        transform.m33 = CGFloat(1 - z0)
        self.transform = transform
    }
}
#endif
