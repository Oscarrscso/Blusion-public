import Testing
import StremioKit
import PlayerKit
import Persistence
import Features

@Suite struct SmokeTests {
    @Test func packagesLinkIntoTheApp() {
        #expect(StremioKitInfo.userAgent.hasPrefix("Blusion/"))
        #expect(PlayerKitInfo.name == "PlayerKit")
        #expect(PersistenceInfo.name == "Persistence")
        #expect(FeaturesInfo.name == "Features")
    }
}
