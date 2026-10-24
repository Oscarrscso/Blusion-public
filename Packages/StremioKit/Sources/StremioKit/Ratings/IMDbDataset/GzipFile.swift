#if canImport(Compression)
import Compression
import Foundation

public enum GzipError: Error, Equatable {
    case notGzip
    case unsupported
    case truncated
    case corrupt
    case checksumMismatch
    case sizeMismatch
}

/// CRC-32 as gzip stores it (IEEE 802.3, reflected).
struct CRC32 {
    private static let table: [UInt32] = (0..<256).map { index in
        var value = UInt32(index)
        for _ in 0..<8 { value = value & 1 == 1 ? (value >> 1) ^ 0xEDB8_8320 : value >> 1 }
        return value
    }
    private(set) var value: UInt32 = 0

    mutating func update(_ bytes: UnsafeBufferPointer<UInt8>) {
        var crc = ~value
        Self.table.withUnsafeBufferPointer { table in
            for byte in bytes { crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8) }
        }
        value = ~crc
    }
}

/// Reads a gzip file in fixed-size pieces, so the 25 MB of text in IMDb's ratings file is never in memory at once.
/// Compression's zlib codec inflates the raw deflate stream; the gzip header and trailer are handled here, and the trailer's CRC-32
/// and length are checked, so a truncated or damaged download is an error and never a short table. Only a single gzip member is
/// read, which is what IMDb publishes.
enum GzipFile {
    /// Calls `body` with each piece of the uncompressed bytes, in order.
    static func inflate(fileAt url: URL, bufferSize: Int = 1 << 18, body: (UnsafeBufferPointer<UInt8>) throws -> Void) throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        guard let head = try handle.read(upToCount: bufferSize), !head.isEmpty else { throw GzipError.truncated }
        let headerLength = try headerLength(of: [UInt8](head.prefix(4096)))
        guard headerLength <= head.count else { throw GzipError.truncated }

        // The stream wants valid pointers even before it has input.
        let placeholder = UnsafeMutablePointer<UInt8>.allocate(capacity: 1)
        defer { placeholder.deallocate() }
        var stream = compression_stream(dst_ptr: placeholder, dst_size: 0, src_ptr: UnsafePointer(placeholder), src_size: 0, state: nil)
        guard compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
            throw GzipError.corrupt
        }
        defer { compression_stream_destroy(&stream) }
        let output = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { output.deallocate() }

        var crc = CRC32()
        var total: UInt64 = 0
        var pending = head.dropFirst(headerLength)
        var inputEnded = false
        var finished = false
        while !finished {
            try Task.checkCancellation()
            if pending.isEmpty, !inputEnded {
                if let next = try handle.read(upToCount: bufferSize), !next.isEmpty { pending = next } else { inputEnded = true }
            }
            let flags = inputEnded ? Int32(COMPRESSION_STREAM_FINALIZE.rawValue) : 0
            try pending.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                let base = raw.bindMemory(to: UInt8.self).baseAddress ?? UnsafePointer(placeholder)
                stream.src_ptr = base
                stream.src_size = raw.count
                while true {
                    stream.dst_ptr = output
                    stream.dst_size = bufferSize
                    let status = compression_stream_process(&stream, flags)
                    let produced = bufferSize - stream.dst_size
                    if produced > 0 {
                        let piece = UnsafeBufferPointer(start: output, count: produced)
                        crc.update(piece)
                        total += UInt64(produced)
                        try body(piece)
                    }
                    switch status {
                    case COMPRESSION_STATUS_OK:
                        // The decoder keeps input it has taken in and hands out its output over several calls, so ask again until a call
                        // makes no output: only then is it waiting for more input (or, at the end of the file, the data is cut short).
                        if produced > 0 || stream.dst_size == 0 { continue }
                        if inputEnded { throw GzipError.truncated }
                        return
                    case COMPRESSION_STATUS_END:
                        finished = true
                        return
                    default:
                        throw GzipError.corrupt
                    }
                }
            }
            pending = Data()
        }

        // The trailer is the last 8 bytes of the file: CRC-32 and the length modulo 2^32, both little-endian. The decoder takes in every
        // byte it is given and does not say where the deflate data ended, so the trailer is read from the end of the file instead.
        let fileSize = try handle.seekToEnd()
        guard fileSize >= UInt64(headerLength + 8) else { throw GzipError.truncated }
        try handle.seek(toOffset: fileSize - 8)
        guard let tail = try handle.read(upToCount: 8), tail.count == 8 else { throw GzipError.truncated }
        let trailer = [UInt8](tail)
        let expectedCRC = littleEndian32(trailer, at: 0)
        let expectedSize = littleEndian32(trailer, at: 4)
        guard crc.value == expectedCRC else { throw GzipError.checksumMismatch }
        guard UInt32(truncatingIfNeeded: total) == expectedSize else { throw GzipError.sizeMismatch }
    }

    /// Bytes taken by the gzip header, including its optional fields.
    static func headerLength(of bytes: [UInt8]) throws -> Int {
        guard bytes.count >= 10, bytes[0] == 0x1F, bytes[1] == 0x8B else { throw GzipError.notGzip }
        guard bytes[2] == 8 else { throw GzipError.unsupported }
        let flags = bytes[3]
        var index = 10
        if flags & 0x04 != 0 {
            guard index + 2 <= bytes.count else { throw GzipError.truncated }
            index += 2 + Int(bytes[index]) + (Int(bytes[index + 1]) << 8)
        }
        for flag: UInt8 in [0x08, 0x10] where flags & flag != 0 {
            guard let end = bytes[min(index, bytes.count)...].firstIndex(of: 0) else { throw GzipError.truncated }
            index = end + 1
        }
        if flags & 0x02 != 0 { index += 2 }
        guard index <= bytes.count else { throw GzipError.truncated }
        return index
    }

    private static func littleEndian32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        (0..<4).reduce(UInt32(0)) { $0 | UInt32(bytes[offset + $1]) << UInt32(8 * $1) }
    }
}
#endif
