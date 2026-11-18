import EHModels
import Foundation
import SwiftSoup

/// Reads image pages (`/s/<key>/<gid>-<page>`, and `?nl=<token>` for another source of the same image).
public enum ImagePageParser {
    /// Parses an image page.
    ///
    /// - The image: `img#img`'s src; the site's 509 placeholder sets `isBandwidthExceeded`.
    /// - The page number and the page count: the two spans of `.sn div` (the navigation above and below the image).
    /// - The file line "<name> :: <width> x <height> :: <size>": a div without a class directly in `#i2`, else in
    ///   `#i4`. The legacy layout had it first in `#i2` (Flutter's `#i2 > div:nth-child(1)`); `.sn` is there now.
    /// - The gallery: `#i5`'s `/g/<gid>/<token>/` link. The original: the `/fullimg/` link.
    /// - The reload token: `nl('…')` in `#loadfail`'s onclick, else in the image's onerror.
    /// - The showkey: `showkey="…"` in the page's scripts (not in its text).
    ///
    /// `imageKey` stays nil: the page states its own key only in its address.
    /// - Throws: `ParseError.missing("imageURL")` without an `img#img` src (`.malformed` when the src is not an
    ///   address); `ParseError.missing("pageIndex")` without the navigation's spans (`.malformed` when the first is
    ///   not a number); whatever SwiftSoup throws, unchanged.
    public static func parse(_ html: String) throws -> ImagePageInfo {
        let document = try SwiftSoup.parse(html)
        let image = try document.select("img#img").first()
        let imageURL = try self.imageURL(of: image, base: nil)
        let spans = try navigationSpans(in: document)
        guard let first = spans.first else { throw ParseError.missing("pageIndex") }
        guard let pageIndex = number(try first.text()) else { throw ParseError.malformed("pageIndex") }
        let file = try fileLine(in: document)
        let gallery = try document.select("#i5").first().flatMap(galleryID(in:))
        let script = try document.select("script").array().map { $0.data() }.joined(separator: "\n")
        return ImagePageInfo(
            gid: gallery?.gid,
            token: gallery?.token,
            pageIndex: pageIndex,
            pageCount: try spans.dropFirst().first.flatMap { number(try $0.text()) },
            imageURL: imageURL,
            imageSize: file?.size,
            fileName: file?.name,
            fileSizeText: file?.fileSize,
            originalImageURL: try originalImageURL(in: document, base: nil),
            reloadToken: try reloadToken(loadFail: document.select("#loadfail").first(), image: image),
            showKey: script.firstMatch(of: /\bshowkey\s*=\s*"([^"]+)"/).map { String($0.1) },
            imageKey: nil,
            isBandwidthExceeded: isBandwidthPlaceholder(imageURL)
        )
    }

    // MARK: Shared with ShowPageParser and ImageDispatchParser

    /// The parts of a file line.
    struct FileLine {
        let name: String
        let size: ImageSize
        let fileSize: String
    }

    /// "<name> :: <width> x <height> :: <size>" (the line above and below the image, and showpage's `i`) → its parts.
    /// The name may hold spaces.
    static func fileLine(from text: String) -> FileLine? {
        let line = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let match = line.wholeMatch(of: /(.+?)\s+::\s+([0-9]+)\s+x\s+([0-9]+)\s+::\s+(.+)/),
              let width = Int(match.2), let height = Int(match.3),
              let name = GalleryListParser.nonEmpty(String(match.1)),
              let fileSize = GalleryListParser.nonEmpty(String(match.4)) else { return nil }
        return FileLine(name: name, size: ImageSize(width: width, height: height), fileSize: fileSize)
    }

    /// The spans of the first `.sn div` in `scope` that has any: the page number, then the page count.
    static func navigationSpans(in scope: Element) throws -> [Element] {
        for navigation in try scope.select(".sn") {
            let spans = try navigation.select("div span").array()
            if !spans.isEmpty { return spans }
        }
        return []
    }

    /// ASCII digits, thousands separators allowed, as a number.
    static func number(_ text: String) -> Int? {
        let digits = text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: "")
        guard !digits.isEmpty, digits.allSatisfy({ ("0"..."9").contains($0) }) else { return nil }
        return Int(digits)
    }

    /// `image`'s src, resolved against `base` when relative.
    /// - Throws: `ParseError.missing("imageURL")` without `image` or its src; `.malformed("imageURL")` when the src
    ///   is not an address.
    static func imageURL(of image: Element?, base: URL?) throws -> URL {
        guard let source = try GalleryListParser.nonEmpty(image?.attr("src")) else {
            throw ParseError.missing("imageURL")
        }
        guard let url = URL(string: source, relativeTo: base)?.absoluteURL else {
            throw ParseError.malformed("imageURL")
        }
        return url
    }

    /// The first `/g/<gid>/<token>/` link in `scope`.
    static func galleryID(in scope: Element) throws -> GalleryID? {
        for link in try scope.select("a[href]") {
            if let match = try link.attr("href").firstMatch(of: /\/g\/([0-9]+)\/([0-9a-f]{10})\//),
               let gid = Int(match.1), gid > 0 {
                return GalleryID(gid: gid, token: String(match.2))
            }
        }
        return nil
    }

    /// The first `/fullimg/` link in `scope` (SwiftSoup has already decoded its `&amp;`), resolved against `base`
    /// when relative.
    static func originalImageURL(in scope: Element, base: URL?) throws -> URL? {
        guard let href = try GalleryListParser.nonEmpty(scope.select("a[href*=/fullimg/]").first()?.attr("href")) else {
            return nil
        }
        return URL(string: href, relativeTo: base)?.absoluteURL
    }

    /// The argument of `nl('…')` in `loadFail`'s onclick ("Reload broken image"), else in `image`'s onerror (the
    /// site calls the same function when the image fails to load).
    static func reloadToken(loadFail: Element?, image: Element?) throws -> String? {
        for (element, attribute) in [(loadFail, "onclick"), (image, "onerror")] {
            if let code = try element?.attr(attribute), let match = code.firstMatch(of: /\bnl\('([^']+)'\)/) {
                return String(match.1)
            }
        }
        return nil
    }

    /// Whether `url` is the site's 509 placeholder, shown instead of the image when the image quota is used up: a
    /// host of `placeholderHosts` (or a subdomain of one) and a path ending with `/509.gif` or `/509s.gif`, as the
    /// Flutter `EHConst.REG_509_URL` (`\.org/.+/509s?\.gif`). An H@H node's image (`*.hath.network`) never is, even
    /// when its file is named `509.gif`.
    static func isBandwidthPlaceholder(_ url: URL) -> Bool {
        guard var host = url.host()?.lowercased() else { return false }
        if host.hasSuffix(".") { host.removeLast() }
        guard placeholderHosts.contains(where: { host == $0 || host.hasSuffix(".\($0)") }) else { return false }
        let path = url.path()
        return path.hasSuffix("/509.gif") || path.hasSuffix("/509s.gif")
    }

    /// The site's own hosts, which serve the 509 placeholder.
    private static let placeholderHosts = ["ehgt.org", "e-hentai.org", "exhentai.org"]

    // MARK: Image page

    /// The file line of a div without a class directly in `#i2`, else in `#i4`.
    private static func fileLine(in document: Document) throws -> FileLine? {
        for block in ["#i2", "#i4"] {
            guard let container = try document.select(block).first() else { continue }
            for div in container.children() where div.tagName() == "div" {
                guard try div.className().trimmingCharacters(in: .whitespaces).isEmpty else { continue }
                if let line = fileLine(from: try div.text()) { return line }
            }
        }
        return nil
    }
}
