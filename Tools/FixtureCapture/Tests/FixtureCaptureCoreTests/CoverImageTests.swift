import FixtureCaptureCore
import Foundation
import Testing

@Suite struct CoverImageTests {
    @Test func fileNamesAndMIMETypes() {
        let names = CoverImageFormat.allCases.map { "\($0.fileName) \($0.mimeType)" }
        #expect(names == ["a.jpg image/jpeg", "a.png image/png", "a.gif image/gif", "a.webp image/webp"])
    }

    @Test func contentTypeNamesTheFormat() {
        let cases: [(String?, CoverImageFormat?)] = [
            ("image/jpeg", .jpeg), ("image/jpg", .jpeg), ("image/pjpeg", .jpeg), (" Image/JPEG ; q=1", .jpeg),
            ("image/png", .png), ("image/gif", .gif), ("image/webp", .webp), ("image/webp;charset=binary", .webp),
            ("image/avif", nil), ("application/octet-stream", nil), ("text/html; charset=UTF-8", nil), ("", nil),
            ("webp", nil), (nil, nil),
        ]
        for (contentType, expected) in cases {
            #expect(CoverImageFormat(contentType: contentType) == expected, "\(contentType ?? "nil")")
        }
    }

    @Test func fileHeaderShowsTheFormat() {
        let cases: [([UInt8], CoverImageFormat?)] = [
            ([0xFF, 0xD8, 0xFF, 0xDB], .jpeg),
            ([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A], .png),
            (Array("GIF87a".utf8), .gif), (Array("GIF89a".utf8) + [0x00], .gif),
            (Array("RIFF".utf8) + [0x10, 0, 0, 0] + Array("WEBP".utf8), .webp),
            // Too short, or RIFF that is not WebP, or a PNG signature cut short.
            ([0xFF, 0xD8], nil), (Array("RIFF".utf8) + [0x10, 0, 0, 0] + Array("WAVE".utf8), nil),
            ([0x89, 0x50, 0x4E, 0x47], nil), (Array("GIF88a".utf8), nil), ([], nil),
        ]
        for (index, (bytes, expected)) in cases.enumerated() {
            #expect(CoverImageFormat(fileHeader: Data(bytes)) == expected, "case \(index)")
        }
    }

    @Test func descriptionsShowNoBytes() {
        let cover = CoverImage(data: Data("zqfakecoverbytes".utf8), format: .webp)
        var dumped = ""
        dump(cover, to: &dumped)
        for rendering in [String(describing: cover), String(reflecting: cover), dumped] {
            let leaked = rendering.contains("zqfake") || rendering.contains("7a71")
            #expect(leaked == false, "a cover rendering shows its bytes")
            let named = rendering.contains("webp")
            #expect(named)
        }
    }
}
