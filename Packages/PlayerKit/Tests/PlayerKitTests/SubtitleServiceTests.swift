import Foundation
import Testing
import StremioKit
import StremioKitTestSupport
@testable import PlayerKit

@Suite struct SubtitleServiceTests {
    private func rig() throws -> (service: SubtitleService, registry: AddonRegistry, server: MockServer) {
        let server = try MockServer.shared()
        let client = AddonClient(configuration: AddonClientConfiguration(timeout: server.slowDelay + 4, maxRetries: 0))
        let registry = AddonRegistry(store: InMemoryAddonStore(), secrets: InMemorySecretStore(), client: client)
        return (SubtitleService(registry: registry, client: client), registry, server)
    }

    private let request = StreamRequest(type: "movie", id: "mock:movie1", title: "Mock Movie 1")
    private func candidate() -> PlaybackCandidate {
        PlaybackCandidate(id: "c", title: "c", route: .native(URL(string: "https://e.example.com/a.mp4")!), filename: "My Movie (2020).mp4", videoHash: "abc123", videoSize: 12345)
    }

    @Test func fetchesFromAddonsAndLoadsBothFormatsAtTheKnownCueTimes() async throws {
        let (service, registry, server) = try rig()
        _ = try await registry.install(from: server.streamManifestURL().absoluteString)
        var options: [SubtitleOption] = []
        for await response in await service.fetch(for: candidate(), request: request) {
            options = SubtitleService.merge(options, SubtitleService.options(from: response.value ?? [], addon: response.addon.name))
        }
        #expect(options.map(\.language) == ["eng", "spa"])
        #expect(options.map(\.title) == ["English · Mock Streams", "Spanish · Mock Streams"])

        let srt = try await service.load(options[0])
        #expect(srt.text(at: 2.0) == "First cue")
        #expect(srt.text(at: 5.0) == "Second cue\nwith two lines")
        #expect(srt.text(at: 3.5) == nil)
        #expect(srt.text(at: 8.4) == "Third cue")
        let vtt = try await service.load(options[1])
        #expect(vtt.cues == srt.cues, "the same cue times from the VTT file")
    }

    @Test func addonsThatDoNotOfferSubtitlesAreNotAsked() async throws {
        let (service, registry, server) = try rig()
        _ = try await registry.install(from: server.catalogManifestURL().absoluteString)
        #expect(await service.fetch(for: candidate(), request: request).collect().isEmpty)
    }

    @Test func aFailingAddonIsAFailureValue() async throws {
        let (service, registry, server) = try rig()
        _ = try await registry.install(from: server.streamManifestURL(flags: ["err500"]).absoluteString)
        let responses = await service.fetch(for: candidate(), request: request).collect()
        #expect(responses.first?.error == .http(status: 500))
    }

    @Test func loadingGarbageThrowsInsteadOfCrashing() async throws {
        let (service, _, server) = try rig()
        let option = SubtitleOption(id: "x", language: "eng", title: "x", url: server.catalogBase().appendingPathComponent("manifest.json"), source: .stream)
        await #expect(throws: SubtitleError.empty) { try await service.load(option) }
        let missing = SubtitleOption(id: "y", language: "eng", title: "y", url: server.stream.appendingPathComponent("media/nope.srt"), source: .stream)
        await #expect(throws: AddonError.notFound) { try await service.load(missing) }
    }

    @Test func streamBundledOptionsMergeWithoutDuplicates() {
        let url = URL(string: "https://e.example.com/en.srt")!
        let bundled = SubtitleService.options(from: [SubtitleItem(id: "1", url: url, lang: "en")])
        let fromAddon = SubtitleService.options(
            from: [SubtitleItem(id: "9", url: url, lang: "eng"),
                SubtitleItem(id: "2", url: URL(string: "https://e.example.com/fr.srt")!, lang: "fr")],
            addon: "Subs")
        let merged = SubtitleService.merge(bundled, fromAddon)
        #expect(merged.map(\.language) == ["eng", "fre"], "the same URL from an addon is dropped")
        #expect(merged[0].source == .stream && merged[0].title == "English")
        #expect(merged[1].source == .addon("Subs") && merged[1].title == "French · Subs")
    }

    @Test func defaultOptionHonoursTheLanguageAndPrefersBundledSubtitles() {
        func option(_ id: String, _ language: String, _ source: SubtitleOption.Source) -> SubtitleOption {
            SubtitleOption(id: id, language: LanguageCodes.normalise(language), title: id, url: URL(string: "https://e.example.com/\(id)")!, source: source)
        }
        let options = [option("fr", "fre", .addon("A")), option("en-addon", "eng", .addon("A")), option("en-stream", "en", .stream)]
        #expect(SubtitleService.defaultOption(in: options, preferredLanguage: "en")?.id == "en-stream")
        #expect(SubtitleService.defaultOption(in: options, preferredLanguage: "French")?.id == "fr")
        #expect(SubtitleService.defaultOption(in: options, preferredLanguage: "de") == nil)
        #expect(SubtitleService.defaultOption(in: options, preferredLanguage: nil) == nil, "subtitles off by default")
        #expect(SubtitleService.defaultOption(in: options, preferredLanguage: "") == nil)
    }
}
