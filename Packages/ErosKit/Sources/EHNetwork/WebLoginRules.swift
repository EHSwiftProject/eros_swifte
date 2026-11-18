import EHModels
import EHParsing
import Foundation

/// What the web login and the WebView session bridge go by (account A1).
public enum WebLoginRules {
    /// The forum sends a logged-in browser to /index.php without a query: https, host forums.e-hentai.org, path
    /// "/index.php", no query.
    ///
    /// The scheme and host are compared case-insensitively; a port other than 443 does not count. An empty query
    /// ("index.php?") counts as none, as Flutter's `queryParameters.isEmpty` (`web_login_in.dart`): WebKit keeps the
    /// "?" of a redirect that has it. A fragment does not matter. Reaching the page is not enough to be signed in: the
    /// cookies still decide (`AccountService.completeWebLogin(cookies:from:)`).
    public static func isCompletion(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https",
              url.host(percentEncoded: false)?.lowercased() == completionHost,
              url.port == nil || url.port == 443,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return false }
        return components.percentEncodedPath == "/index.php" && (components.percentEncodedQuery ?? "").isEmpty
    }

    /// Cookies of both sites (by domain), as ParsedCookie; expired ones become deletions; other domains are dropped.
    ///
    /// A cookie belongs to a site when `EHSite(cookieHost:)` of its domain is one (".e-hentai.org",
    /// "forums.e-hentai.org", ".exhentai.org", …); each keeps its domain as HTTPCookie writes it. As for
    /// `SetCookieParser`, a cookie is a deletion when it expires at or before `now` or its value is empty or
    /// "deleted". The result runs from the least specific domain to the most specific (".e-hentai.org" before
    /// "forums.e-hentai.org", a `Domain` cookie before a host-only one of the same host, a shorter path first), then by
    /// name: when one name is held for a whole site and for one of its hosts, the host's cookie comes last, so it is
    /// the one a jar keeps, whatever order WebKit returned them in.
    public static func siteCookies(from cookies: [HTTPCookie], now: Date = Date()) -> [ParsedCookie] {
        cookies
            .filter { EHSite(cookieHost: $0.domain) != nil }
            .sorted { specificity(of: $0) < specificity(of: $1) }
            .map { cookie in
                let expired = cookie.expiresDate.map { $0 <= now } ?? false
                return ParsedCookie(
                    name: cookie.name,
                    value: cookie.value,
                    domain: cookie.domain,
                    expiresAt: cookie.expiresDate,
                    isDeletion: expired || cookie.value.isEmpty || cookie.value == deletedValue
                )
            }
    }

    /// Cookies never copied into a WebView: the `CookieNames.isUserAgentBound` ones (no cf_clearance injection, user
    /// decision 2026-11-05).
    ///
    /// Cloudflare binds them to the host and UA they were issued for; the WebView earns its own. While the app runs
    /// on the Chrome fallback (`UserAgentStore.isWebKit` false) they are not copied back from the WebView either.
    public static func isNotPushedToWebView(_ name: String) -> Bool { CookieNames.isUserAgentBound(name) }

    private static let completionHost = EHEndpoints.forumsBaseURL.host(percentEncoded: false) ?? "forums.e-hentai.org"
    /// The value PHP's `setcookie` sends to delete a cookie (as `SetCookieParser`).
    private static let deletedValue = "deleted"

    /// Domain labels, then 1 for a host-only cookie, then the path's length, then the name; smaller sorts first.
    private static func specificity(of cookie: HTTPCookie) -> Specificity {
        let isHostOnly = !cookie.domain.hasPrefix(".")
        let host = isHostOnly ? Substring(cookie.domain) : cookie.domain.dropFirst()
        return Specificity(
            labels: host.split(separator: ".").count, hostOnly: isHostOnly ? 1 : 0, pathLength: cookie.path.count,
            name: cookie.name
        )
    }

    private struct Specificity: Comparable {
        let labels: Int
        let hostOnly: Int
        let pathLength: Int
        let name: String

        static func < (lhs: Self, rhs: Self) -> Bool {
            (lhs.labels, lhs.hostOnly, lhs.pathLength, lhs.name) < (rhs.labels, rhs.hostOnly, rhs.pathLength, rhs.name)
        }
    }
}

/// How the cookie store and the session WebView's cookies agree (account exit criterion 5). Names and a Boolean only:
/// no value ever reaches a description, a dump or the debug screen.
public struct SessionConsistency: Sendable, Equatable, CustomStringConvertible {
    /// Names a jar holds that the WebView lacks for that site; `WebLoginRules.isNotPushedToWebView` ones not counted.
    public let missingInWebView: [String]
    /// Names of site cookies the WebView holds that the jar of their site lacks (UA-bound Cloudflare cookies count).
    public let missingInStore: [String]
    /// Names the jar and the WebView both hold for a site with different values.
    public let differingValues: [String]
    /// The URLSession UA equals the WebView's navigator.userAgent.
    public let userAgentMatches: Bool

    /// Ignores nw (the bridge adds nw=1 to the WebView; the jar never stores it) and UA-bound Cloudflare cookies (`CookieNames.isUserAgentBound`) missing from the WebView.
    ///
    /// Consistent means all three lists are empty and the UAs match: every site cookie in the WebView has the name and
    /// the value its site's jar has, and every cookie in the jars but the UA-bound Cloudflare ones is in the WebView for
    /// that site. A WebView cookie belongs to the site `EHSite(cookieHost:)` of its domain gives; cookies of neither
    /// site, without a domain, and deletions are left out. When the WebView holds one name more than once for a site
    /// (for the site and for a host), every value must equal the jar's. Each list is sorted and names a cookie once,
    /// whichever site (or both) it is in.
    public static func compare(
        snapshot: SessionSnapshot, webCookies: [ParsedCookie], sessionUserAgent: String, webUserAgent: String
    ) -> SessionConsistency {
        var web: [EHSite: [String: Set<String>]] = [:]
        for cookie in webCookies where !cookie.isDeletion && cookie.name != CookieNames.noWarning {
            guard let domain = cookie.domain, let site = EHSite(cookieHost: domain) else { continue }
            web[site, default: [:]][cookie.name, default: []].insert(cookie.value)
        }
        var missingInWebView = Set<String>(), missingInStore = Set<String>(), differingValues = Set<String>()
        for site in EHSite.allCases {
            let jar = (snapshot.cookies[site] ?? [:]).filter { $0.key != CookieNames.noWarning }
            let held = web[site] ?? [:]
            for (name, value) in jar {
                if let values = held[name] {
                    if values != [value] { differingValues.insert(name) }
                } else if !WebLoginRules.isNotPushedToWebView(name) {
                    missingInWebView.insert(name)
                }
            }
            for name in held.keys where jar[name] == nil {
                missingInStore.insert(name)
            }
        }
        return SessionConsistency(
            missingInWebView: missingInWebView.sorted(), missingInStore: missingInStore.sorted(),
            differingValues: differingValues.sorted(), userAgentMatches: sessionUserAgent == webUserAgent
        )
    }

    public var description: String {
        func list(_ names: [String]) -> String { "[\(names.joined(separator: ", "))]" }
        return "SessionConsistency(missingInWebView: \(list(missingInWebView)), missingInStore: \(list(missingInStore)), "
            + "differingValues: \(list(differingValues)), userAgentMatches: \(userAgentMatches))"
    }
}
