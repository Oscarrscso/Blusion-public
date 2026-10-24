import Foundation
import Testing
@testable import StremioKit

private struct Probe: Decodable {
    var text: String?
    var number: Int?
    var ratio: Double?
    var flag: Bool
    var url: URL?
    var list: [String]
    var items: [Item]
    var map: [String: String]

    struct Item: Decodable, Equatable {
        var id: String
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: K.self)
            guard let id = c.string(.id) else { throw DroppedItem(reason: "no id") }
            self.id = id
        }
        enum K: String, CodingKey { case id }
    }

    enum K: String, CodingKey { case text, number, ratio, flag, url, list, items, map }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        text = c.string(.text)
        number = c.int(.number)
        ratio = c.double(.ratio)
        flag = c.bool(.flag)
        url = c.url(.url)
        list = c.stringArray(.list)
        items = c.lossyArray(.items)
        map = c.stringMap(.map)
    }
}

private func probe(_ json: String) throws -> Probe {
    try JSONDecoder().decode(Probe.self, from: Data(json.utf8))
}

@Suite struct LenientDecodingTests {
    @Test func stringsAcceptNumbersAndBooleans() throws {
        #expect(try probe(#"{"text": 1999}"#).text == "1999")
        #expect(try probe(#"{"text": 7.5}"#).text == "7.5")
        #expect(try probe(#"{"text": 2.0}"#).text == "2")
        #expect(try probe(#"{"text": true}"#).text == "true")
        #expect(try probe(#"{"text": "  padded  "}"#).text == "padded")
        #expect(try probe(#"{"text": "   "}"#).text == nil)
        #expect(try probe(#"{"text": null}"#).text == nil)
        #expect(try probe(#"{"text": [1]}"#).text == nil)
        #expect(try probe(#"{"text": {"a": 1}}"#).text == nil)
        #expect(try probe(#"{}"#).text == nil)
    }

    @Test func numbersAcceptStrings() throws {
        #expect(try probe(#"{"number": "42", "ratio": "8.1"}"#).number == 42)
        #expect(try probe(#"{"number": "42", "ratio": "8.1"}"#).ratio == 8.1)
        #expect(try probe(#"{"number": 3.0}"#).number == 3)
        #expect(try probe(#"{"number": "3.0"}"#).number == 3)
        #expect(try probe(#"{"number": "abc", "ratio": "x"}"#).number == nil)
        #expect(try probe(#"{"number": true}"#).number == nil)
        #expect(try probe(#"{"ratio": 7}"#).ratio == 7)
        #expect(try probe(#"{"number": 1e300}"#).number == nil)
    }

    @Test func booleansAcceptCommonSpellings() throws {
        #expect(try probe(#"{"flag": true}"#).flag)
        #expect(try probe(#"{"flag": "true"}"#).flag)
        #expect(try probe(#"{"flag": "YES"}"#).flag)
        #expect(try probe(#"{"flag": 1}"#).flag)
        #expect(try probe(#"{"flag": "0"}"#).flag == false)
        #expect(try probe(#"{"flag": 7}"#).flag == false)
        #expect(try probe(#"{"flag": null}"#).flag == false)
    }

    @Test func urlsMustBeHTTP() throws {
        #expect(try probe(#"{"url": "https://example.com/a.png"}"#).url?.host == "example.com")
        #expect(try probe(#"{"url": "http://example.com/a.png"}"#).url != nil)
        #expect(try probe(#"{"url": "about:blank"}"#).url == nil)
        #expect(try probe(#"{"url": "data:image/png;base64,AAAA"}"#).url == nil)
        #expect(try probe(#"{"url": "javascript:alert(1)"}"#).url == nil)
        #expect(try probe(#"{"url": "ftp://example.com/x"}"#).url == nil)
        #expect(try probe(#"{"url": "not a url"}"#).url == nil)
        #expect(try probe(#"{"url": 5}"#).url == nil)
    }

    @Test func stringArraysNeverFail() throws {
        #expect(try probe(#"{"list": ["a", 1, true, null, {"x": 1}, [2], " b "]}"#).list == ["a", "1", "true", "b"])
        #expect(try probe(#"{"list": null}"#).list == [])
        #expect(try probe(#"{"list": "Action, Drama ,"}"#).list == ["Action", "Drama"])
        #expect(try probe(#"{"list": 5}"#).list == [])
        #expect(try probe(#"{"list": {"a": 1}}"#).list == [])
    }

    @Test func lossyArraysDropBadElementsOnly() throws {
        let p = try probe(#"{"items": [{"id": "a"}, null, 3, "x", {"nope": 1}, {"id": 7}, {"id": "b"}]}"#)
        #expect(p.items.map(\.id) == ["a", "7", "b"])
        #expect(try probe(#"{"items": null}"#).items.isEmpty)
        #expect(try probe(#"{"items": {"id": "a"}}"#).items.isEmpty)
        #expect(try probe(#"{"items": "oops"}"#).items.isEmpty)
    }

    @Test func stringMapsKeepScalarsOnly() throws {
        let p = try probe(#"{"map": {"a": "1", "b": 2, "c": true, "d": null, "e": {"x": 1}, "f": [1]}}"#)
        #expect(p.map == ["a": "1", "b": "2", "c": "true"])
        #expect(try probe(#"{"map": [1, 2]}"#).map.isEmpty)
    }
}
