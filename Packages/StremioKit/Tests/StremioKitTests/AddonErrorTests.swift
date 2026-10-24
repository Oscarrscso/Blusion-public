import Foundation
import Testing
@testable import StremioKit

@Suite struct AddonErrorTests {
    @Test func descriptionsNeverContainURLs() {
        let all: [AddonError] = [.invalidURL, .timeout, .offline, .network("urlerror.-1004"), .http(status: 502), .notFound, .invalidJSON,
                                 .responseTooLarge(limit: 1024), .tooManyRedirects, .invalidManifest(["The manifest has no id."]), .cancelled]
        for error in all {
            #expect(!error.shortDescription.isEmpty)
            #expect(!error.shortDescription.contains("://"))
            #expect(error.errorDescription?.isEmpty == false)
        }
        #expect(AddonError.http(status: 502).shortDescription == "Server error (502)")
    }

    @Test func invalidManifestShowsItsReasons() {
        #expect(AddonError.invalidManifest(["A.", "B."]).errorDescription == "A. B.")
        #expect(AddonError.invalidManifest([]).errorDescription == "Invalid addon")
    }

    @Test func onlyTransientFailuresAreRetryable() {
        let retryable: [AddonError] = [.timeout, .network("x"), .http(status: 500), .http(status: 503), .http(status: 429), .http(status: 408)]
        let permanent: [AddonError] = [.invalidURL, .offline, .notFound, .invalidJSON, .responseTooLarge(limit: 1), .tooManyRedirects,
                                       .invalidManifest([]), .cancelled, .http(status: 400), .http(status: 403), .http(status: 404)]
        #expect(retryable.allSatisfy { $0.isRetryable })
        #expect(permanent.allSatisfy { !$0.isRetryable })
    }
}
