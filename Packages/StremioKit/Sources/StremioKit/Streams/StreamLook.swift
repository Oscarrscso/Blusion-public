import Foundation

/// The look a stream's card takes, read from the quality the Auto Pick ranking already parses and from the service a web release names. A
/// Blu-ray or REMUX reads as a disc, a 4K REMUX also glows, and a web release from a streaming service takes that service's colour. Anything
/// else keeps the plain card. Only text the addon gave is read, so no request is made.
public enum StreamLook: Sendable, Equatable {
    /// Nothing in the release names a disc or a service.
    case plain
    /// A Blu-ray or a REMUX, below 4K.
    case disc
    /// A 4K REMUX: a disc, with the blurred 4K treatment.
    case fourKDisc
    /// A web release the text ties to a streaming service.
    case streaming(StreamProvider)

    public init(_ quality: StreamQuality) {
        // A release that names two sources has none that Auto Pick can rank on, so it keeps the plain card too.
        guard !quality.hasConflictingSource else {
            self = .plain
            return
        }
        if quality.isRemux || quality.source == .bluray {
            let is4K = (quality.resolution ?? 0) >= 2160
            self = (is4K && quality.isRemux) ? .fourKDisc : .disc
        } else if let provider = quality.provider,
                  quality.source == nil || quality.source == .webDL || quality.source == .webRip {
            // A service's tag is itself a web release, so a release that gives no WEB-DL or WEBRip still takes its service's look.
            self = .streaming(provider)
        } else {
            self = .plain
        }
    }
}
