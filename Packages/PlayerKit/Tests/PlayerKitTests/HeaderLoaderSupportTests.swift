import Foundation
import Testing
@testable import PlayerKit

@Suite struct HeaderLoaderSupportTests {
    @Test func customSchemeRoundTrips() throws {
        let https = try #require(URL(string: "https://cdn.example.com/a/b.mp4?x=1&y=2#t"))
        let encoded = try #require(CustomScheme.encode(https))
        #expect(encoded.scheme == "blusion-https")
        #expect(encoded.absoluteString == "blusion-https://cdn.example.com/a/b.mp4?x=1&y=2#t")
        #expect(CustomScheme.decode(encoded) == https)
        let lan = try #require(URL(string: "HTTP://192.168.1.2:8080/x"))
        let http = try #require(CustomScheme.encode(lan))
        #expect(http.scheme == "blusion-http")
        #expect(CustomScheme.decode(http)?.absoluteString == "http://192.168.1.2:8080/x")
    }

    @Test func customSchemeRejectsEverythingElse() throws {
        #expect(CustomScheme.encode(try #require(URL(string: "ftp://e.com/x"))) == nil)
        #expect(CustomScheme.encode(try #require(URL(string: "file:///etc/passwd"))) == nil)
        #expect(CustomScheme.decode(try #require(URL(string: "https://e.com/x"))) == nil, "only our own scheme decodes")
        #expect(CustomScheme.decode(try #require(URL(string: "blusion-ftp://e.com/x"))) == nil)
        #expect(CustomScheme.decode(try #require(URL(string: "blusion-file:///x"))) == nil)
    }

    @Test func byteRangeHeaders() {
        #expect(ByteRange.header(offset: 0, length: 2, toEnd: false) == "bytes=0-1")
        #expect(ByteRange.header(offset: 100, length: 50, toEnd: false) == "bytes=100-149")
        #expect(ByteRange.header(offset: 100, length: 50, toEnd: true) == "bytes=100-")
        #expect(ByteRange.header(offset: 7, length: nil, toEnd: false) == "bytes=7-")
        #expect(ByteRange.header(offset: 5, length: 0, toEnd: false) == "bytes=5-5", "a zero-length request still asks for one byte")
    }

    @Test func totalLengthFromContentRange() {
        #expect(ByteRange.totalLength(fromContentRange: "bytes 0-1/204402") == 204402)
        #expect(ByteRange.totalLength(fromContentRange: "bytes 100-199/1000 ") == 1000)
        #expect(ByteRange.totalLength(fromContentRange: "bytes 0-1/*") == nil)
        #expect(ByteRange.totalLength(fromContentRange: "garbage") == nil)
        #expect(ByteRange.totalLength(fromContentRange: nil) == nil)
    }

    @Test func playlistDetection() {
        #expect(HLSPlaylistRewriter.looksLikePlaylist(Data("#EXTM3U\n".utf8)))
        #expect(HLSPlaylistRewriter.looksLikePlaylist(Data("\u{FEFF}#EXTM3U\n".utf8)))
        #expect(!HLSPlaylistRewriter.looksLikePlaylist(Data("<html>".utf8)))
    }

    @Test func rewritesSegmentsKeysAndNestedPlaylists() throws {
        let base = try #require(URL(string: "https://cdn.example.com/video/index.m3u8"))
        let playlist = """
        #EXTM3U
        #EXT-X-VERSION:3
        #EXT-X-KEY:METHOD=AES-128,URI="keys/k1.bin",IV=0x01
        #EXT-X-MAP:URI="https://other.example.com/init.mp4"
        #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="a",URI="audio/en.m3u8"
        #EXTINF:2.0,
        seg000.ts
        #EXTINF:2.0,
        /abs/seg001.ts
        #EXTINF:2.0,
        https://third.example.com/seg002.ts?token=1
        #EXT-X-ENDLIST
        """
        let rewritten = HLSPlaylistRewriter.rewrite(playlist, baseURL: base, map: CustomScheme.encode)
        let lines = rewritten.components(separatedBy: "\n")
        #expect(lines[0] == "#EXTM3U" && lines[1] == "#EXT-X-VERSION:3")
        #expect(lines[2] == "#EXT-X-KEY:METHOD=AES-128,URI=\"blusion-https://cdn.example.com/video/keys/k1.bin\",IV=0x01")
        #expect(lines[3] == "#EXT-X-MAP:URI=\"blusion-https://other.example.com/init.mp4\"")
        #expect(lines[4] == "#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"a\",URI=\"blusion-https://cdn.example.com/video/audio/en.m3u8\"")
        #expect(lines[6] == "blusion-https://cdn.example.com/video/seg000.ts")
        #expect(lines[8] == "blusion-https://cdn.example.com/abs/seg001.ts")
        #expect(lines[10] == "blusion-https://third.example.com/seg002.ts?token=1")
        #expect(lines[11] == "#EXT-X-ENDLIST")
        #expect(!rewritten.contains("\nseg000.ts"))
    }

    @Test func rewriteKeepsLineEndingsAndBlankLinesAndUnmappableURIs() throws {
        let base = try #require(URL(string: "https://cdn.example.com/v/index.m3u8"))
        let crlf = "#EXTM3U\r\n#EXTINF:2,\r\nseg.ts\r\n\r\n"
        let out = HLSPlaylistRewriter.rewrite(crlf, baseURL: base, map: CustomScheme.encode)
        #expect(out == "#EXTM3U\n#EXTINF:2,\nblusion-https://cdn.example.com/v/seg.ts\n\n", "CRLF input is rewritten too; output uses LF")
        let bareCR = HLSPlaylistRewriter.rewrite("#EXTM3U\r#EXTINF:2,\rseg.ts\r", baseURL: base, map: CustomScheme.encode)
        #expect(bareCR.contains("blusion-https://cdn.example.com/v/seg.ts"))
        let left = HLSPlaylistRewriter.rewrite("#EXTM3U\nftp://x.example.com/seg.ts\n#EXT-X-KEY:URI=\"data:text/plain;base64,AAAA\"\n", baseURL: base, map: CustomScheme.encode)
        #expect(left.contains("ftp://x.example.com/seg.ts") && left.contains("URI=\"data:text/plain;base64,AAAA\""), "URIs that can't be mapped are left alone")
    }

    @Test func unterminatedQuotesDoNotCrash() throws {
        let base = try #require(URL(string: "https://cdn.example.com/v/index.m3u8"))
        _ = HLSPlaylistRewriter.rewrite("#EXT-X-KEY:URI=\"never closed\n", baseURL: base, map: CustomScheme.encode)
        _ = HLSPlaylistRewriter.rewrite("", baseURL: base, map: CustomScheme.encode)
    }
}
