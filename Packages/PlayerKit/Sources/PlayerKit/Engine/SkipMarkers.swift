import Foundation

/// A stretch the viewer may want to skip, marked by the media's own chapters. Chapter names are the only marker trusted here: a guess
/// from the running time would skip real scenes.
public struct SkipMarker: Sendable, Equatable, Hashable {
    public enum Kind: String, Sendable, Equatable, Hashable {
        case intro, recap, credits, preview

        public var buttonTitle: String {
            switch self {
            case .intro: "Skip Intro"
            case .recap: "Skip Recap"
            case .credits: "Skip Credits"
            case .preview: "Skip Preview"
            }
        }
    }

    public let kind: Kind
    public let start: TimeInterval
    public let end: TimeInterval

    public init(kind: Kind, start: TimeInterval, end: TimeInterval) {
        self.kind = kind
        self.start = start
        self.end = end
    }

    public func contains(_ position: TimeInterval) -> Bool { position >= start && position < end }
}

public enum SkipMarkers {
    /// Markers from chapter titles such as "Intro", "Opening", "OP", "Previously on", "Recap", "End Credits", "ED", "Preview".
    /// A marker ends where the next chapter starts, or at the end of the media.
    public static func markers(chapters: [Chapter], duration: TimeInterval?) -> [SkipMarker] {
        let sorted = chapters.sorted { $0.start < $1.start }
        var markers: [SkipMarker] = []
        for (offset, chapter) in sorted.enumerated() {
            guard let kind = kind(of: chapter.title) else { continue }
            let end = offset + 1 < sorted.count ? sorted[offset + 1].start : (duration ?? chapter.start)
            let length = end - chapter.start
            // A credits chapter can run long; an "intro" of half an hour is a mislabelled chapter.
            let longest: TimeInterval = kind == .credits || kind == .preview ? 20 * 60 : 6 * 60
            guard length >= 3, length <= longest else { continue }
            markers.append(SkipMarker(kind: kind, start: chapter.start, end: end))
        }
        return markers
    }

    static func kind(of title: String) -> SkipMarker.Kind? {
        let text = title.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        func has(_ pattern: String) -> Bool { text.range(of: pattern, options: .regularExpression) != nil }
        if has(#"\b(recap|previously)\b"#) { return .recap }
        if has(#"\b(preview|next episode|next time)\b"#) { return .preview }
        if has(#"\bopening credits\b"#) { return .intro }
        if has(#"\b(end(ing)?[ \-]?credits?|credits|ending|outro)\b"#) || has(#"^(ed|ed\d*)$"#) { return .credits }
        if has(#"\b(intro|opening|title sequence|main title)\b"#) || has(#"^(op|op\d*)$"#) { return .intro }
        return nil
    }
}
