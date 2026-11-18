import EHModels
import Foundation

/// Every fixed or derived address of the site, the forums and the API.
public enum EHEndpoints {
    /// The forums host (login, member profiles).
    public static let forumsBaseURL = URL(string: "https://forums.e-hentai.org")!

    /// `{base}/g/{gid}/{token}/`, with `?p=n` for the nth page of thumbnails.
    public static func gallery(_ id: GalleryID, site: EHSite, thumbnailPage: Int? = nil) -> URL {
        var text = "\(site.baseURL.absoluteString)/g/\(id.gid)/\(id.token)/"
        if let thumbnailPage { text += "?p=\(thumbnailPage)" }
        return URL(string: text)!
    }

    /// `{base}/s/{key}/{gid}-{page}`, with `?nl=` and the percent-encoded reload token when given.
    public static func imagePage(key: String, gid: Int, page: Int, site: EHSite, reloadToken: String? = nil) -> URL {
        var text = "\(site.baseURL.absoluteString)/s/\(URLEncoding.component(key))/\(gid)-\(page)"
        if let reloadToken { text += "?nl=\(URLEncoding.component(reloadToken))" }
        return URL(string: text)!
    }

    /// `{base}/mpv/{gid}/{token}/`.
    public static func mpv(_ id: GalleryID, site: EHSite) -> URL {
        URL(string: "\(site.baseURL.absoluteString)/mpv/\(id.gid)/\(id.token)/")!
    }

    /// `{base}/gallerypopups.php?gid={gid}&t={token}&act=addfav`.
    public static func favoritesPopup(_ id: GalleryID, site: EHSite) -> URL {
        URL(string: "\(site.baseURL.absoluteString)/gallerypopups.php?gid=\(id.gid)&t=\(id.token)&act=addfav")!
    }

    /// `{base}/gallerytorrents.php?gid={gid}&t={token}`.
    public static func torrents(_ id: GalleryID, site: EHSite) -> URL {
        URL(string: "\(site.baseURL.absoluteString)/gallerytorrents.php?gid=\(id.gid)&t=\(id.token)")!
    }

    /// `{base}/archiver.php?gid={gid}&token={token}`, without an `or` key.
    public static func archiver(_ id: GalleryID, site: EHSite) -> URL {
        URL(string: "\(site.baseURL.absoluteString)/archiver.php?gid=\(id.gid)&token=\(id.token)")!
    }

    /// `{base}/uconfig.php`.
    public static func uconfig(site: EHSite) -> URL {
        URL(string: "\(site.baseURL.absoluteString)/uconfig.php")!
    }

    /// `{base}/mytags`.
    public static func myTags(site: EHSite) -> URL {
        URL(string: "\(site.baseURL.absoluteString)/mytags")!
    }

    /// The image quota page; always on e-hentai.org.
    public static let home = URL(string: "https://e-hentai.org/home.php")!

    /// `{base}/api.php`.
    public static func api(site: EHSite) -> URL {
        URL(string: "\(site.baseURL.absoluteString)/api.php")!
    }

    /// Image search upload: EH `https://upld.e-hentai.org/image_lookup.php`, EX
    /// `https://exhentai.org/upld/image_lookup.php` (upld.exhentai.org answers 403).
    public static func imageLookupURL(for site: EHSite) -> URL {
        switch site {
        case .eh: URL(string: "https://upld.e-hentai.org/image_lookup.php")!
        case .ex: URL(string: "https://exhentai.org/upld/image_lookup.php")!
        }
    }

    /// `https://forums.e-hentai.org/index.php?showuser={id}`.
    public static func forumProfile(memberID: Int) -> URL {
        URL(string: "https://forums.e-hentai.org/index.php?showuser=\(memberID)")!
    }

    /// The password login form target.
    public static let forumLogin = URL(string: "https://forums.e-hentai.org/index.php?act=Login&CODE=01")!
    /// The page the password login form comes from; sent as its `Referer`.
    public static let forumLoginReferer = URL(string: "https://forums.e-hentai.org/index.php?act=Login&CODE=00")!
    /// Where web login starts.
    public static let webLoginStart = URL(string: "https://forums.e-hentai.org/index.php?act=Login")!
}

/// Percent-encoding for URL parts.
enum URLEncoding {
    /// Everything but ASCII letters, digits and "-._~" is encoded (a space is "%20").
    static func component(_ value: String) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}
