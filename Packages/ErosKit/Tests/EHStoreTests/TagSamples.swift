import Foundation
import Testing

/// Made-up EhTagTranslation database files for the tag translation tests.
enum TagSamples {
    /// Resources/tag-db-sample.json.gz: the sample below, compressed with `gzip -n -9`.
    static func gzip() throws -> Data {
        try resource("tag-db-sample.json.gz")
    }

    /// Resources/tag-db-sample.json: 8 entries in "rows", "female", "other" and "cosplayer", keys out of order.
    static func json() throws -> Data {
        try resource("tag-db-sample.json")
    }

    /// One "female" namespace with `count` entries: "fake 00000" → "示例 00000", "fake 00001" → "示例 00001", …
    static func synthetic(count: Int) -> Data {
        var entries: [String] = []
        entries.reserveCapacity(count)
        for index in 0..<count {
            let number = String(format: "%05d", index)
            entries.append(#""fake \#(number)":{"name":"示例 \#(number)"}"#)
        }
        let body = entries.joined(separator: ",")
        return Data(#"{"data":[{"namespace":"female","data":{\#(body)}}]}"#.utf8)
    }

    /// `gzip` with FEXTRA, FNAME, FCOMMENT and FHCRC set (FLG |= 0x1E) and their fields inserted after the fixed
    /// 10-byte header: XLEN 4 + "abcd", "name.json\0", "comment\0" and a 2-byte header CRC.
    static func withHeaderFields(_ gzip: Data) -> Data {
        var bytes = [UInt8](gzip)
        bytes[3] |= 0x1E
        let fields: [UInt8] = [0x04, 0x00] + Array("abcd".utf8) + Array("name.json\0".utf8)
            + Array("comment\0".utf8) + [0x00, 0x00]
        bytes.insert(contentsOf: fields, at: 10)
        return Data(bytes)
    }

    /// `gzip` with FEXTRA set and an XLEN of 65535 inserted after the fixed header, far past the end of the data.
    static func withExtraFieldBeyondTheEnd(_ gzip: Data) -> Data {
        var bytes = [UInt8](gzip)
        bytes[3] |= 0x04
        bytes.insert(contentsOf: [0xFF, 0xFF], at: 10)
        return Data(bytes)
    }

    /// A gzip header with FNAME set whose file name never ends: not a single 0x00 byte anywhere in the data.
    static func unterminatedFileName() -> Data {
        let header: [UInt8] = [0x1F, 0x8B, 0x08, 0x08, 0x01, 0x02, 0x03, 0x04, 0x02, 0x03]
        return Data(header + Array("fake-name.json".utf8) + [UInt8](repeating: 0xFF, count: 8))
    }

    /// A 10-byte gzip header (DEFLATE, the given `method` and `flags`), then `fields`, then a trailer that claims
    /// 1 byte of content, so that only the header checks can reject the archive.
    static func archive(method: UInt8 = 0x08, flags: UInt8, fields: [UInt8]) -> Data {
        let header: [UInt8] = [0x1F, 0x8B, method, flags, 0x01, 0x02, 0x03, 0x04, 0x02, 0x03]
        return Data(header + fields + [0xFF, 0xFF, 0xFF, 0xFF, 0x01, 0x00, 0x00, 0x00])
    }

    private static func resource(_ name: String) throws -> Data {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Resources"))
        return try Data(contentsOf: url)
    }
}
