import Foundation

private struct CatalogEnvelope: Decodable {
    let metas: [MetaPreview]
    private enum Keys: String, CodingKey { case metas }
    init(from decoder: Decoder) throws {
        metas = try decoder.container(keyedBy: Keys.self).lossyArray(.metas)
    }
}

private struct MetaEnvelope: Decodable {
    let meta: MetaDetail?
    private enum Keys: String, CodingKey { case meta }
    init(from decoder: Decoder) throws {
        meta = try decoder.container(keyedBy: Keys.self).object(.meta)
    }
}

private struct StreamsEnvelope: Decodable {
    let streams: [AddonStream]
    private enum Keys: String, CodingKey { case streams }
    init(from decoder: Decoder) throws {
        streams = try decoder.container(keyedBy: Keys.self).lossyArray(.streams)
    }
}

private struct SubtitlesEnvelope: Decodable {
    let subtitles: [SubtitleItem]
    private enum Keys: String, CodingKey { case subtitles }
    init(from decoder: Decoder) throws {
        subtitles = try decoder.container(keyedBy: Keys.self).lossyArray(.subtitles)
    }
}

/// Decodes addon responses. A response must be a JSON object; inside it a bad item is dropped and never fails the whole response.
public enum ResponseDecoder {
    public static func manifest(from data: Data) throws -> Manifest {
        try decode(Manifest.self, from: data)
    }

    public static func catalog(from data: Data, defaultType: String = "") throws -> [MetaPreview] {
        try decode(CatalogEnvelope.self, from: data).metas.map { item in
            var item = item
            if item.type.isEmpty { item.type = defaultType }
            return item
        }
    }

    /// `nil` when the response is valid JSON without a usable `meta`.
    public static func meta(from data: Data, defaultType: String = "") throws -> MetaDetail? {
        guard var detail = try decode(MetaEnvelope.self, from: data).meta else { return nil }
        if detail.preview.type.isEmpty { detail.preview.type = defaultType }
        return detail
    }

    public static func streams(from data: Data) throws -> [AddonStream] {
        try decode(StreamsEnvelope.self, from: data).streams
    }

    public static func subtitles(from data: Data) throws -> [SubtitleItem] {
        try decode(SubtitlesEnvelope.self, from: data).subtitles
    }

    private static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw AddonError.invalidJSON
        }
    }
}
