import Foundation

/// The OpenSubtitles "moviehash": a 64-bit checksum of a file's size and its first and last 64 KB. OpenSubtitles matches it against the exact
/// release, so a hash match means the subtitle was made for this file. Two small reads are enough to compute it for a remote file.
public enum MovieHash {
    public static let chunkSize = 65536

    /// The hash of a file of `size` bytes whose first and last `chunkSize` bytes are `head` and `tail`, as 16 lowercase hex digits.
    /// nil for files under two chunks, and when either chunk is short.
    public static func compute(size: Int64, head: Data, tail: Data) -> String? {
        guard size >= Int64(2 * chunkSize), head.count >= chunkSize, tail.count >= chunkSize else { return nil }
        var hash = UInt64(bitPattern: size)
        hash = hash &+ wordSum(head.prefix(chunkSize))
        hash = hash &+ wordSum(tail.suffix(chunkSize))
        let hex = String(hash, radix: 16)
        return String(repeating: "0", count: 16 - hex.count) + hex
    }

    /// Reads the first and last chunk of a remote file with two ranged requests. `size` saves the first request's total when the caller
    /// already knows it. nil when the size is unknown or too small, or when the server cannot serve ranges.
    public static func compute(url: URL, headers: [String: String], size: Int64?, client: AddonClient) async -> String? {
        if let size, size < Int64(2 * chunkSize) { return nil }
        do {
            let head = try await client.range(of: url, offset: 0, length: chunkSize, headers: headers)
            guard let total = size ?? head.totalLength, total >= Int64(2 * chunkSize) else { return nil }
            let tail = try await client.range(of: url, offset: total - Int64(chunkSize), length: chunkSize, headers: headers)
            return compute(size: total, head: head.data, tail: tail.data)
        } catch {
            return nil
        }
    }

    /// Wrapping sum of the little-endian 64-bit words in `bytes`. Trailing bytes that do not fill a word are ignored.
    private static func wordSum(_ bytes: Data) -> UInt64 {
        let values = Array(bytes)
        var total: UInt64 = 0
        var index = 0
        while index + 8 <= values.count {
            var word: UInt64 = 0
            for byte in 0..<8 {
                word |= UInt64(values[index + byte]) << (8 * byte)
            }
            total = total &+ word
            index += 8
        }
        return total
    }
}
