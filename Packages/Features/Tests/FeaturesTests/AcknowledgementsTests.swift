import Testing
@testable import Features

@Suite struct AcknowledgementsTests {
    @Test func theDefaultBuildListsNoThirdPartyCode() {
        let list = Acknowledgement.all(fallbackEngineLinked: false)
        #expect(list.map(\.name) == ["Apple frameworks", "TMDB", "IMDb", "OpenSubtitles", "Review site icons"])
        #expect(!list.contains { $0.name.contains("mpv") || $0.name.contains("FFmpeg") })
    }

    @Test func imdbIsCreditedAndItsPersonalUseTermsAreStated() throws {
        let imdb = try #require(Acknowledgement.all(fallbackEngineLinked: false).first { $0.name == "IMDb" })
        #expect(imdb.detail.contains("Information courtesy of IMDb (https://www.imdb.com)"))
        #expect(imdb.detail.contains("non-commercial"))
        #expect(imdb.sourceURL != nil)
    }

    @Test func theFallbackBuildNamesEveryLGPLComponentWithALicenseAndSource() {
        let list = Acknowledgement.all(fallbackEngineLinked: true)
        for name in ["MPVKit", "libmpv", "FFmpeg", "libplacebo", "libass", "MoltenVK"] {
            let entry = list.first { $0.name == name }
            #expect(entry != nil, "\(name) is listed")
            #expect(entry?.license.isEmpty == false && entry?.sourceURL != nil, "\(name) has a license and a source link")
        }
        #expect(Set(list.map(\.id)).count == list.count)
        #expect(!list.contains { $0.license.contains("GPL-2.0") || $0.license.contains("GPL-3.0") && !$0.license.hasPrefix("LGPL") }, "no plain GPL entries")
    }
}
