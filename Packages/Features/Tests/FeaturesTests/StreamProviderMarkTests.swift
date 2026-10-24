#if canImport(UIKit)
import StremioKit
import Testing
@testable import Features

@Suite struct StreamProviderMarkTests {
    @Test func everyServiceHasALogo() {
        for provider in StreamProvider.allCases {
            #expect(provider.logoName.hasPrefix("StreamLogo"), "\(provider.name) needs a logo in the asset catalog")
        }
    }

    @Test func eachServiceHasItsOwnLogoExceptHulu() {
        let logos = StreamProvider.allCases.filter { $0 != .hulu }.map(\.logoName)
        #expect(Set(logos).count == logos.count, "two services share a logo")
    }

    @Test func huluShowsTheDisneyPlusLogo() {
        #expect(StreamProvider.hulu.logoName == StreamProvider.disneyPlus.logoName)
    }
}
#endif
