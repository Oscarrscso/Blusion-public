import Foundation
import Testing
@testable import StremioKit

@Suite struct ContainerSnifferTests {
    private func bytes(_ head: [UInt8], padTo count: Int = 64) -> Data {
        Data(head + [UInt8](repeating: 0, count: max(0, count - head.count)))
    }

    private func ftyp(_ brand: String) -> Data { bytes([0, 0, 0, 0x18] + Array("ftyp".utf8) + Array(brand.utf8)) }

    @Test func isoBaseMediaBrands() {
        #expect(ContainerSniffer.container(fromBytes: ftyp("isom")) == .mp4)
        #expect(ContainerSniffer.container(fromBytes: ftyp("mp42")) == .mp4)
        #expect(ContainerSniffer.container(fromBytes: ftyp("avc1")) == .mp4)
        #expect(ContainerSniffer.container(fromBytes: ftyp("M4A ")) == .mp4)
        #expect(ContainerSniffer.container(fromBytes: ftyp("qt  ")) == .mov)
        #expect(ContainerSniffer.container(fromBytes: ftyp("M4V ")) == .m4v)
        #expect(ContainerSniffer.container(fromBytes: ftyp("M4VH")) == .m4v)
    }

    @Test func hlsPlaylistsWithAndWithoutBOM() {
        #expect(ContainerSniffer.container(fromBytes: Data("#EXTM3U\n#EXT-X-VERSION:3\n".utf8)) == .hls)
        #expect(ContainerSniffer.container(fromBytes: Data([0xEF, 0xBB, 0xBF] + Array("#EXTM3U\n".utf8))) == .hls)
        #expect(ContainerSniffer.container(fromBytes: Data("\n  #EXTM3U\n".utf8)) == .hls)
        #expect(ContainerSniffer.container(fromBytes: Data("#EXTM3".utf8)) == nil)
    }

    @Test func matroskaAndWebM() {
        #expect(ContainerSniffer.container(fromBytes: bytes([0x1A, 0x45, 0xDF, 0xA3, 0x9F, 0x42, 0x86, 0x81, 0x01] + Array("matroska".utf8))) == .matroska)
        #expect(ContainerSniffer.container(fromBytes: bytes([0x1A, 0x45, 0xDF, 0xA3] + Array("\u{42}\u{82}\u{84}webm".utf8))) == .webm)
        #expect(ContainerSniffer.container(fromBytes: bytes([0x1A, 0x45, 0xDF, 0xA3])) == .matroska, "no doctype visible: assume Matroska")
    }

    @Test func otherContainers() {
        #expect(ContainerSniffer.container(fromBytes: bytes(Array("RIFF".utf8) + [0, 0, 0, 0] + Array("AVI ".utf8))) == .avi)
        #expect(ContainerSniffer.container(fromBytes: bytes(Array("RIFF".utf8) + [0, 0, 0, 0] + Array("WAVE".utf8))) == .wav)
        #expect(ContainerSniffer.container(fromBytes: bytes(Array("FLV".utf8) + [0x01])) == .flv)
        #expect(ContainerSniffer.container(fromBytes: bytes(Array("OggS".utf8))) == .ogg)
        #expect(ContainerSniffer.container(fromBytes: bytes([0x30, 0x26, 0xB2, 0x75, 0x8E, 0x66, 0xCF, 0x11])) == .asf)
        #expect(ContainerSniffer.container(fromBytes: bytes([0x00, 0x00, 0x01, 0xBA])) == .mpegPS)
        #expect(ContainerSniffer.container(fromBytes: bytes(Array("ID3".utf8) + [0x04])) == .mp3)
        #expect(ContainerSniffer.container(fromBytes: bytes([0xFF, 0xFB, 0x90, 0x00])) == .mp3)
    }

    @Test func transportStreamNeedsSyncBytesAtTheRightOffsets() {
        var ts = [UInt8](repeating: 0, count: 4096)
        for offset in stride(from: 0, to: 4096, by: 188) { ts[offset] = 0x47 }
        #expect(ContainerSniffer.container(fromBytes: Data(ts)) == .mpegTS)
        #expect(ContainerSniffer.container(fromBytes: Data(ts.prefix(100))) == nil, "too short to confirm")
        ts[188] = 0
        #expect(ContainerSniffer.container(fromBytes: Data(ts)) == nil)
    }

    @Test func tooShortOrUnknownBytesSayNothing() {
        #expect(ContainerSniffer.container(fromBytes: Data()) == nil)
        #expect(ContainerSniffer.container(fromBytes: Data([1, 2, 3])) == nil)
        #expect(ContainerSniffer.container(fromBytes: bytes([0x12, 0x34, 0x56, 0x78, 0x9A])) == nil)
        #expect(ContainerSniffer.container(fromBytes: Data("<html><body>nope</body></html>".utf8)) == nil)
    }

    @Test(arguments: [
        ("video/mp4", MediaContainer.mp4), ("video/mp4; codecs=\"avc1\"", .mp4), ("VIDEO/MP4", .mp4), ("video/quicktime", .mov),
        ("application/vnd.apple.mpegurl", .hls), ("application/x-mpegURL", .hls), ("video/x-matroska", .matroska), ("video/webm", .webm),
        ("video/x-msvideo", .avi), ("video/mp2t", .mpegTS), ("video/x-flv", .flv), ("audio/mpeg", .mp3),
    ] as [(String, MediaContainer)])
    func contentTypes(type: String, expected: MediaContainer) {
        #expect(ContainerSniffer.container(fromContentType: type) == expected)
    }

    @Test func uninformativeContentTypesSayNothing() {
        for type in ["application/octet-stream", "binary/octet-stream", "text/plain", "text/html", "", "garbage"] {
            #expect(ContainerSniffer.container(fromContentType: type) == nil, "\(type)")
        }
        #expect(ContainerSniffer.container(fromContentType: nil) == nil)
    }

    @Test(arguments: [
        ("mp4", MediaContainer.mp4), ("MP4", .mp4), ("m4v", .m4v), ("mov", .mov), ("m3u8", .hls), ("mkv", .matroska), ("webm", .webm),
        ("avi", .avi), ("ts", .mpegTS), ("m2ts", .mpegTS), ("flv", .flv), ("wmv", .asf), ("mpg", .mpegPS),
    ] as [(String, MediaContainer)])
    func extensions(ext: String, expected: MediaContainer) {
        #expect(ContainerSniffer.container(fromPathExtension: ext) == expected)
    }

    @Test func filenameHintBeatsTheURLExtension() throws {
        let url = try #require(URL(string: "https://cdn.example.com/download/12345.mp4"))
        #expect(ContainerSniffer.container(url: url, filename: "Movie.mkv") == .matroska)
        #expect(ContainerSniffer.container(url: url, filename: nil) == .mp4)
        #expect(ContainerSniffer.container(url: url, filename: "no-extension") == .mp4)
        #expect(ContainerSniffer.container(url: try #require(URL(string: "https://cdn.example.com/blob")), filename: nil) == nil)
    }

    @Test func bytesBeatContentTypeBeatExtension() throws {
        let url = try #require(URL(string: "https://cdn.example.com/a.mkv"))
        #expect(ContainerSniffer.detect(bytes: ftyp("isom"), contentType: "video/x-matroska", url: url) == .mp4)
        #expect(ContainerSniffer.detect(bytes: bytes([1, 2, 3, 4, 5]), contentType: "video/mp4", url: url) == .mp4)
        #expect(ContainerSniffer.detect(bytes: nil, contentType: "application/octet-stream", url: url) == .matroska)
        #expect(ContainerSniffer.detect(bytes: nil, contentType: nil, url: try #require(URL(string: "https://x.example.com/blob"))) == nil)
    }

    @Test func nativeContainersAreExactlyMP4MOVM4VAndHLS() {
        #expect(Set(MediaContainer.allCases.filter(\.isNativelyPlayable)) == [.mp4, .mov, .m4v, .hls])
    }
}
