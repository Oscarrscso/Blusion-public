import Foundation
import StremioKit

/// Terse builders for stream tests.
public enum S {
    public static func direct(_ name: String, _ url: String, description: String? = nil, notWebReady: Bool = false, filename: String? = nil,
                              proxy: [String: String] = [:], bingeGroup: String? = nil) -> AddonStream {
        let headers = proxy.isEmpty ? nil : ProxyHeaders(request: proxy)
        return AddonStream(name: name, description: description, source: .direct(URL(string: url)!),
                           behaviorHints: StreamBehaviorHints(notWebReady: notWebReady, bingeGroup: bingeGroup, proxyHeaders: headers, filename: filename))
    }

    public static func torrent(_ name: String, hash: String = "0123456789abcdef0123456789abcdef01234567", index: Int? = 0) -> AddonStream {
        AddonStream(name: name, source: .torrent(infoHash: hash, fileIndex: index, sources: []))
    }

    public static func external(_ name: String, _ url: String = "https://example.com/watch") -> AddonStream {
        AddonStream(name: name, source: .external(URL(string: url)!))
    }

    public static func youtube(_ name: String, _ id: String = "aqz-KE-bpKQ") -> AddonStream { AddonStream(name: name, source: .youtube(id)) }

    public static func archive(_ name: String) -> AddonStream { AddonStream(name: name, source: .archive(kind: "nzbUrl")) }

    public static func addon(_ name: String) -> AddonSummary { AddonSummary(id: UUID(), name: name, host: "\(name.lowercased()).example.com") }

    public static func response(_ addon: AddonSummary, _ streams: [AddonStream]) -> AddonResponse<[AddonStream]> {
        AddonResponse(addon: addon, result: .success(streams))
    }

    public static func failure(_ addon: AddonSummary, _ error: AddonError) -> AddonResponse<[AddonStream]> {
        AddonResponse(addon: addon, result: .failure(error))
    }
}
