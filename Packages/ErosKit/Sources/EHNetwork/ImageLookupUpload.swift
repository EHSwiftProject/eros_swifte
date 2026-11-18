import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

extension ImageFormat {
    /// The format the first bytes of `data` show: JPEG `FF D8 FF`, PNG `89 50 4E 47 0D 0A 1A 0A`, GIF `GIF87a` or
    /// `GIF89a`, WebP `RIFF` then `WEBP` at offset 8; nil for anything else (TIFF, HEIC, …). Only the signature is
    /// read: the rest may still be no image.
    public init?(sniffing data: Data) {
        let head = [UInt8](data.prefix(12))
        func starts(with bytes: [UInt8], at offset: Int = 0) -> Bool {
            head.count >= offset + bytes.count && Array(head[offset..<offset + bytes.count]) == bytes
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

/// An image ready for an image search upload.
///
/// `description` and the mirror give the format and the size only: the bytes are the user's image.
public struct PreparedImage: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible,
    CustomReflectable {
    /// The bytes to send.
    public let data: Data
    /// What `data` is.
    public let format: ImageFormat
    /// `data` is a JPEG made from the image picked, not the file itself: the site can then only find similar images,
    /// never this exact file (it matches files by their hash).
    public let wasReencoded: Bool

    public init(data: Data, format: ImageFormat, wasReencoded: Bool) {
        self.data = data
        self.format = format
        self.wasReencoded = wasReencoded
    }

    /// "PreparedImage(png, 1234 bytes)", with ", reencoded" for a JPEG made here.
    public var description: String {
        "PreparedImage(\(format.rawValue), \(data.count) bytes\(wasReencoded ? ", reencoded" : ""))"
    }

    public var debugDescription: String { description }

    public var customMirror: Mirror {
        Mirror(self, children: ["description": description])
    }
}

/// Why an image cannot be uploaded.
public enum ImageLookupUploadError: Error, Equatable {
    /// ImageIO reads no image from the bytes.
    case notAnImage
    /// The bytes are over `ImageLookupUpload.maximumInputBytes`, or no JPEG of the image down to 512 pixels on its
    /// long edge fits the upload limit.
    case tooLarge
}

/// What an image search uploads for the bytes the user picked.
///
/// The site matches an exact file by its hash, which any change of the bytes loses, so the file goes as it is whenever
/// the site takes it: one of the four formats it reads (`ImageFormat`, animated GIF and WebP included) within the
/// limit. Anything else is made a JPEG (quality 0.85) of the first frame, turned as its EXIF orientation says: at the
/// full size first, then at half the long edge again and again while that stays at least 512 pixels, until one fits
/// the limit. The limits are this app's own (search plan index §7); the site's are checked on a device (entry E4).
public enum ImageLookupUpload {
    /// The most an upload may be: 10 MiB.
    public static let maximumUploadBytes = 10 * 1024 * 1024
    /// The most a picked file may be (50 MiB): a larger one is not read at all.
    public static let maximumInputBytes = 50 * 1024 * 1024
    /// The long edge the JPEG steps never go below.
    static let smallestLongEdge = 512
    /// The JPEG quality of a converted image.
    static let jpegQuality = 0.85

    /// The upload for `data` within `limit` bytes; see the type.
    ///
    /// - Throws: `ImageLookupUploadError.tooLarge` for more than `maximumInputBytes`, or when no JPEG step fits;
    ///   `.notAnImage` when ImageIO reads no image.
    public static func prepare(_ data: Data, limit: Int = maximumUploadBytes) throws -> PreparedImage {
        guard data.count <= maximumInputBytes else { throw ImageLookupUploadError.tooLarge }
        if let format = ImageFormat(sniffing: data), data.count <= limit {
            return PreparedImage(data: data, format: format, wasReencoded: false)
        }
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions),
              CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0
        else { throw ImageLookupUploadError.notAnImage }
        for longEdge in steps(from: max(width, height)) {
            guard let jpeg = jpeg(from: source, longEdge: longEdge) else { throw ImageLookupUploadError.notAnImage }
            if jpeg.count <= limit { return PreparedImage(data: jpeg, format: .jpeg, wasReencoded: true) }
        }
        throw ImageLookupUploadError.tooLarge
    }

    /// `longEdge`, then half of it again and again while that is at least `smallestLongEdge`.
    static func steps(from longEdge: Int) -> [Int] {
        var steps = [longEdge]
        var next = longEdge / 2
        while next >= smallestLongEdge {
            steps.append(next)
            next /= 2
        }
        return steps
    }

    /// The first frame of `source` as a JPEG at most `longEdge` pixels on its long edge, turned upright by its EXIF
    /// orientation; nil when ImageIO cannot make it.
    private static func jpeg(from source: CGImageSource, longEdge: Int) -> Data? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: longEdge,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(
            destination, image, [kCGImageDestinationLossyCompressionQuality: jpegQuality] as CFDictionary
        )
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }
}
