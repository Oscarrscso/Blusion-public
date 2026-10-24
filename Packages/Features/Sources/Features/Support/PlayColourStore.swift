#if canImport(UIKit)
import Foundation
import os
import StremioKit
import SwiftUI

/// Where each title's Play colour came from: its poster, its logo, or neither (the plain button).
private let colourLog = Logger(subsystem: "app.blusion.player", category: "play-colour")

/// The Play button colour of each title, read once from the poster its card shows and kept in memory and on disk. A title's page reads it
/// on the first frame, so the button is coloured as the page opens. A poster with no vivid colour is kept too, so it is not read again.
@MainActor
final class PlayColourStore {
    static let shared = PlayColourStore()

    /// "rrggbb" for each title identity whose poster was read, or "" for a poster with no vivid colour.
    private var entries: [String: String] = [:]
    /// Titles being read now, so cards that show the same title at once read it once.
    private var reading: Set<String> = []
    private let file: URL?

    init(file: URL? = PlayColourStore.defaultFile) {
        self.file = file
        guard let file else { return }
        Task { [weak self] in
            let saved = await Task.detached(priority: .utility) { PlayColourStore.read(file) }.value
            self?.entries.merge(saved) { current, _ in current }
        }
    }

    /// The button's colour for a title, or nil when its poster has not been read yet or has no vivid colour. It reads memory only, so it
    /// is cheap to ask on every draw; the page asks once, when it opens.
    func colour(for identity: String) -> Color? {
        Self.colour(hex: entries[identity])
    }

    /// The saved "rrggbb" for a title, "" for the plain button, or nil when it has not been decided.
    func hex(for identity: String) -> String? {
        entries[identity]
    }

    /// The colour for "rrggbb"; nil for "" or nil.
    static func colour(hex: String?) -> Color? {
        guard let hex, let value = UInt32(hex, radix: 16) else { return nil }
        return Color(red: Double(value >> 16 & 0xFF) / 255, green: Double(value >> 8 & 0xFF) / 255, blue: Double(value & 0xFF) / 255)
    }

    /// The pictures a title's card can show, first choice first: the BetterPosters picture a row may show, then the usual poster that stands in
    /// for it. The colour is read from whichever is in the image cache.
    static func pictures(for item: MetaPreview) -> [URL] {
        // A Mac card shows the landscape picture, not the poster, so its poster is often not in the image cache: the pictures the card
        // shows are read too, after the poster.
        [BetterPosters.posterURL(id: item.id, type: item.type), PosterQuality.poster(for: item), PosterQuality.landscape(item.background),
         item.background].compactMap { $0 }
    }

    /// The title's logos, first choice first: the one its preview carries, then Metahub's for its IMDb id. The colour comes from one when
    /// the poster's is dull.
    static func logos(for item: MetaPreview) -> [URL] {
        [item.logo, MetahubArtwork.logo(imdbID: item.id)].compactMap { $0 }
    }

    /// Reads a title's colour on the spot, when its page opens before its card's read has run. Only pictures already in the image cache are
    /// used, so the page opens with its colour or the plain button, and it does not change while the page is open. The read is a few
    /// pixels, so it is done here, on the main thread, without a wait.
    func readNow(identity: String, pictures: [URL], logos: [URL]) {
        guard entries[identity] == nil, case .decided(let hex, let source) = Self.decide(pictures: pictures, logos: logos) else { return }
        store(hex, source: source, for: identity)
    }

    /// Reads a title's colour from its picture, when a picture is already in the image cache because its card has shown it, off the main
    /// thread, once per title. A dull poster takes the logo's colour instead: the logo is fetched here, small, when it is not cached yet.
    /// A title whose picture is not cached yet is read the next time its card appears.
    func read(identity: String, pictures: [URL], logos: [URL]) async {
        guard entries[identity] == nil, !reading.contains(identity), !pictures.isEmpty else { return }
        reading.insert(identity)
        defer { reading.remove(identity) }
        var outcome = await Task.detached(priority: .utility) { PlayColourStore.decide(pictures: pictures, logos: logos) }.value
        if case .needsLogo = outcome {
            for logo in logos {
                if (try? await ImagePipeline.shared.image(for: logo, maxPixelSize: Self.logoPixelSize, priority: .utility)) != nil { break }
            }
            // A card that left the screen calls its read off: nothing is decided, and the next showing reads it again.
            guard !Task.isCancelled else { return }
            outcome = await Task.detached(priority: .utility) { PlayColourStore.decide(pictures: pictures, logos: logos) }.value
            if case .needsLogo = outcome {
                // The plain button only when every logo is known to be missing, so the title is not asked for again on every card. A
                // failure that may pass (offline, a timeout) decides nothing.
                guard logos.allSatisfy({ ImagePipeline.shared.isKnownMissing($0) }) else { return }
                outcome = .decided(hex: "", source: "plain, no logo")
            }
        }
        // A page that opened meanwhile may have decided it already: that stays.
        guard case .decided(let hex, let source) = outcome, entries[identity] == nil else { return }
        store(hex, source: source, for: identity)
    }

    /// Reads the colour of a title whose page opened before it was decided, and returns it ("" for the plain button), or nil when it still
    /// cannot be decided. It is the card's read, made for the page: `standIn` is fetched when no picture is in the image cache yet, at the size
    /// the page's stand-in loads it, so it is the stand-in's own download; a dull poster's logo is fetched too. It does not wait for a card's
    /// read of the same title.
    func readForPage(identity: String, standIn: URL?, pictures: [URL], logos: [URL]) async -> String? {
        if let known = entries[identity] { return known }
        // The stand-in is read too: on the Mac it can be Metahub's backdrop, which a card never shows.
        let pictures = pictures + [standIn].compactMap { $0 }.filter { !pictures.contains($0) }
        var outcome = Self.decide(pictures: pictures, logos: logos)
        if case .unknown = outcome, let standIn {
            _ = try? await ImagePipeline.shared.image(for: standIn, maxPixelSize: TitleHero.placeholderPixelSize)
            guard !Task.isCancelled else { return nil }
            if let known = entries[identity] { return known }
            outcome = Self.decide(pictures: pictures, logos: logos)
        }
        if case .needsLogo = outcome {
            for logo in logos {
                if (try? await ImagePipeline.shared.image(for: logo, maxPixelSize: Self.logoPixelSize)) != nil { break }
            }
            guard !Task.isCancelled else { return nil }
            if let known = entries[identity] { return known }
            outcome = Self.decide(pictures: pictures, logos: logos)
        }
        guard case .decided(let hex, let source) = outcome else { return entries[identity] }
        if entries[identity] == nil { store(hex, source: "\(source), page", for: identity) }
        return entries[identity]
    }

    /// Logs the colour a title page opened with: "rrggbb", "-" for the plain button, or "none" when it was not decided yet.
    func logPageColour(identity: String) {
        let hex = entries[identity]
        colourLog.notice("\(identity, privacy: .public) page opens \(hex.map { $0.isEmpty ? "-" : $0 } ?? "none", privacy: .public)")
    }

    private func store(_ hex: String, source: String, for identity: String) {
        entries[identity] = hex
        colourLog.notice("\(identity, privacy: .public) \(source, privacy: .public) \(hex.isEmpty ? "-" : hex, privacy: .public)")
        save()
    }

    /// The longest side a logo is fetched at for its colour: plenty for a 96 by 32 sample.
    static let logoPixelSize: CGFloat = 300

    /// What a title's colour can be decided as, from the pictures in the image cache now.
    enum Outcome: Equatable, Sendable {
        /// "rrggbb", or "" for the plain button, and where it came from.
        case decided(hex: String, source: String)
        /// The poster is in the cache and its colour is dull, and a logo could give one but is not in the cache yet.
        case needsLogo
        /// None of the pictures is in the cache yet.
        case unknown
    }

    /// The colour from the first cached picture: its most common colour, unless that is dull; then the first cached logo's, unless that is
    /// dull too, which leaves the plain button.
    nonisolated static func decide(pictures: [URL], logos: [URL]) -> Outcome {
        guard let picture = pictures.lazy.compactMap({ ImagePipeline.shared.cachedImageAtAnySize(for: $0)?.cgImage }).first,
              let pixels = PlayColour.pixels(of: picture) else { return .unknown }
        if let colour = PlayColour.mostCommonColour(in: pixels), !PlayColour.isDull(colour) {
            return .decided(hex: hex(PlayColour.buttonColour(for: colour)), source: "poster")
        }
        guard !logos.isEmpty else { return .decided(hex: "", source: "plain") }
        guard let logo = logos.lazy.compactMap({ ImagePipeline.shared.cachedImageAtAnySize(for: $0)?.cgImage }).first else { return .needsLogo }
        if let pixels = PlayColour.pixels(of: logo, width: PlayColour.logoSampleWidth, height: PlayColour.logoSampleHeight),
           let colour = PlayColour.mostCommonColour(in: pixels), !PlayColour.isDull(colour) {
            return .decided(hex: hex(PlayColour.buttonColour(for: colour)), source: "logo")
        }
        return .decided(hex: "", source: "plain, dull logo")
    }

    nonisolated static func hex(_ rgb: (red: Double, green: Double, blue: Double)) -> String {
        [rgb.red, rgb.green, rgb.blue].map { String(format: "%02x", Int(($0 * 255).rounded())) }.joined()
    }

    private func save() {
        guard let file else { return }
        let snapshot = entries
        Task.detached(priority: .utility) { PlayColourStore.write(snapshot, to: file) }
    }

    nonisolated static func read(_ file: URL) -> [String: String] {
        guard let data = try? Data(contentsOf: file), let saved = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return saved
    }

    nonisolated static func write(_ entries: [String: String], to file: URL) {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: file, options: .atomic)
    }

    /// The colours of the current way of picking them. A new way gets a new file, so every title's colour is read again from its poster;
    /// the old file is deleted.
    static var defaultFile: URL? {
        guard let caches = try? FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true) else {
            return nil
        }
        for old in ["play-colours.json", "play-colours-v2.json"] {
            try? FileManager.default.removeItem(at: caches.appendingPathComponent(old))
        }
        return caches.appendingPathComponent("play-colours-v3.json")
    }
}
#endif
