import Foundation

/// A gallery's id and token, as in `/g/<gid>/<token>/`.
public struct GalleryRef: Sendable, Equatable {
    public let gid: Int
    public let token: String

    public init(gid: Int, token: String) {
        self.gid = gid
        self.token = token
    }
}

/// The multi-page viewer's key and the first image's key, for the `imagedispatch` API.
public struct MPVKeys: Sendable, Equatable {
    public let mpvkey: String
    public let firstImageKey: String

    public init(mpvkey: String, firstImageKey: String) {
        self.mpvkey = mpvkey
        self.firstImageKey = firstImageKey
    }
}

/// Pulls the links and keys later capture steps need out of a page. Regular expressions only: the pages are the
/// site's own, and each value is checked again before it is used.
public enum LinkExtractor {
    private static func compile(_ pattern: String, _ options: NSRegularExpression.Options = []) -> NSRegularExpression {
        // Constant patterns, exercised by the tests.
        try! NSRegularExpression(pattern: pattern, options: options)
    }

    private static let galleryLink = compile(#"/g/(\d+)/([0-9a-f]{10})/"#)
    private static let nextPageTag = compile(#"<a\b[^>]*\bid\s*=\s*["']unext["'][^>]*>"#, .caseInsensitive)
    private static let hrefAttribute = compile(#"\bhref\s*=\s*(?:"([^"]*)"|'([^']*)')"#, .caseInsensitive)
    private static let imagePageLink = compile(#"https://e[-x]hentai\.org/s/[0-9a-f]{10}/\d+-\d+"#)
    private static let showkeyValue = compile(#"showkey\s*=\s*"(.*?)""#)
    private static let loadfailTag = compile(#"<[a-z]+\b[^>]*\bid\s*=\s*["']loadfail["'][^>]*>"#, .caseInsensitive)
    private static let reloadCall = compile(#"nl\('(.*?)'\)"#)
    private static let mpvkeyValue = compile(#"mpvkey\s*=\s*"([0-9a-z]+)""#)
    private static let imagelistValue = compile(#"imagelist\s*=\s*(\[.+\]);"#)
    // `or=` only as a query parameter of the archiver link itself (after its `?`, an `&` or the `;` of `&amp;`, in
    // the same quoted string), not inside a word such as "color=" or in another link. The key ends at the next
    // parameter or the end of the string.
    private static let archiverOr = compile(#"archiver\.php\?(?:[^'"]*?[&;])?or=([^'"&\s]*)"#)
    private static let coverDiv = compile(#"<div\b[^>]*\bid\s*=\s*["']gd1["'][^>]*>\s*<div\b([^>]*)>"#, .caseInsensitive)
    private static let styleAttribute = compile(#"\bstyle\s*=\s*(?:"([^"]*)"|'([^']*)')"#, .caseInsensitive)
    private static let cssURL = compile(#"url\(\s*['"]?([^'")\s]+)['"]?\s*\)"#, .caseInsensitive)
    private static let lookupForm = compile(
        #"<form\b[^>]*\baction\s*=\s*(?:"([^"]*image_lookup\.php[^"]*)"|'([^']*image_lookup\.php[^']*)')"#,
        .caseInsensitive
    )

    /// Every `/g/<gid>/<token>/` link, in order of first appearance, without duplicates.
    public static func galleries(in html: String) -> [GalleryRef] {
        var seen = Set<String>()
        var result: [GalleryRef] = []
        for match in matches(of: galleryLink, in: html) {
            guard let gidText = group(1, of: match, in: html), let gid = Int(gidText),
                  let token = group(2, of: match, in: html), seen.insert("\(gid)/\(token)").inserted else { continue }
            result.append(GalleryRef(gid: gid, token: token))
        }
        return result
    }

    /// The `href` of the `id="unext"` link, with HTML entities such as `&amp;` undone. Nil on the last page, where
    /// `unext` is a span.
    public static func nextPageURL(in html: String) -> URL? {
        guard let tag = firstMatch(of: nextPageTag, in: html).flatMap({ group(0, of: $0, in: html) }),
              let href = attribute(hrefAttribute, in: tag) else { return nil }
        return URL(string: htmlUnescaped(href))
    }

    /// Every image page link (`https://e-hentai.org/s/<key>/<gid>-<page>` or the exhentai.org one), in order,
    /// without duplicates.
    public static func imagePageURLs(in html: String) -> [URL] {
        var seen = Set<String>()
        return matches(of: imagePageLink, in: html).compactMap { match in
            guard let link = group(0, of: match, in: html), seen.insert(link).inserted else { return nil }
            return URL(string: link)
        }
    }

    /// The image page's `showkey`, or nil when there is none or it is empty.
    public static func showkey(in html: String) -> String? {
        firstMatch(of: showkeyValue, in: html).flatMap { group(1, of: $0, in: html) }.flatMap(nonEmpty)
    }

    /// The token in `nl('…')` of the `#loadfail` link, used to ask for the image from another server.
    public static func reloadToken(in html: String) -> String? {
        guard let tag = firstMatch(of: loadfailTag, in: html).flatMap({ group(0, of: $0, in: html) }),
              let call = firstMatch(of: reloadCall, in: tag) else { return nil }
        return group(1, of: call, in: tag).flatMap(nonEmpty)
    }

    /// `mpvkey` and the `k` of the first `imagelist` entry of the multi-page viewer.
    public static func mpvKeys(in html: String) -> MPVKeys? {
        guard let mpvkey = firstMatch(of: mpvkeyValue, in: html).flatMap({ group(1, of: $0, in: html) }),
              let list = firstMatch(of: imagelistValue, in: html).flatMap({ group(1, of: $0, in: html) }),
              let entries = try? JSONSerialization.jsonObject(with: Data(list.utf8)) as? [Any],
              let first = entries.first as? [String: Any],
              let key = first["k"] as? String, !key.isEmpty else { return nil }
        return MPVKeys(mpvkey: mpvkey, firstImageKey: key)
    }

    /// The `or` parameter of the archiver link (`…archiver.php?gid=…&amp;token=…&amp;or=<key>'`), or nil when the
    /// link has none: the site dropped it after the Flutter app was written, and links now end at `token=…'`.
    public static func archiverKey(in html: String) -> String? {
        firstMatch(of: archiverOr, in: html).flatMap { group(1, of: $0, in: html) }.flatMap(nonEmpty)
    }

    /// The `url(…)` in the style of the first div inside `#gd1`: the gallery's cover.
    public static func coverURL(in html: String) -> URL? {
        guard let attributes = firstMatch(of: coverDiv, in: html).flatMap({ group(1, of: $0, in: html) }),
              let style = attribute(styleAttribute, in: attributes),
              let url = firstMatch(of: cssURL, in: style).flatMap({ group(1, of: $0, in: style) }) else { return nil }
        return URL(string: htmlUnescaped(url))
    }

    /// The `action` of the first form posting to `image_lookup.php` (the front page's file search), with HTML
    /// entities such as `&amp;` undone. The caller checks the host before using it.
    public static func imageLookupURL(in html: String) -> URL? {
        guard let match = firstMatch(of: lookupForm, in: html),
              let action = group(1, of: match, in: html) ?? group(2, of: match, in: html) else { return nil }
        return URL(string: htmlUnescaped(action))
    }

    // MARK: Helpers

    private static func matches(of regex: NSRegularExpression, in text: String) -> [NSTextCheckingResult] {
        regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
    }

    private static func firstMatch(of regex: NSRegularExpression, in text: String) -> NSTextCheckingResult? {
        regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))
    }

    private static func group(_ index: Int, of match: NSTextCheckingResult, in text: String) -> String? {
        Range(match.range(at: index), in: text).map { String(text[$0]) }
    }

    /// The value of a quoted attribute matched by `regex`, whose groups 1 and 2 are the double- and single-quoted
    /// forms.
    private static func attribute(_ regex: NSRegularExpression, in tag: String) -> String? {
        guard let match = firstMatch(of: regex, in: tag) else { return nil }
        return group(1, of: match, in: tag) ?? group(2, of: match, in: tag)
    }

    private static func nonEmpty(_ value: String) -> String? {
        value.isEmpty ? nil : value
    }
}
