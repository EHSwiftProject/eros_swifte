import Foundation

/// A link to an E-Hentai or ExHentai page the app opens (entry E1): a gallery, one of its image pages, the galleries of
/// a tag or of an uploader, or a search. `init?(url:)` tells which a URL is.
public enum EHLink: Sendable, Hashable {
    /// `/g/<gid>/<token>/`.
    case gallery(GalleryID, site: EHSite)
    /// `/s/<imageKey>/<gid>-<page>`.
    case imagePage(imageKey: String, gid: Int, page: Int, site: EHSite)
    /// `/tag/<namespace:name>`.
    case tag(TagRef, site: EHSite)
    /// `/uploader/<name>`.
    case uploader(String, site: EHSite)
    /// `/?f_search=<text>`.
    case search(String, site: EHSite)

    /// The link `url` is, or nil when it is none of the site's pages the app opens:
    ///
    /// 1. The scheme is `http` or `https`, in any case.
    /// 2. The host, lowercased, without one trailing "." and then one leading "www.", is `e-hentai.org` (`.eh`) or
    ///    `exhentai.org` (`.ex`); a subdomain is not (`forums.`, `upld.`, …).
    /// 3. The path is read percent-encoded, split at "/", empty segments dropped:
    ///    - `g`, gid, token: the gid is `[1-9][0-9]{0,18}` and fits an `Int`, the token `[0-9a-f]{10}`;
    ///    - `s`, key, gid-page: the key `[0-9a-f]{10}`, the gid as above, the page `[1-9][0-9]*` and fits an `Int`;
    ///    - `tag`, segment: decoded (below), then split at its first ":" (`TagRef(raw:)`); the name and a namespace
    ///      there is must not be empty;
    ///    - `uploader`, segment: decoded and trimmed, not empty;
    ///    - no segment: the first `f_search` of the query, decoded and trimmed, not empty.
    /// 4. Anything else is nil. Beyond `f_search`, the query and the fragment are never read.
    ///
    /// Decoding reads "+" as a space, then percent-decodes (`%2B` is "+", `%20` a space); a segment whose escapes are
    /// not UTF-8 is no link. Flutter decoded neither the tag nor the uploader, and never matched a search link
    /// (research §13.2): these are fixed here.
    public init?(url: URL) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let site = Self.site(host: components.host)
        else { return nil }
        let segments = components.percentEncodedPath.split(separator: "/")
        switch (segments.first, segments.count) {
        case ("g", 3):
            guard let gid = Self.galleryID(segments[1]), Self.isKey(segments[2]) else { return nil }
            self = .gallery(GalleryID(gid: gid, token: String(segments[2])), site: site)
        case ("s", 3):
            let gidAndPage = segments[2].split(separator: "-", omittingEmptySubsequences: false)
            guard Self.isKey(segments[1]), gidAndPage.count == 2, let gid = Self.galleryID(gidAndPage[0]),
                  gidAndPage[1].wholeMatch(of: /[1-9][0-9]*/) != nil, let page = Int(gidAndPage[1])
            else { return nil }
            self = .imagePage(imageKey: String(segments[1]), gid: gid, page: page, site: site)
        case ("tag", 2):
            guard let raw = Self.decoded(segments[1]) else { return nil }
            let tag = TagRef(raw: raw)
            guard !tag.name.isEmpty, tag.namespace?.isEmpty != true else { return nil }
            self = .tag(tag, site: site)
        case ("uploader", 2):
            guard let name = Self.decodedText(segments[1]) else { return nil }
            self = .uploader(name, site: site)
        case (nil, _):
            guard let value = components.percentEncodedQueryItems?.first(where: { $0.name == "f_search" })?.value,
                  let text = Self.decodedText(Substring(value))
            else { return nil }
            self = .search(text, site: site)
        default:
            return nil
        }
    }

    /// The site of a link's host (rule 2), or nil.
    private static func site(host: String?) -> EHSite? {
        guard var host = host?.lowercased() else { return nil }
        if host.hasSuffix(".") { host.removeLast() }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        return EHSite.allCases.first { $0.host == host }
    }

    /// A gallery id: `[1-9][0-9]{0,18}` that fits an `Int`.
    private static func galleryID(_ segment: Substring) -> Int? {
        guard segment.wholeMatch(of: /[1-9][0-9]{0,18}/) != nil else { return nil }
        return Int(segment)
    }

    /// Whether `segment` is a gallery token or an image key: ten lowercase hex digits.
    private static func isKey(_ segment: Substring) -> Bool {
        segment.wholeMatch(of: /[0-9a-f]{10}/) != nil
    }

    /// "+" read as a space, then percent-decoded; nil when the escapes are not UTF-8.
    private static func decoded(_ text: Substring) -> String? {
        String(text).replacing("+", with: " ").removingPercentEncoding
    }

    /// `decoded(_:)`, trimmed; nil when that leaves nothing.
    private static func decodedText(_ text: Substring) -> String? {
        guard let text = decoded(text)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            return nil
        }
        return text
    }
}
