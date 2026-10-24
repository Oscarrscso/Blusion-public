import Foundation
import Testing
@testable import StremioKit

@Suite struct RedactorTests {
    @Test func urlKeepsOnlySchemeHostPort() {
        #expect(Redactor.redact(URL(string: "https://addon.example.com:8443/SECRET-TOKEN/manifest.json?x=1")!) == "https://addon.example.com:8443/…")
        #expect(Redactor.redact(URL(string: "http://192.168.1.2/tok/manifest.json")!) == "http://192.168.1.2/…")
    }

    @Test func textRedactionRemovesEveryEmbeddedURL() {
        let line = "GET https://a.example.com/SECRET1/catalog/movie/top.json failed; retry stremio://b.example.com:7000/SECRET2/manifest.json (http://c.example.com/SECRET3)"
        let redacted = Redactor.redact(text: line)
        for secret in ["SECRET1", "SECRET2", "SECRET3", "catalog/movie"] { #expect(!redacted.contains(secret), "leaked \(secret)") }
        #expect(redacted.contains("a.example.com"))
        #expect(redacted.contains("b.example.com:7000"))
        #expect(redacted.contains("c.example.com"))
    }

    @Test func textWithoutURLsIsUntouched() {
        #expect(Redactor.redact(text: "Timed out after 8 s") == "Timed out after 8 s")
        #expect(Redactor.redact(text: "") == "")
    }

    @Test func bracketsInsideTokensDoNotCutTheMatchShort() {
        let redacted = Redactor.redact(text: "failed https://h.example.com/ab)cd}ef]gh/manifest.json.")
        for leaked in ["ab", "cd", "ef", "gh", "manifest"] { #expect(!redacted.contains(leaked), "leaked \(leaked)") }
        #expect(redacted == "failed https://h.example.com/….", "trailing sentence punctuation is kept")
    }

    @Test func malformedLookalikesAreReplacedWholesale() {
        let redacted = Redactor.redact(text: "see https://[bad/SECRET, then more")
        #expect(!redacted.contains("SECRET"))
        #expect(redacted.hasSuffix(", then more"))
    }

    @Test func parenthesisedURLsKeepTheirParenthesis() {
        #expect(Redactor.redact(text: "(http://c.example.com/SECRET3)") == "(http://c.example.com/…)")
    }

    @Test func urlWithoutHostFallsBackToPlaceholders() {
        #expect(Redactor.redact(URL(string: "mailto:x@example.com")!) == "mailto://?/…")
        #expect(Redactor.displayHost(URL(string: "mailto:x@example.com")!) == "unknown host")
    }

    @Test func displayHost() {
        #expect(Redactor.displayHost(URL(string: "https://a.example.com/tok/manifest.json")!) == "a.example.com")
        #expect(Redactor.displayHost(URL(string: "http://10.0.0.5:7000/tok/manifest.json")!) == "10.0.0.5:7000")
    }

    @Test func loggerRedactsBeforeTheSinkSeesAnything() {
        let sink = MemoryLogSink()
        let logger = AddonLogger(sink: sink)
        logger.log(.error, "failed https://h.example.com/TOKEN123/stream/movie/tt1.json: timeout")
        logger.log(.info, "plain message")
        #expect(sink.lines.count == 2)
        #expect(sink.lines.allSatisfy { !$0.contains("TOKEN123") })
        #expect(sink.lines[0].hasPrefix("[error]"))
        AddonLogger.silent.log(.error, "nothing happens")
    }
}
