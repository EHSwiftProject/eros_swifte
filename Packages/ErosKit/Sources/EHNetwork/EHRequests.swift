import EHModels
import Foundation

/// The image types an image search upload accepts.
public enum ImageFormat: String, Sendable {
    case jpeg, png, gif, webp

    var fileName: String {
        switch self {
        case .jpeg: "a.jpg"
        case .png: "a.png"
        case .gif: "a.gif"
        case .webp: "a.webp"
        }
    }

    var mimeType: String { "image/\(rawValue)" }
}

/// The switches of an image search.
public struct ImageLookupOptions: Sendable, Equatable {
    /// Similarity scan (`fs_similar`).
    public var similar = true
    /// Search covers only (`fs_covers`).
    public var coversOnly = false
    /// Include expunged galleries (`fs_exp`).
    public var includeExpunged = false

    public init() {}
}

extension FavoritesOrder {
    /// The `inline_set` value that sets favorites.php to this order (Flutter `EHConst.favoriteOrder`).
    var inlineSetting: String {
        switch self {
        case .favoritedTime: "fs_f"
        case .postedTime: "fs_p"
        }
    }
}

/// Builders for page, list and form requests.
public enum EHRequests {
    /// A GET of `url`; `refresh` forces the site to be asked again.
    public static func page(_ url: URL, site: EHSite, refresh: Bool = false) -> EHRequest {
        EHRequest(url: url, site: site, cachePolicy: refresh ? .reload : .preferCache)
    }

    /// A GET of the list. `forceCompact` appends `inline_set=dm_l` (a site setting change; the caller decides when)
    /// and then uses no cache.
    public static func list(
        _ query: ListQuery, site: EHSite, refresh: Bool = false, forceCompact: Bool = false
    ) -> EHRequest {
        if forceCompact { return list(query, site: site, inlineSet: "dm_l") }
        return EHRequest(url: query.url(for: site), site: site, cachePolicy: refresh ? .reload : .preferCache)
    }

    /// A GET of the list with `inline_set=<setting>` appended (a change to the account's settings on the site; the
    /// caller decides when), never cached: `dm_l` for the Compact view, `fs_f` or `fs_p` for the favorites order
    /// (`FavoritesOrder.inlineSetting`, browse B8).
    static func list(_ query: ListQuery, site: EHSite, inlineSet setting: String) -> EHRequest {
        let text = query.url(for: site).absoluteString
        let url = URL(string: text + (text.contains("?") ? "&" : "?") + "inline_set=" + setting)!
        return EHRequest(url: url, site: site, cachePolicy: .none)
    }

    /// A urlencoded POST, never cached.
    public static func form(_ url: URL, fields: [URLQueryItem], site: EHSite, referer: URL? = nil) -> EHRequest {
        EHRequest(
            method: .post, url: url, site: site, body: .form(fields),
            headers: referer.map { ["Referer": $0.absoluteString] } ?? [:], cachePolicy: .none)
    }

    /// The image search upload; the answer is a redirect that is not followed.
    public static func imageLookup(
        image: Data, format: ImageFormat, options: ImageLookupOptions, site: EHSite
    ) -> EHRequest {
        var parts = [MultipartBody.Part(name: "sfile", fileName: format.fileName, contentType: format.mimeType, data: image)]
        let on = Data("on".utf8)
        if options.similar { parts.append(.init(name: "fs_similar", data: on)) }
        if options.coversOnly { parts.append(.init(name: "fs_covers", data: on)) }
        if options.includeExpunged { parts.append(.init(name: "fs_exp", data: on)) }
        parts.append(.init(name: "f_sfile", data: Data("File Search".utf8)))
        return EHRequest(
            method: .post, url: EHEndpoints.imageLookupURL(for: site), site: site,
            body: .multipart(MultipartBody(parts: parts)),
            headers: ["Referer": site.baseURL.absoluteString + "/"],
            cachePolicy: .none, followsRedirects: false)
    }

    /// The forum login form, which the app's background WebView posts (`EHRequest.webViewRequest()`, account A3b).
    /// The body holds the password; `EHRequest.description` never shows it.
    public static func passwordLogin(username: String, password: String) -> EHRequest {
        form(
            EHEndpoints.forumLogin,
            fields: [
                URLQueryItem(name: "UserName", value: username),
                URLQueryItem(name: "PassWord", value: password),
                URLQueryItem(name: "submit", value: "Log me in"),
                URLQueryItem(name: "temporary_https", value: "off"),
                URLQueryItem(name: "CookieDate", value: "365"),
            ],
            site: .eh, referer: EHEndpoints.forumLoginReferer)
    }

    /// Selects settings profile number `number`.
    public static func selectProfile(_ number: Int, site: EHSite) -> EHRequest {
        form(
            EHEndpoints.uconfig(site: site),
            fields: [URLQueryItem(name: "profile_action", value: ""), URLQueryItem(name: "profile_set", value: String(number))],
            site: site)
    }

    /// Creates a settings profile named `name`.
    public static func createProfile(named name: String, site: EHSite) -> EHRequest {
        form(
            EHEndpoints.uconfig(site: site),
            fields: [URLQueryItem(name: "profile_action", value: "create"), URLQueryItem(name: "profile_name", value: name)],
            site: site)
    }
}
