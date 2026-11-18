import Foundation

/// How the user signed in.
public enum LoginMethod: String, Sendable, Codable {
    /// Username and password through the forum login form.
    case password
    /// Cookies typed or pasted by the user.
    case cookie
    /// The site's own login page in a WKWebView.
    case web
}

/// What the app knows about the signed-in account, besides its cookies.
public struct AccountInfo: Sendable, Equatable, Codable {
    public var method: LoginMethod
    /// The name typed for a password login; nil for the other methods.
    public var username: String?
    /// The nickname from the forum profile page, when it could be read.
    public var displayName: String?
    public var avatarURL: URL?
    /// When `displayName` and `avatarURL` were last read.
    public var profileFetchedAt: Date?

    public init(
        method: LoginMethod, username: String? = nil, displayName: String? = nil, avatarURL: URL? = nil,
        profileFetchedAt: Date? = nil
    ) {
        self.method = method
        self.username = username
        self.displayName = displayName
        self.avatarURL = avatarURL
        self.profileFetchedAt = profileFetchedAt
    }
}

/// Everything the cookie store keeps: one cookie jar per site and the account.
///
/// `description` and the mirror list cookie names only, never values or account fields.
public struct SessionSnapshot: Sendable, Equatable, Codable, CustomStringConvertible, CustomReflectable {
    /// One jar per site, name → value. `nw` is never stored (requests add `nw=1` themselves).
    public var cookies: [EHSite: [String: String]]
    public var account: AccountInfo?

    public init(cookies: [EHSite: [String: String]] = [:], account: AccountInfo? = nil) {
        self.cookies = cookies
        self.account = account
    }

    public static let empty = SessionSnapshot()

    public var description: String {
        let jars = EHSite.allCases.compactMap { site in
            cookies[site].map { "\(site.rawValue): [\($0.keys.sorted().joined(separator: ", "))]" }
        }
        let account = "account: \(account == nil ? "none" : "present")"
        return "SessionSnapshot(\((jars + [account]).joined(separator: ", ")))"
    }

    public var customMirror: Mirror {
        Mirror(self, children: ["description": description])
    }

    // Coded by hand so the jars form a JSON object keyed by the site's raw value ({"eh": {…}, "ex": {…}});
    // the synthesized coding of an enum-keyed dictionary is a flat array of alternating keys and values.
    private enum CodingKeys: String, CodingKey {
        case cookies
        case account
    }

    /// Jars of sites this version does not know are dropped.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let jars = try container.decodeIfPresent([String: [String: String]].self, forKey: .cookies) ?? [:]
        var cookies: [EHSite: [String: String]] = [:]
        for (key, jar) in jars {
            if let site = EHSite(rawValue: key) { cookies[site] = jar }
        }
        self.init(cookies: cookies, account: try container.decodeIfPresent(AccountInfo.self, forKey: .account))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        let jars = Dictionary(uniqueKeysWithValues: cookies.map { ($0.key.rawValue, $0.value) })
        try container.encode(jars, forKey: .cookies)
        try container.encodeIfPresent(account, forKey: .account)
    }
}

/// The user agent the device's WKWebView reports (`navigator.userAgent`), with the system version it was read on.
public struct WebKitUserAgent: Sendable, Equatable, Codable {
    public let value: String
    /// `UIDevice.current.systemVersion` when the UA was read; an OS update changes WebKit's UA.
    public let systemVersion: String
    public let capturedAt: Date

    public init(value: String, systemVersion: String, capturedAt: Date) {
        self.value = value
        self.systemVersion = systemVersion
        self.capturedAt = capturedAt
    }
}
