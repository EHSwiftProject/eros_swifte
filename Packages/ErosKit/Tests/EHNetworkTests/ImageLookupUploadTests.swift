import CoreGraphics
import EHNetwork
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

/// `ImageFormat(sniffing:)` and `ImageLookupUpload.prepare(_:limit:)` (search Q5). Every image is made here, with
/// ImageIO; the noise comes from a fixed seed, so its bytes are the same on every run.
struct ImageLookupUploadTests {
    /// SplitMix64: the same numbers for the same seed, unlike the system's generator.
    private struct SeededGenerator: RandomNumberGenerator {
        var state: UInt64

        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    /// A `width` × `height` RGBA image: noise from `seed`, or one flat colour when `seed` is nil.
    private static func image(width: Int, height: Int, seed: UInt64? = nil) throws -> CGImage {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        var generator = SeededGenerator(state: seed ?? 0)
        for index in stride(from: 0, to: pixels.count, by: 4) {
            if seed != nil {
                let value = generator.next()
                pixels[index] = UInt8(truncatingIfNeeded: value)
                pixels[index + 1] = UInt8(truncatingIfNeeded: value >> 8)
                pixels[index + 2] = UInt8(truncatingIfNeeded: value >> 16)
            } else {
                pixels[index] = 0x33
                pixels[index + 1] = 0x66
                pixels[index + 2] = 0x99
            }
            pixels[index + 3] = 0xFF
        }
        let provider = try #require(CGDataProvider(data: Data(pixels) as CFData))
        return try #require(CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue), provider: provider,
            decode: nil, shouldInterpolate: false, intent: .defaultIntent
        ))
    }

    /// `image` encoded as `type` (PNG, TIFF, …).
    private static func encoded(_ image: CGImage, as type: UTType) throws -> Data {
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }

    /// The longer side, in pixels, of the image `data` holds.
    private static func longEdge(of data: Data) throws -> Int {
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        let width = try #require(properties[kCGImagePropertyPixelWidth] as? Int)
        let height = try #require(properties[kCGImagePropertyPixelHeight] as? Int)
        return max(width, height)
    }

    /// The stored width and height of the image `data` holds, and its orientation property when it has one.
    private static func geometry(of data: Data) throws -> (width: Int, height: Int, orientation: Int?) {
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        return (
            try #require(properties[kCGImagePropertyPixelWidth] as? Int),
            try #require(properties[kCGImagePropertyPixelHeight] as? Int),
            properties[kCGImagePropertyOrientation] as? Int
        )
    }

    /// Bytes that start like no image format.
    private static let notAnImage = Data((0..<256).map { UInt8(truncatingIfNeeded: $0 &* 37 &+ 11) })

    @Test func sniffsTheFourFormats() throws {
        func bytes(_ head: [UInt8]) -> Data { Data(head + [UInt8](repeating: 0, count: 16)) }
        #expect(ImageFormat(sniffing: bytes([0xFF, 0xD8, 0xFF, 0xE0])) == .jpeg)
        #expect(ImageFormat(sniffing: bytes([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])) == .png)
        #expect(ImageFormat(sniffing: bytes(Array("GIF87a".utf8))) == .gif)
        #expect(ImageFormat(sniffing: bytes(Array("GIF89a".utf8))) == .gif)
        #expect(ImageFormat(sniffing: bytes(Array("RIFF".utf8) + [0x24, 0, 0, 0] + Array("WEBP".utf8))) == .webp)

        #expect(ImageFormat(sniffing: bytes(Array("RIFF".utf8) + [0x24, 0, 0, 0] + Array("WAVE".utf8))) == nil)
        #expect(ImageFormat(sniffing: bytes(Array("GIF90a".utf8))) == nil)
        #expect(ImageFormat(sniffing: Data([0x89, 0x50, 0x4E, 0x47])) == nil)
        #expect(ImageFormat(sniffing: Data()) == nil)
        #expect(ImageFormat(sniffing: Self.notAnImage) == nil)
        let tiff = try Self.encoded(try Self.image(width: 8, height: 8), as: .tiff)
        #expect(ImageFormat(sniffing: tiff) == nil)
    }

    /// A supported image under the limit goes as it is, byte for byte: the site matches the exact file by its hash.
    @Test func smallSupportedImageIsSentAsIs() throws {
        let png = try Self.encoded(try Self.image(width: 64, height: 64, seed: 7), as: .png)
        let prepared = try ImageLookupUpload.prepare(png)
        #expect(prepared == PreparedImage(data: png, format: .png, wasReencoded: false))
    }

    @Test func unsupportedFormatBecomesJPEG() throws {
        let tiff = try Self.encoded(try Self.image(width: 64, height: 48, seed: 3), as: .tiff)
        let prepared = try ImageLookupUpload.prepare(tiff)
        #expect(prepared.format == .jpeg)
        #expect(prepared.wasReencoded)
        #expect(ImageFormat(sniffing: prepared.data) == .jpeg)
        #expect(try Self.longEdge(of: prepared.data) == 64)
    }

    /// The rule itself gives the bounds: just over the limit, the first step is the full
    /// size; with a limit just under that JPEG, the next step, half the size, is taken.
    @Test func oversizedImageIsShrunk() throws {
        let png = try Self.encoded(try Self.image(width: 1024, height: 1024, seed: 2026_11_13), as: .png)

        let full = try ImageLookupUpload.prepare(png, limit: png.count - 1)
        #expect(full.format == .jpeg)
        #expect(full.wasReencoded)
        #expect(full.data.count <= png.count - 1)
        #expect(try Self.longEdge(of: full.data) == 1024)

        let smaller = try ImageLookupUpload.prepare(png, limit: full.data.count - 1)
        #expect(smaller.data.count <= full.data.count - 1)
        #expect(smaller.format == .jpeg)
        #expect(smaller.wasReencoded)
        #expect(try Self.longEdge(of: smaller.data) == 512)
    }

    /// A converted image is turned as its EXIF orientation says: a 48 × 32
    /// JPEG marked orientation 6 (rotate 90° clockwise to show) comes out 32 × 48, with no orientation left to apply.
    /// Being a JPEG under the limit it would go byte for byte, so the limit is set just under its size.
    @Test func convertedImageIsTurnedUpright() throws {
        let image = try Self.image(width: 48, height: 32, seed: 11)
        let output = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(
            output, UTType.jpeg.identifier as CFString, 1, nil
        ))
        // The orientation goes in the TIFF dictionary: ImageIO writes it to the JPEG's EXIF from there.
        CGImageDestinationAddImage(destination, image, [
            kCGImagePropertyOrientation: 6, kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFOrientation: 6],
            kCGImageDestinationLossyCompressionQuality: 1.0,
        ] as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        let jpeg = output as Data
        let original = try Self.geometry(of: jpeg)
        #expect(original.width == 48 && original.height == 32 && original.orientation == 6, "\(original)")
        #expect(try ImageLookupUpload.prepare(jpeg).data == jpeg)

        let prepared = try ImageLookupUpload.prepare(jpeg, limit: jpeg.count - 1)
        #expect(prepared.format == .jpeg)
        #expect(prepared.wasReencoded)
        let turned = try Self.geometry(of: prepared.data)
        #expect(turned.width == 32 && turned.height == 48, "\(turned)")
        #expect(turned.orientation == nil || turned.orientation == 1)
    }

    @Test func hopelessImageIsTooLarge() throws {
        let png = try Self.encoded(try Self.image(width: 64, height: 64, seed: 7), as: .png)
        #expect(throws: ImageLookupUploadError.tooLarge) {
            try ImageLookupUpload.prepare(png, limit: 10)
        }
    }

    @Test func notAnImageThrows() {
        #expect(throws: ImageLookupUploadError.notAnImage) {
            try ImageLookupUpload.prepare(Self.notAnImage)
        }
    }

    /// More than `maximumInputBytes` is refused before it is looked at, whatever it holds.
    @Test func inputOverTheCapIsRefused() {
        var data = Data(count: ImageLookupUpload.maximumInputBytes + 1)
        data.replaceSubrange(0..<4, with: [0xFF, 0xD8, 0xFF, 0xE0])
        #expect(throws: ImageLookupUploadError.tooLarge) {
            try ImageLookupUpload.prepare(data, limit: .max)
        }
    }

    @Test func limitsAreTenAndFiftyMebibytes() {
        #expect(ImageLookupUpload.maximumUploadBytes == 10 * 1024 * 1024)
        #expect(ImageLookupUpload.maximumInputBytes == 50 * 1024 * 1024)
    }
}
