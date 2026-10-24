import Foundation
import Testing
@testable import StremioKit
import StremioKitTestSupport

@Suite struct PlaybackPlanTests {
    private let request = StreamRequest(type: "movie", id: "tt1", title: "Movie")
    private let alpha = S.addon("Alpha")

    @Test func aPlanRetriesInTheFallbackEngineOnlyWhereSettingsAllowIt() {
        // The picker builds plans with `make`, so the retry follows the same policy that routed the streams, Settings included.
        for enabled in [true, false] {
            var listing = StreamListing(asking: [alpha], config: PolicyConfiguration(fallbackEngineAvailable: enabled))
            listing.apply(S.response(alpha, [S.direct("Alpha", "https://a.example.com/x.mp4")]))
            let plan = PlaybackPlan.make(request: request, chosen: listing.items[0], from: listing)
            #expect(plan?.retriesInFallbackEngine == enabled, "fallbackEngineAvailable \(enabled)")
        }
    }

    @Test func aPlanRetriesInTheBackupEngineOnlyWhenBothEnginesAreInUse() {
        for fallback in [true, false] {
            for backup in [true, false] {
                var listing = StreamListing(asking: [alpha],
                                            config: PolicyConfiguration(fallbackEngineAvailable: fallback, backupEngineAvailable: backup))
                listing.apply(S.response(alpha, [S.direct("Alpha", "https://a.example.com/x.mp4")]))
                let plan = PlaybackPlan.make(request: request, chosen: listing.items[0], from: listing)
                #expect(plan?.retriesInBackupEngine == (fallback && backup), "fallbackEngineAvailable \(fallback), backupEngineAvailable \(backup)")
            }
        }
    }

    @Test func aPlanBuiltDirectlyDoesNotRetry() {
        let url = URL(string: "https://a.example.com/x.mp4")!
        let plan = PlaybackPlan(request: request, candidates: [PlaybackCandidate(id: "a", title: "a", route: .native(url))])
        #expect(!plan.retriesInFallbackEngine)
        #expect(!plan.retriesInBackupEngine)
    }
}
