import Foundation
import Testing
@testable import StremioKit

@Suite struct SpansBothKindsTests {
    @Test func aTitleNamingNeitherFilmsNorShowsAsksForBothKinds() {
        #expect(TMDbDiscoverQuery.inferred(fromTitle: "Adult animation").spansBothKinds)
        #expect(TMDbDiscoverQuery.inferred(fromTitle: "Animation minus kids and anime").spansBothKinds)
    }

    @Test func aTitleNamingFilmsOrShowsAsksForOneKindOnly() {
        #expect(!TMDbDiscoverQuery.inferred(fromTitle: "Adult animation movies").spansBothKinds)
        #expect(!TMDbDiscoverQuery.inferred(fromTitle: "Adult animation TV").spansBothKinds)
        #expect(TMDbDiscoverQuery.inferred(fromTitle: "Adult animation TV").kind == .series)
    }

    @Test func theFlagIsWrittenOnlyWhenSetSoASavedListKeepsItsEncoding() throws {
        let plain = try JSONEncoder().encode(TMDbDiscoverQuery.inferred(fromTitle: "Adult animation movies"))
        #expect(!String(decoding: plain, as: UTF8.self).contains("spansBothKinds"))
        let both = try JSONEncoder().encode(TMDbDiscoverQuery.inferred(fromTitle: "Adult animation"))
        let decoded = try JSONDecoder().decode(TMDbDiscoverQuery.self, from: both)
        #expect(decoded.spansBothKinds)
    }
}
