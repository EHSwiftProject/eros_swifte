import Compression
import Foundation

/// Decompresses gzip archives (RFC 1952) with the system's raw DEFLATE decoder.
///
/// Only the first member is read: GitHub's assets have one, and a file with more fails the CRC-32 check of the last
/// member's trailer, so it counts as damaged. Every byte is bounds-checked before it is read; damaged input throws
/// instead of trapping.
enum Gzip {
    /// The largest decompressed size accepted, and the largest plain file `TagTranslationStore` reads: 64 MiB. The real
    /// database takes about 12 MB once imported, full-text index included, so this leaves it room to grow, while an
    /// answer from a mirror cannot make the app allocate hundreds of MiB (the size in the trailer is checked before
    /// anything is allocated).
    static let maximumSize = 64 << 20

    /// Header flags (FLG), RFC 1952 §2.3.1.
    private static let headerCRCFlag: UInt8 = 0x02
    private static let extraFieldFlag: UInt8 = 0x04
    private static let fileNameFlag: UInt8 = 0x08
    private static let commentFlag: UInt8 = 0x10
    private static let reservedFlags: UInt8 = 0xE0

    /// Whether `data` starts with the gzip magic bytes 1f 8b; anything else is taken as plain JSON.
    static func isArchive(_ data: Data) -> Bool {
        data.starts(with: [0x1F, 0x8B])
    }

    /// The decompressed content of the first member of `data`.
    ///
    /// - Throws: `TagDatabaseError.corruptArchive` when the header is not gzip with DEFLATE, a header field runs past
    ///   the trailer, the stream is truncated or damaged, the size is 0 or above `maximumSize`, or the CRC-32 or size
    ///   in the trailer does not match the output.
    static func decompress(_ data: Data) throws(TagDatabaseError) -> Data {
        let bytes = [UInt8](data)
        // 10-byte fixed header + 8-byte trailer (CRC32, ISIZE).
        guard bytes.count >= 18, bytes[0] == 0x1F, bytes[1] == 0x8B,
              bytes[2] == 8, bytes[3] & reservedFlags == 0 else {
            throw .corruptArchive
        }
        let flags = bytes[3]
        let trailer = bytes.count - 8
        var position = 10
        if flags & extraFieldFlag != 0 {
            guard trailer - position >= 2 else { throw .corruptArchive }
            let length = Int(bytes[position]) | Int(bytes[position + 1]) << 8
            position += 2
            guard trailer - position >= length else { throw .corruptArchive }
            position += length
        }
        if flags & fileNameFlag != 0 {
            position = try endOfTerminatedField(in: bytes, from: position, before: trailer)
        }
        if flags & commentFlag != 0 {
            position = try endOfTerminatedField(in: bytes, from: position, before: trailer)
        }
        if flags & headerCRCFlag != 0 {
            // The header CRC is skipped, not checked: the CRC-32 of the content covers what matters.
            guard trailer - position >= 2 else { throw .corruptArchive }
            position += 2
        }
        // Each step above already stops at the trailer; this keeps the slice below valid whatever changes there.
        guard position <= trailer else { throw .corruptArchive }

        let crc = littleEndianUInt32(in: bytes, at: trailer)
        let size = Int(littleEndianUInt32(in: bytes, at: trailer + 4))
        guard size > 0, size <= maximumSize else { throw .corruptArchive }

        var output = Data(count: size)
        let written = output.withUnsafeMutableBytes { destination in
            bytes[position..<trailer].withUnsafeBufferPointer { source in
                guard let destinationAddress = destination.baseAddress, let sourceAddress = source.baseAddress,
                      !source.isEmpty else {
                    return 0
                }
                return compression_decode_buffer(
                    destinationAddress.assumingMemoryBound(to: UInt8.self), size,
                    sourceAddress, source.count,
                    nil, COMPRESSION_ZLIB
                )
            }
        }
        guard written == size, crc32(output) == crc else { throw .corruptArchive }
        return output
    }

    /// CRC-32/ISO-HDLC (the gzip and zlib checksum): reflected polynomial 0xEDB88320, initial and final XOR 0xFFFFFFFF.
    static func crc32(_ data: Data) -> UInt32 {
        data.withUnsafeBytes { buffer in
            crcTable.withUnsafeBufferPointer { table in
                var crc: UInt32 = 0xFFFF_FFFF
                for byte in buffer {
                    crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
                }
                return ~crc
            }
        }
    }

    private static let crcTable: [UInt32] = (0..<256).map { index in
        var value = UInt32(index)
        for _ in 0..<8 {
            value = value & 1 == 1 ? 0xEDB8_8320 ^ (value >> 1) : value >> 1
        }
        return value
    }

    /// The index just past the 0x00 that ends the field starting at `start`; the field must end before `end`.
    private static func endOfTerminatedField(
        in bytes: [UInt8], from start: Int, before end: Int
    ) throws(TagDatabaseError) -> Int {
        guard start < end, let zero = bytes[start..<end].firstIndex(of: 0) else { throw .corruptArchive }
        return zero + 1
    }

    /// The 4 bytes at `offset`, little-endian; the caller has checked that they exist.
    private static func littleEndianUInt32(in bytes: [UInt8], at offset: Int) -> UInt32 {
        UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8 | UInt32(bytes[offset + 2]) << 16
            | UInt32(bytes[offset + 3]) << 24
    }
}
