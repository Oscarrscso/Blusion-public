import Foundation
import Testing
@testable import StremioKit
import StremioKitTestSupport

@Suite struct AutoStreamRankingTests {
    /// Two hours: the runtime that size is read against when a release states no bitrate.
    private let runtime: TimeInterval = 7_200

    private func release(_ id: String, _ text: String) -> RankedStream {
        let stream = S.direct(text, "https://e.example.com/\(id).mkv")
        return RankedStream(id: id, stream: stream, addon: S.addon("A"), alsoProvidedBy: [], quality: StreamQuality.parse(stream),
                            container: nil, route: .fallback(URL(string: "https://e.example.com/\(id).mkv")!, .container(.matroska)), addonIndex: 0, indexInAddon: 0)
    }

    private func score(_ text: String) -> Double {
        AutoStreamRanking.assess(release("score", text), duration: runtime).qualityScore
    }

    private func best(_ items: [RankedStream], duration: TimeInterval?, preferences: RankingPreferences = .init()) -> String? {
        AutoStreamRanking.best(from: items, duration: duration, preferences: preferences)?.item.id
    }

    @Test func strongAudioEncodeCanBeatALossyRemux() {
        // A REMUX label cannot outweigh substantially better audio.
        let bluRay = release("bluray", "Movie.2160p.BluRay.x265.HDR.DTS-HD.MA.5.1-GRP 44.66 GB")
        let remux = release("remux", "Movie.2160p.REMUX.HEVC.AAC-GRP 29.71 GB")
        #expect(best([remux, bluRay], duration: runtime) == "bluray")
        #expect(best([bluRay, remux], duration: runtime) == "bluray", "list order does not decide it")
    }

    @Test func weightedQualityCanBeatALowerResolutionRemux() {
        let uhd = release("uhd", "Movie.2160p.BluRay.x265.10bit.HDR.DTS-HD.MA.7.1-GRP 40 GB")
        let remux = release("remux", "Movie.1080p.REMUX.AAC-GRP 25 GB")
        #expect(best([remux, uhd], duration: runtime) == "uhd")
    }

    @Test func aRemuxHasABoundedScoreBonus() {
        let bluRay = release("bluray", "Movie.2160p.BluRay.x265.HDR.DTS-HD.MA.5.1-GRP 30 GB")
        let remux = release("remux", "Movie.2160p.REMUX.x265.HDR.DTS-HD.MA.5.1-GRP 30 GB")
        #expect(best([bluRay, remux], duration: runtime) == "remux")
        let nudge = AutoStreamRanking.assess(remux, duration: runtime).qualityScore - AutoStreamRanking.assess(bluRay, duration: runtime).qualityScore
        #expect(abs(nudge - 10) < 0.000_001, "the REMUX tag is worth a small, fixed indicator")
    }

    @Test func suspiciousSmallRemuxDoesNotBeatAGood4KWebDL() {
        let web = release("web", "Movie 2160p WEB-DL HEVC 10bit Dolby Vision TrueHD Atmos 7.1 60 GB seeders: 100")
        for count in ["", "seeders: 1", "seeders: 0"] {
            let remux = release("remux", "Movie 1080p BluRay REMUX AAC 2 GB " + count)
            #expect(best([web, remux], duration: runtime) == "web")
            #expect(best([remux, web], duration: nil) == "web")
        }
    }

    @Test func cinemaParadisoUHDRemuxWinsInEitherOrder() {
        let uhd = release("uhd", "Cinema Paradiso 2160p UHD REMUX HEVC HDR DTS-HD MA 5.1 85.88 GB")
        let hd = release("hd", "Cinema Paradiso 1080p REMUX H.264 23.8 GB")
        for items in [[hd, uhd], [uhd, hd]] {
            #expect(best(items, duration: 9_300) == "uhd")
        }
        print("Cinema Paradiso:", AutoStreamRanking.ranked([hd, uhd], duration: 9_300).map { ($0.item.id, $0.qualityScore) })
    }

    @Test func adventureTimeAmazonWebDLWinsInEitherOrder() {
        let amazon = release("amazon", "Adventure Time Side Quests AMZN 1080p WEB-DL DD+ 938 MB")
        let rip = release("rip", "Adventure Time Side Quests 1080p WEBRip AAC 454.6 MB")
        for items in [[rip, amazon], [amazon, rip]] {
            #expect(best(items, duration: 1_320) == "amazon")
        }
        print("Adventure Time:", AutoStreamRanking.ranked([rip, amazon], duration: 1_320).map { ($0.item.id, $0.qualityScore) })
    }

    @Test func immersiveLosslessAudioCanOutweighResolution() {
        let hd = release("hd", "1080p BluRay TrueHD Atmos 7.1 30 GB")
        let uhd = release("uhd", "2160p BluRay AAC 2.0 30 GB")
        #expect(best([uhd, hd], duration: runtime) == "hd")
    }

    @Test func cacheIsABonusRatherThanAnExclusiveFilter() {
        let cached = release("cached", "[RD+] 720p WEBRip AAC")
        let unknown = release("unknown", "2160p REMUX HEVC HDR TrueHD Atmos 7.1")
        #expect(best([cached, unknown], duration: nil) == "unknown")
        let equal = release("equal", "720p WEBRip AAC")
        #expect(best([equal, cached], duration: nil) == "cached")
        #expect(best([release("zero", "1080p seeders: 0"), release("unknown", "1080p")], duration: nil) == "unknown")
    }

    @Test func unsupportedAndDownloadingLinksCannotWin() {
        let good = release("good", "2160p REMUX HEVC TrueHD Atmos")
        let low = release("low", "720p")
        #expect(best([good.rerouted(.unsupported(.matroska)), low], duration: nil) == "low")
        #expect(best([release("waiting", "uncached 2160p REMUX"), low], duration: nil) == "low")
        #expect(best([good.rerouted(.fallback(URL(string: "https://e.example.com/good.mkv")!, .container(.matroska))), low], duration: nil) == "good")
    }

    @Test func uncachedTorrentUsesSeedersWhenAServerCanPlayIt() {
        let stream = S.torrent("uncached 1080p WEB-DL seeders: 40")
        let template = release("torrent", "1080p WEB-DL")
        let torrent = RankedStream(id: template.id, stream: stream, addon: template.addon, alsoProvidedBy: [], quality: StreamQuality.parse(stream),
                                   container: nil, route: template.route, addonIndex: 0, indexInAddon: 0)
        #expect(StreamAvailability.automaticCandidates(from: [torrent]).count == 1)
        #expect(!StreamAvailability.isCached(stream))
        // A release that plays now beats one that must download first, whatever its quality.
        #expect(best([release("unknown", "720p WEB-DL"), torrent], duration: nil) == "unknown")
        // Among releases that must download, the seeders decide.
        let deadSwarm = RankedStream(id: "dead", stream: S.torrent("uncached 1080p WEB-DL seeders: 0"), addon: template.addon, alsoProvidedBy: [],
                                     quality: StreamQuality.parse(from: ["uncached 1080p WEB-DL seeders: 0"]), container: nil, route: template.route,
                                     addonIndex: 0, indexInAddon: 0)
        #expect(best([deadSwarm, torrent], duration: nil) == "torrent")
        #expect(StreamAvailability.automaticCandidates(from: [torrent.rerouted(.unsupported(.matroska))]).isEmpty)
        #expect(!StreamAvailability.isCached(release("contradicted", "[RD+] Cached: false").stream))
        #expect(best([release("cached", "[RD+] 1080p WEB-DL seeders: 0"), release("unknown", "1080p WEB-DL")], duration: nil) == "cached")
    }

    @Test func nativeRouteOnlyScoresAudioItCanDecode() {
        let url = URL(string: "https://e.example.com/file.mp4")!
        let mixed = release("mixed", "1080p TrueHD Atmos AAC 5.1").rerouted(.native(url))
        let aac = release("aac", "1080p AAC 5.1").rerouted(.native(url))
        #expect(AutoStreamRanking.assess(mixed, duration: nil).qualityScore == AutoStreamRanking.assess(aac, duration: nil).qualityScore)
    }

    @Test func preferencesCompareEveryReleaseAtTheChosenResolution() {
        let weak = release("weak", "1080p WEBRip AAC")
        let good = release("good", "1080p AMZN WEB-DL DD+ 5.1")
        let uhd = release("uhd", "2160p REMUX TrueHD Atmos")
        #expect(AutoStreamRanking.best(from: [weak, uhd, good], duration: nil, preferences: .init(preferredResolution: 1080))?.item.id == "good")
    }

    @Test func reputationIsModestAndLanguageNeutral() {
        #expect(score("1080p WEB-DL DD+ AMZN-FLUX") > score("1080p WEB-DL DD+"))
        #expect(score("1080p WEB-DL DD+ Italian") == score("1080p WEB-DL DD+ English"))
        #expect(score("1080p DTS:X 7.1") > score("1080p DTS-HD MA 7.1"))
        #expect(score("1080p DD+ 768 kbps") > score("1080p DD+ 192 kbps"))
    }

    @Test func losslessAudioBeatsLossyAtTheSameVideo() {
        let flac = release("flac", "Movie.1080p.BluRay.x264.FLAC 15 GB")
        let aac = release("aac", "Movie.1080p.BluRay.x264.AAC 15 GB")
        #expect(best([aac, flac], duration: runtime) == "flac")
    }

    @Test func aFileGainsNothingOnceItsBitrateIsFarAboveTheReference() {
        // Size counts relative to runtime, and the gain stops at a cap: 60 GB and 120 GB over two hours are both far above a 1080p reference.
        #expect(score("Movie.1080p.WEB-DL.x264 60 GB") == score("Movie.1080p.WEB-DL.x264 120 GB"))
        #expect(score("Movie.1080p.WEB-DL.x264 20 GB") > score("Movie.1080p.WEB-DL.x264 2 GB"), "a starved encode still loses")
    }

    @Test func missingMetadataScoresNeutrallyAndNeverBreaksTheRanking() {
        let bare = release("bare", "Movie")
        let hd = release("hd", "Movie 720p")
        #expect(best([bare, hd], duration: nil) == "hd", "a known resolution beats no information")
        #expect(best([bare], duration: nil) == "bare", "a release with no facts is still a candidate")
        #expect(AutoStreamRanking.assess(bare, duration: nil).bitrateMbps == nil)
    }

    @Test func aResolutionTheTextContradictsEarnsNothing() {
        #expect(StreamQuality.parse(from: ["Movie 1080p 2160p WEB-DL"]).hasConflictingResolution)
        let both = release("both", "Movie 1080p 2160p WEB-DL")
        let one = release("one", "Movie 1080p WEB-DL")
        #expect(best([both, one], duration: runtime) == "one")
    }

    @Test func aSourceTheTextContradictsEarnsNothing() {
        // A REMUX that also names a WEB-DL is a contradiction: it scores as if it named neither source nor REMUX.
        #expect(StreamQuality.parse(from: ["Movie 2160p WEB-DL REMUX"]).hasConflictingSource)
        let contradicted = AutoStreamRanking.assess(release("contradicted", "Movie 2160p WEB-DL REMUX DTS-HD 40 GB"), duration: runtime)
        let plain = AutoStreamRanking.assess(release("plain", "Movie 2160p DTS-HD 40 GB"), duration: runtime)
        #expect(contradicted.qualityScore < plain.qualityScore)
    }

    @Test func aCodecTheTextContradictsIsNotTrusted() {
        // An x264 transcoded from HEVC names two codecs. Its codec is not ranked on, so its bitrate is read at H.264's rate, as an x264 is.
        #expect(StreamQuality.parse(from: ["Movie 1080p x264 HEVC 10 GB"]).hasConflictingVideoCodec)
        let mixed = AutoStreamRanking.assess(release("mixed", "Movie 1080p x264 HEVC 10 GB"), duration: runtime)
        let h264 = AutoStreamRanking.assess(release("h264", "Movie 1080p x264 10 GB"), duration: runtime)
        #expect(mixed.qualityScore < h264.qualityScore)
    }

    @Test func aBareSDDoesNotContradictA1080p() {
        // "SD" in a release name is common, and it sets the resolution only when nothing else does.
        let quality = StreamQuality.parse(from: ["Movie.1080p.BluRay.x264-SD"])
        #expect(!quality.hasConflictingResolution)
        #expect(quality.resolution == 1080)
        #expect(StreamQuality.parse(from: ["Movie SD"]).resolution == 480)
    }

    @Test func aDimensionThatContradictsTheHeightIsAConflict() {
        #expect(StreamQuality.parse(from: ["Movie 1920x1080 2160p WEB-DL"]).hasConflictingResolution)
        #expect(!StreamQuality.parse(from: ["Movie 1920x1080 WEB-DL"]).hasConflictingResolution)
    }

    @Test func aCodecWordIsNotAPixelSize() {
        // The 264 in "1080 x264" is a codec, never a width or a height. The 1080 beside it is the resolution.
        #expect(StreamQuality.parse(from: ["Movie 1080 x264"]).resolution == 1080, "a bare height beside a codec word is the resolution")
        #expect(StreamQuality.parse(from: ["Movie 1080 x264 WEB-DL"]).resolution == 1080)
        #expect(StreamQuality.parse(from: ["Movie 1080 x264 WEB-DL"]).videoCodec == .h264)
        #expect(!StreamQuality.parse(from: ["Movie 1080 x264"]).hasConflictingResolution)
        #expect(StreamQuality.parse(from: ["Movie 1080p x264"]).resolution == 1080)
        #expect(StreamQuality.parse(from: ["Movie 1920x1080 x264"]).resolution == 1080, "a real pixel size still reads past the codec word")
        #expect(StreamQuality.parse(from: ["Movie h.264 x 1080"]).resolution == 1080, "a codec word that is the width keeps the height after it")
    }

    @Test func aBareHeightBesideACodecWordIsTheResolution() {
        #expect(StreamQuality.parse(from: ["Movie x265 2160"]).resolution == 2160, "a height after the codec word counts too")
        #expect(StreamQuality.parse(from: ["Movie 1080x264"]).resolution == 1080, "no space between the height and the codec word")
        #expect(StreamQuality.parse(from: ["Movie x264 720 MB"]).resolution == nil, "a size in MB is not a height")
        #expect(StreamQuality.parse(from: ["Movie x264 720 subs"]).resolution == nil, "a count of subtitles is not a height")
        // A bare height beside a codec word is weaker than a named resolution: the named one wins, and the pair is not a contradiction.
        #expect(StreamQuality.parse(from: ["Movie 1080 x264 2160p"]).resolution == 2160)
        #expect(!StreamQuality.parse(from: ["Movie 1080 x264 2160p"]).hasConflictingResolution)
        #expect(!StreamQuality.parse(from: ["Movie 1080p x264 720 subs"]).hasConflictingResolution)
    }

    @Test func explicitPixelDimensionsWinOverTheSDWord() {
        #expect(StreamQuality.parse(from: ["Movie 1920x1080 SD"]).resolution == 1080)
        #expect(StreamQuality.parse(from: ["Movie 360p SD"]).resolution == 360, "a stated height beats the SD word too")
        #expect(StreamQuality.parse(from: ["Movie SD"]).resolution == 480, "SD alone still reads as 480")
    }

    @Test func aDeclaredBitrateThatContradictsTheSizeIsNotTrusted() {
        let contradicted = AutoStreamRanking.assess(release("c", "Movie 1080p 2 Mbps 40 GB"), duration: runtime)
        #expect(contradicted.bitrateMbps == nil, "2 Mbps against 40 GB over two hours is not one release")
        let agreeing = AutoStreamRanking.assess(release("a", "Movie 1080p 40 Mbps 40 GB"), duration: runtime)
        #expect(agreeing.bitrateMbps == 40, "a stated rate near the size over runtime is used as stated")
    }

    @Test func anAtmosLabelBesideAACEarnsNoAtmosCredit() {
        #expect(score("Movie 1080p AAC Atmos") == score("Movie 1080p AAC"))
        #expect(score("Movie 1080p TrueHD Atmos") > score("Movie 1080p TrueHD"), "Atmos with a codec that carries it counts")
    }

    @Test func aDeadTorrentLosesToAnAvailableOne() {
        let dead = release("dead", "Movie 2160p BluRay 👤 0")
        let alive = release("alive", "Movie 1080p BluRay 👤 40")
        #expect(best([dead, alive], duration: runtime) == "alive")
    }

    @Test func partsOfTheTextAreReadOncePerRelease() {
        #expect(StreamQuality.parse(from: ["2160p x265 10bit"]).bitDepth == 10)
        #expect(StreamQuality.parse(from: ["Hi10P 1080p"]).bitDepth == 10)
        #expect(StreamQuality.parse(from: ["DTS-HD.MA.7.1 DDP5.1"]).audioChannels == 8, "the most channels named")
        #expect(StreamQuality.parse(from: ["DDP5.1"]).audioChannels == 6)
        #expect(StreamQuality.parse(from: ["Movie 5.1 GB"]).audioChannels == nil, "a size is not a channel layout")
        #expect(StreamQuality.parse(from: ["Movie 12.5 Mbps"]).declaredBitrateMbps == 12.5)
        #expect(StreamQuality.parse(from: ["2160p REMUX"]).isRemux)
        #expect(!StreamQuality.parse(from: ["2160p WEB-DL"]).isRemux)
    }

    @Test func seedersReadInTheWordedForms() {
        #expect(StreamQuality.parse(from: ["Movie 1080p 12 seeders"]).seeders == 12)
        #expect(StreamQuality.parse(from: ["Movie 1080p seeders: 7"]).seeders == 7)
        #expect(StreamQuality.parse(from: ["Movie 1080p 🌱 9"]).seeders == 9)
        #expect(StreamQuality.parse(from: ["Movie 1080p 12 seeders 44.66 GB"]).seeders == 12, "the size's number is not the seeder count")
        #expect(StreamQuality.parse(from: ["Movie 1080p seeders 12 44.66 GB"]).seeders == 12)
    }

    // MARK: The screenshot scenario

    /// The release Auto Pick chose over the better one: 720p cached WEB-DL, 432 MB, DD+, against 1080p cached WEB-DL, 830 MB, DD+.
    @Test func cachedFullHDBeatsCachedHDAtTheSameCodecAndAudio() {
        let fullHD = release("fullHD", "[RD+] Show.S01E01.1080p.AMZN.WEB-DL.DDP5.1.H.264-GRP 830 MB")
        let hd = release("hd", "[RD+] Show.S01E01.720p.AMZN.WEB-DL.DDP5.1.H.264-GRP 432 MB")
        for runtime in [nil, 1_320, 2_700, 7_200] as [TimeInterval?] {
            #expect(best([hd, fullHD], duration: runtime) == "fullHD", "runtime \(String(describing: runtime))")
            #expect(best([fullHD, hd], duration: runtime) == "fullHD", "list order does not decide it")
        }
    }

    @Test func theLosingReleaseSaysWhichFactCostIt() {
        let fullHD = release("fullHD", "[RD+] Show.S01E01.1080p.AMZN.WEB-DL.DDP5.1.H.264-GRP 830 MB")
        let hd = release("hd", "[RD+] Show.S01E01.720p.AMZN.WEB-DL.DDP5.1.H.264-GRP 432 MB")
        let lines = AutoStreamRanking.explain(AutoStreamRanking.ranked([hd, fullHD], duration: 2_700))
        #expect(lines.map(\.id) == ["fullHD", "hd"])
        #expect(lines.map(\.rank) == [1, 2])
        #expect(lines[0].reasons.first?.hasPrefix("chosen, ") == true)
        #expect(lines[1].reasons.first?.contains("points behind") == true)
        #expect(lines[1].reasons.contains { $0.hasPrefix("resolution 720p (+6) against 1080p (+12)") }, "\(lines[1].reasons)")
    }

    // MARK: REMUX hierarchy

    @Test func aFourKRemuxBeatsAFullHDRemux() {
        let uhd = release("uhd", "Movie.2160p.REMUX.HEVC.DTS-HD.MA.5.1-GRP 60 GB")
        let fhd = release("fhd", "Movie.1080p.REMUX.AVC.DTS-HD.MA.5.1-GRP 22 GB")
        #expect(best([fhd, uhd], duration: runtime) == "uhd")
        #expect(best([uhd, fhd], duration: runtime) == "uhd")
    }

    @Test func aFullHDRemuxBeatsAFourKWebDLAtTypicalBitrates() {
        let remux = release("remux", "Movie.1080p.BluRay.REMUX.AVC.DTS-HD.MA.5.1-GRP 22 GB")
        let web = release("web", "Movie.2160p.AMZN.WEB-DL.HEVC.DDP5.1.HDR-GRP 9 GB")
        #expect(best([web, remux], duration: runtime) == "remux")
        #expect(best([remux, web], duration: runtime) == "remux")
    }

    // MARK: Caching

    private func torrent(_ id: String, _ text: String) -> RankedStream {
        let template = release(id, "1080p WEB-DL")
        let stream = S.torrent(text)
        return RankedStream(id: id, stream: stream, addon: template.addon, alsoProvidedBy: [], quality: StreamQuality.parse(stream),
                            container: nil, route: template.route, addonIndex: 0, indexInAddon: 0)
    }

    @Test func aCachedReleaseBeatsAnUncachedTorrentOfHigherQuality() {
        let uncached = torrent("uncached", "uncached 2160p REMUX HEVC HDR TrueHD Atmos 7.1 seeders: 80")
        let cached = release("cached", "[RD+] 1080p WEB-DL DDP5.1")
        #expect(best([uncached, cached], duration: runtime) == "cached")
        #expect(best([cached, uncached], duration: runtime) == "cached")
        #expect(AutoStreamRanking.ranked([uncached, cached], duration: runtime).first?.needsDownload == false)
    }

    @Test func aCachedTorrentBeatsAnUncachedOneOfTheSameQuality() {
        let uncached = torrent("uncached", "uncached 1080p WEB-DL seeders: 40")
        let cached = torrent("cached", "[RD+] 1080p WEB-DL seeders: 40")
        #expect(best([uncached, cached], duration: runtime) == "cached")
    }

    // MARK: Audio

    @Test func dolbyDigitalPlusBeatsAACAtTheSameVideo() {
        #expect(score("Movie.1080p.WEB-DL.DDP5.1") > score("Movie.1080p.WEB-DL.AAC"))
        #expect(score("Movie.1080p.WEB-DL.DDP5.1") > score("Movie.1080p.WEB-DL.AAC.5.1"))
    }

    @Test func losslessAudioBeatsDolbyDigitalPlusAtTheSameVideo() {
        let lossless = release("lossless", "Movie.1080p.BluRay.TrueHD.7.1")
        let lossy = release("lossy", "Movie.1080p.BluRay.DDP5.1")
        #expect(best([lossy, lossless], duration: runtime) == "lossless")
    }

    // MARK: Preferences

    private func addonRelease(_ id: String, _ text: String, from addon: AddonSummary, group: String? = nil) -> RankedStream {
        let stream = group.map { g in S.direct(text, "https://e.example.com/\(id).mkv", bingeGroup: g) } ?? S.direct(text, "https://e.example.com/\(id).mkv")
        return RankedStream(id: id, stream: stream, addon: addon, alsoProvidedBy: [], quality: StreamQuality.parse(stream), container: nil,
                            route: .fallback(URL(string: "https://e.example.com/\(id).mkv")!, .container(.matroska)), addonIndex: 0, indexInAddon: 0)
    }

    @Test func aSourcePreferenceNeverOutweighsAClearlyBetterRelease() {
        let debridFourK = release("debrid4K", "☁️ ⚡ Movie.2160p.BluRay.REMUX 60 GB")
        let usenetFullHD = release("usenetFHD", "📰 ⚡ Movie.1080p.WEB-DL 9 GB")
        for preference in [StreamSourcePreference.usenet, .debrid, .balanced] {
            #expect(best([debridFourK, usenetFullHD], duration: runtime, preferences: .init(sourcePreference: preference)) == "debrid4K",
                    "\(preference)")
        }
    }

    @Test func aSourcePreferenceBreaksANearTie() {
        let debrid = release("debrid", "☁️ ⚡ Movie.1080p.WEB-DL.DDP5.1 9 GB")
        let usenet = release("usenet", "📰 ⚡ Movie.1080p.WEB-DL.DDP5.1 9 GB")
        #expect(best([debrid, usenet], duration: runtime, preferences: .init(sourcePreference: .usenet)) == "usenet")
        #expect(best([usenet, debrid], duration: runtime, preferences: .init(sourcePreference: .debrid)) == "debrid")
    }

    @Test func anExplicitResolutionIsAConstraint() {
        let remux = release("remux", "Movie.2160p.REMUX.TrueHD.Atmos 60 GB")
        let hd = release("hd", "[RD+] Movie.720p.WEB-DL.DDP5.1 2 GB")
        #expect(best([remux, hd], duration: runtime, preferences: .init(preferredResolution: 720)) == "hd")
        #expect(best([remux, hd], duration: runtime, preferences: .init(preferredResolution: 2160)) == "remux")
    }

    // MARK: Episode continuity

    @Test func continuityDoesNotKeepAClearlyWeakerReleaseFromThePreviousAddon() {
        let previous = S.addon("Previous")
        let other = S.addon("Other")
        let weak = addonRelease("weak", "[RD+] 720p WEB-DL DDP5.1", from: previous, group: "show")
        let strong = addonRelease("strong", "[RD+] 1080p WEB-DL DDP5.1", from: other, group: "show")
        let continuing = BingeContext(bingeGroup: "show", addonID: previous.id)
        #expect(AutoStreamRanking.best(from: [weak, strong], duration: runtime, continuing: continuing)?.item.id == "strong")
        #expect(BingeSelection.pick(from: [weak, strong], continuing: continuing, duration: runtime)?.id == "strong")
    }

    @Test func continuityBreaksANearTieInFavourOfThePreviousAddon() {
        let previous = S.addon("Previous")
        let other = S.addon("Other")
        let same = addonRelease("same", "[RD+] 1080p WEB-DL DDP5.1", from: previous, group: "show")
        let different = addonRelease("different", "[RD+] 1080p WEB-DL DDP5.1", from: other, group: "show")
        let continuing = BingeContext(bingeGroup: "show", addonID: previous.id)
        #expect(BingeSelection.pick(from: [different, same], continuing: continuing, duration: runtime)?.id == "same")
    }

    // MARK: Diagnostics

    @Test func everyReleaseGetsAReasonList() {
        let a = release("a", "[RD+] 2160p REMUX HEVC TrueHD Atmos 7.1 60 GB")
        let b = release("b", "[RD+] 1080p WEB-DL H.264 DDP5.1 830 MB")
        let lines = AutoStreamRanking.explain(AutoStreamRanking.ranked([b, a], duration: runtime))
        #expect(lines.count == 2)
        #expect(lines.allSatisfy { !$0.reasons.isEmpty })
        #expect(AutoStreamRanking.explain([]).isEmpty)
        #expect(AutoStreamRanking.explain(AutoStreamRanking.ranked([a], duration: runtime)).first?.reasons == ["the only candidate"])
    }
}
