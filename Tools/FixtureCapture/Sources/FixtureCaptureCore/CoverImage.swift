import Foundation

/// An image format the image lookup is sent as: the file name and MIME type of the uploaded cover.
public enum CoverImageFormat: String, Sendable, CaseIterable {
    case jpeg, png, gif, webp

    /// `a.jpg`, `a.png`, `a.gif` or `a.webp`.
    public var fileName: String {
        switch self {
        case .jpeg: "a.jpg"
        case .png: "a.png"
        case .gif: "a.gif"
        case .webp: "a.webp"
        }
    }

    /// `image/jpeg`, `image/png`, `image/gif` or `image/webp`.
    public var mimeType: String { "image/\(rawValue)" }

    /// The format a `Content-Type` value names (`image/jpeg`, also `image/jpg` and `image/pjpeg`; `image/png`;
    /// `image/gif`; `image/webp`), ignoring case and parameters such as `; charset=…`. Nil for anything else.
    public init?(contentType: String?) {
        guard let contentType else { return nil }
        let type = contentType.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false).first
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? ""
        switch type {
        case "image/jpeg", "image/jpg", "image/pjpeg": self = .jpeg
        case "image/png": self = .png
        case "image/gif": self = .gif
        case "image/webp": self = .webp
        default: return nil
        }
    }

    /// The format the file header shows: JPEG `FF D8 FF`, PNG `89 50 4E 47 0D 0A 1A 0A`, GIF `GIF87a`/`GIF89a`,
    /// WebP `RIFF` + 4 bytes + `WEBP`. Nil for anything else.
    public init?(fileHeader data: Data) {
        let bytes = Array(data.prefix(12))
        func starts(with prefix: [UInt8], at offset: Int = 0) -> Bool {
            bytes.count >= offset + prefix.count && Array(bytes[offset..<offset + prefix.count]) == prefix
        }
        if starts(with: [0xFF, 0xD8, 0xFF]) {
            self = .jpeg
        } else if starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) {
            self = .png
        } else if starts(with: Array("GIF87a".utf8)) || starts(with: Array("GIF89a".utf8)) {
            self = .gif
        } else if starts(with: Array("RIFF".utf8)), starts(with: Array("WEBP".utf8), at: 8) {
            self = .webp
        } else {
            return nil
        }
    }
}

/// The downloaded gallery cover and the format it is uploaded to the image lookup as. It holds the image, so
/// printing, debug-printing or dumping it shows only the format and the size.
public struct CoverImage: Sendable, Equatable {
    public let data: Data
    public let format: CoverImageFormat

    public init(data: Data, format: CoverImageFormat) {
        self.data = data
        self.format = format
    }

    /// What was off about how the format was chosen.
    enum FormatProblem: Equatable {
        /// Neither the `Content-Type` nor the file header names a known format; the cover is sent as JPEG.
        case unrecognized
        /// Both name a known format, but not the same one; the cover is sent as the `Content-Type` says.
        case mismatch(contentType: CoverImageFormat, fileHeader: CoverImageFormat)
    }

    /// The cover from an image response: the format its `Content-Type` names, else the one its file header shows,
    /// else JPEG.
    /// - Returns: The cover, and what was off, if anything.
    static func from(data: Data, contentType: String?) -> (cover: CoverImage, problem: FormatProblem?) {
        let declared = CoverImageFormat(contentType: contentType)
        let sniffed = CoverImageFormat(fileHeader: data)
        let problem: FormatProblem? = switch (declared, sniffed) {
        case (nil, nil): .unrecognized
        case let (declared?, sniffed?) where declared != sniffed: .mismatch(contentType: declared, fileHeader: sniffed)
        default: nil
        }
        return (CoverImage(data: data, format: declared ?? sniffed ?? .jpeg), problem)
    }
}

extension CoverImage: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String { "CoverImage(\(format.rawValue), \(data.count) bytes)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror {
        Mirror(self, children: ["format": format, "bytes": data.count], displayStyle: .struct)
    }
}
