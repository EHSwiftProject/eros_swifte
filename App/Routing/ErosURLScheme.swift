import EHModels
import Foundation

/// The app's own URL scheme, `eros://` (entry E2): another app, a bookmarklet or a shortcut opens a site link in Eros
/// through it. Two forms, both handed to `EHLink` in the end, so the site's links are told apart in one place:
///
/// - the host form, `eros://e-hentai.org/g/1234/0123456789/`: a site URL with `https` changed to `eros`, which a user
///   or a shortcut's Replace Text can do;
/// - the open form, `eros://open?url=https%3A%2F%2Fexhentai.org%2Fs%2F…`: the whole link percent-encoded in `url`, for
///   tools that encode a link (a Safari bookmarklet's `encodeURIComponent(location.href)`, a shortcut's URL Encode).
///
/// The two never mix: `open` is no site host. The scheme and `open` are read in any case.
nonisolated enum ErosURLScheme {
    static let scheme = "eros"

    /// The host of the open form.
    private static let openHost = "open"

    /// The site URL an `eros://` link stands for, or nil:
    /// - `eros://open?url=<link>`: the first `url` query item, decoded, when it is a URL whose scheme is `http` or
    ///   `https` (any case);
    /// - `eros://<host>/<path>?<query>#<fragment>`, the host not empty: the same URL with the scheme `https`. Only the
    ///   scheme changes: the rest is copied as it came, percent-encoding included (`URL(string:)` and the system have
    ///   already rewritten a malformed escape, and `EHLink` must see the URL as they left it).
    ///
    /// Any other URL, `eros://` without a host or with another scheme, is nil.
    static func siteURL(from url: URL) -> URL? {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == scheme
        else { return nil }
        if components.host?.lowercased() == openHost {
            guard let text = components.queryItems?.first(where: { $0.name == "url" })?.value,
                  let link = URL(string: text), isHTTP(link)
            else { return nil }
            return link
        }
        guard let host = components.host, !host.isEmpty else { return nil }
        components.scheme = "https"
        return components.url
    }

    /// The site link `url` is: an `eros://` link through `siteURL(from:)`, an `http(s)` URL as it is; nil when
    /// `EHLink(url:)` does not read it as one, and for any other scheme.
    static func link(from url: URL) -> EHLink? {
        if url.scheme?.lowercased() == scheme {
            return siteURL(from: url).flatMap(EHLink.init(url:))
        }
        return isHTTP(url) ? EHLink(url: url) : nil
    }

    private static func isHTTP(_ url: URL) -> Bool {
        let scheme = url.scheme?.lowercased()
        return scheme == "http" || scheme == "https"
    }
}
