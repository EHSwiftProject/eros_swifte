import Foundation

/// The two E-Hentai front ends the app can talk to.
public enum EHSite: String, Sendable, Codable, CaseIterable {
    case eh
    case ex

    /// Main web host, without scheme.
    public var host: String {
        switch self {
        case .eh: "e-hentai.org"
        case .ex: "exhentai.org"
        }
    }

    /// Base URL of the main site, without a trailing slash.
    public var baseURL: URL {
        URL(string: "https://\(host)")!
    }
}

extension EHSite {
    /// The site whose cookies a host gets: e-hentai.org and its subdomains → .eh, exhentai.org and its subdomains → .ex.
    /// Case-insensitive; one leading "." (an HTTPCookie domain such as ".e-hentai.org") and one trailing "." are ignored.
    /// nil for every other host (ehgt.org, *.hath.network, …).
    public init?(cookieHost: String) {
        var host = Substring(cookieHost.lowercased())
        if host.hasPrefix(".") { host = host.dropFirst() }
        if host.hasSuffix(".") { host = host.dropLast() }
        // A host with an empty label ("..e-hentai.org", "a..e-hentai.org") is malformed and gets nothing.
        guard !host.isEmpty, !host.hasPrefix("."), !host.hasSuffix("."), !host.contains("..") else { return nil }
        guard let site = EHSite.allCases.first(where: { host == $0.host || host.hasSuffix(".\($0.host)") }) else {
            return nil
        }
        self = site
    }
}
