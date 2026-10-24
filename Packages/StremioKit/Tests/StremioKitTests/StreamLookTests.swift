import Foundation
import Testing
@testable import StremioKit

@Suite struct StreamProviderTests {
    @Test func readsTheServiceFromItsReleaseTag() {
        #expect(StreamProvider.detect(in: ["Dark.Knight.2008.2160p.NF.WEB-DL.DDP5.1.HDR.H.265-FLUX"]) == .netflix)
        #expect(StreamProvider.detect(in: ["Movie.2020.1080p.AMZN.WEB-DL.DDP5.1.H.264"]) == .primeVideo)
        #expect(StreamProvider.detect(in: ["Show.S01E01.1080p.ATVP.WEB-DL.DDP5.1"]) == .appleTV)
        #expect(StreamProvider.detect(in: ["Show.S01E01.720p.DSNP.WEB-DL"]) == .disneyPlus)
        #expect(StreamProvider.detect(in: ["Movie.2019.1080p.HMAX.WEB-DL"]) == .hboMax)
        #expect(StreamProvider.detect(in: ["Show.S02E03.1080p.HULU.WEB-DL"]) == .hulu)
        #expect(StreamProvider.detect(in: ["Show.S02E03.1080p.PMTP.WEB-DL"]) == .paramountPlus)
        #expect(StreamProvider.detect(in: ["Show.S02E03.1080p.PCOK.WEB-DL"]) == .peacock)
        #expect(StreamProvider.detect(in: ["Anime - 01 [1080p] CR WEB-DL"]) == .crunchyroll)
    }

    @Test func readsTheServiceFromItsName() {
        #expect(StreamProvider.detect(in: [nil, "Movie 1080p Netflix WEB-DL"]) == .netflix)
        #expect(StreamProvider.detect(in: ["Movie 1080p Prime Video WEB-DL"]) == .primeVideo)
        #expect(StreamProvider.detect(in: ["Show 1080p Apple TV+ WEB-DL"]) == .appleTV)
        #expect(StreamProvider.detect(in: ["Show 1080p Disney+ WEB-DL"]) == .disneyPlus)
        #expect(StreamProvider.detect(in: ["Show 1080p HBO Max WEB-DL"]) == .hboMax)
        #expect(StreamProvider.detect(in: ["Show 1080p Paramount+ WEB-DL"]) == .paramountPlus)
        #expect(StreamProvider.detect(in: ["Show 1080p Peacock TV WEB-DL"]) == .peacock)
        #expect(StreamProvider.detect(in: ["Movie 1080p Amazon Prime WEB-DL"]) == .primeVideo)
    }

    @Test func readsTheTextThatComesFirstBeforeAnotherThatNamesAService() {
        #expect(StreamProvider.detect(in: ["Show.S01E01.1080p.AMZN.WEB-DL", "Watch on Netflix"]) == .primeVideo)
        #expect(StreamProvider.detect(in: [nil, "Show 1080p NF WEB-DL", "Watch on Hulu"]) == .netflix)
    }

    @Test func leavesOutWordsThatOnlyResemblingATag() {
        #expect(StreamProvider.detect(in: ["NFL Highlights 720p WEB-DL"]) == nil, "nf is a whole word, not a prefix")
        #expect(StreamProvider.detect(in: ["Movie 1080p BluRay REMUX"]) == nil)
        #expect(StreamProvider.detect(in: ["Movie 1080p WEB-DL"]) == nil)
        #expect(StreamProvider.detect(in: ["Movie 1080p CR-ROM"]) == nil, "CR counts only before a web release")
        #expect(StreamProvider.detect(in: ["Amazon.Women.on.the.Moon.1987.1080p.WEB-DL.x264"]) == nil, "a film titled Amazon is no service")
        #expect(StreamProvider.detect(in: ["Peacock.2010.1080p.WEB-DL"]) == nil, "a film titled Peacock is no service")
        #expect(StreamProvider.detect(in: [nil, nil]) == nil)
    }

    @Test func qualityCarriesTheServiceTheTextNames() {
        #expect(StreamQuality.parse(from: ["Movie 2160p WEB-DL NF"]).provider == .netflix)
        #expect(StreamQuality.parse(from: ["Movie 2160p BluRay REMUX"]).provider == nil)
        #expect(StreamQuality.parse(from: [nil, nil]) == StreamQuality(), "no text, no provider: the empty quality is unchanged")
    }
}

@Suite struct StreamLookTests {
    private func look(_ text: String) -> StreamLook {
        StreamLook(StreamQuality.parse(from: [text]))
    }

    @Test func discReleasesReadAsDiscs() {
        #expect(look("Movie 1080p BluRay x264") == .disc)
        #expect(look("Movie 1080p BluRay REMUX AVC") == .disc)
        #expect(look("Movie 2160p BluRay x265") == .disc, "a 4K Blu-ray encode is a disc, not a REMUX")
    }

    @Test func fourKRemuxGetsTheBlurredTreatment() {
        #expect(look("Movie 2160p BluRay REMUX HEVC TrueHD 7.1 Atmos") == .fourKDisc)
        #expect(look("Movie 2160p REMUX") == .fourKDisc, "the name says REMUX, whatever source it gives")
    }

    @Test func serviceTagsWithoutAWebSourceStillTakeTheLook() {
        #expect(look("Movie.2024.2160p.NF.WEB.H265") == .streaming(.netflix), "WEB alone is no source, the tag says it")
        #expect(look("Movie.2024.1080p.NF") == .streaming(.netflix))
        #expect(look("Movie 2160p NF") == .streaming(.netflix), "a service tag is itself a web release")
    }

    /// Torrentio-shaped streams: the addon's name is its quality label, and the release line sits in the description.
    @Test func readsAStreamsServiceFromItsDescriptionLine() {
        let hash = "0123456789abcdef0123456789abcdef01234567"
        let stream = AddonStream(name: "Torrentio\n1080p", description: "Show.S01E01.1080p.WEB-DL NF\n👤 3 💾 1.1 GB ⚙️ Torrentio",
                                 source: .torrent(infoHash: hash, fileIndex: nil, sources: []))
        #expect(StreamLook(StreamQuality.parse(stream)) == .streaming(.netflix))
        let amazon = AddonStream(name: "Torrentio\n2160p", description: "🎬 Show S01E01\n📺 AMZN WEB-DL 2160p",
                                 source: .torrent(infoHash: hash, fileIndex: nil, sources: []))
        #expect(StreamLook(StreamQuality.parse(amazon)) == .streaming(.primeVideo))
    }

    @Test func webReleasesFromAServiceTakeItsLook() {
        #expect(look("Dark.Knight.2008.2160p.NF.WEB-DL.DDP5.1") == .streaming(.netflix))
        #expect(look("Movie.2020.1080p.AMZN.WEBRip.x264") == .streaming(.primeVideo))
        #expect(look("Show.S01E01.1080p.ATVP.WEB-DL") == .streaming(.appleTV))
    }

    @Test func releasesThatNameTwoSourcesKeepThePlainCard() {
        #expect(look("Movie 2160p WEB-DL REMUX") == .plain, "Auto Pick reads a conflicting source as unknown, so the card does too")
        #expect(look("Show 1080p NF WEB-DL BluRay") == .plain)
    }

    @Test func unknownSourcesKeepThePlainCard() {
        #expect(look("Movie 1080p WEB-DL") == .plain, "a web release with no service named")
        #expect(look("Movie 720p HDTV NF") == .plain, "a service named beside a TV source keeps the plain card")
        #expect(look("Movie 720p HDTV") == .plain)
        #expect(look("Movie 480p DVDRip") == .plain)
        #expect(look("Movie 1080p HDCAM") == .plain)
        #expect(look("") == .plain)
    }
}
