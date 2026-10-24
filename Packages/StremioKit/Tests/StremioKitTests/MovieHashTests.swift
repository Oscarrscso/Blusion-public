import Foundation
import Testing
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import StremioKit
import StremioKitTestSupport

@Suite struct MovieHashTests {
    private static let url = URL(string: "https://files.example.com/movie.mkv")!
    private static let chunk = MovieHash.chunkSize

    /// The hash written as the format describes it, one byte at a time: size, then each little-endian word of both chunks, wrapping.
    private func reference(size: Int64, head: [UInt8], tail: [UInt8]) -> String {
        var total = UInt64(bitPattern: size)
        for block in [head, tail] {
            for start in stride(from: 0, to: block.count, by: 8) {
                var word: UInt64 = 0
                for byte in 0..<8 {
                    word += UInt64(block[start + byte]) << (8 * byte)
                }
                total = total &+ word
            }
        }
        let hex = String(total, radix: 16)
        return String(repeating: "0", count: 16 - hex.count) + hex
    }

    @Test func aKnownFileHashesToAFixedValue() throws {
        // Head: 65536 bytes of 0x01 is 8192 words of 0x0101010101010101; tail: 0x02 is twice that. Summed with the size:
        // 1_000_000 + 3 * 0x2020202020202000 = 0x60606060606FA240.
        let hash = MovieHash.compute(size: 1_000_000, head: Data(repeating: 0x01, count: Self.chunk),
                                     tail: Data(repeating: 0x02, count: Self.chunk))
        #expect(hash == "60606060606fa240")
        #expect(hash == reference(size: 1_000_000, head: [UInt8](repeating: 0x01, count: Self.chunk),
                                  tail: [UInt8](repeating: 0x02, count: Self.chunk)))
    }

    @Test func variedBytesMatchTheByteByByteReference() throws {
        let head = (0..<Self.chunk).map { UInt8(truncatingIfNeeded: $0 &* 37) }
        let tail = (0..<Self.chunk).map { UInt8(truncatingIfNeeded: $0 &* 11 &+ 3) }
        let hash = MovieHash.compute(size: 5_000_000, head: Data(head), tail: Data(tail))
        #expect(hash == reference(size: 5_000_000, head: head, tail: tail))
        #expect(hash?.count == 16 && hash == hash?.lowercased())
    }

    @Test func aFileUnderTwoChunksHasNoHash() {
        let chunk = Data(repeating: 0x01, count: Self.chunk)
        #expect(MovieHash.compute(size: Int64(2 * Self.chunk - 1), head: chunk, tail: chunk) == nil)
        #expect(MovieHash.compute(size: Int64(2 * Self.chunk), head: chunk, tail: chunk) != nil)
    }

    @Test func aShortChunkHasNoHash() {
        let full = Data(repeating: 0x01, count: Self.chunk)
        #expect(MovieHash.compute(size: 1_000_000, head: full.prefix(Self.chunk - 1), tail: full) == nil)
        #expect(MovieHash.compute(size: 1_000_000, head: full, tail: Data()) == nil)
    }

    @Test func aRemoteFileIsHashedFromItsFirstAndLastChunk() async throws {
        let head = Data(repeating: 0x01, count: Self.chunk)
        let tail = Data(repeating: 0x02, count: Self.chunk)
        for knownSize: Int64? in [nil, 1_000_000] {
            let transport = StubTransport { request, _ in
                let range = request.value(forHTTPHeaderField: "Range")
                if range == "bytes=0-65535" {
                    return HTTPResult(data: head, response: HTTPResponseInfo(statusCode: 206, headers: ["content-range": "bytes 0-65535/1000000"]))
                }
                if range == "bytes=934464-999999" {
                    return HTTPResult(data: tail, response: HTTPResponseInfo(statusCode: 206, headers: ["content-range": "bytes 934464-999999/1000000"]))
                }
                return StubTransport.response(Data(), status: 416, for: request)
            }
            let hash = await MovieHash.compute(url: Self.url, headers: ["X-Test": "1"], size: knownSize, client: makeClient(transport))
            #expect(hash == "60606060606fa240")
            #expect(transport.requests.compactMap { $0.value(forHTTPHeaderField: "Range") } == ["bytes=0-65535", "bytes=934464-999999"])
            #expect(transport.requests.allSatisfy { $0.value(forHTTPHeaderField: "X-Test") == "1" })
        }
    }

    @Test func aRemoteFileTooSmallIsNotRead() async {
        let transport = StubTransport(data: Data(repeating: 0, count: Self.chunk))
        let hash = await MovieHash.compute(url: Self.url, headers: [:], size: 100_000, client: makeClient(transport))
        #expect(hash == nil)
        #expect(transport.callCount == 0)
    }

    @Test func aServerThatIgnoresRangesGivesNoHash() async {
        let whole = Data(repeating: 0x07, count: 200_000)
        let transport = StubTransport(data: whole, status: 200)
        #expect(await MovieHash.compute(url: Self.url, headers: [:], size: nil, client: makeClient(transport)) == nil)
        #expect(await MovieHash.compute(url: Self.url, headers: [:], size: 1_000_000, client: makeClient(transport)) == nil)
    }
}

@Suite struct AddonClientRangeTests {
    private let url = URL(string: "https://files.example.com/movie.mkv")!

    @Test func aRangeAsksForTheBytesAndReadsTheTotal() async throws {
        let transport = StubTransport { request, _ in
            StubTransport.response(Data(repeating: 0x2A, count: 10), status: 206, for: request, headers: ["content-range": "bytes 10-19/100"])
        }
        let result = try await makeClient(transport).range(of: url, offset: 10, length: 10)
        #expect(result.data.count == 10)
        #expect(result.totalLength == 100)
        #expect(transport.requests.first?.value(forHTTPHeaderField: "Range") == "bytes=10-19")
    }

    @Test func anUnknownTotalIsNil() async throws {
        let transport = StubTransport { request, _ in
            StubTransport.response(Data(repeating: 1, count: 10), status: 206, for: request, headers: ["content-range": "bytes 0-9/*"])
        }
        let result = try await makeClient(transport).range(of: url, offset: 0, length: 10)
        #expect(result.totalLength == nil)
    }

    @Test func aWholeBodyIsAcceptedAtOffsetZeroAndCutToTheLength() async throws {
        let transport = StubTransport(data: Data(repeating: 1, count: 50), status: 200)
        let result = try await makeClient(transport).range(of: url, offset: 0, length: 10)
        #expect(result.data.count == 10)
        #expect(result.totalLength == nil)
    }

    @Test func aWholeBodyAtAnOffsetIsRefused() async {
        let transport = StubTransport(data: Data(repeating: 1, count: 50), status: 200)
        await #expect(throws: AddonError.http(status: 416)) { try await makeClient(transport).range(of: url, offset: 5, length: 10) }
    }

    @Test func aRefusedRangeFails() async {
        let transport = StubTransport(data: Data(), status: 416)
        await #expect(throws: AddonError.http(status: 416)) { try await makeClient(transport).range(of: url, offset: 0, length: 10) }
    }
}
