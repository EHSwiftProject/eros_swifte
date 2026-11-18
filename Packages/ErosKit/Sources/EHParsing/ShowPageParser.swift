import CoreFoundation
import EHModels
import Foundation
import SwiftSoup

/// Reads `showpage` answers of `api.php`: another page of the image page's reader, without loading that page.
public enum ShowPageParser {
    /// Parses a `showpage` answer. The answer is read as the method's JSON whatever its `Content-Type` (the site sends
    /// `text/html`).
    ///
    /// - The page number: `p`. The page count: the second span of `n` (the navigation, as on the image page).
    /// - The image: `img#img`'s src in `i3`; the 509 placeholder sets `isBandwidthExceeded`.
    /// - The size: `x` and `y`, else the dimensions of the file line `i` ("<name> :: <width> x <height> :: <size>"),
    ///   which also gives the file name and size.
    /// - The gallery: `i5`'s `/g/<gid>/<token>/` link. The original: `i6`'s `/fullimg/` link.
    /// - The reload token: `nl('…')` of `i6`'s `#loadfail`, else of the image's onerror in `i3`.
    /// - The image key: `k`.
    ///
    /// Numbers may be JSON numbers or strings of digits. Relative links are resolved against `site.baseURL`.
    /// `showKey` stays nil: the request sends it and the answer does not repeat it.
    /// - Throws: `APIError.notJSON` when the answer is not a JSON object; `APIError.server(message)` for
    ///   `{"error": message}` (a stale showkey gives "Key mismatch"); `ParseError.missing("pageIndex")` without `p`
    ///   (`.malformed` when it is not a number); `ParseError.missing("imageURL")` without an `img#img` src in `i3`
    ///   (`.malformed` when it is not an address); whatever SwiftSoup throws, unchanged.
    public static func parse(_ json: Data, site: EHSite) throws -> ImagePageInfo {
        let answer = try object(from: json)
        let pageIndex = try self.pageIndex(answer["p"])
        let image = try fragment(answer["i3"])?.select("img#img").first()
        let imageURL = try ImagePageParser.imageURL(of: image, base: site.baseURL)
        let file = try fragment(answer["i"]).flatMap { ImagePageParser.fileLine(from: try $0.text()) }
        let links = try fragment(answer["i6"])
        let size = integer(answer["x"]).flatMap { width in
            integer(answer["y"]).map { ImageSize(width: width, height: $0) }
        }
        let gallery = try fragment(answer["i5"]).flatMap(ImagePageParser.galleryID(in:))
        let navigation = try fragment(answer["n"]).map(ImagePageParser.navigationSpans(in:)) ?? []
        return ImagePageInfo(
            gid: gallery?.gid,
            token: gallery?.token,
            pageIndex: pageIndex,
            pageCount: try navigation.dropFirst().first.flatMap { ImagePageParser.number(try $0.text()) },
            imageURL: imageURL,
            imageSize: size ?? file?.size,
            fileName: file?.name,
            fileSizeText: file?.fileSize,
            originalImageURL: try links.flatMap { try ImagePageParser.originalImageURL(in: $0, base: site.baseURL) },
            reloadToken: try ImagePageParser.reloadToken(loadFail: links?.select("#loadfail").first(), image: image),
            showKey: nil,
            imageKey: text(answer["k"]),
            isBandwidthExceeded: ImagePageParser.isBandwidthPlaceholder(imageURL)
        )
    }

    // MARK: Shared with ImageDispatchParser

    /// The answer as a JSON object.
    /// - Throws: `APIError.notJSON` when it is not one; `APIError.server(message)` when it has an `error` (whatever
    ///   else it has).
    static func object(from json: Data) throws -> [String: Any] {
        guard let value = try? JSONSerialization.jsonObject(with: json, options: [.fragmentsAllowed]),
              let object = value as? [String: Any] else { throw APIError.notJSON }
        if let error = object["error"], !(error is NSNull) {
            throw APIError.server(error as? String ?? String(describing: error))
        }
        return object
    }

    /// A JSON number without a fraction, or a string of ASCII digits (thousands separators allowed); not a Boolean.
    static func integer(_ value: Any?) -> Int? {
        if let text = value as? String { return ImagePageParser.number(text) }
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return Int(exactly: number.doubleValue)
    }

    /// A non-empty string (trimmed), or a number written out; not a Boolean.
    static func text(_ value: Any?) -> String? {
        if let text = value as? String { return GalleryListParser.nonEmpty(text) }
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return number.stringValue
    }

    /// A string field holding HTML, as the body of a parsed fragment; nil when the field is absent or not a string.
    static func fragment(_ value: Any?) throws -> Element? {
        guard let html = value as? String else { return nil }
        let document = try SwiftSoup.parseBodyFragment(html)
        return document.body() ?? document
    }

    // MARK: showpage

    /// `p`. - Throws: `ParseError.missing("pageIndex")` without it, `.malformed("pageIndex")` when not a number.
    private static func pageIndex(_ value: Any?) throws -> Int {
        guard let value, !(value is NSNull) else { throw ParseError.missing("pageIndex") }
        guard let page = integer(value) else { throw ParseError.malformed("pageIndex") }
        return page
    }
}
