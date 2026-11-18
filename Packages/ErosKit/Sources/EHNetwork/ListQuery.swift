import EHModels
import EHParsing
import Foundation

/// The period of a toplist.
public enum ToplistPeriod: Int, Sendable, Codable, CaseIterable {
    case yesterday = 15, month = 13, year = 12, allTime = 11
}

/// Which list of galleries to ask for.
public enum ListSource: Sendable, Hashable, Codable {
    case front, popular, watched
    /// A favorites folder, or all of them when nil.
    case favorites(folder: Int?)
    case toplist(ToplistPeriod)
    case tag(TagRef)
    case uploader(String)
}

/// A gallery a list pages from: the page after it (`next`) or before it (`prev`).
public enum ListCursor: Sendable, Hashable, Codable {
    case next(String), previous(String)
}

/// Where in the list to start.
public enum ListPosition: Sendable, Hashable, Codable {
    case first
    /// The page after the one ending at this gallery id (`next`).
    case next(String)
    /// The page before the one starting at this gallery id (`prev`).
    case previous(String)
    /// A page number (`page`; `p` for a toplist).
    case page(Int)
    /// A date or relative jump (`jump`).
    case jump(String)
    /// A date to seek to (`seek`).
    case seek(String)
    /// A relative jump and a date to seek to, each when non-nil, from a cursor when non-nil (`jump`, `seek`, then `next`
    /// or `prev`; Flutter request.dart:40-182 `gidOrTimeParams`).
    case offset(jump: String?, seek: String?, from: ListCursor?)
}

/// A gallery list request: the source, search text, category filter, advanced options and position.
public struct ListQuery: Sendable, Hashable, Codable {
    public var source: ListSource
    public var search: String?
    /// The `f_cats` bit mask of excluded categories.
    public var excludedCategories: Int?
    public var advanced: AdvancedSearch?
    public var position: ListPosition

    public init(
        source: ListSource, search: String? = nil, excludedCategories: Int? = nil,
        advanced: AdvancedSearch? = nil, position: ListPosition = .first
    ) {
        self.source = source
        self.search = search
        self.excludedCategories = excludedCategories
        self.advanced = advanced
        self.position = position
    }

    /// The list address on `site` (a toplist is always on e-hentai.org).
    ///
    /// Query order follows Flutter's `getGallery`: `f_cats` (front, watched, tag, uploader), `f_search` (all but
    /// popular and toplist), `tl`, `favcat`, the position, then `advsearch=1` with the advanced options. A popular
    /// list takes no search, position or advanced options; a toplist ignores `search`, `excludedCategories` and
    /// `advanced` (it has no search; Flutter sends advanced options there by oversight, not by design).
    public func url(for site: EHSite) -> URL {
        var path = ""
        var items: [URLQueryItem] = []
        var base = site.baseURL.absoluteString
        var isToplist = false
        var isPopular = false
        var usesCategories = false
        switch source {
        case .front: path = "/"; usesCategories = true
        case .popular: path = "/popular"; isPopular = true
        case .watched: path = "/watched"; usesCategories = true
        case .favorites: path = "/favorites.php"
        case .toplist: base = EHSite.eh.baseURL.absoluteString; path = "/toplist.php"; isToplist = true
        case .tag(let tag):
            path = "/tag/" + Self.tagPath(tag.raw); usesCategories = true
        case .uploader(let name):
            path = "/uploader/" + URLEncoding.component(name); usesCategories = true
        }

        if usesCategories, let excludedCategories {
            items.append(URLQueryItem(name: "f_cats", value: String(excludedCategories)))
        }
        if !isToplist, !isPopular, let search {
            items.append(URLQueryItem(name: "f_search", value: search))
        }
        if case .toplist(let period) = source {
            items.append(URLQueryItem(name: "tl", value: String(period.rawValue)))
        }
        if case .favorites(let folder?) = source {
            items.append(URLQueryItem(name: "favcat", value: String(folder)))
        }
        if !isPopular {
            switch position {
            case .first: break
            case .page(let number): items.append(URLQueryItem(name: isToplist ? "p" : "page", value: String(number)))
            case .jump(let value): items.append(URLQueryItem(name: "jump", value: value))
            case .seek(let value): items.append(URLQueryItem(name: "seek", value: value))
            case .next(let value): items.append(URLQueryItem(name: "next", value: value))
            case .previous(let value): items.append(URLQueryItem(name: "prev", value: value))
            case .offset(let jump, let seek, let from):
                if let jump { items.append(URLQueryItem(name: "jump", value: jump)) }
                if let seek { items.append(URLQueryItem(name: "seek", value: seek)) }
                switch from {
                case .next(let value)?: items.append(URLQueryItem(name: "next", value: value))
                case .previous(let value)?: items.append(URLQueryItem(name: "prev", value: value))
                case nil: break
                }
            }
        }
        if !isPopular, !isToplist, let advanced {
            let extra = AdvancedSearchParser.queryItems(for: advanced)
            if !extra.isEmpty {
                items.append(URLQueryItem(name: "advsearch", value: "1"))
                items += extra
            }
        }
        return URL(string: base + path + Self.queryString(items))!
    }

    /// "?a=b&c=d" with every name and value percent-encoded; empty for no items.
    static func queryString(_ items: [URLQueryItem]) -> String {
        guard !items.isEmpty else { return "" }
        return "?" + items.map { "\(URLEncoding.component($0.name))=\(URLEncoding.component($0.value ?? ""))" }
            .joined(separator: "&")
    }

    /// Spaces become "+"; ":" and "+" stay; other reserved characters are percent-encoded.
    private static func tagPath(_ raw: String) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~:+")
        return raw.replacingOccurrences(of: " ", with: "+")
            .addingPercentEncoding(withAllowedCharacters: allowed) ?? raw
    }
}
